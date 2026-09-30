#!/data/data/com.termux/files/usr/bin/bash
# 检查凭据文件是否被写坏（只报长度与是否一致，不打印明文）
P="$PREFIX"
F="$P/var/service/dsh-web/environment"

echo "=== 文件内容（值打码）==="
sed -E 's/(=.{0,10}).*/\1…/' "$F"

echo
echo "=== 每个变量的值长度 ==="
while IFS= read -r line; do
  case "$line" in
    "export "*"="*)
      name="${line#export }"; name="${name%%=*}"
      val="${line#*=}"
      printf '  %-26s %s 字符\n' "$name" "${#val}"
      ;;
  esac
done < "$F"

echo
echo "=== 与预期比对（不打印明文）==="
EXPECT='dahl_7dKF1i1XRcjXKVr1jof8fKcn3xkZzom8Y'
GOT=$(sed -n 's/^export DSH_GATEWAY_API_KEY=//p' "$F" | tr -d '"'"'"'')
if [ "$GOT" = "$EXPECT" ]; then
  echo "  gateway key 一致 ✓"
else
  echo "  gateway key 不一致 ✗  实际长度=${#GOT}  期望长度=${#EXPECT}"
  printf '  实际前缀: %.14s…\n' "$GOT"
fi

echo
echo "=== 直接拿文件里的 key 打一次 dahl（验证 key 本身还有效）==="
K=$(sed -n 's/^export DSH_GATEWAY_API_KEY=//p' "$F" | tr -d '"'"'"'')
curl -s -o /dev/null -w "  GET /v1/models -> %{http_code}\n" --max-time 20 \
  -H "authorization: Bearer $K" https://inference.dahl.global/v1/models
curl -s --max-time 25 -X POST https://inference.dahl.global/v1/chat/completions \
  -H "authorization: Bearer $K" -H 'content-type: application/json' \
  -d '{"model":"deepseek-ai/DeepSeek-V4-Flash-0731","max_tokens":16,"messages":[{"role":"user","content":"只回答两个字：收到"}]}' \
  | head -c 200
echo

echo
echo "=== dsh-set-key 是怎么写文件的（看合并逻辑）==="
grep -nE 'environment|>>|> *"\$|grep -v|sort|mv |cp ' "$P/bin/dsh-set-key" | head -20
