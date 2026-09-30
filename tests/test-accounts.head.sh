#!/data/data/com.termux/files/usr/bin/bash
# 设备侧：安装新版 dsh-set-provider，并用一份真实的双账号清单跑通全流程。
set -u
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
PROF="$HOME/.dsh/profiles"

echo "=== 1. 备份 + 安装新版 dsh-set-provider ==="
mkdir -p "$HOME/dsh-termux/backups"
cp -a "$PREFIX/bin/dsh-set-provider" "$HOME/dsh-termux/backups/dsh-set-provider.$(date +%Y%m%d%H%M%S)"
printf '%s' '##B64##' | base64 -d > "$PREFIX/bin/dsh-set-provider"
chmod 755 "$PREFIX/bin/dsh-set-provider"
bash -n "$PREFIX/bin/dsh-set-provider" && echo "  ✓ 语法 OK"
echo "  大小: $(wc -c < "$PREFIX/bin/dsh-set-provider") 字节"

echo
echo "=== 2. 备份当前生效配置（退路）==="
cp -a "$PROF/web/cordis.patch.yml" "$TMPDIR/web.before.yml"
cp -a "$PROF/headless/cordis.patch.yml" "$TMPDIR/headless.before.yml"
echo "  已备份到 \$TMPDIR"

echo
echo "=== 3. 写入双账号清单（dahl 有 key / zhipu 无 key，验证欠 key 不炸）==="
cat > "$TMPDIR/acc.json" <<'JSON'
{
  "active": "dahl",
  "accounts": [
    {
      "id": "dahl",
      "displayName": "Dahl 聚合网关",
      "api": "openai-completions",
      "baseURL": "https://inference.dahl.global/v1",
      "keyVar": "DSH_GATEWAY_API_KEY",
      "defaultModel": "MiniMaxAI/MiniMax-M2.7",
      "models": ["deepseek-ai/DeepSeek-V4-Flash-0731", "MiniMaxAI/MiniMax-M2.7", "zai-org/GLM-5.3-Flash"]
    },
    {
      "id": "zhipu",
      "displayName": "智谱 GLM",
      "api": "anthropic-messages",
      "baseURL": "https://open.bigmodel.cn/api/anthropic",
      "keyVar": "DSH_ZHIPU_KEY",
      "models": ["glm-5", "glm-4.6", "glm-5"]
    }
  ]
}
JSON
dsh-set-provider --accounts-file "$TMPDIR/acc.json"
RC=$?
echo "  rc=$RC"

echo
echo "=== 4. 落盘的生效配置 ==="
sed -n '/# >>> dsh-provider/,/# <<< dsh-provider/p' "$PROF/web/cordis.patch.yml" | sed 's/^/  /'

echo
echo "=== 5. headless 与 web 两个 profile 是否一致 ==="
for p in web headless; do
  n=$(sed -n '/# >>> dsh-provider/,/# <<< dsh-provider/p' "$PROF/$p/cordis.patch.yml" | grep -cE '^      [a-z][a-z0-9-]*:$')
  a=$(grep -A2 'agent-default-model' "$PROF/$p/cordis.patch.yml" | grep -E 'provider:|model:' | tr -d ' ' | tr '\n' ' ')
  printf '  %-9s 账号数=%s  %s\n' "$p" "$n" "$a"
done

echo
echo "=== 6. 命令行回显 ==="
dsh-set-provider | sed 's/^/  /'

echo
echo "=== 7. 能否只切激活账号（dahl -> zhipu 再切回）==="
python3 - "$TMPDIR/acc.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); j = json.loads(p.read_text())
j['active'] = 'zhipu'
pathlib.Path('/tmp/acc2.json').write_text(json.dumps(j, ensure_ascii=False))
PY
cp /tmp/acc2.json "$TMPDIR/acc2.json"
dsh-set-provider --accounts-file "$TMPDIR/acc2.json" --no-restart >/dev/null 2>&1
grep -A2 'agent-default-model' "$PROF/web/cordis.patch.yml" | grep -E 'provider:|model:' | sed 's/^/  切到 zhipu: /'
dsh-set-provider --accounts-file "$TMPDIR/acc.json" --no-restart >/dev/null 2>&1
grep -A2 'agent-default-model' "$PROF/web/cordis.patch.yml" | grep -E 'provider:|model:' | sed 's/^/  切回 dahl : /'

echo
echo "=== 8. 服务状态 ==="
sv status dsh-web | sed 's/^/  /'
