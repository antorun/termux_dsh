#!/data/data/com.termux/files/usr/bin/bash
# dsh-termux · 在 Termux(Android) 上把 @deepseek-ai/dsh 补成可用状态
#
# 用法（脚本本体从 Mac 推过来，落在 $TMPDIR，不污染 home）：
#   bash $TMPDIR/install.sh --code      # 只打 JS 补丁（解开启动）
#   bash $TMPDIR/install.sh --check     # 只体检，不改任何东西
#
# 为什么需要补丁：见 patches.py 顶部说明。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:---code}"

PREFIX=/data/data/com.termux/files/usr
DSH="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
NODE_BIN="$(command -v node || true)"
PY_BIN="$(command -v python3 || true)"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }

say "环境"
echo "  node    = ${NODE_BIN:-（缺）}  $($NODE_BIN -v 2>/dev/null)"
echo "  npm     = $(command -v npm || echo '（缺）')  $(npm -v 2>/dev/null)"
echo "  python3 = ${PY_BIN:-（缺）}"
echo "  dsh     = $DSH"
if [ -d "$DSH" ]; then
  echo "  dsh 版本= $(node -p "require('$DSH/package.json').version" 2>/dev/null)"
else
  echo "  ✗ dsh 没装，先跑：npm install -g @deepseek-ai/dsh"
  exit 1
fi

[ -n "$NODE_BIN" ] || { echo "✗ 没有 node，先 pkg install nodejs"; exit 1; }
[ -n "$PY_BIN" ] || { echo "✗ 没有 python3，先 pkg install python"; exit 1; }

say "native Termux 能力体检（不装东西，只报事实）"
for p in clang cmake ninja build-essential libvips; do
  if [ -e "$PREFIX/bin/$(echo "$p" | sed 's/build-essential/make/')" ]; then
    echo "  ✓ $p"
  else
    echo "  ✗ $p（缺，编译原生模块时才需要）"
  fi
done
echo "  link(2) 支持：$(
  cd "$TMPDIR" && rm -rf .lktest && mkdir .lktest && echo x > .lktest/a
  if ln .lktest/a .lktest/b 2>/dev/null; then echo '可用'; else echo '被内核拒绝（EACCES）—— 需要 link→rename 补丁'; fi
  rm -rf .lktest
)"

if [ "$MODE" = "--check" ]; then
  say "补丁状态"
  "$PY_BIN" "$HERE/patches.py" --list
  say "flock 原生插件状态"
  FB="$DSH/node_modules/@deepseek-ai/node-addon-system-android-arm64/bin/system.node"
  if [ -f "$FB" ]; then echo "  ✓ 已编：$FB（$(wc -c < "$FB") 字节）"; else echo "  ✗ 未编（跑 --flock 或 --all）"; fi
  exit 0
fi

if [ "$MODE" = "--flock" ] || [ "$MODE" = "--all" ]; then
  say "编译 flock 原生插件（android-arm64）"
  bash "$HERE/build-flock.sh" || exit 1
fi

say "打 JS 补丁"
"$PY_BIN" "$HERE/patches.py" || exit 1

say "复查"
head -1 "$DSH/lib/bin.js"
grep -c 'termux-expose-internals' \
  "$DSH/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js" \
  "$DSH/node_modules/@deepseek-ai/dsh-app-boot/lib/worker/profile-resolution-bootstrap.js"

say "跑一次 dsh --version"
dsh --version 2>&1 | head -3
echo "rc=$?"
