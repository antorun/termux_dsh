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

# 当前入口（dsh 的登录令牌链接）
dsh-web-url --all

# 8030 三态
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.3.190:8030/       # 200 控制台面板（路由器模型：直接进）
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.3.190:8030/app    # 200 dsh 主界面
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.3.190:8030/ctl    # 200 同面板；save 等改配置接口才 401
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

---

## 九、卸载（`install/uninstall.sh`，2026-09-30 新增）

装得上也要卸得干净。卸载是 install.sh 的严格逆操作：**README「目录结构」表里写明的设备
落点，多一个不删，少一个不落。**

卸什么：

| 层 | 内容 |
|---|---|
| 服务 | `sv down` 停服务 → `$SVDIR/{dsh-web,dsh-lan,dsh-ctl}` → 对应的 `$PREFIX/var/log/sv/<服务>` |
| 工具 | `$PREFIX/bin/` 里 8 个自写工具（精确名单，见 1.4） |
| 面板 | `$PREFIX/share/dsh-ctl/`（`panel.html` / `patches.py` / `build-flock.sh`） |

默认保留（和升级链一条线：可以失败回滚，但用户数据不丢）：`~/.dsh`（会话 / profile / 密钥）、
`~/.dsh-termux-backup`（补丁原始备份）、`~/dsh-termux`（工作目录 + `backups/` 备份史）、
dsh npm 包本体（`--dsh` 才删 —— 14 处补丁和 flock 原生模块全在包里，想再用：
`npm i -g @deepseek-ai/dsh` → `patches.py` → `build-flock.sh`）。

四个刻意的设计决策：

1. **绝不用 `dsh*` 通配**。`$PREFIX/bin/dsh` 是 npm 装的符号链接
   （→ `../lib/node_modules/@deepseek-ai/dsh/lib/bin.js`），动它就是动 npm 的账。同理
   日志目录按服务名精确删除 —— `$PREFIX/var/log/sv/` 下面还有 cloudflared / sshd / mysite
   等别人的日志。
2. **每刀先路径守卫**：非空且必须在 `$PREFIX` 或 `$HOME` 之下，越界拒绝并记录（退出 3）。
3. **交叉确认 + 复核**：交互要输全字 `yes`（防手抖）；删完逐项复核，服务目录被 runsv 占着
   是正常的，等 5 秒再扫一遍。
4. **8030 控制台里没有「卸载」按钮**。网关自己就是被删的对象 —— 收到请求、删到一半把自己
   `rm` 掉，响应还没写回连接就断了，半拆状态比不卸更糟。破坏性操作留在设备侧脚本，和
   「更新到 x.y.z」五步链同一个理由：要能失败、要能看清楚、要能回滚。

幂等：删过的再跑是 no-op；全都不在时报「没有可卸载的东西」退出 0。
`PREFIX` / `SVDIR` / `LOGDIR` / `HOME` 允许环境变量覆盖（同 `install-web-service.sh`
的约定），既能用于非交互 SSH，也能在假树上把破坏性路径真跑一遍。

**一个坑**：`say "盘点要删什么（PREFIX=$PREFIX）"` 在 macOS 自带 bash 3.2 下会把全角
括号的字节吃进变量名（`set -u` 直接报 unbound variable 杀掉脚本）—— Termux 的 bash 5
没事，但脚本应当到处都能跑，所以变量后接多字节字符一律写 `${PREFIX}`。

测试：`tests/test-uninstall.sh` 在 Mac 上造假树（假 `$PREFIX` 含 runit 服务目录、svlogd
日志、8 个工具、`share/`、npm 包；假 `$HOME` 含 `.dsh` / 备份 / 工作目录；`sv` / `npm`
是桩脚本），把破坏性路径真跑一遍 —— 67 项断言覆盖预演、默认层、`--all`、幂等、拒绝确认、
参数错误；还放了 `cloudflared` 服务/日志和 npm 的 `bin/dsh` 符号链接两个「绝对不能误删」
的哨兵。真机上用 `-n` 预演验证过清单与实际部署一致（3 服务 + 8 工具 + 面板资源），
预演后三个服务的 PID 不变、8030 控制台照常 200。

---

## 十、网关优先生命周期管理（2026-09-30 新增）

### 问题：顺序反了

原来的流程是「先在 SSH 里把 dsh 装好 → 再装网关」。但 dsh 是 300MB 级 npm 包 + koffi/flock
现编，SSH 里干等一个 `npm install` 几分钟起步：中途没进度、断了重跑、koffi 编译失败还得回滚。
这一全程恰恰是最需要「看着进度」的地方，却偏偏发生在连控制台都还没有的时候。

**网关优先**把顺序倒过来：安装器只装「入口」（网关 + 面板 + 生命周期脚本，几秒落盘），
dsh 本体的装 / 修 / 升 / 卸全部挪到浏览器控制台里完成。哪怕 dsh 还不存在，8030 上也已经
有一个能点的地方。

### 入口：`install-gateway.sh`（`.head.sh` + `build-install-gateway.py` 生成）

单文件、幂等、可直接 bash 执行，base64 内联 14 个 payload，五步：

| 步 | 做什么 | 备注 |
|---|---|---|
| 0 | 备份：`$PREFIX/bin/` 下 8 个工具、`panel.html`、`~/.dsh/{sites,accounts}.json`、两个 profile 的 `cordis.patch.yml` 全 `cp -a` 到 `~/dsh-termux/backups/` | dsh 已装就原地更新网关，不动 dsh |
| 1 | 落网关全套：9 个工具 + 面板 + 生命周期四件套（`patches.py` / `build-flock.sh` / `uninstall.sh` / `install-web-service.sh`），逐件 `node --check` / `bash -n` / `ast.parse` 自检 | 自检失败即停 |
| 2 | 建 / 复位 runit 服务 `dsh-ctl`：<lan-ip>:8030 → 127.0.0.1:3080 | 服务目录已存在就复位 run 脚本 |
| 3 | 启动：`sv restart`（已有服务）/ `sv up`（新建），最多等 25 秒出 `run:` | 起不来退出 1 并指向日志 |
| 4 | 五项验证：`/ctl` 200 直接面板含向导、`state` 无凭据 `ok:true`、明文 key 计数 0、非白名单接口 `save` 401 | 没 curl / 没拿到 LAN IP 就跳过验证 |

> 安装器原来是 6 步：第 3 步「生成引导令牌」已随第十三节的路由器模型一起去掉。

### 鉴权：路由器模型（第十三节改的，原来叫引导令牌）

老设计里 dsh 没装时唯一凭据是安装器生成的一个 32 位令牌；现在控制台对局域网
全开（`install-gateway.head.sh` 的步骤表也同步精简）。现状：

- 白名单 `OPEN_API = ['state','install','repair','uninstall','jobstatus','dshcheck','dshupgrade','log','restart']`
  —— 生命周期接口不登录也能调；`save` / `apply` / `manifest` / `key` 这些能改
  后端配置的一律 401，要先去 `/app` 登录 dsh
- `state` 的 `credentials` 按登录态给：未登录只有掩码（`buildState(authed)`），
  明文 API key 不外露
- `/ctl` 与 `/` 一律返回面板；登录态只决定接口权限与明文密钥

### 长任务：job 契约

装 / 修 / 升 / 卸都是长任务（npm 装包几分钟，卸载会连网关自己一起杀掉），HTTP 请求不能挂着等。
统一改成：**API 立刻返回 jobId → 后台跑 → 输出逐行实时收进 `lines` → 面板轮询 `/ctl/api/jobstatus`**。

```json
{ "ok": true, "job": { "id": "install-1727…", "kind": "install", "title": "安装 dsh 0.2.0-rc.2",
  "status": "running",
  "steps": [{ "cmd": "…npm install -g @deepseek-ai/dsh@0.2.0-rc.2", "code": 0, "out": "…" }],
  "lines": ["$ …", "…"], "elapsedS": 47, "result": null } }
```

- `steps[]`：一步的定妆照（命令 / 退出码 / 输出摘要）。输出 `clipTail` 头尾各留 2000 字符 ——
  npm 能吐几千行，全塞回来既没用又卡
- `lines[]`：实时现场。剔 `\r`（进度条会把一行劈成多行），400 行封顶丢头留尾，快照只给最近 160 行
- 同一时间只允许一个任务（设备上并行两个 `npm install` 会互相踩），第二个直接拒绝，并告诉用户
  当前任务的标题和已跑秒数
- 完成后 `jobstatus` 保留**最后一个任务的快照**（不是 null），面板晚几十秒来看结果也还在
- 面板轮询节奏：600ms 一次，连续 miss 两次以上降为 3000ms

### 装修升共用一条链：`provisionDsh`

`install`（dsh 还没有）/ `dshupgrade`（换版本）/ `repair`（包在但坏了）共用一个引擎，区别只在
是否走 npm：

| 步 | 命令 | 失败处理 |
|---|---|---|
| 1 | 备份：整个 `@deepseek-ai` 作用域目录**改名**挪走（`mv` 瞬时；`cp -a` 300MB 要几十秒） | 改名失败就不装 |
| 2 | `npm install -g @deepseek-ai/dsh@<目标>`，带 `NPM_BUILD_ENV` 编译标志 | **自动回滚**：删装坏的、把备份改回来、`sv restart dsh-web` |
| 3 | `python3 patches.py`（幂等，带锚点断言；退出码 0/1/2） | 补丁没全打成 → 失败（升级时包已换，提示手动处理或卸载重装） |
| 4 | `dsh-patch-lan-settings` | **非致命**，只往 lines 推一行警告 |
| 5 | `build-flock.sh`（flock 原生模块被 npm 冲掉了才编） | 非致命（只影响那条子系统） |
| 6 | `install-web-service.sh`（服务目录不在才建）+ `sv up/restart dsh-web`（最多 8 轮，每轮间隔 2.5s） | 起不来 → 失败并指向 `$PREFIX/var/log/sv/dsh-web/current` |
| 7 | 等 3080 端口应答（`waitUp` 120s）+ `readToken`×10 拿登录令牌，拼出可直接点的链接 | 非致命（链接拿不到不影响 `ok`） |

第 2 步的编译标志（`NPM_BUILD_ENV`）是这一轮补上的。上一轮真机升 0.2.0-rc.2 栽在 `koffi`
（预编译二进制加载失败 → 回源码编译 → 当时设备没 CMake），回滚 100% 生效但升级 itself 失败。
这一轮两件事一起办了：设备补 `cmake` / `ninja`，安装链给 `CFLAGS`/`CXXFLAGS` 带上

```
--target=aarch64-unknown-linux-android30 -D_GNU_SOURCE
```

原因是 bionic 的 `<sys/stat.h>` 里 `statx()` 同时要 `__USE_GNU`（即 `-D_GNU_SOURCE`）和
API>=30 两个条件，少一条 `statx` 就只剩类型没有函数，clang 报出来的那句
`cannot initialize a member subobject of type '__u32' with an lvalue of type 'const char *'`
看着像参数写错，其实是函数根本没声明。设备实测（clang 21.1.8 / cmake 4.4.3 / ninja 1.13.2）
裸编译 ✗、只 `-D_GNU_SOURCE` ✗、再加 `-D__ANDROID_API__=30` ✗（宏被内置定义覆盖）、
`--target=…android30 -D_GNU_SOURCE` ✓ 编 / 链 / 跑全通。

`repair` 刻意**不挪包也不走 npm**：包没换就没必要冒险动它，只重打补丁 + 起服务 —— 比升级快
（不下载 300MB），也比「强制重装」安全（不动 npm 的账）。

### 卸载：detached 跑

第九节里那条「8030 控制台里没有『卸载』按钮 —— 网关自己就是被删的对象，删到一半把自己
`rm` 掉，响应还没写回连接就断了，半拆状态比不卸更糟」—— 这一轮把它解了：

1. 把 `uninstall.sh` **复制到 TMPDIR** 再跑 —— 卸载会删 `share/dsh-ctl/`，脚本跑到一半把
   自己删了就卡住
2. `spawn(..., { detached: true, stdio: ['ignore', fd, fd] })` + `unref()`，输出写
   `$TMPDIR/dsh-uninstall.log`（追加模式，网关被杀前能推多少推多少）
3. API 立刻返回 jobId；网关存活时每秒 `tail -n 40` 日志推进现场（180 秒封顶，网关被杀后
   轮询自然停止）
4. 默认参数 `-y --dsh`（把 npm 包一起卸）—— 否则「继续安装」会被旧包挡住报「已经装了」；
   `--all` 是「把整个方案从手机上抹掉」那一档（连 `~/.dsh` 用户数据一起）
5. 面板那侧按「连接断了 = 网关正被卸载」理解这个行为，不当作故障

破坏性操作从「 SSH 里敲命令」挪到「网页上点按钮」的代价，靠这两条兜住：脚本跑在独立进程里
（不受 HTTP 连接生死影响），且复制出来再跑（不怕删到自己）。

### 面板（`share/dsh-ctl/panel.html`）

- 引导页：粘贴令牌的表单（`bsToken()` 存 sessionStorage），不回显令牌
- 安装向导 `#wizard` 卡片：dsh 未装时显示 —— 通道下拉（latest / next / alpha）或手填版本，
  「开始安装」按钮
- 任务弹窗 `#jmodal`：`pollJob()` 轮询（600ms / 3000ms 退避），日志实时滚，步骤逐条显示
  命令 + 退出码 + 输出，底栏 sticky（沿用第八节那个「按钮被顶出视口」的修法）
- 装完在弹窗里给出令牌登录链接（`/app?token=…`），点开直接进 dsh 主界面
- dsh 装好后向导卡片消失，改走服务卡片上常规的「修复 / 更新到 x.y.z / 卸载」

### 测试

`tests/test-gateway.sh`：造假树（假 `$PREFIX` + 假 `$HOME` + `sv` / `npm` / `ifconfig`
桩脚本 + 假上游 node），把网关真跑起来，72 项断言。Mac / Linux / Termux 都能跑（真机
实测：Android 15 / node 24.18 / bash 5.3）：

| 组 | 内容 |
|---|---|
| T1 鉴权 | `/ctl` 与 `/` 直接 200 面板且**无令牌表单** / state 无凭据 `ok:true` 且只给掩码 / save 401 |
| T2 安装 job | jobId 返回 / 拒绝并发第二个任务 / npm 调用参数正确 / steps 与 lines 结构 / 完成态 |
| T3 修复幂等 | 不走 npm（数调用次数）/ 重打补丁成功 |
| T4 登录后完整权限 | 同一把假 key：未登录只见掩码、登录后见明文（对照组）/ save 登录后不再 401 /
 `/app` 代理回上游页面 / state 不带 cookie 依旧 200 |
| T5 卸载 + 落盘恢复 | API 立即返回 jobId（**不带凭据**）/ **杀网关再重启，轮询照样取到 done**（job 落盘 +
 detached 恢复）/ 后台真把假树拆了 / 调用串含 `-y --dsh` 且脚本来自 TMPDIR 副本 |
| T6 完成态保留 | 再重启一次 jobstatus 仍返回最后任务快照（`"kind":"uninstall"`）/
 `log`、`restart` **不用凭据**白名单放行 |

写这套测试时踩的三个坑（都是「桩脚本」本身的）：

- 桩脚本的 shebang 必须写**绝对路径**。写 `#!/usr/bin/env bash` 时 `CHILD_ENV` 把假树 bin
  排在 PATH 最前，`env bash` 会递归找到桩自身 → 参数列表无限增长。Mac 上表现是
  `E2BIG: Argument list too long`；**Termux 上更阴**（`/bin/bash` 不存在、`/usr/bin/env`
  存在）：execve 循环不报错，每个被调桩留一个 83% CPU 空转的孤儿进程，网关的 state /
  jobstatus 请求全被拖死，的表现像「网关挂了」其实是被桩转死了。解法：测试里
  `REAL_BASH=$(command -v bash)`，桩里写 `#!@BASH@` 占位符，建树时 `sed` 成绝对路径；
  桩里 `exec bash …` 同理换成 `exec "$REAL_BASH" …`（PATH 里的 `bash` 就是桩自己）
- `ifconfig` 桩必须 `echo` 出文本。裸把数据行写给 bash 执行（exit 127）→ `lanIp()` 落空 →
  拼出的 `appUrl` 是空串，下游断言全灭
- 数 npm 调用次数别写 `grep -c … || echo 0`：grep 没匹配时输出 `"0\n0"`，拼成字符串喂给
  算术比较直接炸。要用 `grep … | wc -l`

### 与既有结构的关系

- 网关 (`bin/dsh-ctl-gateway`) 从「反向代理 + 控制面」扩成「反向代理 + 控制面 + 生命周期
  引擎」：+579 / −131 行，全部在 `/* … */` 分块注释划出的新区里，代理路径一行没动
- `install/uninstall.sh` 本身**没改**，只是被网关复制到 TMPDIR 后台调用 —— 第九节的设计
  （路径守卫 / 精确名单 / 幂等）原样复用
- 老入口 `install-ctl.sh` / `install-lan.sh` / `install.sh` 保留不动；`install-gateway.sh`
  是面向「新设备 / 想全网页操作」的入口，不是替换

---

## 十一、一键 curl 入口（`bootstrap.sh`，2026-09-30 新增）

仓库推到 GitHub 后，`install-gateway.sh` 是 gitignore 的生成物，raw 上拿不到。
`bootstrap.sh`（仓库根）补上这一环 —— Termux 里一行：

    curl -fsSL https://raw.githubusercontent.com/antorun/termux_dsh/main/bootstrap.sh | bash

从 raw 拉 16 个源文件到 `$TMPDIR` → 本地现构建 → 执行。依赖只有 curl + python3
（nodejs / termux-services 由安装器自己检查提示）。两个设计点：

- **下载 URL 带同一时间戳**：raw 的 CDN 按文件缓存且不同步 —— 不带戳可能拿到
  「A 文件新版、B 文件旧版」的混合快照，构建照过但行为是旧的。带同一 `?ts` 强制
  全部回源，锁死同一时刻。真机实测：无戳拿到旧版 `dsh-ctl-gateway`（63866 B），
  带戳立刻是新版（81731 B）。`bash -s <ref>` 可指定分支 / tag / commit。
- **生成物继续不入库**：bootstrap 拉的是源，当场构建，源与产物不可能不同步。
  失败时提示 `git clone` 备选（raw 被墙的场景）。本地可用 `DSH_RAW` 覆盖下载源
  自测（仓库根起 `python3 -m http.server`，`DSH_BUILD_ONLY=1` 只构建不执行）。

顺带修了一个线上事故的尾巴：16:00 控制台点的「卸载」是 detached 跑的（删 300MB
的 dsh 包很慢），与 16:04 的 repair 重建发生竞争 —— 重建好的 `dsh-web` 服务被慢吞吞
的卸载又删了一遍，导致 8030 的 `/app` 一度 502。 detached 卸载结束后重跑
`install-web-service.sh` 即恢复。这是 job/卸载纯内存态的同一类脆弱性 —— 已由
「**job 落盘 + 重启对账**」解掉，见第十二节。

---

## 十二、job 落盘与生命周期实现（2026-09-30 落地）

第十节写的是设计（`repair` / `uninstall` 端点、卸载 detached 跑、`#wizard` 安装卡），
这一节写的是**真正落到代码里的那部分**，外加从线上事故（第十一节尾巴）反推出的
「job 必须比网关活得更长」。

### run.sh：detached 的退出码要落码

detached 子进程靠 `spawn(..., { detached: true, stdio: ['ignore', logFd, logFd] })`
起，stdin 关掉、stdout/stderr 全追加进 `$TMPDIR/dsh-uninstall.log`。但「进程退出了」
这件事网关未必收得到（`sv down dsh-ctl` 把网关杀了，`child.on('exit')` 就没了），
所以复制的 `run.sh` 自己兜底：

    SCRIPT="$1"; MARK="$2"; shift 2
    bash "$SCRIPT" "$@"
    echo $? >"$MARK"

退出码写进 `dsh-uninstall-*/exit.code`，谁活着谁读取 —— 网关活着走 exit 事件，
网关被杀过走落码文件。**脚本串里不拼任何用户输入**（沿用 `install.sh` 的约定），
`-y --dsh` / `-y --all` 是固定 argv，由 `apiUninstall` 生成。

### persistJob / reconcileJob：job 的生死不跟网关绑定

- `persistJob(force)`：把 `{id, kind, title, status, steps, lines, startedAt, elapsedS,
  pid, detach}` 原子写进 `$TMPDIR/dsh-ctl-job.json`（tmp 文件 + rename，300ms 去抖；
  启动 / 起新 job 时 force 立刻写）。catch-all 吞掉所有写失败 —— 落盘是保命手段，
  不能反过来把请求打挂
- `jobLine()` / `jobStep()`：每次推进现场都顺手落盘（去抖），面板轮询断在半路，
  重连拿到的也是连贯现场
- 启动时 `reconcileJob()`（在 `bind()` 之前）：文件不在 / 字段不齐（kind / startedAt /
  lines / steps 有一个不是数组）就当没有，故意严格 —— 手改的脏文件不能把网关带沟里
  - `done` / `failed` → 原样挂回，面板继续看得到最后现场
  - `running` + 有 `detach` → `resumeDetached()` 对账
  - `running` 无 `detach` → 中断为 failed，说明写「子进程可能仍在后台跑完」——
    这种 job 的子进程不在 job 文件的管辖范围内，只能把现场交给用户

**并发闸门跨重启生效**：恢复出来的 `running` job 会挡住新生命周期任务
（「另一个任务正在跑」）—— 这就是 16:00 卸载 / 16:04 repair 竞争的根除：重启
（或被杀重启）之后，网关仍然知道「卸载还在跑」，repair 不会插队。

### resumeDetached 的三段判定

    readExitMark(job.detach.mark)  → 码在 = 子进程已退，直接收尸
    pidAlive(job.pid)              → 码不在、PID 活着 = 还在跑，挂 supervise 接着等
    都不是                          → 都不是 = 没any痕迹，中断现场

`superviseDetached` 每秒查三件事：退出码文件、PID 活不活、日志有没有新行
（`tailInto` 靠字节偏移 `detach.pushed` + 半行缓冲 `detach.buf` 推进，避免反复
`tail -n 40` 把旧行重复推进去），外加 `NPM_UPGRADE_TIMEOUT` 封顶看门狗。
`finishDetached()` 收尾时把日志尾部塞进 `result.out` —— 用户看到的「卸载干了什么」
是 detached 进程自己写的，不是网关脑补的。

### repair：install 已有链条的复用

`runPatchChain(job)`（patches.py → LAN 补丁 → flock 插件，lan-patch 与 flock 的失败
记为非致命）和 `ensureWebService(job)`（`sv` 缺服务目录就 `install-web-service.sh` 建、
`restart` ×8、`waitUp` 等它活）从安装流程里抽出来共用 —— install 和 repair 走的是
**同一条补丁链**，区别只在「要不要重装 npm 包」。repair 刻意不挪包：包没换就不
冒 npm 的险，只重打补丁 + 起服务。`BOOTSTRAP_WHITELIST` 相应加上 `repair` /
`uninstall`（与 README 记录的生命周期端点对齐），`buildState()` 加
`uninstallAvailable`（`share/dsh-ctl/uninstall.sh` 在场才给卸载按钮）。

### 面板配套

- `#wizard` 安装卡：dsh 未装时显示（通道 latest / next / alpha 或手填版本），点位
  在头部之后、服务卡之前；`st.dshMissing` 管显隐
- 服务卡新增「修复（重打补丁）」「卸载」按钮 + `unAll` 勾选（`--all` 的确认文案
  会变）；卸载的任务弹窗用 `missMs: 180000` + 专用 `missHint` —— 轮询取不到任务
  状态 180 秒就当作「网关自己就是被删的对象」，按完成展示而不是报错
- `pollJob` 的 miss 超时分支：`ok = !!JT.missHint` —— 给了提示语就走「乐观完成」，
  没给才是真超时

### 真机验证

- `tests/test-gateway.sh` **72 / 72 全过**（Android 15 aarch64 / node v24.18.0 /
  bash 5.3），含 T5 的完整往返：卸载 → 杀网关 → 重启 → 轮询到 done → 断言假树
  真被拆、调用串含 `-y --dsh`、脚本来自 `dsh-uninstall-*` 副本（T1 / T4 后来
  按第十三节重写，套件现为 65 项）
- `tests/test-uninstall.sh` 67 / 67；`tests/audit-panel.js` 全绿（95 函数 / 47 id）
- Windows（git bash）上 T1 全绿、HTTP 层与任务编排的语法都正常，但 node 无法 spawn
  无扩展名的脚本桩 —— 假树里的 `npm` / `sv` / … 在 Windows 上不是可执行文件，
  job 类断言必然失败。仓库的开发机约定是 Mac / Linux / Termux，Windows 只做
  语法与面板结构审查

### 一个已知的边界

`lanIp()` 与服务状态读走 `execSync('… 2>&1')`，node 在 Linux 上硬编码用 `/bin/sh`。
带 `/bin` 挂载的设备（本机）没问题；纯 Termux 无 `/bin/sh` 时这两处会抛异常被
各自 catch（`lanIp` 落空、服务 `raw` 记一条报错），面板降级但网关不挂。要彻底
干净得换 `execFileSync` 直跑 `BIN + '/sv'`，属既有行为，本轮不动。

## 十三、去掉引导令牌：控制台改「路由器模型」（2026-09-30）

装完网关打开 `http://<LAN-IP>:8030/` **就是**控制台 —— 这是用户要的体感，
代价是引导令牌那整套机器没有存在意义了。拆掉的东西：

- `readBootstrap` / `bootstrapValid` / `bootstrapGiven` / `revokeBootstrap` /
  `bootstrapPage`（粘贴令牌的落地页）全部删除；`$PREFIX/share/dsh-ctl/.bootstrap-token`
  不再生成，安装器第 3 步整个去掉（5 步 → 头部说明同步改）
- `handleCtl`：`/ctl` 与 `/` 一律返回面板；未登录鉴权从「令牌 + 白名单」
  简化为「白名单」。`BOOTSTRAP_WHITELIST` 改名 `OPEN_API`，语义从「令牌持有者
  的子集」变成「局域网内任何人的子集」

### 边界：明文密钥（这是令牌唯一真正挡住的东西）

`state` 的 `credentials` 数组里 `value` 是**明文 API key**（`save` 回显、登录态
面板要用）。放开 `state` 就等于把 key 摊给整个局域网 —— 所以 `buildState(authed)`
按登录态给：未登录只有 `{name, masked}`，登录后（dsh cookie）才给全文。
`restart` 的内嵌 state 同样透传登录态。`save` 依旧 401 拒绝未登录。

放开的是什么：`state` / `install` / `repair` / `uninstall` / `jobstatus` /
`dshcheck` / `dshupgrade` / `log` / `restart` —— 生命周期接口对局域网全开，
**路由器管理页模型**：同一个 WiFi 下能打开 8030 的人就能修 / 卸。破坏性操作
的拦截留在面板的 confirm（卸载还有 `-y` / `--all` 双确认），改配置 / 读密钥
则必须登录 dsh。这是用户明确选的档位。

### 面板与安装器

- 删掉 `bsToken` / `bsClear` / `bsHeaders` 三件套与 `?bootstrap=` URL 解析；
  `api()` 的 401 分支改成「这个接口需要先登录 dsh（打开 /app）」
- `apiState` 的 `bootstrapActive` 字段去掉，面板相应提示删除
- `install-gateway.head.sh` 的验证项改写：`/ctl` 直接 200 面板、state 无凭据
  `ok:true`、明文 key 计数 = 0、save 无凭据 401；收尾只打印控制台地址与
  dsh 登录链接，不再有令牌两行

### `/app` 自动登录（路由器模型的最后一块拼图）

打开 `http://<lan-ip>:8030/app` 不用再贴令牌链接：浏览器没 cookie 时，网关
自己跑一次 `dsh-web-url` 拿当前登录令牌，302 到 `/app?token=…` 让 dsh
按这个 authority 把 cookie 种好（303 落回干净的 `/app`），下一次请求就带
cookie 直接进 SPA。已有 cookie 的请求按老路取首页（**不**画蛇添足地重走
令牌）。令牌失效时不再把 dsh 的裸 401 甩给浏览器 —— `proxy` 加了 `on401`
钩子，落到登录页说「令牌没通过：可能已过期」。

老的 `loginPage`（未登录落地页）按钮原来指向「去网关首页拿令牌」，现在
首页没令牌可拿了，主按钮改成「打开 /app（自动登录）」。

### 测试（T1 / T4 重写，T5 / T6 去掉令牌路径）

- T1「开放模型鉴权」：`/ctl` 与 `/` 直接给面板且**没有** `name="bootstrap"`
  表单；state 无凭据 `ok:true` 且只有掩码；save 无凭据 401
- T4「登录后完整权限」：同一把假 key —— 未登录只见掩码、登录后见明文
  （对照组）；save 登录后不再 401；`/app` 代理回上游页面；state 不带 cookie
  依旧 200（登录不把白名单的路走窄）
- T5 卸载改不带凭据调用；T6 的 `log` / `restart` 也去掉 cookie ——
  白名单接口不登录能调，正是这轮改的点
- 假密钥（`environment` 里一把 `TEST_API_KEY`）只在断言时 `plant_key` 进
  假树、验完 `unplant_key` 拆掉：`var/service/dsh-web` 目录在位会让
  `ensureWebService` 跳过 `install-web-service.sh`（T2 要断言的核心路径），
  不能常驻

真机 `tests/test-gateway.sh` **68 / 68 全过**（新增 5 项 /app 自动登录断言：
无 cookie 302 到 `?token=`、跟随跳转 200、落地是登录页、直贴令牌走 `on401`
钩子给登录页），安装器在 Android 15 / node v24.18 上一遍过，自带的自检五项
（面板 200 / umodal 在场 / state 无凭据 ok / 明文 key 计数 0 / save 401）全绿。
旧设备上残留的 `.bootstrap-token` 文件已手动删除（新代码不读它，留着也只是
死文件）。/app 自动登录在真机验证：无 cookie → 302 → 303 种 cookie → 落回
干净 /app 拿到 34KB 的 dsh SPA。

### 自动登录：陈旧 cookie 不再死循环（2026-09-30 下午修）

第一版只看「浏览器有没有 cookie」—— 有 cookie 就走老路取首页。真机和
curl 上都好好的，偏偏用户浏览器卡死：浏览器里存着**陈旧** cookie（登过
别的 authority、或 dsh-web 重启后 cookie 名已失效）时，`/app` 每次都
401 → 登录页，点「自动登录」→ 因为还有 cookie → 又 401 → 死循环。

改成**探测后决定**：`/app`（无令牌参数）先用浏览器自己的 cookie 探一下
`probeAuth`（404=已登录），不是 404 才去 `readToken()` 补令牌。没有 cookie、
cookie 过期、别的 authority 登的 —— 一律自动接令牌重登。

### 缺模型的密钥不再拖死整表保存（「新增接口 / key 加不了」的另一半根因）

用户加接口时，清单里留下一把**没模型**的半成品密钥（`discovery-t1`）。
dsh-set-provider 按规矩拒收（"还需要配一个模型 id"），而网关把整表一次性
喂给它 —— 结果**只要清单里有一把不完整，谁也存不进去**：新接口再完整也
"无效"。加接口走的是 `manifest`（只写清单，本来能成功），但未登录时它 401
（同上一个根因），所以看起来「加了也存不下、刷新就没」。

- 网关 `apiSave`：落盘前把 `!models.length` 的密钥**过滤掉**再喂给
  dsh-set-provider（`defaultModel` 空但有 models 时自动补首个）。完整的
  照写进 dsh；草稿留在清单里（`SITES_JSON` 刷新不丢），配齐模型再保存就
  写进去。响应里带上「其中 N 把缺模型，按草稿留在清单里、没写进 dsh」。
- 一把完整的都没有时：清单照存，dsh 配置不动，明确说「先不用重启」，
  不再抛 dsh-set-provider 的裸报错。
- 面板：本地校验从硬拦改成确认 —— 结构问题（缺 id / 缺地址 / 没密钥）
  仍硬拦；缺模型改为「会作为草稿保留、不写进 dsh，继续保存吗？」；`afterSave`
  把服务端附注（草稿提示）一并显示。

真机回归：`tests/test-gateway.sh` **75 / 75 全过**（T1 加 6 项：陈旧 cookie
跳自动登录、带草稿保存 ok + 草稿提示、provider 收到的清单只有完整密钥、
草稿留在存档等；`dsh-set-provider` 桩把 `--sites-file` 转存后断言，注意
落盘 JSON 有缩进 → 冒号后有空格，grep 模式要对齐）。

## 十四、本机直连：auto 模式同时绑定 loopback（2026-09-30）

网关 `auto` 模式以前只绑局域网 IP，手机自己访问 `http://127.0.0.1:8030/`
是被拒的（长期被当成「设计如此」）—— 用户的实际需求是**直连可以、路由也
可以**：Termux 里 curl / 浏览器开 127.0.0.1 直进，电脑上走 192.168.0.102。

`bindLoopback()`：`auto` 模式下再起一个 `127.0.0.1:8030` 的监听（同一个
`onRequest` / `onUpgrade`，WebSocket 一样通）。它与局域网那台相互独立 ——
局域网那台等 IP、随 WiFi 变重绑；loopback 永远在，**WiFi 没连也能进**。
显式 `LISTEN_HOST` 模式（测试套件用）仍只有一个监听，端口不冲突。两个
authority 的围栏自检都会打日志（`✓ /api 围栏放行 127.0.0.1:8030`）。

`/app` 的自动登录按**请求当时的 authority** 让 dsh 种 cookie —— 从
127.0.0.1 进就种 127.0.0.1 的，从局域网 IP 进就种局域网 IP 的（dsh 的
cookie 本来就按 authority 隔离，两边互不干扰）。

### dsh-lan 不用装（路由器方案下的结论）

控制台服务卡里 `dsh-lan: 未安装` 是**正常状态**，不是缺件：

- dsh-lan（install-lan.sh）是**无网关方案**的局域网入口：`<lan-ip>:3080`
  裸转发到 127.0.0.1:3080 + 给 dsh-web 注入 `--trusted-host <lan-ip>`
- 网关方案里这两件事都有人做了：局域网入口由 8030 接（代理 + 控制台 +
  `/app` 自动登录），`--trusted-host` 由 `install-web-service.sh` 注入

它跟 dsh-web / dsh-ctl 不一样（那俩是必须的），装了只是多一条 3080 的
重复入口。**它也不再出现在控制台的服务列表里**（2026-09-30 晚最后
摘掉）：路由器模型下 8030 就是局域网入口，`dsh-lan · 未安装` 这行
对用户只有噪音。旧装机的 dsh-lan 服务要是还在跑也不影响什么，
`uninstall.sh` 照旧会清掉它。

## 十五、控制台深度精简 + UI 重做（2026-09-30 晚）

用户反馈「网关里边没用的东西删掉，太繁琐了，简单好用即可」—— 面板从
1883 行砍到 ~1200 行，主页从五块卡片变成三块。

**删掉的**（约 600 行）：

- **整套密钥健康探测**：`HL` 状态表、`healthOne/healthAll/healthApi`、
  `paintHealth/paintApiHealth`、429/503 退避重试、页面加载时的自动
  轮询（每刷新一次就打所有端点的 `/models`，聚合站容易 429 —— 评论里
  记录过的真实现象）。要查密钥好不好使，保存时勾「保存后自检」（走
  dsh headless 端到端验证），或在密钥弹窗里「从端点拉取模型列表」。
- **候选模型批量操作**：`candAll/candNone/copyModels`（全选 / 清空 /
  同步给同接口其它密钥）—— 拉模型时已经全量加入，不要的取消勾选即可。
- **清空配置** `clearAll`（回到官方默认端点）+ 通用 `act()`。
- 「服务与运行环境」整块卡片、「输出」卡片 —— 收进「高级」折叠区。

**留下的三块主页**：

1. **当前生效**：进来看一眼就知道现在用着哪个接口、哪把密钥（密钥掩码
   + 默认模型），两个按钮：`打开 dsh 主界面 →`（就是 /app 自动登录）、
   `编辑这把密钥`。
2. **接口与密钥**：接口行（名称 / 地址 / 待命徽章）点开是密钥行 ——
   开关（= 当前生效，互斥）+ 名称（**备注优先**：用户填的「主号」比
   脱敏串 sk-7.ca14 认得出）+ 掩码 / 模型 / 草稿提示 + 编辑 / 删。
   底下一个大按钮 `保存并生效`（旁配「保存后自检」勾选）。
3. **维护**：`更新 dsh` / `卸载`，`高级` 折叠区里是版本对表、修复、
   服务状态、日志、输出。

**UI**：暗色保留，按钮最小 44px 触摸高度、字号 14-15px、卡片间距加大；
`out()` 出错时自动把「输出」折叠区展开（不然用户不知道发生了什么）。

端口路径都要回归：新增 `tests/panel-render-check.js` —— 在 node 里用
假 DOM 跑面板的渲染与交互（applyState → renderList/renderCur、切启用
互斥、密钥弹窗候选模型、save 打到哪里），21 项断言全过；`tests/audit-panel.js`
的静态断言同步更新到精简后的 DOM 契约（健康探测 / candAll / clearAll 等
want=0 的「已删」项），它还抓出一个真 bug：重写时漏了 `id="verNow"` 而
`renderVer` 还在写它的 `title`（浏览器里会抛 TypeError）；设备端
`tests/test-gateway.sh` 75/75。

playwright 的 `tests/test-panel-ui.js`（135 项真浏览器断言）退役 ——
它绑着旧 DOM，且本机/设备都没有 chromium 可跑；同样的路径由不需要浏览器
的 `panel-render-check.js` 覆盖。

## 十六、安装入口全自动化（2026-09-30 深夜）

用户要装到其他设备：「pkg install curl python 也要集成到安装脚本，
脚本要去更新 termux 和装必要的包，输出整洁一点」。

`bootstrap.sh` 从「只负责拉源+构建」变成**全套环境准备**：

- **0. 检查运行环境**：确认在 Termux 里（`$PREFIX/bin/pkg` 存在），
  否则提示去 F-Droid / GitHub Releases 装 Termux（应用商店版已停更）。
- **1. pkg update + 依赖**：八个依赖（curl / python / nodejs-lts /
  termux-services / clang / make / cmake / ninja —— 后四个是 dsh 0.2.0+
  的 koffi 原生编译要用的）逐个探测，已有的跳过、缺的 `pkg install -y`。
  pkg 几百行输出全部重定向到日志，只留一行结果；失败时才打 tail。
- **2. 起 runit 守护**：termux-services 的自启在登录 shell 的
  profile.d 里，curl|bash 这个 session 没跑过 profile —— 现场用
  `setsid runsvdir $SVDIR &` 拉起并等它就绪（最多 20 秒），不然安装器
  起不了服务。
- **3/4. 拉源 + 构建 + 执行**：16 个文件的逐行输出压成一行汇总
  （`16/16 个，共 278 KB`），失败项才逐条列。

`install-gateway.head.sh` 输出同期浓缩（信息量不减）：

- 备份步骤：N 个文件逐行列 → 一行「旧文件备份 N 个 → …」；
- 自检：18 行 OK 列表 → `ck()` 收集器，一行「自检 16/16 项通过」，
  失败项才列出并退出（以前自检失败也继续往下装）；
- 去掉 `ls -la $SVDIR`、服务目录、日志尾部三处倾倒；
- 修了步骤编号不一致（文案里两处「第 6 步」实为第 5 步）。

README「快速开始」整段重写，按用户要的四块：**安装环境**（Android 7+ /
无 root / Termux 别用应用商店版 / 网络 / 空间）、**一键安装**（它做哪
七步、下载了什么、装了什么、备份了什么）、**使用方法**（三个地址表 +
控制台三块主页 + 凭据分工）、**运行逻辑**（转发拓扑图、手机重启后
打开 Termux 即恢复、划掉应用会被杀 → termux-wake-lock、热生效 vs
必须重启的分界）。

实测：设备上 `bash bootstrap.sh` 端到端 3 分钟跑完 —— pkg update ok、
八依赖齐全不重复装、runsvdir 已在运行、16 文件 278 KB、生成
366KB 安装器、自检 16/16、验证六项全过（面板 200 / 本机直连 200 /
state ok / 掩码 0 / save 401）。

第二天在**另一台设备**上装时撞上 dpkg 死锁：

```
dpkg: error processing package libdecor (--configure):
 dependency problems - leaving unconfigured
sdl2 depends on libdecor; however: Package libdecor is not configured yet.
Errors were encountered while processing: shared-mime-info gtk3 libdecor sdl2
```

根因不在本方案 —— `pkg install cmake ninja` 的依赖里没有 gtk3/sdl2，
是那台设备**之前**装别的东西时留下了「配一半的包」（shared-mime-info
的 postinst `update-mime-database` 常因内存不足失败 → gtk3 → libdecor →
sdl2 依赖链全卡住），之后任何 apt 操作都被 dpkg 拖去先配完它们。

bootstrap 的依赖环节因此改成三级防线：

1. **软硬分开**：`curl / python / nodejs-lts / termux-services / clang /
   make` 是硬依赖；`cmake / ninja` 只有 dsh 0.2.0+ 的 koffi 原生编译
   要 —— 装不上只警告，不拦着装网关（网关、控制台、低版本 dsh 都
   不需要它们），事后 `pkg install -y cmake ninja` 即可。
2. **失败先自愈**：`dpkg --configure -a` 收拾半成品后重试一次安装。
3. **降级重试**：还不行就只装硬依赖；全失败才退出，并在提示里直接
   给出那串 pkg remove 命令（ gtk3 / libdecor / sdl2 /
   shared-mime-info）让用户自救。
