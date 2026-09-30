#!/data/data/com.termux/files/usr/bin/bash
# 把「局域网下开放设置页」的补丁并入 ~/dsh-termux/patches.py，幂等。
set -u
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:$PREFIX/bin/applets:$PATH

P="$HOME/dsh-termux/patches.py"
[ -f "$P" ] || { echo "✗ 找不到 $P"; exit 1; }
cp -a "$P" "$HOME/dsh-termux/backups/patches.py.bak.$(date +%Y%m%d%H%M%S)"

python3 - "$P" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

FUNC_MARK = "termux-lan-settings:"
FUNC = '''

def patch_lan_settings(dry=False):
    """⑤ 让 Web UI 在「非 loopback 的浏览器地址」下也开放设置页。

    dsh-client-connection/lib/client.js 里
        isLoopback: transport?.ownsHost === true || pageLocation === void 0
                 || isLoopbackHostname(pageLocation.hostname)
    pageLocation 就是浏览器的 location，经局域网 IP 打开时必然为 false。
    而 dsh-client-ui-settings 用它决定设置镜像的持久化模式
    （isLoopback ? "host" : "memory"），memory 模式下 mirror.load() 直接
    return，永不向 Host 取 describe，设置页于是报
    「settings are unavailable in this browser」。

    只影响「浏览器经非 loopback 地址打开」这一种情形：桌面端 ownsHost=true、
    Node 侧 pageLocation 为 undefined 时本来就是 true。服务端那道
    Host/Origin 围栏（isTrustedApiRequest）不受影响，仍由 dsh-web 的
    --trusted-host 决定，鉴权仍要 cookie。

    termux-lan-settings: 与 $PREFIX/bin/dsh-patch-lan-settings 产出完全一致。
    """
    once(os.path.join(DSH, "node_modules", "@deepseek-ai", "dsh-client-connection",
                      "lib", "client.js"),
         "isLoopback: transport?.ownsHost === true || pageLocation === void 0 || "
         "isLoopbackHostname(pageLocation.hostname)",
         "isLoopback: true /* dsh-termux-lan */",
         "dsh-termux-lan", dry)

'''

if FUNC_MARK in s:
    print("  补丁函数已在 patches.py 里，跳过插入")
else:
    anchor = "# ---------------------------------------------------------------- 主流程"
    n = s.count(anchor)
    if n != 1:
        sys.exit("✗ 主流程锚点命中 %d 次，停手" % n)
    s = s.replace(anchor, FUNC.lstrip("\n") + "\n" + anchor, 1)
    print("  已插入 patch_lan_settings()")

CALL = "    patch_lan_settings(dry)\n"
if "patch_lan_settings(dry)" in s:
    print("  主流程里已有调用，跳过")
else:
    anchor = "    patch_links(dry)\n"
    n = s.count(anchor)
    if n != 1:
        sys.exit("✗ run_all 锚点命中 %d 次，停手" % n)
    s = s.replace(anchor, anchor + CALL, 1)
    print("  已把 patch_lan_settings 挂进 run_all")

p.write_text(s, encoding="utf-8")
PY

echo "== 语法自检 =="
python3 -c "import ast,sys; ast.parse(open('$P',encoding='utf-8').read()); print('  patches.py 语法 OK')"

echo "== 补丁状态（应把 client.js 报成「已打」）=="
python3 "$P" --list 2>&1 | sed 's/^/  /'
