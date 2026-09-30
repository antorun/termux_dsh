#!/usr/bin/env bash
# tests/test-bootstrap-local.sh —— 不需要真机：造假 Termux 树在本地跑 bootstrap.sh
#
# 覆盖三条路径：
#   A) happy path    : 依赖齐全 → 拉源（本地 http 源）→ 构建 → DSH_BUILD_ONLY 退出 0
#   B) 软依赖降级     : 假 pkg 失败 + 缺 cmake/ninja → 警告「不影响装网关」→ 继续 → 成功
#   C) 硬依赖失败     : 六个核心依赖全缺 + pkg 必失败 → dpkg --configure -a 自愈 → 仍失败 → exit 1
#
# 跑法（仓库根目录）：bash tests/test-bootstrap-local.sh
# 需要：bash / curl / python3（叫 python3 或可通过 stub 指向）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BASE="${TMPDIR:-${TMP:-/tmp}}"
T="$BASE/faketux-$$"          # 假 $PREFIX
H="$BASE/fakehome-$$"         # 假 $HOME（bootstrap 的备份目录写在这下面）
PORT="${PORT:-8719}"
PASS=0; FAIL=0
say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
no()  { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

# ---- python3 探测：bootstrap 第 4 步要它构建安装器。
# 得真的能跑 —— Windows 的 python3 常是应用商店残桩（command -v 认得、执行无效）
PY=""
for cand in python python3 py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'print(1)' >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
if [ -z "$PY" ]; then
  say "没有能跑的 python，本测试跑不了（bootstrap 构建安装器要它）"; exit 2
fi

cleanup() {
  [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
  # runsvdir 桩是常驻的，按 pid 文件收掉（git bash 的 pkill 也不灵）
  if [ -f "${FAKE_PGREP_FILE:-}" ]; then
    kill "$(cat "$FAKE_PGREP_FILE" 2>/dev/null)" 2>/dev/null
    rm -f "$FAKE_PGREP_FILE"
  fi
  rm -rf "$T" "$H"
}
trap cleanup EXIT

# ---- 本地 http 源：直接 serve 仓库根；REF="." 让 URL 是 /./<路径>，
# http.server 会吃掉 "." 比特段（这样就不依赖 msys 半残的 ln -s 了）----
( cd "$ROOT" && exec "$PY" -m http.server "$PORT" >/dev/null 2>&1 ) &
SRV_PID=$!
for _ in $(seq 1 40); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/./bootstrap.sh" && break
  sleep 0.25
done

# ---- 假 PREFIX 里的桩 ----
mkstub() {  # mkstub <名字> <bash 体>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1"
  chmod +x "$1"
}
mkdir -p "$T/bin" "$T/var/service" "$T/tmp" "$H"
# pkg 必失败（测降级 / 失败分支）；dpkg 假装成功
mkstub "$T/bin/pkg"  'echo "FAKE-PKG-FAIL: $*" >&2; exit 1'
mkstub "$T/bin/dpkg" 'echo "FAKE-DPKG: $*" >&2; exit 0'
# runsvdir 桩：写个 pid 文件后常驻。git bash 的 ps 看不到后台脚本的 cmdline，
# 真 pgrep 也没有（pgrep 桩就认这个 pid 文件，见下）。
mkstub "$T/bin/runsvdir" 'echo $$ > "$FAKE_PGREP_FILE"; while :; do sleep 5; done'
# 假 pgrep：认上面那个 pid 文件。bootstrap 只用它问「runsvdir 在不在」。
mkstub "$T/bin/pgrep" '[ -n "${FAKE_PGREP_FILE:-}" ] || exit 1
[ -f "${FAKE_PGREP_FILE:-/nonexistent}" ] || exit 1
PID="$(cat "$FAKE_PGREP_FILE" 2>/dev/null)" || exit 1
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && exit 0
exit 1'
export FAKE_PGREP_FILE="$T/var/runsvdir.pid"
# 假的「核心依赖已装」：command -v 认得 + --version 打一行
for c in sv clang make cmake ninja; do
  mkstub "$T/bin/$c" 'echo "fake-'"$c"' 0.0.0"; exit 0'
done
# python3 桩指向真实 python
mkstub "$T/bin/python3" 'exec '"$PY"' "$@"'

# bootstrap 的 PATH 是 $PREFIX/bin 优先 —— 造假 $HOME 下的 .dsh 备份也会落在 H。
run_boot() {  # run_boot [bootstrap 的参数...] —— REF 用 "." 走本地源的 /./ 路径
  # stdin 给 /dev/null：bootstrap 只在「stdin 是 tty」时才问源站，测试别卡住
  PREFIX="$T" HOME="$H" TMPDIR="$T/tmp" FAKE_PGREP_FILE="$FAKE_PGREP_FILE" \
    bash "$ROOT/bootstrap.sh" "$@" </dev/null 2>&1
}

# ============================== A) happy path ==============================
say "== A) happy path：核心依赖齐全，pkg 会失败但路径上不经过装依赖 =="
OUT=$(DSH_RAW="http://127.0.0.1:$PORT" DSH_BUILD_ONLY=1 run_boot .)
EXIT=$?
echo "$OUT" | grep -q "FAKE-PKG-FAIL: update" && ok "pkg update 失败被优雅吞掉" || no "pkg update 失败没处理"
echo "$OUT" | grep -q "依赖齐全，不重复装" && ok "依赖探测全过" || no "依赖探测没全过"
echo "$OUT" | grep -Eq 'runsvdir\s+ok' && ok "假 runsvdir 被拉起并认出" || no "runsvdir 没被认出"
echo "$OUT" | grep -q "16/16 个" && ok "16 个源文件从本地源拉齐" || no "源文件没拉齐"
echo "$OUT" | grep -q "语法自检通过" && ok "生成器语法自检通过" || no "生成器语法自检失败"
echo "$OUT" | grep -q "DSH_BUILD_ONLY 已设：只构建不执行" && ok "BUILD_ONLY 模式收尾正确" || no "BUILD_ONLY 收尾不对"
[ "$EXIT" = 0 ] && ok "exit 0" || no "退出码 $EXIT（期望 0）"

# ============================== B) 软依赖降级 ==============================
say "== B) 软依赖降级：伪装 cmake/ninja 缺失 + pkg 必失败 =="
# 把 cmake/ninja 的桩挪走 → 进 SOFTMISS；
# 装依赖那段第一次 pkg 失败 → dpkg --configure -a → 重试失败 → 软依赖警告并继续
mkdir -p "$T/hidden"
for c in cmake ninja; do mv "$T/bin/$c" "$T/hidden/" 2>/dev/null; done
OUT=$(DSH_RAW="http://127.0.0.1:$PORT" DSH_BUILD_ONLY=1 run_boot .)
EXIT=$?
echo "$OUT" | grep -q "装：cmake ninja" && ok "列出要补装的软依赖" || no "没列软依赖"
# pkg/dpkg 的输出被重定向进 pkg-install.log（失败那条路径才会 tail 到 stdout），
# 所以这里查最新一次运行的日志文件
LATEST=$(ls -t "$T/tmp"/dsh-boot-*/pkg-install.log 2>/dev/null | head -1)
grep -q "FAKE-DPKG: --configure -a" "$LATEST" && ok "失败后跑了 dpkg --configure -a 自愈" || no "没跑 dpkg 自愈（日志: $LATEST）"
echo "$OUT" | grep -q "核心依赖 ok；cmake/ninja 装不上" && ok "软依赖降级（继续而不是退出）" || no "软依赖降级分支没走到"
echo "$OUT" | grep -q "koffi 原生编译要它" && ok "给出事后补装提示" || no "没给补装提示"
echo "$OUT" | grep -q "16/16 个" && ok "降级后下载/构建继续完成" || no "降级后没走完"
[ "$EXIT" = 0 ] && ok "exit 0" || no "退出码 $EXIT（期望 0）"

# ============================== C) 硬依赖全败 ==============================
say "== C) 硬依赖失败：把假核心依赖挪走 → 六个全「缺」+ pkg 必败 → exit 1 =="
for c in sv clang make python3; do mv "$T/bin/$c" "$T/hidden/" 2>/dev/null; done
OUT=$(DSH_RAW="http://127.0.0.1:$PORT" run_boot .)
EXIT=$?
echo "$OUT" | grep -qE '装：.*clang' && ok "列出缺的硬依赖" || no "没列出硬依赖"
echo "$OUT" | grep -q "FAKE-DPKG: --configure -a" && ok "先跑了 dpkg 自愈" || no "没跑 dpkg 自愈"
echo "$OUT" | grep -q "依赖装不上，看日志" && ok "硬依赖失败最终报错退出" || no "硬依赖失败没报错退出"
echo "$OUT" | grep -q "shared-mime-info gtk3 libdecor sdl2" && ok "给出自救命令" || no "没给自救命令"
[ "$EXIT" = 1 ] && ok "exit 1（硬依赖装不上就该停）" || no "退出码 $EXIT（期望 1）"

say ""
say "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" = 0 ] || exit 1
