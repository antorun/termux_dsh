#!/data/data/com.termux/files/usr/bin/bash
# install-lan.sh —— 给 dsh web 加「局域网直连」能力。幂等，可重复执行。
#
# 做三件事：
#   1. 装 dsh-lan-ip（取局域网 IP）与 dsh-lan-gateway（裸 TCP 转发层）
#   2. 新建 runit 服务 dsh-lan：<lan-ip>:3080 -> 127.0.0.1:3080
#   3. 给 dsh-web 的 run 注入 --trusted-host <lan-ip>（让 /api 的 Host/Origin 围栏放行）
set -u

export PREFIX="/data/data/com.termux/files/usr"
export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
export TMPDIR="$PREFIX/tmp"
export SVDIR="$PREFIX/var/service"
export LANG="en_US.UTF-8"
SVD="$SVDIR"
BAK="$HOME/dsh-termux/backups"
mkdir -p "$BAK" "$TMPDIR"

step() { printf '\n==================================================================\n%s\n==================================================================\n' "$1"; }
put() { base64 -d >"$1"; chmod "$2" "$1"; }

step "0. 现状与备份"
ls -la "$SVD" | sed 's/^/  /'
TS=$(date +%Y%m%d%H%M%S)
cp -a "$SVD/dsh-web/run" "$BAK/dsh-web.run.$TS" && echo "  dsh-web/run -> $BAK/dsh-web.run.$TS"
[ -f "$PREFIX/bin/dsh-web-url" ] && cp -a "$PREFIX/bin/dsh-web-url" "$BAK/dsh-web-url.$TS" && echo "  dsh-web-url -> $BAK/dsh-web-url.$TS"
if [ -f "$SVD/dsh-web/run.bak-20260930080736" ]; then
  mv -f "$SVD/dsh-web/run.bak-20260930080736" "$BAK/" && echo "  顺手把服务目录里的旧备份挪到 $BAK/"
fi

step "1. 安装脚本"
put "$PREFIX/bin/dsh-lan-ip" 755 <<'B64_1'
##PAYLOAD:dsh-lan-ip##
B64_1
put "$PREFIX/bin/dsh-lan-gateway" 755 <<'B64_2'
##PAYLOAD:dsh-lan-gateway##
B64_2
put "$PREFIX/bin/dsh-web-url" 755 <<'B64_3'
##PAYLOAD:dsh-web-url##
B64_3
echo "  -- 语法自检 --"
bash -n "$PREFIX/bin/dsh-lan-ip" && echo "    dsh-lan-ip      OK"
node --check "$PREFIX/bin/dsh-lan-gateway" && echo "    dsh-lan-gateway OK"
bash -n "$PREFIX/bin/dsh-web-url" && echo "    dsh-web-url     OK"
echo "  -- 取址自检 --"
"$PREFIX/bin/dsh-lan-ip" | sed 's/^/    lan-ip = /'

step "2. 新建 dsh-lan 服务"
mkdir -p "$SVD/dsh-lan/log"
put "$SVD/dsh-lan/run" 755 <<'B64_4'
##PAYLOAD:dsh-lan-run##
B64_4
cat >"$SVD/dsh-lan/log/run" <<'LOGEOF'
#!/data/data/com.termux/files/usr/bin/sh
D="${LOGDIR:-/data/data/com.termux/files/usr/var/log}"
sv=${PWD%/*}; service=${sv##*/}
mkdir -p "$D/sv/$service"
exec svlogd -tt "$D/sv/$service"
LOGEOF
chmod 755 "$SVD/dsh-lan/log/run"
rm -f "$SVD/dsh-lan/down"
ls -la "$SVD/dsh-lan" | sed 's/^/  /'
command -v sv-enable >/dev/null 2>&1 && { sv-enable dsh-lan >/dev/null 2>&1 && echo "  sv-enable dsh-lan OK"; }

step "3. 给 dsh-web/run 注入 --trusted-host"
python3 - "$SVD/dsh-web/run" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
if 'termux-dsh-lan-trust' in src:
    print('  已带标记，跳过')
    sys.exit(0)
m = re.search(r'^exec .*dsh["\']?\s+web.*$', src, re.M)
if not m:
    print('  ✗ 找不到 "exec ... dsh web ..." 那一行，未改动'); sys.exit(1)
block = '''# termux-dsh-lan-trust: 让局域网的 authority 通过 /api 的 Host/Origin 围栏。
#   dsh 只绑 127.0.0.1（0.0.0.0 被官方显式拒绝），局域网入口由 dsh-lan 的裸 TCP
#   转发层接进来，于是浏览器看到的 authority 是 <lan-ip>:3080。--trusted-host 收
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
set -- --port 3080 --no-open
[ -n "$LANIP" ] && set -- "$@" --trusted-host "$LANIP"
exec "/data/data/com.termux/files/usr/bin/dsh" web "$@"
'''
p.write_text(src[:m.start()] + block + src[m.end():])
print('  已注入（exec 行被替换，原行已备份）')
PY

step "4. 重启服务"
sv restart dsh-web >/dev/null 2>&1 || echo "  ! sv restart dsh-web 失败"
sleep 6
sv down dsh-lan >/dev/null 2>&1 || true
sv up dsh-lan || echo "  ! sv up dsh-lan 失败"
sleep 4

step "5. 验证"
echo "-- 服务状态 --"
sv status dsh-web | sed 's/^/  /'
sv status dsh-lan | sed 's/^/  /'
echo
echo "-- dsh-web 进程实参 --"
for f in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' <"$f" 2>/dev/null)
  case "$c" in *"/bin/dsh web"*) printf '  pid=%s  %s\n' "$(printf '%s' "$f" | cut -d/ -f3)" "$c" ;; esac
done
echo
echo "-- dsh-lan 日志 --"
tail -6 "$PREFIX/var/log/sv/dsh-lan/current" 2>/dev/null | sed 's/^/  /'
echo
echo "-- 可达性 --"
IP=$("$PREFIX/bin/dsh-lan-ip")
TOK=$(grep -aoE 'token=[A-Za-z0-9_-]+' "$PREFIX/var/log/sv/dsh-web/current" 2>/dev/null | tail -1 | cut -d= -f2)
printf '  loopback 无令牌 : %s  （期望 401）\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/)"
printf '  lan(%s) 无令牌 : %s  （期望 401）\n' "$IP" "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:3080/")"
cd "$TMPDIR" || exit 1
rm -f ck.txt
printf '  lan 带令牌      : %s  （期望 303）\n' "$(curl -s -c ck.txt -o /dev/null -w '%{http_code}' "http://$IP:3080/?token=$TOK")"
printf '  lan 带 cookie   : %s  （期望 200）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:3080/")"
printf '  围栏自检 /api/x : %s  （403=被围栏拦；404=围栏放行、只是没这条路由）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:3080/api/x")"
printf '  SPA 首页字节数  : %s\n' "$(curl -s -b ck.txt "http://$IP:3080/" | wc -c)"
rm -f ck.txt
echo
echo "-- 局域网 URL --"
"$PREFIX/bin/dsh-web-url" --lan | sed 's/^/  /'
echo
echo "完成。"
