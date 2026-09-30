#!/data/data/com.termux/files/usr/bin/bash
# bootstrap.sh —— 一键安装入口：curl 拉源 → 本地构建 install-gateway.sh → 执行。
#
# Termux 里敲一行：
#   curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash
#
# 指定分支 / tag / commit：
#   curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash -s v0.2
#
# 为什么不直接下载现成的安装器：install-gateway.sh 是生成物，按项目规矩不入版本库
# （改了 payload 忘了重建、产物里长期内联旧版本的亏吃过）。所以这里拉的是源文件，
# 当场构建，永远和仓库一致。前置依赖只要 curl + python3；nodejs / termux-services
# 由安装器自己检查并提示。
set -u

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:${PATH}"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"

REF="${1:-main}"
# 可覆盖：自建镜像 / 本地调试，如 DSH_RAW=http://127.0.0.1:8123
RAW="${DSH_RAW:-https://raw.githubusercontent.com/antorun/termux_dsh}"

step() { printf '\n==================================================================\n%s\n==================================================================\n' "$1"; }

command -v curl >/dev/null 2>&1 || { echo "✗ 缺 curl：pkg install curl 后重跑本命令"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "✗ 缺 python3（构建安装器要用）：pkg install python 后重跑本命令"; exit 1; }

WORK="$TMPDIR/dsh-boot-$(date +%s)"
mkdir -p "$WORK" || { echo "✗ 建不了工作目录 $WORK"; exit 1; }

# 与 install/build-install-gateway.py 的 PAYLOADS 保持一致（新增 payload 时两处同步改；
# 漏了的话构建器会用「缺文件: ...」明确报错，不会静默装成旧的）
FILES="bin/dsh-ctl-gateway
share/dsh-ctl/panel.html
bin/dsh-web-url
bin/dsh-patch-lan-settings
bin/dsh-set-provider
bin/dsh-set-key
bin/dsh-lan-gateway
bin/dsh-lan-ip
bin/verify-hot-reload.sh
install/patches.py
install/build-flock.sh
install/uninstall.sh
install/install-web-service.sh
runit/dsh-ctl-run
install/install-gateway.head.sh
install/build-install-gateway.py"

step "1/3 拉源文件（ref=${REF}）→ ${WORK}"
cd "$WORK" || exit 1
fail=0
i=0
total=$(printf '%s\n' "$FILES" | grep -c .)
for f in $FILES; do
  i=$((i + 1))
  if mkdir -p "$(dirname "$f")" && curl -fsSL --retry 2 -m 40 -o "$f" "$RAW/$REF/$f"; then
    sz=$(wc -c <"$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 0 ]; then
      printf '  [%2d/%2d] %-42s %s 字节\n' "$i" "$total" "$f" "$sz"
    else
      echo "  ✗ 拉下来是空文件：$f"
      fail=1
    fi
  else
    echo "  ✗ 拉不到：$RAW/$REF/$f"
    fail=1
  fi
done
if [ "$fail" != 0 ]; then
  echo
  echo "有源文件没拉成。常见原因：到 raw.githubusercontent.com 网络不通，或 ref 写错。"
  echo "备选（走 github.com 而不是 raw）："
  echo "  git clone --depth 1 https://github.com/antorun/termux_dsh.git"
  echo "  cd termux_dsh && bash bootstrap.sh"
  exit 1
fi

step "2/3 构建安装器"
python3 install/build-install-gateway.py || { echo "✗ 构建失败（看上面的「缺文件」提示）"; exit 1; }
GEN="install/install-gateway.sh"
[ -s "$GEN" ] || { echo "✗ 没生成 $GEN"; exit 1; }
bash -n "$GEN" || { echo "✗ 生成物语法检查没过"; exit 1; }
echo "  生成 $(wc -c <"$GEN") 字节，语法自检通过"

step "3/3 执行安装器"
echo "  工作目录：${WORK}（不看可删；重跑本命令会建新的）"
echo "  安装器会检查 nodejs / termux-services，缺了会提示 pkg install 命令。"
echo
if [ -n "${DSH_BUILD_ONLY:-}" ]; then
  echo "  DSH_BUILD_ONLY 已设：只构建不执行。生成物在 $WORK/$GEN"
  exit 0
fi
exec bash "$GEN"
