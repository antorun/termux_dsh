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
| 控制台 | `http://<LAN-IP>:8030/` | 服务状态 / 模型后端 / 接口与密钥 / 自检 |
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
| `install/patches.py` | 推 `$TMPDIR` 执行；**同时**落 `$PREFIX/share/dsh-ctl/` | 幂等补丁器，14 处改动带 marker，npm 升级后重跑即可 |
| `install/build-flock.sh` | 推 `$TMPDIR` 执行；**同时**落 `$PREFIX/share/dsh-ctl/` | `clang -shared` 直编 `system.node`，**绕开 node-gyp**（它在 Termux 上编不出来） |
| `install/install-web-service.sh` | 同上 | 装 `dsh-web` runit 服务 |
| `install/install-lan.head.sh` + `build-install-lan.py` | → 生成 `install-lan.sh` | 装 `dsh-lan` 裸转发 |
| `install/install-ctl.head.sh` + `build-install-ctl.py` | → 生成 `install-ctl.sh` | 装 8030 网关 + 控制台（幂等，含 200+ 行断言） |
| `install/install-key-path.sh` / `install-provider-tools.sh` | 同上 | 密钥通路 / 工具升级 |
| `install/merge-patch-into-patcher.sh` / `tighten-pid-detect.sh` | 同上 | 把一次性改动并入补丁器 / 收紧进程识别 |
| `tests/` | 本机 | 面板静态自检 + 真浏览器交互断言 + 假后端预览 |
| `docs/CHANGELOG.md` | 本机 | 装了什么、改了什么、为什么缺一不可（因果链） |
| `docs/SKILL.md` | 本机 | 完整 playbook（含每个坑的判据与误判陷阱） |
| `docs/probes/` | 本机 | 一次性探针脚本，逆向过程留档 |
| `docs/shots/` | 本机 | 界面截图留档 |

---

## 快速开始

前提：Termux 里 `pkg install nodejs-lts clang make python git`，然后 `npm i -g @deepseek-ai/dsh`。

```bash
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
```

生成的 `install-ctl.sh` / `install-lan.sh` 是**单文件、可直接 bash 执行、幂等** —— 内联 base64 是为了
一次传输不失真。**注意它们由 `.head.sh` + `build-*.py` 生成，不入版本库**（曾经发生过：改了
`bin/dsh-web-url` 却忘了重建，`install-lan.sh` 里长期内联着旧版本。所以产物一律现生成）。

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
