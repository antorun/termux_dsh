#!/data/data/com.termux/files/usr/bin/bash
# 修正版：headless 走的是 headless profile，不是 web profile
set -u
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
export DSH_HOME="$HOME/.dsh"
H="$DSH_HOME/profiles/headless"
W="$DSH_HOME/profiles/web"

echo "##### 0. headless profile 里有没有 llm-deepseek 条目"
dsh --dump-default-config --profile headless 2>/dev/null | grep -n -B2 -A4 "dsh-llm-deepseek-api-key"

probe() {
  echo "===== $1 ====="
  DEEPSEEK_API_KEY=sk-0000000000000000000000000000000000000000 \
    timeout 60 dsh headless "hi" 2>&1 | tail -4
  echo
}

echo "##### A. 基线（headless profile 未改）"
probe "基线"

echo "##### B. headless/cordis.patch.yml 覆写 baseURL"
cp -a "$H/cordis.patch.yml" "$H/cordis.patch.yml.bak"
cat > "$H/cordis.patch.yml" <<'YML'
- id: llm-deepseek
  config:
    baseURL: https://127.0.0.1:9/anthropic
    apiKeyEnv: THIRDPARTY_API_KEY
YML
probe "cordis.patch.yml(headless) 生效测试"

echo "##### C. 换成 headless/settings.yaml"
mv -f "$H/cordis.patch.yml.bak" "$H/cordis.patch.yml"
cat > "$H/settings.yaml" <<'YML'
llm-deepseek:
  baseURL: https://127.0.0.1:9/anthropic
  apiKeyEnv: THIRDPARTY_API_KEY
YML
probe "settings.yaml(headless) 生效测试"

echo "##### D. 复原"
rm -f "$H/settings.yaml"
ls -la "$H"
echo "--- patch 内容 ---"; cat "$H/cordis.patch.yml" | sed 's/^/    /'
echo "--- web profile 是否被污染 ---"; ls "$W"
echo
echo "##### E. 复原后基线复核"
probe "复原后"
