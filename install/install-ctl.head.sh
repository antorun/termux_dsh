#!/data/data/com.termux/files/usr/bin/bash
# install-ctl.sh —— 给 dsh 加「8030 控制网关（入口 + 接口/密钥控制台）」并修好局域网下的设置页。
# 幂等，可重复执行。
#
# 做四件事：
#   1. 装 dsh-ctl-gateway（反向代理 + 接口/密钥控制台）与控制台页面
#      —— 8030 的 `/` 是网关自己的控制台，dsh 主界面挪到 `/app`
#   2. 新建 runit 服务 dsh-ctl：<lan-ip>:8030 -> 127.0.0.1:3080
#   3. 给客户端 bundle 打 isLoopback 补丁（局域网下「设置 → 模型」才可用）
#   4. 升级 dsh-set-provider（加 --sites-file「接口 + 多密钥」写入）与 dsh-web-url（加 --gw / --app）
set -u

export PREFIX="/data/data/com.termux/files/usr"
export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
export TMPDIR="$PREFIX/tmp"
export SVDIR="$PREFIX/var/service"
export LANG="en_US.UTF-8"
SVD="$SVDIR"
BAK="$HOME/dsh-termux/backups"
mkdir -p "$BAK" "$TMPDIR" "$PREFIX/share/dsh-ctl"

step() { printf '\n==================================================================\n%s\n==================================================================\n' "$1"; }
put() { base64 -d >"$1"; chmod "$2" "$1"; }

step "0. 现状与备份"
ls -la "$SVD" | sed 's/^/  /'
TS=$(date +%Y%m%d%H%M%S)
for f in dsh-web-url dsh-set-provider; do
  if [ -f "$PREFIX/bin/$f" ]; then
    cp -a "$PREFIX/bin/$f" "$BAK/$f.$TS" && echo "  $f -> $BAK/$f.$TS"
  fi
done
if [ -f "$HOME/.dsh/profiles/web/cordis.patch.yml" ]; then
  cp -a "$HOME/.dsh/profiles/web/cordis.patch.yml" "$BAK/cordis.patch.web.$TS"
  cp -a "$HOME/.dsh/profiles/headless/cordis.patch.yml" "$BAK/cordis.patch.headless.$TS" 2>/dev/null
  echo "  两份 cordis.patch.yml -> $BAK/（出问题可直接 cp 回来）"
fi
# 清单是控制台的全部记忆（备注 / 顺序 / 还没配密钥的那几把），换版本前先留一份
for f in sites.json accounts.json; do
  [ -f "$HOME/.dsh/$f" ] && cp -a "$HOME/.dsh/$f" "$BAK/$f.$TS" && echo "  $f -> $BAK/$f.$TS"
done

step "1. 安装文件"
put "$PREFIX/bin/dsh-ctl-gateway" 755 <<'B64_1'
##PAYLOAD:dsh-ctl-gateway##
B64_1
put "$PREFIX/share/dsh-ctl/panel.html" 644 <<'B64_2'
##PAYLOAD:dsh-ctl-panel##
B64_2
put "$PREFIX/bin/dsh-web-url" 755 <<'B64_3'
##PAYLOAD:dsh-web-url##
B64_3
put "$PREFIX/bin/dsh-patch-lan-settings" 755 <<'B64_4'
##PAYLOAD:patch-lan-settings##
B64_4
put "$PREFIX/bin/dsh-set-provider" 755 <<'B64_6'
##PAYLOAD:dsh-set-provider##
B64_6
# 补丁器与 flock 编译脚本：控制台里的「更新 dsh 版本」要用。
# npm install -g 会把 node_modules 里的补丁全冲掉，所以升级流程必须能就近拿到
# patches.py 重打一遍 —— 放在 share/dsh-ctl/ 下（跟面板同级），路径由网关写死。
put "$PREFIX/share/dsh-ctl/patches.py" 644 <<'B64_7'
##PAYLOAD:patches-py##
B64_7
put "$PREFIX/share/dsh-ctl/build-flock.sh" 755 <<'B64_8'
##PAYLOAD:build-flock##
B64_8
echo "  -- 语法自检 --"
node --check "$PREFIX/bin/dsh-ctl-gateway" && echo "    dsh-ctl-gateway        OK"
sh   -n "$PREFIX/bin/dsh-web-url"        && echo "    dsh-web-url            OK"
bash -n "$PREFIX/bin/dsh-patch-lan-settings" && echo "    dsh-patch-lan-settings OK"
bash -n "$PREFIX/bin/dsh-set-provider"   && echo "    dsh-set-provider       OK"
"$PREFIX/bin/dsh-set-provider" --help >/dev/null 2>&1 && echo "    dsh-set-provider --help OK"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' \
  "$PREFIX/share/dsh-ctl/patches.py" && echo "    patches.py             OK（语法）"
bash -n "$PREFIX/share/dsh-ctl/build-flock.sh" && echo "    build-flock.sh         OK"
echo "    控制台页面 $(wc -c <"$PREFIX/share/dsh-ctl/panel.html") 字节"

step "2. 新建 dsh-ctl 服务"
mkdir -p "$SVD/dsh-ctl/log"
put "$SVD/dsh-ctl/run" 755 <<'B64_5'
##PAYLOAD:dsh-ctl-run##
B64_5
cat >"$SVD/dsh-ctl/log/run" <<'LOGEOF'
#!/data/data/com.termux/files/usr/bin/sh
D="${LOGDIR:-/data/data/com.termux/files/usr/var/log}"
sv=${PWD%/*}; service=${sv##*/}
mkdir -p "$D/sv/$service"
exec svlogd -tt "$D/sv/$service"
LOGEOF
chmod 755 "$SVD/dsh-ctl/log/run"
rm -f "$SVD/dsh-ctl/down"
ls -la "$SVD/dsh-ctl" | sed 's/^/  /'
command -v sv-enable >/dev/null 2>&1 && { sv-enable dsh-ctl >/dev/null 2>&1 && echo "  sv-enable dsh-ctl OK"; }

step "3. 客户端 loopback 补丁（局域网下「设置」页的开关）"
"$PREFIX/bin/dsh-patch-lan-settings"

step "4. 重启服务"
sv restart dsh-web >/dev/null 2>&1 || echo "  ! sv restart dsh-web 失败"
sleep 6
sv down dsh-ctl >/dev/null 2>&1 || true
sv up dsh-ctl || echo "  ! sv up dsh-ctl 失败"
sleep 4

step "5. 验证"
echo "-- 服务状态 --"
sv status dsh-web | sed 's/^/  /'
sv status dsh-ctl | sed 's/^/  /'
echo
echo "-- dsh-ctl 日志 --"
tail -8 "$PREFIX/var/log/sv/dsh-ctl/current" 2>/dev/null | sed 's/^/  /'
echo
echo "-- dsh-web 进程实参（应有 --trusted-host <lan-ip>）--"
for f in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' <"$f" 2>/dev/null)
  case "$c" in *"/bin/dsh web"*) printf '  pid=%s  %s\n' "$(printf '%s' "$f" | cut -d/ -f3)" "$c" ;; esac
done

echo
echo "-- 可达性 --"
IP=$("$PREFIX/bin/dsh-lan-ip" 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "  ! 取不到局域网 IP，跳过局域网探测"
else
  TOK=$(grep -aoE 'token=[A-Za-z0-9_-]+' "$PREFIX/var/log/sv/dsh-web/current" 2>/dev/null | tail -1 | cut -d= -f2)
  cd "$TMPDIR" || exit 1
  printf '  8030 未登录 /           : %s  （期望 200，落地页）\n' "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:8030/")"
  printf '  8030 未登录 /app        : %s  （期望 200，落地页）\n' "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:8030/app")"
  printf '  8030 未登录 /ctl        : %s  （期望 401）\n' "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:8030/ctl")"
  printf '  8030 老链接 /?token=    : %s  （期望 302 → /app）\n' "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:8030/?token=$TOK")"
  rm -f ck.txt
  printf '  8030 取令牌 /app?token= : %s  （期望 303）\n' "$(curl -s -c ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/app?token=$TOK")"
  printf '  8030 带 cookie /        : %s  （期望 200，控制台）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/")"
  printf '  8030 带 cookie /app     : %s  （期望 200，dsh 主界面）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/app")"
  printf '  8030 带 cookie /app/    : %s  （期望 302 → /app）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/app/")"
  printf '  8030 带 cookie /ctl     : %s  （期望 200，控制台）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/ctl")"
  printf '  8030 控制台 API         : %s\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' "http://$IP:8030/ctl/api/state")"
  printf '  8030 围栏自检 /api/x    : %s  （403=围栏拦；404=放行）\n' "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/api/x")"
  printf '  真实 WS 升级 /api/remote.mux : %s\n' "$(curl -s -b ck.txt -o /dev/null -D - -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://$IP:8030/api/remote.mux" 2>/dev/null | head -1 | tr -d '\r')"
  echo
  echo "  -- 内容判别（'/' 必须是控制台，'/app' 必须是 dsh 前端）--"
  printf '  /       含「dsh 网关控制台」: %s  （期望 ≥1）\n' "$(curl -s -b ck.txt "http://$IP:8030/" | grep -c 'dsh 网关控制台')"
  H=$(curl -s -b ck.txt "http://$IP:8030/app")
  printf '  /app    含 id="root"       : %s  （期望 1）\n' "$(printf '%s' "$H" | grep -c 'id="root"')"
  printf '  /app    含 ./assets/       : %s  （期望 ≥1，相对引用）\n' "$(printf '%s' "$H" | grep -c '\./assets/')"
  AS=$(printf '%s' "$H" | grep -o 'assets/[A-Za-z0-9._-]*\.js' | head -1)
  printf '  /assets 静态资源 %s : %s  （期望 200）\n' "${AS:-<未取到>}" "$(curl -s -b ck.txt -o /dev/null -w '%{http_code}' "http://$IP:8030/${AS:-__none__}")"

  echo
  echo "  -- 接口 / 密钥控制台 --"
  STJ=$(curl -s -b ck.txt -X POST -H 'content-type: application/json' -d '{}' "http://$IP:8030/ctl/api/state")
  printf '  state.sites 接口数           : %s  （期望 ≥1）\n' "$(printf '%s' "$STJ" | grep -o '"baseURL"' | wc -l | tr -d ' ')"
  printf '  state 里 token 数            : %s  （期望 ≥1）\n' "$(printf '%s' "$STJ" | grep -o '"keyVar"' | wc -l | tr -d ' ')"
  printf '  state 带每条路由 id          : %s  （期望 ≥1）\n' "$(printf '%s' "$STJ" | grep -o '"routeId"' | wc -l | tr -d ' ')"
  printf '  state.active 有 site+token   : %s  （期望 2）\n' "$(printf '%s' "$STJ" | grep -oE '"active":\{"site":"[a-z]|"token":"t[0-9]' | wc -l | tr -d ' ')"
  printf '  state 只给打码密钥           : %s  （期望 ≥1，keyMasked 而非明文）\n' "$(printf '%s' "$STJ" | grep -c 'keyMasked')"
  printf '  state 有固定预设 freellmapi  : %s  （期望 ≥1）\n' "$(printf '%s' "$STJ" | grep -c 'freellmapi')"
  printf '  state 带启停开关 enabled     : %s  （期望 ≥1）\n' "$(printf '%s' "$STJ" | grep -o '"enabled"' | wc -l | tr -d ' ')"
  printf '  state 带密钥脱敏串 keyHint   : %s  （期望 ≥1）\n' "$(printf '%s' "$STJ" | grep -o '"keyHint"' | wc -l | tr -d ' ')"
  PANEL=$(curl -s -b ck.txt "http://$IP:8030/ctl")
  GW=$(cat "$PREFIX/bin/dsh-ctl-gateway" 2>/dev/null)
  printf '  面板标题「接口列表」         : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c '<h2>接口列表</h2>')"
  printf '  标题下已无长段说明文字       : %s  （期望 0：用户嫌太长让删了，别再长回来）\n' "$(printf '%s' "$PANEL" | grep -cE '一行一个<b>接口</b>|不能证明密钥有效|三件事是同一件事')"
  printf '  接口行(.arow)                : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'class="arow')"
  printf '  密钥行(.krow)                : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'class="krow')"
  printf '  接口展开容器(data-adet)      : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'data-adet=')"
  printf '  密钥行无二级展开(kdet/chev)  : %s  （期望 0：data-kdet / data-kchev / OPENK 都该没了）\n' "$(printf '%s' "$PANEL" | grep -cE 'data-kdet=|data-kchev|OPENK')"
  printf '  接口行尾部有「编辑」按钮     : %s  （期望 ≥1：data-aedit）\n' "$(printf '%s' "$PANEL" | grep -c 'data-aedit=')"
  printf '  点「编辑」不误触展开         : %s  （期望 ≥1：事件 stopPropagation）\n' "$(printf '%s' "$PANEL" | grep -c 'stopPropagation()')"
  printf '  接口展开入口 toggleApi       : %s  （期望 ≥2：定义 + 调用）\n' "$(printf '%s' "$PANEL" | grep -c 'toggleApi(')"
  printf '  「＋ 增加密钥」在展开区最下边 : %s  （期望 1：只在接口展开区）\n' "$(printf '%s' "$PANEL" | grep -c 'class="kadd"')"
  printf '  增加密钥按接口加 addKeyTo    : %s  （期望 ≥2）\n' "$(printf '%s' "$PANEL" | grep -c 'addKeyTo(')"
  printf '  列表下部「＋ 新增接口」      : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="btnAddApi"')"
  printf '  新增/编辑接口走弹窗          : %s  （期望 ≥3）\n' "$(printf '%s' "$PANEL" | grep -c 'openApiModal(')"
  printf '  弹窗容器 id="modal"          : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="modal"')"
  printf '  弹窗里有「第一把密钥」组     : %s  （期望 ≥2：id + 开关）\n' "$(printf '%s' "$PANEL" | grep -c 'mFirstKey')"
  printf '  弹窗可编辑接口 updateApi     : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'updateApi')"
  printf '  接口弹窗不再掺密钥(mKeyList) : %s  （期望 0：mKeyList / modalKeysHtml / modalKeyHtml 都该没了）\n' "$(printf '%s' "$PANEL" | grep -cE 'mKeyList|modalKeysHtml|modalKeyHtml')"
  printf '  密钥弹窗容器 id="kmodal"     : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="kmodal"')"
  printf '  密钥弹窗正文容器 id="kBody"  : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="kBody"')"
  printf '  密钥弹窗渲染 keyModalHtml    : %s  （期望 ≥2：定义 + 调用）\n' "$(printf '%s' "$PANEL" | grep -c 'keyModalHtml(')"
  printf '  列表重绘同步密钥弹窗         : %s  （期望 ≥2）\n' "$(printf '%s' "$PANEL" | grep -c 'refreshKeyModal(')"
  printf '  密钥弹窗里能删这把 keyModalDel: %s  （期望 ≥2）\n' "$(printf '%s' "$PANEL" | grep -c 'keyModalDel')"
  printf '  密钥行尾有「编辑」按钮       : %s  （期望 ≥1：data-kedit）\n' "$(printf '%s' "$PANEL" | grep -c 'data-kedit=')"
  printf '  密钥行尾有「删除」按钮       : %s  （期望 ≥1：data-kdel）\n' "$(printf '%s' "$PANEL" | grep -c 'data-kdel=')"
  printf '  接口行尾有「检测」按钮       : %s  （期望 ≥1：data-ahealth）\n' "$(printf '%s' "$PANEL" | grep -c 'data-ahealth=')"
  printf '  接口级检测 healthApi         : %s  （期望 ≥2：定义 + 调用）\n' "$(printf '%s' "$PANEL" | grep -c 'healthApi(')"
  printf '  弹窗里能删接口 modalDelApi   : %s  （期望 ≥2）\n' "$(printf '%s' "$PANEL" | grep -c 'modalDelApi')"
  printf '  弹窗内联红条 id="mErr"       : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="mErr"')"
  printf '  校验失败在弹窗里看得见       : %s  （期望 ≥8：modalFail 定义 + 各处校验调用）\n' "$(printf '%s' "$PANEL" | grep -c 'modalFail(')"
  printf '  弹窗上挂「输入即清红条」监听 : %s  （期望 1）\n' "$(printf '%s' "$PANEL" | grep -c "oninput=\"modalErr('')\"")"
  printf '  弹窗里有健康徽章 data-mhint  : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'data-mhint=')"
  printf '  保存后清明文密钥值 clearNew  : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'clearNewKeys(')"
  printf '  面板有行内启停开关(.sw)      : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'class="sw"')"
  printf '  面板有展开箭头(.chev)        : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'chev')"
  printf '  面板有「健康」列             : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c '健康')"
  printf '  已去掉「全部检测」按钮       : %s  （期望 0：按钮和字样都该没了）\n' "$(printf '%s' "$PANEL" | grep -cE '全部检测|onclick="healthAll\(\)"')"
  printf '  面板含「备注」字段           : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c '备注')"
  printf '  面板有「显示名」字段         : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c '显示名')"
  printf '  旧结构已清(内联表单/接口下拉) : %s  （期望 0：newsite/siteSel/btnAddToken/btnAddSite）\n' "$(printf '%s' "$PANEL" | grep -cE 'id="newsite"|id="siteSel"|id="btnAddToken"|id="btnAddSite"')"
  printf '  旧行式表格类名已清           : %s  （期望 0：trow/tdet/abar）\n' "$(printf '%s' "$PANEL" | grep -cE 'class="trow|class="tdet|\.trow|\.tdet|class="abar"')"
  printf '  旧函数已清(moveTo/toggleOpen): %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cE 'function moveTo\(|toggleOpen\(')"
  printf '  面板已去掉独立的接口表格     : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -c 'id="sites"')"
  printf '  面板已去掉凭据总览卡片       : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -c 'id="creds"')"
  printf '  面板结构改动会立刻落清单     : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'persistManifest')"
  printf '  面板清单/配置共用一份形状    : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'draftPayload')"
  printf '  没有遮蔽函数名的局部变量     : %s  （期望 0，曾在 createSite 里 var key、setTok 里 var el 炸过）\n' "$(printf '%s' "$PANEL" | grep -cE '(var|let|const) (key|api|act|el|enabledTok) *=')"
  printf '  网关有「只写清单」接口       : %s  （期望 ≥1）\n' "$(printf '%s' "$GW" | grep -c 'apiManifest')"
  printf '  网关 manifest 已挂到路由表   : %s  （期望 ≥1）\n' "$(printf '%s' "$GW" | grep -c 'manifest: apiManifest')"
  printf '  面板有「拉取模型」按钮       : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'pullModels')"
  printf '  面板有「同步给本接口其它密钥」: %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'copyModels')"
  printf '  面板没有 token 计数输入框    : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -ciE 'maxTokens|contextWindow|上下文窗口')"
  printf '  面板没有价格相关字段         : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -ciE '价格|pricing|单价|费用|计费')"
  echo
  echo "  -- 术语统一（Token→密钥、凭据→密钥值/环境变量名、识别名→显示名、站点→接口）--"
  printf '  旧词 Token 列表/新增 Token   : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cE 'Token 列表|新增 Token|把 Token')"
  printf '  旧词 凭据*/识别名            : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cE '凭据值|凭据环境变量名|凭据已存|缺凭据|识别名')"
  printf '  旧词 注册路由/当前使用       : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cE '注册路由|未注册|当前使用')"
  printf '  旧词 站点（已改名接口）      : %s  （期望 0，面板 + 网关一起看）\n' "$(printf '%s%s' "$PANEL" "$GW" | grep -c '站点')"
  echo
  echo "  -- 交互（详情默认收起 + 健康探测不再自造 429）--"
  printf '  详情默认收起（无自动展开）   : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -c 'total <= 1')"
  printf '  健康结果 20 秒内复用(RETEST) : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'RETEST_MS')"
  printf '  429 退避重试(HL_MAX_TRY)     : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'HL_MAX_TRY')"
  printf '  全部检测串行（无并发三路）   : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cF 'Promise.all([next(), next(), next()])')"
  printf '  手动「检测」强制真打         : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'false,true)')"
  printf '  刷新不吞未保存的密钥值 prevKey: %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'prevKey\[k\]')"
  printf '  dsh-set-provider 支持接口模式: %s  （期望 ≥1）\n' "$("$PREFIX/bin/dsh-set-provider" --help 2>&1 | grep -c 'sites-file')"
  printf '  配置里已注册的路由数         : %s\n' "$(sed -n '/# >>> dsh-provider/,/# <<< dsh-provider/p' "$HOME/.dsh/profiles/web/cordis.patch.yml" | grep -cE '^      [a-z][a-z0-9-]*:$')"
  echo
  echo "  -- 启用位：同一时间只有一把（面板单开关 + 网关归一化）--"
  printf '  面板写明「同一时间只有一把」 : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c '同一时间只有一把')"
  printf '  启用位唯一入口 onlyEnable    : %s  （期望 ≥2：定义 + 调用点）\n' "$(printf '%s' "$PANEL" | grep -c 'onlyEnable(')"
  printf '  面板已去掉全部启用/全部停用  : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cE 'setAllEnabled|全部启用|全部停用')"
  printf '  面板没有直写 enabled 的地方  : %s  （期望 0）\n' "$(printf '%s' "$PANEL" | grep -cE '\.enabled *= *true')"
  printf '  网关有归一化 normalizeActive : %s  （期望 ≥2）\n' "$(printf '%s' "$GW" | grep -c 'normalizeActive(')"
  echo
  echo "  -- dsh 版本更新（装新版 → 重打补丁 → 重启 → 验证，失败自动回滚）--"
  printf '  面板有版本行 verNow          : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="verNow"')"
  printf '  面板有「检查更新」入口       : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'checkDsh(')"
  printf '  面板有更新弹窗 umodal        : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'id="umodal"')"
  printf '  面板区分升/降（cmpVer）      : %s  （期望 ≥1）\n' "$(printf '%s' "$PANEL" | grep -c 'function cmpVer(')"
  printf '  网关注册了 dshcheck          : %s  （期望 ≥2：定义 + 路由表）\n' "$(printf '%s' "$GW" | grep -c 'apiDshCheck')"
  printf '  网关注册了 dshupgrade        : %s  （期望 ≥2：定义 + 路由表）\n' "$(printf '%s' "$GW" | grep -c 'apiDshUpgrade')"
  printf '  升级失败会回滚               : %s  （期望 ≥2：定义 + 至少一处调用）\n' "$(printf '%s' "$GW" | grep -c 'rollback')"
  printf '  补丁器已落位 patches.py      : %s  （期望 1）\n' "$([ -f "$PREFIX/share/dsh-ctl/patches.py" ] && echo 1 || echo 0)"
  printf '  补丁器能被 python 解析       : %s  （期望 1）\n' "$(python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' "$PREFIX/share/dsh-ctl/patches.py" 2>/dev/null && echo 1 || echo 0)"
  printf '  flock 编译脚本已落位         : %s  （期望 1）\n' "$([ -f "$PREFIX/share/dsh-ctl/build-flock.sh" ] && echo 1 || echo 0)"
  echo
  echo "  -- 健康探测 API（拿 active 那把密钥真打一次它接口上的模型列表）--"
  HP=$(printf '%s' "$STJ" | python3 -c '
import json,sys
st=json.load(sys.stdin)
a=st.get("active") or {}
s=next((x for x in st.get("sites",[]) if x["id"]==a.get("site")), None)
t=next((x for x in (s or {}).get("tokens",[]) if x["id"]==a.get("token")), None)
print(json.dumps({"api":s["api"],"baseUrl":s["baseURL"],"keyVar":t["keyVar"]}, ensure_ascii=False) if s and t else "{}")
' 2>/dev/null)
  # 注意：不要写 -d "${HP:-{}}" —— bash 会把第一个 } 当收尾、再补一个字面 }，
  # 结果 body 多一个括号 → 网关 JSON.parse 失败 → 空 payload → 假的 code:0。
  # （这个坑真踩过：看起来像 429，其实是探测压根没发出去。）
  [ -n "${HP:-}" ] || HP='{}'
  # 只打一次，后面几行都读这个结果 —— 安装器自己连打两遍会把端点打成 429。
  curl -s -m 35 -b ck.txt -X POST -H 'content-type: application/json' -d "$HP" \
       "http://$IP:8030/ctl/api/health" > hpr.json 2>/dev/null
  printf '  /ctl/api/health              : %s  （ok:true=通；429=端点限流，非配置问题）\n' \
    "$(grep -oE '"ok":(true|false)|"code":[0-9]+|"ms":[0-9]+' hpr.json | tr '\n' ' ')"
  printf '  健康探测实际打的地址         : %s\n' \
    "$(sed -e 's/^.*"out":"//' -e 's/".*$//' hpr.json | head -c 140)"
  rm -f hpr.json
  echo
  echo "  -- 只写清单接口（原样回写；归一化收敛后应一个字节都不再动）--"
  ON1=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
n=sum(1 for s in d["sites"] for t in (s.get("tokens") or []) if t.get("enabled"))
a=d.get("active") or {}
print(str(n) + " 把（active=" + str(a.get("site","")) + "-" + str(a.get("token","")) + "）")
' "$HOME/.dsh/sites.json" 2>/dev/null)
  M1=$(md5sum "$HOME/.dsh/sites.json" | cut -d' ' -f1)
  MP=$(printf '%s' "$STJ" | python3 -c '
import json,sys
st=json.load(sys.stdin)
print(json.dumps({"active":st.get("active") or {}, "sites":st.get("sites") or []}, ensure_ascii=False))
' 2>/dev/null)
  [ -n "${MP:-}" ] || MP='{}'
  MR=$(curl -s -b ck.txt -X POST -H 'content-type: application/json' -d "$MP" "http://$IP:8030/ctl/api/manifest" \
        | grep -oE '"ok":(true|false)' | head -1)
  M2=$(md5sum "$HOME/.dsh/sites.json" | cut -d' ' -f1)
  # 再回写一次：归一化如果收敛了，这一次必须一个字节都不动。
  curl -s -b ck.txt -X POST -H 'content-type: application/json' -d "$MP" "http://$IP:8030/ctl/api/manifest" >/dev/null 2>&1
  M3=$(md5sum "$HOME/.dsh/sites.json" | cut -d' ' -f1)
  printf '  回写前清单里启用的把数       : %s  （期望 1 把）\n' "${ON1:-<读不到>}"
  printf '  /ctl/api/manifest 返回       : %s  （期望 ok:true）\n' "${MR:-<无响应>}"
  printf '  第一次回写后 md5             : %s\n' \
    "$([ "$M1" = "$M2" ] && echo '未变（清单本来就是归一态）' || echo '变了 —— 这份清单里本来有多把启用，顺手归一了（预期内）')"
  printf '  再回写一次（幂等）           : %s\n' \
    "$([ "$M2" = "$M3" ] && echo '未变 ✓ 归一化已收敛' || echo "✗ 又变了：$M2 → $M3")"

  echo
  echo "  -- 「同一时间只有一把启用」服务端兜底（故意全标启用，看落盘是否归一；测完还原）--"
  cp -a "$HOME/.dsh/sites.json" "$TMPDIR/sites.prenorm.json"
  MP2=$(printf '%s' "$STJ" | python3 -c '
import json,sys
st=json.load(sys.stdin)
sites=st.get("sites") or []
for s in sites:
    for t in (s.get("tokens") or []):
        t["enabled"]=True
print(json.dumps({"active":st.get("active") or {}, "sites":sites}, ensure_ascii=False))
' 2>/dev/null)
  [ -n "${MP2:-}" ] || MP2='{}'
  curl -s -b ck.txt -X POST -H 'content-type: application/json' -d "$MP2" "http://$IP:8030/ctl/api/manifest" >/dev/null 2>&1
  EN=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
on=[s["id"]+"-"+t["id"] for s in d["sites"] for t in (s.get("tokens") or []) if t.get("enabled")]
a=d.get("active") or {}
print(str(len(on)) + " 把（" + " ".join(on) + "） / active=" + str(a.get("site","")) + "-" + str(a.get("token","")))
' "$HOME/.dsh/sites.json" 2>/dev/null)
  printf '  全标启用后落盘               : %s  （期望 1 把，且与 active 同一把）\n' "${EN:-<读不到>}"
  cp -a "$TMPDIR/sites.prenorm.json" "$HOME/.dsh/sites.json"
  printf '  测后清单已还原               : %s\n' \
    "$([ "$(md5sum "$HOME/.dsh/sites.json" | cut -d' ' -f1)" = "$M2" ] && echo '✓ md5 与归一后一致' || echo '✗ 还原后 md5 不一致')"

  rm -f ck.txt
  echo
  echo "-- 入口地址 --"
  "$PREFIX/bin/dsh-web-url" --all | sed 's/^/  /'
fi
echo
echo "完成。"
