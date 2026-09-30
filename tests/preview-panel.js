#!/usr/bin/env node
/**
 * preview-panel.js —— 本地静态预览 8030 控制台新版界面（token 列表式）。
 *
 * 只读：不起任何写入动作，state / health / models 全是假数据，
 * 目的只是把 ../share/dsh-ctl/panel.html 渲染出来看版式，不碰设备。
 *
 *   node tests/preview-panel.js [port]     # 默认 8877
 */
'use strict'
const http = require('http')
const fs = require('fs')
const path = require('path')

const PORT = Number(process.argv[2] || 8877)
const HERE = __dirname
// 面板本体在仓库的 share/dsh-ctl/ 下（设备上落到 $PREFIX/share/dsh-ctl/panel.html）
const PANEL = path.join(HERE, '..', 'share', 'dsh-ctl', 'panel.html')
// 每次请求现读：改完面板刷新一下就能看到，不用重启预览
const readPanel = () => fs.readFileSync(PANEL, 'utf8')

const KEY1 = 'dahl_7dKF1i1XRcjXKVr1jof8fKcn3xkZzom8Y'
const KEY2 = 'sk-7d8f2a91bc4e6f0a3d5c8b2e9f1a7c4d6e8b0f2aca14'
const KEY3 = 'sk-2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c3f8e'

const STATE = {
  ok: true,
  services: [
    { name: 'dsh-web', up: true, installed: true },
    { name: 'dsh-lan', up: true, installed: true },
    { name: 'dsh-ctl', up: true, installed: true },
  ],
  dshVersion: '0.1.7-rc.2',
  nodeVersion: 'v22.22.2',
  host: 'localhost',
  lanIp: '192.168.3.190',
  gatewayUrl: 'http://192.168.3.190:8030/',
  dshUrl: 'http://192.168.3.190:8030/app?token=EXAMPLE-TOKEN-NOT-REAL-0000',
  directUrl: 'http://127.0.0.1:3080/?token=EXAMPLE-TOKEN-NOT-REAL-0000',
  sites: [
    {
      id: 'dahl', name: 'Dahl 聚合', api: 'openai-completions',
      baseURL: 'https://inference.dahl.global/v1', preset: 'dahl',
      tokens: [{
        id: 't1', note: 'cc07ecce18bea323d8ac4032fbcfb484', label: '',
        keyVar: 'DSH_DAHL_T1', keyHint: 'dahl.fQNA', keyMasked: 'dahl_7…fQNA',
        hasKey: true, registered: true, enabled: true, routeId: 'dahl-t1',
        defaultModel: 'deepseek-ai/DeepSeek-V4-Flash-0731',
        models: ['deepseek-ai/DeepSeek-V4-Flash-0731', 'MiniMaxAI/MiniMax-M2.7', 'zai-org/GLM-5.3-Flash'],
      }],
    },
    {
      id: 'intern', name: 'intern-ai 聚合', api: 'openai-completions',
      baseURL: 'https://discovery-api.intern-ai.org.cn/v1', preset: '',
      tokens: [
        {
          id: 't1', note: '02o8is9c34@paytrust.cc', label: '',
          keyVar: 'DSH_INTERN_T1', keyHint: 'sk-7.ca14', keyMasked: 'sk-7d8…ca14',
          hasKey: true, registered: true, enabled: false, routeId: 'intern-t1',
          defaultModel: 'gpt-4o-mini', models: ['gpt-4o-mini', 'claude-3-5-sonnet'],
        },
        {
          id: 't2', note: 'b7c22nolod@paytrust.cc', label: '',
          keyVar: 'DSH_INTERN_T2', keyHint: 'sk-2.3f8e', keyMasked: 'sk-2b4…3f8e',
          hasKey: true, registered: true, enabled: false, routeId: 'intern-t2',
          defaultModel: 'gpt-4o-mini', models: ['gpt-4o-mini'],
        },
        {
          id: 't3', note: '还没配（占位）', label: '',
          keyVar: 'DSH_INTERN_T3', keyHint: '', keyMasked: '',
          hasKey: false, registered: false, enabled: false, routeId: 'intern-t3',
          defaultModel: '', models: [],
        },
      ],
    },
  ],
  active: {
    site: 'dahl', token: 't1', routeId: 'dahl-t1',
    model: 'deepseek-ai/DeepSeek-V4-Flash-0731',
  },
  migrated: false,
  dshFlavor: {
    patcher: true,
    flockOk: true,
    cmake: true,
    ninja: true,
    share: '/data/data/com.termux/files/usr/share/dsh-ctl',
  },
  credentials: [
    { name: 'DSH_DAHL_T1', value: KEY1, masked: 'dahl_7…fQNA' },
    { name: 'DSH_INTERN_T1', value: KEY2, masked: 'sk-7d8…ca14' },
    { name: 'DSH_INTERN_T2', value: KEY3, masked: 'sk-2b4…3f8e' },
  ],
  presets: [
    { kind: 'fixed', id: 'freellmapi', label: 'FreeLLMAPI 本地聚合', url: 'http://127.0.0.1:3001/v1', api: 'openai-completions' },
    { kind: 'fixed', id: 'freellm', label: 'FreeLLM (npx)', url: 'http://localhost:3000/v1', api: 'openai-completions' },
    { kind: 'fixed', id: 'ollama', label: 'Ollama 本地', url: 'http://127.0.0.1:11434/v1', api: 'openai-completions' },
    { kind: 'cloud', id: 'dahl', label: 'Dahl 聚合网关', url: 'https://inference.dahl.global/v1', api: 'openai-completions' },
    { kind: 'cloud', id: 'deepseek', label: 'DeepSeek 官方', url: 'https://api.deepseek.com/anthropic', api: 'anthropic-messages' },
    { kind: 'cloud', id: 'zhipu', label: '智谱 GLM', url: 'https://open.bigmodel.cn/api/anthropic', api: 'anthropic-messages' },
  ],
  paths: {
    dshHome: '/data/data/com.termux/files/home/.dsh',
    keys: '/data/data/com.termux/files/usr/var/service/dsh-web/environment',
    serviceDir: '/data/data/com.termux/files/usr/var/service',
    sites: '/data/data/com.termux/files/home/.dsh/sites.json',
    accounts: '/data/data/com.termux/files/home/.dsh/accounts.json',
  },
}

const HIT = {}   // keyVar -> 被探测了几次：第一次故意回 429，用来实测面板的退避重试

const j = (res, obj) => {
  const s = JSON.stringify(obj)
  res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(s) })
  res.end(s)
}

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  const body = []
  req.on('data', (d) => body.push(d))
  req.on('end', () => {
    // 每个请求都记一行：排查「点了按钮到底有没有发出去」
    console.log(new Date().toTimeString().slice(0, 8) + '  ' + req.method + ' ' + url.pathname +
                (body.length ? '  ' + Buffer.concat(body).toString().slice(0, 160) : ''))
    if (url.pathname === '/' || url.pathname === '/ctl') {
      const html = readPanel()
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
      return res.end(html)
    }
    if (url.pathname === '/ctl/api/state') return j(res, STATE)
    if (url.pathname === '/ctl/api/health') {
      let b = {}
      try { b = JSON.parse(Buffer.concat(body).toString() || '{}') } catch {}
      const id = b.keyVar || '?'
      HIT[id] = (HIT[id] || 0) + 1
      const ms = 120 + Math.floor(Math.random() * 400)
      const where = 'GET ' + (b.baseUrl || '') + '/models'
      // 头一次回 429：模拟真机上那个聚合站的按 IP 限速 —— 面板应该自己退避重试再来一次。
      if (HIT[id] === 1) {
        return setTimeout(() => j(res, {
          ok: false, code: 429, ms,
          out: where + ' → 429（too many requests，假数据：第 1 次故意限流）',
        }), ms)
      }
      return setTimeout(() => j(res, {
        ok: true, code: 200, ms,
        out: where + ' → 200，3 个模型（假数据：第 ' + HIT[id] + ' 次放行）',
      }), ms)
    }
    if (url.pathname === '/ctl/api/models') {
      return j(res, {
        ok: true, code: 200, ms: 240, models: ['gpt-4o-mini', 'claude-3-5-sonnet', 'deepseek-chat'],
        out: 'GET … → 200，3 个模型（假数据）',
      })
    }
    // 版本对表：真网关打 registry 的 dist-tags 小端点，这里直接把三个通道写死。
    if (url.pathname === '/ctl/api/dshcheck') {
      let b = {}
      try { b = JSON.parse(Buffer.concat(body).toString() || '{}') } catch {}
      const chan = b.channel || 'latest'
      const tags = { latest: '0.2.0-rc.2', next: '0.2.0-rc.2', alpha: '0.1.7-alpha.2' }
      const latest = tags[chan] || tags.latest
      return setTimeout(() => j(res, {
        ok: true,
        current: STATE.dshVersion,
        channel: chan,
        latest,
        tags,
        hasUpdate: STATE.dshVersion !== latest,
        registry: 'https://registry.npmjs.org',
        ms: 183,
        patcher: true,
        flockOk: true,
      }), 220)
    }
    // 升级：目标版本里带 "fail" 的，故意演一遍「补丁锚点对不上 → 自动回滚」。
    // 这样面板的两条路（成功 / 回滚）都能在本地被测到，不用去动真机。
    if (url.pathname === '/ctl/api/dshupgrade') {
      let b = {}
      try { b = JSON.parse(Buffer.concat(body).toString() || '{}') } catch {}
      const want = String(b.version || '')
      const from = STATE.dshVersion
      const bakStep = { cmd: 'mv …/@deepseek-ai …/@deepseek-ai.bak-1780000000000', code: 0, out: '(改名备份 ' + from + ')' }
      if (/fail/.test(want)) {
        return setTimeout(() => j(res, {
          ok: false,
          rolledBack: true,
          current: from,
          out: '新版本的源码跟补丁对不上了（patches.py 退出码 1）。上游很可能改了被补丁的那几个文件，硬留着会起不来。\n\n已自动回滚。',
          steps: [
            bakStep,
            { cmd: 'npm install -g @deepseek-ai/dsh@' + want, code: 0, out: 'added 1 package in 42s' },
            { cmd: 'python3 patches.py', code: 1, out: '  失败 lib/bin.js —— 找不到锚点\n❌ 有 1 条补丁没打成' },
            { cmd: '回滚到 ' + from, code: 0, out: '已把备份改回' },
            { cmd: 'sv restart dsh-web', code: 0, out: 'run: dsh-web: (pid 8123) 0s' },
          ],
          state: STATE,
        }), 320)
      }
      STATE.dshVersion = want
      return setTimeout(() => j(res, {
        ok: true,
        from,
        to: want,
        out: '已从 ' + from + ' 升到 ' + want + '，补丁已重打，dsh-web 已重启。\nflock 原生插件：不需要（新包装完就带着可用的 .node）',
        steps: [
          bakStep,
          { cmd: 'npm install -g @deepseek-ai/dsh@' + want, code: 0, out: 'added 1 package, changed 20 packages in 63s' },
          { cmd: 'python3 patches.py', code: 0, out: '✅ 补丁完成：改动 8 处，跳过 0 处' },
          { cmd: 'sv restart dsh-web', code: 0, out: 'run: dsh-web: (pid 4321) 0s' },
          { cmd: 'dsh --version', code: 0, out: want },
        ],
        state: STATE,
      }), 320)
    }
    if (url.pathname === '/ctl/api/manifest') {
      // 只改内存里的 STATE，模拟「清单落盘了」：刷新页面后加的那行还在。
      let b = {}
      try { b = JSON.parse(Buffer.concat(body).toString() || '{}') } catch {}
      // 面板发上来的是「清单」，不带凭据状态；按 id 对上老的那份，把凭据字段还回去
      const prev = {}
      for (const s of STATE.sites) for (const t of s.tokens) prev[s.id + '/' + t.id] = t
      // 与真机网关同一条不变量：清单里只有 active 指的那把是启用的。
      const a = b.active || {}
      const firstS = (b.sites || [])[0] || {}
      const firstT = (firstS.tokens || [])[0] || {}
      const pickK = a.site ? (a.site + '/' + (a.token || '')) : ((firstS.id || '') + '/' + (firstT.id || ''))
      STATE.sites = (b.sites || []).map((s) => ({
        ...s,
        tokens: (s.tokens || []).map((t) => {
          const old = prev[(s.id || '') + '/' + (t.id || '')] || {}
          return {
            ...old, ...t,
            keyHint: old.keyHint || '',
            keyMasked: old.keyMasked || '',
            hasKey: !!old.hasKey,
            registered: !!old.registered,
            enabled: ((s.id || '') + '/' + (t.id || '')) === pickK,
            routeId: (s.id || '') + '-' + (t.id || ''),
          }
        }),
      }))
      if (b.active) STATE.active = { ...STATE.active, ...b.active }
      return j(res, {
        ok: true,
        out: '（本地预览）已写清单：' + STATE.sites.length + ' 个接口 / ' +
             STATE.sites.reduce((n, s) => n + s.tokens.length, 0) + ' 把密钥。',
        state: STATE,
      })
    }
    if (url.pathname.startsWith('/ctl/api/')) return j(res, { ok: true, out: '本地预览：不执行任何动作。' })
    res.writeHead(404).end('nope')
  })
}).listen(PORT, '127.0.0.1', () => {
  console.log('预览已启动： http://127.0.0.1:' + PORT + '/   （假数据，只读，不写任何文件）')
})
