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

// 7d) 两层结构：接口（接口地址）→ 展开才是密钥列表 → 最下边「＋ 增加密钥」
//     密钥那一级没有第三层：行里不再有 ▸，行尾「编辑」开单把密钥的弹窗，「删除」直接移除这把。
for (const [name, pat, want] of [
  ['接口行 .arow', /class="arow/, 1],
  ['密钥行 .krow', /class="krow/, 1],
  ['接口展开容器 data-adet', /data-adet=/, 1],
  ['接口行展开入口 toggleApi(', /toggleApi\(/, 2],
  ['「＋ 增加密钥」在展开区里', /class="kadd"/, 1],
  ['增加密钥按接口加（addKeyTo）', /addKeyTo\(/, 2],
  ['「＋ 新增接口」按钮在列表下部', /id="btnAddApi"/, 1],
  ['新增接口走弹窗 openApiModal', /openApiModal\(/, 3],
  ['接口行尾部有「编辑」按钮', /data-aedit=/, 1],
  ['接口行尾部有「检测」按钮', /data-ahealth=/, 1],
  ['接口级检测 healthApi（定义+调用）', /healthApi\(/, 2],
  ['已去掉「全部检测」按钮', /onclick="healthAll\(\)"|全部检测/, 0],
  ['密钥行尾部有「编辑」按钮', /data-kedit=/, 1],
  ['密钥行尾部有「删除」按钮', /data-kdel=/, 1],
  ['密钥行尾是操作列 .kact/.c-act', /class="c-act"/, 1],
  ['密钥行没有二级展开（无 OPENK/箭头/详情容器）', /OPENK|data-kchev|data-kdet=/, 0],
  ['旧的常驻表单已删', /id="newsite"/, 0],
  ['旧的站点下拉已删', /id="siteSel"/, 0],
  ['旧的行式表格类名已清', /class="trow|class="tdet/, 0],
  ['旧的接口信息条 .abar 已删', /class="abar"/, 0],
  ['密钥的旧「换接口挂」已删', /function moveTo\(|toggleOpen\(/, 0],
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

// 7c) 健康探测的节流/重试机制
for (const [name, pat, want] of [
  ['详情默认收起（没有 total<=1 自动展开）', /total\s*<=\s*1/, 0],
  ['20 秒内不重测（RETEST_MS）', /RETEST_MS/, 1],
  ['429 退避重试（HL_MAX_TRY）', /HL_MAX_TRY/, 1],
  ['全部检测是串行（无并发三路）', /Promise\.all\(\[next\(\), next\(\), next\(\)\]\)/, 0],
  ['手动「检测」强制真打（force=true）', /healthOne\(' \+ sid \+ ',' \+ tid \+ '\)|,false,true\)/, 1],
  // 弹窗盖着输出面板，检测结果得有地方显示
  ['弹窗里有健康徽章（data-mhint）', /data-mhint=/, 2],
  ['保存成功后清掉明文密钥值', /clearNewKeys\(/, 2],
  ['刷新不吞掉还没保存的密钥值', /prevKey\[k\]/, 1],
  // 「同一时间只有一把启用」：启用位只有一个入口 onlyEnable()，
  // 别处不许直接 t.enabled = true（那正是以前能同时亮起两把的原因）。
  ['启用位唯一入口 onlyEnable（定义+调用）', /onlyEnable\(/, 3],
  ['没有「全部启用/全部停用」按钮', /setAllEnabled|全部启用|全部停用/, 0],
  ['没有直接写 enabled = true 的地方', /\.enabled\s*=\s*true/, 0],
]) {
  const c = (s.match(new RegExp(pat.source, 'g')) || []).length
  const good = want === 0 ? c === 0 : c >= want
  console.log('机制 ' + name + ': ' + c + (good ? ' ✓' : ' ✗ 期望 ' + (want === 0 ? '0' : '≥' + want)))
}

// 8) 需要存在的字样
const must = ['接口列表', '新增接口', '增加密钥', 'id="modal"', 'persistManifest', 'draftPayload',
  '同一时间只有一把', '健康', '显示名', '环境变量名', '接口地址', '当前生效', '已写入 dsh', '编辑接口']
const lost = must.filter((x) => !s.includes(x))
console.log('必须在的字样 ' + must.length + ' 个，' + (lost.length ? '✗ 缺: ' + lost.join(',') : '✓ 齐全'))

// 8b) 「接口列表」卡片下面不再挂长段说明文字（用户嫌太长，2026-09-30 让删掉）。
//     结构断言：<h2>接口列表</h2> 和表头 .ahead 之间不许出现 <p>。
//     文字断言：那段话的几个特征串不许回来 —— 换个措辞重写也会被结构断言抓住。
{
  const gap = s.match(/<h2>接口列表<\/h2>([\s\S]{0,200}?)<div class="ahead">/)
  const noP = !!gap && !/<\s*p[\s>]/.test(gap[1])
  console.log('接口列表卡片下无说明段（h2 后直接接表头）: ' + (noP ? '✓' : '✗ 期望 h2 与 .ahead 之间没有 <p>'))
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
  'key', 'el', 'enabledTok', 'apiRowHtml', 'apiDetHtml', 'keyRowHtml', 'keyDetHtml']))
for (const mm of js.matchAll(/\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=/g)) {
  if (fns.has(mm[1])) sha.push(mm[1])
}
console.log('遮蔽函数名的局部变量 ' + (sha.length ? '✗ ' + [...new Set(sha)].join(',') : '✓ 无'))

// 10) 用到的 api 名字
const apis = new Set([...js.matchAll(/api\(\s*'([a-z]+)'/g)].map((x) => x[1]))
console.log('调用的接口: ' + [...apis].join(', '))
