#!/data/data/com.termux/files/usr/bin/bash
# 验证：把 anthropic-messages 也交给 llm-pi-ai 之后，请求形状对不对。
# 用本地 mock 端点记录 dsh 实际发出的 method/url/headers/body。
set -u
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
DSH_HOME="$HOME/.dsh"
W="$DSH_HOME/profiles/web/cordis.patch.yml"
H="$DSH_HOME/profiles/headless/cordis.patch.yml"
LOG="$TMPDIR/mock.log"

echo "=== 0. 备份两份 patch ==="
cp -a "$W" "$TMPDIR/cordis.web.bak"
cp -a "$H" "$TMPDIR/cordis.headless.bak"
echo "  已备份到 \$TMPDIR"

echo
echo "=== 1. 起 mock 端点 :18999 ==="
cat > "$TMPDIR/mock.js" <<'JS'
const http = require('http'), fs = require('fs')
const LOG = process.env.TMPDIR + '/mock.log'
http.createServer((req, res) => {
  let b = ''
  req.on('data', (d) => { b += d })
  req.on('end', () => {
    fs.appendFileSync(LOG, JSON.stringify({ m: req.method, u: req.url, h: req.headers, b: b.slice(0, 500) }) + '\n')
    if (/\/models/.test(req.url)) {
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end(JSON.stringify({ data: [{ id: 'mock-model-1', display_name: 'Mock One' }, { id: 'mock-model-2' }] }))
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({
      id: 'msg_mock', type: 'message', role: 'assistant', model: 'mock-model-1',
      content: [{ type: 'text', text: '收到' }],
      stop_reason: 'end_turn', usage: { input_tokens: 1, output_tokens: 1 },
    }))
  })
}).listen(18999, '127.0.0.1', () => console.log('mock on 18999'))
JS
: > "$LOG"
node "$TMPDIR/mock.js" > "$TMPDIR/mock.out" 2>&1 &
MOCK=$!
sleep 1.5
curl -s -o /dev/null -w "  mock 自检 GET /models -> %{http_code}\n" http://127.0.0.1:18999/models

echo
echo "=== 2. 写入双 provider 配置（同插件两个路由，协议不同）==="
write_cfg() {
  cat > "$1" <<'YML'
# >>> dsh-provider (probe)
- id: llm-pi-ai
  config:
    providers:
      mockopenai:
        apiKeyEnv: DSH_GATEWAY_API_KEY
        displayName: Mock OpenAI
        api: openai-completions
        baseURL: http://127.0.0.1:18999/v1
        models:
          - id: mock-model-1
            name: mock-model-1
      mockanth:
        apiKeyEnv: DSH_GATEWAY_API_KEY
        displayName: Mock Anthropic
        api: anthropic-messages
        baseURL: http://127.0.0.1:18999
        models:
          - id: mock-model-2
            name: mock-model-2
- id: agent-default-model
  config:
    provider: mockopenai
    model: mock-model-1
# <<< dsh-provider
YML
}
write_cfg "$W"; write_cfg "$H"

echo "=== 3. 组合校验（两个路由能不能共存）==="
if dsh --dump-config --profile web > "$TMPDIR/dump.txt" 2>&1; then
  echo "  ✓ profile web 组合成功"
  grep -nE "mockopenai|mockanth|api:|baseURL:" "$TMPDIR/dump.txt" | head -14 | sed 's/^/    /'
else
  echo "  ✗ 组合失败："
  head -15 "$TMPDIR/dump.txt" | sed 's/^/    /'
fi

set -a; [ -f "$PREFIX/var/service/dsh-web/environment" ] && . "$PREFIX/var/service/dsh-web/environment"; set +a

echo
echo "=== 4. 走 openai 路由跑 headless ==="
: > "$LOG"
timeout 90 dsh headless "只回答两个字：收到" > "$TMPDIR/o1.txt" 2>&1
echo "  rc=$? 回答：$(grep -aoE '收到|Error|error|MISSING[A-Z_]*|[A-Z_]{6,}' "$TMPDIR/o1.txt" | tail -2 | tr '\n' ' ')"
echo "  mock 收到："
python3 - "$LOG" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line)
    print('    %s %s' % (d['m'], d['u']))
    h = {k: v for k, v in d['h'].items() if k in ('authorization', 'x-api-key', 'anthropic-version', 'content-type', 'accept')}
    print('      头: %s' % h)
PY

echo
echo "=== 5. 走 anthropic 路由跑 headless ==="
sed -i 's/^    provider: .*/    provider: mockanth/; s/^    model: .*/    model: mock-model-2/' "$W"
sed -i 's/^    provider: .*/    provider: mockanth/; s/^    model: .*/    model: mock-model-2/' "$H"
grep -A2 "agent-default-model" "$W" | sed 's/^/    /'
dsh --dump-config --profile web > /dev/null 2>&1 && echo "  ✓ 改后组合仍成功" || echo "  ✗ 改后组合失败"
: > "$LOG"
timeout 90 dsh headless "只回答两个字：收到" > "$TMPDIR/o2.txt" 2>&1
echo "  rc=$? 回答：$(grep -aoE '收到|Error|error|MISSING[A-Z_]*|[A-Z_]{6,}' "$TMPDIR/o2.txt" | tail -2 | tr '\n' ' ')"
echo "  mock 收到："
python3 - "$LOG" <<'PY'
import json, sys
try:
    for line in open(sys.argv[1]):
        d = json.loads(line)
        print('    %s %s' % (d['m'], d['u']))
        h = {k: v for k, v in d['h'].items() if k in ('authorization', 'x-api-key', 'anthropic-version', 'content-type', 'accept')}
        print('      头: %s' % h)
        print('      体: %s' % d['b'][:220])
except FileNotFoundError:
    print('    (mock 没收到任何请求)')
PY

echo
echo "=== 6. 模型发现：两个协议的列表 URL 与鉴权 ==="
: > "$LOG"
dsh --dump-config --profile web >/dev/null 2>&1
node -e '
const { execFileSync } = require("child_process")
' 2>/dev/null
echo "  （见 §7，改用真实调用）"

echo
echo "=== 7. 还原 ==="
kill $MOCK 2>/dev/null
cp -a "$TMPDIR/cordis.web.bak" "$W"
cp -a "$TMPDIR/cordis.headless.bak" "$H"
grep -c "dsh-provider" "$W" | sed 's/^/  web 里 dsh-provider 标记数: /'
echo "  已还原；当前后端："
dsh-set-provider 2>/dev/null | head -8 | sed 's/^/    /'
