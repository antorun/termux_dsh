#!/usr/bin/env python3
"""把 bin/ share/ runit/ 下的成品以 base64 内联进 install-ctl.head.sh，生成 install-ctl.sh。

生成的 install-ctl.sh 是单文件、可直接 bash 执行、幂等 —— 为了在设备上一次传输就把
网关、面板、runit 服务全落好（Termux 上从 Mac 推大文件走 base64 内联最省事）。

改完任一 payload 后重跑本脚本重建：

    python3 install/build-install-ctl.py
"""
import base64
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

# 键 = install-ctl.head.sh 里的 ##PAYLOAD:<键>## 占位符
# 值 = 仓库内的成品文件（顺序与 head 里占位符出现顺序一致）
PAYLOADS = {
    'dsh-ctl-gateway': 'bin/dsh-ctl-gateway',            # -> $PREFIX/bin/dsh-ctl-gateway
    'dsh-ctl-panel': 'share/dsh-ctl/panel.html',         # -> $PREFIX/share/dsh-ctl/panel.html
    'dsh-web-url': 'bin/dsh-web-url',                    # -> $PREFIX/bin/dsh-web-url
    'patch-lan-settings': 'bin/dsh-patch-lan-settings',  # -> $PREFIX/bin/dsh-patch-lan-settings
    'dsh-ctl-run': 'runit/dsh-ctl-run',                  # -> $SVDIR/dsh-ctl/run
    'dsh-set-provider': 'bin/dsh-set-provider',          # -> $PREFIX/bin/dsh-set-provider
    # 控制台「更新 dsh 版本」要用的两件：npm 换包会冲掉 Termux 补丁，升级后得就地重打。
    'patches-py': 'install/patches.py',                  # -> $PREFIX/share/dsh-ctl/patches.py
    'build-flock': 'install/build-flock.sh',             # -> $PREFIX/share/dsh-ctl/build-flock.sh
}

head = (HERE / 'install-ctl.head.sh').read_text()
for key, rel in PAYLOADS.items():
    src = ROOT / rel
    assert src.is_file(), '缺文件: ' + str(src)
    b64 = base64.b64encode(src.read_bytes()).decode()
    assert '\n' not in b64, rel + ': base64 折行了'
    token = '##PAYLOAD:%s##' % key
    assert token in head, '占位符缺失: ' + token
    head = head.replace(token, b64)

assert '##PAYLOAD' not in head, '还有未替换的占位符'
out = HERE / 'install-ctl.sh'
out.write_text(head)
print('written:', out, len(head), 'bytes')
