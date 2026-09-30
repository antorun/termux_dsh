#!/usr/bin/env bash
# tests/test-uninstall.sh —— 在 Mac 上用假树真跑 install/uninstall.sh
#
# uninstall.sh 的每一刀都是 rm -rf，唯一能放心测的办法是造一棵假树：
# 伪造 Termux 的 $PREFIX（runit 服务目录、svlogd 日志、bin/、share/、npm 包）
# 和假的 $HOME（.dsh 用户数据、补丁备份、工作目录），再通过环境变量覆盖
# PREFIX / SVDIR / LOGDIR / HOME（uninstall.sh 头部声明支持的入口）把脚本
# 指向假树。sv 和 npm 是两个桩脚本：sv 只记录 down 调用，npm 真删假包目录。
#
# 用例：
#   T1 -n        预演：列出 3 服务 + 8 工具 + 面板资源，但一个字节不动
#   T2 -y        默认层：服务/日志/工具/面板删掉，用户数据 + dsh 包 + 别人的服务留着
#   T3 -y --all  连 dsh 包（走 npm 桩）/ 用户数据 / 工作目录一起删
#   T4 再跑      幂等：没有可卸载的东西，退出 0
#   T5 拒绝确认  输入 no → 退出 1，树原样不动
#   T6 未知参数  退出 2
#
# 跑法：bash tests/test-uninstall.sh（从仓库根目录）
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UNINSTALL="$ROOT/install/uninstall.sh"
[ -f "$UNINSTALL" ] || { echo "找不到 $UNINSTALL"; exit 2; }

PASS=0
FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { # check <名字> <实际> <期望>
  if [ "$2" = "$3" ]; then ok "$1 = $3"
  else bad "$1：实际=$2 期望=$3"; fi
}
sec() { printf '\n########## %s ##########\n' "$1"; }

SERVICES="dsh-web dsh-lan dsh-ctl"
TOOLS="dsh-ctl-gateway dsh-set-provider dsh-set-key dsh-web-url dsh-patch-lan-settings dsh-lan-ip dsh-lan-gateway verify-hot-reload.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 建假树
# 仿真设备布局：多放 cloudflared（别人的服务/日志）和 bin/dsh（npm 的符号
# 链接）—— 这两个是「绝对不能误删」的哨兵，每个用例都要验它们还活着。
build_tree() {
  STUB="$WORK/tree"
  rm -rf "$STUB"
  mkdir -p "$STUB/bin" "$STUB/var/service" "$STUB/var/log/sv" \
           "$STUB/share/dsh-ctl" \
           "$STUB/lib/node_modules/@deepseek-ai/dsh/lib" \
           "$STUB/home/.dsh/sessions" "$STUB/home/.dsh-termux-backup/orig" \
           "$STUB/home/dsh-termux/backups"

  for svc in $SERVICES; do
    mkdir -p "$STUB/var/service/$svc/supervise" "$STUB/var/service/$svc/log" \
             "$STUB/var/log/sv/$svc"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexec sleep 100\n' \
      > "$STUB/var/service/$svc/run"
    chmod +x "$STUB/var/service/$svc/run"
    echo "log of $svc" > "$STUB/var/log/sv/$svc/current"
  done

  # 别人的服务 + 日志（哨兵）
  mkdir -p "$STUB/var/service/cloudflared" "$STUB/var/log/sv/cloudflared"
  echo "someone else" > "$STUB/var/service/cloudflared/run"

  # 8 个自写工具（内容是占位，不会被真执行）
  for t in $TOOLS; do
    printf '#!/bin/false\necho %s\n' "$t" > "$STUB/bin/$t"
    chmod +x "$STUB/bin/$t"
  done

  # npm 装的 dsh 符号链接（哨兵：不在 TOOLS 名单里，默认层不许动）
  ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$STUB/bin/dsh"
  echo '{"name":"@deepseek-ai/dsh"}' \
    > "$STUB/lib/node_modules/@deepseek-ai/dsh/package.json"
  echo 'console.log("dsh")' > "$STUB/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"

  echo '<html>panel</html>' > "$STUB/share/dsh-ctl/panel.html"

  echo '{}' > "$STUB/home/.dsh/accounts.json"
  echo 'orig' > "$STUB/home/.dsh-termux-backup/orig/server.js"
  echo 'work notes' > "$STUB/home/dsh-termux/notes.txt"

  # sv 桩：只记 down 调用，不真停什么（假树里没有 runsv）
  cat > "$STUB/bin/sv" <<'STUB_SV'
#!/usr/bin/env bash
PREFIX=$(cd "$(dirname "$0")/.." && pwd)
echo "down $2" >> "$PREFIX/.sv-calls"
STUB_SV
  chmod +x "$STUB/bin/sv"

  # npm 桩：认 uninstall -g @deepseek-ai/dsh，真删假包目录 + bin/dsh 链接
  cat > "$STUB/bin/npm" <<'STUB_NPM'
#!/usr/bin/env bash
PREFIX=$(cd "$(dirname "$0")/.." && pwd)
if [ "$*" = "uninstall -g @deepseek-ai/dsh" ]; then
  rm -rf "$PREFIX/lib/node_modules/@deepseek-ai/dsh"
  rm -f "$PREFIX/bin/dsh"
  echo "removed @deepseek-ai/dsh"
  exit 0
fi
echo "npm 桩：意外参数 $*" >&2
exit 1
STUB_NPM
  chmod +x "$STUB/bin/npm"
}

# 跑被测脚本（子 shell 里覆盖环境，不污染本测试）
run() {
  ( PREFIX="$STUB" SVDIR="$STUB/var/service" LOGDIR="$STUB/var/log" \
    HOME="$STUB/home" bash "$UNINSTALL" "$@" )
}

DIR_GONE() { [ -e "$1" ] && bad "$2 残留：$1" || ok "$2 已删：$1"; }

# =================================================================== T1
build_tree
sec "T1. -n 预演：列清单，树完整"
OUT=$(run -n); RC=$?
check "退出码" "$RC" 0
for svc in $SERVICES; do
  case "$OUT" in *"$svc"*) ok "列出服务 $svc";; *) bad "没列出服务 $svc";; esac
done
for t in $TOOLS; do
  case "$OUT" in *"$t"*) ok "列出工具 $t";; *) bad "没列出工具 $t";; esac
done
case "$OUT" in *"$STUB/share/dsh-ctl"*) ok "列出面板资源";; *) bad "没列出面板资源";; esac
case "$OUT" in *"将删"*) ok "预演标了「将删」";; *) bad "预演没有「将删」标记";; esac
for svc in $SERVICES; do
  [ -d "$STUB/var/service/$svc" ] && ok "服务目录仍在 $svc" || bad "预演删了服务目录 $svc"
done
for t in $TOOLS; do
  [ -e "$STUB/bin/$t" ] && ok "工具仍在 $t" || bad "预演删了工具 $t"
done
[ -d "$STUB/share/dsh-ctl" ] && ok "面板资源仍在" || bad "预演删了面板资源"
[ -L "$STUB/bin/dsh" ] && ok "npm 的 dsh 链接仍在" || bad "预演动了 bin/dsh"

# =================================================================== T5
sec "T5. 拒绝确认（输入 no）：树原样不动"
OUT=$(echo no | run); RC=$?
check "退出码" "$RC" 1
case "$OUT" in *"已取消"*) ok "提示已取消";; *) bad "没有取消提示";; esac
[ -d "$STUB/var/service/dsh-web" ] && ok "服务目录仍在" || bad "拒绝后仍被删"
[ -e "$STUB/bin/dsh-ctl-gateway" ] && ok "工具仍在" || bad "拒绝后仍被删"
[ -d "$STUB/share/dsh-ctl" ] && ok "面板资源仍在" || bad "拒绝后仍被删"

# =================================================================== T2
sec "T2. -y 默认层：服务/日志/工具/面板走，其余留"
OUT=$(run -y); RC=$?
check "退出码" "$RC" 0
for svc in $SERVICES; do
  DIR_GONE "$STUB/var/service/$svc" "服务目录 $svc"
  DIR_GONE "$STUB/var/log/sv/$svc" "日志目录 $svc"
done
for t in $TOOLS; do
  DIR_GONE "$STUB/bin/$t" "工具 $t"
done
DIR_GONE "$STUB/share/dsh-ctl" "面板资源"
[ -d "$STUB/lib/node_modules/@deepseek-ai/dsh" ] && ok "dsh npm 包保留" || bad "默认层删了 dsh 包"
[ -L "$STUB/bin/dsh" ] && ok "npm 的 bin/dsh 链接保留" || bad "默认层动了 bin/dsh"
[ -f "$STUB/home/.dsh/accounts.json" ] && ok "~/.dsh 用户数据保留" || bad "默认层删了用户数据"
[ -d "$STUB/home/.dsh-termux-backup" ] && ok "补丁备份保留" || bad "默认层删了补丁备份"
[ -f "$STUB/home/dsh-termux/notes.txt" ] && ok "工作目录保留" || bad "默认层删了工作目录"
[ -d "$STUB/var/service/cloudflared" ] && ok "别人的服务 cloudflared 没被动" || bad "误删了 cloudflared"
[ -d "$STUB/var/log/sv/cloudflared" ] && ok "别人的日志没被动" || bad "误删了 cloudflared 日志"
SVC_DOWN=$({ wc -l < "$STUB/.sv-calls" 2>/dev/null || echo 0; } | tr -d '[:space:]')
check "sv down 调用次数" "$SVC_DOWN" 3

# =================================================================== T3
sec "T3. -y --all：dsh 包 / 用户数据 / 工作目录一起删"
OUT=$(run -y --all); RC=$?
check "退出码" "$RC" 0
DIR_GONE "$STUB/lib/node_modules/@deepseek-ai/dsh" "dsh 包"
DIR_GONE "$STUB/bin/dsh" "npm 的 bin/dsh 链接"
DIR_GONE "$STUB/home/.dsh" "用户数据 .dsh"
DIR_GONE "$STUB/home/.dsh-termux-backup" "补丁备份"
DIR_GONE "$STUB/home/dsh-termux" "工作目录"
[ -d "$STUB/var/service/cloudflared" ] && ok "cloudflared 仍在（--all 也不动别人的）" || bad "--all 误删 cloudflared"
case "$OUT" in *"npm uninstall -g @deepseek-ai/dsh"*) ok "走了 npm 卸载";; *) bad "没走 npm 卸载";; esac

# =================================================================== T4
sec "T4. 幂等：再跑报告「没有可卸载的东西」"
OUT=$(run -y --all); RC=$?
check "退出码" "$RC" 0
case "$OUT" in *"没有可卸载的东西"*) ok "报告干净";; *) bad "没报告干净";; esac

# =================================================================== T6
sec "T6. 未知参数 → 退出 2"
OUT=$(run --bogus 2>/dev/null); RC=$?
check "退出码" "$RC" 2

# ===================================================================
sec "结果"
printf '通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
