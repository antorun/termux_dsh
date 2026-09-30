# 让 dsh 在 Termux 上跑起来：装了什么、改了什么

> **路径说明**：本文档较早期的段落写的是 `.remote/xxx`（当时所有脚本都堆在一个隐藏目录里）。
> 2026-09-30 仓库按用途重组为 `bin/` `share/` `install/` `tests/` `docs/`，正文路径已就地更新。
> 例外：第 228 行那棵 `~/dsh-termux/` 目录树描述的是设备上的实际落点，保持原样。

盘点时间：2026-09-30 09:20 GMT+8
设备：Android 16 / aarch64 / Termux（`u0_a383@192.168.3.190:8022`）
目标：`@deepseek-ai/dsh` **0.1.7-rc.2**

一句话结论：**dsh 本体一行没动逻辑，只动了 8 个文件的 14 处（全是 Android 平台适配），
外加在 Termux 侧补了 1 个本地编译的原生模块、8 个自用可执行文件、3 个 runit 服务。**
上游 npm 包升级后这些改动会全部丢失，需要重跑补丁器。

---

## 一、装了什么

### 1.1 Termux 系统包（为编译原生模块准备的）

| 包 | 版本 | 用途 |
|---|---|---|
| `nodejs-lts` | 24.18.0-1 | 运行 dsh（Node 24） |
| `clang` | 21.1.8-3 | **编译 flock 原生模块**（见 1.3） |
| `make` | 4.4.1-1 | 编译链 |
| `python` | 3.14.6-1 | 跑 `patches.py` |
| `git` | 2.55.0 | 取源码/工具 |

### 1.2 npm 全局包

只有 `@deepseek-ai/dsh`（`$PREFIX/lib/node_modules/@deepseek-ai/dsh`）。
`$PREFIX/bin/dsh` 是 **符号链接** → `../lib/node_modules/@deepseek-ai/dsh/lib/bin.js`
（所以补丁 ① 改 `lib/bin.js` 的 shebang，就等于改好了 `dsh` 这条命令）。

### 1.3 本地编译的原生模块（关键）

| 产物 | 大小 | 来源 |
|---|---|---|
| `@deepseek-ai/node-addon-system-android-arm64/bin/system.node` | 11776 B | **本地 clang 编的**（`~/dsh-termux/build-flock.sh`） |
| `node-pty/build/Release/pty.node` | 64472 B | **安装时现场编的**（`node-pty` 只有 linux/darwin/win 预编译，没有 android） |

`build-flock.sh` 的关键决策：**绕开 node-gyp**。
Termux 上 npm ≥ 11.10 自带的 node-gyp ≥ 12.3 会因 `process.config` 解析失败而编不出来，
而这个模块只是一层 POSIX `flock` 的薄封装，所以直接：

```sh
clang -shared -fPIC … -o "$PKG/bin/system.node"
```

并手写 `@deepseek-ai/node-addon-system-android-arm64/package.json`（`"main": "bin/system.node"`）。
android 不加 `glibc`/`musl` 子目录，正好落在 `bin/system.node` —— 和模块里原有的平台探测逻辑天然吻合。

实测：`require(…) /lib/flock.js` → **成功**，导出 `tryLockExclusive`。

### 1.4 自己写的可执行文件（`$PREFIX/bin/`）

| 文件 | 大小 | 作用 |
|---|---|---|
| `dsh-web-url` | 4272 B | 从日志里取**当前**令牌 URL（令牌每次启动都变）；`--gw` 网关首页、`--app` 网关内的 dsh 主界面、`--lan` 裸转发、`--all`、`--open`、`--tunnel` |
| `dsh-lan-ip` | 1463 B | 取局域网 IP（`SSH_CONNECTION` 优先，否则解析无参 `ifconfig`） |
| `dsh-lan-gateway` | 4240 B | 裸 TCP 转发：`<lan-ip>:3080` → `127.0.0.1:3080` |
| `dsh-ctl-gateway` | 30700 B | **8030 反向代理 + 控制台**（`/` 是控制台、`/app` 是 dsh 主界面、`/ctl/api/*` 是接口） |
| `dsh-set-key` | 6123 B | 往 runit 服务的 `environment` 里合并写入 API key（幂等） |
| `dsh-set-provider` | 16171 B | 一键切模型后端（预置/自定义、写 `cordis.patch.yml`、组合校验、失败回滚） |
| `dsh-patch-lan-settings` | 2953 B | 单点：给客户端 bundle 打 `isLoopback` 补丁（补丁 ⑤ 的独立入口） |

另有一份页面 `$PREFIX/share/dsh-ctl/panel.html`（15957 B）供 8030 控制台渲染。

### 1.5 runit 服务（termux-services，三个都带 svlogd 日志）

| 服务 | 监听 | 启动命令 |
|---|---|---|
| `dsh-web` | `127.0.0.1:3080` | `node --expose-internals $PREFIX/bin/dsh web --port 3080 --no-open --trusted-host 192.168.3.190` |
| `dsh-lan` | `<lan-ip>:3080` | `dsh-lan-gateway`（裸 TCP） |
| `dsh-ctl` | `<lan-ip>:8030` | `dsh-ctl-gateway auto 8030 127.0.0.1 3080` |

三者都没有 `down` 文件（= 开机自启）。`dsh-lan` / `dsh-ctl` 可以单独 `sv down` 而不影响 `dsh-web`。

---

## 二、改了 dsh 源码的哪些地方（8 文件 / 14 处）

补丁器：`~/dsh-termux/patches.py`（幂等，`--list` 只判定不写盘）。
原件备份：`~/.dsh-termux-backup/orig/`（按相对路径镜像，重跑不覆盖真原件）。

### ① 启动加 `--expose-internals`（1 处）

- 文件：`lib/bin.js` 第 1 行

```
- #!/data/data/com.termux/files/usr/bin/node
+ #!/data/data/com.termux/files/usr/bin/node --expose-internals
```

**为什么**：Android 上没有 `node-addon-require-builtin` 的预编译包，而 dsh 需要拿
Node 内部模块（`internal/modules/esm/loader` 等）。这些只有带 `--expose-internals` 才 require 得到。
`NODE_OPTIONS` 里塞不进去（Node 明确拒绝该标志走环境变量），只能写在 shebang 上。

### ② 让 `internalModules()` 不再强制依赖那个原生插件（2 处）

- 文件：`@deepseek-ai/dsh-app-boot/lib/index.js`
- 文件：`@deepseek-ai/dsh-app-boot/lib/worker/profile-resolution-bootstrap.js`

```
- const addon = createRequire(import.meta.url)("node-addon-require-builtin");
+ const addon = process.execArgv.includes("--expose-internals")
+     ? { requireBuiltin: (id) => createRequire(import.meta.url)(id) }
+     : createRequire(import.meta.url)("node-addon-require-builtin");
```

**为什么**：原实现**无条件** require 那个插件，插件在 android-arm64 上必然找不到绑定 →
boot 直接 fatal（`No usable native binding found for node-addon-require-builtin-android-arm64`）。
有了 ① 的标志就走前三元分支，不碰插件；非 Android 平台行为零变化。
`@deepseek-ai/node-addon-require-builtin` 至今仍是**缺失**状态 —— 这是预期的。

### ③ 放开 `flock` 的平台闸门（1 处）

- 文件：`@deepseek-ai/node-addon-system/lib/flock.js`

```
- if (platform !== 'linux' && platform !== 'darwin') {
+ if (platform !== 'linux' && platform !== 'darwin' && platform !== 'android') {
```

**为什么**：模块自带 linux/darwin 预编译、没有 android，但 bionic 的 `flock(2)` 本身是好的
（实测争用返回 `EWOULDBLOCK=11`）。所以只需要放开闸门，配合 1.3 里本地编的那份插件。
**这一步必须和编译配套**：只放开闸门而不编插件，会从「平台不支持」变成更难查的 `MODULE_NOT_FOUND`。

### ④ `link(2)` → 等价替换（9 处，3 个文件）

Android 禁止 `link(2)`（`EACCES`，实测）。三个调用点**语义不同，不能一律 rename**：

**`@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js`（4 处）**

| # | 锚点 | 改法 |
|---|---|---|
| 1 | import 列表 | 加 `rename` |
| 2 | `internals.fs` 默认实现表 | 加 `rename` |
| 3 | `await internals.fs.link(staged, currentPath)` | try/catch → 非 EACCES 抛，否则 `rename` |
| 4 | `await link(tmp, finalPath)` | 同上 |

源是**临时名**，同目录 `rename` 同样原子，还顺带消费掉临时名 —— 等价且更省。

**`@deepseek-ai/dsh-fs-local/lib/index.js`（1 处）**

| 锚点 | 改法 |
|---|---|
| `await linkFile(tempPath, absolutePath)` | try/catch → 先 `inspectPublicationTarget()` 确认目标不存在，再 `rename` |

这里 `link` 提供的是**「目标不存在」的原子保证**（no-replace）。直接 `rename` 会把语义
从「拒绝覆盖」悄悄变成「覆盖」—— 所以必须自己先查一次，存在就抛 `EEXIST`。

**`@deepseek-ai/dsh-attachment-local/lib/index.js`（4 处）**

| # | 锚点 | 改法 |
|---|---|---|
| 1 | import 列表 | 加 `copyFile` |
| 2 | `await link(source, target)` | try/catch → `copyFile(source, target, COPYFILE_EXCL)` |
| 3 | `await link(staged.path, target)` | try/catch → `rename` |
| 4 | `await unlink(staged.path)` | 改成容忍 `ENOENT` |

别名场景的 `source` 是**已存在的对象、必须保留**，`rename` 会把它搬走 —— 只能用
`copyFile` 且带 `COPYFILE_EXCL` 保住 `EEXIST` 语义。第 4 处是配套：走 `rename` 兜底后
暂存名已被消费，原来的 `unlink` 会误报。

### ⑤ 客户端 `isLoopback` 强制为真（1 处）

- 文件：`@deepseek-ai/dsh-client-connection/lib/client.js`（第 1404 行）

```
- isLoopback: transport?.ownsHost === true || pageLocation === void 0
-          || isLoopbackHostname(pageLocation.hostname)
+ isLoopback: true /* dsh-termux-lan */
```

**为什么**：`pageLocation` 就是浏览器的 `location`，经局域网 IP 打开时必然判为 false。
而 `dsh-client-ui-settings` 用它决定设置镜像的持久化模式：

```js
persistence = ctx.remote.$host.isLoopback ? "host" : "memory"
// memory 模式下 SettingsDescribeMirror.load() 直接 return
// → mirrored.view === undefined → 设置页报
//   「加载提供商目录失败: settings are unavailable in this browser」
```

服务端那道 Host/Origin 围栏（`isTrustedApiRequest`）**不受影响**，仍由 `dsh-web` 的
`--trusted-host` 决定，鉴权仍要 cookie。

### 汇总

| 类别 | 文件数 | 编辑处数 |
|---|---|---|
| ① shebang | 1 | 1 |
| ② internalModules | 2 | 2 |
| ③ flock 闸门 | 1 | 1 |
| ④ link(2) 等价替换 | 3 | 9 |
| ⑤ 客户端 isLoopback | 1 | 1 |
| **合计** | **8** | **14** |

`patches.py --list` 当前 8 个文件全部 `[已打]`。

---

## 三、配置与凭据

| 位置 | 内容 |
|---|---|
| `~/.dsh/profiles/web/cordis.patch.yml` | 872 B，`# >>> dsh-provider` 块：插件 `llm-pi-ai`、provider `gateway`、`api: openai-completions`、`baseURL: https://inference.dahl.global/v1`、3 个模型、`agent-default-model` |
| `~/.dsh/profiles/headless/cordis.patch.yml` | 同上（headless 与服务端自检共用同一后端） |
| `$PREFIX/var/service/dsh-web/environment` | 68 B，权限 600，`export DSH_GATEWAY_API_KEY=…` |
| `~/.dsh/.credentials.yaml` | dsh 自身的凭据文件 |
| `~/.dsh/storages/workspace.json` | 工作区状态 |

两个 `cordis.patch.yml` 里的 provider 块**由 `dsh-set-provider` 管理，手改会被下次覆盖**。
当前文件里是**两个数组条目**（`llm-pi-ai` + `agent-default-model`），所以没有独立的 `[]` 行；
但一旦 `dsh-set-provider --clear` 把块摘掉，**必须留一个顶层 `[]`** ——
只有注释没有 `[]` 的 YAML 会解析成 `null` → `overlay 解析失败` → 服务直接 down（实测踩过）。
`dsh-set-provider` 已经内置了这个哨兵逻辑，所以不要手改这个文件。

当前默认模型：`deepseek-ai/DeepSeek-V4-Flash-0731`。

---

## 四、目录与备份

```
~/dsh-termux/                       # 工具与补丁器工作区
├── patches.py                      # 幂等补丁器（--list / --dry-run）
├── build-flock.sh                  # clang 直编 system.node
├── install.sh / install-web-service.sh
├── dsh-set-provider / dsh-set-key
├── dsh-ctl-gateway / dsh-ctl-panel.html / dsh-ctl.run
├── dsh-lan-gateway / dsh-lan-ip / dsh-lan.run
├── dsh-web-url / dsh-patch-lan-settings
└── backups/                        # 脚本自身的版本备份
    ├── client.js.orig              # 客户端 bundle 原文件（59411 B）
    ├── dsh-web-url.<时间戳> ×5
    ├── dsh-web.run.<时间戳>
    ├── run.bak-<时间戳>
    └── patches.py.bak.<时间戳> ×2

~/.dsh-termux-backup/orig/          # 补丁器的原件镜像（按相对路径）
└── node_modules/…

$PREFIX/var/service/{dsh-web,dsh-lan,dsh-ctl}/
├── run                             # 启动脚本（env 在脚本里 export）
└── log/run                         # svlogd → $PREFIX/var/log/sv/<name>/current
```

**注意**：两个备份目录职责不同 —— `~/.dsh-termux-backup/orig/` 只放**被补丁改过的 dsh 源文件**
（用于回滚补丁）；`~/dsh-termux/backups/` 放的是**我们自己脚本**的历史版本。
另外 `patches.py` 的 `BACKUP` 常量指向的是前者。

---

## 五、为什么这几步缺一不可（因果链）

```
Android 没有 node-addon-require-builtin 预编译
        └─► ② 必须让 internalModules() 能绕过它
                └─► 但绕过靠的是 --expose-internals
                        └─► ① 只能写在 shebang 上（NODE_OPTIONS 塞不进）
Android 没有 node-addon-system 的 android 预编译
        └─► ③ 放开平台闸门
                └─► 但闸门后面要有真插件
                        └─► 1.3 用 clang 直编 system.node（node-gyp 在 Termux 编不出来）
Android 禁止 link(2)（EACCES）
        └─► ④ 三处调用点按各自语义替换（rename / 先查后 rename / copyFile EXCL）
非 loopback 地址下客户端把自己判成非本机
        └─► ⑤ 设置页拒绝向 Host 取配置
                └─► 否则局域网访问时设置页直接不可用
```

---

## 六、已知降级与边界

| 项 | 状态 |
|---|---|
| `sharp` | **不可用** —— `Error: Could not load the "sharp" module using the android-arm64 runtime`（缺 `@img/sharp-android-arm64`）；附件/图片读取功能因此受影响 |
| `@deepseek-ai/node-addon-require-builtin` | 缺失（**预期**），已由补丁 ② 绕过 |
| 上游升级 | **14 处补丁全部丢失**，升级后必须重跑补丁器；`patches.py --list` 会先报「待打」 |
| 局域网暴露 | 8030 / 3080 等价于把「远程代码执行入口」开到内网。可信内网之外请 `sv down dsh-ctl dsh-lan` |
| 令牌 | 每次重启都变，永远用 `dsh-web-url` 现取，不要缓存 |
| cookie | 按 authority 绑定，3080 与 8030 各要登一次 |

---

## 七、自查命令（都可直接跑）

```sh
# 补丁是否齐全（只判定不写盘）
python ~/dsh-termux/patches.py --list

# 补丁造成的实际改动痕迹
grep -rlE "termux-expose-internals|termux-android-flock|termux-link-|dsh-termux-lan" \
  $PREFIX/lib/node_modules/@deepseek-ai/dsh --include="*.js"

# flock 原生模块能否加载
node -e 'require("'"$PREFIX"'/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/node-addon-system/lib/flock.js")'

# 三个服务
sv status dsh-web dsh-lan dsh-ctl

# 当前入口（含令牌）
dsh-web-url --all

# 8030 三态
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.3.190:8030/       # 200 控制台 / 落地页
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.3.190:8030/app    # 200 dsh 主界面
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.3.190:8030/ctl    # 401 未登录
```

## 八、8030 控制台面板改版记录（2026-09-30）

一天里连改四轮，都是用户看实物提的。落在 `share/dsh-ctl/panel.html`（+ 网关 `dsh-ctl-gateway` 的 `/ctl/api/manifest`）。

| 轮次 | 用户要求 | 落成什么 |
|---|---|---|
| ① | 去掉配置卡片与凭据总览；「增加 token」= 在站点下加一把、其余配置复用；只有新增站点才弹配置项 | 删两张卡；`addTokenQuick()` 复用当前那把的地址/协议/模型；配置项只在新增时出现 |
| ② | 详情默认不显示；「全部检测」报 429 但单把检测正常；界面名词改对 | 详情默认收起；`RETEST_MS=20000` 结果复用 + 429 退避重试 + 串行 700ms；术语统一（Token→密钥、凭据→密钥值/环境变量名、识别名→显示名、注册路由→已写入 dsh） |
| ③ | 同一时间只能启用一把 | 启用位唯一入口 `onlyEnable()` + 网关 `normalizeActive()` 写盘兜底 |
| ④ | 列表以接口地址为标准、一个接口下多把 key、加密钥放展开区最下边、新增走弹窗 | 两层结构（接口 → 密钥）+ `#btnAddApi` 弹窗；「站点」全改「接口」 |
| ⑤ | **每个 key 不再展开；接口地址后面加「编辑」按钮，弹窗显示当前地址的配置内容** | 删掉密钥级展开（`.kdet`/`OPENK`/`toggleOpen`）与接口信息条 `.abar`；接口行尾部加「编辑」→ 弹窗 = 接口本身 + 它下面每把密钥的完整配置（`.mkey` 卡片），左下角可删接口 |

**最终形态**

```
接口行 .arow  [▸] 接口地址 | 名称·当前 | 协议 | N 把密钥 | 健康 | [编辑]
  └ .adet 展开区 → .klist
       密钥行 .krow  [开关] [dot] 名称·当前 | 备注 | 健康      ← 无第三级
       「＋ 增加密钥」.kadd（klist 最后一个子元素）
[＋ 新增接口] #btnAddApi
弹窗（编辑态）= 地址/协议/显示名 + 每把密钥的 .mkey（备注/显示名/环境变量名/密钥值/模型/检测/删除）
              + 左下角「删除这个接口」#mDel
```

**两个容易踩的实现点**

1. 列表和弹窗是同一份 `DRAFT`：`renderList()` 末尾调 `refreshModalKeys()` 重绘 `#mKeyList`，
   且要**保存并还原 `.mbox` 的 scrollTop**（否则点一个模型勾选就弹回顶部）。
   而 `setTok(...,'note'|'label')` 故意不重绘 —— 重绘会吞掉正在打的字。
2. 密钥值只活在 `DRAFT`（清单不存明文）：`applyState()` 重建前用 `prevKey['sid/tid']` 捞回 `_newKey`；
   保存成功后 `afterSave()` → `clearNewKeys()` 才清掉明文。

**验证（一轮截图都没做）**

- `node tests/audit-panel.js share/dsh-ctl/panel.html` —— 静态自检，含「密钥行没有二级展开」「旧 .abar / moveTo 已清」
  「弹窗里能加密钥 / 删接口」等组。
- `node tests/test-panel-ui.js` —— headless chromium 驱动假后端，**76 项交互断言全过**。
- 真机 `bash install-ctl.sh`（md5 `6c69d307bc7a081ab50507344e65512c`）断言全部命中期望：
  `data-aedit=1`、`id="mKeyList"=1`、`data-kdet|data-kchev|OPENK=0`、`moveTo|toggleOpen=0`、
  清单回写幂等、故意全标启用后落盘归一为 1 把且能还原。

### 8.4 弹窗分工定稿 + 接口级「检测」（2026-09-30 再一轮）

用户原话两句：

1. 「每个key 不再可以展开 接口地址 后边增加一个编辑 按钮 点击弹窗 当前地址的配置内容」
2. 「接口编辑之显示接口相关的即可 不在显示 key key在展开列表中单独管理 key后要增加删除 按钮」
3. 「全部检测 也不要了 每个接口 那增加一个检测即可」

**上一轮理解错了什么**：第 1 句的「当前地址的配置内容」我按「这个接口 + 它下面所有密钥」做了，
把密钥详情全塞进接口弹窗（`#mKeyList`）。第 2 句用户纠偏：**弹窗要分工**。

**现在的形态**

```
接口行 .arow  [▸] 接口地址 | 名称·当前 | 协议 | N 把密钥 | 健康 | [检测][编辑]
  │                     ↑ healthApi(sid)              ↑ openApiModal(sid) → 只改接口本身
  └ 接口展开区 .adet
      └ 密钥列表 .klist
          ├ 密钥行 .krow  [开关] [dot] 名称·当前 | 备注 | 健康 | [编辑][删除]
          │                                                     ↑ data-kdel → delToken
          └ 「＋ 增加密钥」.kadd      ← 仍是 klist 最后一个子元素

接口弹窗 #modal  = 预设 / 接口 id（只读）/ 显示名 / 协议 / 接口地址 + 「删除这个接口」
密钥弹窗 #kmodal = 这一把的备注 / 显示名 / 环境变量名 / 密钥值 / 模型 / 检测 + 「删除这把密钥」
```

**接口级检测为什么不能直接复用 `healthOne`**：它开头那道门是
`if (!t.enabled || ...) return`，即「只测启用那把」；而全局只有一把启用，
所以其它接口点了会毫无反应。改成给它加第 5 个参数 `allowIdle`，
新写 `healthApi(sid)` 串行测该接口下所有 `hasKey || _newKey` 的密钥（含待命），
复用同一套 `RETEST_MS` 结果缓存与 `HL_MAX_TRY` 退避。
`healthAll` 保留，但只剩「页面加载时那一次静默自动探测」这一个调用点。

**这次改到的文件**

| 文件 | 改动 |
|---|---|
| `share/dsh-ctl/panel.html` | 删 `#mKeyList` 与 `.tbar`；新增 `#kmodal`/`#kBody`/`#kDel`；`keyModalHtml()` / `openKeyModal()` / `closeKeyModal()` / `refreshKeyModal()` / `keyModalDel()`；密钥行加 `data-kedit`/`data-kdel` 操作列；接口行加 `data-ahealth`；`healthApi()`；`healthOne()` 加 `allowIdle` |
| `tests/audit-panel.js` | 断言换新；**「函数重复定义」判定改成 `/^function …/gm`（只看顶层）** —— 面板里有同名内部函数会误报 |
| `tests/test-panel-ui.js` | 第 3/4/7/10 段重写，新增 1b / 1c 两段检测断言；**99 项全过** |
| `install/install-ctl.head.sh` / `install-ctl.sh` | 断言换新，md5 `16604c7abc577cd91dda0955376f7649` |

**两个容易踩的实现细节**

1. `refreshKeyModal()` 要**先存 `.mbox` 的 `scrollTop` 和 `document.activeElement.id`**，
   重绘后还原 + 重新 focus；并且查到 `tokById()` 为 null 就直接 `closeKeyModal()`
   —— 删掉的那把会让弹窗自己关，不用在每个删除分支里手写。
2. 接口行两个按钮都要 `event.stopPropagation()`：整行是「展开」的点击区，不拦就被吃掉。

**验证（仍然一张截图都没做）**

- `audit-panel.js` 全绿（结构组含 `data-kedit`/`data-kdel`/`c-act`/`data-ahealth`，
  弹窗组含 `id="kmodal"`/`id="kBody"`/`keyModalHtml(`/`refreshKeyModal(`/`keyModalDel`，
  并断言 `mKeyList|modalKeysHtml|modalKeyHtml` 为 0）。
- `test-panel-ui.js` **99 项全过**（上一版 76 项）；1b 断言 20 秒内复用不新增请求、
  1c 断言一个有 2 把待命密钥的接口点检测会发出 4 次请求（每把 429 + 退避重试各一次）。
- 真机 `install-ctl.sh`（md5 `16604c7abc577cd91dda0955376f7649`）面板 58 行断言**逐行符合期望，零偏差**：
  `kmodal=1` / `kBody=1` / `keyModalHtml=3` / `refreshKeyModal=2` / `keyModalDel=2` /
  `data-kedit=1` / `data-kdel=1` / `data-ahealth=1` / `healthApi=2` /
  `mKeyList|modalKeysHtml|modalKeyHtml=0` / `全部检测=0` / `kadd=1`；
  清单回写幂等、故意全标启用后落盘仍归一为 1 把且能还原。
- 真机现状未被改动：**1 个接口 / 2 把密钥，active=gateway-t2**。

### 8.5 「接口列表」卡片下的长段说明删掉（2026-09-30 微调）

用户原话：「一行一个接口（= 一个接口地址 + 一种协议，在 dsh 里就是一个 provider）……密钥行尾有 编辑 描述太长 不要了」

就是那句抱怨 —— 卡片里那段 6 行的 `<p class="muted">` 整段删掉，`<h2>接口列表</h2>` 之后
直接就是表头 `.ahead`。解释性内容不再占卡片位置，需要提示的都在各元素的 `title=` 里。

**顺手把它锁住了**（删文字这种事最容易下次被「顺手加回来」）：

| 文件 | 改动 |
|---|---|
| `share/dsh-ctl/panel.html` | 删掉 `#list` 上方那段 `<p class="muted">`（6 行） |
| `tests/audit-panel.js` | 新增第 8b 组：结构断言（h2 与 .ahead 之间不许有 `<p>`）+ 三个特征串计数为 0 |
| `install/install-ctl.head.sh` / `install-ctl.sh` | 新增「标题下已无长段说明文字」期望 0；md5 `cb2e18b798d5b25e9ec5953c46561c6d` |

**断言做了反证**：把那段临时插回去 → `audit-panel.js` 报两条 ✗（结构 + 特征串），删掉又全绿。
新加的字符串断言必须走这一步，否则不知道它是真在测还是在空转。

**验证**：`audit-panel.js` 全绿；`test-panel-ui.js` **99 项全过**（无回归）；
真机 `install-ctl.sh` 212 行输出**零 ✗**，`标题下已无长段说明文字: 0 ✓`，
清单回写幂等、归一化后 md5 还原一致，用户现状未被动（1 接口 / 2 把密钥，active=gateway-t2）。

### 8.6 修「新增接口弹窗点创建接口无反应」—— 错误提示被弹窗盖住了（2026-09-30）

用户原话：「新增接口弹窗 点击创建接口无反应」

**不是崩溃，是提示不可见。** 复现（headless + 假后端）五种非法输入：

| 填什么 | 弹窗 | 列表 | 弹窗内能看见错误吗 |
|---|---|---|---|
| id 用大写 `MyApi` / 带下划线点 / 留空 | 不关 | 没变 | **看不见** |
| 地址漏协议头 / 留空 | 不关 | 没变 | **看不见** |

错误全写进了页面底部的「输出」卡片 `#out`，而弹窗是 `position:fixed` 遮罩层 ——
**提示被自己盖住了**，用户视角就是「点了没反应」。

**更该记的是断言比需求弱**：第 5 段当时断言的是
`ok('输出面板给出原因', (await page.locator('#out').innerText()).includes('http'))` ——
「错误写进 #out」等于绿，可需求是「用户要知道为什么没建成」。断言只覆盖实现、没覆盖体验，
bug 就从断言底下走过去了。

**改法三件套**

| 改动 | 内容 |
|---|---|
| 弹窗内联红条 | `<p class="merr" id="mErr">` 贴在标题下、表单上方，不用滚就能看到 |
| 统一失败入口 | `modalFail(msg, focusId)` = 弹窗可见 + `out()` 留痕 + 聚焦出问题的输入框 |
| 输入即清 | `<div id="modal" … oninput="modalErr('')" onchange="modalErr('')">`，靠冒泡吃全部输入 |

外加 `openApiModal()` / `closeModal()` 里补 `modalErr('')`。报错文案给了下一步
（id 不合法时算出 `my-api-v2` 这种建议、地址缺协议头时回显原值），用户能一次改对。

**踩到的**：`modalErr` 用 `textContent`，第一版消息里写了 `<b>…</b>` → 会显示成字面量标签。已改纯文本。

**验证**

- `audit-panel.js`：`id="mErr"`=1、`modalFail(`=9、`modalErr(`=6、`oninput="modalErr('')"`=1。
- `test-panel-ui.js`：**108 项全过**（上一版 99，+9）。新增「红条可见且写的是原因」
  「聚焦到 nsUrl」「改输入红条自动消失」「id 重复时红条说已存在」，以及编辑接口
  `updateApi` 那一侧同样验一遍。
- 真机 `install-ctl.sh`（md5 `b270ae3bd314d86db43de65bbca28056`）215 行输出**零 ✗**；
  清单回写幂等、归一化后 md5 还原一致，用户现状未被动。

---

## 8.7 「保存并重启」里的重启，对配置多余、对密钥必需（2026-09-30 验证）

**起因**：用户问「底部的保存并重启 验证下 是否改配置文件后无需重启即刻生效」。

**结论 —— 两条链路方向相反，不能合成一句「要/不要重启」**

| 改什么 | 落盘位置 | 需要重启 | 实测延迟 |
|---|---|---|---|
| 接口地址 / 协议 / 模型 / 显示名 / 启用切换 | `~/.dsh/profiles/web/cordis.patch.yml` | **不需要** | **2275–2303 ms** |
| 面板里新填的密钥值 | `$PREFIX/var/service/dsh-web/environment` | **需要** `sv restart dsh-web` | 启动期注入，不重启永不生效 |

**机制**：dsh `dsh-base` bundle 的 `- id: hmr`（`@deepseek-ai/dsh-hmr`，
`disabled: !!js "!ctx.get('profileContext')"`）在 web profile 下启用，chokidar 监听
profile patch，`awaitWriteFinish` 2s + debounce 100ms → 正好对上实测 2.3 秒。
密钥走 runit `environment`，`./run` 启动期 `set -a; . environment` 注入，运行中进程 environ 不更新。

**方法论（比结论更值钱）**

1. **别拿日志当判据**。注入「不存在的插件包」「非法 YAML」「重复 id」三种探针，
   日志一行不出、PID 不变 —— 差点判成"完全没反应"。真相是 HMR 成功路径不打日志
   （源码里只有 `warnings` 才 `logger.warn`）。
2. **要判"运行中进程认不认"，就直问它**。用真实浏览器（playwright-core + 本地
   `chromium_headless_shell-1243`）打开 dsh web 抓网络，才发现 `/api/*` 是 **POST RPC**：

   ```bash
   curl -s -b cj -X POST -H 'Content-Type: application/json' \
     -d '{"type":"client-request","rpcId":"1","method":"llm/listProviders","payload":{"args":{}}}' \
     http://127.0.0.1:3080/api/llm/listProviders
   ```

   body 必须 `{type,rpcId,method,payload:{args:{}}}`；`method` 要写端点全名
   （写 `listProviders` 会 400 `method does not match endpoint`）；`payload` 必须含且仅含
   一个 plain-object `args`。同族端点：`/api/session/modelCatalog`、`/api/settings/describe`、
   `/api/credentials/describe`、`/api/session/list`。
3. **`sed -i` 换 inode**，所以「进程 watch 的 ino == 文件 ino」判据会假否 ——
   chokidar 靠目录事件重新注册。**用行为判定，别用 inode。**

**产物**：`bin/verify-hot-reload.sh` —— 改一次 `displayName`、轮询 API 测延迟、
md5 对账还原、报 pid 有没有变。连跑三次：2303 / 2276 / 2275 ms，pid 全程未变。

**对面板的含义（待用户决定，未改代码）**：「保存并重启」多出来的那次 restart，
在本次没有新密钥值时对配置生效没有贡献（只是让浏览器重连）。面板上那句
「有 N 把填了新密钥值 —— 那要回列表点『保存并重启』才写进服务环境」是对的，不能删。

---

## 8.8 控制台新增「dsh 版本更新」（2026-09-30）

**起因**：用户「面板增加 dsh 版本更新功能」。

### 为什么这不是「执行一条 npm i -g」那么简单

`npm install -g @deepseek-ai/dsh` 会把整个包目录换成官方版，于是：

- 打在 `node_modules` 源码上的 **14 处 Termux 补丁全部丢失**（见 §二）
- 本地 `clang` 编出来的 `flock` 原生插件 `system.node` 也没了

**只装包不补补丁，dsh-web 直接起不来**（回到 §1 那四类不兼容）。所以「更新版本」
在 Termux 上是一条固定五步链，不是一步。

### 实现（网关 `bin/dsh-ctl-gateway`）

新增两个 `/ctl/api/*`：

| 接口 | 性质 | 做什么 |
|---|---|---|
| `dshcheck` | **只读** | 读本地 `package.json` 拿当前版本 + 打 registry 小端点拿远端版本，给出 `hasUpdate` / 通道 / 补丁器是否在位 |
| `dshupgrade` | 写 | 五步链 + 失败自动回滚 |

五步链（`apiDshUpgrade`）：

| 步 | 动作 | 失败后果 |
|---|---|---|
| 0 | `mv $PREFIX/lib/node_modules/@deepseek-ai` → `@deepseek-ai.bak-<ts>` | 中止（一个字节都没动） |
| 1 | `npm install -g @deepseek-ai/dsh@<目标版本>`（超时 15 分钟） | 回滚 |
| 2 | `python3 $PREFIX/share/dsh-ctl/patches.py`（幂等 + 锚点断言） | **回滚** |
| 3 | `flock` 原生插件缺了就 `build-flock.sh` 现编 | 继续（只影响那条子系统） |
| 4 | `sv restart dsh-web` + `dsh --version` 复验 | 回滚 |

**回滚用改名不用复制**：包目录 300MB 级（实测 `du -sh` = 305M），`cp -a` 要几十秒，
`mv` 是瞬时的（同文件系统改名）。失败时 `fs.rmSync` 删掉装坏的、`fs.renameSync`
把备份改回来，再 `sv restart dsh-web`。

**补丁器落位改动**：`install-ctl.sh` 现在多 put 两个文件到 `$PREFIX/share/dsh-ctl/`
（跟 `panel.html` 同级）：

- `patches.py` —— 升级后重打补丁用
- `build-flock.sh` —— 原生插件丢失时现编用

网关把这两个路径写死，**不依赖 `$HOME/dsh-termux/`**（历史遗留的临时目录，随时过期）。
**补丁器不在就直接拒绝升级** —— 宁可不升，也不留一个起不来的 dsh。

### 查版本：别用 `npm view`

`npm view` 要起一个 npm 进程 + 拉整包文档。改打 registry 的**小端点**：

```
https://registry.npmjs.org/-/package/@deepseek-ai%2Fdsh/dist-tags
→ {"alpha":"0.1.7-alpha.2","latest":"0.2.0-rc.2","next":"0.2.0-rc.2"}
```

几百字节，设备实测 **0.9 秒**（含 TLS 握手；第二次 0.37 秒）。官方源失败自动退
`registry.npmmirror.com`。

### 面板（`share/dsh-ctl/panel.html`）

服务卡片里加版本行：`dsh <版本>` chip + `检查更新` + `更新到 x.y.z` + 状态短语。
更新走确认弹窗：通道下拉（latest / next / alpha）、可手填任意版本、强制重装勾选、
**升级前的步骤预告**、执行中的已等待秒数、**分步结果**（每步命令 + 退出码 + 输出）。

页面加载后静默对一次远端（5 分钟内不重复，不覆盖输出面板），该亮时才亮。

### 这一轮挖出来的四个真问题

1. **「远端版本」不等于「更新」**。切到 alpha 通道时远端可能**比本机旧**
   （实测本机 `0.1.7-rc.2`、alpha `0.1.7-alpha.2`）。按钮还写「更新到」是误导，
   改成按 semver 粗比显示「**回退到**」。粗比必须算 prerelease 段
   （`alpha.2` < `rc.2`），否则两者主版本相同会被判成"相等"。

2. **结果一长，弹窗按钮被顶出视口**。升级结果 5 段加起来 781px，`.mbox` 只有 632px
   （`max-height:88vh`），「关闭」落到 `y=770` —— 已在 720 高的视口**外**。
   用户看到的是「按钮没了」。修：`.mfoot` 改 `position:sticky;bottom:0`，
   `#uLog` 自己 `max-height:44vh;overflow:auto`。
   断言同步改成测**位置**（`r.top >= 0 && r.bottom <= innerHeight`），
   不再只测"元素存在"—— 与 §8.6 那条「断言只覆盖实现、没覆盖体验」同一类病。

3. **拿按钮文字当状态位**。`closeUpdModal()` 原来靠 `ok.textContent === '执行中…'`
   判断"正在跑"，而下拉完成时只把按钮 `display:none`、文字没换回来 →
   **弹窗再也关不掉**。改用显式 `UPD.busy`。

4. **`install/patches.py` 在仓库里是 CRLF、设备上是 LF**。内容一字不差（忽略行尾后
   md5 一致），但直接下发到 Termux 是隐患。已转 LF 并加 `.gitattributes`
   （`*.sh` / `*.py` / `*.js` / `*.html` / `bin/*` / `runit/*` 一律 `eol=lf`）。
   `tests/inventory.out.txt` 同样处理。

### 测试

- `tests/audit-panel.js`：新增 17 条版本组断言（含「升降区分」「版本不再塞在 envline」）
- `tests/test-panel-ui.js`：新增一段 24 项 —— 含**失败路径**（假后端版本号带 `fail` 就演一遍
  「补丁锚点对不上 → 自动回滚」）与**成功路径**，共 **135 项全过**
- `tests/preview-panel.js`：补 `dshcheck` / `dshupgrade` 两个假端点
- 设备 `install-ctl.sh`：新增 10 条断言（面板有版本行 / 弹窗 / 网关两个接口 /
  回滚存在 / 补丁器已落位且能被 python 解析 / flock 编译脚本已落位）

### 真机实测：三轮才升上去，`koffi` 要 CMake + `statx` 要 Android 30（2026-09-30）

**`dshcheck`（真机，`http://192.168.3.190:8030/ctl/api/dshcheck`）**

```json
{"current":"0.1.7-rc.2","latest":"0.2.0-rc.2","hasUpdate":true,
 "registry":"https://registry.npmjs.org","ms":859,"patcher":true,"flockOk":true}
```

耗时 909 ms；`channel=alpha` 返回 `latest:"0.1.7-alpha.2"`（正确触发「回退到」）；
未登录 → `HTTP 401`。**这一半功能是真机验证过的。**

**`dshupgrade`（真机，升 `0.2.0-rc.2`，耗时 283 秒）→ 失败，但回滚 100% 生效**

`npm install -g @deepseek-ai/dsh@0.2.0-rc.2` 退出码 1：

```
npm error path    …/dsh/node_modules/koffi
npm error command sh -c node ./cnoke.cjs -P . -D src/koffi --prebuild --release
npm error Failed to load prebuilt binary, rebuilding from source
npm error Error: CMake does not seem to be available
```

**根因**：`koffi`（0.2.0-rc.2 新增依赖）装的时候要跑 `cnoke.cjs`；Android/arm64 预编译
二进制加载失败 → 回退源码编译 → 需要 **CMake**。设备实测：

| 工具 | 状态 |
|---|---|
| `cmake` | **缺** |
| `ninja` | **缺** |
| `clang` / `make` / `gcc` / `pkg-config` | 在 |

`0.1.7-rc.2` 里也有 `node_modules/koffi`，但那是当年用预编译二进制装上的，所以没暴露这个问题。

**回滚验证（这才是重点）**：失败后设备**零损伤** ——

| 项 | 升级前 | 升级后（回滚完） |
|---|---|---|
| dsh 版本 | `0.1.7-rc.2` | `0.1.7-rc.2` ✓ |
| `cordis.patch.yml` | `34a4a29a…` | `34a4a29a…` ✓ |
| `sites.json` | `192be465…` | `192be465…` ✓ |
| flock `system.node` | 11776 B | 11776 B ✓ |
| 8 条补丁 | 已打 | 已打 ✓ |
| `@deepseek-ai.bak-*` | — | 已清理 ✓ |
| `dsh-web` | run | run ✓ |

**结论**：升级链路本身是好的，**卡点是新版本依赖 `koffi` 需要 CMake，而设备没装**。

#### 第二轮：装了 cmake 还是挂 —— 这次挂在 `statx`

`pkg install -y cmake ninja`（59 秒，连带 libarchive/jsoncpp/libuv/rhash），
`cmake 4.4.3` + `ninja 1.13.2` 就位后重跑。CMake 配置一路走通，
**编译 `koffi_unity.cpp` 时炸**：

```
lib/native/base/base.cc:2967:19: error: cannot initialize a member subobject
  of type '__u32' (aka 'unsigned int') with an lvalue of type 'const char *'
 2967 |     if (statx(fd, pathname, stat_flags, stat_mask, &sxb) < 0) {
      |                   ^~~~~~~~
lib/native/base/base.cc:2967:58: error: invalid operands to binary
  expression ('statx' and 'int')
```

**这句报错极具误导性**：看着像「参数类型写错了」，其实是 **`statx` 这个「函数」根本没声明**。
bionic 的 `<sys/stat.h>` 里它是这样藏着的：

```c
#if defined(__USE_GNU) && __BIONIC_AVAILABILITY_GUARD(30)
int statx(int __dir_fd, const char* __path, int __flags,
          unsigned __mask, struct statx* __buf) __INTRODUCED_IN(30);
#endif
```

两个条件**缺一不可**：`__USE_GNU`（要 `-D_GNU_SOURCE`）+ API 级别 ≥ 30。
少任何一条，`statx(fd, pathname, …)` 里的 `statx` 就只解析成**类型**，
整句变成一次强制类型转换 —— 于是报「`__u32` 不能用 `const char *` 初始化」。

设备实测（clang 21.1.8）最小复现，五选一：

| 编译方式 | 结果 |
|---|---|
| 裸编译 | ✗ `statx` 未声明 |
| `-D_GNU_SOURCE` | ✗ |
| `-D_GNU_SOURCE -D__ANDROID_API__=30` | ✗（宏被内置定义覆盖） |
| `-D_GNU_SOURCE -D__ANDROID_MIN_SDK_VERSION__=30` | ✗ `statx is unavailable: introduced in Android 30` |
| **`--target=aarch64-unknown-linux-android30 -D_GNU_SOURCE`** | **✓ 编 / 链 / 跑全通** |

C 与 C++（含 `<string>`/`<vector>`）都验过，且 **CMake 从环境变量 `CFLAGS`/`CXXFLAGS`
吃得下这组标志**（已用最小 CMake 工程验证，正是 `cnoke.cjs` 的构建路径）。

#### 第三轮：把标志塞进装包那一步，成了

网关新增常量 + `runFile` 多一个 env 覆盖位：

```js
const ANDROID30_FLAGS = '--target=aarch64-unknown-linux-android30 -D_GNU_SOURCE'
const NPM_BUILD_ENV = Object.assign({}, CHILD_ENV, {
  CFLAGS: ANDROID30_FLAGS, CXXFLAGS: ANDROID30_FLAGS, CPPFLAGS: '-D_GNU_SOURCE',
})
// 只有装包这一步带，补丁器 / flock 编译脚本不受影响
runFile(NPM_BIN, ['install', '-g', DSH_PKG + '@' + want], NPM_UPGRADE_TIMEOUT, NPM_BUILD_ENV)
```

**结果：`ok:true`，`0.1.7-rc.2 → 0.2.0-rc.2`**，各步退出码全 0：

| 步 | 结果 |
|---|---|
| mv 备份 | 0（瞬时） |
| `npm install -g @deepseek-ai/dsh@0.2.0-rc.2` | 0，**2 分钟**，530 个包 |
| `python3 patches.py` | 0，**改动 14 处，跳过 0 处** |
| `build-flock.sh` | 0，11776 B，自测「争用返回 EWOULDBLOCK」✓ |
| `sv restart dsh-web` + `dsh --version` | 0，**`0.2.0-rc.2`** |

**升级后实测（不是只看返回码）**：

| 项 | 结果 |
|---|---|
| `dsh --version` | `0.2.0-rc.2` ✓ |
| `require('koffi')` | ok ✓ |
| `require('node-pty')` | ok ✓ |
| flock `system.node` | 加载 ok，`tryLock` 是函数 ✓ |
| `GET /ctl`（控制台页面） | `200` ✓ |
| `/ctl/api/dshcheck` | `current=0.2.0-rc.2`、`hasUpdate:false` ✓ |
| `/ctl/api/health` | 真打 `discovery-api.intern-ai.org.cn/v1/models` → **200，10 个模型，211 ms** ✓ |
| `dsh-web` / `dsh-ctl` / `dsh-lan` | 三个都在跑 ✓ |
| 安装器自带断言 | 全部 ✓（含新增 4 条编译标志组） |

**成功时备份目录会留着**（`@deepseek-ai.bak-<ts>`，实测 **305 MB**），
网关不会自己删 —— 确认新版没问题后手动清理：
`rm -rf $PREFIX/lib/node_modules/@deepseek-ai.bak-*`。

**顺带记一笔**：`install-ctl.sh` 的「全标启用」自测会把 active 归一到**第一把**
（跑完是 `gateway-t1`，原先是 `atria-t1`）。它的还原基准是「归一化之后」的 md5，
不是「跑之前」的 —— 所以跑安装器可能顺手改掉当前启用的那把。已知，未改。
