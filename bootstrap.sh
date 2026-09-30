#!/data/data/com.termux/files/usr/bin/bash
# bootstrap.sh —— Termux 上的一键安装入口。
#
# 用法（在 Termux 里粘贴这一行）：
#   curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash
#
# 指定分支 / tag / commit：
#   curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash -s v0.2
#
# 所有地址 / 清单都不写死，用环境变量覆盖（fork、自建镜像、内网部署直接用）：
#   DSH_REPO=owner/name   仓库（默认 antorun/termux_dsh），模板和 git clone 回退都从它派生
#   DSH_MIRROR=auto       源站模式（默认）：ghfast 透传镜像优先，raw 兜底
#                         其他值：raw（只用原始源）/ jsdelivr / https://…（自己的代理前缀，
#                         后面拼 raw 的完整 URL）
#   DSH_RAW=http://…      整个源站用一个 base URL 覆盖（自建镜像 / 本地调试）
#   DSH_FILES='a
# b'                     拉取清单覆盖（换行分隔；默认那 16 个）
#   DSH_BUILD_ONLY=1      只构建 install-gateway.sh 不执行（调试用）
#   DSH_CHANNEL / DSH_VERSION  传给安装器：装哪个版本的 dsh
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
# 仓库身份：默认本仓库。fork / 私有部署 / 自建镜像整机覆盖都能用 DSH_REPO。
DSH_REPO="${DSH_REPO:-antorun/termux_dsh}"
# 源站模板在下面第 3 步（默认 raw + jsdelivr 回退；DSH_RAW 指定就只用它，
# 用于自建镜像 / 本地调试，如 DSH_RAW=http://127.0.0.1:8123）

WORK="$TMPDIR/dsh-boot-$(date +%s)"
mkdir -p "$WORK" || { echo "✗ 建不了工作目录 $WORK"; exit 1; }

# ────────────────────────────────────────────────────────────────────
# 小工具：输出整齐一点。step() 给每步一个小标题；行内内容统一缩进 4 格。
# ────────────────────────────────────────────────────────────────────
step() { printf '\n== %s ==\n' "$1"; }
line() { printf '    %-22s %s\n' "$1" "$2"; }
say() { printf '    %s\n' "$1"; }

# 长任务放后台跑，前台单行实时刷新（已用秒数 + 日志最后一行）。
# pkg 的输出几百行扔进日志：既不刷屏，又一眼知道它在动、动到哪了。
# 返回值就是那条命令的退出码。
run_bg() {  # run_bg <日志> <说明(≤10字)> <命令…>
  local log="$1" msg="$2"; shift 2
  local pid t0 el last
  "$@" >>"$log" 2>&1 &
  pid=$!
  t0=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    el=$(( $(date +%s) - t0 ))
    last=$(tail -c 300 "$log" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -1 | cut -c1-56)
    printf '\r      %-10s %3ds  %s' "$msg" "$el" "${last:-（等输出）}"
    sleep 2
  done
  printf '\r\033[K'   # 擦掉心跳行（VT100 清行）
  wait "$pid"
}

step "0/4 检查运行环境"
if [ ! -x "$PREFIX/bin/pkg" ]; then
  echo "✗ 这个脚本只能在 Termux 里跑（找不到 $PREFIX/bin/pkg）。"
  echo "  Termux 请从 F-Droid 或 GitHub Releases 装，应用商店里的版本太旧。"
  exit 1
fi
say "Termux 环境 OK（PREFIX=$PREFIX）"

step "1/4 更新软件源 + 装依赖"
# pkg 的输出几百行，只留结果；日志留着排查用（run_bg 心跳行实时滚最后一行）。
if run_bg "$WORK/pkg-update.log" "pkg update" pkg update -y; then
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
  if run_bg "$WORK/pkg-install.log" "装依赖" pkg install -y $ALLMISS; then
    line "pkg install" "ok"
  else
    say "第一次失败，dpkg --configure -a 收拾半成品后重试……"
    run_bg "$WORK/pkg-install.log" "dpkg 收拾" dpkg --configure -a || true
    if run_bg "$WORK/pkg-install.log" "装依赖重试" pkg install -y $ALLMISS; then
      line "pkg install" "ok（重试后成功）"
    elif [ -z "$MISSING" ]; then
      # 缺的只是 cmake/ninja：网关、控制台、低版本 dsh 都不需要它们
      line "pkg install" "核心依赖 ok；cmake/ninja 装不上（不影响装网关，见下）"
      echo "  ! cmake / ninja 没装上 —— 只有 dsh 0.2.0+ 的 koffi 原生编译要它。"
      echo "    网关和控制台照装；之后在控制台装 dsh 时要是卡在 koffi，再补："
      echo "      pkg install -y cmake ninja"
    elif run_bg "$WORK/pkg-install.log" "只装硬依赖" pkg install -y $MISSING; then
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
  # setsid 不是哪都有（git bash 就没有），缺了就直接后台跑
  if command -v setsid >/dev/null 2>&1; then
    setsid runsvdir "$SVDIR" >/dev/null 2>&1 &
  else
    runsvdir "$SVDIR" >/dev/null 2>&1 &
  fi
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
# 下载 URL 带同一时间戳：绕过 CDN 缓存，保证 16 个文件来自同一时刻的快照，
# 不会出现「A 文件已是新版、B 文件还是旧版」的混合状态
TS=$(date +%s)

# 与 install/build-install-gateway.py 的 PAYLOADS 保持一致（新增 payload 时两处同步改；
# 漏了的话构建器会用「缺文件: ...」明确报错，不会静默装成旧的）。
# fork 加了文件可用 DSH_FILES 覆盖（换行分隔的相对路径）。
FILES="${DSH_FILES:-bin/dsh-ctl-gateway
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
install/build-install-gateway.py}"

total=$(printf '%s\n' "$FILES" | grep -c .)

# 源站候选（URL 模板：%R = ref，%F = 文件路径）。
# raw.githubusercontent 在国内网络经常抽风（40 秒超时）；jsdelivr 镜像反过来
# 有缓存滞后。所以：交互式跑就问一次要哪个；管道跑（curl|bash）默认 auto。
# DSH_RAW 指定了就只用它（自建镜像 / 本地调试，不问）。
if [ -n "${DSH_RAW:-}" ]; then
  MIRROR_NAME="自建镜像（DSH_RAW）"
  TEMPLATES=("$DSH_RAW/%R/%F")
else
  if [ -z "${DSH_MIRROR:-}" ]; then
    if [ -t 0 ]; then
      echo "  源站选择（从哪拉源文件）："
      echo "    1) 国内镜像（ghfast 透传优先，raw 兜底）—— 国内网络推荐"
      echo "    2) jsdelivr CDN（稳定，但分支文件有缓存滞后）"
      echo "    3) 原始源（只用 raw.githubusercontent.com）—— 有代理 / 海外"
      printf '    输入 1/2/3，15 秒不选走 1：'
      read -t 15 -n 1 MIRROR_ANS 2>/dev/null
      echo
      case "$MIRROR_ANS" in
        2) DSH_MIRROR=jsdelivr ;;
        3) DSH_MIRROR=raw ;;
        *) DSH_MIRROR=auto ;;
      esac
    else
      DSH_MIRROR=auto
    fi
  fi
  case "$DSH_MIRROR" in
    http*)  # 直接给代理前缀：DSH_MIRROR=https://my.proxy/
      MIRROR_NAME="自建代理（$DSH_MIRROR）"
      TEMPLATES=("$DSH_MIRROR/https://raw.githubusercontent.com/$DSH_REPO/%R/%F"
                 "https://raw.githubusercontent.com/$DSH_REPO/%R/%F")
      ;;
    jsdelivr|cdn)
      MIRROR_NAME="jsdelivr CDN（raw 兜底）"
      TEMPLATES=("https://cdn.jsdelivr.net/gh/$DSH_REPO@%R/%F"
                 "https://raw.githubusercontent.com/$DSH_REPO/%R/%F")
      ;;
    raw|origin|github)
      MIRROR_NAME="原始源（raw.githubusercontent.com）"
      TEMPLATES=("https://raw.githubusercontent.com/$DSH_REPO/%R/%F")
      ;;
    *)  # auto / cn / mirror（默认）：透传镜像优先，无缓存，raw 兜底
      MIRROR_NAME="镜像（ghfast 透传，raw 兜底）"
      TEMPLATES=("https://ghfast.top/https://raw.githubusercontent.com/$DSH_REPO/%R/%F"
                 "https://raw.githubusercontent.com/$DSH_REPO/%R/%F")
      ;;
  esac
fi
line "源站" "$MIRROR_NAME"

# 多个候选时，先并行探速：各拉 1KB，谁先回 200/206 就谁优先（都失败保持原序）。
# 不盲选镜像：raw 通的网络里镜像反而慢个十倍，反之亦然。
if [ "${#TEMPLATES[@]}" -gt 1 ]; then
  f0=$(printf '%s\n' "$FILES" | head -1)
  PDIR="$WORK/probe"; mkdir -p "$PDIR"
  i=0
  for tpl in "${TEMPLATES[@]}"; do
    i=$((i + 1))
    u="${tpl/\%R/$REF}"; u="${u/\%F/$f0}"
    ( curl -s -m 6 -r 0-1023 -o /dev/null -w '%{http_code} %{time_total}' "$u?${TS}" \
        >"$PDIR/$i" 2>/dev/null ) &
  done
  wait
  SORTED=(); REPORT=""
  i=0
  for tpl in "${TEMPLATES[@]}"; do
    i=$((i + 1))
    pt=$(cat "$PDIR/$i" 2>/dev/null)
    code=${pt%% *}; t=${pt##* }
    name="${tpl#*://}"; name="${name%%/*}"
    case "$code" in
      200|206) SORTED+=("$t|$tpl"); REPORT="$REPORT $name $(printf '%.1fs' "$t")" ;;
      *) SORTED+=("99999|$tpl"); REPORT="$REPORT $name ✗" ;;
    esac
  done
  # 按耗时升序（-s stable：同耗时的保持原顺序）
  TEMPLATES=()
  while IFS= read -r line; do TEMPLATES+=("${line#*|}"); done \
    < <(printf '%s\n' "${SORTED[@]}" | sort -t'|' -k1,1g -s)
  say "源站探速：$REPORT → 用 $(printf '%s' "${TEMPLATES[0]}" | sed 's|.*://||; s|/.*||')"
fi

cd "$WORK" || exit 1
ok=0
for tpl in "${TEMPLATES[@]}"; do
  base="${tpl/\%R/$REF}"
  base="${base/\%F/<文件>}"
  urlbase="${tpl/\%R/$REF}"
  say "从 $base 拉"
  fail=0
  got=0
  bytes=0
  n=0
  for f in $FILES; do
    url="${urlbase/\%F/$f}"
    n=$((n + 1))
    if mkdir -p "$(dirname "$f")" && curl -fsSL --retry 2 -m 40 -o "$f" "$url?${TS}"; then
      sz=$(wc -c <"$f" 2>/dev/null || echo 0)
      if [ "$sz" -gt 0 ]; then
        got=$((got + 1)); bytes=$((bytes + sz))
        printf '      [%2d/%d] %-34s %6d KB\n' "$n" "$total" "$f" "$((sz / 1024))"
      else
        printf '      [%2d/%d] %-34s ✗ 空文件\n' "$n" "$total" "$f"
        fail=1
      fi
    else
      printf '      [%2d/%d] %-34s ✗ 拉不到\n' "$n" "$total" "$f"
      say "          $url"
      fail=1
    fi
  done
  if [ "$got" = "$total" ]; then
    line "源文件" "${got}/${total} 个，共 $((bytes / 1024)) KB"
    ok=1
    break
  fi
  # 换下一个源之前清掉残缺的下载物，以免旧文件混进下一次
  find "$WORK" -type f -size 0 -delete 2>/dev/null
  [ "$got" -gt 0 ] && say "这个源只拉到 $got/$total，换下一个源"
done

if [ "$ok" != 1 ]; then
  echo
  echo "✗ 所有源站都没拉齐。检查网络，或指定自建镜像：DSH_RAW=http://… bash。"
  echo "  备选（走 github.com 而不是 raw）："
  echo "    git clone --depth 1 https://github.com/$DSH_REPO.git"
  echo "    cd $(basename "$DSH_REPO") && bash bootstrap.sh"
  exit 1
fi

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
