#!/data/data/com.termux/files/usr/bin/bash
# dsh-termux · 为 android-arm64 编译 @deepseek-ai/node-addon-system 的 flock 原生插件
#
# 背景：dsh 的会话持久化用 POSIX 非阻塞 flock 做互斥；该能力由一个只有
# linux/darwin 预编译包的原生模块提供，Android 上直接抛
# `flock is not supported on android-arm64`，会话一开就挂。
#
# 但 bionic 的 flock(2) 本身完全可用（本机实测：争用时正确返回 EWOULDBLOCK=11）。
# 包自带 src/flock.c（自包含 N-API v8 插件），Termux 自带 $PREFIX/include/node 全套头文件，
# 所以直接 clang -shared 编一个即可。
#
# 为什么不走 node-gyp：npm ≥ 11.10 自带的 node-gyp ≥ 12.3 会把 process.config 里的
# OS=android 写进 config.gypi，gyp 的 "OS == android" 分支随即引用未定义的
# android_ndk_path 而失败（社区记录过的坑）。这里根本用不上它。
set -u

PREFIX=/data/data/com.termux/files/usr
DSH="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
ENTRY="$DSH/node_modules/@deepseek-ai/node-addon-system"
PKG="$DSH/node_modules/@deepseek-ai/node-addon-system-android-arm64"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }

say "前置检查"
CLANG="$(command -v clang || true)"
[ -n "$CLANG" ] || { echo "✗ 没有 clang，先 pkg install clang"; exit 1; }
[ -f "$ENTRY/src/flock.c" ] || { echo "✗ 找不到 $ENTRY/src/flock.c（上游布局变了）"; exit 1; }
[ -f "$PREFIX/include/node/node_api.h" ] || {
  echo "✗ 找不到 $PREFIX/include/node/node_api.h"; exit 1; }
echo "  clang     = $CLANG"
echo "  源码      = $ENTRY/src/flock.c"
echo "  头文件    = $PREFIX/include/node"

say "编译"
mkdir -p "$PKG/bin"

# 让 Node 的解析器找得到这个平台包：flock.js 会 require.resolve(
# '@deepseek-ai/node-addon-system-android-arm64/package.json') 再取同级的 bin/system.node
cat > "$PKG/package.json" <<'EOF'
{
  "name": "@deepseek-ai/node-addon-system-android-arm64",
  "version": "0.1.2",
  "private": true,
  "description": "Locally built Android/arm64 system primitives: asynchronous POSIX flock.",
  "main": "bin/system.node",
  "files": ["bin/"]
}
EOF

"$CLANG" -shared -fPIC -O2 -Wall \
  -I"$PREFIX/include/node" \
  -o "$PKG/bin/system.node" \
  "$ENTRY/src/flock.c" || { echo "✗ 编译失败"; exit 1; }
chmod 644 "$PKG/bin/system.node"
echo "  → $PKG/bin/system.node  ($(wc -c < "$PKG/bin/system.node") 字节)"

say "验证原生插件本身（绕开 flock.js 的平台判断，直接 require .node）"
VERIFY="$TMPDIR/verify-flock-binding.mjs"
cat > "$VERIFY" <<'EOF'
const binding = (await import("node:module")).createRequire(import.meta.url)(
  process.env.NODE_ADDON_SYSTEM_BIN);
const { openSync, closeSync, writeFileSync } = await import("node:fs");
const path = process.env.TMPDIR + "/flock-binding-verify.lock";
writeFileSync(path, "");
const call = (fd) => new Promise((resolve) => binding.tryLock(fd, resolve));

const a = openSync(path, "r+");
const b = openSync(path, "r+");
const e1 = await call(a);
console.log("  第一个 fd 加锁        -> errno=" + e1 + (e1 === 0 ? "（拿到锁）" : " ✗"));
const e2 = await call(b);
console.log("  第二个 fd 争用        -> errno=" + e2 +
  (e2 === 11 ? "（EWOULDBLOCK，符合预期）" : " ✗ 期望 11"));
closeSync(a);
await new Promise((r) => setTimeout(r, 50));
const c = openSync(path, "r+");
const e3 = await call(c);
console.log("  释放后第三方 fd 加锁  -> errno=" + e3 + (e3 === 0 ? "（拿到锁）" : " ✗"));
closeSync(b); closeSync(c);

if (e1 === 0 && e2 === 11 && e3 === 0) {
  console.log("  ✓ 原生 flock 在 android-arm64 上真实可用");
} else {
  console.log("  ✗ 原生 flock 行为不符预期");
  process.exitCode = 1;
}
EOF
NODE_ADDON_SYSTEM_BIN="$PKG/bin/system.node" TMPDIR="$TMPDIR" node "$VERIFY"
