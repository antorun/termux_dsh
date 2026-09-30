#!/data/data/com.termux/files/usr/bin/bash
# dsh-set-provider 的 --model 语义回归：预置名 + --model 不得重复写入。
set -u
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH=$PREFIX/bin:$PREFIX/bin/applets:$PATH

F="$HOME/.dsh/profiles/web/cordis.patch.yml"
A="deepseek-ai/DeepSeek-V4-Flash-0731"
B="MiniMaxAI/MiniMax-M2.7"
C="zai-org/GLM-5.3-Flash"

models_of() { grep -E "^ +- id: " "$F" | sed 's/^ *- id: //' | paste -sd, -; }

run() { # $1=说明 $2=期望
  echo "== $1"
  echo "   期望: $2"
  echo "   实得: $(models_of)"
  [ "$(models_of)" = "$2" ] && echo "   ✓" || echo "   ✗ 不一致"
  echo
}

echo "########## T1 预置名在前 + --model 覆盖（复现原 bug 的顺序）"
dsh-set-provider dahl --api openai-completions --provider-id gateway \
  --model "$A,$B" --no-restart >/dev/null 2>&1
dphp=$?
run "dahl --model A,B" "$A,$B"

echo "########## T2 --model 出现在预置名之前"
dsh-set-provider --api openai-completions --provider-id gateway --model "$A,$C" dahl --no-restart >/dev/null 2>&1
run "--model A,C dahl" "$A,$C"

echo "########## T3 多次 --model 仍然累加"
dsh-set-provider --base-url https://inference.dahl.global/v1 --api openai-completions \
  --provider-id gateway --model "$A" --model "$B" --no-restart >/dev/null 2>&1
run "--model A --model B" "$A,$B"

echo "########## T4 重复 id 要去重"
dsh-set-provider --base-url https://inference.dahl.global/v1 --api openai-completions \
  --provider-id gateway --model "$A,$A,$B,$B,$C" --no-restart >/dev/null 2>&1
run "--model A,A,B,B,C" "$A,$B,$C"

echo "########## T5 只给预置名，用预置自带的模型列表"
dsh-set-provider dahl --no-restart >/dev/null 2>&1
run "dahl（不带 --model）" "$A,$B,$C"

echo "########## T6 收尾：重放正式配置（两个 profile）并重启"
dsh-set-provider dahl --key-var DSH_GATEWAY_API_KEY --model "$A,$B,$C"
echo "  web      models: $(models_of)"
echo "  headless models: $(grep -E '^ +- id: ' "$HOME/.dsh/profiles/headless/cordis.patch.yml" | sed 's/^ *- id: //' | paste -sd, -)"
