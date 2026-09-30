#!/data/data/com.termux/files/usr/bin/bash
# verify-hot-reload.sh —— 验证「改 cordis.patch.yml 后 dsh 是否自动生效（是否必须重启）」
#
# 为什么要有这个：
#   8030 面板底部的「保存并重启」里那个 restart，对**配置文件**其实是多余的 ——
#   dsh 自带 @deepseek-ai/dsh-hmr（chokidar 监听 profile patch），改完约 2.3 秒自动重组合。
#   但**密钥**走的是 runit 的 environment 文件（进程启动期注入），那条必须重启。
#   两条链路结论相反，所以必须能随时复验，不能靠记忆。
#
# 判据不是日志（HMR 静默重载，只在 warning 时打日志），而是
#   POST /api/llm/listProviders 的返回值 —— 那是运行中进程内存里的真状态。
#
# 用法：
#   bash verify-hot-reload.sh            # 改 displayName 取值，测生效延迟，自动还原
#
# 退出码：0 = 判定完成（无论结论是"热生效"还是"需重启"）；1 = 环境/前置条件不满足。
set -u

P="$HOME/.dsh/profiles/web/cordis.patch.yml"
LOG="$PREFIX/var/log/sv/dsh-web/current"
T="${TMPDIR:-/tmp}"

die() { echo "✗ $*" >&2; exit 1; }
[ -f "$P" ] || die "找不到 $P"

# 取运行中的 dsh web 进程（sv status 会同时报 svlogd，按 cmdline 判才准）
dsh_pid() {
  for p in /proc/[0-9]*/cmdline; do
    local pid cmd
    pid=$(printf '%s' "$p" | cut -d/ -f3)
    cmd=$(tr '\0' ' ' < "$p" 2>/dev/null)
    case "$cmd" in *"/bin/dsh web"*) printf '%s' "$pid"; return;; esac
  done
}

TOK=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2)
[ -n "$TOK" ] || die "日志里拿不到 token（dsh-web 在跑吗？）"
CJ="$T/hmr-cj.$$"
curl -s -c "$CJ" -b "$CJ" -o /dev/null -L -m 10 "http://127.0.0.1:3080/?token=$TOK"

# 运行中进程内存里的 provider 列表。顺序不固定，所以只做「包含判断」，不取第 N 个。
providers() {
  curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' \
    -d '{"type":"client-request","rpcId":"1","method":"llm/listProviders","payload":{"args":{}}}' \
    -m 8 "http://127.0.0.1:3080/api/llm/listProviders"
}
# 重组合的一瞬间列表可能短暂为空，所以重试几次再下结论
names() {
  local out i
  for i in 1 2 3 4 5 6 7 8; do
    out=$(providers | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//' | tr '\n' ' ')
    [ -n "$out" ] && { printf '%s' "$out"; return; }
    sleep 0.5
  done
}
has_name() { providers | grep -q "\"name\":\"$1\"" && echo yes || echo no; }

PID0=$(dsh_pid)
[ -n "$PID0" ] || die "没找到运行中的 dsh web 进程"
echo "PID=$PID0"
echo "运行中实例当前认得的 provider 名: $(names)"

ORIG_VAL=$(grep -m1 'displayName' "$P" | sed 's/.*displayName: *"//;s/".*//')
[ -n "$ORIG_VAL" ] || die "配置里没有 displayName，换个探针字段再说"
NEW_VAL="${ORIG_VAL}-HMRTEST$$"
MD5_ORIG=$(md5sum "$P" | awk '{print $1}')

echo "把 displayName 由 \"$ORIG_VAL\" 改成 \"$NEW_VAL\"（不重启进程）……"
sed -i "s/displayName: \"$ORIG_VAL\"/displayName: \"$NEW_VAL\"/" "$P"

t0=$(date +%s%N); got=no; waited=0; ms=0
while [ $waited -lt 20000 ]; do
  got=$(has_name "$NEW_VAL")
  [ "$got" = yes ] && { ms=$(( ($(date +%s%N) - t0) / 1000000 )); break; }
  sleep 0.25; waited=$((waited+250))
done
PIDN=$(dsh_pid)

# 还原，用 md5 对账，不靠肉眼
sed -i "s/displayName: \"$NEW_VAL\"/displayName: \"$ORIG_VAL\"/" "$P"
MD5_BACK=$(md5sum "$P" | awk '{print $1}')
waited=0
while [ $waited -lt 15000 ]; do
  [ "$(has_name "$ORIG_VAL")" = yes ] && break
  sleep 0.25; waited=$((waited+250))
done
PIDF=$(dsh_pid)

echo "──────────────────────────────────────────────"
if [ "$got" = yes ]; then
  echo "结论：热生效 ✓  改完 $ms ms 后运行中的 dsh 已认得新值，进程 pid 未变（$PID0 → $PIDN）。"
  echo "      → 只改配置（接口地址 / 模型 / 显示名 / 启用切换）不需要重启。"
else
  echo "结论：20 秒内没生效 ✗（新值始终没出现在运行中实例里）。这条链路上必须重启。"
fi
echo "还原后运行中实例认得: $(names)"
echo "配置已还原：md5 $MD5_BACK $([ "$MD5_BACK" = "$MD5_ORIG" ] && echo '（与改动前一致 ✓）' || echo "（与改动前不一致 ✗ 原 $MD5_ORIG）")"
echo "pid 最终: $PIDF"
echo
echo "注意：本条只覆盖 cordis.patch.yml → dsh 的 provider/模型。"
echo "      密钥不在这条链路上：dsh-set-key 写的是 $PREFIX/var/service/dsh-web/environment，"
echo "      那是 runit 启动期 source 进进程的环境变量 → 写入后必须 sv restart dsh-web 才进进程。"
rm -f "$CJ"
