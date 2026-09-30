// 在 node 里跑 panel.html 的渲染逻辑（假 DOM），验证新写的渲染函数不炸。
// 仓库根目录运行：node tests/panel-render-check.js
const fs = require('fs')
const path = require('path')
const src = fs.readFileSync(path.join(__dirname, '..', 'share', 'dsh-ctl', 'panel.html'), 'utf8')
const script = /^<script>([\s\S]*?)<\/script>/m.exec(src)[1]

const store = {}
function mkEl(id) {
  return {
    id,
    style: {},
    textContent: '',
    innerHTML: '',
    value: '',
    checked: false,
    disabled: false,
    querySelectorAll: () => [],
    querySelector: () => mkEl('fake2'),
    closest: () => null,
    focus: () => {},
    appendChild: () => {},
    options: [],
  }
}
global.document = {
  getElementById: (id) => { if (!store[id]) store[id] = mkEl(id); return store[id]; },
  querySelectorAll: () => [],
  querySelector: () => mkEl('fake'),
  activeElement: null,
}
global.fetch = () => Promise.resolve({ status: 200, json: () => Promise.resolve({ ok: true }) })
global.confirm = () => true
global.sessionStorage = { getItem: () => null, setItem: () => {} }

// 去掉末尾的 load() 自动拉取（fetch 桩返回的不是真 state），改成手工喂
const fixed = script
  .replace(/load\(\)\.then\(function\(\)\{[\s\S]*\}\);?\s*$/, '')
  .replace(/^load\(\);/m, '')

eval(fixed)  // eslint-disable-line

const FAKE_ST = {
  ok: true,
  nodeVersion: 'v24.18.0',
  host: 'phone', lanIp: '192.168.0.102',
  dshVersion: '0.2.0-rc.2', dshMissing: false, uninstallAvailable: true,
  paths: { sites: '~/.dsh/sites.json', keys: 'environment' },
  services: [
    { name: 'dsh-web', up: true, installed: true },
    { name: 'dsh-ctl', up: true, installed: true },
  ],
  presets: [
    { id: 'p1', label: 'presetA', url: 'https://a.example/v1', api: 'openai-completions', kind: 'cloud' },
  ],
  active: { site: 'mp', token: 't1', routeId: 'mp-t1', model: 'auto' },
  sites: [{
    id: 'mp', name: 'mp', api: 'openai-completions', baseURL: 'https://e.example/v1', preset: '',
    tokens: [
      { id: 't1', note: 'main', label: '', keyVar: 'DSH_MP_T1', defaultModel: 'auto',
        enabled: true, hasKey: true, keyMasked: 'sk-7.ca14', keyHint: 'sk-7.ca14',
        registered: true, models: ['auto', 'x2'] },
      { id: 't2', note: 'backup', label: '', keyVar: 'DSH_MP_T2', defaultModel: '',
        enabled: false, hasKey: false, keyMasked: '', keyHint: '', registered: false, models: [] },
    ],
  }],
}

applyState(FAKE_ST)
const list = store['list'] ? store['list'].innerHTML : ''
const checks = [
  ['list rendered api row', list.indexOf('arow') >= 0],
  ['list has site name', list.indexOf('mp') >= 0],
  ['key row has masked key', list.indexOf('sk-7.ca14') >= 0],
  ['cur card visible', store['curCard'] && store['curCard'].style.display !== 'none'],
  ['cur = note-first name', (store['curSite'] || {}).textContent.indexOf('main') >= 0],
  ['cur url shown', (store['curUrl'] || {}).textContent.indexOf('https://e.example/v1') >= 0],
  ['cur has masked key', (store['curKey'] || {}).innerHTML.indexOf('sk-7.ca14') >= 0],
  ['draft row present', list.indexOf('缺模型（草稿') >= 0 && list.indexOf('backup') >= 0],
  ['sub has lan ip', (store['sub'] || {}).innerHTML.indexOf('192.168.0.102') >= 0],
  ['preset select filled', (store['nsTpl'] || {}).innerHTML.indexOf('presetA') >= 0],
  ['service chips', (store['services'] || {}).innerHTML.indexOf('dsh-web') >= 0],
  ['envline', (store['envline'] || {}).textContent.indexOf('node v24.18.0') >= 0],
  ['savehint', (store['savehint'] || {}).textContent.indexOf('sites.json') >= 0],
]
let bad = 0
for (const [name, ok] of checks) { if (!ok) bad++; console.log((ok ? 'PASS ' : 'FAIL ') + name) }

OPEN['mp'] = true
toggleApi('mp')
store['list'].innerHTML = ''
renderList()
setEnabled('mp', 't2', true)
console.log((tokById('mp', 't2').enabled ? 'PASS ' : 'FAIL ') + 'switch to t2: t2 enabled')
console.log((tokById('mp', 't1').enabled ? 'FAIL ' : 'PASS ') + 't1 auto standby')
console.log((DRAFT.active.token === 't2' ? 'PASS ' : 'FAIL ') + 'active=t2')

CAND['mp/t2'] = ['m1', 'm2']
openKeyModal('mp', 't2')
const kb = store['kBody'] ? store['kBody'].innerHTML : ''
console.log((kb.indexOf('m1') >= 0 ? 'PASS ' : 'FAIL ') + 'key modal renders candidate models')
console.log((kb.indexOf('拉取模型列表') >= 0 ? 'PASS ' : 'FAIL ') + 'key modal has pull button')

// save 流程；先切回有密钥的 t1，不然会被「启用+已存密钥」的正确性校验拦下
onlyEnable('mp', 't1')
const saved = {}
global.fetch = (url, opt) => {
  saved.url = url
  saved.body = JSON.parse(opt.body)
  return Promise.resolve({ status: 200, json: () => Promise.resolve({ ok: true, steps: [{ cmd: 'x', code: 0, out: '' }], state: FAKE_ST }) })
}
save(true, false)
setTimeout(() => {
  console.log((saved.url === '/ctl/api/save' ? 'PASS ' : 'FAIL ') + 'save posts to /ctl/api/save')
  console.log((saved.body && saved.body.restart === true ? 'PASS ' : 'FAIL ') + 'save body restart=true')
  console.log((saved.body && saved.body.verify === false ? 'PASS ' : 'FAIL ') + 'save body verify=false')
  console.log(bad === 0 ? '\nALL PASS' : '\nFAILURES: ' + bad)
  process.exit(bad === 0 ? 0 : 1)
}, 300)
