#!/data/data/com.termux/files/usr/bin/bash
# 实测：third-party baseURL 从哪个文件生效（settings.yaml vs cordis.patch.yml）
set -u
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
export DSH_HOME="$HOME/.dsh"
P="$DSH_HOME/profiles/web"
BOGUS="https://127.0.0.1:9/anthropic"   # 必然连接失败：用来判定 baseURL 是否被读到

probe() { # $1 = 标签
  echo "===== $1 ====="
  DEEPSEEK_API_KEY=sk-0000000000000000000000000000000000000000 \
    timeout 60 dsh headless "hi" 2>&1 | tail -4
  echo
}

echo "##### A. 基线（两个文件都不动）"
probe "基线"

echo "##### B. 写 profiles/web/settings.yaml"
cat > "$P/settings.yaml" <<'YML'
llm-deepseek:
  baseURL: https://127.0.0.1:9/anthropic
  apiKeyEnv: THIRDPARTY_API_KEY
YML
cat "$P/settings.yaml" | sed 's/^/    /'
probe "settings.yaml 生效测试"

echo "##### C. 撤掉 settings.yaml，改用 cordis.patch.yml"
rm -f "$P/settings.yaml"
cp -a "$P/cordis.patch.yml" "$P/cordis.patch.yml.bak"
cat > "$P/cordis.patch.yml" <<'YML'
- id: llm-deepseek
  config:
    baseURL: https://127.0.0.1:9/anthropic
    apiKeyEnv: THIRDPARTY_API_KEY
YML
probe "cordis.patch.yml 生效测试"

echo "##### D. 复原"
mv -f "$P/cordis.patch.yml.bak" "$P/cordis.patch.yml"
rm -f "$P/settings.yaml"
echo "已复原："
cat "$P/cordis.patch.yml" | sed 's/^/    /'
ls -la "$P"
echo
echo "##### E. 复原后基线复核"
probe "复原后"
