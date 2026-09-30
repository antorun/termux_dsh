#!/data/data/com.termux/files/usr/bin/bash
# install-gateway.sh —— 网关优先（gateway-first）的 dsh Termux 方案入口。
# 幂等，可重复执行。一键装全套：网关 + 控制台 + dsh 本体（最新版），
# 最后把 dsh 的登录链接直接打到屏幕上。
#
# 做五件事：
#   1. 落网关全套：bin/ 下 9 个工具 + share/dsh-ctl/ 下控制台与生命周期脚本
#      （patches.py、build-flock.sh、uninstall.sh、install-web-service.sh）
#   2. 建 / 复位 runit 服务 dsh-ctl：<lan-ip>:8030 -> 127.0.0.1:3080
#   3. 启动 dsh-ctl，等出 run:
#   4. 验证：打开就是面板、API 无凭据放行、明文密钥不外露、改配置接口 401
#   5. 装 dsh 本体（已装则跳过）：POST 网关 install 接口，终端实时滚进度，
#      装完打印登录链接（http://<lan-ip>:8030/app?token=…）
#
# 控制台是路由器模型：http://<lan-ip>:8030/ 打开就是，不问令牌。
#
# 装哪个版本（环境变量，可选）：
#   DSH_CHANNEL=latest|next|alpha   通道，默认 latest
#   DSH_VERSION=x.y.z               手填版本号，优先于通道；留空 = 通道最新
#   例：DSH_CHANNEL=next bash install-gateway.sh
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
  echo "  dsh 未装 —— 第 6 步会自动装最新版（DSH_CHANNEL / DSH_VERSION 可选）"
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
printf '    面板含更新弹窗(#umodal)    %s\n' "$(grep -c 'id="umodal"' "$PANEL")"
printf '    面板含任务弹窗(#jmodal)    %s\n' "$(grep -c 'id="jmodal"' "$PANEL")"
printf '    面板含轮询(pollJob)        %s\n' "$(grep -c 'function pollJob' "$PANEL")"
printf '    面板无令牌残留(bsToken)    %s\n' "$(grep -c 'function bsToken' "$PANEL")"

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

step "3. 启动 dsh-ctl"
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

step "4. 验证"
IP=$("$PREFIX/bin/dsh-lan-ip" 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "  ! 取不到局域网 IP（dsh-lan-ip）—— WiFi 没连时网关会一直重试绑定，等 30 秒看它出来没："
  for i in $(seq 1 15); do
    sleep 2
    IP=$("$PREFIX/bin/dsh-lan-ip" 2>/dev/null || true)
    [ -n "$IP" ] && break
    printf '    [%2d/15] 还是没有局域网 IP\n' "$i"
  done
fi
if [ -z "$IP" ]; then
  echo "  ✗ 局域网 IP 始终取不到 —— 网关在跑（IP 一有就自动绑上），但第 5 步装不了 dsh。"
  echo "    连上 WiFi / 局域网后重跑本脚本：前 4 步秒过，第 5 步自动把 dsh 装上。"
  echo
  echo "=================================================================="
  echo "  控制台地址（IP 有了把 <手机IP> 换掉）：http://<手机IP>:$GW_PORT/"
  echo "  打开就是控制台，不用输任何令牌。"
  echo "=================================================================="
  exit 0
fi
BASE="http://$IP:$GW_PORT"
HAVE_CURL=0
command -v curl >/dev/null 2>&1 && HAVE_CURL=1

# 没 curl 就不自检了：第 6 步的轮询脚本只用 node，自己有 60 秒重试。
if [ "$HAVE_CURL" = 1 ]; then
  # 服务刚 restart，给端口 15 秒
  for i in $(seq 1 15); do
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$BASE/ctl" 2>/dev/null || true)
    [ "$code" != "000" ] && [ -n "$code" ] && break
    sleep 1
  done

  printf '  /ctl 打开就是面板       : %s  （期望 200：控制台面板，不问令牌）\n' \
    "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/ctl")"
  printf '  面板含更新弹窗 #umodal  : %s  （期望 ≥1）\n' \
    "$(curl -s -m 8 "$BASE/ctl" | grep -c 'id="umodal"')"
  printf '  state 不用任何凭据      : %s  （期望 ok:true）\n' \
    "$(curl -s -m 8 -X POST -H 'content-type: application/json' -d '{}' "$BASE/ctl/api/state" | grep -o '"ok":true' | head -1)"
  printf '  state 凭据只给掩码     : %s  （期望 0：明文 key 不外露）\n' \
    "$(curl -s -m 8 -X POST -H 'content-type: application/json' -d '{}' "$BASE/ctl/api/state" | grep -c '"value":"[^"]*')" || true
  printf '  改配置接口 save 需登录 : %s  （期望 401）\n' \
    "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' "$BASE/ctl/api/save")"
  echo
  echo "-- 日志尾部 --"
  tail -4 "$PREFIX/var/log/sv/dsh-ctl/current" 2>/dev/null | sed 's/^/  /'
else
  echo "  ! 没 curl，自检跳过（pkg install curl 后重跑可看），直接装 dsh。"
fi

step "5. 装 dsh 本体"
DSH_PKG_JSON="$PREFIX/lib/node_modules/@deepseek-ai/dsh/package.json"
DSH_CHANNEL="${DSH_CHANNEL:-latest}"
case "$DSH_CHANNEL" in latest|next|alpha) ;;
  *) echo "  ✗ DSH_CHANNEL 只能是 latest / next / alpha（当前：${DSH_CHANNEL}）"; exit 1 ;;
esac
DSH_VERSION="${DSH_VERSION:-}"
APPURL=""
if [ -f "$DSH_PKG_JSON" ]; then
  echo "  dsh 已装（$("$PREFIX/bin/dsh" --version 2>/dev/null || echo 版本未知)）—— 不动它，升级走控制台「更新」。"
  # 顺手从 state 接口掏登录链接；没 curl 就空着，banner 走回退文案。
  if [ "$HAVE_CURL" = 1 ]; then
    APPURL=$(curl -s -m 8 -X POST -H 'content-type: application/json' -d '{}' \
      "$BASE/ctl/api/state" \
      | grep -o '"dshUrl":"[^"]*"' | head -1 | sed 's/^"dshUrl":"//; s/"$//')
  fi
else
  echo "  走网关 install 接口装 dsh（通道 $DSH_CHANNEL${DSH_VERSION:+，手填版本 $DSH_VERSION}）。npm 要几分钟，输出实时滚："
  cat >"$TMPDIR/dsh-install-poll.js" <<'POLL_EOF'
#!/usr/bin/env node
// 由 install-gateway.sh 第 5 步写进 $TMPDIR：调网关 install 接口装 dsh，
// 轮询 jobstatus 把进度逐行打到终端；装完把登录链接写进结果文件（最后
// 一个参数）。退出码 0 = 装好，1 = 没装成（原因打在最后一行）。
// 只用 require('http')，不指望 node 18 才有的全局 fetch。
'use strict'
const http = require('http')
const fs = require('fs')

const base = process.argv[2] || ''
const channel = process.argv[3] || 'latest'
const version = process.argv[4] || ''
const resultFile = process.argv[5] || ''

const START_DEADLINE_MS = 60000      // 网关刚 restart / 端口没到，给 60 秒
const POLL_MS = 2000
const DEADLINE_MS = 25 * 60 * 1000   // 网关里 npm 自己的超时是 15 分钟，留余量
const ERR_DEADLINE_MS = 30000        // 轮询拉不到现场：30 秒死线（网关重启 / 断网）

const t0 = Date.now()
let shown = 0
let jobSeen = false
let errSince = 0
let retried = false

// BASE 地址不能解析是永久错误，不进重试循环。
try { new URL(base) } catch (e) {
  out('✗ 网关地址不对：' + base)
  process.exit(1)
}

function out(s) { process.stdout.write(s + '\n') }

function post(path, bodyObj, timeoutMs, cb) {
  const body = JSON.stringify(bodyObj)
  let u
  try { u = new URL(base + path) } catch (e) { return cb(new Error('网关地址不对：' + base)) }
  let req
  try {
    req = http.request({
      hostname: u.hostname,
      port: u.port,
      path: u.pathname,
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      },
      timeout: timeoutMs || 30000,
    }, (res) => {
      let b = ''
      res.setEncoding('utf8')
      res.on('data', (d) => { b += d })
      res.on('end', () => {
        let j = null
        try { j = JSON.parse(b) } catch (e) {}
        cb(null, { code: res.statusCode, json: j, raw: b })
      })
    })
  } catch (e) { return cb(e) }
  req.on('error', (e) => cb(e))
  req.on('timeout', () => { req.destroy(); cb(new Error('请求网关超时')) })
  req.end(body)
}

function finish(ok, appUrl, why) {
  try { if (resultFile) fs.writeFileSync(resultFile, ok ? (appUrl || '') : '') } catch (e) {}
  if (ok) {
    out('✓ dsh 装好了' + (appUrl ? '，登录链接：' + appUrl : '（网关没拿到局域网 IP，登录链接见控制台首页）'))
    process.exit(0)
  }
  out('✗ ' + (why || '安装失败'))
  process.exit(1)
}

const want = { channel }
if (version) want.version = version

// 1) 触发安装：端口没起来就重试到 60 秒死线（接口本身要查远端版本，超时也给足 60 秒）。
function startInstall() {
  post('/ctl/api/install', want, 60000, (err, r) => {
    if (err || !r || r.code >= 500) {
      if (Date.now() - t0 < START_DEADLINE_MS) {
        if (!retried) { retried = true; out('⏳ 网关还没应答，重试中（最多 60 秒）……') }
        return setTimeout(startInstall, 2000)
      }
      return finish(false, '', '连不上网关的 install 接口：' +
        (err ? err.message : (r ? 'HTTP ' + r.code : '无响应')))
    }
    if (!r.json) return finish(false, '', 'install 接口返回不是 JSON：' + String(r.raw).slice(0, 200))
    if (!r.json.ok) return finish(false, '', '网关拒绝安装：' + (r.json.out || '（没给原因）'))
    if (!r.json.jobId) return finish(false, '', 'install 接口没返回 jobId')
    poll(r.json.jobId)
  })
}

// 2) 轮询现场：增量打印新行，等到 done / failed。
function poll(jobId) {
  post('/ctl/api/jobstatus', {}, 30000, (err, r) => {
    if (err || !r || !r.json) {
      if (!errSince) errSince = Date.now()
      if (Date.now() - errSince > ERR_DEADLINE_MS) {
        return finish(false, '', '连着 30 秒拉不到任务现场（网关重启 / 断网？）：' +
          (err ? err.message : '看 $PREFIX/var/log/sv/dsh-ctl/current'))
      }
      return setTimeout(() => poll(jobId), POLL_MS)
    }
    errSince = 0
    const job = r.json.job
    if (job) {
      jobSeen = true
      if (job.lines) {
        if (job.lines.length < shown) shown = 0   // 快照截头了（>160 行/2 秒），重打一遍
        for (; shown < job.lines.length; shown++) out('  ' + job.lines[shown])
      }
      const res = job.result || {}
      if (job.status === 'done' && res.ok) return finish(true, res.appUrl || '', '')
      if (job.status === 'failed' || (job.status === 'done' && !res.ok)) {
        return finish(false, '', '任务没跑成：' + (res.out || '（任务没给结果）'))
      }
    } else if (jobSeen) {
      return finish(false, '', '任务找不到了（网关重启过？）。重跑安装脚本可再试。')
    }
    if (Date.now() - t0 > DEADLINE_MS) {
      return finish(false, '', '等了 25 分钟还没完（npm 卡住了？）。重跑安装脚本可再试。')
    }
    setTimeout(() => poll(jobId), POLL_MS)
  })
}

startInstall()
POLL_EOF
  node --check "$TMPDIR/dsh-install-poll.js" \
    || { echo "  ✗ 轮询脚本没过语法检查（$TMPDIR/dsh-install-poll.js）"; exit 1; }
  node "$TMPDIR/dsh-install-poll.js" "$BASE" "$DSH_CHANNEL" "$DSH_VERSION" "$TMPDIR/dsh-install.result"
  if [ "$?" != 0 ]; then
    echo
    echo "======================================================================"
    echo "  ✗ dsh 没装成 —— 网关已经在跑，随时能再试："
    echo "    重跑本脚本（前 4 步秒过）：bash install-gateway.sh"
    echo "    或在控制台手动装：http://$IP:$GW_PORT/ctl"
    echo "    网关日志：tail -50 $PREFIX/var/log/sv/dsh-ctl/current"
    echo "======================================================================"
    exit 1
  fi
  APPURL=$(tr -d '\n\r' <"$TMPDIR/dsh-install.result" 2>/dev/null || true)
fi

echo
echo "======================================================================"
echo "  ✓ 全部就绪：网关 http://$IP:$GW_PORT/  +  dsh 本体"
echo
if [ -n "$APPURL" ]; then
  echo "  ① dsh 登录链接（点开直接进主界面）："
  echo "      $APPURL"
else
  echo "  ① dsh 登录链接：打开下面的控制台，首页就有。"
fi
echo "  ② 控制台（查状态 / 更新 / 卸载，局域网内打开即用）："
echo "      http://$IP:$GW_PORT/"
echo "======================================================================"
echo "  今后只剩两件事："
echo "    更新 dsh → 控制台「更新」（选通道 / 版本，可强制重装）"
echo "    卸载     → bash $PREFIX/share/dsh-ctl/uninstall.sh -y"
echo "              （-n 先预演；--all 连 dsh 包 / 用户数据一起拆）"
echo "  改 dsh 后端配置 / 密钥要先登录 dsh（打开 ① 那个链接）。"
echo "======================================================================"
echo
echo "完成。"
