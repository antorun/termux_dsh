export PREFIX="/data/data/com.termux/files/usr"; export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
D="$PREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules"
echo "=== 关键原生依赖（含 scope 路径）==="
for m in "@deepseek-ai/node-addon-require-builtin" "@deepseek-ai/node-addon-system" \
         "@deepseek-ai/node-addon-system-android-arm64" "@koromix/koffi" "@koromix/koffi-android-arm64" \
         "node-pty" "sharp" "@img/sharp-android-arm64"; do
  p="$D/$m"
  if [ -e "$p" ]; then printf '  %-46s 有\n' "$m"; else printf '  %-46s 缺\n' "$m"; fi
done
echo
echo "=== 哪些 .node 是「本地编的」而不是 npm 下发的 ==="
for f in "$PREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/node-addon-system-android-arm64/bin/system.node" \
         "$PREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty/build/Release/pty.node"; do
  [ -f "$f" ] && printf '  %-70s %s  %s\n' "${f#$PREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules/}" "$(wc -c <"$f")B" "$(date -r "$f" '+%m-%d %H:%M')"
done
echo "  （对比：npm 下发的 darwin-arm64 预编译时间）"
ls -la --time-style=+%m-%d\ %H:%M "$PREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty/prebuilds/darwin-arm64/" 2>/dev/null | tail -2 | sed 's/^/    /'
echo
echo "=== sharp 能不能 load（已知降级项，复核）==="
cd "$TMPDIR" 2>/dev/null || cd /tmp
node -e 'require("/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/sharp")' 2>&1 | grep -E "Error|Cannot find|Could not" | head -3 | sed 's/^/  /'
echo
echo "=== build-flock.sh 的关键行 ==="
grep -nE "clang|target|outfile|system.node|npmrc|node-gyp" "$HOME/dsh-termux/build-flock.sh" 2>/dev/null | head -14 | sed 's/^/  /'
echo
echo "=== 清点补丁编辑处数（按 marker 统计）==="
P="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
for f in $(grep -rlE "termux-expose-internals|termux-android-flock|termux-link-|dsh-termux-lan" "$P" --include="*.js" 2>/dev/null); do
  n=$(grep -coE "termux-expose-internals|termux-android-flock|termux-link-[a-z-]+|dsh-termux-lan" "$f")
  printf '  %-72s %s 处\n' "${f#$P/}" "$n"
done
