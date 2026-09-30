#!@BASH@
# tests/test-gateway.sh —— 在 Mac 上用假树 + 假上游真跑 bin/dsh-ctl-gateway
#
# 网关是整个方案的入口，最怕的是鉴权逻辑和生命周期任务（install/repair/
# uninstall 的 job 契约）回归。这里造一棵假 Termux 树当 $PREFIX：
#
#   tree/bin/{npm,python3,sv,bash,dsh,dsh-web-url,ifconfig}  全是桩脚本：
#     - npm install -g @deepseek-ai/dsh@X.Y.Z → 真建假包目录 + package.json
#     - python3 / bash → 记录调用、退出 0（补丁器 / 卸载脚本本身另有专项测试）
#     - sv status → 永远 "run:"；sv up/restart/down → 只记录
#     - ifconfig → 固定 192.168.3.5，让 lanIp() / appUrl 可断言
#   tree/share/dsh-ctl/ 面板 / patches.py / uninstall.sh / install-web-service.sh
#     用仓库真文件（apiInstall 的存在性检查要它们在场）
#
# 再起一个假 dsh-web（node http，默认 401；模式文件一改就变 404 = 已登录），
# 然后 PREFIX=$TREE HOME=$TREE/home TMPDIR=$WORK/tmp 真跑网关。
#
# 用例：
#   T1 开放模型鉴权（路由器模型，未登录、dsh 未装）：/ctl 直接面板 /
#       state 不用凭据且凭据只给掩码 / save 401 / 白名单
#   T2 安装任务：jobId → 轮询 → done / appUrl / 并发拒绝
#   T3 修复幂等：不重装包（npm 调用数不变）
#   T4 登录后完整权限：state 给明文凭据 / save 放行 / /app 回上游页面
#   T5 卸载：detached 子进程真拆假树；杀掉网关再重启 → job 落盘恢复
#       （PID 还活着就续盯 / 退出码已落就结案）
#   T6 完成态落盘保留：再重启一次 jobstatus 仍在 / log 白名单 / restart 放行
#       （白名单接口不登录也能调 —— 路由器模型）
#
# 跑法：bash tests/test-gateway.sh（从仓库根目录）
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GW="$ROOT/bin/dsh-ctl-gateway"
[ -f "$GW" ] || { echo "找不到 $GW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "缺 node"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "缺 curl"; exit 2; }

PASS=0
FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { # check <名字> <实际> <期望>
  if [ "$2" = "$3" ]; then ok "$1 = $3"
  else bad "$1：实际=$2 期望=$3"; fi
}
has() { # has <名字> <实际串> <期望子串>
  case "$2" in *"$3"*) ok "$1 含「$3」";; *) bad "$1 不含「$3」";; esac
}
nohas() { # nohas <名字> <实际串> <讨厌子串>
  case "$2" in *"$3"*) bad "$1 不该含「$3」";; *) ok "$1 不含「$3」";; esac
}
sec() { printf '\n########## %s ##########\n' "$1"; }

GW_PORT=18079
UP_PORT=18078
BASE="http://127.0.0.1:$GW_PORT"
FAKE_IP='192.168.3.5'
INSTALL_VER='9.9.9'
# 种进 environment 的假密钥：T1 验「未登录只见掩码」、T4 验「登录后见明文」
TEST_KEY='sk-fake-secret-1234567890'

WORK=$(mktemp -d) || exit 2
GW_PID=''
UP_PID=''
cleanup() {
  [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null
  [ -n "$UP_PID" ] && kill "$UP_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# 假上游：模式文件写 'authed' 时 /api/__ctl_probe 回 404（=已登录），/ 回 200；
# 默认（anon）一律 401。网关靠 probe 的状态码判定登录。
cat >"$WORK/upstream.js" <<'UP_EOF'
'use strict'
const http = require('http')
const fs = require('fs')
const CTL = process.argv[2]
function mode() { try { return (fs.readFileSync(CTL, 'utf8') || '').trim() } catch { return '' } }
const s = http.createServer((req, res) => {
  // authed 模式模拟「dsh 在线且这个浏览器登过」：probe 只有带着 cookie 才回 404
  const authed = mode() === 'authed' && !!req.headers.cookie
  if (req.url.indexOf('/api/__ctl_probe') === 0) {
    res.writeHead(authed ? 404 : 401, { 'content-type': 'text/plain' })
    return res.end(authed ? 'no such route' : 'login required')
  }
  if (authed) {
    res.writeHead(200, { 'content-type': 'text/html' })
    return res.end('<html>UPSTREAM-APP-HTML</html>')
  }
  res.writeHead(401, { 'content-type': 'text/plain' })
  res.end('login required')
})
s.listen(Number(process.argv[3]), '127.0.0.1', () => console.log('upstream up'))
UP_EOF

# ------------------------------------------------------------------ 建假树
build_tree() {
  STUB="$WORK/tree"
  rm -rf "$STUB"
  mkdir -p "$STUB/bin" "$STUB/share/dsh-ctl" "$STUB/home/.dsh" \
           "$STUB/var/service" "$STUB/var/log/sv/dsh-web"

  # 面板与生命周期四件套用仓库真文件（apiInstall/apiRepair/apiUninstall 要它们在场）
  cp "$ROOT/share/dsh-ctl/panel.html" "$STUB/share/dsh-ctl/panel.html"
  cp "$ROOT/install/patches.py" "$STUB/share/dsh-ctl/patches.py"
  cp "$ROOT/install/build-flock.sh" "$STUB/share/dsh-ctl/build-flock.sh"
  cp "$ROOT/install/uninstall.sh" "$STUB/share/dsh-ctl/uninstall.sh"
  cp "$ROOT/install/install-web-service.sh" "$STUB/share/dsh-ctl/install-web-service.sh"

  # 桩脚本统一把调用记进树外的 calls 文件，便于断言"谁被调了几次"
  : >"$WORK/calls"

  # 桩的 shebang 写成 @BASH@ 占位符，下面统一替换成本机真 bash 的绝对路径：
  # 不能用 #!@BASH@ —— env 按 PATH 解析，而网关子进程的 PATH 第一项就是
  # 假树 bin（里面有同名 bash 桩），内核 exec 桩 → shebang → env → 又解析到桩，死循环。
  REAL_BASH=$(command -v bash)

  cat >"$STUB/bin/npm" <<'STUB_NPM'
#!@BASH@
STUB=$(cd "$(dirname "$0")/.." && pwd)
echo "npm $*" >>"$STUB/../calls"
if [ "$1" = "install" ]; then
  sleep 3   # 给"并发拒绝"留窗口
  arg="$3"  # 形如 @deepseek-ai/dsh@9.9.9
  ver="${arg##*@}"
  dir="$STUB/lib/node_modules/@deepseek-ai/dsh"
  mkdir -p "$dir" "$STUB/bin"
  printf '{"name":"@deepseek-ai/dsh","version":"%s"}\n' "$ver" >"$dir/package.json"
  exit 0
fi
if [ "$1" = "uninstall" ]; then
  # 真 npm 卸 300MB 要好一会：给 T5「杀网关再重启」的落盘恢复留窗口
  sleep 2
  rm -rf "$STUB/lib/node_modules/@deepseek-ai/dsh"
  exit 0
fi
echo "npm 桩：意外参数 $*" >&2
exit 1
STUB_NPM

  cat >"$STUB/bin/python3" <<'STUB_PY'
#!@BASH@
STUB=$(cd "$(dirname "$0")/.." && pwd)
echo "python3 $*" >>"$STUB/../calls"
exit 0
STUB_PY

  cat >"$STUB/bin/bash" <<'STUB_BASH'
#!@BASH@
STUB=$(cd "$(dirname "$0")/.." && pwd)
echo "bash $*" >>"$STUB/../calls"
# 网关 detached 卸载跑的是 TMPDIR/dsh-uninstall-*/run.sh —— 这条路径必须真执行：
# 否则卸载根本没发生、退出码也不会落码，job 落盘的恢复路就没法测。
# 其余调用保持纯桩（只记录、不执行），好断言「谁被调了几次」。
case "$1" in
  */dsh-uninstall-*) exec @BASH@ "$@" ;;
esac
exit 0
STUB_BASH

  cat >"$STUB/bin/sv" <<'STUB_SV'
#!@BASH@
STUB=$(cd "$(dirname "$0")/.." && pwd)
echo "sv $*" >>"$STUB/../calls"
if [ "$1" = "status" ]; then
  echo "run: $2: 1s: runsv: running"
fi
exit 0
STUB_SV

  cat >"$STUB/bin/dsh" <<'STUB_DSH'
#!@BASH@
STUB=$(cd "$(dirname "$0")/.." && pwd)
f="$STUB/lib/node_modules/@deepseek-ai/dsh/package.json"
if [ -f "$f" ]; then
  grep -o '"version":"[^"]*"' "$f" | head -1 | cut -d'"' -f4
else
  echo unknown
fi
STUB_DSH

  cat >"$STUB/bin/dsh-web-url" <<'STUB_WU'
#!@BASH@
echo "http://127.0.0.1:3080/?token=STUBTOKEN123"
STUB_WU

  # provisionDsh 第 4 步会跑 BIN/dsh-patch-lan-settings（真脚本的 shebang 指向
  # Termux 路径，Mac 上不存在，所以也用桩）
  cat >"$STUB/bin/dsh-patch-lan-settings" <<'STUB_PL'
#!@BASH@
STUB=$(cd "$(dirname "$0")/.." && pwd)
echo "dsh-patch-lan-settings $*" >>"$STUB/../calls"
exit 0
STUB_PL

  # lanIp() 跑 ifconfig（execSync 走 PATH，假树 bin 排在最前）
  # 内容必须 echo 出来：lanIp() 解析的是 stdout
  cat >"$STUB/bin/ifconfig" <<STUB_IFC
#!@BASH@
echo "en0: flags=8863 mtu 1500"
echo "  inet $FAKE_IP netmask 0xffffff00 broadcast 192.168.3.255"
echo "lo0: flags=8049 mtu 16384"
echo "  inet 127.0.0.1 netmask 0xff000000"
STUB_IFC

  for f in npm python3 bash sv dsh dsh-web-url dsh-patch-lan-settings ifconfig; do
    sed -i "s|@BASH@|$REAL_BASH|g" "$STUB/bin/$f"
    chmod +x "$STUB/bin/$f"
  done
}

post() { # post <api> <json> → POST，不带任何凭据（路由器模型：白名单接口就这么调）
  curl -s -m 20 -X POST -H 'content-type: application/json' \
    -d "$2" "$BASE/ctl/api/$1"
}
postCode() { # postCode <api> <json> → 只输出状态码
  curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
    -H 'content-type: application/json' -d "$2" "$BASE/ctl/api/$1"
}
postCk() { # postCk <api> <json> → 已登录 cookie POST，输出 body
  curl -s -m 20 -X POST -H 'content-type: application/json' \
    -H "$COOKIE" -d "$2" "$BASE/ctl/api/$1"
}
POLLER=post

# 假密钥（dsh-web 的 environment 文件，网关 readCredentials 的读源）：只在
# T1 / T4 用到时临时种进去，验完就拆 —— 这个目录在位的话 ensureWebService
# 会跳过 install-web-service.sh（那是 T2 要断言的核心路径）
plant_key() {
  mkdir -p "$STUB/var/service/dsh-web"
  printf 'export TEST_API_KEY=%s\n' "'$TEST_KEY'" >"$STUB/var/service/dsh-web/environment"
}
unplant_key() { rm -rf "$STUB/var/service/dsh-web"; }
pollJob() { # pollJob <超时秒> → JOB 变量；返回 0=done 1=failed/超时
  local i
  JOB=''
  for i in $(seq 1 "$1"); do
    JOB=$($POLLER jobstatus '{}')
    case "$JOB" in
      *'"status":"done"'*) return 0 ;;
      *'"status":"failed"'*) return 1 ;;
    esac
    sleep 1
  done
  return 1
}
# 杀掉网关再原样重启：模拟「sv down / 崩溃 / 手滑重启」。
# job 落盘就是为了这一刻 —— 新进程起来时把盘上的任务对上账。
restart_gw() {
  kill "$GW_PID" 2>/dev/null
  wait "$GW_PID" 2>/dev/null
  PREFIX="$STUB" HOME="$STUB/home" TMPDIR="$WORK/tmp" SVDIR="$STUB/var/service" \
    node "$GW" 127.0.0.1 "$GW_PORT" 127.0.0.1 "$UP_PORT" >>"$WORK/gw.log" 2>&1 &
  GW_PID=$!
  GW_READY=0
  for i in $(seq 1 40); do
    c=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/ctl" 2>/dev/null || true)
    [ "$c" = "200" ] && { GW_READY=1; break; }
    sleep 0.5
  done
  if [ "$GW_READY" != 1 ]; then
    echo "网关重启失败，看 $WORK/gw.log"; tail -20 "$WORK/gw.log"; exit 2
  fi
}

# ================================================================== 启动
build_tree
node "$WORK/upstream.js" "$WORK/mode" "$UP_PORT" >"$WORK/up.log" 2>&1 &
UP_PID=$!
UP_READY=0
for i in $(seq 1 40); do
  c=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$UP_PORT/api/__ctl_probe" 2>/dev/null || true)
  [ "$c" = "401" ] && { UP_READY=1; break; }
  sleep 0.5
done
[ "$UP_READY" = 1 ] || { echo "假上游没起来，看 $WORK/up.log"; cat "$WORK/up.log"; exit 2; }

mkdir -p "$WORK/tmp"   # 网关的 TMPDIR（卸载日志 / 临时脚本都在这）
PREFIX="$STUB" HOME="$STUB/home" TMPDIR="$WORK/tmp" SVDIR="$STUB/var/service" \
  node "$GW" 127.0.0.1 "$GW_PORT" 127.0.0.1 "$UP_PORT" >"$WORK/gw.log" 2>&1 &
GW_PID=$!
GW_READY=0
for i in $(seq 1 40); do
  c=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/ctl" 2>/dev/null || true)
  [ "$c" = "200" ] && { GW_READY=1; break; }
  sleep 0.5
done
if [ "$GW_READY" != 1 ]; then
  echo "网关没起来，看 $WORK/gw.log"; cat "$WORK/gw.log"; exit 2
fi

# ================================================================== T1
sec "T1. 开放模型鉴权（路由器模型：不登录、dsh 未装）"
# 路由器模型：局域网内打开就是控制台，没有任何令牌 / 表单
BODY=$(curl -s -m 8 "$BASE/ctl")
check "/ctl 状态码" "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/ctl")" 200
has "/ctl 直接给面板（向导卡）" "$BODY" 'id="wizard"'
nohas "/ctl 不弹令牌表单" "$BODY" 'name="bootstrap"'

check "/ 状态码" "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/")" 200
has "/ 也是面板" "$(curl -s -m 8 "$BASE/")" 'id="wizard"'

# /app 路由器模型：没 cookie 时网关自动补 dsh 的登录令牌（桩 dsh-web-url 给
# STUBTOKEN123），有 cookie 就直接取首页；令牌走不通时落回说人话的登录页
check "/app 无 cookie 跳自动登录" \
  "$(curl -s -m 8 -o /dev/null -w '%{redirect_url}' "$BASE/app")" "$BASE/app?token=STUBTOKEN123"
BODY=$(curl -s -m 8 -L "$BASE/app")
check "/app 跟随跳转 200" "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -L "$BASE/app")" 200
has "/app 落地是登录页" "$BODY" '需要先登录'
check "/app 直贴令牌也 200" "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/app?token=WHATEVER")" 200
has "/app 令牌不通给登录页" "$(curl -s -m 8 "$BASE/app?token=WHATEVER")" '令牌没通过'

check "未知 api 404" "$(postCode nosuchapi '{}')" 404

check "save 没登录不能改配置 401" "$(postCode save '{}')" 401

plant_key
BODY=$(post state '{}')
has "state 不用凭据 ok:true" "$BODY" '"ok":true'
has "state dshMissing" "$BODY" '"dshMissing":true'
has "state uninstallAvailable" "$BODY" '"uninstallAvailable":true'
has "state 凭给掩码" "$BODY" '"masked"'
nohas "state 明文 key 不外露" "$BODY" "\"value\":\"$TEST_KEY\""
unplant_key

# 已登录浏览器才知道的 cookie；T4 起用它模拟登录态
COOKIE='cookie: session=loggedin-user'

# ================================================================== T2
sec "T2. 安装任务（jobId → 轮询 → 完成；并发拒绝）"
NPM_BEFORE=$(grep '^npm install' "$WORK/calls" 2>/dev/null | wc -l | tr -d '[:space:]')
RES=$(post install "{\"version\":\"$INSTALL_VER\"}")
has "install 立即返回 ok:true" "$RES" '"ok":true'
has "install 返回 jobId" "$RES" '"jobId"'
has "install job 快照 running" "$RES" '"status":"running"'

# npm 桩 sleep 3 秒：第二个任务必须被拒绝
RES2=$(post install "{\"version\":\"$INSTALL_VER\"}")
has "并发 install 被拒绝" "$RES2" '"ok":false'
has "并发拒绝说明在跑哪个" "$RES2" '另一个任务正在跑'

if pollJob 90; then
  ok "job 轮询到 done"
  case "${DBG:-}" in 1) printf 'DBG JOB=%s\n' "$JOB";; esac
  has "job 结果 ok" "$JOB" '"ok":true'
  has "job 出现过的行被快照" "$JOB" '"lines":['
  has "job 步骤有退出码" "$JOB" '"steps":[{"cmd"'
  has "结果带 state" "$JOB" '"state":{'
  has "结果 state dshMissing:false" "$JOB" '"dshMissing":false'
  has "结果 state dshVersion" "$JOB" "\"dshVersion\":\"$INSTALL_VER\""
  has "结果给 appUrl（令牌登录链接）" "$JOB" 'app?token='
else
  bad "install 任务没完成（或失败了）：$JOB"
fi
CALLS=$(cat "$WORK/calls")
has "真跑了 npm install" "$CALLS" "npm install -g @deepseek-ai/dsh@$INSTALL_VER"
has "跑了补丁器" "$CALLS" 'python3 '
has "跑了 patches.py" "$CALLS" 'patches.py'
has "跑了 dsh-patch-lan-settings" "$CALLS" 'dsh-patch-lan-settings'
has "缺 flock 原生插件时现编" "$CALLS" 'build-flock.sh'
has "建服务脚本被执行" "$CALLS" 'install-web-service.sh'
has "sv up dsh-web" "$CALLS" 'sv up dsh-web'
has "sv status 探活" "$CALLS" 'sv status dsh-web'
NPM_AFTER=$(grep '^npm install' "$WORK/calls" 2>/dev/null | wc -l | tr -d '[:space:]')
check "安装只装一次包" "$NPM_AFTER" $((NPM_BEFORE + 1))

# 装完再问 state：dshMissing 翻转
BODY=$(post state '{}')
has "装完 state dshMissing:false" "$BODY" '"dshMissing":false'
has "装完 state 有版本" "$BODY" "\"dshVersion\":\"$INSTALL_VER\""
has "装完有 dshUrl" "$BODY" 'token='

# ================================================================== T3
sec "T3. 修复幂等（不换包，只重打补丁 + 起服务）"
NPM_BEFORE=$(grep '^npm install' "$WORK/calls" 2>/dev/null | wc -l | tr -d '[:space:]')
RES=$(post repair '{}')
has "repair 立即返回 ok:true" "$RES" '"ok":true'
has "repair 返回 jobId" "$RES" '"jobId"'
if pollJob 90; then
  ok "repair 轮询到 done"
  has "repair 结果 ok" "$JOB" '"result":{"ok":true'
else
  bad "repair 任务没完成：$JOB"
fi
NPM_AFTER=$(grep '^npm install' "$WORK/calls" 2>/dev/null | wc -l | tr -d '[:space:]')
check "修复不重装包（npm 调用数不变）" "$NPM_AFTER" "$NPM_BEFORE"
BODY=$(post state '{}')
has "修复后版本不变" "$BODY" "\"dshVersion\":\"$INSTALL_VER\""

# ================================================================== T4
sec "T4. 登录后完整权限（明文凭据 / save 放行 / 上游被代理）"
printf 'authed' >"$WORK/mode"   # 假上游从现在起认 cookie
check "/ctl 已登录 200" "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -H "$COOKIE" "$BASE/ctl")" 200
has "已登录给面板" "$(curl -s -m 8 -H "$COOKIE" "$BASE/ctl")" 'id="wizard"'

plant_key   # 掩码断言的对照组：同一把 key，登录后应该给明文
BODY=$(postCk state '{}')
has "登录后 state ok:true" "$BODY" '"ok":true'
has "登录后凭据给明文" "$BODY" "\"value\":\"$TEST_KEY\""
unplant_key
has "/app 已登录回上游页面" "$(curl -s -m 8 -H "$COOKIE" "$BASE/app")" 'UPSTREAM-APP-HTML'

# save 不再是 401：登录态放行（桩树上保存成不成功无所谓，只看不再被拒）
SC=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -H "$COOKIE" -d '{}' "$BASE/ctl/api/save")
if [ "$SC" = "401" ]; then
  bad "登录后 save 仍被 401 拒了"
else
  ok "登录后 save 不再 401（HTTP $SC）"
fi

# 白名单接口对未登录仍然开放：登录不该把路走窄了
check "state 不带 cookie 依旧 200" "$(postCode state '{}')" 200

# ================================================================== T5
sec "T5. 卸载（detached 子进程 + 杀网关再重启的落盘恢复）"
# 不带凭据调卸载：路由器模型下生命周期接口本来就开放
RES=$(post uninstall '{}')
has "uninstall 立即返回 ok:true" "$RES" '"ok":true'
has "uninstall 返回 jobId" "$RES" '"jobId"'
has "uninstall 提示后台跑" "$RES" '后台'

# 杀掉网关 = 模拟「卸载把网关自己删掉」（真机上 sv down dsh-ctl）。
# detached 子进程不在网关的进程组里 —— 杀不死，继续拆树；job 状态已落盘。
restart_gw
# 新网关起来时对账：退出码落码了（子进程已跑完）→ 结案；PID 还活着 → 续盯到它跑完
if pollJob 90; then
  ok "重启后任务轮询到 done（job 落盘 + detached 恢复）"
  has "uninstall 结果 ok" "$JOB" '"result":{"ok":true'
else
  bad "uninstall 任务没完成：$JOB"
fi
CALLS=$(cat "$WORK/calls")
has "卸载脚本被 detached 执行" "$CALLS" ' -y --dsh'
has "卸载脚本来自 TMPDIR 副本" "$CALLS" 'dsh-uninstall-'
if [ -d "$STUB/share/dsh-ctl" ]; then
  bad "假树的 share/dsh-ctl 没被删掉（detached 卸载没真跑）"
else
  ok "面板资源已删（detached 卸载真拆了假树）"
fi
if [ -d "$STUB/lib/node_modules/@deepseek-ai/dsh" ]; then
  bad "dsh 包没被卸掉（--dsh 没生效）"
else
  ok "dsh 包已卸（--dsh）"
fi

# ================================================================== T6
sec "T6. 完成态落盘保留（再重启一次仍在）+ 白名单接口不用凭据"
# 已结束的 job 写在盘上：再重启一次网关，jobstatus 照样回得出最后一个任务
restart_gw
sleep 1
BODY=$(post jobstatus '{}')
has "jobstatus 保留完成现场" "$BODY" '"status":"done"'
has "最后任务是 uninstall" "$BODY" '"kind":"uninstall"'
BODY=$(post log '{"name":"dsh-web","lines":5}')
has "log 不用凭据（白名单）" "$BODY" '"ok":true'
check "restart 不用凭据（sv 桩无条件 ok）" "$(postCode restart '{}')" 200

# ==================================================================
sec "结果"
if [ "$FAIL" -gt 0 ]; then
  echo "-- 网关日志尾部（排查用）--"
  tail -20 "$WORK/gw.log" 2>/dev/null | sed 's/^/  /'
fi
printf '通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
