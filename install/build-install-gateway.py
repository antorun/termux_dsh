#!/usr/bin/env python3
"""把 bin/ share/ runit/ install/ 下的成品以 base64 内联进 install-gateway.head.sh，
生成 install-gateway.sh（网关优先方案的唯一入口）。

生成的 install-gateway.sh 是单文件、可直接 bash 执行、幂等 —— 在设备上跑一次就把
网关、面板、runit 服务、生命周期四件套（patches.py / build-flock.sh /
uninstall.sh / install-web-service.sh）全落好。dsh 本体不在这里装，装完网关后去
浏览器控制台贴引导令牌，由控制台走 install / repair / upgrade / uninstall。

改完任一 payload 后重跑本脚本重建：

    python3 install/build-install-gateway.py
"""
import base64
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

# 键 = install-gateway.head.sh 里的 ##PAYLOAD:<键>## 占位符
# 值 = 仓库内的成品文件（顺序与 head 里占位符出现顺序一致）
PAYLOADS = {
    'dsh-ctl-gateway':    'bin/dsh-ctl-gateway',              # -> $PREFIX/bin/dsh-ctl-gateway
    'dsh-ctl-panel':      'share/dsh-ctl/panel.html',         # -> $PREFIX/share/dsh-ctl/panel.html
    'dsh-web-url':        'bin/dsh-web-url',                  # -> $PREFIX/bin/dsh-web-url
    'patch-lan-settings': 'bin/dsh-patch-lan-settings',       # -> $PREFIX/bin/dsh-patch-lan-settings
    'dsh-set-provider':   'bin/dsh-set-provider',             # -> $PREFIX/bin/dsh-set-provider
    'dsh-set-key':        'bin/dsh-set-key',                  # -> $PREFIX/bin/dsh-set-key
    'dsh-lan-gateway':    'bin/dsh-lan-gateway',              # -> $PREFIX/bin/dsh-lan-gateway
    'dsh-lan-ip':         'bin/dsh-lan-ip',                   # -> $PREFIX/bin/dsh-lan-ip
    'verify-hot-reload':  'bin/verify-hot-reload.sh',         # -> $PREFIX/bin/verify-hot-reload.sh
    'patches-py':         'install/patches.py',               # -> $PREFIX/share/dsh-ctl/patches.py
    'build-flock':        'install/build-flock.sh',           # -> $PREFIX/share/dsh-ctl/build-flock.sh
    'uninstall-sh':       'install/uninstall.sh',             # -> $PREFIX/share/dsh-ctl/uninstall.sh
    'install-web-service': 'install/install-web-service.sh',  # -> $PREFIX/share/dsh-ctl/install-web-service.sh
    'dsh-ctl-run':        'runit/dsh-ctl-run',                # -> $SVDIR/dsh-ctl/run
}

# 显式 utf-8：Windows 上 read_text 默认按终端 locale（GBK）解码中文 payload 会炸
head = (HERE / 'install-gateway.head.sh').read_text(encoding='utf-8')
for key, rel in PAYLOADS.items():
    src = ROOT / rel
    assert src.is_file(), '缺文件: ' + str(src)
    b64 = base64.b64encode(src.read_bytes()).decode()
    assert '\n' not in b64, rel + ': base64 折行了'
    token = '##PAYLOAD:%s##' % key
    assert token in head, '占位符缺失: ' + token
    head = head.replace(token, b64)

leftover = [ln for ln in head.splitlines() if '##PAYLOAD' in ln]
if leftover:
    raise SystemExit(f'还有没替换的占位符: {leftover}')

out = HERE / 'install-gateway.sh'
# 写字节：在 Windows 上 write_text 会把 \n 翻成 \r\n，生成的安装器拿到 bash 里
# 就满屏 $'\r': command not found（3.7 的 write_text 还没有 newline= 参数）
out.write_bytes(head.encode('utf-8'))
print(f'已生成 {out} ({len(head)} bytes, {len(PAYLOADS)} 个 payload)')
