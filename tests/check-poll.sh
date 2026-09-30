#!/usr/bin/env bash
# tests/check-poll.sh —— 校验 install-gateway.head.sh 里内联的 dsh-install-poll.js。
# 那段 JS 是 heredoc 内联的（不是独立文件），改它时单独 node --check 一下最稳。
# 跑法（仓库根目录）：bash tests/check-poll.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
H="$HERE/../install/install-gateway.head.sh"
OUT="${TMPDIR:-${TMP:-/tmp}}/poll-check-$$.js"
trap 'rm -f "$OUT"' EXIT
awk '/cat >"\$TMPDIR\/dsh-install-poll.js" <<.POLL_EOF.$/{f=1;next} /^POLL_EOF$/{f=0} f' "$H" > "$OUT"
L=$(wc -l <"$OUT")
[ "$L" -gt 50 ] || { echo "✗ 只提取到 $L 行，heredoc 边界没匹配上"; exit 1; }
echo "提取 $L 行"
if command -v node >/dev/null 2>&1; then
  node --check "$OUT" && echo "poll.js 语法 OK" || { echo "✗ poll.js 语法不过"; exit 1; }
else
  echo "无 node，跳过"
fi
