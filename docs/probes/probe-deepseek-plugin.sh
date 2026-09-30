#!/data/data/com.termux/files/usr/bin/bash
# 对比：llm-deepseek（dsh 官方 anthropic 插件）发出的请求形状，
# 以及它能否与 llm-pi-ai 同时共存。
set -u
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
DSH_HOME="$HOME/.dsh"
W="$DSH_HOME/profiles/web/cordis.patch.yml"
H="$DSH_HOME/profiles/headless/cordis.patch.yml"
LOG="$TMPDIR/mock.log"

cp -a "$W" "$TMPDIR/cw.bak"; cp -a "$H" "$TMPDIR/ch.bak"

cat > "$TMPDIR/mock.js" <<'JS'
const http = require('http'), fs = require('fs')
const LOG = process.env.TMPDIR + '/mock.log'
http.createServer((req, res) => {
  let b = ''
  req.on('data', (d) => { b += d })
  req.on('end', () => {
    fs.appendFileSync(LOG, JSON.stringify({ m: req.method, u: req.url, h: req.headers }) + '\n')
    if (/\/models/.test(req.url)) {
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end(JSON.stringify({ data: [{ id: 'm-1', display_name: 'M One' }] }))
    }
    // 返回一个合法但立即结束的 SSE 流，让客户端能正常收尾
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
    res.write('event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"m-1","content":[],"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":0}}}\n\n')
    res.write('event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n')
    res.write('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"收到"}}\n\n')
    res.write('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
    res.write('event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n')
    res.write('event: message_stop\ndata: {"type":"message_stop"}\n\n')
    res.end()
  })
}).listen(18999, '127.0.0.1', () => console.log('mock up'))
JS
: > "$LOG"; node "$TMPDIR/mock.js" >/dev/null 2>&1 & MOCK=$!
sleep 1.5

write_pair() {
  cat > "$1" <<'YML'
# >>> dsh-provider (probe)
- id: llm-deepseek
  config:
    baseURL: http://127.0.0.1:18999
    thinking: disabled
    maxTokens: 8192
    models:
      - id: m-1
        name: m-1
- id: llm-pi-ai
  config:
    providers:
      mockoai:
        apiKeyEnv: DSH_GATEWAY_API_KEY
        displayName: Mock OpenAI
        api: openai-completions
        baseURL: http://127.0.0.1:18999/v1
        models:
          - id: m-1
            name: m-1
- id: agent-default-model
  config:
    provider: deepseek-official
    model: m-1
# <<< dsh-provider
YML
}
write_pair "$W"; write_pair "$H"

echo "=== A. llm-deepseek + llm-pi-ai 能否共存 ==="
if dsh --dump-config --profile web > "$TMPDIR/d.txt" 2>&1; then
  echo "  ✓ 组合成功"
  grep -nE "id: llm-deepseek|id: llm-pi-ai|provider: |baseURL:" "$TMPDIR/d.txt" | head -10 | sed 's/^/    /'
else
  echo "  ✗ 组合失败："; head -12 "$TMPDIR/d.txt" | sed 's/^/    /'
fi

set -a; [ -f "$PREFIX/var/service/dsh-web/environment" ] && . "$PREFIX/var/service/dsh-web/environment"; set +a

echo
echo "=== B. llm-deepseek 发出的请求形状 ==="
: > "$LOG"
timeout 60 dsh headless "只回答两个字：收到" > "$TMPDIR/r.txt" 2>&1
echo "  rc=$? 输出：$(grep -aoE '收到|TRANSPORT|MISSING[A-Z_]*' "$TMPDIR/r.txt" | head -2 | tr '\n' ' ')"
python3 - "$LOG" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    d = json.loads(line); n += 1
    if n > 3: continue
    print('    %s %s' % (d['m'], d['u']))
    h = {k: v for k, v in d['h'].items() if k in ('authorization', 'x-api-key', 'anthropic-version', 'anthropic-beta')}
    print('      头: %s' % h)
print('    （共 %d 个请求）' % n)
PY

echo
echo "=== C. 还原 ==="
kill $MOCK 2>/dev/null
cp -a "$TMPDIR/cw.bak" "$W"; cp -a "$TMPDIR/ch.bak" "$H"
dsh-set-provider 2>/dev/null | head -4 | sed 's/^/    /'
