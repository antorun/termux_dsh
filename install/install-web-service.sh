#!/bin/bash
# install-web-service.sh —— 把 dsh web 装成 Termux 的 runit 守护服务
#
# 在设备（Termux）上运行。产物两件：
#   1) $SVDIR/dsh-web/run          服务本体（含凭据注入与局域网放行两块标记）
#   2) $SVDIR/dsh-web/log/run      svlogd 日志
#
# ── 网关优先（gateway-first）──────────────────────────────────────
# 本脚本不再自带 dsh-web-url：它是会变的东西（--gw/--app/--lan/--all 参数
# 随版本长），内联一份旧的在安装器里长期踩「忘了重建」的坑。现在它由
# install-gateway.sh 下发，这里只检查它在不在 —— 不在就是网关没装，直接拒绝。
# 同理 dsh-lan-ip：run 脚本要用它取局域网 IP，也随网关下发。
#
# ── 写这个脚本踩过的坑，改动前务必读 ─────────────────────────────
#
#  key 事实（都在真机实测过，别再试错）：
#    * dsh 出于安全考虑**拒绝** --host 0.0.0.0，只允许 loopback。
#      README.zh.md「不支持绑定所有网络接口」是设计决定，不要绕过。
#      局域网入口由网关（8030）/ dsh-lan 转发层接，不由 dsh 自己开。
#    * 令牌每次启动都变（进程级随机），所以必须有 dsh-web-url 这类取值入口。
#    * runit 的 run 脚本运行在极简环境，PATH/HOME/PREFIX 都要显式给。
#
#  取本机局域网地址只能用「无参 ifconfig + 自己解析」：
#    - Termux 默认没有 iproute2，ip 命令不存在；
#    - getprop dhcp.wlan0.ipaddress 在 Android 16 上返回空；
#    - hostname -I 在 Termux 的 hostname 上不支持；
#    - ifconfig wlan0（带接口名）输出为空，只有无参 ifconfig 才列得出。
#    这一段在 bin/dsh-lan-ip 里（run 脚本直接调它，不在这里重复）。
#
#  heredoc 一律用**引号形式** <<'XXX'：内容逐字落盘，不做生成期展开。
#  非引号 heredoc 是陷阱 —— 注释里只要出现反引号包住的命令名，
#  生成时就会被真的执行并把输出塞进文件（本项目真发生过一次），
#  awk 里的 $1/$2 也会被外层提前吃掉。引号形式下这些都是普通字符。
#  → 代价：写进文件的路径不能靠 $PREFIX 展开，只能在运行时用 ${PREFIX:-…} 取。
#  → 好处：同一份 run 脚本在任何 PREFIX 下都能跑，假树测试也不用改字。
#
#  幂等：重复执行就等于把 run 脚本重写成规范内容（两块标记都在）。
#  install-key-path.sh / install-lan.head.sh 见到标记就跳过自己的注入步，
#  不会再往里二次塞内容。

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
# 网关优先：这两个工具随 install-gateway.sh 下发，缺了说明网关没装
for t in dsh-web-url dsh-lan-ip; do
  if [ ! -x "$PREFIX/bin/$t" ]; then
    echo "✗ 缺 $PREFIX/bin/$t —— 它随网关一起下发。先跑 install-gateway.sh。" >&2
    exit 1
  fi
done

echo "=== 建立服务目录 $SVC ==="
mkdir -p "$SVC/log"

echo "=== 写 run（服务本体：基础环境 + 凭据注入 + 局域网放行）==="
cat > "$SVC/run" <<'RUN'
#!/data/data/com.termux/files/usr/bin/sh
# dsh-web —— DeepSeek Harness 浏览器 UI 守护服务（termux-services / runit）
#
# 为什么端口写死：runit 只在进程退出时重启，端口漂移会让上次打印的
# URL 与本次不一致；固定端口 + dsh-web-url 才自洽。
#
# 为什么只用 loopback：dsh 主动拒绝 --host 0.0.0.0（安全设计）。
# 要从电脑访问就开 SSH 隧道，或走网关 / dsh-lan 转发，不要改这里：
#   ssh -N -L 3080:127.0.0.1:3080 -p 8022 u0_a383@<手机IP>
#
# 令牌每次启动都不同，用 dsh-web-url 取当前值。
# 本文件由 install-web-service.sh 生成，两块标记（credentials / lan-trust）
# 是 install-key-path.sh 与 install-lan.head.sh 的跳过依据，别手动改格式。

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:$PREFIX/bin/applets"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export LANG="en_US.UTF-8"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

# termux-dsh-credentials: 模型凭据的唯一注入点（由 dsh-set-key 维护，缺失则跳过）。
#   dsh 的模型凭据优先级：provider 管理的 .credentials.yaml > 这里是环境变量
#   没有 api-key 记录时走环境变量，所以这一行就是唯一的 key 来源。
ENVFILE="${SVDIR:-$PREFIX/var/service}/dsh-web/environment"
if [ -f "$ENVFILE" ]; then . "$ENVFILE"; fi

cd "$HOME" || exit 1
# termux-dsh-lan-trust: 让局域网的 authority 通过 /api 的 Host/Origin 围栏。
#   dsh 只绑 127.0.0.1（0.0.0.0 被官方显式拒绝），局域网入口由网关 / dsh-lan 的
#   转发层接进来，于是浏览器看到的 authority 是 <lan-ip>:<端口>。--trusted-host 收
#   端口无关的 IP 字面量（匹配任意端口），正好覆盖这个场景。
#   取不到 IP 时不加该参数：服务照常起，只是局域网下 /api 会 403。
LANIP=""
_n=0
while [ "$_n" -lt 15 ]; do
  LANIP="$(dsh-lan-ip 2>/dev/null || true)"
  [ -n "$LANIP" ] && break
  _n=$((_n + 1)); sleep 2
done
if [ -n "$LANIP" ]; then
  echo "dsh-web: --trusted-host $LANIP"
else
  echo "dsh-web: 警告：取不到局域网 IP，未加 --trusted-host（局域网下 /api 会 403）"
fi
set -- --port "${DSH_WEB_PORT:-3080}" --no-open
[ -n "$LANIP" ] && set -- "$@" --trusted-host "$LANIP"
exec "$PREFIX/bin/dsh" web "$@"
RUN
chmod 755 "$SVC/run"
sh -n "$SVC/run" && echo "  run 语法 OK"

echo "=== 写 log/run（svlogd）==="
cat > "$SVC/log/run" <<'LOGRUN'
#!/data/data/com.termux/files/usr/bin/sh
D="${LOGDIR:-/data/data/com.termux/files/usr/var/log}"
sv=${PWD%/*}; service=${sv##*/}
mkdir -p "$D/sv/$service"
exec svlogd -tt "$D/sv/$service"
LOGRUN
chmod 755 "$SVC/log/run"

# down 文件在就清掉：有它 runsv 不会拉服务（先装时绝不该带着）
rm -f "$SVC/down"

echo
echo "=== 装好了 ==="
ls -la "$SVC" "$SVC/log"
echo
echo "下一步：网关里点「继续安装」会自己 sv up；手工起就：  sv up dsh-web"
