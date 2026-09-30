#!/data/data/com.termux/files/usr/bin/bash
# install-gateway.sh —— 网关优先（gateway-first）的 dsh Termux 方案入口。
# 幂等，可重复执行。dsh 本体**不**在这里装 —— 装完网关后，在浏览器控制台里贴
# 引导令牌，由控制台走 install / repair / upgrade / uninstall（全程网页看进度）。
#
# 做五件事：
#   1. 落网关全套：bin/ 下 9 个工具 + share/dsh-ctl/ 下控制台与生命周期脚本
#      （patches.py、build-flock.sh、uninstall.sh、install-web-service.sh）
#   2. 建 / 复位 runit 服务 dsh-ctl：<lan-ip>:8030 -> 127.0.0.1:3080
#   3. 引导令牌：沿用现有的，或缺了就生成 32 位（600 权限，只随安装器打印一次）
#   4. 启动 dsh-ctl，等出 run:
#   5. 用令牌验证：拿得到面板、API 放行、错令牌 401、非白名单接口 403
#
# 为什么 dsh 不在这里装：
#   dsh 是 300MB 级的 npm 包 + koffi/flock 现编，耗时长且要看好进度。网页控制台
#   能给实时日志和分步退出码，SSH 里干等一个 npm install 体验最差。所以安装器
#   只把「入口」装好 —— 哪怕 dsh 还没有，8030 上也已经有一个能点的地方。
set -u

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export SVDIR="${SVDIR:-$PREFIX/var/service}"
export LANG="en_US.UTF-8"
BAK="$HOME/dsh-termux/backups"
GW_PORT=8030

step() { printf '\n==================================================================\n%s\n==================================================================\n' "$1"; }
put() { base64 -d >"$1"; chmod "$2" "$1"; }

command -v node >/dev/null 2>&1 || { echo "缺 node：pkg install nodejs，装完重跑本脚本。"; exit 1; }
command -v sv >/dev/null 2>&1   || { echo "缺 sv：pkg install termux-services，装完重开 Termux（让 runsvdir 起来）后重跑本脚本。"; exit 1; }
command -v curl >/dev/null 2>&1 || echo "  ! 没 curl，第 5 步验证会跳过：pkg install curl"
command -v python3 >/dev/null 2>&1 || echo "  ! 没 python3 —— 网页装 dsh 时补丁器（patches.py）会被卡住：pkg install python"

mkdir -p "$BAK" "$TMPDIR" "$PREFIX/share/dsh-ctl"

step "0. 现状与备份"
TS=$(date +%Y%m%d%H%M%S)
ls -la "$SVDIR" 2>/dev/null | sed 's/^/  /'
for f in dsh-ctl-gateway dsh-web-url dsh-set-provider dsh-set-key dsh-lan-gateway dsh-lan-ip dsh-patch-lan-settings verify-hot-reload.sh; do
  if [ -f "$PREFIX/bin/$f" ]; then
    cp -a "$PREFIX/bin/$f" "$BAK/$f.$TS" && echo "  bin/$f -> $BAK/$f.$TS"
  fi
done
[ -f "$PREFIX/share/dsh-ctl/panel.html" ] && cp -a "$PREFIX/share/dsh-ctl/panel.html" "$BAK/panel.html.$TS" && echo "  panel.html -> $BAK/panel.html.$TS"
for f in sites.json accounts.json; do
  [ -f "$HOME/.dsh/$f" ] && cp -a "$HOME/.dsh/$f" "$BAK/$f.$TS" && echo "  ~/.dsh/$f -> $BAK/$f.$TS"
done
for p in web headless; do
  [ -f "$HOME/.dsh/profiles/$p/cordis.patch.yml" ] && cp -a "$HOME/.dsh/profiles/$p/cordis.patch.yml" "$BAK/cordis.patch.$p.$TS" && echo "  profiles/$p/cordis.patch.yml -> $BAK/"
done
if [ -f "$PREFIX/lib/node_modules/@deepseek-ai/dsh/package.json" ]; then
  echo "  dsh 已装（$("$PREFIX/bin/dsh" --version 2>/dev/null || echo 版本未知)）—— 网关原地更新，不动 dsh"
else
  echo "  dsh 未装 —— 稍后在控制台里贴引导令牌继续安装"
fi

step "1. 落网关全套"
put "$PREFIX/bin/dsh-ctl-gateway" 755 <<'B64_GW'
##PAYLOAD:dsh-ctl-gateway##
B64_GW
put "$PREFIX/share/dsh-ctl/panel.html" 644 <<'B64_PANEL'
##PAYLOAD:dsh-ctl-panel##
B64_PANEL
put "$PREFIX/bin/dsh-web-url" 755 <<'B64_WU'
##PAYLOAD:dsh-web-url##
B64_WU
put "$PREFIX/bin/dsh-patch-lan-settings" 755 <<'B64_PL'
##PAYLOAD:patch-lan-settings##
B64_PL
put "$PREFIX/bin/dsh-set-provider" 755 <<'B64_SP'
##PAYLOAD:dsh-set-provider##
B64_SP
put "$PREFIX/bin/dsh-set-key" 755 <<'B64_SK'
##PAYLOAD:dsh-set-key##
B64_SK
put "$PREFIX/bin/dsh-lan-gateway" 755 <<'B64_LG'
##PAYLOAD:dsh-lan-gateway##
B64_LG
put "$PREFIX/bin/dsh-lan-ip" 755 <<'B64_LI'
##PAYLOAD:dsh-lan-ip##
B64_LI
put "$PREFIX/bin/verify-hot-reload.sh" 755 <<'B64_VH'
##PAYLOAD:verify-hot-reload##
B64_VH
# 生命周期四件：网页装 / 修 / 升 / 卸 dsh 全靠它们，跟面板同级放在 share/dsh-ctl/。
put "$PREFIX/share/dsh-ctl/patches.py" 644 <<'B6_P'
##PAYLOAD:patches-py##
B6_P
put "$PREFIX/share/dsh-ctl/build-flock.sh" 755 <<'B6_F'
##PAYLOAD:build-flock##
B6_F
put "$PREFIX/share/dsh-ctl/uninstall.sh" 755 <<'B6_U'
##PAYLOAD:uninstall-sh##
B6_U
put "$PREFIX/share/dsh-ctl/install-web-service.sh" 755 <<'B6_I'
##PAYLOAD:install-web-service##
B6_I

echo "  -- 自检 --"
node --check "$PREFIX/bin/dsh-ctl-gateway" && echo "    dsh-ctl-gateway          OK"
sh   -n "$PREFIX/bin/dsh-web-url" && echo "    dsh-web-url              OK"
bash -n "$PREFIX/bin/dsh-patch-lan-settings" && echo "    dsh-patch-lan-settings   OK"
bash -n "$PREFIX/bin/dsh-set-provider" && echo "    dsh-set-provider         OK"
bash -n "$PREFIX/bin/dsh-set-key" && echo "    dsh-set-key              OK"
node --check "$PREFIX/bin/dsh-lan-gateway" && echo "    dsh-lan-gateway          OK"
sh   -n "$PREFIX/bin/dsh-lan-ip" && echo "    dsh-lan-ip               OK"
bash -n "$PREFIX/bin/verify-hot-reload.sh" && echo "    verify-hot-reload.sh     OK"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' \
  "$PREFIX/share/dsh-ctl/patches.py" && echo "    patches.py               OK（语法）"
bash -n "$PREFIX/share/dsh-ctl/build-flock.sh" && echo "    build-flock.sh           OK"
bash -n "$PREFIX/share/dsh-ctl/uninstall.sh" && echo "    uninstall.sh             OK"
bash -n "$PREFIX/share/dsh-ctl/install-web-service.sh" && echo "    install-web-service.sh   OK"
PANEL="$PREFIX/share/dsh-ctl/panel.html"
echo "    控制台页面 $(wc -c <"$PANEL") 字节"
printf '    面板含安装向导(#wizard)    %s\n' "$(grep -c 'id="wizard"' "$PANEL")"
printf '    面板含任务弹窗(#jmodal)    %s\n' "$(grep -c 'id="jmodal"' "$PANEL")"
printf '    面板含轮询(pollJob)        %s\n' "$(grep -c 'function pollJob' "$PANEL")"
printf '    面板含引导令牌处理(bsToken) %s\n' "$(grep -c 'function bsToken' "$PANEL")"

step "2. dsh-ctl 服务"
HAD_SVC=0
[ -d "$SVDIR/dsh-ctl" ] && HAD_SVC=1
mkdir -p "$SVDIR/dsh-ctl/log"
put "$SVDIR/dsh-ctl/run" 755 <<'B64_RUN'
##PAYLOAD:dsh-ctl-run##
B64_RUN
cat >"$SVDIR/dsh-ctl/log/run" <<'LOGEOF'
#!/data/data/com.termux/files/usr/bin/sh
D="${LOGDIR:-/data/data/com.termux/files/usr/var/log}"
sv=${PWD%/*}; service=${sv##*/}
mkdir -p "$D/sv/$service"
exec svlogd -tt "$D/sv/$service"
LOGEOF
chmod 755 "$SVDIR/dsh-ctl/log/run"
rm -f "$SVDIR/dsh-ctl/down"
[ "$HAD_SVC" = 1 ] && echo "  服务目录已存在（复位 run 脚本）" || echo "  新建服务目录"
ls -la "$SVDIR/dsh-ctl" | sed 's/^/  /'
command -v sv-enable >/dev/null 2>&1 && { sv-enable dsh-ctl >/dev/null 2>&1 && echo "  sv-enable dsh-ctl OK"; }

step "3. 引导令牌"
# 16~64 位 urlsafe 才会被网关认；格式不对就跟没有一样，重新生成。
TOK=""
if [ -f "$PREFIX/share/dsh-ctl/.bootstrap-token" ]; then
  TOK=$(tr -d ' \n\r' <"$PREFIX/share/dsh-ctl/.bootstrap-token" 2>/dev/null || true)
fi
if [ -n "$TOK" ] && [ "${#TOK}" -ge 16 ] && [ "${#TOK}" -le 64 ] \
   && printf '%s' "$TOK" | grep -qE '^[A-Za-z0-9_-]+$'; then
  chmod 600 "$PREFIX/share/dsh-ctl/.bootstrap-token"
  echo "  沿用现有引导令牌（chmod 600）"
else
  TOK=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)
  umask 077
  printf '%s' "$TOK" >"$PREFIX/share/dsh-ctl/.bootstrap-token"
  umask 022
  chmod 600 "$PREFIX/share/dsh-ctl/.bootstrap-token"
  echo "  生成新令牌（32 位，600）"
fi
echo "  令牌只在安装结束时打印一次；dsh 装好并被登录一次后自动作废。"

step "4. 启动 dsh-ctl"
if [ "$HAD_SVC" = 1 ]; then
  sv restart dsh-ctl || echo "  ! sv restart 失败"
else
  sv up dsh-ctl 2>/dev/null || echo "  ! sv up 还没就绪（runsvdir 最多 5 秒认新服务，下面会等）"
fi
UP=0
for i in $(seq 1 25); do
  case "$(sv status dsh-ctl 2>/dev/null | tr -d '\r')" in
    run:*) UP=1; break ;;
  esac
  sleep 1
done
sv status dsh-ctl 2>/dev/null | sed 's/^/  /'
[ "$UP" = 1 ] || { echo "  ✗ dsh-ctl 没起来，看日志：tail -50 $PREFIX/var/log/sv/dsh-ctl/current"; exit 1; }
tail -6 "$PREFIX/var/log/sv/dsh-ctl/current" 2>/dev/null | sed 's/^/  /'

step "5. 验证"
IP=$("$PREFIX/bin/dsh-lan-ip" 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "  ! 取不到局域网 IP（dsh-lan-ip）—— 检查 WiFi 连接；令牌仍有效，IP 有了就能用"
  echo
  echo "=================================================================="
  echo "  网关进程已就绪（局域网 IP 待定）。控制台地址：http://<手机IP>:$GW_PORT/ctl?bootstrap=$TOK"
  echo "=================================================================="
  exit 0
fi
BASE="http://$IP:$GW_PORT"
command -v curl >/dev/null 2>&1 || { echo "  ! 没 curl，跳过验证"; exit 0; }

# 服务刚 restart，给端口 15 秒
for i in $(seq 1 15); do
  code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$BASE/ctl" 2>/dev/null || true)
  [ "$code" != "000" ] && [ -n "$code" ] && break
  sleep 1
done

printf '  /ctl 无令牌           : %s  （期望 200：引导页，贴令牌的表单）\n' \
  "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/ctl")"
printf '  /ctl?bootstrap=<对的> : %s  （期望 200：控制台面板）\n' \
  "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/ctl?bootstrap=$TOK")"
printf '  面板含向导 #wizard    : %s  （期望 ≥1）\n' \
  "$(curl -s -m 8 "$BASE/ctl?bootstrap=$TOK" | grep -c 'id="wizard"')"
printf '  state 带令牌头        : %s  （期望 ok:true）\n' \
  "$(curl -s -m 8 -X POST -H 'content-type: application/json' -H "x-bootstrap-token: $TOK" -d '{}' "$BASE/ctl/api/state" | grep -o '"ok":true' | head -1)"
printf '  state 带错令牌头      : %s  （期望 401）\n' \
  "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H 'x-bootstrap-token: WRONGTOKEN0123456789' -d '{}' "$BASE/ctl/api/state")"
printf '  非白名单接口 save     : %s  （期望 403：引导令牌不能改配置）\n' \
  "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H "x-bootstrap-token: $TOK" -d '{}' "$BASE/ctl/api/save")"
echo
echo "-- 日志尾部 --"
tail -4 "$PREFIX/var/log/sv/dsh-ctl/current" 2>/dev/null | sed 's/^/  /'

echo
echo "======================================================================"
echo "  ✓ 网关已就绪：http://$IP:$GW_PORT/"
echo
echo "  ① 打开（dsh 未装时从这里进，贴令牌或直接用下面带令牌的链接）："
echo "      http://$IP:$GW_PORT/ctl?bootstrap=$TOK"
echo "  ② 在页面上选通道 / 版本 →「开始安装」，进度实时滚；"
echo "  ③ 装完用页面里给出的令牌链接登录 dsh，控制台自动转完整模式。"
echo "======================================================================"
echo "  令牌：$TOK"
echo "  令牌只打印这一次（存在 $PREFIX/share/dsh-ctl/.bootstrap-token，600）。"
echo "  再看一眼：cat $PREFIX/share/dsh-ctl/.bootstrap-token"
echo "  dsh 装好并登录一次后它会自动作废 —— 那时候控制台改用 dsh 自己的 cookie。"
echo "======================================================================"
echo
echo "完成。"
