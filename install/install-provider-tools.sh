#!/data/data/com.termux/files/usr/bin/bash
# 安装 dsh-set-key v2 + dsh-set-provider
set -eu
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
SRC=/data/data/com.termux/files/usr/tmp/dsh-tools
mkdir -p "$SRC" "$HOME/dsh-termux"

echo "== 语法自检 =="
bash -n "$SRC/dsh-set-key" && echo "  dsh-set-key OK"
bash -n "$SRC/dsh-set-provider" && echo "  dsh-set-provider OK"

echo "== 安装 =="
install -m 700 "$SRC/dsh-set-key"      "$PREFIX/bin/dsh-set-key"
install -m 700 "$SRC/dsh-set-provider" "$PREFIX/bin/dsh-set-provider"
cp -a "$SRC/dsh-set-key" "$SRC/dsh-set-provider" "$HOME/dsh-termux/"
ls -la "$PREFIX/bin/dsh-set-key" "$PREFIX/bin/dsh-set-provider" "$HOME/dsh-termux/" | sed 's/^/  /'

echo
echo "== 现状 =="
dsh-set-provider
