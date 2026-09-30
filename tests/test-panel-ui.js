#!/usr/bin/env node
/**
 * test-panel-ui.js —— 拿真浏览器（headless chromium）驱动 8030 控制台面板，
 * 对着本地假后端 preview-panel.js 做交互断言。只看结果，不出截图。
 *
 * 为什么要有这个：audit-panel.js 只做静态自检（有没有那个函数、那个字样），
 * 证明不了「点开接口真的出密钥列表」「弹窗里改密钥值真的进 DRAFT」。这两件事必须真跑。
 *
 *   node tests/test-panel-ui.js            # 自己去起 preview-panel.js（8879）
 *   node tests/test-panel-ui.js 8879       # 用已经起好的那个
 *   CHROME_PATH=/path/to/chrome node tests/test-panel-ui.js   # 没装 playwright 包时指定浏览器
 */
'use strict'
const { spawn } = require('child_process')
const path = require('path')

const PORT = Number(process.argv[2] || 8879)
const HERE = __dirname
const BASE = 'http://127.0.0.1:' + PORT

// 浏览器怎么找：
//   1) 装了 playwright 包 —— 用它，浏览器路径它自己管；
//   2) 只装了 playwright-core（不需要下载浏览器，体积小）—— 用 CHROME_PATH，
//      没给就扫 ms-playwright 缓存目录（macOS / Linux 两处都看）。
function findChromium () {
  const fs = require('fs')
  const home = process.env.HOME || ''
  const roots = [path.join(home, 'Library/Caches/ms-playwright'), path.join(home, '.cache/ms-playwright')]
  for (const root of roots) {
    let dirs = []
    try { dirs = fs.readdirSync(root) } catch (_) { continue }
    for (const d of dirs.sort().reverse()) {
      const cands = [
        path.join(root, d, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell'),
        path.join(root, d, 'chrome-headless-shell-mac-x64', 'chrome-headless-shell'),
        path.join(root, d, 'chrome-headless-shell-linux64', 'chrome-headless-shell'),
        path.join(root, d, 'chrome-mac-arm64', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        path.join(root, d, 'chrome-mac', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        path.join(root, d, 'chrome-linux', 'chrome')
      ]
      for (const c of cands) if (fs.existsSync(c)) return c
    }
  }
  return null
}

function loadChromium () {
  try {
    return { chromium: require('playwright').chromium, opts: {} }
  } catch (_) {
    const { chromium } = require('playwright-core')
    const exe = process.env.CHROME_PATH || findChromium()
    if (!exe) throw new Error('没装 playwright 包，也没找到 chromium 可执行文件 —— 请设 CHROME_PATH')
    return { chromium, opts: { executablePath: exe } }
  }
}

let pass = 0, fail = 0
const ok = (name, cond, extra) => {
  if (cond) { pass++; console.log('  ✓ ' + name) }
  else { fail++; console.log('  ✗ ' + name + (extra ? '  → ' + extra : '')) }
}
const eq = (name, got, want) => ok(name + '（期望 ' + want + '）', got === want, '实际 ' + JSON.stringify(got))

async function main () {
  const { chromium, opts } = loadChromium()

  // 假后端：没有外部传入就自己起一个
  let srv = null
  if (!process.argv[2]) {
    srv = spawn(process.execPath, [path.join(HERE, 'preview-panel.js'), String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] })
    srv.stdout.on('data', () => {})
    await new Promise((r) => setTimeout(r, 700))
  }

  const browser = await chromium.launch({ ...opts, args: ['--no-sandbox'] })
  const page = await browser.newPage()

  const errors = []
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message))
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()) })

  const posts = []
  page.on('request', (r) => {
    if (r.method() === 'POST' && r.url().includes('/ctl/api/')) posts.push(r.url().split('/').pop())
  })
  // confirm 一律同意（删除接口 / 删除密钥 / 回到默认都会弹）
  page.on('dialog', (d) => d.accept())

  await page.goto(BASE + '/', { waitUntil: 'load' })
  await page.waitForSelector('.arow')
  // 等页面加载那次自动健康探测跑完：假后端第 1 次故意回 429，面板要退避重试（sleep 600ms）再打一次
  await page.waitForTimeout(3200)

  // 复用的小工具
  const rowOf = (url) => page.locator('.arow', { hasText: url })
  const openEdit = async (url) => {
    await rowOf(url).locator('[data-aedit]').click()
    await page.waitForTimeout(180)
  }

  console.log('\n== 1. 列表顶层 = 接口（接口地址），默认收起 ==')
  eq('接口行数', await page.locator('.arow').count(), 2)
  eq('默认没有展开的接口', await page.locator('.adet:visible').count(), 0)
  const urls = await page.locator('.arow .a-url').allTextContents()
  ok('接口地址是行的主体', urls.includes('https://inference.dahl.global/v1') && urls.includes('https://discovery-api.intern-ai.org.cn/v1'), urls.join(' | '))
  eq('接口地址不含密钥相关的旧列（.c-url 已下线）', await page.locator('.arow .c-url').count(), 0)
  eq('列表下部有「＋ 新增接口」', await page.locator('#btnAddApi').count(), 1)
  eq('列表下部 + 在 #list 下方', await page.locator('#list + .addapi #btnAddApi').count(), 1)
  eq('接口行尾部有「编辑」按钮', await page.locator('.arow [data-aedit]').count(), 2)
  eq('页面加载即探测：启用那把显示健康', (await page.locator('.arow .c-hl.ok, .arow .c-hl.warn').count()) >= 1, true)

  console.log('\n== 1b. 接口行尾的「检测」：测这个接口的密钥（20 秒内复用结果） ==')
  eq('每个接口行都有「检测」按钮', await page.locator('.arow [data-ahealth]').count(), 2)
  eq('已去掉「全部检测」按钮', await page.locator('button', { hasText: '全部检测' }).count(), 0)
  const h0 = posts.filter((x) => x === 'health').length
  await rowOf('inference.dahl.global').locator('[data-ahealth]').click()
  await page.waitForTimeout(900)
  ok('输出面板写了这次检测的结论（复用也照写）',
    (await page.locator('#out').innerText()).includes('接口 dahl 检测完成'), '')
  ok('接口行健康列给出结论', /健康|限流|异常|待命/.test((await rowOf('inference.dahl.global').locator('.c-hl').innerText()).trim()))
  eq('20 秒内刚测过 → 复用，没重复打端点', posts.filter((x) => x === 'health').length, h0)
  eq('点「检测」不动展开状态', await page.locator('.adet:visible').count(), 0)

  console.log('\n== 1c. 接口级检测会带上这个接口下「待命」的密钥一起测 ==')
  await page.locator('.arow').nth(1).locator('.chev').click()      // 展开 intern
  await page.waitForTimeout(150)
  await page.locator('.arow').nth(1).locator('[data-ahealth]').click()
  await page.waitForTimeout(6200)
  eq('intern 下 2 把有密钥的都测了（t3 缺密钥不算）', posts.filter((x) => x === 'health').length - h0, 4)
  ok('待命那把也拿到了结论（不再是未检测）', await page.evaluate(() =>
    !!(window.HL['intern/t1'] && window.HL['intern/t1'].state && window.HL['intern/t1'].state !== 'busy')))
  await page.locator('.arow').nth(1).locator('.chev').click()      // 收起 intern
  await page.waitForTimeout(120)
  eq('收回只展开 0 个', await page.locator('.adet:visible').count(), 0)

  console.log('\n== 2. 点行首 ▸ 展开的是 key 列表，最下边才是「＋ 增加密钥」 ==')
  await page.locator('.arow').first().locator('.chev').click()
  await page.waitForTimeout(120)
  eq('展开的接口数', await page.locator('.adet:visible').count(), 1)
  eq('dahl 下面 1 把密钥', await page.locator('.adet:visible .krow').count(), 1)
  const kAddLast = await page.evaluate(() => {
    // 注意：:visible 是 playwright 的伪类，querySelector 不认，这里只能挑出可见的那个容器
    const vis = [...document.querySelectorAll('.adet')].filter((d) => d.style.display !== 'none')
    const kl = vis[0].querySelector('.klist')
    return kl.lastElementChild.className + '|' + kl.children.length
  })
  ok('「＋ 增加密钥」是 klist 的最后一个子元素', /kadd/.test(kAddLast), kAddLast)
  eq('密钥行里没有旧的接口地址列', await page.locator('.krow .c-url').count(), 0)

  console.log('\n== 3. 密钥行没有展开；行尾是「编辑」「删除」 ==')
  eq('密钥行里没有 ▸', await page.locator('.krow .chev').count(), 0)
  eq('列表里没有密钥详情容器（.kdet / data-kdet 已下线）',
    await page.locator('.kdet, [data-kdet]').count(), 0)
  eq('可见密钥行尾的「编辑」', await page.locator('.adet:visible .krow [data-kedit]').count(), 1)
  eq('可见密钥行尾的「删除」', await page.locator('.adet:visible .krow [data-kdel]').count(), 1)
  eq('一开始没有密钥弹窗', await page.locator('#kmodal:visible').count(), 0)

  console.log('\n== 3b. 接口弹窗只管接口本身，不掺密钥 ==')
  await openEdit('inference.dahl.global')
  eq('点「编辑」打开接口弹窗', await page.locator('#modal:visible').count(), 1)
  ok('标题是编辑接口', (await page.locator('#mTitle').innerText()).includes('编辑接口'), '')
  eq('接口 id 只读', await page.locator('#nsId').isDisabled(), true)
  eq('接口弹窗里没有密钥区（mKeyList 已删）', await page.locator('#mKeyList').count(), 0)
  eq('接口弹窗里没有密钥卡', await page.locator('#modal .mkey').count(), 0)
  ok('提示里说明密钥去展开列表里改', (await page.locator('#mHint').innerText()).includes('密钥'), '')
  eq('点「编辑」没把接口收起来（事件没被整行吃掉）', await page.locator('.adet:visible').count(), 1)

  console.log('\n== 4. 密钥弹窗：只管这一把；改备注列表同步；没保存的密钥值不丢 ==')
  await page.locator('#modal .mfoot button', { hasText: '取消' }).click()
  await page.waitForTimeout(120)
  await page.locator('.adet:visible .krow [data-kedit]').first().click()
  await page.waitForTimeout(200)
  eq('密钥弹窗打开', await page.locator('#kmodal:visible').count(), 1)
  eq('接口弹窗没跟着开', await page.locator('#modal:visible').count(), 0)
  ok('标题是「密钥 · …」', (await page.locator('#kTitle').innerText()).startsWith('密钥 · '), '')
  eq('弹窗里只有这一把', await page.locator('#kmodal .mkey').count(), 1)
  eq('密钥弹窗里没有「＋ 增加密钥」', await page.locator('#kmodal .kadd').count(), 0)
  const ktext = await page.locator('#kBody').innerText()
  ok('弹窗里有备注 / 显示名 / 密钥值 / 环境变量名 / 模型',
    ['备注', '显示名', '密钥值', '环境变量名', '模型'].every((x) => ktext.includes(x)), '')
  ok('写明了接口地址在这里改不了', ktext.includes('接口地址'), '')

  await page.locator('#kBody .mkey input').first().fill('主号-改过')
  await page.waitForTimeout(120)
  eq('列表行的备注跟着变', (await page.locator('.adet:visible .krow .c-nt').first().innerText()).trim(), '主号-改过')
  await page.locator('#kBody .mkey input[type=password]').first().fill('sk-unsaved-xyz')
  await page.locator('#kmodal .mfoot button', { hasText: '完成' }).click()
  await page.waitForTimeout(120)
  eq('「完成」关掉密钥弹窗', await page.locator('#kmodal:visible').count(), 0)
  await page.locator('.adet:visible .krow [data-kedit]').first().click()
  await page.waitForTimeout(200)
  eq('重开：还没保存的密钥值还在',
    await page.locator('#kBody .mkey input[type=password]').first().inputValue(), 'sk-unsaved-xyz')
  await page.locator('#kBody .mkey input[type=password]').first().fill('')
  await page.locator('#kmodal .mfoot button', { hasText: '完成' }).click()
  await page.waitForTimeout(120)
  eq('点遮罩外也能关（这里用完成代替）', await page.locator('#kmodal:visible').count(), 0)
  await page.locator('.arow').first().locator('.chev').click()   // 收起 dahl，后面好数可见的接口
  await page.waitForTimeout(100)
  eq('收起后没有展开的接口', await page.locator('.adet:visible').count(), 0)

  console.log('\n== 5. 「＋ 新增接口」= 弹窗 ==')
  await page.locator('#btnAddApi').click()
  await page.waitForTimeout(120)
  eq('弹窗打开', await page.locator('#modal:visible').count(), 1)
  eq('标题', (await page.locator('#mTitle').innerText()).trim(), '新增接口')
  eq('确认按钮', (await page.locator('#mOk').innerText()).trim(), '创建接口')
  eq('「第一把密钥」组可见', await page.locator('#mFirstKey:visible').count(), 1)
  eq('接口弹窗里没有密钥区', await page.locator('#mKeyList, #modal .mkey').count(), 0)
  eq('「删除这个接口」不显示', await page.locator('#mDel:visible').count(), 0)
  eq('接口 id 可编辑', await page.locator('#nsId').isDisabled(), false)
  ok('弹窗里是常驻表单（列表里已没有内联表单）', await page.locator('#list #newsite').count() === 0)

  // 非法输入 → 不关弹窗，而且**错误必须显示在弹窗里**。
  // 之前这里只断言「错误写进 #out」—— #out 在页面底部被弹窗盖着，等于没提示，
  // 用户看到的就是「点创建接口没反应」。断言写松了，bug 就从这儿漏过去了。
  await page.locator('#nsUrl').fill('ftp://x')
  await page.locator('#nsId').fill('probe')
  await page.locator('#mOk').click()
  await page.waitForTimeout(120)
  eq('地址不合法时不关弹窗', await page.locator('#modal:visible').count(), 1)
  eq('弹窗里的红条可见（#mErr）', await page.locator('#mErr:visible').count(), 1)
  ok('红条写的就是原因', (await page.locator('#mErr').innerText()).includes('http'), '')
  eq('出问题的输入框被聚焦', await page.evaluate(() => document.activeElement.id), 'nsUrl')
  ok('输出面板也留一份痕', (await page.locator('#out').innerText()).includes('http'), '')
  eq('不合法时没多发写清单请求', posts.filter((x) => x === 'manifest').length, 0)

  // 一改输入红条就自己消失，不用关掉弹窗重开
  await page.locator('#nsUrl').fill('https://probe.example.com/anthropic')
  await page.waitForTimeout(80)
  eq('改了输入红条自动消失', await page.locator('#mErr:visible').count(), 0)

  // 接口 id 重复：同样要在弹窗里说清楚
  const existId = await page.evaluate(() => window.DRAFT.sites[0].id)
  await page.locator('#nsId').fill(existId)
  await page.locator('#mOk').click()
  await page.waitForTimeout(120)
  eq('id 重复时不关弹窗', await page.locator('#modal:visible').count(), 1)
  ok('红条说 id 已经存在', (await page.locator('#mErr').innerText()).includes('已经存在'), '')
  await page.locator('#nsId').fill('probe')
  await page.waitForTimeout(80)

  // 正常创建
  await page.locator('#nsId').fill('probe')
  await page.locator('#nsName').fill('probe 聚合')
  await page.locator('#nsApi').selectOption('anthropic-messages')
  await page.locator('#nsUrl').fill('https://probe.example.com/anthropic')
  await page.locator('#nsNote').fill('主号')
  await page.locator('#nsKey').fill('sk-probe-123')
  await page.locator('#mOk').click()
  await page.waitForTimeout(350)
  eq('创建后弹窗关闭', await page.locator('#modal:visible').count(), 0)
  eq('接口行数 +1', await page.locator('.arow').count(), 3)
  eq('新建的接口自动展开', await page.locator('.adet:visible').count(), 1)
  ok('新接口的地址进了列表', (await page.locator('.arow .a-url').allTextContents()).includes('https://probe.example.com/anthropic'))
  ok('新建即落清单（manifest）', posts.includes('manifest'), posts.join(','))
  eq('新接口自带第一把密钥', await page.locator('.adet:visible .krow').count(), 1)

  console.log('\n== 6. 接口行的「编辑」：改地址，密钥不动 ==')
  await openEdit('probe.example.com')
  eq('弹窗打开', await page.locator('#modal:visible').count(), 1)
  eq('确认按钮变成保存修改', (await page.locator('#mOk').innerText()).trim(), '保存修改')
  eq('「第一把密钥」组隐藏', await page.locator('#mFirstKey:visible').count(), 0)
  eq('回填了协议', await page.locator('#nsApi').inputValue(), 'anthropic-messages')
  eq('「删除这个接口」可见', await page.locator('#mDel:visible').count(), 1)

  // 编辑时填了非法地址：同样要在弹窗里看得见，而且不许发写清单请求
  const mBefore = posts.filter((x) => x === 'manifest').length
  await page.locator('#nsUrl').fill('x.example.com/v1')
  await page.locator('#mOk').click()
  await page.waitForTimeout(150)
  eq('编辑时非法不关弹窗', await page.locator('#modal:visible').count(), 1)
  eq('编辑时红条可见', await page.locator('#mErr:visible').count(), 1)
  eq('编辑时非法不发写清单请求', posts.filter((x) => x === 'manifest').length, mBefore)

  await page.locator('#nsUrl').fill('https://probe.example.com/v1')
  await page.locator('#mOk').click()
  await page.waitForTimeout(300)
  eq('弹窗关闭', await page.locator('#modal:visible').count(), 0)
  ok('列表上的地址跟着改了', (await page.locator('.arow .a-url').allTextContents()).includes('https://probe.example.com/v1'))
  eq('接口数没变', await page.locator('.arow').count(), 3)

  console.log('\n== 7. 展开列表最下边的「＋ 增加密钥」：环境变量名不撞、默认待命 ==')
  eq('展开区就是 probe', (await page.locator('.adet:visible').first().getAttribute('data-adet')), 'probe')
  eq('现在 1 行密钥', await page.locator('.adet:visible .krow').count(), 1)
  await page.locator('.adet:visible .kadd button').click()
  await page.waitForTimeout(350)
  const probe = await page.evaluate(() => window.DRAFT.sites.find((s) => s.id === 'probe'))
  eq('DRAFT 里也是 2 把', probe.tokens.length, 2)
  ok('环境变量名自动生成且不撞上一把', probe.tokens[1].keyVar === 'DSH_PROBE_T2' && probe.tokens[1].keyVar !== probe.tokens[0].keyVar, probe.tokens[1].keyVar)
  eq('新加的默认「待命」', probe.tokens[1].enabled, false)
  ok('模型继承同一个接口里的那把', JSON.stringify(probe.tokens[1].models) === JSON.stringify(probe.tokens[0].models))
  ok('加密钥也落清单', posts.filter((x) => x === 'manifest').length >= 2)
  ok('列表里同步成 2 把', (await rowOf('probe.example.com').innerText()).includes('2 把密钥'))
  eq('列表里也是 2 行密钥', await page.locator('.adet:visible .krow').count(), 2)
  eq('两行都带「编辑」「删除」', await page.locator('.adet:visible .krow [data-kdel]').count(), 2)

  console.log('\n== 8. 开关：同一时间只有一把启用 ==')
  const box = '.adet:visible .krow'
  await page.locator(box).first().locator('input[type=checkbox]').check()
  await page.waitForTimeout(350)
  eq('全局勾上的开关数', await page.locator('input[type=checkbox]:checked').count(), 1)
  eq('勾上的是刚点的那把', await page.locator(box).first().locator('input').isChecked(), true)
  eq('接口行上的「当前」标记数', await page.locator('.arow .cur').count(), 1)
  ok('接口行的「当前」落在 probe 上', (await page.locator('.arow', { has: page.locator('.cur') }).innerText()).includes('probe'), '')
  ok('跨接口互斥：dahl 那把已被顶成待命', await page.evaluate(() =>
    window.DRAFT.sites.find((s) => s.id === 'dahl').tokens.every((t) => !t.enabled)))

  console.log('\n== 9. 关不掉自己（dsh 至少要留一条路由） ==')
  await page.locator(box).first().locator('input[type=checkbox]').click()   // 点已勾上的 → 期望被弹回
  await page.waitForTimeout(200)
  eq('依然是勾上的', await page.locator('input[type=checkbox]:checked').count(), 1)
  ok('输出面板解释原因', (await page.locator('#out').innerText()).includes('同一时间只能启用一把'))

  console.log('\n== 10. 删密钥：行尾「删除」/ 弹窗里的「删除这把密钥」/ 删接口 ==')
  eq('现在 2 行密钥', await page.locator('.adet:visible .krow').count(), 2)
  await page.locator('.adet:visible .krow').nth(1).locator('[data-kdel]').click()
  await page.waitForTimeout(350)
  eq('行尾删除：密钥 -1', await page.locator('.adet:visible .krow').count(), 1)

  await page.locator('.adet:visible .krow [data-kedit]').first().click()
  await page.waitForTimeout(180)
  eq('密钥弹窗打开', await page.locator('#kmodal:visible').count(), 1)
  await page.locator('#kDel').click()
  await page.waitForTimeout(350)
  eq('弹窗里删除：密钥 -1', await page.locator('.adet:visible .krow').count(), 0)
  eq('删完密钥，弹窗自己关掉（那把已经不存在了）', await page.locator('#kmodal:visible').count(), 0)
  eq('展开区提示没有密钥', await page.locator('.adet:visible .kadd').count(), 1)

  const aBefore = await page.locator('.arow').count()
  await openEdit('probe.example.com')
  await page.locator('#mDel').click()
  await page.waitForTimeout(350)
  eq('弹窗跟着关了', await page.locator('#modal:visible').count(), 0)
  eq('接口数 -1', await page.locator('.arow').count(), aBefore - 1)
  eq('probe 已不在列表里', await rowOf('probe.example.com').count(), 0)

  console.log('\n== 11. 刷新：展开状态按接口记忆 ==')
  await page.locator('.arow').first().locator('.chev').click()
  await page.waitForTimeout(120)
  eq('展开了一个接口', await page.locator('.adet:visible').count(), 1)
  await page.locator('button', { hasText: '刷新' }).first().click()
  await page.waitForTimeout(1400)
  eq('刷新后展开的还是那一个', await page.locator('.adet:visible').count(), 1)

  console.log('\n== 12. dsh 版本更新 ==')
  eq('版本行显示当前版本', (await page.locator('#verTxt').innerText()).trim(), '0.1.7-rc.2')
  ok('页面加载那次静默对表已点亮远端版本',
    (await page.locator('#verNew:visible').count()) === 1, await page.locator('#verNew').innerText())
  ok('远端版本号是 0.2.0-rc.2', (await page.locator('#verNew').innerText()).includes('0.2.0-rc.2'))
  eq('更新入口出现', await page.locator('#btnUpd:visible').count(), 1)
  ok('更新按钮自带目标版本', (await page.locator('#btnUpd').innerText()).includes('0.2.0-rc.2'))

  await page.locator('#btnUpd').click()
  await page.waitForTimeout(200)
  eq('更新弹窗打开', await page.locator('#umodal:visible').count(), 1)
  eq('目标版本已回填', await page.locator('#uVer').inputValue(), '0.2.0-rc.2')
  eq('现有版本回填', await page.locator('#uFrom').inputValue(), '0.1.7-rc.2')
  ok('计划里写明要重打补丁', (await page.locator('#uPlan').innerText()).includes('patches.py'))

  await page.locator('#uChan').selectOption('alpha')
  await page.waitForTimeout(150)
  eq('切通道后目标版本跟着变', await page.locator('#uVer').inputValue(), '0.1.7-alpha.2')
  // alpha 通道上远端(0.1.7-alpha.2)比本机(0.1.7-rc.2 前身 0.1.7/0.2.0)旧 —— 按钮不许再说「更新」
  eq('远端比本机旧时按钮说「确认回退」', (await page.locator('#uOk').innerText()).trim(), '确认回退')

  await page.locator('#uVer').fill('abc')
  await page.locator('#uOk').click()
  await page.waitForTimeout(160)
  eq('非法版本号：弹窗不关', await page.locator('#umodal:visible').count(), 1)
  eq('非法版本号：红条可见', await page.locator('#uErr:visible').count(), 1)
  eq('非法版本号：没发升级请求', posts.filter((x) => x === 'dshupgrade').length, 0)

  // 失败路径：假后端看到版本号里的 fail，就演一遍「补丁锚点对不上 → 自动回滚」
  await page.locator('#uVer').fill('9.9.9-fail')
  await page.locator('#uOk').click()
  await page.waitForTimeout(1600)
  ok('失败时弹窗里说清「已自动回滚」', (await page.locator('#uLog').innerText()).includes('回滚'))
  ok('失败的那一步标成了 bad', (await page.locator('#uLog .ustep.bad').count()) >= 1)
  ok('失败时把补丁输出摆出来', (await page.locator('#uLog').innerText()).includes('patches.py'))
  eq('失败后版本行没被改脏', (await page.locator('#verTxt').innerText()).trim(), '0.1.7-rc.2')
  // 体验断言（不是实现断言）：结果一长，footer 会被顶出可视区，用户看到的是「按钮没了」。
  // 真出过：内容 781px / 容器 632px，「关闭」落到 y=770，已跑出 720 高的视口。
  ok('结果很长时「关闭」仍在视口内可点', await page.evaluate(() => {
    var r = document.getElementById('uCancel').getBoundingClientRect()
    return r.height > 0 && r.top >= 0 && Math.round(r.bottom) <= window.innerHeight
  }))
  await page.locator('#uCancel').click()
  await page.waitForTimeout(150)
  eq('关掉弹窗', await page.locator('#umodal:visible').count(), 0)

  // 成功路径
  const upBefore = posts.filter((x) => x === 'dshupgrade').length
  await page.locator('#btnUpd').click()
  await page.waitForTimeout(200)
  await page.locator('#uChan').selectOption('latest')
  await page.waitForTimeout(150)
  eq('切回 latest 后目标版本是新版', await page.locator('#uVer').inputValue(), '0.2.0-rc.2')
  await page.locator('#uVer').fill('0.2.0-rc.2')
  await page.locator('#uOk').click()
  await page.waitForTimeout(1800)
  eq('升级请求发出去了', posts.filter((x) => x === 'dshupgrade').length, upBefore + 1)
  ok('结果里逐步列出每一步', (await page.locator('#uLog .ustep').count()) >= 4)
  ok('结果里能看到「重打补丁」那一步', (await page.locator('#uLog').innerText()).includes('patches.py'))
  eq('版本行更新成新版本', (await page.locator('#verTxt').innerText()).trim(), '0.2.0-rc.2')
  ok('输出面板记了一笔', (await page.locator('#out').innerText()).includes('dsh 更新完成'))
  eq('升完已是最新，更新按钮收起来', await page.locator('#btnUpd:visible').count(), 0)
  await page.locator('#uCancel').click()
  await page.waitForTimeout(150)

  console.log('\n== 13. 没有 JS 报错 ==')
  ok('无 pageerror / console.error', errors.length === 0, errors.join(' | '))

  await browser.close()
  if (srv) srv.kill()

  console.log('\n通过 ' + pass + ' 项，失败 ' + fail + ' 项')
  process.exit(fail ? 1 : 0)
}

main().catch((e) => { console.error('测试自身炸了：' + e.stack); process.exit(2) })
