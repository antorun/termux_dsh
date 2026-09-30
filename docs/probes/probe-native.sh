export PREFIX="/data/data/com.termux/files/usr"; export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
D="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
echo "=== 原生依赖现状 ==="
for m in node-addon-require-builtin node-addon-system node-addon-system-android-arm64 node-pty @koromix/koffi sharp; do
  p="$D/node_modules/$m"
  if [ -e "$p" ]; then printf '  %-38s %s\n' "$m" "$([ -d "$p" ] && echo 目录 || echo 文件)"; else printf '  %-38s (缺失)\n' "$m"; fi
done
echo
echo "=== node-pty 有没有 android 预编译 ==="
ls "$D/node_modules/node-pty/prebuilds/" 2>/dev/null | tr '\n' ' '; echo
echo "  build/Release: $(ls "$D/node_modules/node-pty/build/Release" 2>/dev/null | tr '\n' ' ')"
echo "  有无 napi 版本: $(ls "$D/node_modules/node-pty/build/Release/"*.node >/dev/null 2>&1 && echo 有 || echo 无)"
echo
echo "=== node-addon-system 结构 ==="
find "$D/node_modules/@deepseek-ai/node-addon-system" -maxdepth 3 \( -name "*.node" -o -name package.json -o -name "*.js" \) 2>/dev/null | sed "s|$D/node_modules/@deepseek-ai/||" | sed 's/^/  /'
echo "  内容: $(head -c 200 "$D/node_modules/@deepseek-ai/node-addon-system-android-arm64/package.json" 2>/dev/null)"
echo
echo "=== flock 实测（android 平台闸门放开后能否 require）==="
cd "$TMPDIR" 2>/dev/null || cd /tmp
node -e 'const m=require("/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/node-addon-system/lib/flock.js");console.log("  require 成功, 导出:",Object.keys(m).join(","))' 2>&1 | head -5
echo
echo "=== profiles/web/cordis.patch.yml ==="
cat "$HOME/.dsh/profiles/web/cordis.patch.yml" 2>/dev/null | sed 's/^/  /'
