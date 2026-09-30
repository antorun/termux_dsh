#!/data/data/com.termux/files/usr/bin/bash
# dsh-termux · 卸载脚本（install.sh 的逆操作，幂等）
#
# 用法（和安装脚本一样：从 Mac 推过来，落在 $TMPDIR 执行）：
#   bash $TMPDIR/uninstall.sh -n           # 预演：只列要删什么，一个字节都不动（先跑这个）
#   bash $TMPDIR/uninstall.sh              # 交互确认后，卸掉 termux_dsh 这一层（服务+工具+面板）
#   bash $TMPDIR/uninstall.sh --dsh        # 连 dsh npm 包一起卸（14 处补丁都在它的 node_modules 里）
#   bash $TMPDIR/uninstall.sh --data       # 连 ~/.dsh 用户数据一起删（会话/profile/密钥，删了就回不来）
#   bash $TMPDIR/uninstall.sh --staging    # 连 ~/dsh-termux 工作目录一起删（含 backups/ 时间戳备份史）
#   bash $TMPDIR/uninstall.sh -y --all     # 全拆，不问（脚本/自动化）
#
# 卸什么（= README「目录结构」表里写明的全部设备落点，多一个不删，少一个不落）：
#   1) runit 服务 dsh-web / dsh-lan / dsh-ctl
#      sv down 停服务 → rm -rf $SVDIR/<服务>（runsvdir 最多 5 秒会自己摘掉 runsv 进程）
#      → rm -rf $PREFIX/var/log/sv/<服务>（svlogd 的日志落点，严格按服务名区分，
#      绝不用通配 —— 同目录下还有 cloudflared / sshd / mysite 等别人的日志）
#   2) $PREFIX/bin/ 里 8 个自写工具：dsh-ctl-gateway / dsh-set-provider / dsh-set-key /
#      dsh-web-url / dsh-patch-lan-settings / dsh-lan-ip / dsh-lan-gateway /
#      verify-hot-reload.sh。精确名单，不用 dsh* 通配 —— $PREFIX/bin/dsh 是 npm 装的
#      符号链接（→ ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js），动它就是动 npm 的账。
#   3) $PREFIX/share/dsh-ctl/（panel.html / patches.py / build-flock.sh）
#
# 默认保留（和升级链一条线：可以失败回滚，但用户数据不丢）：
#   * ~/.dsh                 会话/profile/接口与密钥（accounts.json、sites.json、sessions/）
#   * ~/.dsh-termux-backup   补丁器下刀前备份的原始文件
#   * ~/dsh-termux           设备侧工作目录 + backups/ 时间戳备份史
#   * dsh npm 包本体          要 --dsh 才删。补丁、koffi、flock 原生模块全在包里，
#                            日后想再用：npm i -g @deepseek-ai/dsh → patches.py → build-flock.sh
#
# 现在控制台里有「卸载」按钮了（网关 apiUninstall）：
#   网关收到请求后把本脚本复制到 TMPDIR 再 detached 跑 —— 网关自己就是被删的
#   对象，在 HTTP 请求里等它必然断连。输出写日志（$TMPDIR/dsh-uninstall.log），
#   网关被杀前能推多少推多少；面板按「连接断了 = 网关正在被卸载」处理，180 秒
#   后放弃轮询。手动执行本脚本走同一条路、同样的参数（-y --dsh / -y --all）。
#   detached 子进程 + 日志文件让破坏性操作既能在控制台点、也能失败可查。
#
# 幂等：删过的再跑一遍是 no-op；全都不在时报「没有可卸载的东西」退出 0。
# PREFIX/SVDIR/HOME 允许环境变量覆盖（同 install-web-service.sh 的约定）：
#   一是非交互 SSH 里 SVDIR 未必导出（runit 的 sv 命令靠它找服务目录）；
#   二是能在假树上把破坏性路径真跑一遍（tests/test-uninstall.sh 就这么干的）。

set -u

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SVDIR="${SVDIR:-$PREFIX/var/service}"
LOGDIR="${LOGDIR:-$PREFIX/var/log}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

SERVICES="dsh-web dsh-lan dsh-ctl"
TOOLS="dsh-ctl-gateway dsh-set-provider dsh-set-key dsh-web-url dsh-patch-lan-settings dsh-lan-ip dsh-lan-gateway verify-hot-reload.sh"

SHARE_DIR="$PREFIX/share/dsh-ctl"
DSH_PKG_DIR="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
DSH_HOME_DIR="$HOME_DIR/.dsh"
PATCH_BACKUP_DIR="$HOME_DIR/.dsh-termux-backup"
STAGING_DIR="$HOME_DIR/dsh-termux"

DRY=0
YES=0
RM_DSH=0
RM_DATA=0
RM_STAGING=0

say() { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    --dsh) RM_DSH=1 ;;
    --data) RM_DATA=1 ;;
    --staging) RM_STAGING=1 ;;
    --all) RM_DSH=1; RM_DATA=1; RM_STAGING=1 ;;
    -h|--help) usage ;;
    *) echo "不认识的参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 路径安全
# 每一刀都先校验：非空、在 PREFIX 或 HOME 之下。越界直接拒绝并记录。
GUARD_FAIL=0
rm_path() { # rm_path <路径> <标签>
  local p="$1" label="$2"
  [ -n "$p" ] || return 0
  case "$p" in
    "$PREFIX"/*) ;;
    "$HOME_DIR"/*) ;;
    *)
      echo "  ✗ 拒绝删除越界路径（$label）：$p" >&2
      GUARD_FAIL=1
      return 1
      ;;
  esac
 if [ "$DRY" = 1 ]; then
   printf '  \033[1;33m将删\033[0m %-10s %s\n' "$label" "$p"
   return 0
 fi
 if rm -rf -- "$p" 2>/dev/null; then
    printf '  ✓ 已删 %-10s %s\n' "$label" "$p"
 else
   printf '  ✗ 删不掉 %s：%s\n' "$label" "$p"
 fi
}

# ---------------------------------------------------------------- 盘点
say "盘点要删什么（PREFIX=${PREFIX}）"
TOTAL=0

SVC_FOUND=""
for svc in $SERVICES; do
  if [ -d "$SVDIR/$svc" ]; then SVC_FOUND="$SVC_FOUND $svc"; fi
done
[ -n "$SVC_FOUND" ] && { echo "  服务：$SVC_FOUND"; TOTAL=$((TOTAL + $(echo $SVC_FOUND | wc -w))); }

TOOL_FOUND=""
for t in $TOOLS; do
  if [ -e "$PREFIX/bin/$t" ]; then TOOL_FOUND="$TOOL_FOUND $t"; fi
done
[ -n "$TOOL_FOUND" ] && { echo "  工具：$TOOL_FOUND"; TOTAL=$((TOTAL + $(echo $TOOL_FOUND | wc -w))); }

[ -d "$SHARE_DIR" ] && { echo "  控制台资源：$SHARE_DIR"; TOTAL=$((TOTAL + 1)); }

if [ "$RM_DSH" = 1 ]; then
  if [ -d "$DSH_PKG_DIR" ]; then
    echo "  dsh 包（--dsh）：$DSH_PKG_DIR"
    TOTAL=$((TOTAL + 1))
    # 要删包就得有 npm；先验后删，别删到一半才发现没法删
    if [ ! -x "$PREFIX/bin/npm" ] && ! command -v npm >/dev/null 2>&1; then
      echo "✗ 选了 --dsh 但 npm 不在，没法卸包 —— 一个字节都不动，自己看着办。" >&2
      exit 2
    fi
  else
    echo "  dsh 包（--dsh）：本来就不在，跳过"
  fi
fi

if [ "$RM_DATA" = 1 ]; then
  [ -d "$DSH_HOME_DIR" ] && { echo "  用户数据（--data）：$DSH_HOME_DIR"; TOTAL=$((TOTAL + 1)); }
  [ -d "$PATCH_BACKUP_DIR" ] && { echo "  补丁备份（--data）：$PATCH_BACKUP_DIR"; TOTAL=$((TOTAL + 1)); }
fi

if [ "$RM_STAGING" = 1 ] && [ -d "$STAGING_DIR" ]; then
  echo "  工作目录（--staging）：$STAGING_DIR"
  TOTAL=$((TOTAL + 1))
fi

if [ "$TOTAL" = 0 ]; then
  say "没有可卸载的东西"
  echo "  服务 / 工具 / 控制台资源都不在 —— 已经是干净的了。"
  exit 0
fi

say "默认保留"
echo "  ~/.dsh                 用户数据（--data 才删）"
echo "  ~/.dsh-termux-backup   补丁原始备份（--data 才删）"
echo "  ~/dsh-termux           工作目录+备份史（--staging 才删）"
echo "  dsh npm 包             （--dsh 才删）"

# ---------------------------------------------------------------- 确认
if [ "$DRY" != 1 ] && [ "$YES" != 1 ]; then
  echo
  printf '\033[1;31m即将删除上面列出的 %s 项。\033[0m 输入 yes 确认：' "$TOTAL"
  read -r ANSWER
  case "$ANSWER" in
    yes|YES) ;;
    *) echo "已取消（要直说 yes，防手抖）"; exit 1 ;;
  esac
fi

# ---------------------------------------------------------------- 动手
say "卸载（$([ "$DRY" = 1 ] && echo 预演 || echo 实删)）"

for svc in $SVC_FOUND; do
  if [ "$DRY" != 1 ] && [ -x "$PREFIX/bin/sv" ]; then
    # sv down 之后 runsv 还在（它只是不再拉起服务）；目录一删，runsvdir 5 秒内摘掉它
    SVDIR="$SVDIR" "$PREFIX/bin/sv" down "$svc" 2>/dev/null || true
  fi
  rm_path "$SVDIR/$svc" "服务"
  rm_path "$LOGDIR/sv/$svc" "日志"
done

for t in $TOOL_FOUND; do
  rm_path "$PREFIX/bin/$t" "工具"
done

rm_path "$SHARE_DIR" "面板资源"

if [ "$RM_DSH" = 1 ] && [ -d "$DSH_PKG_DIR" ]; then
  if [ "$DRY" = 1 ]; then
    rm_path "$DSH_PKG_DIR" "dsh 包"
  else
    echo "  npm uninstall -g @deepseek-ai/dsh …"
    if "$PREFIX/bin/npm" uninstall -g @deepseek-ai/dsh 2>&1 | sed 's/^/    /'; then
      echo "  ✓ npm 卸载命令返回 0"
    else
      echo "  ✗ npm uninstall 失败 —— 包目录可能仍在，自己检查 $DSH_PKG_DIR"
    fi
  fi
fi

if [ "$RM_DATA" = 1 ]; then
  rm_path "$DSH_HOME_DIR" "用户数据"
  rm_path "$PATCH_BACKUP_DIR" "补丁备份"
fi

if [ "$RM_STAGING" = 1 ]; then
  rm_path "$STAGING_DIR" "工作目录"
fi

[ "$GUARD_FAIL" = 1 ] && { echo "✗ 有越界路径被拒绝（上面有标），没有删它们。" >&2; exit 3; }

# ---------------------------------------------------------------- 复核
if [ "$DRY" != 1 ]; then
  say "复核"
  RESIDUAL=0
  for svc in $SVC_FOUND; do
    # runsv 可能还短暂占着目录；给它 5 秒，再扫一次
    if [ -d "$SVDIR/$svc" ]; then
      sleep 5
      rm -rf -- "$SVDIR/$svc" 2>/dev/null || true
      rm -rf -- "$LOGDIR/sv/$svc" 2>/dev/null || true
    fi
    for p in "$SVDIR/$svc" "$LOGDIR/sv/$svc"; do
      if [ -e "$p" ]; then echo "  ✗ 残留：$p（runsv 可能还占着，几秒后 runsvdir 会摘掉）"; RESIDUAL=1
      else printf '  ✓ 干净 %s\n' "$p"; fi
    done
  done
  for t in $TOOL_FOUND; do
    if [ -e "$PREFIX/bin/$t" ]; then echo "  ✗ 残留工具：$t"; RESIDUAL=1
    else printf '  ✓ 干净 %s\n' "$PREFIX/bin/$t"; fi
  done
  if [ -d "$SHARE_DIR" ]; then echo "  ✗ 残留：$SHARE_DIR"; RESIDUAL=1
  else printf '  ✓ 干净 %s\n' "$SHARE_DIR"; fi
  if [ "$RM_DSH" = 1 ] && [ -d "$DSH_PKG_DIR" ]; then echo "  ✗ 残留：$DSH_PKG_DIR"; RESIDUAL=1; fi
  if [ "$RM_DATA" = 1 ]; then
    [ -d "$DSH_HOME_DIR" ] && { echo "  ✗ 残留：$DSH_HOME_DIR"; RESIDUAL=1; }
    [ -d "$PATCH_BACKUP_DIR" ] && { echo "  ✗ 残留：$PATCH_BACKUP_DIR"; RESIDUAL=1; }
  fi
  if [ "$RM_STAGING" = 1 ] && [ -d "$STAGING_DIR" ]; then echo "  ✗ 残留：$STAGING_DIR"; RESIDUAL=1; fi

  if [ "$RESIDUAL" = 1 ]; then
    echo
    echo "✗ 有残留 —— 见上面 ✗ 行。服务目录被 runsv 占住是正常的，几秒后自动消失；"
    echo "  其它残留请手动处理。"
    exit 3
  fi
  echo
  echo "✓ 卸载完成。保留下的东西仍在原位（~/.dsh 等），想恢复 dsh："
  echo "    npm i -g @deepseek-ai/dsh && python3 share/dsh-ctl/patches.py && bash share/dsh-ctl/build-flock.sh"
fi
exit 0
