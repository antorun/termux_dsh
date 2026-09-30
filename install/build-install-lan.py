#!/usr/bin/env python3
"""把 bin/ runit/ 下的 payload 内联进 install-lan.head.sh，生成可直接执行的 install-lan.sh。

install-lan.sh 里内嵌的 base64 是为了一次性传输不失真；改完 payload 后重跑本脚本重建即可：

    python3 install/build-install-lan.py
"""
import base64
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

# 键 = install-lan.head.sh 里的 ##PAYLOAD:<键>## 占位符
PAYLOADS = {
    'dsh-lan-ip': 'bin/dsh-lan-ip',            # -> $PREFIX/bin/dsh-lan-ip
    'dsh-lan-gateway': 'bin/dsh-lan-gateway',  # -> $PREFIX/bin/dsh-lan-gateway
    'dsh-web-url': 'bin/dsh-web-url',          # -> $PREFIX/bin/dsh-web-url
    'dsh-lan-run': 'runit/dsh-lan-run',        # -> $SVDIR/dsh-lan/run
}

head = (HERE / 'install-lan.head.sh').read_text()
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

out = HERE / 'install-lan.sh'
out.write_text(head)
print(f'已生成 {out} ({len(head)} bytes)')
