# termux_dsh

在 Android / Termux 上把 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)（DeepSeek Harness）
从「**装得上但起不来**」补成可用状态，并给它配一个局域网 **8030 控制台**（反向代理 + 接口/密钥管理面板）。

dsh 本体是为 glibc Linux / macOS / Windows 构建的，在 Android 上会连续撞上四堵墙：原生插件没有
`android-arm64` 预编译、`link(2)` 被内核拒绝、`flock` 平台闸门、以及非 loopback 地址下客户端把自己
判成"非本机"。本仓库是逐条拆墙的完整实现 —— **dsh 业务逻辑一行没改，14 处改动全是平台适配**。

---

## 目标形态

| 形态 | 入口 | 用途 |
|---|---|---|
| 控制台 | `http://<LAN-IP>:8030/` | 服务状态 / 模型后端 / 接口与密钥 / 自检 / **装·修·升·卸 dsh** |
| dsh 主界面 | `http://<LAN-IP>:8030/app` | 经网关带令牌进入，手机浏览器里的主力形态 |
| 裸转发 | `http://<LAN-IP>:3080/` | 只做 TCP 转发，不带控制面 |
| 本机 | `http://127.0.0.1:3080/` | Termux 终端里由 `dsh-web-url` 直接给出带令牌 URL |

> 文中出现的 `192.168.3.190` / `u0_a383` 是开发时的设备取值，换成自己的即可。

---

## 目录结构

仓库按「**部署到设备的落点**」分组，每条都能一眼看出推到哪里。

| 仓库路径 | 设备落点 | 说明 |
|---|---|---|
| `bin/dsh-ctl-gateway` | `$PREFIX/bin/` | 8030 网关：反向代理（HTTP + WebSocket 透传到 3080）+ 控制面 `/ctl/api/*` |
| `bin/dsh-set-provider` | `$PREFIX/bin/` | 接口（provider）写入器：`--sites-file`「一接口多密钥」，幂等，带顶层 `[]` 哨兵 |
| `bin/dsh-set-key` | `$PREFIX/bin/` | 给 `dsh-web` 注入模型密钥（写 runit `environment` + 重启 + 真调一次 API 验证） |
| `bin/dsh-web-url` | `$PREFIX/bin/` | 打印访问 URL：`--gw` / `--app` / `--lan` / `--all` |
| `bin/dsh-patch-lan-settings` | `$PREFIX/bin/` | 给客户端 bundle 打 `isLoopback` 补丁，否则局域网下设置页报 `settings are unavailable` |
| `bin/dsh-lan-ip` | `$PREFIX/bin/` | 取本机局域网 IPv4（Termux 上 `ip` / `hostname -I` / `getprop` 全不灵） |
| `bin/dsh-lan-gateway` | `$PREFIX/bin/` | 裸 TCP 转发层（dsh 拒绝直接绑 `0.0.0.0`） |
| `bin/verify-hot-reload.sh` | `$PREFIX/bin/` | 验证「改配置是否即时生效」，见下文 |
| `share/dsh-ctl/panel.html` | `$PREFIX/share/dsh-ctl/` | 8030 控制台页面（单文件，无构建步骤） |
| `runit/dsh-ctl-run` | `$SVDIR/dsh-ctl/run` | 服务 `dsh-ctl`：`<LAN-IP>:8030` |
| `runit/dsh-lan-run` | `$SVDIR/dsh-lan/run` | 服务 `dsh-lan`：`<LAN-IP>:3080` |
| `install/install.sh` | 推 `$TMPDIR` 执行 | 入口：打 JS 补丁 / 体检（`--check`） |
| `bootstrap.sh`（仓库根） | curl 管道执行，不落地 | **一键入口**：从 GitHub raw 拉源 → 构建 `install-gateway.sh` → 执行（见「快速开始 · 0」） |
| `install/uninstall.sh` | 同上 | install.sh 的逆操作（幂等）：`-n` 预演，默认保留 `~/.dsh` / dsh 包，`--all` 全拆 |
| `install/patches.py` | 推 `$TMPDIR` 执行；**同时**落 `$PREFIX/share/dsh-ctl/` | 幂等补丁器，14 处改动带 marker，npm 升级后重跑即可 |
| `install/build-flock.sh` | 推 `$TMPDIR` 执行；**同时**落 `$PREFIX/share/dsh-ctl/` | `clang -shared` 直编 `system.node`，**绕开 node-gyp**（它在 Termux 上编不出来） |
| `install/install-web-service.sh` | 同上 | 装 `dsh-web` runit 服务 |
| `install/install-lan.head.sh` + `build-install-lan.py` | → 生成 `install-lan.sh` | 装 `dsh-lan` 裸转发 |
| `install/install-ctl.head.sh` + `build-install-ctl.py` | → 生成 `install-ctl.sh` | 装 8030 网关 + 控制台（幂等，含 200+ 行断言） |
| `install/install-gateway.head.sh` + `build-install-gateway.py` | → 生成 `install-gateway.sh` | **网关优先入口**：单文件装网关 + 控制台 + 生命周期四件套；dsh 本体留给控制台装 |
| `install/install-key-path.sh` / `install-provider-tools.sh` | 同上 | 密钥通路 / 工具升级 |
| `install/merge-patch-into-patcher.sh` / `tighten-pid-detect.sh` | 同上 | 把一次性改动并入补丁器 / 收紧进程识别 |
| `tests/` | 本机 | 面板静态自检 + 真浏览器交互断言 + 假后端预览 |
| `docs/CHANGELOG.md` | 本机 | 装了什么、改了什么、为什么缺一不可（因果链） |
| `docs/SKILL.md` | 本机 | 完整 playbook（含每个坑的判据与误判陷阱） |
| `docs/probes/` | 本机 | 一次性探针脚本，逆向过程留档 |
| `docs/shots/` | 本机 | 界面截图留档 |

---

## 快速开始

### 0. 一键 curl（最省事）

Termux 里只要 `pkg install curl python`，然后一行：

    curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash

它从 GitHub raw 拉源文件、当场构建 `install-gateway.sh` 并执行 —— 落网关、起 8030、
打印控制台地址（相当于自动完成下面 A 的第 1、2 步）。指定分支 / tag / commit：行尾加
`bash -s <ref>`。之后照 A 的第 3、4 步在浏览器里装 dsh、走生命周期。

为什么不直接下载现成安装器：`install-gateway.sh` 是生成物，按项目规矩不入版本库
（改了 payload 忘重建、产物里长期内联旧版本的亏吃过）；bootstrap 拉源当场构建，
永远和仓库一致。raw 网络不通时的备选：`git clone` 后在仓库里跑同一条命令（失败时
脚本会提示）。

### A. 网关优先（推荐）

先装「入口」，再在浏览器里装 dsh 本体 —— 哪怕 dsh 还没有，8030 上已经有一个能点的地方。

前提：Termux 里 `pkg install nodejs-lts python curl termux-services`（`termux-services` 装完
重开 Termux，让 `runsvdir` 起来）。**dsh 本体不用手动 npm 装**，控制台会装。

```bash
# 1) 在任意能跑 python3 的机器上（本机即可），生成单文件安装器
python3 install/build-install-gateway.py      # → install/install-gateway.sh

# 2) 推到设备执行（scp / adb push / 任意方式；脚本幂等，可重复跑）
scp install/install-gateway.sh <设备>:~/
ssh <设备> 'bash ~/install-gateway.sh'
#    → 落 9 个工具 + 面板 + 生命周期四件套 → 起 dsh-ctl 服务 → 打印控制台地址
#    旧文件会被备份到 ~/dsh-termux/backups/，现有 ~/.dsh 配置原样保留

# 3) 浏览器打开 http://<LAN-IP>:8030/ 就是控制台（路由器模型：不问令牌、不问登录）
#    → 选通道（latest / next / alpha）或手填版本 →「开始安装」，进度实时滚
#    → 装完打开 http://<LAN-IP>:8030/app 就是 dsh 主界面（自动登录，见下）

# 4) 之后的全生命周期都在控制台里：修复 / 更新 / 卸载，SSH 都不用开
```

控制台是**路由器模型**：局域网内任何设备打开 8030 就是管理界面（像路由器后台一样），
`state` / `install` / `repair` / `uninstall` / `jobstatus` / `dshcheck` / `dshupgrade` /
`log` / `restart` 这些生命周期接口不用任何凭据。**改配置类的接口（`save` 等）一律 401** ——
要先登录 dsh，cookie 就对网关这个地址生效；登录态下 `state` 才返回明文密钥，未登录只给掩码。

`/app`（dsh 主界面）同样不用贴令牌链接：浏览器没 cookie 时网关自取 dsh 的登录
令牌补上（302 → dsh 按 authority 种 cookie → 落回干净的 `/app`），有 cookie
就直接取首页。手机本机直接开 `http://127.0.0.1:8030/` 也行 —— 网关在局域网
IP 与 loopback 上各有一个监听（WiFi 没连都能用）。

> **dsh-lan 不用装**：它是无网关方案的局域网入口（`<lan-ip>:3080` 裸转发
> + 注入 `--trusted-host`）。网关方案里这两件事 8030 与 `install-web-service.sh`
> 已经做了，控制台服务卡里 `dsh-lan: 未安装` 是正常状态。

### B. 手工路径（不想用控制台）

```bash
# 前提：pkg install nodejs-lts clang make python git，然后 npm i -g @deepseek-ai/dsh
# 1) 把 install/ 整个推到设备（scp 或任意方式），在设备上执行
cd $TMPDIR/install
bash install.sh            # 打 JS 补丁；--flock 顺便编原生模块，--check 只体检

# 2) 起 dsh-web 服务（127.0.0.1:3080）
bash install-web-service.sh

# 3) 要局域网访问，再装转发层（两个都幂等）
python3 build-install-lan.py && bash install-lan.sh    # <LAN-IP>:3080 裸转发
python3 build-install-ctl.py && bash install-ctl.sh    # <LAN-IP>:8030 网关 + 控制台

# 4) 取访问地址
dsh-web-url --all

# 5) 卸载（install.sh 的逆操作，幂等）
bash uninstall.sh -n          # 预演：只列清单，一个字节都不动（先跑这个）
bash uninstall.sh             # 交互确认后卸 服务 + 工具 + 面板（默认保留 ~/.dsh / dsh 包）
bash uninstall.sh -y --all    # 全拆：连 dsh 包 / 用户数据 / 工作目录
```

生成的 `install-gateway.sh` / `install-ctl.sh` / `install-lan.sh` 都是**单文件、可直接 bash
执行、幂等** —— 内联 base64 是为了一次传输不失真。**注意它们由 `.head.sh` + `build-*.py`
生成，不入版本库**（曾经发生过：改了 `bin/dsh-web-url` 却忘了重建，`install-lan.sh` 里
长期内联着旧版本。所以产物一律现生成）。

卸载脚本的默认层只删 termux_dsh 自己装的东西（服务 / 工具 / 面板），**用户数据、补丁备份、
工作目录、dsh npm 包一律保留** —— 和升级链同一个原则：可以失败回滚，但用户数据不丢；要彻底
清掉用 `--all`。什么都不剩时再跑会报「没有可卸载的东西」并退出 0。
控制台里也能卸（「卸载」按钮 = 后台 detached 跑同一个 `uninstall.sh`，
网关被杀也会在重启后靠落盘的 job 对账结案），见下文第十、十二节。

---

## 测试

```bash
# 面板静态自检（语法 / 函数遮蔽 / onclick 与 id 引用 / 已删元素残留）
node tests/audit-panel.js share/dsh-ctl/panel.html       # 期望 ✗ = 0

# 假后端预览：只读，state/health/models 全是假数据，不碰设备
node tests/preview-panel.js            # http://127.0.0.1:8877

# 真浏览器交互断言（headless chromium 驱动假后端）
node tests/test-panel-ui.js            # 期望「失败 0 项」（当前 135 项）

# 设备上：验证「改配置是否需要重启」
bash $PREFIX/bin/verify-hot-reload.sh

# 卸载脚本：造假树（假 $PREFIX + 假 $HOME + sv/npm 桩脚本）真跑 rm -rf
bash tests/test-uninstall.sh          # 期望「失败 0 项」（67 项断言）

# 网关 + 生命周期：假树 + 假上游 node，真跑安装 / 修复 / 卸载 job（令牌鉴权、
# 并发拒绝、回滚、卸载 detached + 杀网关重启的 job 落盘恢复、完成态保留、登录撤销令牌）
bash tests/test-gateway.sh            # 期望「失败 0 项」（68 项断言，约 20 秒）
```

`test-panel-ui.js` 需要浏览器：装了 `playwright` 包就直接跑；只装 `playwright-core` 时用
`CHROME_PATH=/path/to/chrome` 指定，或让它自己扫 `~/Library/Caches/ms-playwright`（macOS）/
`~/.cache/ms-playwright`（Linux）。

---

## 三条最容易踩的实测结论

### 1. 「保存并重启」里的重启对配置多余、对密钥必需

| 改什么 | 落到哪 | 需要重启吗 | 实测延迟 |
|---|---|---|---|
| 接口地址 / 协议 / 模型 / 显示名 / 启用切换 | `~/.dsh/profiles/web/cordis.patch.yml` | **不需要** | **约 2.3 秒** |
| 面板里新填的密钥值 | `$PREFIX/var/service/dsh-web/environment` | **必须** `sv restart dsh-web` | 启动期注入，不重启永不生效 |

前者由 dsh 自带的 `@deepseek-ai/dsh-hmr`（chokidar 监听 profile patch，`awaitWriteFinish` 2s +
debounce 100ms）负责，正好对上实测的 2275–2367 ms。后者走 runit 的 `environment`，`./run` 启动期
`set -a; . environment` 注入，运行中进程的 environ 不会因文件改动而更新。

**判据不要用日志**：HMR 成功路径**一行日志都不打**（源码里只有 `warnings` 才 `logger.warn`）。
注入「不存在的插件包」「非法 YAML」「重复 id」三种探针，`svlogd` 全静默、PID 不变 —— 很容易误判成
"完全没反应"。正确做法是**直接问运行中的进程**：

```bash
curl -s -b cookie.jar -X POST -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"1","method":"llm/listProviders","payload":{"args":{}}}' \
  http://127.0.0.1:3080/api/llm/listProviders
```

`method` 必须写端点全名（写 `listProviders` 会 400），`payload` 必须含且仅含一个 plain-object `args`。
同族端点：`/api/session/modelCatalog`、`/api/settings/describe`、`/api/credentials/describe`。

### 2. `sed -i` 会换 inode

所以「进程 watch 的 ino == 文件 ino」这种判据会假否 —— chokidar 靠目录事件重新注册。
**用行为判定，别用 inode。**

### 3. 更新 dsh = 装包 **加** 重打补丁，少一步服务就起不来

控制台右上角「服务与运行环境」卡片里有版本行：`检查更新` 只读，`更新到 x.y.z` 才是写操作。

关键事实：**`npm install -g @deepseek-ai/dsh` 会把整个包目录换成官方版** —— 那 14 处 Termux 补丁
（打在 `node_modules` 里的源码上）全部丢失，本地编译的 `flock` 原生插件 `system.node` 也没了。
只装包不补补丁，服务直接起不来。所以升级是一条固定的五步链：

| 步 | 做什么 | 失败会怎样 |
|---|---|---|
| 0 | **改名备份**整个 `@deepseek-ai` 作用域目录 | — |
| 1 | `npm install -g @deepseek-ai/dsh@<目标版本>` | 回滚 |
| 2 | `python3 $PREFIX/share/dsh-ctl/patches.py`（幂等，带锚点断言） | 回滚 |
| 3 | `flock` 原生插件缺了就 `build-flock.sh` 现编 | 继续（只影响那条子系统） |
| 4 | `sv restart dsh-web` + `dsh --version` 复验 | 回滚 |

**上游改了被补丁的文件 → 补丁器的锚点断言会失败（退出码 1）→ 自动回滚**。这是刻意设计：
宁可不升，也不留一个起不来的 dsh。

**回滚用 `mv` 不用 `cp`**：包目录 300MB 级，`cp -a` 要几十秒，`mv` 是瞬时的（同文件系统改名）。
先把旧的改名挪走、装新的，失败就把新的删掉、旧的改回来。

**查版本不走 `npm view`**，直接打 registry 的**小端点** `/-/package/@deepseek-ai%2Fdsh/dist-tags`
（几百字节，实测 0.9 秒；整包文档是几百 KB）。官方源失败自动退 `registry.npmmirror.com`。

**「远端版本」不等于「更新」**：切到 `alpha` 通道时远端可能**比本机旧**（实测本机 `0.2.0-rc.2`、
alpha 是 `0.1.7-alpha.2`）。面板会按 semver 粗比把按钮改成「**回退到** …」，别一律写「更新」。

**0.2.0+ 装包时要现编 `koffi`，两件事都得有**（缺一件就装不上，见 CHANGELOG §8.8）：

1. 设备要有 `cmake` + `ninja`：`pkg install -y cmake ninja`；
2. 编译标志必须带 `--target=aarch64-unknown-linux-android30 -D_GNU_SOURCE`
   （网关已经在装包那一步自动带上，不用手动配）。原因是 bionic 把 `statx()` 藏在
   `#if defined(__USE_GNU) && __BIONIC_AVAILABILITY_GUARD(30)` 后面，少任一条
   `statx(fd, …)` 里的 `statx` 就被当成**类型**，报错是
   `cannot initialize a member subobject of type '__u32' with an lvalue of type 'const char *'`
   —— **看着像参数类型写错，其实是函数没声明**。

**升级成功后备份目录会留着**（`@deepseek-ai.bak-<ts>`，实测 305 MB），网关不自己删。
确认新版没问题后手动清理：`rm -rf $PREFIX/lib/node_modules/@deepseek-ai.bak-*`。

---

## 安全边界

- dsh 官方**显式拒绝** `--host 0.0.0.0`（原文：*intentionally not supported yet for safety*），
  因为这个 Web UI 等于远程代码执行入口。所以对外只暴露网关，dsh 本体始终只听 `127.0.0.1`。
- 8030 网关复用 dsh 自己的登录 cookie，不额外设口令 —— **只应放在可信局域网**。
  不要直接暴露到公网；要远程用就走 SSH 隧道。
- 开发时用的推文件脚本（`ssh_helper` / `scp_push`）含设备口令，**不在本仓库内**。

---

## 文档

- [docs/CHANGELOG.md](docs/CHANGELOG.md) —— 装了什么、改了什么、每一处改动的因果链
- [docs/SKILL.md](docs/SKILL.md) —— 完整 playbook：四类不兼容的锚点与语义、每类报错的判据、
  以及会让人误判的坑（局部变量遮蔽函数名、`-d "${V:-{}}"`、断言只覆盖实现不覆盖体验……）
- [docs/probes/](docs/probes/) —— 一次性探针脚本留档
