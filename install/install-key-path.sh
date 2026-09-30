#!/data/data/com.termux/files/usr/bin/bash
# 在 Termux 上安装「模型凭据注入」通路：
#   1) 给 runit 的 run 脚本加一个可选 environment 源（幂等，带 marker）
#   2) 落一个命令行工具 dsh-set-key（写凭据 + 重启 + 真调 API 验证）
set -u
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"

SVD="$PREFIX/var/service/dsh-web"
RUN="$SVD/run"
MARK="termux-dsh-credentials"
KEYS="$SVD/environment"

echo "== 0. 清掉无效的 runsv env/ 目录（这版 runit 不认）=="
rm -rf "$SVD/env" && echo "  已移除 $SVD/env"

echo
echo "== 1. 幂等补 run 脚本 =="
if grep -q "$MARK" "$RUN"; then
  echo "  跳过（已打过）"
else
  cp -a "$RUN" "$RUN.bak-$(date +%Y%m%d%H%M%S)"
  python3 - "$RUN" "$MARK" <<'PY'
import sys, pathlib
run, mark = sys.argv[1], sys.argv[2]
p = pathlib.Path(run)
src = p.read_text()
anchor = 'cd "/data/data/com.termux/files/home" || exit 1\n'
assert src.count(anchor) == 1, f"锚点命中 {src.count(anchor)} 次，停手"
block = (
    "# %s: 模型凭据的唯一注入点（由 dsh-set-key 维护，缺失则跳过）。\n"
    "#   dsh 的模型凭据优先级：provider 管理的 .credentials.yaml > 这里是环境变量\n"
    "#   没有 api-key 记录时走环境变量，所以这一行就是唯一的 key 来源。\n"
    'ENVFILE="/data/data/com.termux/files/usr/var/service/dsh-web/environment"\n'
    'if [ -f "$ENVFILE" ]; then . "$ENVFILE"; fi\n\n'
) % mark
p.write_text(src.replace(anchor, block + anchor))
print("  已插入 environment 源")
PY
fi
echo "  --- run 脚本当前内容 ---"
sed 's/^/    /' "$RUN"

echo
echo "== 2. 落地 dsh-set-key =="
cat > "$PREFIX/bin/dsh-set-key" <<'EOS'
#!/data/data/com.termux/files/usr/bin/bash
# dsh-set-key —— 给 dsh-web 守护服务注入/查看/清除模型 API Key
#
#   dsh-set-key sk-xxxxxxxx           写入并重启服务，真调一次 API 验证
#   dsh-set-key --show                显示当前 key（打码）
#   dsh-set-key --clear               清除并重启
#   dsh-set-key --no-restart sk-...   只写文件，不重启
#
# 为什么走环境变量而不是 .credentials.yaml：
#   那份文件由 provider 自己管理（原子写 + 跨进程锁 + 启动期强校验），
#   手工改坏了会让 dsh web 起不来；环境变量是官方支持的等价通路，坏了删掉即可。
set -u
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"

SVD="$PREFIX/var/service/dsh-web"
KEYS="$SVD/environment"
API="https://api.deepseek.com/models"

die() { echo "$*" >&2; exit 1; }

mask() { printf '%s' "$1" | sed -E 's/^(sk-[A-Za-z0-9]{4})[A-Za-z0-9_-]*([A-Za-z0-9]{4})$/\1…\2/'; }

verify() { # $1 = key
  local body code
  body=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "$API" 2>&1) \
    || { echo "  ! 网络请求失败：$body"; return 1; }
  case "$body" in
    200) echo "  ✓ 凭据有效（GET $API → 200）"; return 0 ;;
    401|403) echo "  ✗ 凭据无效（$API → $body）"; return 1 ;;
    *) echo "  ? 意外响应码 $body"; return 1 ;;
  esac
}

restart_and_report() {
  sv restart dsh-web >/dev/null 2>&1 || die "sv restart 失败"
  sleep 4
  sv status dsh-web | sed 's/^/  /'
  local pid
  for p in /proc/[0-9]*/environ; do
    pid=$(printf '%s' "$p" | cut -d/ -f3)
    case "$(tr '\0' ' ' < "$p" 2>/dev/null)" in
      *dsh*web*)
        if tr '\0' '\n' < "$p" 2>/dev/null | grep -q '^DEEPSEEK_API_KEY='; then
          echo "  ✓ 服务进程 $pid 已带上 DEEPSEEK_API_KEY"
        else
          echo "  ! 服务进程 $pid 未见 DEEPSEEK_API_KEY"
        fi;;
    esac
  done
  echo "  令牌: $(dsh-web-url 2>/dev/null | grep -aoE 'http://[^[:space:]]+token=[A-Za-z0-9_-]+' | tail -1)"
}

case "${1:-}" in
  ""|-h|--help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0;;
  --show)
    if [ -f "$KEYS" ]; then
      printf '当前 key: %s\n' "$(mask "$(sed -n 's/^export DEEPSEEK_API_KEY=//p' "$KEYS" | tr -d "'\"")")"
    else
      echo "未设置（$KEYS 不存在）"; fi
    exit 0;;
  --clear)
    rm -f "$KEYS" && echo "已清除 key" || die "删除失败"
    restart_and_report
    exit 0;;
  --no-restart)
    shift; KEY="${1:-}"; RESTART=no;;
  *) KEY="${1:-}"; RESTART=yes;;
esac

[ -n "${KEY:-}" ] || die "用法：dsh-set-key <sk-...>  |  --show  |  --clear"
case "$KEY" in sk-*) ;; *) die "看起来不像 DeepSeek key（应以 sk- 开头）";; esac

umask 077
printf "export DEEPSEEK_API_KEY='%s'\n" "$KEY" > "$KEYS"
chmod 600 "$KEYS"
echo "已写入 $KEYS"

[ "${RESTART:-yes}" = yes ] || { echo "(--no-restart：跳过重启与验证)"; exit 0; }

echo "== 真调 API 验证 =="
if verify "$KEY"; then
  echo "== 重启服务 =="
  restart_and_report
else
  echo "== key 不可用，仍已写入（--clear 可撤销），重启让 Web UI 至少能打开 =="
  restart_and_report
  exit 1
fi
EOS
chmod 700 "$PREFIX/bin/dsh-set-key"
echo "  已安装 $PREFIX/bin/dsh-set-key"

echo
echo "== 3. 备份脚本进 ~/dsh-termux（升级重装后还在）=="
mkdir -p "$HOME/dsh-termux"
cp -a "$PREFIX/bin/dsh-set-key" "$HOME/dsh-termux/dsh-set-key"
echo "  $HOME/dsh-termux/dsh-set-key"

echo
echo "== 4. 语法自检 =="
bash -n "$RUN" && echo "  run 脚本语法 OK"
bash -n "$PREFIX/bin/dsh-set-key" && echo "  dsh-set-key 语法 OK"
"$PREFIX/bin/dsh-set-key" --show
