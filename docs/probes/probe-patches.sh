export PREFIX="/data/data/com.termux/files/usr"; export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
echo "=== \$PREFIX/bin/dsh 是什么 ==="
ls -la "$PREFIX/bin/dsh"; file "$PREFIX/bin/dsh" 2>/dev/null
echo "=== 包内 lib/bin.js 前 3 行 ==="
head -3 "$PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" 2>/dev/null
echo
echo "=== 两个备份目录 ==="
for d in "$HOME/.dsh-termux-backup" "$HOME/dsh-termux/backups"; do
  echo "--- $d ---"; find "$d" -maxdepth 2 2>/dev/null | sed "s|$HOME|~|" | head -20
done
echo
echo "=== patches.py 的补丁函数清单 ==="
grep -nE "^def patch_|^FUNC_MARK|^# >>>|once\(" "$HOME/dsh-termux/patches.py" | sed 's/^/  /' | head -60
