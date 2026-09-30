---
name: dsh-termux
description: 在 Android/Termux 上把 @deepseek-ai/dsh（DeepSeek Harness）从「装得上但起不来」补成可用状态，并做成 runit 守护服务 + 取令牌命令。当用户提到「termux 上装 dsh / deepseek harness / dsh web 起不来 / node-addon-require-builtin 没有 android-arm64 / No usable native binding / flock is not supported on android-arm64 / link EACCES / MISSING_CREDENTIAL llm-deepseek / dsh 升级后打不开 / 401 dsh web authentication required / 想让手机浏览器用 dsh / 从电脑访问 dsh web / dsh --host 0.0.0.0 被拒绝 / 用局域网 IP 访问 dsh 报 502 503 或 /api 403 / 设置里模型页报 settings are unavailable in this browser 或 加载提供商目录失败 / 局域网下设置页不可用 / 想在局域网上管 dsh 的模型与凭据 / 想要一个 8030 的网关入口 / 访问 8030 进的是 dsh 主界面而不是网关管理 / 想把 dsh 主界面挂到子路径 / 把 dsh 前端挂到 /app / 想配多个模型站点、每个站点多把 token 并可切换 / 一个端点要有多个 key 并且需要备注 / token 管理 / 多账号模型后端管理 / 从端点拉取模型列表拉不回来 / 从端点拉模型没反应 / 增加端点时想要一个固定的内置预设（类似 FreeLLMAPI 那种聚合路由）/ 配置里模型重复了 / 面板里不要 token 计数和价格设定 / token 要以列表平铺展示（一行一把、别用卡片）/ 列表下面的配置卡片太碍事去掉 / 凭据总览那张卡不要了 / 增加 token 就是在一个站点下加一把、其他配置全部复用当前这把 / 只有新增站点才弹配置项 / 加完 Token 刷新一下那行就没了 / 点了＋没反应 / 每把 token 下的详细信息默认不要显示、我点开才显示 / 详情默认折叠 / 全部检测显示 429 但单把检测正常 / 检测老是 429 / 界面名词叫得不对要改（Token→密钥、凭据→密钥值、识别名→显示名、端点→接口地址）」时使用。覆盖四/五类补丁的锚点与语义、用 clang 绕开 node-gyp 编译原生插件、幂等补丁器的正确判据、runit 服务与「令牌每次变」的取用方式、loopback-only 的安全边界、SSH 隧道访问、外挂转发层实现局域网直连（裸 TCP 3000 系转发 + 8030 反向代理控制台：`/` 是控制台、`/app` 是主界面）、8030 面板的行式密钥列表（站点 ⊃ 多密钥，路由 id = `<站点>-<密钥>`，只有已存密钥的才写进配置；详情默认收起、点 ▸ 才展开；「清单」与「配置」分两个接口写，避免结构改动被 dsh-set-provider 连坐拒掉）、`enabled` 停用开关、健康探测的「限流 vs 异常」语义与三条节流规则（20 秒结果复用 / 429 退避重试 / 全部检测串行 + 间隔）、客户端 isLoopback 门导致的设置页不可用、用 scp 绕开 ssh 单参数长度上限的推文件方式，以及 `-d "${V:-{}}"`、局部变量遮蔽函数名这两个会让人误判的坑。
agent_created: true
---

# Android/Termux 上装 dsh（DeepSeek Harness）

`@deepseek-ai/dsh` 是为 glibc Linux / macOS / Windows 构建的，**在 Android 上装得上但起不来**。
本技能是把它补成可用状态的完整 playbook。

## 0. 先认清目标形态

| 形态 | 命令 | 用途 |
|---|---|---|
| 浏览器 UI | `dsh web` | **移动端主力形态**：手机浏览器里用 |
| 一次性任务 | `dsh headless "…"` | 跑一个 job 打印结果退出 |
| 终端 UI | `dsh tui` | 需要真终端的场景 |

profile 是「插件包 patch 层的有序堆叠」，入口：`dsh <name>` / `dsh web` / `dsh --profile acp` /
`dsh plugin --profile <name> <pnpm args>`。`DSH_HOME` 默认 `$HOME/.dsh`。

## 0.1 改动全貌（先看这个，心里有数）

整套适配 = **改 8 个文件的 14 处 + 补 1 个本地编译的原生模块 + 8 个自用可执行文件 + 3 个 runit 服务**。
dsh 的业务逻辑一行没动，14 处全是平台适配。

| 类别 | 文件数 | 编辑处数 | 一句话 |
|---|---|---|---|
| ① shebang `--expose-internals` | 1 | 1 | `lib/bin.js` 首行；`NODE_OPTIONS` 塞不进 |
| ② `internalModules()` 绕过原生插件 | 2 | 2 | `dsh-app-boot` 的 `lib/index.js` + `lib/worker/profile-resolution-bootstrap.js` |
| ③ `flock` 平台闸门 | 1 | 1 | `node-addon-system/lib/flock.js`，配合本地编译的 `system.node` |
| ④ `link(2)` → 等价替换 | 3 | 9 | 三个调用点语义不同：`rename` / 先查后 `rename` / `copyFile(EXCL)` |
| ⑤ 客户端 `isLoopback` 强制真 | 1 | 1 | 否则局域网下设置页报 `settings are unavailable` |
| **合计** | **8** | **14** | |

另外补了这些（不是补丁，是新增）：

| 类型 | 内容 |
|---|---|
| 本地编译的原生模块 | `@deepseek-ai/node-addon-system-android-arm64/bin/system.node`（`clang -shared` 直编，绕开 node-gyp）、`node-pty/build/Release/pty.node`（无 android 预编译，装的时候现场编） |
| `$PREFIX/bin/` 自用工具 | `dsh-web-url`、`dsh-lan-ip`、`dsh-lan-gateway`、`dsh-ctl-gateway`、`dsh-set-key`、`dsh-set-provider`、`dsh-patch-lan-settings` |
| 页面 | `$PREFIX/share/dsh-ctl/panel.html` |
| runit 服务 | `dsh-web`（`127.0.0.1:3080`）、`dsh-lan`（`<lan-ip>:3080` 裸 TCP）、`dsh-ctl`（`<lan-ip>:8030` 反代+控制台） |
| Termux 包 | `nodejs-lts` 24.18.0、`clang`（编译用）、`make`、`python`（跑补丁器）、`git` |

**两个备份目录别搞混**：

| 目录 | 放什么 | 谁在写 |
|---|---|---|
| `~/.dsh-termux-backup/orig/` | 被补丁改过的 **dsh 源文件**，按相对路径镜像（用于回滚补丁） | `patches.py` 的 `BACKUP` 常量 |
| `~/dsh-termux/backups/` | **我们自己脚本**的历史版本（`dsh-web-url.*`、`patches.py.bak.*`、`client.js.orig`、`dsh-ctl.run.*` …） | 各安装脚本 |

## 1. 四类不兼容（都必须修，缺一不可）

### ① 启动就 fatal：`No usable native binding found for node-addon-require-builtin-android-arm64`

- 根因：`node-addon-require-builtin` 是原生插件，用于 `requireBuiltin("internal/…")`。
  **npm 上没有 android-arm64 预编译包，包内也不含 C 源码**（`files` 只有 `lib/`），
  所以 loader 的 local-build 兜底路径在 Android 上**永远不可能成功**。
- 修法：让 dsh 带 `--expose-internals` 启动，内部模块就能用普通 require 拿到。
- ⚠️ **`NODE_OPTIONS=--expose-internals` 被 node 明确拒绝**
  （`--expose-internals is not allowed in NODE_OPTIONS`）→ **只能写 shebang 或 argv**。
- ⚠️ **只改 shebang 不够！** `dsh-app-boot` 的 `internalModules()` 是**无条件** require
  那个原生插件，`--expose-internals` 对它无效。必须再打 ②。

**补丁①（shebang）** —— 文件 `lib/bin.js`，把首行改成：
```
#!<PREFIX>/bin/node --expose-internals
```

**补丁②** —— `node_modules/@deepseek-ai/dsh-app-boot/lib/index.js` **和**
`lib/worker/profile-resolution-bootstrap.js`，各替换一次：

锚点（唯一）：
```js
const addon = createRequire(import.meta.url)("node-addon-require-builtin");
```
替换为：
```js
/* termux-expose-internals: … */
const addon = process.execArgv.includes("--expose-internals")
	? { requireBuiltin: (id) => createRequire(import.meta.url)(id) }
	: createRequire(import.meta.url)("node-addon-require-builtin");
```
（marker `termux-expose-internals`）

### ③ `flock is not supported on android-arm64`（headless 一走到就抛）

- 根因：`@deepseek-ai/node-addon-system/lib/flock.js` 的 `loadBinding()` 对
  非 linux/darwin 平台直接抛 `ERR_FLOCK_UNSUPPORTED_PLATFORM`，且只发
  darwin-arm64/x64、linux-x64/arm64 四个可选包。
- **关键事实：bionic 的 `flock(2)` 完全可用**（实测首 fd `errno=0`、争用 fd
  `errno=11`=EWOULDBLOCK、解锁后第三方 fd `errno=0`）。包自带 `src/flock.c`。
- 修法：**绕开 node-gyp，用 clang 直接编**一个
  `@deepseek-ai/node-addon-system-android-arm64`：

```sh
ENTRY="$DSH/node_modules/@deepseek-ai/node-addon-system"
PKG="$DSH/node_modules/@deepseek-ai/node-addon-system-android-arm64"
mkdir -p "$PKG/bin"
# package.json: {"main":"bin/system.node","files":["bin/"]}
"$PREFIX/bin/clang" -shared -fPIC -O2 -I"$PREFIX/include/node" \
  -o "$PKG/bin/system.node" "$ENTRY/src/flock.c"
```
> 为什么能绕开 node-gyp：Termux 自带 `$PREFIX/include/node/`（全套 `node_api.h`、
> `js_native_api.h`、`common.gypi`、`config.gypi`），自包含 N-API 插件直接 `clang -shared`
> 即可。而 npm ≥ 11.10 自带的 node-gyp ≥ 12.3 会把
> `process.config.variables.OS = "android"` 写进 `config.gypi`，gyp 的 `OS == android`
> 分支随即引用未定义的 `android_ndk_path` 而失败。

**补丁③（放开平台闸门，必须与上面配套）** —— `node-addon-system/lib/flock.js`：
```js
// 锚点
if (platform !== 'linux' && platform !== 'darwin') {
// 替换
if (platform !== 'linux' && platform !== 'darwin' && platform !== 'android') {
```
（marker `termux-android-flock`）
> ⚠️ 只放开闸门而不编插件 → `MODULE_NOT_FOUND`，比原来的报错更难查。两者必须成套。

### ④ `EACCES: permission denied, link '…tmp' -> '…'`

- 根因：**Android 内核拒绝 `link(2)`**（`ln` 与 `fs.linkSync` 都报 EACCES）。
  `rename(2)` **不受限**。这是 dsh 多个模块的硬阻塞（会话日志发布、新建文件、附件存储）。
- ⚠️ **不能一律改成 rename —— 三个场景语义不同**：

| 文件 | 调用点 | 语义 | 正确替换 |
|---|---|---|---|
| `dsh-session-persistence-jsonl/lib/index.js` | `await internals.fs.link(staged, currentPath)` | 源是临时名，可消费 | `rename` |
| 同上 | `await link(tmp, finalPath)` | 源是临时名，且随后被 rm | `rename` |
| `dsh-fs-local/lib/index.js` | `await linkFile(tempPath, absolutePath)` | **no-replace**：目标已存在必须失败 | 先 `inspectPublicationTarget` 确认目标不存在，存在则抛 `EEXIST`，不存在才 `rename` |
| `dsh-attachment-local/lib/index.js` | `await link(source, target)` | 别名：**source 必须保留** | `copyFile(source, target, constants.COPYFILE_EXCL)` |
| 同上 | `await link(staged.path, target)` | 暂存发布，源可消费 | `rename` |
| 同上 | `await unlink(staged.path)` | rename 兜底后暂存名已不在 | 容忍 `ENOENT` |

统一写成一个守卫：
```js
try { await <原调用>; } catch (linkError) {
  /* termux-link-xxx: Android 拒绝 link(2)（EACCES）。 */
  if (!(linkError instanceof Error && "code" in linkError && linkError.code === "EACCES")) throw linkError;
  await <等价替换>;
}
```
另需给 import 列表补上 `rename` / `copyFile`（`dsh-attachment-local` 的 `constants`
已在第 6 行从 `node:fs` 导入，直接用即可）。

## 2. 幂等补丁器的正确写法（踩过坑）

每条补丁三个要素：
1. **marker** —— 已打过就跳过；
2. **唯一锚点断言** —— `src.count(old)` 必须 === 1，否则**报错停手**，绝不静默改错地方；
3. **首次改动前备份**原件（按相对路径存，重跑不覆盖真原件）。
   `BACKUP` 指向 **`~/.dsh-termux-backup/orig/`**（不是 `~/dsh-termux/backups/`，后者放我们自己脚本的版本）。

**上游升级后必做**：`npm i -g @deepseek-ai/dsh@…` 会把 14 处补丁**全部冲掉**，
而且 `node-pty` 也要重新现场编译。升级流程固定为：

```sh
python ~/dsh-termux/patches.py --list      # 先看哪些变成 [待打]
bash ~/dsh-termux/build-flock.sh           # 重新编 android-arm64 的 system.node
python ~/dsh-termux/patches.py             # 打补丁（有 FAIL 就停手，别硬来）
sv restart dsh-web dsh-lan dsh-ctl         # 三个服务都要重启
```

`patches.py --list` 的成功判据是**8 个文件全绿**；出现 `[待打]` 说明被冲掉了，
出现 `⚠ 锚点命中 0 次` 说明上游改了代码，必须人工比对后改锚点，**不要放开唯一性断言**。

**幂等判据必须是「marker 命中 **或** 替换结果已在文件里」两条之一。**
只靠 marker 会翻车：那几条「往 import 列表 / 对象属性表插入裸标识符」的补丁
没地方放 marker（放注释会污染上游风格），而打完后**原锚点文本也变了**，
于是重跑时报「锚点命中 0 次」的**假失败**。
```python
if marker in src or new in src:
    SKIP.append(name); return False
```

**状态查询不要维护「期望 marker 表」。** 改为「空跑一遍真实补丁逻辑（dry=True）再按文件聚合」，
与实现同源、不会漂移。

`FAIL` 用 `(文件, 原因)` 元组而非字符串，便于按文件聚合状态。

## 3. 装成 runit 服务 + 「令牌每次变」的取用

`dsh web` 每次启动**都会打印一个带令牌的 URL，令牌进程级随机、每次不同**。
所以必须有取值入口，否则用户每次都得翻日志。

产物三件：
1. `$PREFIX/var/service/dsh-web/run`
   ```sh
   #!/data/data/com.termux/files/usr/bin/sh
   export PREFIX=…  HOME=…  PATH="$PREFIX/bin:$PREFIX/bin/applets"  TMPDIR="$PREFIX/tmp"
   export DSH_HOME="$HOME/.dsh"
   cd "$HOME" || exit 1
   exec "$PREFIX/bin/dsh" web --port 3080 --no-open
   ```
   > runit 的 run 脚本跑在**极简环境**，PATH/HOME/PREFIX 都要显式给，
   > 否则 dsh 找不到 `$HOME/.dsh`、也找不到自己。
2. `$PREFIX/var/service/dsh-web/log/run` —— svlogd，日志落
   `$PREFIX/var/log/sv/dsh-web/`（`current` 是软链）
3. `$PREFIX/bin/dsh-web-url` —— 从 `$LOGDIR/sv/dsh-web/current` 里
   `grep -aoE 'http://[^[:space:]]+token=[A-Za-z0-9_-]+'` 取**最后一条**；
   `--open` 用 `termux-open-url` 开机内浏览器；`--tunnel` 打印电脑侧隧道命令。

然后 `sv up dsh-web` + `sv-enable dsh-web`（开机自启）。
**验证要含崩溃自愈**：`kill -9` 主进程后应在数秒内重启（实测 2~3 秒）。

> ⚠️ **runsv 的 `env/` 目录在这版 runit（termux-services）上不生效** ——
> 实测在 `$PREFIX/var/service/dsh-web/env/` 下放 `DEEPSEEK_API_KEY` 再 `sv restart`，
> 服务进程 `/proc/<pid>/environ` 里**没有**该变量（`env/` 目录被完全忽略）。
> **要注入环境变量只能改 `run` 脚本**，在 `exec` 之前 source 一个文件：
> ```sh
> ENVFILE="$PREFIX/var/service/dsh-web/environment"
> if [ -f "$ENVFILE" ]; then . "$ENVFILE"; fi
> ```
> 别浪费时间在 `env/` 上。

> ⚠️ `sv status` 输出形如
> `run: dsh-web: (pid 22998) 15s; run: log: (pid 22997) 15s` —— 有**两个 pid**。
> `sed -n 's/.*pid \([0-9]*\).*/\1/p'` 贪婪匹配会抓到**日志进程**，
> 于是「崩溃自愈测试」杀的是 svlogd 而不是主进程。
> **要按 `/proc/*/cmdline` 精确定位**。同理，进程 cmdline 是**软链路径**
> （`…/bin/node --expose-internals …/bin/dsh web`），**不含 `bin.js` 字样** ——
> `pkill -f 'bin.js'` 永远匹配不到。

## 4. 访问边界（重要，不要绕过）

**`dsh web` 只绑 loopback，`--host 0.0.0.0` 被上游主动拒绝：**
```
error: --host 0.0.0.0 is intentionally not supported yet for safety:
it would expose remote code execution to the network; use 127.0.0.1 instead
```
这是**设计决定**，README 也写明「不支持绑定所有网络接口」。**不要在服务脚本里改掉。**

| 场景 | 做法 |
|---|---|
| 手机自己用 | 浏览器直接开 `dsh-web-url --open` 给的 URL |
| 电脑用 | SSH 隧道：`ssh -N -L 3080:127.0.0.1:3080 -p 8022 user@<手机IP>`，然后把 URL 里的 `127.0.0.1` 原样粘到电脑浏览器 |

认证流程（实测）：无令牌 → **401**；带 `?token=…` → **303 See Other** +
`set-cookie: dsh-auth-<authority哈希>=v1.<JWT>`（HttpOnly / SameSite=Strict /
Max-Age 30d）→ `location: ./` → **200**。cookie 的 authority **按请求的 Host 动态绑定**，
所以经隧道（`127.0.0.1:13080`）访问也能自适应，无需额外 `--trusted-host`。

**隧道场景实测（用 `-H "Host: …"` 在设备上原地模拟，不必真开隧道）**：
```sh
TOK=$(dsh-web-url | grep -aoE 'token=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2)
curl -s -o /dev/null -w '%{http_code}\n' -c ck -H 'Host: 127.0.0.1:13080' "http://127.0.0.1:3080/?token=$TOK"  # 303
curl -s -o /dev/null -w '%{http_code}\n' -b ck -H 'Host: 127.0.0.1:13080' http://127.0.0.1:3080/            # 200
curl -s -o /dev/null -w '%{http_code}\n' -b ck -H 'Host: 127.0.0.1:3080'  http://127.0.0.1:3080/            # 401 ← 绑定生效
```
第 3 条返回 401 正是设计如此（cookie 绑 authority），换个 Host 就得重新走一次令牌 URL。

另有 `--host` / `--port` / `--trusted-host` / `--no-open` 四个 flag
（`--no-open` 在无浏览器环境必须加）。

**前端是否完整**也能纯 curl 验：认证后 `GET /` 得 200 + ~34 KB SPA HTML，
再抽查 `assets/index-*.js`（~600 KB）、`manifest.webmanifest`、
`plugins/??@deepseek-ai/dsh-client-modules/client.js`（~40 KB）都 200 即前端资源齐。

**升级/重装后**：npm 升级会冲掉 `node_modules` 里的补丁。把补丁脚本持久放在设备上
（如 `~/dsh-termux/`），升级后重跑 `install.sh --all` 即可（幂等，已打过的会跳过）。

## 5. 唯一的功能门：模型凭据

**不一定要 DeepSeek 官方的 key** —— 可以接第三方。两种接法：Anthropic 端点走 §5.3，
OpenAI 兼容端点走 §5.4。但先认清这道门本身：

补丁全打完后，headless 的报错会**精确停在**：
```
MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official";
store DEEPSEEK_API_KEY through the credentials service (the web Models page writes it),
or export DEEPSEEK_API_KEY in the launching environment
```
两条路（**都不需要助手经手密钥**，让用户自己做）：
- **API key**：插件 `dsh-llm-deepseek-api-key`，`apiKeyEnv` 默认 `DEEPSEEK_API_KEY`，
  凭据键 `llm-deepseek-api-key`，落在 `$DSH_HOME/.credentials.yaml`
  → **Web UI 的「设置 → 模型」页可直接写**。
- **账号登录**：插件 `dsh-llm-deepseek-account`（路由 `deepseek-account`），
  Web UI 有 `dsh-client-ui-settings-account` 界面。

### 5.1 装完自检：用假 key 把链路推到最后一道门（推荐做法）

不用真 key 也能证明「除凭据外全链路已通」—— **塞一个假 key，看报错停在哪**：

```sh
DEEPSEEK_API_KEY=sk-0000000000000000000000000000000000000000 dsh headless "只回答两个字：收到"
```
| 输出 | 含义 |
|---|---|
| `MISSING_CREDENTIAL …` | 凭据还没进到进程（通路没接对） |
| `AUTH: Authentication Fails, Your api key: ****0000 is invalid (request_id: …)` | ✅ **全链路打通**：凭据读取、route 解析、出网、API 调用全部正常，只差真 key |

同时检查 `$DSH_HOME/sessions/<路径 slug>/session-<uuid>/` 下是否新增
`session.v4.jsonl.zstd` + `session.lock` —— 有就是 **session-persistence 的 link→rename 补丁生效**，
没报 `EACCES` 就说明 link 补丁齐了。

### 5.2 给守护服务注入 key：`dsh-set-key`（设备上已有的成品）

`$PREFIX/bin/dsh-set-key`（+ `~/dsh-termux/dsh-set-key` 备份）：
```sh
dsh-set-key sk-xxxx                    # 写 DEEPSEEK_API_KEY → 真调 API 校验 → sv restart → 回报进程是否带上变量
dsh-set-key --env DAHL_API_KEY <key>   # 写到指定变量名（第三方网关用这个）
dsh-set-key --show                     # 列出所有变量（打码）
dsh-set-key --clear [--env NAME]       # 不给 --env 删整个文件；给了只删那一个
```
**这个 environment 文件是多变量共存的**（写入是合并：同名覆盖、其它保留），
所以官方 key 和网关 key 可以同时躺着，由 profile 里各路由的 `apiKeyEnv` 决定用哪个。
要点：
- **校验用 `GET https://api.deepseek.com/models`**（带 `Authorization: Bearer`），
  `200` 有效 / `401|403` 无效 —— **不消耗 token**，比跑一次 headless 便宜。
  换了第三方后端时这个校验不适用 → 加 `--no-verify`（见 §5.3）。
- 为什么走环境变量而不是直接改 `.credentials.yaml`：那份文件由 provider 自己管理
  （原子写 + 跨进程锁 + 启动期**强校验**，顶层只允许 `version` / `refs` / `records`，
  记录 `kind` 只认 `api-key` 与 `grant`），**手工改坏了 `dsh web` 会起不来**；
  环境变量是官方支持的等价通路，坏了删文件即可。优先级：`.credentials.yaml` > 环境变量。
- key 存在时重启后要**回读 `/proc/<pid>/environ`** 确认真的带上了 ——
  光看 `sv restart` 返回 0 不算数。
- 进程识别务必定到 cmdline 含 `/bin/dsh web` 的那个 pid，否则会报 svlogd 那个（见 §3 的警告）。

### 5.3 换成第三方后端 · 接法①：Anthropic Messages 端点

**这条路（插件 `llm-deepseek`）的硬条件：第三方必须提供 Anthropic Messages 兼容端点**，
不是 OpenAI `/chat/completions`。只给 OpenAI 协议的网关请看 §5.4。
证据（读源码得出，非猜测）：

| 事实 | 位置 |
|---|---|
| `PUBLIC_BASE_URL = "https://api.deepseek.com/anthropic"` | `dsh-llm-deepseek/lib/index.js` |
| 鉴权头固定 `{ "x-api-key": <key> }` | `dsh-llm-deepseek-api-key/lib/index.js` |
| 请求体是 `{model, stream, messages, max_tokens, thinking:{type}, output_config:{effort}, system, tools[]}` | 同上 |
| 路径规则 `messagesApiRoot()`：baseURL 的 pathname 以 `/v1` 结尾就用原样，否则补 `/v1`，然后 POST `{root}/messages` | 同上 |

可配置项（`dsh-llm-deepseek-api-key` 的 `Config`，**全部标了 volatile**）：
`baseURL` · `apiKeyEnv`（默认 `DEEPSEEK_API_KEY`）· `thinking`(enabled/disabled) ·
`reasoningEffort`(off/low/high/max) · `maxTokens`（**默认 256000**）·
`defaultContextWindow`（**默认 1e6**）· `models[]`（默认 `deepseek-flash` / `deepseek-v4-pro`）。
另有环境变量 `DEEPSEEK_BASE_URL`，但**优先级低于 `config.baseURL`**。

**改哪个文件**：用户可写层就是 `$DSH_HOME/profiles/<web|headless>/cordis.patch.yml`
（id-targeted 覆写）。⚠️ **`profiles/<名字>/settings.yaml` 手写无效** —— 实测手写它完全不被读
（那是 settings 服务自己写的地方，别手写）。⚠️ **headless 走的是 headless profile**，
`dsh headless` 根本不读 web profile，两个都要改（第一次就踩了这个，白测一轮）。

实测筛过的端点（假 key，看谁报自己的鉴权错 → 说明路由存在且格式被接受）：

| 预置名 | baseURL | 假 key 返回 |
|---|---|---|
| deepseek | `https://api.deepseek.com/anthropic` | `Authentication Fails, Your api key: ****0000 is invalid (request_id: …)` |
| zhipu | `https://open.bigmodel.cn/api/anthropic` | `令牌已过期或验证不正确`（智谱自己的中文报错）|
| kimi | `https://api.moonshot.cn/anthropic` | `Invalid Authentication` |
| ark | `https://ark.cn-beijing.volces.com/api/coding` | `The API key format is incorrect. Request id: …` |
| minimax | `https://api.minimaxi.com/anthropic` | `login fail: Please carry the API secret key in the 'X-Api-Key' field` |
| dashscope | `https://dashscope.aliyuncs.com/api/v2/apps/claude-code-proxy` | `DeepSeek Messages request failed (401)`（通用 401，证据较弱）|
| siliconflow | `https://api.siliconflow.cn` | `DeepSeek Messages request failed (401)`（同上）|

**模型 id 不要猜**：各家改名很快（智谱首页已是 GLM-5.x），一定要从服务商文档的
「Anthropic / Claude Code 接入」那节取，通过 `--model` 传。填错会在验证阶段被对方明确报错。
同时 `agent-default-model` 的 `model` 也要跟着改，否则默认模型在选择器里不存在。

**成品：`$PREFIX/bin/dsh-set-provider`**（+ `~/dsh-termux/` 备份）
```sh
dsh-set-provider                                     # 看当前后端
dsh-set-provider --list                              # 列预置
dsh-set-provider zhipu --key sk-xxx --model glm-4.6  # 切过去（写 patch + 写 key + 重启 + 端到端验证）
dsh-set-provider --clear                             # 回官方默认
```
选项：`--model`(逗号分隔多个) `--max-tokens`(默认 8192) `--context-window`(默认 131072)
`--thinking`(默认关) `--profile "web headless"` `--no-restart`；
接法②专用的 `--api` / `--provider-id` / `--key-var` 见 §5.4。
预置名会自动带上对应协议（如 `dahl` → `openai-completions`）。

### 5.4 换成第三方后端 · 接法②：OpenAI 兼容网关（`llm-pi-ai` 通用路由）

**大量网关只提供 OpenAI 协议**（`POST {root}/chat/completions` + `Authorization: Bearer`），
且不给 Anthropic 旁路。实测 **Dahl 网关**（`https://inference.dahl.global/v1`）对
`/v1/messages`、`/anthropic/v1/messages`、`/api/v1/messages` … **所有** `/messages` 路径
统一回 **405 Method Not Allowed**，而 `/v1/chat/completions` 直接 200
（`system_fingerprint: vllm-0.25.1`）→ 这种端点用 §5.3 那条路**接不上**。

dsh 自带**第二个** LLM 插件 **`dsh-llm-pi-ai`**，默认已在 profile 里启用、`providers: {}` 空转。
它是通用 provider 适配器，支持 **7 种 wire protocol**：

```
anthropic-messages · openai-completions · openai-responses ·
azure-openai-responses · openai-codex-responses · bedrock-converse-stream · deepseek
```

配置形状（`Config = z.object({ providers: z.dict(profile) })`，**字典键就是 provider id**）：

```yaml
- id: llm-pi-ai
  config:
    providers:
      gateway:                            # provider id：必须小写字母开头、只含 [a-z0-9-]
        apiKeyEnv: DSH_GATEWAY_API_KEY    # 凭据**引用名**（环境变量名），不是 key 本身
        displayName: gateway
        api: openai-completions           # ← 显式给 api 时不需要内置 catalog
        baseURL: https://inference.dahl.global/v1
        defaultContextWindow: 131072
        defaultMaxTokens: 8192
        models:
          - id: deepseek-ai/DeepSeek-V4-Flash-0731
            name: deepseek-ai/DeepSeek-V4-Flash-0731
- id: agent-default-model
  config:
    provider: gateway                     # ← 指向上面那个 provider id
    model: deepseek-ai/DeepSeek-V4-Flash-0731
```

要点（都验证过）：
- **`api` 必须显式给**。不给会去找内置 catalog，找不到就报
  `model "…" needs an api; the installed catalog does not describe it, so set the route's
  api to the wire protocol its endpoint speaks`。
- 协议实现来自外部包 `@earendil-works/pi-ai@0.85.1`（`dist/api/openai-completions.js`），
  dsh 装完就在，**无需额外安装**。
- 模型 id 带 org 前缀（`deepseek-ai/…`、`zai-org/…`、`MiniMaxAI/…`）时**原样填**，别改。
- `agent-default-model.provider` 直接写 pi-ai 的 provider id（不是 `deepseek-official`）。

**成品：`dsh-set-provider` 已内建这条路**（预置表分「① Anthropic」「② OpenAI」两组）
```sh
dsh-set-provider dahl --key dahl_xxx     # 预置：带默认模型，一步到位
dsh-set-provider --base-url https://x/v1 --api openai-completions --key K --model m1,m2
dsh-set-provider                                         # 看当前后端（两种接法都认）
dsh-set-provider --clear                                 # 回官方默认
```
额外选项：`--api` `--provider-id`（默认 `gateway`）`--key-var`（默认 `DSH_GATEWAY_API_KEY`）。

**`--model` 的语义（2026-09-30 修的一个真 bug）**：原实现是纯累加
（`MODELS="${MODELS:+$MODELS,}${2:-}"`），而给预置名时脚本又会
`[ -n "$MODELS" ] || MODELS=$(preset_models "$1")` → **「预置名 + `--model`」把预置自带的
模型列表又抄了一遍，patch 里写出 6 条重复模型**（控制台就是这么踩到的）。
现在：**首次出现 `--model` = 覆盖，之后才是追加**，最终列表再按 id 去重。
两种入参顺序（预置名在前/在后）都实测一致。回归脚本见会话记录里的 5 条用例
（T1 预置+model、T2 反序、T3 多次累加、T4 去重、T5 只用预置）。
凭据用 `dsh-set-key --env <名字>` 写（§5.2 的工具已支持任意变量名 + 多变量共存）。

**怎么选接法**：端点以 `/anthropic` 结尾、或文档写「Anthropic / Claude Code 接入」→ ①；
端点是 `/v1`、`GET {baseURL}/models` 能列模型、模型名带 `org/` 前缀 → ②。

**Dahl 网关实测（2026-09-30）**

| 模型 | 网关直连结果 |
|---|---|
| `deepseek-ai/DeepSeek-V4-Flash-0731` | 200 ✅ 默认模型 |
| `MiniMaxAI/MiniMax-M2.7` | 200 ✅（输出含 `<think>`，是推理模型）|
| `zai-org/GLM-5.3-Flash` | **503 `no live host capacity`**（上游没算力，非配置问题；重试 4 次均如此）|

**这一轮的坑**：patch 块由工具用 marker（`# >>> dsh-provider`）管理，**没带 marker 的手写块
不会被替换**，会与新块并存 → 出现两个 `llm-pi-ai` 条目。手工试过之后要用工具正式配置前，
先把两个 profile 的 `cordis.patch.yml` 重置成纯 `[]` 哨兵。

### 5.5 改 `cordis.patch.yml` 时踩到的两个坑（都很致命）

1. **空数组的 `[]` 哨兵不能删。** 只有注释、没有 `[]` 的 patch 文件 YAML 解析成 `null`，
   `loadProfileDirectory` 直接抛 `failed to parse overlay`，**dsh 起不来**。
   清理逻辑写成「去掉 `[]` 再去掉自己的块」就正好制造这个状态（实测把服务搞 down）。
   正确做法：清理后若一条 patch 条目都不剩，必须补回 `[]`。
2. **写坏会被 `dsh-hmr` 立刻感知并把服务带 down**，所以流程必须是
   **先备份 → 写 → `dsh --dump-config --profile <p>` 组合校验 → 失败立刻回滚 + 重启**，
   不能「写完再校验」了事。
   
   另一个更隐蔽的坑：给 python 传「一整段多行 block」时，判「有没有真实条目」必须先把
   block **摊平成行**再 `startswith("- ")`；拿整段字符串去判会永远为假，
   于是往已有序列后面又补一个 `[]` → 又是非法 YAML。

`dsh --dump-config --profile <name>` 是最好的 YAML 校验器兼读回工具：
rc=0 就是合法，输出里 `- id: llm-deepseek` 下面能 `grep baseURL:` 到生效值。

## 6. 局域网访问 —— dsh 拒绝绑 LAN，只能外挂转发层

**「用 `http://<手机IP>:3080` 打不开」不是配置错，是设计。** 别在 dsh 侧试这三条：

1. `dsh web --host <lan-ip>` → webserver 插件 schema 只认 `"127.0.0.1" | "0.0.0.0"`，
   传局域网 IP 直接**启动失败**：
   `ValidationError: $.host expected "127.0.0.1" | "0.0.0.0" but got "…"`。
2. `dsh web --host 0.0.0.0` → 启动期显式拒绝：
   `--host 0.0.0.0 is intentionally not supported yet for safety: it would expose
   remote code execution to the network; use 127.0.0.1 instead`。
3. 所以 dsh 本体**永远只绑 127.0.0.1**，局域网入口只能由外部转发层提供。

### 6.1 关键机关：`/api` 的 Host/Origin 围栏（不处理它 UI 会半死）

`dsh-client-connection` 的 `isTrustedApiRequest()` 对每个 `/api/*` 请求做判定：
`Host` 是 loopback → 放行；否则必须命中 `trustedHosts`，且
`sec-fetch-site !== "cross-site"`、`Origin` 的 host 与 `Host` 一致。

`trustedHosts` 由 `dsh-web-app` 的 `resolveLanTrust(bindHost, extra)` 组装 ——
**只有 `bindHost === "0.0.0.0"` 时**才自动填入本机所有非内部 IPv4（`extra` 来自 `--trusted-host`）。
绑 loopback 时这个数组是空的，而这正是唯一能绑的东西。

**判定症状（很好认）**：同一个 `/api/xxx`，loopback 回 **404**（围栏放行、只是没这条路由），
局域网 authority 回 **403**（围栏拦下，根本没进路由）。

**修法**：`--trusted-host <lan-ip>`，**给不带端口的 IP 字面量**。
`isTrustedAuthority()` 里无端口条目走「hostname 相同即匹配任意端口」那条分支，
正好覆盖 `:3080`；带端口的写法只匹配那一个精确 authority。
端口可能由 OS 决定，所以**永远优先无端口写法**。

### 6.2 统一转发层：裸 TCP，**不要**做 HTTP 头改写

实测可行的做法是 `dsh-lan` 服务（`dsh-lan-gateway`）裸 TCP 转发
`<lan-ip>:3080` → `127.0.0.1:3080`：

- **不建议改写 `Host`**：改掉它看起来更优雅（服务端以为自己在 loopback，围栏全过），
  但 HTTP/1.1 **keep-alive** 上第 2..n 个请求走的是裸拼管，改不到 `Host`
  → 浏览器复用连接时 `/api/*` 又变 403。除非逼全部 `Connection: close`
  （代价大，还要放过 WS 升级）。**这条路是陷阱。**
- 裸 TCP 就够：浏览器 authority 就是 `<lan-ip>:3080`，服务端看到的也是它，
  靠 §6.1 的 `--trusted-host` 放行；**WebSocket 升级（对话流 `/api/remote.mux`）天然透传**。
- 网关要 `bind <lan-ip>` 而不是 `0.0.0.0`：dsh 已占 `127.0.0.1:3080`，`0.0.0.0:3080`
  会 EADDRINUSE；绑具体地址才可能同端口共存 → 用户看到的 URL 不必换端口。
- 转发实现：**别在 socket `close` 事件里 `destroy()` 对端**（会丢掉还没 flush 的响应，
  curl 表现为 `000`）。两端各 `pipe` 对方、只在 `error` 时成对销毁才对。

### 6.3 验收清单（缺一条都不算通）

```sh
# 设备侧
dsh-web-url --lan                                          # 带令牌的局域网 URL
# 客户端 —— 本机若带 HTTP_PROXY，一定加 --noproxy '*'
curl -s -o /dev/null -w '%{http_code}\n' http://<lan-ip>:3080/                 # 401
curl -s -c ck -o /dev/null -w '%{http_code}\n' "http://<lan-ip>:3080/?token=…" # 303
curl -s -b ck -o /dev/null -w '%{http_code}\n' http://<lan-ip>:3080/           # 200
curl -s -b ck -o /dev/null -w '%{http_code}\n' http://<lan-ip>:3080/api/x      # 404（403=围栏没放行）
curl -s -b ck -D- -o /dev/null -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://<lan-ip>:3080/api/remote.mux                                          # 101
```

### 6.4 「打不开」的隐形元凶：客户端本机的代理

客户端上若存在 `HTTP_PROXY`（macOS 上常由 IDE/助手注入），浏览器和工具会把
`http://<手机IP>:3080` **也走代理**，拿到
**502/503 `upstream connect failed: Connection refused (os error 61)`** ——
看着像手机故障，其实是中间那一跳返回的。判定：`nc -z <手机IP> 3080`。
端口真开着时代理也能过（实测 401）；端口没开才是 502/503。
排查一律先 `curl --noproxy '*'`。

**验收用的无头浏览器（agent-browser）另有自己的坑**，别把两件事混在一起：

- 它的 Chromium daemon **在启动时继承环境变量**，之后改环境没用 ——
  改 `AGENT_BROWSER_ARGS` / `AGENT_BROWSER_PROXY_BYPASS` 之前必须先 `agent-browser close --all`。
- 但**不要条件反射地加 `AGENT_BROWSER_ARGS="--no-proxy-server"`**：在 macOS 上这个参数
  会让 daemon 起不来，症状是一律 `✗ CDP response channel closed`（`close --all` 也救不回来）。
  先不加参数试一次；只有当系统代理真的把请求带偏时（`scutil --proxy` 显示开着
  127.0.0.1:8888）才需要绕，那时优先用 `AGENT_BROWSER_PROXY_BYPASS='*'`。
- 见过 daemon 崩溃后残留 `~/.agent-browser/default.{sock,pid,stream,engine,version}`，
  导致后续每次启动都 `CDP response channel closed`。清掉这几个运行时文件即可
  （**保留 `~/.agent-browser/browsers/`**，那是下载好的 Chromium）。
- `screenshot <path>` 的相对路径会被忽略（落到 `~/.agent-browser/tmp/screenshots/`），
  要用**绝对路径**。
- 取页面信息用 `get url` / `get title` / `get text body`；`eval` 偶尔返回空串，
  优先用 `get` 子命令。点元素用 `find text "<文本>" click`（不是 `find text "…" first click`）。

### 6.5 安全边界（动手前先讲清）

官方拒绝 `0.0.0.0` 的理由是「这个 Web UI 等于远程代码执行入口」。外挂转发层等于把同一扇门
开到局域网，**只是换了位置**。可接受的前提：可信内网 + dsh 自带的一次性令牌 +
authority 绑定的 HttpOnly cookie（无令牌 401，WS 路径同样 401）。
**公共 Wi-Fi 下必须 `sv down dsh-lan`** —— 关掉它不影响 dsh-web 本体，SSH 隧道照旧可用。

### 6.6 「设置 → 模型」报 `settings are unavailable in this browser` —— 客户端侧的 loopback 门

这是**独立于 §6.1 围栏的第二道门**，在**客户端**，改服务端任何参数都没用。

源码实证（`@deepseek-ai/dsh-client-connection/lib/client.js`）：

```js
function apply(ctx) {
  const pageLocation = typeof location === "undefined" ? void 0 : location;   // ← 浏览器地址栏
  installConnection(ctx, { ..., ...(pageLocation === void 0 ? {} : { location: pageLocation }) });
}
// installConnection 里：
handle = { isLoopback: transport?.ownsHost === true || pageLocation === void 0
                       || isLoopbackHostname(pageLocation.hostname), ... }
```

`@deepseek-ai/dsh-client-ui-settings/lib/client.js` 用它决定设置镜像的持久化模式：

```js
const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";
```

`memory` 模式下 `SettingsDescribeMirror.load()` 第一行就 `return`，**永不向 Host 取 describe**，
于是 `mirrored.view === undefined` → 设置页报
`settings are unavailable in this browser`。

**所以：只要浏览器地址栏是 `192.168.x.x`，原生设置页永远不可用 —— 这是 by design，不是 bug。**
`ctx.remote.$host` 不是从服务端 ready 帧来的（那帧只带 `home`），`isLoopback` 就在客户端现算。

三条出路，按推荐度排：

1. **打补丁**（已做，并入补丁器）：把那一行强制成 `isLoopback: true /* dsh-termux-lan */`。
   只影响「浏览器经非 loopback 地址打开」这一种情形（桌面端 `ownsHost===true`、
   Node 侧 `pageLocation===undefined` 本来就是 true）。
   **服务端围栏不受影响**——仍由 `--trusted-host` 决定，鉴权仍要 cookie。
   出问题用 `~/dsh-termux/backups/client.js.orig` 还原。
   重打：`dsh-patch-lan-settings`，或 `~/dsh-termux/install.sh --all`（已并入 `patches.py`）。
2. **SSH 隧道 + `127.0.0.1:PORT`**：地址栏是 loopback，原生可用，零补丁。想「不改上游」就走这条。
3. **自带控制台**：见 §6.7 的 `/ctl`，能改后端/凭据/模型，但不复刻 UI 内的设置面板。

判定顺序（别再猜）：先看地址栏 hostname 是不是 127/8；是的话再去查 §6.1 的围栏。

### 6.7 8030 控制网关：入口 + 控制台（`dsh-ctl`）

`dsh-lan`（§6.2）只是裸 TCP 转发，没有任何控制面。`dsh-ctl` 是**反向代理 + 控制台**：

| 路径 | 行为 |
|---|---|
| `http://<lan-ip>:8030/` | **网关自己的首页 = 控制台**（站点 + Token 管理）；未登录 → 落地页（现取令牌的入口链接） |
| `http://<lan-ip>:8030/ctl[/…]` | 控制台别名 + 控制台 JSON API（`{state,save,apply,key,models,verify,restart,log}`，都要求登录） |
| `http://<lan-ip>:8030/app` | **dsh 主界面**（网关自己取回 index.html 再吐出，见下） |
| `http://<lan-ip>:8030/app?token=…` | 用令牌登录：路径改写成上游 `/`，再把 303 的 `location` 改回 `/app` |
| `http://<lan-ip>:8030/app/*` | 302 回 `/app` |
| `http://<lan-ip>:8030/?token=…` | 302 到 `/app?token=…`（兼容老链接 / 书签） |
| 其余 | 原样反向代理到 `127.0.0.1:3080`（HTTP + WebSocket 升级都透传） |

**为什么 `/` 是控制台、`/app` 才是主界面**：一开始把已登录的 `/` 直接透传成 dsh 主界面，
用户从 `8030/` 进去看到的不是「网关管理」而是聊天页 —— 和「一个端口管 dsh 的设置、
也从这里进主界面」的预期不符。所以把主界面挪到子路径。

**子路径挂载的关键事实**（不要凭直觉改）：

- dsh **没有 SPA fallback**：`GET /dsh`、`/app/` 之类一律 **404**（实测），
  所以 dsh 前端不做路径路由，挂到子路径没有「深链 reload 404」的包袱。
- `dsh-web-frontend/dist/index.html` 用的是**相对引用** `./assets/…`、`./manifest.webmanifest`、
  `./favicon.svg`。于是：
  - 挂在 **`/app`**（无尾斜杠）→ 目录基是 `/` → 相对引用解析成 `/assets/…`
    → 正好命中兜底转发。**可行**。
  - 挂在 `/app/`（带尾斜杠）→ 目录基是 `/app/` → 变成 `/app/assets/…` → 上游 **404**。
    **不可行**，所以 `/app/` 必须 302 回 `/app`。
  - 直接上游取 `/` 拿不到子路径的 HTML，所以由网关**自己去上游取 `/` 的 HTML 再以 200 吐给浏览器**
    （`serveSpa()`：只带 `host` + `cookie` + `accept-encoding: identity`，不做 gzip 透传，
    否则自己产的响应没带 `content-encoding` 会让浏览器解错）。这等于免改上游地做了子路径挂载。
- 一定要再单独发一次 302 的 `location` 改写：上游令牌下发是 `303 location: ./`，
  在 `/app?token=…` 上解析回根，会把人送回控制台而不是主界面。

设计上的几个硬决定：

- **代理不改任何 header**（Host 原样转发）。`--trusted-host <lan-ip>` 是端口无关的 IP 字面量，
  天然覆盖 8030；改 Host 反而会在 keep-alive 的后续请求上坏掉（见 §6.2）。
- **写入只走 `dsh-set-provider` / `dsh-set-key`**（`execFile` 传 argv 数组，不过 shell），
  网关自己只读。单一真源，不复制一份 YAML 逻辑。
- **`/ctl` 复用 dsh 自己的登录 cookie**，不引入第二套口令。判定方式：
  把请求原样探到 `/api/__ctl_probe` —— 围栏+鉴权都过 → **404**（路由不存在）；
  **401**=没登录；**403**=围栏拒绝。启动时也会自检这条并打日志。
- 控制台里的模型 id 走 **`--no-restart`** 写入（脚本内部仍会做 `--dump-config` 组合校验 +
  失败回滚），重启与自检拆成独立按钮，避免一次点击卡两分钟。
- 控制台面板的 JS 全部用**绝对路径** `/ctl/api/…`，所以在 `/` 或 `/ctl` 上渲染都一致。

**踩过的坑**（都已修）：

1. `/ctl` 若按「dsh 不可达就放行」做，等于在最需要保护的时候把门开着 → 一律严格要 cookie。
2. cookie 是**按 authority 绑定的**，3080 登过 ≠ 8030 登过，两个端口各要登一次；
   落地页必须据此提示，否则用户会以为登录坏了。
3. 把 `/` 改成控制台之后，落地页上那条 `<pre>` 里打印的令牌 URL 还在指 `/?token=…`，
   点了只会转回落地页 → 要同步改成 `/app?token=…`，并在根上保留 302 兼容老链接。
4. 验收**必须做内容判别**，不能只看状态码：`/` 和 `/app` 已登录时都是 200，
   得断言 `/` 的 HTML 含「dsh 控制台」、`/app` 的 HTML 含 `id="root"` 与 `./assets/`，
   再从 `/app` 的 HTML 里抽出真实 asset 路径去请求一次（hash 会随版本变，别硬编码）。

### 6.8 站点 + 多 Token：N 个端点、每端点 N 把钥匙一起注册进 dsh（`dsh-set-provider --sites-file`）

需求演进：「**主要突出 token，每个站点可以有多个 token，需要备注**」。于是数据模型
从「账号」升成两层：

- **站点** = 一个 `baseURL` + 协议；
- **Token** = 这个站点上的一把钥匙，带**备注**（备注就是它在 dsh 里的显示名），各自一组模型。

dsh 侧的路由 id 是 **`<站点 id>-<token id>`**（如 `dahl-t1`）—— 每把 Token 一条路由，
所以同一个站点的多把钥匙在 **dsh 自己的模型选择器里**就能直接切换。这才是「多 token」
的意义：限流了就换一把，不用回控制台重配端点。

**前提（实测确认）**：`llm-pi-ai` 的 `supportedProtocols()` 有且只有三个 ——
`openai-completions` / `openai-responses` / `anthropic-messages`。即
**Anthropic 兼容端点也能走 pi-ai**，不用另外去动 `llm-deepseek` 插件。
实测请求形状：`POST {baseURL}/v1/messages?beta=true`，头 `x-api-key` +
`anthropic-version: 2023-06-01`，body 是标准 Anthropic Messages。
（`?beta=true` 来自 `@anthropic-ai/sdk` 的 middleware，不是我们加的，第三方网关一般忽略。）

生成的配置（每把 Token 独立 `apiKeyEnv`，互不干扰；`displayName` = `站点名 · 备注`）：

```yaml
# >>> dsh-provider (dsh-set-provider 管理；手改会被下次覆盖)
- id: llm-pi-ai
  config:
    providers:
      dahl-t1:                             # 路由 id = <站点 id>-<token id>
        apiKeyEnv: "DSH_DAHL_T1"
        displayName: "Dahl 聚合 · 主号"
        api: "openai-completions"
        baseURL: "https://inference.dahl.global/v1"
        defaultContextWindow: 131072       # 内置默认，不暴露给用户
        defaultMaxTokens: 8192
        models:
          - id: "deepseek-ai/DeepSeek-V4-Flash-0731"
            name: "deepseek-ai/DeepSeek-V4-Flash-0731"
      dahl-t2:                             # 同一站点的第二把钥匙 = 第二条路由
        apiKeyEnv: "DSH_DAHL_T2"
        displayName: "Dahl 聚合 · 备用号"
        api: "openai-completions"
        baseURL: "https://inference.dahl.global/v1"
        defaultContextWindow: 131072
        defaultMaxTokens: 8192
        models:
          - id: "zai-org/GLM-5.3-Flash"
            name: "zai-org/GLM-5.3-Flash"
      zhipu-t1:
        apiKeyEnv: "DSH_ZHIPU_T1"
        displayName: "智谱 GLM · 公司号"
        api: "anthropic-messages"          # 同一字典里混协议，实测可共存
        baseURL: "https://open.bigmodel.cn/api/anthropic"
        defaultContextWindow: 131072
        defaultMaxTokens: 8192
        models:
          - id: "glm-5"
            name: "glm-5"
- id: agent-default-model
  config:
    provider: "dahl-t2"
    model: "zai-org/GLM-5.3-Flash"
# <<< dsh-provider
```

清单 JSON 的形状（`--sites-file`）：

```json
{ "active": {"site":"dahl","token":"t2"},
  "sites": [
    { "id":"dahl", "name":"Dahl 聚合", "api":"openai-completions",
      "baseURL":"https://inference.dahl.global/v1",
      "tokens": [
        {"id":"t1","note":"主号","keyVar":"DSH_DAHL_T1",
         "defaultModel":"deepseek-ai/DeepSeek-V4-Flash-0731",
         "models":["deepseek-ai/DeepSeek-V4-Flash-0731"]},
        {"id":"t2","note":"备用号","keyVar":"DSH_DAHL_T2",
         "models":["zai-org/GLM-5.3-Flash"]}
      ]}
  ]}
```

**只有「已存凭据」的 token 才写路由**（重要）：凭据还没落盘的 token 写进配置，dsh 一请求就
`MISSING_CREDENTIAL`。所以生成器自己读一遍 `$PREFIX/var/service/dsh-web/environment`，
只给里面 `export NAME=` 存在的 token 出路由；被跳过的打在 stderr 上
（`! 跳过 dahl-t3（DSH_DAHL_T3 没配凭据）`），面板上对应显示「未注册 · 缺凭据」。
**当前激活的那把 token 必须有凭据**，否则直接报错、不动任何文件 ——
避免把一个必炸的配置写进去。

**摘要走 stderr、YAML 走 stdout**：调用方用 `BLOCK=$(python3 …)` 整段收走 stdout，
所以任何给人看的摘要都必须写 stderr，否则会被一起塞进 YAML 里。

**为什么 `defaultContextWindow` / `defaultMaxTokens` 必须显式写**：pi-ai schema 里这两个字段
默认 **262144 / 32768**（`DEFAULT_CONTEXT_WINDOW` / `DEFAULT_MAX_TOKENS`），后者对多数
第三方网关偏大、会被直接拒。脚本固定写 8192 / 131072（与单账号时代一致），
但**不在面板暴露** —— 用户明确要求「不要填 token 计数 / 价格设定」。

**清单的真源分两处，读时合并**：

- `$DSH_HOME/sites.json` —— 网关写的 v2 存档，装「备注 / 顺序 / 还没配凭据的 token」这些
  dsh 配置放不下的东西；
- `cordis.patch.yml` 的 `dsh-provider` 块 —— 真正生效的那份，也是 `active` 的真源。

读时依次降级：**`sites.json` → 旧 `accounts.json` → 从生效配置反解**，
所以任何历史形态（旧版单账号、只有配置没有存档、老的 `llm-deepseek` 块）都能直接读出来，
state 里 `migrated: true`，不用手工迁移。从生效配置反解时有个坑：
`displayName` 是 `"<站点名> · <备注>"`，反解时拆不开 —— 站点名要留空（让面板退回显示 id）、
备注要切掉前缀，否则会叠成 `Dahl 聚合 · Dahl 聚合 · 主号`。

**保存顺序是刻意的**：先落凭据 → 再改配置 → 最后重启。反过来会出现
「配置引用了还不存在的凭据」，服务起来直接 `MISSING_CREDENTIAL`；而且生成器只认**已有凭据**的
token，凭据晚一步那把 token 就白配了。

**面板（`dsh-ctl-panel.html`）以 Token 为主角**：站点一张卡，卡里每把 Token 一个块 ——
备注（大号输入框，视觉上最突出）/ 凭据状态徽章（`凭据已存 dahl_7…xxxx` / `缺凭据`）/
路由 id（`t1 → dahl-t1`）/ 凭据值（留空＝沿用现有的）/ 凭据变量名 / 模型标签 /
「从端点拉取模型列表」/「同步给本站其它 Token」。站点层只有显示名 / 协议 / baseURL。

面板两个前端教训：

1. **`oninput` 不要触发重渲染**：早期版本每个输入都重绘整个列表，结果正在打字的密码框
   被重建、字全丢。现在 `oninput` 只改内存对象，只有增删 / 勾选 / 切当前才重绘。
2. **模型名进 `onclick` 要两步转义**：先 `JSON.stringify` 生成 JS 字面量，再 `esc()` 进 HTML
   属性。只做 `esc()` 不够 —— `&#39;` 会被 HTML 解析器还原成 `'`，把 JS 字符串打断。

**新增站点是一档固定预设**（用户原话：「增加端点时 做一个固定的 类似 freellmAPi 一样」）：
`PRESETS` 里 `kind: 'fixed'` 一组是**本地 / 自建聚合路由**，开箱即用 ——
FreeLLMAPI（`http://127.0.0.1:3001/v1`，统一 key 前缀 `freellmapi-`，模型填 `auto`）、
FreeLLM（`npx freellm`，`:3000`）、Ollama（`:11434`）、LM Studio（`:1234`）；
`kind: 'cloud'` 一组是常用云端端点。面板用 `<optgroup>` 分档。
**模型 id 一律不预置**（聚合路由的 `auto` 除外）—— 各家改名太快，一律去端点上真拉。

#### 6.8.1 面板最终形态：一行一把 Token 的平铺列表（用户否掉了卡片式）

用户看了卡片式之后给了参考图，要求**以 token 为准、平铺成列表**（原话：「以token显示为标准
以列表展示」）。于是版面定成三层，别再改回去：

```
服务与运行环境（服务灯 / 版本 / 刷新 / 重启 / 自检 / 日志）
TOKEN 列表
  ├ 工具行：[站点选择] [＋ 新增 Token] [＋ 新增站点]   …   [全部检测][全部启用][全部停用]
  ├ 行（每把 Token 一行，grid 38/16/22/名称/备注/端点/健康）
  │    [启停开关] [状态点] [展开箭头] 名称+「当前」徽章 | 备注 | 端点 | 健康
  └ 展开区（点 ▸）：备注 / 识别名 / 所属站点
       站点设置（站点显示名 / 协议 / 站点 id(禁改) / baseURL）  ← 改了对该站所有 Token 生效
       凭据值（+ 清除已存凭据）/ 凭据变量名
       模型 chips + 从端点拉取 / 同步给本站其它 Token
       [检测] [删除站点] [删除这把]
输出
```

**被删掉的**（用户逐条点名，不要再加回来）：独立的「站点」表格卡、**「凭据总览」卡**
（凭据的清除挪到每把 Token 展开区的「清除已存凭据」）、token 计数 / 价格输入框。

**两处交互语义（用户明确区分过）**：

- **「＋ 新增 Token」= 复制当前 Token 的配置**，只换一个东西：`keyVar` 自动生成新名字。
  备注留空自己填。**必须换 keyVar** —— 复用会让两把 Token 共用同一把 key，删一把就伤到另一把。
- **「＋ 新增站点」才弹配置表单**（`#newsite`：从预设开始 / 站点 id / 显示名 / 协议 /
  baseURL / 第一把 Token 的备注 / 凭据值 / 凭据变量名）。默认隐藏，`toggleNewSite()` 开关。
  注意 `toggleNewSite(true)` 会**清空表单**，任何自动化测试都要「先开表单再填值」，顺序反了就白填。

#### 6.8.2 「清单」和「配置」分开写：结构改动走 `/ctl/api/manifest`

这是面板上最容易踩的一个坑，**必须在网关侧分成两个接口**：

| 动作 | 接口 | 干什么 |
|---|---|---|
| 加站点 / 加 Token | `POST /ctl/api/manifest` | **只**写 `$HOME/.dsh/sites.json`，不碰 dsh 配置 |
| 改配置 / 保存 | `POST /ctl/api/save` | 先落凭据 → 再跑 `dsh-set-provider` → 最后重启 |

原因：刚加出来的站点/Token 生来就是**不完整**的（没凭据、甚至没模型），而
`dsh-set-provider` 会按规矩**硬拒**（`至少要有一个模型 id` / 缺凭据），它拒的同时
**清单也不会被写**。结果就是「点了＋，列表里出现了，刷新一下那行没了」——用户会当成丢数据。
清单是面板的记忆、配置是 dsh 的事实，本来就是两件事。`apiManifest` 只做形状校验
（站点 id 正则、变量名正则、至少一个站点），不校验完整性。

面板侧配套一个 `draftPayload()`：`save()` 和 `persistManifest()` **共用同一份形状**，
避免两边字段慢慢长歪（`save()` 再往上叠 `keys` / `restart` / `verify`）。

加出来的 Token 没有凭据 → `dsh-set-provider` 会打一行
`! 跳过 gateway-t2（DSH_GATEWAY_T2_API_KEY 没配凭据）` 并**保持原路由不动**，
所以「先加后填」完全安全，dsh 不受影响。

#### 6.8.3 面板三个前端教训（都是实测炸出来的）

1. **别让局部变量遮蔽辅助函数**。`createSite()` 里写过 `var key = nsKey.value;`，
   而全局有个 `key(sid, tid)` 拼缓存键的辅助函数。后面的 `OPEN[key(sid,'t1')] = true`
   直接 `TypeError: key is not a function` —— **异常发生在落盘之前**，于是站点进了内存、
   请求根本没发出去，界面看起来一切正常。这类 bug 静态看代码很难发现，
   所以在面板自检里加了一条「`var/let/const` 声明的名字不能和已定义的函数重名」，
   一并抓出 `var api = …`（遮蔽 `api()`）、`var act = …`（遮蔽 `act()`）。
2. **后台自己跑的事必须静默**。页面加载时自动做一次健康探测，早期它会 `out('执行中…')`、
   `out('检测完成…')`，还会 `busy()` 把**所有按钮禁用**几秒 —— 用户在这个窗口里的点击
   被静默吞掉，刚点的动作结果也被一句「检测完成」冲掉。现在：自动探测调
   `healthAll(true)` / `api(name, body, quiet=true)`，不禁用按钮、不写输出面板，
   结束时再把 `out` 的原文还原回去。手动点「全部检测」才给完整反馈。
3. **健康列要区分「限流」和「异常」**。端点回 429/503 是**上游限速**，不是配置错
   （实测这个聚合站的 `/models` 会这样，隔几秒再打就 200）。429/503 显示 `限流 <code>`
   （黄），其它非 2xx 才显示 `异常 <code>`（红）；自动探测 60 秒内不重复
   （`sessionStorage['dsh-hl-at']`）。别把限流渲染成配置问题，用户会白折腾半天。

**归纳成一句**：健康探测只能证明「端点可达」，证明不了 key 有效 —— 有些聚合站的
`/models` 根本不校验鉴权（dahl 拿错 key 也回 200）。面板上写清楚这句，真正验 key 用「端到端自检」。

#### 6.8.4 bash 里的一个隐形坑：`-d "${VAR:-{}}"` 会多发一个 `}`

给 `curl -d` 传「可能为空的 JSON」时，很容易写成 `-d "${HP:-{}}"`。**bash 把冒号后第一个
`}` 当作参数展开的收尾**，于是实际参数是 `<HP的值>}` —— body 多一个花括号，网关
`JSON.parse` 失败、退化成空 payload，`apiHealth({})` 返回
`{"ok":false,"code":0,"ms":0,"out":"baseURL 必须以 http(s):// 开头"}`。

**它能骗过眼睛**：`"code":0` 看着像「连不上 / 被限流」，我第一轮就这么误判了。真实的
429 长这样：`{"ok":false,"code":429,"ms":197,"out":"GET … → 429（too many requests）"}` ——
**有具体的 code 和 ms**。区分方法：`code` 非 0 才是端点真的回了个状态码。

写法定死成两行：

```sh
[ -n "${HP:-}" ] || HP='{}'
curl -s -b ck.txt -X POST -H 'content-type: application/json' -d "$HP" "http://$IP:8030/ctl/api/health"
```

顺带一条同类事实：**8030 网关只监听 LAN IP，不监听 127.0.0.1**。设备上自测
`http://127.0.0.1:8030/...` 会直接 `000`，要用 `http://$IP:8030/...`
（`ip route get 1` 在 Termux 上取不到 IP，用 `dsh-lan-ip`）。

#### 6.8.5 用 agent-browser 验收这个面板（几个必踩的坑）

改完面板要真点一遍才算验过，用 `agent-browser` 时注意：

1. **必须 `NO_PROXY`**：`export NO_PROXY="192.168.3.190,127.0.0.1,localhost"`，
   否则本机代理会把 LAN 请求吃掉。（不要用 `--no-proxy-server`，那条会弄坏 headless。）
2. **先登录再访问 `/`**：8030 的控制台要 cookie。先
   `open "http://192.168.3.190:8030/app?token=$TOK"`（`$TOK` 从设备
   `$PREFIX/var/log/sv/dsh-web/current` 里 grep 出来），再 `open "http://192.168.3.190:8030/"`。
3. **`--path` 必须绝对路径**：`screenshot -f --path /abs/path.png`，相对路径会
   `No such file or directory`。
4. **点击前先 `scrollintoview`**：面板很长时，`click <sel>` 会「✓ Done」但事件根本没到元素
   （实测按钮的 click 监听计数为 0）。先
   `eval '(function(){document.getElementById("btnAddApi").scrollIntoView({block:"center"})})()'`
   再点。为此面板给关键按钮留了稳定 id：列表下部的 `#btnAddApi`、接口展开区的
   `[data-adet] .kadd button`、弹窗的 `#mOk`。
5. **别用 `button:has-text(...)`**：这个 CLI 不支持，会 `Element not found`。
   用 id / `[data-adet="<sid>"] .kadd button` 这种标准 CSS。
6. **`eval` 里不能裸 `return`**（`SyntaxError: Illegal return statement`），
   包一层 `(function(){ … })()`；返回对象用 `JSON.stringify(...)`。
7. **别复用上一轮的 ref**：`@ref` 是快照作用域的，列表重绘后编号会错位，
   曾把「点创建接口」点到「全部检测」上去。要稳就用 CSS 选择器。
8. **改完先跑 `tests/audit-panel.js share/dsh-ctl/panel.html`**（纯 Node，不开浏览器）：
   语法 / 函数重复 / `on*` 引用是否都有定义 / `getElementById` 的 id 是否存在 /
   已删卡片残留 / 两层结构是否齐（`.arow` `.krow` `data-adet` `data-kdet` `#modal`）/
   **局部变量是否遮蔽函数名**。最后一条抓到过两次真 bug（`var key`、`var el`）。
9. 本地版式迭代用 `tests/preview-panel.js`（假数据，:8877，不写任何文件）：
   每次请求现读 `dsh-ctl-panel.html`，改完刷新即可；它把 `/ctl/api/manifest` 也
   模拟成「改内存 STATE」，所以能验证「加完刷新还在」。
   **它监听 127.0.0.1 且日志逐请求打印**，排查「按钮到底有没有发请求」非常好用。
10. **纯静态自检证明不了交互**：audit 只说明「函数在、字样在」，不说明「点开 ▸ 真出密钥列表」。
   交互层跑 `tests/test-panel-ui.js`（playwright headless，自己起 preview 假后端，
    59 项断言：展开/收起、弹窗新增+编辑、加密钥、开关互斥、删密钥/删接口、刷新记忆）。
    ```bash
    cd .remote
    NODE_PATH=/Users/zhao/.npm-global/lib/node_modules \
      ~/.workbuddy/binaries/node/versions/20.18.0/bin/node test-panel-ui.js
    ```
    （全局装过 `playwright@1.63.0`，浏览器在 `~/Library/Caches/ms-playwright`。
    注意 `:visible` 是 playwright 伪类，`page.evaluate` 里的 `querySelector` 不认。）

#### 6.8.6 详情默认收起 + 一次术语统一（用户明确要求）

用户原话：「每个 token 下 不要显示 详细信息我查看时才显示，默认不显示…另外 界面的对应的
名词改一下 有可能现在叫的不对」。

**① 默认全收。** `applyState()` 里原来是 `OPEN[k] = total <= 1 ? true : !!prevOpen[k]`
（只有一把就自动展开）—— 删掉那个特例，改成 `OPEN[k] = !!prevOpen[k]`，
除用户自己点过 ▸ 的以外，详情一律 `display:none`。
唯一例外：`addTokenQuick()` / `createSite()` 之后**把刚加的那把展开**（用户马上要填密钥）。
判据：`grep -c 'total <= 1'` 必须为 0。

**② 术语表**（同一件东西以前有三个名字，最容易看晕）：

| 旧 | 新 | 为什么 |
|---|---|---|
| Token（列表 / 新增 Token / 把 Token） | **密钥**（一张 API Key） | 「token」在 LLM 语境里指计量单位，dsh 设置里也有 token 计数，两者会混 |
| 凭据值 | 密钥值 | |
| 凭据环境变量名 | 环境变量名 | 它确实就是 provider 的 `apiKeyEnv` |
| 识别名 | 显示名 | |
| 端点（列头）/ baseURL | 接口地址 | |
| 已注册路由 / 未注册 | 已写入 dsh / 未写入 | 「注册路由」是内部说法 |
| 当前使用 / 当前启用 | 当前生效 | 同一个状态两个词 |
| 站点 | **接口** | 列表以「接口地址」为标准，一个接口挂 N 把密钥；见 6.8.9 |

协议 / 备注 / 健康 / 限流 这几个词不动。
改文案**必须同步** `install-ctl.head.sh` 的断言和 `audit-panel.js` 的 `must` 列表 ——
两边都是字符串匹配，改词必红。

#### 6.8.7 连测几把就报 429、单把「检测」却正常 —— 是自己打自己

现象（用户报的）：页面刚加载完再点一次整表检测 → 健康列一排 `限流 429`；
单独点一把「检测」→ 正常。**根因不是配置**：

1. 页面加载时会自动探测一次，紧接着又测 = 同一把密钥几秒内打两遍；
2. 当时 `healthAll` 是 `Promise.all([next(), next(), next()])` **并发 3 路**，
   同一出口 IP 瞬间三个请求 —— 上游按 IP 窗口限速，第二遍必吃 429。

（顺带排除一种假象：安装器里 `-d "${HP:-{}}"` 多出一个 `}` 会让 body 畸形、
返回 `code:0`，那根本不是 429 —— 见 6.8.4，两个现象别混。）

**三条修法**：

1. **结果复用**：`HL[k].at` 记时间戳，同一把密钥 `RETEST_MS = 20000` 内不重复打端点，
   直接复用上次结果；输出里明说「其中 N 把是 20 秒内刚测过的，直接复用上次结果」。
   用户自己点「检测」传 `force=true` 跳过复用 —— 主动作必须是真动作。
2. **429 退避重试**：拿到 429/503 不下结论，`sleep(600 * n)` 后重试，`HL_MAX_TRY = 3`；
   重试仍被限才显示「限流」，title 注明「重试 N 次后仍被限」。
3. **串行 + 间隔**：改成一把一把来、每把之间停 700ms，去掉并发三路。

自动探测（`healthAll(true)`）保持 60 秒节流，且**完全静默**：不禁用按钮、不写输出面板 ——
否则它会静默吞掉用户的点击、冲掉刚点出来的结果。

**后来按钮整个被用户砍掉了**（见 6.8.11）：不要整表「一键全测」，改成**每个接口行一个「检测」**。
所以 `healthAll` 现在只剩「页面加载时那一次静默自动探测」这一个调用点，
而 `healthApi(sid)` 复用了同一套串行 + 复用 + 退避机制（见 6.8.11）。

**验证方式（不用真机也能验）**：给 `tests/preview-panel.js` 的 `/ctl/api/health` 加一句
「同一 keyVar 第一次必回 429」，看它的**逐请求日志**：每把密钥应出现**两次**请求
（429 → 退避 → 200），多把之间串行不重叠；等 20 秒后再点每把只打 1 次；
20 秒内再点一次，日志里**一个新请求都没有**。

#### 6.8.8 「同一时间只有一把启用」—— 启用 = 当前生效 = 写进 dsh 的那条路由

用户要求（原话）：「同时只能启用一个」。以前这三件事是**分开**的三个状态，所以能出现
「两把同时亮着启用」、也能出现「启用的是 A、生效的是 B」。现在**合成一件事**：

> 启用（开关）= 当前生效（`active`）= 会被写进 dsh 的那**唯一一条**路由

为什么必须合：`dsh-set-provider` 会把**每一把** `enabled: true` 的 token 都写进 providers
字典 —— 多把启用 = 多开线路，跟面板上「只有一把生效」这句话直接矛盾。

**面板侧（`dsh-ctl-panel.html`）**

- `onlyEnable(sid, tid)` 是**唯一入口**：遍历全清单把 `enabled` 只留给目标那把，并同步
  `DRAFT.active`。别处不许各写各的赋值 —— 那正是以前能同时亮起两把的原因。
  自检里加了一条 `.enabled *= *true` 必须为 0 来守它。
- **开关关不掉自己**：dsh 至少要留一条能注册的路由，全关等于让它起不来（保存也会被拒）。
  用户点关闭时把勾**弹回去** + 一句「直接点目标那把的开关，这把会自动让位」。
- 删掉两个按钮：**「全部启用」天然就会造出多把启用**，「全部停用」会造出「一把都没启用」
  这个非法状态。顺带删掉详情里的「设为当前」按钮 —— 开关就是当前，重复了。
- **新增站点 / 新增密钥默认 `enabled: false`（待命）**：不抢当前生效那把的位置。
  只有「清单里一把都没启用」时（首次建站）才顶上。这两处原来都是 `enabled: true`，
  不改就等于每加一把就多亮一把。
- 删站点 / 删密钥时，如果删掉的正是启用那把，启用位接给清单剩下的第一把。

**网关侧（`dsh-ctl-gateway`）**

- `normalizeActive(sites, wantSite, wantToken)`：写盘前归一化，只留一把 `enabled: true`
  （选定顺序：精确命中 → 同站点第一把 → 清单第一把）。`apiManifest` 与 `apiSave` 都先过它。
  这是**兜底**：清单被手改过、或换版本读到老数据时也不会漏出去多把启用。
- `readSites()` 展示时按生效配置（`cordis.patch.yml` 里 `agent-default-model` 的 provider）
  对齐 `enabled`，只改内存不写盘 —— 免得列表里同时亮起两把。

**验证方式（三层，都不用截图）**

1. **单元**：从网关源码里正则抽出 `normalizeActive` 函数体 `eval('(' + m[0] + ')')` 单独跑
   （别去 require 整个网关，它会 listen）。用例：两把都启用只留指定的、want 不存在退到
   同站点第一把、站点不存在退到第一把、空清单返回空；每条都断言「启用数恰好 1」。
2. **本地预览**：点第二把的开关 → 断言启用数=1、`active` 跟着走、勾选数=1；
   点当前启用那把的开关 → 状态不变、勾选弹回；`＋ 新增密钥` / `＋ 新建站点` → 新那把是待命；
   再查 `/ctl/api/state`（预览里 `manifest` 已同步做归一）确认落盘后仍是 1 把。
3. **真机安装器**：静态断言（`同一时间只有一把`、`onlyEnable(` ≥2、`全部启用|全部停用` = 0、
   `.enabled = true` = 0、网关 `normalizeActive(` ≥2）+ 一条实测：**故意把这把清单里所有密钥
   都标成 `enabled: true` 发给 `/ctl/api/manifest`**，断言落盘后只剩 1 把且与 `active` 同号，
   然后 `cp -a` 还原并核对 md5 与测试前一致。

**模型发现：两种协议不一样，不能一套头打天下**

| 协议 | 列表 URL | 鉴权 |
|---|---|---|
| `openai-completions` | `GET {baseURL}/models` | `Authorization: Bearer <key>` |
| `anthropic-messages` | `GET {baseURL}/v1/models?limit=1000` | `x-api-key` + `anthropic-version: 2023-06-01` |

（anthropic 的列表 URL 接受带或不带末尾 `/v1` 的根，要归一化。）

> ⚠️ **有些网关的 `/models` 根本不校验鉴权** —— 用错的 key 照样返回 200。
> 所以「拉模型成功」**不能**当作 key 可用的证据，必须真跑一次推理
> （面板的「端到端自检」或 `dsh headless "…"`）才算数。这个坑实际骗到过一次。

**这次踩到的坑（都已修）**：

1. `apiModels()` 里 `const url = …` 算出来了却**没传进 `http.request`** —— options 对象
   里没有 host/path，于是一直在请求 `localhost:80`。等于「从端点拉模型」**从来没生效过**，
   只是被前面的 `if (!key)` 挡着没暴露。教训：拼了个 URL 又不用，就是把功能假实现了，
   一定要用真端点跑一次，别只看它"没报错"。
2. 改成 `new URL()` 解析后立刻撞第二个：第三方端点都是 `https:`，而 `http.request`
   直接抛 `ERR_INVALID_PROTOCOL: Protocol "https:" not supported`。
   要按 `target.protocol` 选 `https` / `http` 模块（Termux 上 `require('https')` 可用，
   不需要额外装东西）。
3. **`dsh headless` 在 SSH 会话里直接跑必然报 `MISSING_CREDENTIAL`** —— 因为设备上的
   `dsh-set-key` 是**故意不写 `.credentials.yaml`** 的（那份文件由 provider 自己原子写 + 跨进程锁，
   手改坏了 dsh web 起不来），走的是 `$PREFIX/var/service/dsh-web/environment` 环境变量通路。
   而 SSH 会话不继承 runit 服务的环境。所以要么
   `set -a; . "$PREFIX/var/service/dsh-web/environment"; set +a`，要么用面板的自检
   （它内部就是这么干的）。**排查时先怀疑自己没加载 env，别急着怀疑 key 坏了** ——
   我这次就先误判成了回归。
4. **`MISSING_CREDENTIAL` / `TRANSPORT: Connection error` / curl 返回 `000` 都可能是瞬时抖动**：
   这次手机切网导致设备侧 DNS 解析失败（`dns=2.5s` 之后 000），同一时刻本机 curl 也偶发 40s 超时，
   几分钟后全部自愈，配置一个字没改。**判定顺序应该是 ① 本机 curl 同一端点 → ② 设备 curl
   同一端点 → ③（前两步都正常）才去怀疑配置。** 直接跳到 ③ 会把自己带进沟里。

#### 6.8.9 列表改成两层：接口（接口地址）→ 展开才是密钥列表；新增走弹窗

用户原话：「新增站点 使用弹窗模式，另外 列表 以接口地址为标准 一个接口地址 内部可以有多个key，
前边点击展开是 key 的列表，每个接口 增加密钥放到 接口展开列表的最下边，站点列表下部添加 + 即可，
点击 弹窗增加新的接口api」。

**结构（一层套一层，别再加层级）**

```
接口行 .arow    [▸] 接口地址 | 名称·当前 | 协议 | N 把密钥 | 健康
  └ 接口展开区 .adet（data-adet="<sid>"，默认 display:none）
      ├ 信息条 .abar  ：接口 id / 协议 / N 把密钥 / 预设  +  [编辑接口] [删除接口]
      └ 密钥列表 .klist（左侧竖线缩进一级）
          ├ 密钥行 .krow  [开关] [dot] [▸] 名称·当前 | 备注 | 健康
          │   └ 密钥详情 .kdet（data-kdet="<sid>/<tid>"，默认收起）
          │       备注 / 显示名 / 所属接口 / 密钥值 / 环境变量名 / 模型 / 检测 / 删除这把
          └ 「＋ 增加密钥」.kadd    ← 必须在 klist 最后一个子元素
[＋ 新增接口] #btnAddApi           ← 在 #list 下方的 .addapi 里，虚线整条
```

> 这一版的「密钥行自己还有 ▸ 展开」后来被用户否掉了 —— 见 **§6.8.10**，
> 密钥那一级不再展开，详情整块搬进了接口的编辑弹窗。

- **两层各有自己的箭头**：接口层 `toggleApi(sid)` 用 `OPEN[sid]` + `.adet`/`.achev`；
  密钥层 `toggleOpen(sid,tid)` 用 `OPENK['sid/tid']` + `.kdet`/`.kchev`。
  以前只有一个 `OPEN`（扁平存 `sid/tid`），改名时两个都保留在 `applyState()` 里
  （`OPEN[s.id]`、`OPENK[k]` 各按 `prev*` 还原），否则一刷新展开态就丢。
- **接口地址是行主体**：`baseURL` 加粗等宽打头，名称/协议/密钥数/健康跟在后面。
  密钥行里**删掉**原来那一列接口地址（父行已经说了），只留 名称 / 备注 / 健康。
- **接口本身的编辑（地址 / 协议 / 显示名 / 预设）从密钥详情里搬进弹窗** ——
  这也是「改地址只在一个地方改」的意思。密钥详情里不再有「接口设置」块。
- 界面上的词一律「接口」（`站点` 全清，面板 + 网关 + `dsh-set-provider` 一起改）。

**弹窗（一个，两种模式）**

- HTML 里放**常驻**表单（不是 JS 拼的字符串）——`audit-panel.js` 要能查到 id；
  这点跟列表行相反（行是拼字符串的）。
- `openApiModal()` → 新增：标题「新增接口」、按钮「创建接口」、显示 `#mFirstKey`（第一把密钥）、
  `nsId` 可编辑。`openApiModal(sid)` → 编辑：标题「编辑接口 · <sid>」、按钮「保存修改」、
  隐藏 `#mFirstKey`、`nsId` 置 `disabled`（**接口 id 建好不能改**：dsh 路由 id 挂在它上面）。
  两者共用一个 `#mOk`，由 `modalOk()` 按 `MODAL.mode` 分派到 `createSite()` / `updateApi()`。
- 点遮罩关闭：`onclick="if(event.target===this)closeModal()"`；`✕` 也关。
- **校验不过就不关弹窗**，错误写给输出面板 —— 别让用户填了半天一键没。
- `el(id)` 是这一段的 `getElementById` 简写。**代价**：`out()`、`addModel()`、`setTok()`
  里原来都有局部 `var el = …`，全得改名（`node`），否则就是那个
  「局部变量遮蔽全局函数」的老坑（`audit-panel.js` 会直接报 ✗）。

**这次的验证（59 项，跑 `tests/test-panel-ui.js`）**：真 chromium 驱动假后端，
覆盖「接口地址是行主体 / 默认全收 / 展开的是密钥列表 / kadd 是最后一个子元素 /
接口详情里没有接口设置 / 弹窗两种模式 / 非法地址不关弹窗且不发请求 /
按接口加密钥且环境变量名不撞 / 跨接口开关互斥 / 关不掉自己 / 删密钥删接口 / 刷新记忆展开态 /
零 JS 报错」。静态自检（`audit-panel.js`）另加「两层结构齐不齐」和「旧类名已清」两组。

#### 6.8.10 弹窗分工定稿：接口弹窗只管接口，密钥在自己的列表里管

用户原话（连着两次纠偏）：

1. 「每个key 不再可以展开 接口地址 后边增加一个编辑 按钮 点击弹窗 当前地址的配置内容」
2. 「接口编辑之显示接口相关的即可 不在显示 key  key在展开列表中单独管理 key后要增加删除 按钮」

第 ① 次我把「当前地址的配置内容」理解成「这个接口 + 它下面所有密钥」，
把密钥详情全塞进了接口弹窗；第 ② 次用户纠偏：**弹窗要分工**。

**最终形态**

```
接口行 .arow  [▸] 接口地址 | 名称·当前 | 协议 | N 把密钥 | 健康 | [检测][编辑]
  │                     ↑ 检测 = healthApi(sid)      ↑ 编辑 = 接口弹窗 openApiModal(sid)
  └ 接口展开区 .adet（data-adet="<sid>"，默认 display:none）
      └ 密钥列表 .klist（左侧竖线缩进一级）
          ├ 密钥行 .krow  [开关] [dot] 名称·当前 | 备注 | 健康 | [编辑][删除]
          │                  ↑ data-kedit → openKeyModal(sid,tid)   ↑ data-kdel → delToken
          │                  密钥行本身没有 ▸，没有第三级
          └ 「＋ 增加密钥」.kadd     ← 仍是 klist 的最后一个子元素

接口弹窗 #modal  = 只有接口本身：预设 / 接口 id（只读）/ 显示名 / 协议 / 接口地址
                   + 左下角「删除这个接口」#mDel        ← 里面一把密钥都不显示
密钥弹窗 #kmodal = 只有这一把：备注 / 显示名 / 环境变量名 / 密钥值（+清除已存密钥）
                   / 模型（拉取·同步·手填·候选勾选）/ 检测 + 左下角「删除这把密钥」#kDel
```

**接口行两个按钮都要 `event.stopPropagation()`** —— 整行是「展开」的点击区，
不拦就被吃掉（点编辑顺手把接口收起来）。

**三个必须记住的实现点**

1. **两个弹窗互不干扰、但和列表共用同一份 `DRAFT`**：
   - `renderList()` 末尾调 `refreshKeyModal()`：只在 `MKEY.sid` 有值且弹窗可见时重绘 `#kBody`；
     **先存 `.mbox` 的 `scrollTop` 和 `document.activeElement.id`，重绘后还原 + 重新 focus** ——
     不保滚动位置，点一个模型勾选就被弹回顶部；不保焦点，手填模型那个输入框会失去焦点。
   - `refreshKeyModal()` 里先 `tokById()`，查到 null 就 `closeKeyModal()` ——
     **删掉的那把会让弹窗自己关掉**，不用在每个删除分支里手写关闭。
2. **`setTok(sid,tid,'note'|'label')` 只改数据 + 局部改列表行、不重绘**（否则吞掉正在打的字）；
   模型类操作（`toggleModel`/`addModel`/`delModel`/`candAll`/`copyModels`/`pullModels`）
   走 `renderList()` 自动两处同步。手填模型的输入框 id 是 `km-<sid>-<tid>`（`addModel()` 按它找）。
3. **没保存的密钥值不能被一次刷新吞掉**：密钥值只活在 `DRAFT` 里（清单本来就不存明文）。
   `applyState()` 重建 DRAFT 前先用 `prevKey['sid/tid']` 把 `_newKey` 捞回来；
   保存成功后 `afterSave()` 调 `clearNewKeys()` 再清掉明文。
   另外弹窗盖着输出面板，`healthOne(...,false,true)` 的结果用户看不见 ——
   所以弹窗 bar 上加了 `data-mhint` 小徽章，`paintHealth()` 一起刷它。

**连带删掉的东西（状态一起删，别留孤儿）**

| 删掉 | 说明 |
|---|---|
| `.kdet` / `data-kdet` / `data-kchev` / `OPENK` / `toggleOpen()` | 密钥级行内展开，彻底不要了 |
| 接口展开区的信息条 `.abar` | 徽章信息（id/协议/预设）没用了 |
| 密钥详情里的「所属接口」下拉 + `moveTo()` | 「换接口挂」整个不要了 —— 要换就删了在目标接口重加 |
| `#mKeyList` / `modalKeysHtml()` / `modalKeyHtml()` / `refreshModalKeys()` | 接口弹窗里那块密钥区 |
| 整表「全部检测」按钮 | 换成每个接口行一个「检测」，见 6.8.11 |

**验证（都不截图）**

- `tests/audit-panel.js share/dsh-ctl/panel.html`：结构组断言 `data-kedit=` / `data-kdel=` / `class="c-act"` /
  `data-ahealth=` 各 ≥1，`mKeyList|modalKeysHtml|modalKeyHtml` 为 0；
  弹窗组断言 `id="kmodal"` / `id="kBody"` / `keyModalHtml(` / `refreshKeyModal(` / `keyModalDel`。
  另注意：它统计「函数重复定义」必须用 `/^function …/gm`（**只看行首无缩进的顶层函数**）——
  面板里有几处同名的内部 `step()` / `next()`，用 `\bfunction\b` 会误报。
- `tests/test-panel-ui.js`：**99 项全过**。新增覆盖：接口弹窗里没有密钥区、
  密钥行尾「编辑」开的是密钥弹窗（且接口弹窗没跟着开）、密钥弹窗里只有这一把、
  改备注列表同步、**没保存的密钥值关掉重开还在**、行尾「删除」直接删一行、
  弹窗里删除后弹窗自动关、接口级检测（见 6.8.11）。
- 真机 `install-ctl.sh` 断言同步换新：`data-kedit=` / `data-kdel=` / `data-ahealth=` /
  `id="kmodal"` / `id="kBody"` / `keyModalHtml(` / `refreshKeyModal(` / `keyModalDel` / `healthApi(`，
  并硬断言 `mKeyList|modalKeysHtml|modalKeyHtml`、`全部检测`、`data-kdet=|data-kchev|OPENK`、
  `function moveTo\(|toggleOpen\(` 全为 0。

#### 6.8.11 砍掉整表「全部检测」，改成每个接口一个「检测」

用户原话：「全部检测 也不要了 每个接口 那增加一个检测即可」

**为什么不能直接复用 `healthOne`**：它开头有一道门

```js
if (!t.enabled || (!t.hasKey && !t._newKey)) { HL[k] = null; paintHealth(sid, tid); return }
```

即「只测当前启用那把」。而全局只有一把启用（见 6.8.8），
所以拿它当接口级检测用，除启用那把所在的接口外，**其余接口点了毫无反应**。

**改法**：给 `healthOne` 加第 5 个参数 `allowIdle`

```js
function healthOne(sid, tid, silent, force, allowIdle){
  …
  if ((!t.enabled && !allowIdle) || (!t.hasKey && !t._newKey)) { HL[k] = null; …; return }
```

再新增 `healthApi(sid)`：把该接口下 `hasKey || _newKey` 的密钥**串行**测一遍
（含待命），每把之间停 700ms，复用 `RETEST_MS` 结果缓存与 `HL_MAX_TRY` 退避 ——
和 `healthAll` 用的是同一套机制，差别只在「测哪些」。

| 函数 | 测谁 | 现在谁在调 |
|---|---|---|
| `healthOne(sid,tid,silent,force,allowIdle)` | 一把 | 密钥弹窗里的「检测」；`healthApi`/`healthAll` 内部 |
| `healthApi(sid)` | 这个接口下**所有已存密钥**（含待命） | 接口行尾的「检测」 |
| `healthAll(silent)` | 全局**启用**那把（只有一把） | 只剩页面加载时那一次静默自动探测 |

接口行「健康」那一列仍只显示**启用中那把**的结果（`paintApiHealth`），
它和「检测」按钮的结果不是同一个集合。这条以前写在卡片说明里，后来用户把整段说明删了
（见 6.8.12），所以现在只能靠列本身的语义 + `title=` tooltip 表达。

**验证**：`tests/test-panel-ui.js` 的 1b / 1c 两段。1b 点启用接口的检测，
断言 20 秒内**不新增 health 请求**（复用页面加载那次结果）、不动展开状态、输出面板写结论；
1c 展开一个下面有 2 把已存密钥（且全是待命）的接口，点检测，断言
**发出 4 次 health 请求**（每把 429 一次 + 退避重试一次），
且待命那把的 `window.HL['intern/t1'].state` 不再是 `busy`。

#### 6.8.12 卡片下不挂长段说明文字（用户偏好，且有断言锁住）

用户原话：「……（那段描述）太长 不要了」

「接口列表」卡片 `#list` 上方原来有一段 6 行的 `<p class="muted">`：讲「一行一个接口
= 一个接口地址 + 一种协议」「密钥挂在接口下、加密钥在列表最下边」「开关 = 启用 =
当前生效 = 写进 dsh 的那条路由」「健康只证明地址能连、不能证明密钥有效」……
用户要删，**别再顺手补回来**。这类解释一律下沉到 `title=` tooltip 或干脆留白，
不占卡片位置（面板已经很长了，用户是滚动着看的）。

**怎么锁住它**（不然下次「顺手加个说明」就回归了）

| 位置 | 断言 |
|---|---|
| `audit-panel.js` 第 8b 组 | **结构**：`<h2>接口列表</h2>` 与 `<div class="ahead">` 之间不许出现 `<p>` —— 换个措辞重写也会被抓到<br>**文字**：「一行一个&lt;b&gt;接口&lt;/b&gt;」「不能证明密钥有效」「三件事是同一件事」三个特征串计数必须为 0 |
| `install-ctl.head.sh` | `标题下已无长段说明文字` 期望 0 |

**新加的字符串断言必须做一次反证**：把删掉的那段临时插回去，`audit-panel.js` 应立刻报
两条 ✗，删掉又全绿。不做这一步就不知道断言是真在测还是在空转 —— 这轮就是这么验的。

#### 6.8.13 「点了没反应」通常是提示被弹窗盖住了 —— 校验失败必须写在弹窗里

用户报的：「新增接口弹窗 点击创建接口无反应」。

**先别怀疑事件没绑上。** 静态检查早就证明了按钮的 `onclick="modalOk()"` 有定义
（`audit-panel.js` 的「on* 引用全部有定义」一直是绿的）。真跑一遍才看清：

| 填什么 | 弹窗关了吗 | 列表变了吗 | 弹窗内能看到错误吗 | 错误写到哪了 |
|---|---|---|---|---|
| id 用大写 `MyApi` | 不关 | 没变 | **看不到** | 页面底部的 `#out` |
| id 带下划线/点 | 不关 | 没变 | **看不到** | 同上 |
| 地址漏协议头 | 不关 | 没变 | **看不到** | 同上 |
| id 留空 / 地址留空 | 不关 | 没变 | **看不到** | 同上 |

`#out`（「输出」卡片）在卡片流最底部，而弹窗是 `position:fixed` 的遮罩层 ——
**错误提示被自己盖住了**。用户视角就是：点按钮，什么都没发生。

**根因不是崩溃，是提示不可见。** 更值得记的是：**我的测试断言比需求弱**——
第 5 段当时断言的是

```js
ok('输出面板给出原因', (await page.locator('#out').innerText()).includes('http'), '')
```

「错误写进 `#out` 了」= 绿。可需求是「用户要知道为什么没建成」。断言只覆盖了实现，
没覆盖体验，所以 bug 从断言底下大摇大摆走过去。**凡是有 UI 的断言，问一句
「这条断言挂了，用户会看见差别吗」——不会就说明它测的是实现细节。**

**改法（三件套）**

```js
// 1) 弹窗里加内联红条（贴在标题下、表单上方，不用滚就能看到）
<p class="merr" id="mErr" style="display:none"></p>

// 2) 失败统一走一个入口：弹窗可见 + 输出面板留痕 + 聚焦出问题的输入框
function modalFail(msg, focusId){ modalErr(msg); out(msg); if (focusId && el(focusId)) el(focusId).focus() }

// 3) 一改输入就自动消红条，不用关掉弹窗重开（挂在遮罩层上，靠事件冒泡吃全部输入）
<div id="modal" … oninput="modalErr('')" onchange="modalErr('')">
```

`openApiModal()` 与 `closeModal()` 里都补 `modalErr('')`，上一轮的红条别带进下一轮。

**两个细节**

- `modalErr` 用的是 `textContent`，所以消息里**不能放 `<b>` 之类的标签** ——
  会原样显示成字面量。想要强调就用「」引号。（第一版就踩了，已改回纯文本。）
- 报错文案要**给出下一步**，不只是宣判：id 不合法时顺手算出
  `sid.toLowerCase().replace(/[^a-z0-9-]/g,'-')` 塞进提示里（「比如改成 "my-api-v2"」）；
  地址缺协议头就回显用户填的原值。用户能一次改对，比读一遍规则快。

**验证**

- `audit-panel.js`：`id="mErr"` = 1、`modalFail(` ≥ 8、`modalErr(` ≥ 3、
  `oninput="modalErr('')"` = 1。
- `test-panel-ui.js` 第 5/6 段：非法输入时 `#mErr:visible` 可见且写的是原因、
  `document.activeElement.id === 'nsUrl'`（聚焦到出错框）、一改输入红条消失、
  id 重复时红条说「已经存在」；**编辑接口那一侧（`updateApi`）同样验一遍**。
- 真机：`install-ctl.sh` 加「弹窗内联红条」「校验失败在弹窗里看得见」「输入即清红条监听」三条。

#### 6.8.14 「保存并重启」里的重启，对**配置**是多余的；对**密钥**是必需的

用户问：「底部的保存并重启 验证下 是否改配置文件后无需重启即刻生效」。

**结论分两条链路，方向相反 —— 别把它们混成一句「要/不要重启」。**

| 改什么 | 写成什么文件 | 需要重启吗 | 生效延迟 |
|---|---|---|---|
| 接口地址 / 协议 / 模型 / 显示名 / 启用切换 | `~/.dsh/profiles/web/cordis.patch.yml` | **不需要** | 实测 **2.3 秒** |
| 密钥值（面板里填的新 key） | `$PREFIX/var/service/dsh-web/environment` | **需要** `sv restart dsh-web` | 启动期注入，不重启永不生效 |

**为什么配置不用重启**：dsh 自带 `@deepseek-ai/dsh-hmr`，包描述就是
"Coordinated module and profile configuration hot reload"。`dsh-base` 的 bundle 里：

```yaml
- id: hmr
  name: '@deepseek-ai/dsh-hmr'
  disabled: !!js "!ctx.get('profileContext')"   # web profile 有 profileContext → 启用
  config:
    root: []                                    # 不监听源码模块，只保留配置监听
```

它用 chokidar 监听 `profile.patchPath` 与 home patch，`awaitWriteFinish` 默认
2 秒稳定窗口 + 100ms debounce —— 正好对上实测的 2.3 秒。

**为什么密钥必须重启**：`dsh-set-key` 写的是 runit 服务的 `environment` 文件，
由 `./run` 在**进程启动时** `set -a; . environment; set +a` 注入。运行中的进程 environ
不会因为文件改了而更新。（`dsh-set-key` 头部注释也写了为什么不用 `.credentials.yaml`：
那份文件 provider 自己管，手工改坏会让 dsh 起不来。）

**⚠️ 排查这类问题最容易踩的坑：不要用日志当判据。**
我一开始注入「不存在的插件包」「非法 YAML」「重复 id」三种探针，日志**一行都不出**，
PID 也不变，看起来像"完全没反应"。实际是 HMR 正常静默重载 —— 源码里只有
`warnings` 才 `logger.warn`，成功路径**不打任何日志**。日志静默 ≠ 没生效。

**正确的判据：直接问运行中的进程。** dsh web 的 `/api/*` 是 RPC（不是 REST），
浏览器里看到的一次 GET 实际是 POST：

```bash
# 1) 用 token 换成 cookie
TOK=$(grep -o 'token=[A-Za-z0-9_-]*' "$PREFIX/var/log/sv/dsh-web/current" | tail -1 | cut -d= -f2)
curl -s -c /tmp/cj -b /tmp/cj -o /dev/null -L "http://127.0.0.1:3080/?token=$TOK"

# 2) POST，body 必须 {type, rpcId, method, payload:{args:{}}}
#    method 要写端点全名 "llm/listProviders"（写 "listProviders" 会 400
#    method does not match endpoint）；payload 必须含且仅含一个 plain-object args
curl -s -b /tmp/cj -X POST -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"1","method":"llm/listProviders","payload":{"args":{}}}' \
  http://127.0.0.1:3080/api/llm/listProviders
# → {"result":{"ok":true,"value":[{"id":"atria-t1","name":"atria"},…]}}
```

这条返回值是**运行中进程内存里的真状态**。同族的还有：
`/api/session/modelCatalog`（默认模型 + 各组模型清单）、`/api/settings/describe`
（`agent-default-model` 当前值）、`/api/credentials/describe`、`/api/session/list`。

**另一个坑**：`sed -i` 是「临时文件 + rename」，会**换 inode**。想用
「进程 inotify watch 的 ino 是否等于文件 ino」来证明"监听了没"会得到假否 ——
chokidar 靠目录事件重新注册，inode 对不上不代表没监听。**用行为（API 返回值）判定，别用 inode。**

**现成复验脚本**：`bin/verify-hot-reload.sh`（在设备上跑）
—— 改一次 `displayName`、轮询 API 测延迟、md5 对账还原、报 pid 有没有变。
连跑三次稳定在 2275–2303 ms。

**这条结论对面板的直接影响**：8030 面板的「只写配置（不重启）」按钮，
在**本次没有填新密钥值**时是完全够用的；「保存并重启」多出来的那次 restart
只是让浏览器端重连一次，对配置生效没有贡献。面板上那句
「有 N 把填了新密钥值 —— 那要回列表点『保存并重启』才写进服务环境」（§6.8 系列里那条提示）
**是对的**，别按"重启多余"去把它删掉。

## 7. 已知降级边界

| 能力 | 状态 |
|---|---|
| `node-pty` | ✅ 可加载 |
| `koffi` | ✅ 可加载（Android 上 `statx()` 需 `--target=aarch64-unknown-linux-android30`） |
| `sharp` | ❌ **不可用**：`Could not load the "sharp" module using the android-arm64 runtime`（无预编译包，需 `pkg install libvips` + `SHARP_FORCE_GLOBAL_LIBVIPS=1`）→ 影响 `dsh-attachment-local`、`dsh-spill-policy`，即**读图片/附件不可用** |
| cmake / ninja / libvips | 未装（源里有） |

## 8. 上游版本调查（2026-09-29）

`latest = 0.1.7-rc.2`（可用）· `next = 0.2.0-rc.1` · `alpha = 0.1.7-alpha.2`。

**0.2.0-rc.1 一条 Android 兼容问题都没修**：`bin.js` 仍是裸 `#!/usr/bin/env node`，
`session-persistence` 仍 `import { link, … }`，`app-boot` 仍无 `expose-internals` 分支，
仍依赖 `node-addon-require-builtin ^0.1.6`。
→ **留在 latest 打补丁是对的路**；升级后重跑补丁器。

社区参考：`deepseek-ai/deepseek-harness` discussion **#1588**
「dsh runs on Termux (Android) — with 5 small patches」——**列了 5 条但缺 flock 那条**；
另有 `lilyco-42/dsh-termux`（一键 installer，7 补丁）、`w1ngy/dsh-android-setup`、
`Vengisk/deepseek-harness-termux`（对照 0.1.0-rc.6，套到 0.1.7-rc.2 上不够用）。
**上游迭代很快，动手前先 `npm view @deepseek-ai/dsh versions` 确认当前版本，
并把补丁器的锚点断言当护栏 —— 改不了就停手，不要硬改。**

## 9. 排查时容易吃亏的通用 Termux 事实

- **取本机局域网 IP**：Termux 默认**没有 iproute2**（`ip` 命令不存在）；
  `getprop dhcp.wlan0.ipaddress` 在 Android 16 上返回空；`hostname -I` 不支持；
  **`ifconfig wlan0`（带接口名）输出为空**，只有**无参 `ifconfig`** 才列得出
  → 必须自己按接口块解析。**最省事的是 `SSH_CONNECTION` 的第 3 个字段就是本机地址**。
- **`link(2)` 在 Android 被拒（EACCES）**，`rename(2)` 正常 —— 见 §1④。
- **`flock(2)` 在 bionic 上可用** —— 见 §1③。
- 写脚本时：**非引号 heredoc 里注释写反引号 = 生成期真执行**（会被替换成命令输出，
  甚至撕碎后面的代码）。**heredoc 一律用引号形式 `<<'XXX'`**；代价是路径要在运行时用
  `${PREFIX:-…}` 取。
- **往设备推大文件别走 `ssh "echo <base64> | base64 -d | bash"`**：整段 base64 是**单个命令行
  参数**，超限就静默失败 —— 症状是命令 1 秒内返回、**完全没有输出**，很容易误判成脚本报错。
  实测这条路径在 ~106 KB base64 时还能过，涨到 ~176 KB（安装器源文件 132 KB）就不执行了。
  **判据**：`./.ssh_helper.sh <file>` 秒回且零输出 = 大概率是超限，不是脚本的问题。
  **解法**：改 `scp` 落盘再执行（本仓库有 `.scp_push.sh <本地文件> <远端路径>`，
  同样是 expect 喂密码；scp 是流式的，不受单参数长度限制）。传完先 `bash -n` 校验再跑。
- **`node --check` 认扩展名**：`node --check x.new` 会报
  `ERR_UNKNOWN_FILE_EXTENSION: Unknown file extension ".new"` —— 这和语法错误无关。
  校验前先 `cp` 成 `.js`，或直接放到目标位置再查。
- Termux 上 `/tmp` 常不可写（用 `$TMPDIR`）；**用户数据不要放项目目录**。

## 10. 怎么连上去 / 为什么不走 docker

- 连接方式是 **expect + base64 的 SSH 助手**（`ssh -p 8022 <user>@<手机IP>` + 密码），
  写法与登录信息见 skill `termux-remote-deploy` §「SSH 执行助手」——
  **不要另起炉灶写 `ssh host "…"`**，引号会被 double-escape 打死。
- **「搞不定就上 docker」在无 root 的 Termux 上是死路**：真 Docker 需要内核
  namespace / cgroup，Termux 拿不到（`proot-distro` 不是 Docker，是用户态 syscall 翻译）。
  真要 glibc 环境只能走 `proot-distro` 装 Ubuntu（见 skill `termux-proot-linux-container`），
  但那会**换一批问题**：proot 下原生模块与 `link(2)` 的行为都需要重新验一遍，
  且性能与内存都比原生差。
- **判断顺序**：先按 §1 的四类不兼容逐条核对补丁（用 `install.sh --status` 空跑对账），
  再按 §5.1 用假 key 推到 AUTH 那道门 —— 这两步都过了却还「用不了」，
  那问题在凭据或上游版本，**不在环境**，此时换 proot/docker 也救不了。

设备上现成的成品（都在 `$PREFIX/bin/`，并在 `~/dsh-termux/` 留了副本）：

| 命令 | 作用 |
|---|---|
| `dsh-web-url` | 取当前带令牌的访问 URL；`--gw` 给 8030 网关首页（控制台）URL；`--app` 给 8030 `/app` 带令牌的 dsh 主界面 URL；`--lan` 给 3080 裸转发 URL；`--all` 四条都给；`--open` 开机内浏览器；`--tunnel` 打印电脑侧隧道命令 |
| `dsh-lan-ip` | 打印本机局域网 IPv4（`wlan0` 优先，跳过 `lo`/`vgate0`） |
| `dsh-lan-gateway` | 裸 TCP 转发层，把 loopback 的 dsh web 暴露到局域网 3080（见 §6.2） |
| `sv up|down dsh-lan` | 开/关 3080 裸转发入口，不影响 dsh-web 本体 |
| `dsh-ctl-gateway` | 8030 反向代理 + 控制台（见 §6.7）；页面在 `$PREFIX/share/dsh-ctl/panel.html` |
| `sv up|down dsh-ctl` | 开/关 8030 网关，不影响 dsh-web 本体 |
| `dsh-patch-lan-settings` | 幂等打「局域网下开放设置页」的补丁（见 §6.6），已并入 `patches.py` |
| `dsh-set-key` | 注入/查看/清除模型 key（`--no-verify` 供第三方用，`--env NAME` 多变量共存） |
| `dsh-set-provider` | 切第三方后端 / `--clear` 回官方（见 §5.3/§5.4） |
| `~/dsh-termux/install.sh --all` | npm 升级后重打全部补丁（幂等；含 §6.6 那条） |
