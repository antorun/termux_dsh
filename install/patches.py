#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dsh-termux · JS 补丁器（只改 node_modules 里的源码，不改 dsh 的功能语义）

背景：@deepseek-ai/dsh 是为 glibc Linux/macOS/Windows 构建的，在 Android/Termux 上
有几处硬不兼容。本脚本把补丁逐条打上去，每条都：

  · 有 marker —— 已打过就跳过（幂等，npm 升级后重跑即可）
  · 有锚点断言 —— 上游代码变了就**报错停手**，绝不静默改错地方
  · 首次改动前把原文件备份到 $HOME/.dsh-termux-backup/orig/（可回退）

用法：
    python3 patches.py            # 打全部补丁
    python3 patches.py --dry-run  # 只报告会改什么，不写盘
    python3 patches.py --list     # 列出补丁与状态
"""
import argparse
import hashlib
import io
import os
import shutil
import sys

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
DSH = os.path.join(PREFIX, "lib", "node_modules", "@deepseek-ai", "dsh")
NODE_BIN = os.path.join(PREFIX, "bin", "node")
BACKUP = os.path.join(os.path.expanduser("~"), ".dsh-termux-backup", "orig")

FAIL = []     # [(相对路径, 原因)] —— 结构化，便于按文件聚合状态
SKIP = []     # [相对路径]         已打过（幂等跳过）
DONE = []     # [相对路径]         本次改动
CHANGES = []  # [可读描述]         只用于最终报告，不参与判定


def rel(p):
    return os.path.relpath(p, DSH)


def read(p):
    with io.open(p, encoding="utf-8") as fh:
        return fh.read()


def backup_once(path):
    """首次改动前留一份原件。按相对路径存放，重跑不会覆盖真原件。"""
    dst = os.path.join(BACKUP, rel(path))
    if os.path.exists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(path, dst)


def once(path, old, new, marker, dry=False):
    """替换 old→new（必须唯一命中），并把 marker 写进文件（用作幂等判据）。

    幂等判据有两条，命中任一即算已打过：

      1) marker 出现在文件里 —— 适用于替换文本自带注释标记的补丁；
      2) new 本身已经出现在文件里 —— 适用于「往 import 列表 / 对象属性表里
         插入一个名字」这类补丁。它们插入的是裸标识符，没有地方放 marker
         （放注释会污染上游代码风格），而打完之后原锚点文本也变了，于是
         只靠 ① 会在重跑时报「锚点命中 0 次」的**假失败**。
         用 ② 兜底后，已经打过的树能正确判定为已打过，不必回滚重打。
    """
    name = rel(path)
    if not os.path.exists(path):
        FAIL.append(("文件不存在", name))
        return False
    src = read(path)
    if marker in src or new in src:
        SKIP.append(name)
        return False
    n = src.count(old)
    if n != 1:
        FAIL.append((name, "锚点命中 %d 次（应为 1 次），上游代码变了，停手：%s"
                     % (n, old.strip().splitlines()[0][:90])))
        return False
    if not dry:
        backup_once(path)
        io.open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
    DONE.append(name)
    CHANGES.append(name)
    return True


# ---------------------------------------------------------------- 补丁定义

def patch_shebang(dry=False):
    """① 让 dsh 用 `node --expose-internals` 启动。

    Android 上没有 node-addon-require-builtin 的预编译包，而 Node 内部模块
    (internal/modules/esm/loader 等) 只有带这个标志才 require 得到。
    NODE_OPTIONS 里塞不进去（node 明确拒绝），只能写在 shebang 上。
    """
    p = os.path.join(DSH, "lib", "bin.js")
    src = read(p)
    first, sep, rest = src.partition("\n")
    if "expose-internals" in first:
        SKIP.append(rel(p))
        return
    if not first.startswith("#!"):
        FAIL.append((rel(p), "首行不是 shebang，与预期不符"))
        return
    if not dry:
        backup_once(p)
        io.open(p, "w", encoding="utf-8").write(
            "#!" + NODE_BIN + " --expose-internals\n" + rest)
    DONE.append(rel(p))
    CHANGES.append(rel(p) + "（shebang → node --expose-internals）")


ANCHOR_ADDON = ('const addon = createRequire(import.meta.url)'
                '("node-addon-require-builtin");')
REPLACE_ADDON = (
    "/* termux-expose-internals: Android 上 node-addon-require-builtin 没有预编译包。\n"
    "\t   带 --expose-internals 启动时，普通 require 就能拿到同样是这些 id 的内部模块，\n"
    "\t   于是这个原生插件不再必需。无该标志时仍走原生插件（非 Android 平台零影响）。 */\n"
    "\tconst addon = process.execArgv.includes(\"--expose-internals\")\n"
    "\t\t? { requireBuiltin: (id) => createRequire(import.meta.url)(id) }\n"
    "\t\t: createRequire(import.meta.url)(\"node-addon-require-builtin\");"
)


def patch_flock(dry=False):
    """③ 让 flock 原生模块接受 android 平台。

    模块本身有 linux/darwin 预编译包、没有 android；但 bionic 的 flock(2) 是好的
    （实测争用返回 EWOULDBLOCK=11），build-flock.sh 已经为 android-arm64 真编了一份。
    这里只需把平台闸门放开；android 不加 glibc/musl 子目录，正好落在 bin/system.node。

    这一步必须和 build-flock.sh 配套：只放开闸门而不编插件，会变成 require 不到的
    MODULE_NOT_FOUND —— 比原来的报错更难查。
    """
    once(os.path.join(DSH, "node_modules", "@deepseek-ai", "node-addon-system",
                      "lib", "flock.js"),
         "if (platform !== 'linux' && platform !== 'darwin') {",
         "// termux-android-flock: bionic 的 flock(2) 可用，插件已由 build-flock.sh 本地编译。\n"
         "    if (platform !== 'linux' && platform !== 'darwin' && platform !== 'android') {",
         "termux-android-flock", dry)


def _eacc(var):
    """返回「不是 EACCES」的判断式，便于写成 `if (…) throw`。"""
    return ('!(%s instanceof Error && "code" in %s && %s.code === "EACCES")'
            % (var, var, var))


def patch_links(dry=False):
    """④⑤⑥ Android 禁止 link(2)（EACCES 实测），三处调用点各自的等价替换。

    不能一律 rename —— 三个调用点的语义不一样：
      · 会话日志发布：源是临时名，rename 等价且更省（消费掉临时名）
      · 新建文件的 no-replace：必须在 rename 前自己确认「目标不存在」，
        否则会把「拒绝覆盖已有文件」的语义悄悄变成「覆盖」
      · 附件别名：源是已存在的对象，rename 会把它搬走 —— 必须用 copyFile(EXCL)
    """
    SP = os.path.join(DSH, "node_modules", "@deepseek-ai",
                      "dsh-session-persistence-jsonl", "lib", "index.js")
    FL = os.path.join(DSH, "node_modules", "@deepseek-ai",
                      "dsh-fs-local", "lib", "index.js")
    AT = os.path.join(DSH, "node_modules", "@deepseek-ai",
                      "dsh-attachment-local", "lib", "index.js")

    # 会话持久化：日志文件发布用的是 link
    once(SP,
         'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, '
         'realpath, rm, stat, truncate } from "node:fs/promises";',
         'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, '
         'realpath, rename, rm, stat, truncate } from "node:fs/promises";',
         "termux-link-import", dry)
    once(SP, "\tlink,\n\trm: (path) => rm(path, { force: true })",
         "\tlink,\n\trename,\n\trm: (path) => rm(path, { force: true })",
         "termux-link-fs-default", dry)
    once(SP, "await internals.fs.link(staged, currentPath);",
         "try {\n"
         "\t\t\tawait internals.fs.link(staged, currentPath);\n"
         "\t\t} catch (linkError) {\n"
         "\t\t\t/* termux-link-publish: Android 拒绝 link(2)（EACCES）。\n"
         "\t\t\t   源是临时名，同目录 rename 同样原子，并顺带消费掉临时名。 */\n"
         "\t\t\tif (" + _eacc("linkError") + ") throw linkError;\n"
         "\t\t\tawait internals.fs.rename(staged, currentPath);\n"
         "\t\t}",
         "termux-link-publish", dry)
    once(SP, "await link(tmp, finalPath);",
         "try {\n"
         "\t\t\t\tawait link(tmp, finalPath);\n"
         "\t\t\t} catch (linkError) {\n"
         "\t\t\t\t/* termux-link-materialize: 同上；tmp 随后被 rm(force)，rename 消费掉也无妨。 */\n"
         "\t\t\t\tif (" + _eacc("linkError") + ") throw linkError;\n"
         "\t\t\t\tawait rename(tmp, finalPath);\n"
         "\t\t\t}",
         "termux-link-materialize", dry)

    # 新建文件：link 提供的是「目标不存在」的原子保证，用「先看再 rename」复现
    once(FL, "await linkFile(tempPath, absolutePath);",
         "try {\n"
         "\t\t\t\tawait linkFile(tempPath, absolutePath);\n"
         "\t\t\t} catch (linkError) {\n"
         "\t\t\t\t/* termux-link-create: Android 拒绝 link(2)（EACCES）。\n"
         "\t\t\t\t   link 的 no-replace 语义用「目标不存在才 rename」复现：\n"
         "\t\t\t\t   目标在就抛 EEXIST，交给外层的 throwGuardedCreateFailure 报 FS_NOT_OBSERVED。 */\n"
         "\t\t\t\tif (" + _eacc("linkError") + ") throw linkError;\n"
         "\t\t\t\tlet existing;\n"
         "\t\t\t\ttry {\n"
         "\t\t\t\t\texisting = await inspectPublicationTarget(absolutePath);\n"
         "\t\t\t\t} catch (metadataError) {\n"
         "\t\t\t\t\tif (!isENOENT(metadataError) && !isENOTDIR(metadataError)) throw metadataError;\n"
         "\t\t\t\t}\n"
         "\t\t\t\tif (existing !== void 0) throw Object.assign(new Error(\"publication target already exists\"), { code: \"EEXIST\" });\n"
         "\t\t\t\tawait rename(tempPath, absolutePath);\n"
         "\t\t\t}",
         "termux-link-create", dry)

    # 附件：别名场景的源必须保留 → copyFile；暂存发布场景 → rename
    # 注意 constants 已在该文件第 6 行从 node:fs 导入，直接用即可，不再加第二条 import。
    once(AT,
         'import { chmod, link, mkdir, open, readFile, rename, rm, unlink, '
         'writeFile } from "node:fs/promises";',
         'import { chmod, copyFile, link, mkdir, open, readFile, rename, rm, '
         'unlink, writeFile } from "node:fs/promises";',
         "termux-link-attach-import", dry)
    once(AT, "await link(source, target);",
         "try {\n"
         "\t\t\t\tawait link(source, target);\n"
         "\t\t\t} catch (linkError) {\n"
         "\t\t\t\t/* termux-link-alias: 这里 target 是**新增**的一个名字，source 必须留着。\n"
         "\t\t\t\t   rename 会把 source 搬走 —— 只能用 copyFile，且带 EXCL 保住 EEXIST 语义。 */\n"
         "\t\t\t\tif (" + _eacc("linkError") + ") throw linkError;\n"
         "\t\t\t\tawait copyFile(source, target, constants.COPYFILE_EXCL);\n"
         "\t\t\t}",
         "termux-link-alias", dry)
    once(AT, "await link(staged.path, target);",
         "try {\n"
         "\t\t\t\tawait link(staged.path, target);\n"
         "\t\t\t} catch (linkError) {\n"
         "\t\t\t\t/* termux-link-attach-publish: 源是暂存名，rename 等价。 */\n"
         "\t\t\t\tif (" + _eacc("linkError") + ") throw linkError;\n"
         "\t\t\t\tawait rename(staged.path, target);\n"
         "\t\t\t}",
         "termux-link-attach-publish", dry)
    once(AT, "await unlink(staged.path);",
         "await unlink(staged.path).catch((cleanupError) => {\n"
         "\t\t\t/* termux-link-attach-unlink: 走 rename 兜底后暂存名已被消费，容忍 ENOENT。 */\n"
         "\t\t\tif (!(cleanupError instanceof Error && \"code\" in cleanupError && cleanupError.code === \"ENOENT\")) throw cleanupError;\n"
         "\t\t});",
         "termux-link-attach-unlink", dry)


def patch_internals(dry=False):
    """② app-boot 的 internalModules() 不再强制依赖那个原生插件。

    internalModules() 要 5 个内部模块；原实现无条件 require 原生插件，
    插件在 android-arm64 上必然找不到绑定 → boot 直接 fatal。
    """
    for sub in ("lib/index.js", "lib/worker/profile-resolution-bootstrap.js"):
        once(os.path.join(DSH, "node_modules", "@deepseek-ai", "dsh-app-boot", sub),
             ANCHOR_ADDON, REPLACE_ADDON, "termux-expose-internals", dry)


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


# ---------------------------------------------------------------- 主流程

def run_all(dry=False):
    """按固定顺序跑全部补丁。dry=True 时只判定不写盘。"""
    patch_shebang(dry)
    patch_internals(dry)
    patch_flock(dry)
    patch_links(dry)
    patch_lan_settings(dry)


def reset():
    for lst in (FAIL, SKIP, DONE, CHANGES):
        del lst[:]


def file_status():
    """按文件聚合状态：{相对路径: 状态}。

    直接复用真实补丁逻辑的判定结果，不再维护一份「期望 marker 表」——
    那张表只要有补丁的替换文本不带 marker 就会永远报不准（本项目里就有 3 条
    这类「插入裸标识符」的补丁），而且会随补丁增删而漂移。
    """
    st = {}
    for p in DONE:
        st[p] = "待打"
    for p in SKIP:
        st[p] = "已打"
    for f, _why in FAIL:
        st[f] = "异常"
    return st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(DSH):
        print("找不到 dsh 安装目录：%s" % DSH)
        return 2
    if not os.path.exists(NODE_BIN) and not args.list:
        print("找不到 node：%s" % NODE_BIN)
        return 2

    if args.list:
        print("dsh 安装目录：%s" % DSH)
        print("备份目录：    %s" % BACKUP)
        print("（下面是空跑一遍真实补丁逻辑得到的判定，不写盘）")
        reset()
        run_all(dry=True)
        st = file_status()
        if not st:
            print("  （没有任何补丁命中任何文件 —— dsh 装了没？）")
        width = max(len(k) for k in st)
        for p in sorted(st):
            print("  [%s] %-*s" % (st[p], width, p))
        if FAIL:
            print()
            for f, why in FAIL:
                print("  ⚠ %s —— %s" % (f, why))
        return 0

    print("=== 打补丁%s ===" % ("（dry-run，不写盘）" if args.dry_run else ""))
    run_all(args.dry_run)

    for p in CHANGES:
        print("  改  %s" % p)
    for p in SKIP:
        print("  跳过 %s（已打过）" % p)
    for f, why in FAIL:
        print("  失败 %s —— %s" % (f, why))

    print()
    if FAIL:
        print("❌ 有 %d 条补丁没打成 —— 上游代码可能变了，请人工看一眼再决定。"
              % len(FAIL))
        return 1
    print("✅ 补丁完成：改动 %d 处，跳过 %d 处" % (len(DONE), len(SKIP)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
