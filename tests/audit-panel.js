// 面板静态自检：语法 + 函数定义/重复 + onclick 引用 + id 引用 + 已删卡片残留
const fs = require('fs')
const p = process.argv[2]
const s = fs.readFileSync(p, 'utf8')

const m = s.match(/<script>([\s\S]*?)<\/script>/)
if (!m) { console.log('✗ 没找到 <script>'); process.exit(1) }
const js = m[1]

// 1) 语法
try { new Function(js); console.log('✓ 脚本语法 OK') }
catch (e) { console.log('✗ 语法错误：' + e.message); process.exit(1) }

// 2) 函数定义
// 只看顶层函数（行首无缩进）：healthAll / healthApi 里各有一个内部 step/next，
// 嵌套函数同名是正常的，不该算「重复定义」。
const defs = [...js.matchAll(/^function\s+([A-Za-z_$][\w$]*)\s*\(/gm)].map((x) => x[1])
const dup = defs.filter((n, i) => defs.indexOf(n) !== i)
console.log('函数 ' + defs.length + ' ' + (dup.length ? '✗ 重复: ' + [...new Set(dup)].join(',') : '✓ 无重复'))

// 3) onclick / oninput / onchange 里引用的函数（跳过 JSON.stringify 这种带点号的）
const refs = new Set()
for (const mm of s.matchAll(/\bon(?:click|change|input|keydown|blur|focus)\s*=\s*"([^"]*)"/g)) {
  for (const c of mm[1].matchAll(/(?<![.\w$])([A-Za-z_$][\w$]*)\s*\(/g)) refs.add(c[1])
}
const builtin = new Set(['if', 'return', 'this', 'event', 'String', 'Number', 'parseInt', 'confirm', 'alert'])
const missing = [...refs].filter((r) => !defs.includes(r) && !builtin.has(r))
console.log('on* 引用 ' + refs.size + ' 个函数，' + (missing.length ? '✗ 未定义: ' + missing.join(',') : '✓ 全部有定义'))

// 4) getElementById / key() 引用的 id 是否在 HTML 里
const ids = new Set([...s.matchAll(/\bid\s*=\s*"([^"]+)"/g)].map((x) => x[1]))
const getIds = new Set([...js.matchAll(/getElementById\(\s*'([^']+)'\s*\)/g)].map((x) => x[1]))
const badIds = [...getIds].filter((i) => !ids.has(i) && !i.startsWith('nm-'))
console.log('getElementById ' + getIds.size + ' 个，' + (badIds.length ? '✗ 不存在: ' + badIds.join(',') : '✓ 引用的 id 都存在'))

// 5) 动态拼的 id（前缀）
const dynPrefix = [...js.matchAll(/getElementById\(\s*'([^']+)'\s*\+/g)].map((x) => x[1])
const badDyn = dynPrefix.filter((pre) => ![...ids].some((i) => i.startsWith(pre)))
console.log('动态 id 前缀 ' + dynPrefix.length + ' 个，' + (badDyn.length ? '✗ 没有匹配的元素: ' + badDyn.join(',') : '✓ 都能匹配到'))

// 6) 已删掉的卡片残留
for (const [name, pat] of [['sites表', /id="sites"/g], ['creds表', /id="creds"/g], ['旧tpl', /id="tpl"/g]]) {
  const c = (s.match(pat) || []).length
  console.log('已删卡片残留 ' + name + ': ' + c + (c ? ' ✗' : ' ✓'))
}

// 7) 不该出现的东西
for (const [name, pat] of [['token计数', /maxTokens|token计数|inputTokens|计费/g], ['价格字段', /价格|单价|pricing|\$\/1M/g]]) {
  const c = (s.match(pat) || []).length
  console.log('不该有 ' + name + ': ' + c + (c ? ' ✗' : ' ✓'))
}

// 7b) 旧术语残留（2026-09-30 统一过命名：Token→密钥、凭据→密钥值/环境变量名、识别名→显示名，
//     同一轮把「站点」改成「接口」—— 列表以接口地址为标准，密钥挂在接口下面）
for (const [name, pat] of [
  ['Token 列表/新增 Token', /Token 列表|新增 Token|把 Token/g],
  ['凭据*', /凭据值|凭据环境变量名|凭据已存|缺凭据|清除已存凭据|识别名/g],
  ['注册路由/当前使用', /注册路由|未注册|当前使用/g],
  ['站点（已改名接口）', /站点/g],
]) {
  const c = (s.match(pat) || []).length
  console.log('旧术语残留 ' + name + ': ' + c + (c ? ' ✗' : ' ✓'))
}

// 7d) 两层结构：接口（接口地址）→ 行尾「＋ 增加密钥」「编辑」；点行展开密钥列表。
//     密钥那一级没有第三层：行里不再有 ▸，行尾「编辑」开单把密钥的弹窗，「删」直接移除这把。
//     2026-09-30 晚深度精简：健康探测整条删了（HL/healthOne/healthApi），要查密钥好使
//     就保存时勾「保存后自检」或去密钥弹窗「从端点拉取模型列表」。
for (const [name, pat, want] of [
  ['接口行 .arow', /class="arow/, 1],
  ['密钥行 .krow', /class="krow/, 1],
  ['接口展开容器 data-adet', /data-adet=/, 1],
  ['接口行展开入口 toggleApi(', /toggleApi\(/, 2],
  ['接口行里有「＋ 增加密钥」按钮（addKeyHere）', /addKeyHere\(/, 2],
  ['增加密钥按接口加（addKeyTo）', /addKeyTo\(/, 2],
  ['「＋ 新增接口」按钮在列表下部', /id="btnAddApi"/, 1],
  ['新增接口走弹窗 openApiModal', /openApiModal\(/, 3],
  ['接口行尾部有「编辑」按钮（stopPropagation + openApiModal）', /stopPropagation\(\);openApiModal\(/, 1],
  ['密钥行尾部有「编辑」按钮', /onclick="openKeyModal\(/, 1],
  ['密钥行尾部有「删」按钮', /onclick="delToken\(/, 1],
  ['密钥行尾是操作列 .k-act', /class="k-act"/, 1],
  ['健康探测已删（healthOne）', /healthOne\(/, 0],
  ['健康探测已删（healthApi）', /healthApi\(/, 0],
  ['健康探测已删（HL 状态表）', /HL\[|var HL/, 0],
  ['接口级「检测」按钮已删（data-ahealth）', /data-ahealth=/, 0],
  ['弹窗里「检测」按钮已删（data-mhint）', /data-mhint=/, 0],
  ['密钥行没有二级展开（无 OPENK/箭头/详情容器）', /OPENK|data-kchev|data-kdet=/, 0],
  ['旧的常驻表单已删', /id="newsite"/, 0],
  ['旧的站点下拉已删', /id="siteSel"/, 0],
  ['旧的行式表格类名已清', /class="trow|class="tdet/, 0],
  ['旧的接口信息条 .abar 已删', /class="abar"/, 0],
  ['密钥的旧「换接口挂」已删', /function moveTo\(|toggleOpen\(/, 0],
  ['「清空配置」入口已删（clearAll / apply mode:clear）', /clearAll|mode:'clear'/, 0],
  ['候选模型批操作已删（candAll/candNone/copyModels）', /candAll\(|candNone\(|copyModels\(/, 0],
]) {
  const c = (s.match(new RegExp(pat.source, 'g')) || []).length
  const good = want === 0 ? c === 0 : c >= want
  console.log('结构 ' + name + ': ' + c + (good ? ' ✓' : ' ✗ 期望 ' + (want === 0 ? '0' : '≥' + want)))
}

// 7e) 两个弹窗分工：接口弹窗只管接口本身；密钥弹窗管一把密钥的全部配置
for (const [name, pat, want] of [
  ['接口弹窗容器 id="modal"', /id="modal"/, 1],
  ['接口弹窗标题 / 提示 / 确认按钮', /id="mTitle"|id="mHint"|id="mOk"/, 3],
  ['新增时才显示「第一把密钥」组', /mFirstKey/, 2],
  ['接口弹窗里不再有密钥区（mKeyList 已删）', /mKeyList|modalKeysHtml|modalKeyHtml/, 0],
  ['接口弹窗里能删接口', /modalDelApi\(/, 2],
  ['编辑接口入口 updateApi', /function updateApi\(|updateApi\(\)/, 1],
  ['点遮罩关闭弹窗', /event\.target===this/, 2],
  ['点「编辑」不触发展开（stopPropagation）', /stopPropagation\(\)/, 1],
  // 校验失败的提示必须落在弹窗里。真出过 bug：只写 out()，而 out 面板被弹窗盖着，
  // 用户点「创建接口」看不到任何变化，报「点了没反应」。
  ['弹窗内联红条 id="mErr"', /id="mErr"/, 1],
  ['校验失败在弹窗里可见（modalFail 定义+调用）', /modalFail\(/, 8],
  ['红条能写能清（modalErr）', /modalErr\(/, 3],
  ['弹窗上挂了输入即清红条的监听', /oninput="modalErr\(''\)"/, 1],
  ['密钥弹窗容器 id="kmodal"', /id="kmodal"/, 1],
  ['密钥弹窗正文容器 id="kBody"', /id="kBody"/, 1],
  ['密钥弹窗正文渲染 keyModalHtml', /keyModalHtml\(/, 2],
  ['打开 / 关闭密钥弹窗', /openKeyModal\(|closeKeyModal\(/, 4],
  ['列表重绘同步密钥弹窗', /refreshKeyModal\(/, 2],
  ['密钥弹窗里能删这把', /keyModalDel\(/, 2],
]) {
  const c = (s.match(new RegExp(pat.source, 'g')) || []).length
  console.log('弹窗 ' + name + ': ' + c + (c >= want || want === 0 && c === 0 ? ' ✓' : ' ✗ 期望 ' + (want === 0 ? '0' : '≥' + want)))
}

// 7c) 节流/状态保持机制（健康探测已全删，这里只留与精简版有关的）
for (const [name, pat, want] of [
  ['详情默认收起（没有 total<=1 自动展开）', /total\s*<=\s*1/, 0],
  ['健康探测的节流常量已删（RETEST_MS）', /RETEST_MS/, 0],
  ['429 退避重试已删（HL_MAX_TRY）', /HL_MAX_TRY/, 0],
  ['保存成功后清掉明文密钥值', /clearNewKeys\(/, 2],
  ['刷新不吞掉还没保存的密钥值', /prevKey\[k\]/, 1],
  // 「同一时间只有一把启用」：启用位只有一个入口 onlyEnable()，
  // 别处不许直接 t.enabled = true（那正是以前能同时亮起两把的原因）。
  ['启用位唯一入口 onlyEnable（定义+调用）', /onlyEnable\(/, 3],
  ['没有「全部启用/全部停用」按钮', /setAllEnabled|全部启用|全部停用/, 0],
  ['没有直接写 enabled = true 的地方', /\.enabled\s*=\s*true/, 0],
  ['加载时不再自动探测（healthAll 调用已删）', /healthAll\(/, 0],
]) {
  const c = (s.match(new RegExp(pat.source, 'g')) || []).length
  const good = want === 0 ? c === 0 : c >= want
  console.log('机制 ' + name + ': ' + c + (good ? ' ✓' : ' ✗ 期望 ' + (want === 0 ? '0' : '≥' + want)))
}

// 7g) dsh 版本更新：版本行 —— 更新确认弹窗 —— 分步结果
//     两条硬约束：① 升级前的「要做什么」必须写在弹窗里（升级会重启服务，不能点了不知道会发生什么）；
//     ② 结果必须**分步**摆出来（哪一步失败、失败在哪要看得见），不能只回一句 ok/error。
for (const [name, pat, want] of [
  ['版本行容器 id="verNow"', /id="verNow"/, 1],
  ['远端版本标记位 id="verNew"', /id="verNew"/, 1],
  ['「检查更新」入口 checkDsh（定义+调用）', /checkDsh\(/, 3],
  ['「更新」入口 openUpdModal（定义+调用）', /openUpdModal\(/, 2],
  ['更新弹窗容器 id="umodal"', /id="umodal"/, 1],
  ['目标版本输入 + 现有版本只读', /id="uVer"|id="uFrom"/, 2],
  ['通道下拉（latest/next/alpha）', /id="uChan"/, 1],
  ['强制重装开关 id="uForce"', /id="uForce"/, 1],
  ['升级前的步骤预告 id="uPlan"', /id="uPlan"/, 1],
  ['分步结果区 id="uLog" + renderSteps', /id="uLog"|renderSteps\(/, 2],
  ['确认更新入口 doUpgrade', /doUpgrade\(/, 1],
  ['升级走 /ctl/api/dshupgrade', /'dshupgrade'/, 1],
  ['查版本走 /ctl/api/dshcheck', /'dshcheck'/, 1],
  // 已等待只在 renderJob 里出现一次；阈值 2 是旧版两处显示时的遗留
  ['执行中显示已等待秒数', /已等待/, 1],
  ['执行中不给关弹窗', /执行中…/, 1],
  // 升 / 降必须分开说：切到 alpha 通道时远端可能比本机还旧（本机 0.2.0-rc.2 / alpha 0.1.7-alpha.2），
  // 一律写「更新到」会让人以为在升级。
  ['升降区分 cmpVer（定义+调用）', /cmpVer\(/, 4],
  ['远端更旧时按钮说「回退到」', /'回退到 ' : '更新到 '/, 1],
  ['版本不再塞在 envline 里（已挪到版本行）', /dsh ' \+ \(st\.dshVersion/, 0],
]) {
  const c = (s.match(new RegExp(pat.source, 'g')) || []).length
  const good = want === 0 ? c === 0 : c >= want
  console.log('版本 更新 ' + name + ': ' + c + (good ? ' ✓' : ' ✗ 期望 ' + (want === 0 ? '0' : '≥' + want)))
}

// 7h) 生命周期：安装向导 + 修复 + 卸载。三条硬约束：
//     ① dsh 没装时必须有向导卡（#wizard），否则 8030 首页连个能点的地方都没有；
//     ② 修复 / 卸载是「装好之后」的常规入口，挂在服务卡上；
//     ③ 卸载会杀掉网关自己，轮询断连必须被当成预期行为（missHint），不能报故障。
for (const [name, pat, want] of [
  ['安装向导卡 id="wizard"', /id="wizard"/, 1],
  ['向导通道下拉 id="wChan"', /id="wChan"/, 1],
  ['向导版本输入 id="wVer"', /id="wVer"/, 1],
  ['安装入口 doInstall（定义+调用）', /doInstall\(/, 2],
  ['安装走 /ctl/api/install', /api\('install'/, 1],
  ['修复按钮 id="btnRepair"', /id="btnRepair"/, 1],
  ['修复入口 doRepair（定义+调用）', /doRepair\(/, 2],
  ['修复走 /ctl/api/repair', /api\('repair'/, 1],
  ['卸载按钮 id="btnUninstall"', /id="btnUninstall"/, 1],
  ['卸载 --all 开关 id="unAll"', /id="unAll"/, 1],
  ['卸载入口 doUninstall（定义+调用）', /doUninstall\(/, 2],
  ['卸载走 /ctl/api/uninstall', /api\('uninstall'/, 1],
  ['卸载前有确认（confirm）', /确定卸载|连用户数据一起删/, 2],
  // 卸载 = 网关被删：断连时间必须放宽（默认 30 秒对卸载就是误报）
  ['卸载的断连容忍传了 missMs', /missMs: *180000/, 1],
  ['卸载断连有解释（missHint）', /missHint: *'/, 1],
  ['卸载提示后台执行（detached）', /detached|后台执行/, 1],
  // 向导的显隐由 applyState 按 dshMissing 切换 —— 装好不消失就是坏体验
  ['applyState 切向导显隐', /getElementById\('wizard'\)\.style\.display/, 1],
  ['applyState 切修复按钮显隐', /getElementById\('btnRepair'\)\.style\.display/, 1],
  ['applyState 切卸载按钮显隐', /getElementById\('btnUninstall'\)\.style\.display/, 1],
]) {
  const c = (s.match(new RegExp(pat.source, 'g')) || []).length
  const good = want === 0 ? c === 0 : c >= want
  console.log('生命周期 ' + name + ': ' + c + (good ? ' ✓' : ' ✗ 期望 ' + (want === 0 ? '0' : '≥' + want)))
}

// 8) 需要存在的字样（2026-09-30 晚精简后：主页三块 + 大按钮）
const must = ['接口与密钥', '新增接口', '增加密钥', 'id="modal"', 'persistManifest', 'draftPayload',
  '同一时间只有一把', '显示名', '环境变量名', '接口地址', '当前生效', '已写入 dsh', '编辑接口',
  '安装 dsh', '开始安装', '修复（重打补丁）', '卸载', '保存并生效', '打开 dsh 主界面', '从端点拉取模型列表']
const lost = must.filter((x) => !s.includes(x))
console.log('必须在的字样 ' + must.length + ' 个，' + (lost.length ? '✗ 缺: ' + lost.join(',') : '✓ 齐全'))

// 8b) 「接口与密钥」卡片标题与列表之间不许塞长段说明（用户嫌繁琐，2026-09-30 删过一轮）。
{
  const gap = s.match(/<h2>接口与密钥<\/h2>([\s\S]{0,200}?)<div id="list">/)
  const noP = !!gap && !/<\s*p[\s>]/.test(gap[1])
  console.log('接口卡片下无说明段（h2 后直接接列表）: ' + (noP ? '✓' : '✗ 期望 h2 与 #list 之间没有 <p>'))
  for (const [name, pat] of [
    ['卡片说明「一行一个接口」', /一行一个<b>接口<\/b>/],
    ['卡片说明「不能证明密钥有效」', /不能证明密钥有效/],
    ['卡片说明「三件事是同一件事」', /三件事是同一件事/],
  ]) {
    const c = (s.match(new RegExp(pat.source, 'g')) || []).length
    console.log('已删长说明 ' + name + ': ' + c + (c === 0 ? ' ✓' : ' ✗ 期望 0'))
  }
}

// 9) 局部变量遮蔽了函数名（createSite 里 var key、setTok 里 var el 各炸过一次）
const sha = []
const fns = new Set(defs.concat(['api', 'out', 'esc', 'busy', 'renderList', 'tokenName',
  'key', 'el', 'enabledTok', 'apiRowHtml', 'keyRowHtml', 'keyModalHtml']))
for (const mm of js.matchAll(/\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=/g)) {
  if (fns.has(mm[1])) sha.push(mm[1])
}
console.log('遮蔽函数名的局部变量 ' + (sha.length ? '✗ ' + [...new Set(sha)].join(',') : '✓ 无'))

// 10) 用到的 api 名字
const apis = new Set([...js.matchAll(/api\(\s*'([a-z]+)'/g)].map((x) => x[1]))
console.log('调用的接口: ' + [...apis].join(', '))
