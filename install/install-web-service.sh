#!/bin/bash
# install-web-service.sh —— 把 dsh web 装成 Termux 的 runit 守护服务
#
# 在设备（Termux）上运行。产物三件：
#   1) $PREFIX/var/service/dsh-web/run        服务本体
#   2) $PREFIX/var/service/dsh-web/log/run    svlogd 日志
#   3) $PREFIX/bin/dsh-web-url                便捷命令：打印当前带令牌 URL
#
# ── 写这个脚本踩过的坑，改动前务必读 ─────────────────────────────
#
#  key 事实（都在真机实测过，别再试错）：
#    * dsh 出于安全考虑**拒绝** --host 0.0.0.0，只允许 loopback。
#      README.zh.md「不支持绑定所有网络接口」是设计决定，不要绕过。
#      要局域网访问只能开 SSH 隧道。
#    * 令牌每次启动都变（进程级随机），所以必须有 dsh-web-url 这类取值入口。
#    * runit 的 run 脚本运行在极简环境，PATH/HOME/PREFIX 都要显式给。
#
#  取本机局域网地址只能用「无参 ifconfig + 自己解析」：
#    - Termux 默认没有 iproute2，ip 命令不存在；
#    - getprop dhcp.wlan0.ipaddress 在 Android 16 上返回空；
#    - hostname -I 在 Termux 的 hostname 上不支持；
#    - ifconfig wlan0（带接口名）输出为空，只有无参 ifconfig 才列得出。
#
#  heredoc 一律用**引号形式** <<'XXX'：内容逐字落盘，不做生成期展开。
#  非引号 heredoc 是陷阱 —— 注释里只要出现反引号包住的命令名，
#  生成时就会被真的执行并把输出塞进文件（本项目真发生过一次），
#  awk 里的 $1/$2 也会被外层提前吃掉。引号形式下这些都是普通字符。
#  → 代价：写进文件的路径不能靠 $PREFIX 展开，只能在运行时用 ${PREFIX:-…} 取。

set -eu

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
SVDIR="${SVDIR:-$PREFIX/var/service}"
SVC="$SVDIR/dsh-web"
PORT="${DSH_WEB_PORT:-3080}"

if [ ! -x "$PREFIX/bin/dsh" ]; then
  echo "✗ 找不到 $PREFIX/bin/dsh —— dsh 没装好？先装再回来。" >&2
  exit 1
fi

echo "=== 建立服务目录 $SVC ==="
mkdir -p "$SVC/log"

echo "=== 写 run（服务本体）==="
# 用带引号的 heredoc 会阻止 $PREFIX 等展开，这里需要展开（生成期已知），
# 所以本段保持非引号，但内容里没有反引号、也没有 awk，不存在踩坑点。
cat > "$SVC/run" <<RUN
#!/data/data/com.termux/files/usr/bin/sh
# dsh-web —— DeepSeek Harness 浏览器 UI 守护服务（termux-services / runit）
#
# 为什么端口写死 $PORT：runit 只在进程退出时重启，端口漂移会让上次打印的
# URL 与本次不一致；固定端口 + dsh-web-url 才自洽。
#
# 为什么只用 loopback：dsh 主动拒绝 --host 0.0.0.0（安全设计）。
# 要从电脑访问就开 SSH 隧道，不要改这里：
#   ssh -N -L $PORT:127.0.0.1:$PORT -p 8022 u0_a383@<手机IP>
#
# 令牌每次启动都不同，用 dsh-web-url 取当前值。

export PREFIX="$PREFIX"
export HOME="$HOME_DIR"
export PATH="$PREFIX/bin:$PREFIX/bin/applets"
export TMPDIR="$PREFIX/tmp"
export LANG="en_US.UTF-8"
export DSH_HOME="$HOME_DIR/.dsh"

cd "$HOME_DIR" || exit 1
exec "$PREFIX/bin/dsh" web --port $PORT --no-open
RUN
chmod 755 "$SVC/run"

echo "=== 写 log/run（svlogd）==="
cat > "$SVC/log/run" <<'LOGRUN'
#!/data/data/com.termux/files/usr/bin/sh
D="${LOGDIR:-/data/data/com.termux/files/usr/var/log}"
sv=${PWD%/*}; service=${sv##*/}
mkdir -p "$D/sv/$service"
exec svlogd -tt "$D/sv/$service"
LOGRUN
chmod 755 "$SVC/log/run"

echo "=== 写便捷命令 $PREFIX/bin/dsh-web-url ==="
cat > "$PREFIX/bin/dsh-web-url" <<'URLSH'
#!/data/data/com.termux/files/usr/bin/sh
# dsh-web-url —— 打印当前 dsh web 的带令牌访问 URL
#
#   dsh-web-url           只打印 URL（Termux 终端里可直接点击打开）
#   dsh-web-url --open    顺带用系统浏览器打开
#   dsh-web-url --tunnel  顺带打印从电脑访问的 SSH 隧道命令
#
# 令牌每次启动都会变，所以永远从日志里取最新，不要缓存。

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LOGDIR="${LOGDIR:-$PREFIX/var/log}"
LOG="$LOGDIR/sv/dsh-web/current"

if [ ! -e "$LOG" ]; then
  echo "✗ 日志不存在：$LOG" >&2
  echo "  服务没启动？试： sv status dsh-web   /   sv up dsh-web" >&2
  exit 1
fi

URL=$(grep -aoE 'http://[^[:space:]]+token=[A-Za-z0-9_-]+' "$LOG" 2>/dev/null | tail -1)

if [ -z "$URL" ]; then
  echo "✗ 日志里还没有带令牌的 URL（服务可能刚重启或启动失败）。" >&2
  echo "  --- 日志尾部 ---" >&2
  tail -25 "$LOG" >&2
  exit 1
fi

echo "$URL"

# 取本机局域网地址。可用手段只剩「无参 ifconfig + 自己按接口块解析」：
#   · Termux 默认没有 iproute2，'ip' 命令不存在；
#   · 'getprop dhcp.wlan0.ipaddress' 在 Android 16 上返回空；
#   · 'hostname -I' 在 Termux 的 hostname 上不支持；
#   · 'ifconfig wlan0'（带接口名）输出为空，只有无参 ifconfig 才列得出。
# 优先用 SSH_CONNECTION（第 3 个字段就是本机地址）；否则解析无参 ifconfig。
lan_ip() {
  if [ -n "${SSH_CONNECTION:-}" ]; then
    set -- $SSH_CONNECTION
    if [ -n "${3:-}" ]; then printf '%s\n' "$3"; return; fi
  fi
  ifconfig 2>/dev/null | awk '
    /^[A-Za-z0-9_.]+:/ { n = $1; sub(/:.*/, "", n) }
    /inet / {
      ip = $2; sub(/^addr:/, "", ip)
      if (n == "wlan0") { print ip; exit }
      if (ip != "127.0.0.1" && n != "vgate0" && fb == "") fb = ip
    }
    END { if (fb != "") print fb }
  ' 2>/dev/null | head -1
}

case "${1:-}" in
  --open)
    termux-open-url "$URL" >/dev/null 2>&1 || echo "(termux-open-url 打开失败，请手动点击上面的链接)" >&2
    ;;
  --tunnel)
    PORT=$(printf '%s' "$URL" | sed -n 's|.*127\.0\.0\.1:\([0-9]*\)/.*|\1|p')
    [ -z "$PORT" ] && PORT=3080
    IP=$(lan_ip)
    [ -z "$IP" ] && IP="<手机IP：跑 ifconfig 看 wlan0 那块的 inet>"
    echo ""
    echo "在电脑上执行（保持这个终端开着）："
    echo "  ssh -N -L $PORT:127.0.0.1:$PORT -p 8022 ${USER:-$(whoami)}@$IP"
    echo ""
    echo "然后把上面 URL 里的 127.0.0.1 原样粘到电脑浏览器（隧道已把它接到手机）。"
    echo "注意：dsh 主动拒绝 --host 0.0.0.0（安全设计），所以只能走隧道，不能直接开局域网端口。"
    ;;
esac

exit 0
URLSH
chmod 755 "$PREFIX/bin/dsh-web-url"

echo
echo "=== 装好了 ==="
ls -la "$SVC" "$SVC/log" "$PREFIX/bin/dsh-web-url"
