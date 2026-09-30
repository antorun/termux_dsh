#!/data/data/com.termux/files/usr/bin/bash
# bootstrap.sh —— Termux 上的一键安装入口。
#
# 用法（在 Termux 里粘贴这一行）：
#   curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash
#
# 指定分支 / tag / commit：
#   curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash -s v0.2
#
# 做四件事：
#   1. pkg update + 装齐依赖（curl / python / nodejs-lts / termux-services /
#      clang / make / cmake / ninja —— dsh 0.2.0+ 的 koffi 原生编译要后面四个）
#   2. runit 守护（runsvdir）没跑就拉起来 —— 本 session 里现装 termux-services
#      时它还没自启，不等它安装器起不了服务
#   3. 从 GitHub raw 拉 16 个源文件 → 当场用 python3 构建 install-gateway.sh
#   4. 执行安装器：落网关 + 控制台面板 + dsh-ctl 服务 → 装 dsh 本体 → 打印地址
#
# 为什么不直接下载现成安装器：install-gateway.sh 是生成物，按项目规矩不入版本库
# （改了 payload 忘重建、产物里长期内联旧版本的亏吃过）。这里拉的是源文件，
# 当场构建，永远和仓库一致。前置依赖只假设 Termux 本身；curl / python 没有
# 的话第 1 步现装。
set -u

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:${PATH}"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export SVDIR="${SVDIR:-$PREFIX/var/service}"
export LOGDIR="${LOGDIR:-$PREFIX/var/log}"

REF="${1:-main}"
# 可覆盖：自建镜像 / 本地调试，如 DSH_RAW=http://127.0.0.1:8123
RAW="${DSH_RAW:-https://raw.githubusercontent.com/antorun/termux_dsh}"

WORK="$TMPDIR/dsh-boot-$(date +%s)"
mkdir -p "$WORK" || { echo "✗ 建不了工作目录 $WORK"; exit 1; }

# ────────────────────────────────────────────────────────────────────
# 小工具：输出整齐一点。step() 给每步一个小标题；行内内容统一缩进 4 格。
# ────────────────────────────────────────────────────────────────────
step() { printf '\n== %s ==\n' "$1"; }
line() { printf '    %-22s %s\n' "$1" "$2"; }
say() { printf '    %s\n' "$1"; }

step "0/4 检查运行环境"
if [ ! -x "$PREFIX/bin/pkg" ]; then
  echo "✗ 这个脚本只能在 Termux 里跑（找不到 $PREFIX/bin/pkg）。"
  echo "  Termux 请从 F-Droid 或 GitHub Releases 装，应用商店里的版本太旧。"
  exit 1
fi
say "Termux 环境 OK（PREFIX=$PREFIX）"

step "1/4 更新软件源 + 装依赖"
# pkg 的输出几百行，只留结果；日志留着排查用。
if pkg update -y >"$WORK/pkg-update.log" 2>&1; then
  line "pkg update" "ok"
else
  line "pkg update" "失败（不影响，源文件还没拉）"
  sed -n '$p' "$WORK/pkg-update.log" 2>/dev/null | sed 's/^/      /'
fi

# 依赖清单：探测命令 → 包名。已有的跳过（重跑脚本秒过），缺的才装。
# 前六个是硬依赖；cmake / ninja 只有 dsh 0.2.0+ 的 koffi 原生编译要 ——
# 装不上不拦着网关，等控制台装 dsh 时再说。
CORE="curl:curl python:python3 node:nodejs-lts sv:termux-services clang:clang make:make"
SOFT="cmake:cmake ninja:ninja"
MISSING=""; SOFTMISS=""
for d in $CORE $SOFT; do
  cmd="${d%%:*}"; pkg="${d#*:}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ver=$("$cmd" --version 2>/dev/null | head -1 | cut -c1-40)
    line "$pkg" "已有 ${cmd}（${ver}）"
  else
    # 软依赖记到另一份：它们能装就装，装不上只警告
    case " $SOFT " in *" $d "*) SOFTMISS="$SOFTMISS $pkg" ;; *) MISSING="$MISSING $pkg" ;; esac
  fi
done

ALLMISS="${MISSING# }${MISSING:+ }${SOFTMISS# }"
if [ -n "$ALLMISS" ]; then
  say "装：$ALLMISS"
  # 失败先自愈：设备上有「上次没配完的包」时，任何 apt 操作都会被 dpkg 拖去
  # 配完它们，配不上就整个事务失败 —— 跟我们要装的包无关（报错里若出现
  # gtk3 / libdecor / sdl2 / shared-mime-info 就是这个）。--configure -a 一把
  # 收拾半成品，再重试一次。
  if pkg install -y $ALLMISS >"$WORK/pkg-install.log" 2>&1; then
    line "pkg install" "ok"
  else
    say "第一次失败，dpkg --configure -a 收拾半成品后重试……"
    dpkg --configure -a >>"$WORK/pkg-install.log" 2>&1 || true
    if pkg install -y $ALLMISS >>"$WORK/pkg-install.log" 2>&1; then
      line "pkg install" "ok（重试后成功）"
    elif [ -z "$MISSING" ]; then
      # 缺的只是 cmake/ninja：网关、控制台、低版本 dsh 都不需要它们
      line "pkg install" "核心依赖 ok；cmake/ninja 装不上（不影响装网关，见下）"
      echo "  ! cmake / ninja 没装上 —— 只有 dsh 0.2.0+ 的 koffi 原生编译要它。"
      echo "    网关和控制台照装；之后在控制台装 dsh 时要是卡在 koffi，再补："
      echo "      pkg install -y cmake ninja"
    elif pkg install -y $MISSING >>"$WORK/pkg-install.log" 2>&1; then
      line "pkg install" "核心依赖 ok；cmake/ninja 装不上（重试已跳过）"
      echo "  ! cmake / ninja 没装上 —— 只有 dsh 0.2.0+ 的 koffi 原生编译要它。"
      echo "    之后在控制台装 dsh 时要是卡在 koffi，再补：pkg install -y cmake ninja"
    else
      echo "✗ 依赖装不上，看日志：tail -30 $WORK/pkg-install.log"
      tail -15 "$WORK/pkg-install.log" 2>/dev/null | sed 's/^/      /'
      echo "  常见根因：设备上有「没配完的包」（报错里若出现 gtk3 / libdecor /"
      echo "  sdl2 / shared-mime-info 就是它，跟我们要装的无关）："
      echo "    pkg remove -y shared-mime-info gtk3 libdecor sdl2 && dpkg --configure -a"
      echo "  然后重跑本命令。"
      exit 1
    fi
  fi
else
  say "依赖齐全，不重复装"
fi

step "2/4 启动 runit 守护（runsvdir）"
# termux-services 的自启在登录 shell 里（/etc/profile.d/start-services.sh）；
# curl|bash 这个 session 里 profile 没跑过，所以得自己确认它在跑。
if pgrep -f "runsvdir $SVDIR" >/dev/null 2>&1; then
  line "runsvdir" "已在运行"
else
  if ! command -v runsvdir >/dev/null 2>&1; then
    echo "✗ 没有 runsvdir —— termux-services 没装上（上一步应该装了，看日志）"
    exit 1
  fi
  say "未运行，后台拉起……"
  setsid runsvdir "$SVDIR" >/dev/null 2>&1 &
  UP=0
  for i in $(seq 1 20); do
    pgrep -f "runsvdir $SVDIR" >/dev/null 2>&1 && { UP=1; break; }
    sleep 1
  done
  if [ "$UP" = 1 ]; then
    line "runsvdir" "ok"
  else
    echo "✗ runsvdir 拉不起来。手动试一次：打开新 Termux 窗口（登录时自启），或执行"
    echo "    setsid runsvdir $SVDIR &"
    exit 1
  fi
fi

step "3/4 拉源文件（ref=${REF}）→ $WORK"
# 下载 URL 带同一时间戳：绕过 raw 的 CDN 缓存，保证 16 个文件来自同一时刻的
# 快照，不会出现「A 文件已是新版、B 文件还是旧版」的混合状态
TS=$(date +%s)

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

cd "$WORK" || exit 1
fail=0
bytes=0
got=0
total=$(printf '%s\n' "$FILES" | grep -c .)
for f in $FILES; do
  if mkdir -p "$(dirname "$f")" && curl -fsSL --retry 2 -m 40 -o "$f" "$RAW/$REF/$f?${TS}"; then
    sz=$(wc -c <"$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 0 ]; then
      got=$((got + 1)); bytes=$((bytes + sz))
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
  echo "✗ 有源文件没拉成。常见原因：到 raw.githubusercontent.com 网络不通，或 ref 写错。"
  echo "  备选（走 github.com 而不是 raw）："
  echo "    git clone --depth 1 https://github.com/antorun/termux_dsh.git"
  echo "    cd termux_dsh && bash bootstrap.sh"
  exit 1
fi
line "源文件" "${got}/${total} 个，共 $((bytes / 1024)) KB"

step "4/4 构建 + 执行安装器"
python3 install/build-install-gateway.py >"$WORK/build.log" 2>&1 \
  || { echo "✗ 构建失败（看上面的「缺文件」提示）"; tail -10 "$WORK/build.log"; exit 1; }
GEN="install/install-gateway.sh"
[ -s "$GEN" ] || { echo "✗ 没生成 $GEN"; exit 1; }
bash -n "$GEN" || { echo "✗ 生成物语法检查没过"; exit 1; }
line "install-gateway.sh" "$(wc -c <"$GEN") 字节，语法自检通过"
say "工作目录 ${WORK}（不看可删；重跑本命令会建新的）"
if [ -n "${DSH_BUILD_ONLY:-}" ]; then
  say "DSH_BUILD_ONLY 已设：只构建不执行。生成物在 $WORK/$GEN"
  exit 0
fi
exec bash "$GEN"
