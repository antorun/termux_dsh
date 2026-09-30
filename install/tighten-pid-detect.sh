#!/data/data/com.termux/files/usr/bin/bash
# 收紧 dsh-set-key 里的进程识别：只认 cmdline 含 "bin/dsh web" 的 node 进程，
# 避免抓到 svlogd 日志进程（同一陷阱：sv status 也报两个 pid）。
set -eu
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"

for f in "$PREFIX/bin/dsh-set-key" "$HOME/dsh-termux/dsh-set-key"; do
  python3 - "$f" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
old = """  local pid
  for p in /proc/[0-9]*/environ; do
    pid=$(printf '%s' "$p" | cut -d/ -f3)
    case "$(tr '\\0' ' ' < "$p" 2>/dev/null)" in
      *dsh*web*)
        if tr '\\0' '\\n' < "$p" 2>/dev/null | grep -q '^DEEPSEEK_API_KEY='; then
          echo "  ✓ 服务进程 $pid 已带上 DEEPSEEK_API_KEY"
        else
          echo "  ! 服务进程 $pid 未见 DEEPSEEK_API_KEY"
        fi;;
    esac
  done
"""
new = """  local pid cmd
  # 只认 cmdline 里是 「<node> --expose-internals .../bin/dsh web ...」 的那个进程。
  # sv status 会同时报主进程与 svlogd 两个 pid，按 cmdline 判才不会杀/报错对象。
  for p in /proc/[0-9]*/cmdline; do
    pid=$(printf '%s' "$p" | cut -d/ -f3)
    cmd=$(tr '\\0' ' ' < "$p" 2>/dev/null)
    case "$cmd" in
      *"/bin/dsh web"*)
        if tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^DEEPSEEK_API_KEY='; then
          echo "  ✓ 服务进程 $pid 已带上 DEEPSEEK_API_KEY"
        else
          echo "  ! 服务进程 $pid 未见 DEEPSEEK_API_KEY"
        fi
        echo "    cmd: $cmd";;
    esac
  done
"""
if old not in src:
    if "只认 cmdline 里是" in src:
        print(f"  {sys.argv[1]}: 已收紧，跳过")
    else:
        print(f"  ✗ {sys.argv[1]}: 锚点未命中，停手", file=sys.stderr)
        sys.exit(3)
else:
    p.write_text(src.replace(old, new))
    print(f"  {sys.argv[1]}: 已收紧进程识别")
PY
done

echo "== 语法自检 =="
bash -n "$PREFIX/bin/dsh-set-key" && echo "  OK"
echo "== 复测（假 key 仍在）=="
"$PREFIX/bin/dsh-set-key" --show
