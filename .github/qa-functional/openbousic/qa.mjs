// Functional QA of the installed Actelyo OpenBousic desktop app.
// Launches the real Electron app with a CDP port, attaches Playwright to it and
// walks the first-run flow: provider -> projects folder -> vision -> project ->
// session -> chat with a local llama-server model -> terminal panel.
import { chromium } from 'playwright'
import { spawn, execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const APP_EXE = process.env.APP_EXE
const OUT = path.join(process.env.QA_OUT || 'qa-out', 'shots')
const ORIGIN = 'http://127.0.0.1:10369'
const CDP = 'http://127.0.0.1:9222'
const WORKDIR = 'C:\\qa-projects'
const PROJECT = 'hello-qa'
const PROJECT_DIR = path.join(WORKDIR, PROJECT)
const PROMPTS = [
  'write a hello world in Python into hello.py',
  'Use the write_file tool now to create the file hello.py in the project folder with exactly this content: print("Hello, World!")',
]
// Keep the Electron renderer painting even if the runner desktop occludes the window
// (otherwise requestAnimationFrame stops and Playwright waits/screenshots hang).
const RENDER_FLAGS = ['--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding', '--disable-background-timer-throttling', '--disable-features=CalculateNativeWinOcclusion']
let fallbackBrowser = null
const HERE = path.dirname(fileURLToPath(import.meta.url))

fs.mkdirSync(OUT, { recursive: true })
const report = { startedAt: new Date().toISOString(), steps: [], facts: {} }
let shotIndex = 0
let page = null

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const re = (en, fr) => new RegExp(`^\\s*(${en}|${fr})\\s*$`, 'i')

function save() {
  fs.writeFileSync(path.join(process.env.QA_OUT || 'qa-out', 'report.json'), JSON.stringify(report, null, 2))
}

async function shot(name, { desktop = false } = {}) {
  const file = `${String(++shotIndex).padStart(2, '0')}-${name}.png`
  try {
    if (page) await page.screenshot({ path: path.join(OUT, file), timeout: 20000 })
  } catch (e) {
    console.log(`screenshot ${file} failed: ${e.message}`)
  }
  if (desktop) {
    const dfile = file.replace('.png', '-desktop.png')
    try {
      execFileSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(HERE, 'desktop-shot.ps1'), '-Path', path.join(OUT, dfile)], { timeout: 30000 })
    } catch (e) {
      console.log(`desktop screenshot failed: ${e.message}`)
    }
  }
  return file
}

async function step(name, fn, { critical = true } = {}) {
  const rec = { name, ok: false, detail: '', startedAt: new Date().toISOString() }
  report.steps.push(rec)
  console.log(`\n=== ${name}`)
  try {
    const detail = await fn(rec)
    rec.ok = rec.okOverride !== false
    rec.detail = rec.detail || (detail ?? '')
  } catch (e) {
    rec.ok = false
    rec.detail = `${rec.detail ? rec.detail + ' | ' : ''}ERROR: ${e.message.split('\n')[0]}`
    try { fs.writeFileSync(path.join(OUT, '..', `dom-fail-${report.steps.length}.html`), await page.content()) } catch {}
    rec.failShot = await shot(`FAIL-${name.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`, { desktop: true })
  }
  delete rec.okOverride
  rec.endedAt = new Date().toISOString()
  console.log(`[${rec.ok ? 'PASS' : 'FAIL'}] ${name} :: ${rec.detail}`)
  save()
  if (!rec.ok && critical) throw new Error(`critical step failed: ${name}`)
  return rec
}

async function api(p, init) {
  return page.evaluate(
    async ([p, init]) => {
      const r = await fetch(p, init)
      const text = await r.text()
      try {
        return { status: r.status, body: JSON.parse(text) }
      } catch {
        return { status: r.status, body: text }
      }
    },
    [p, init],
  )
}

async function clickIfVisible(locator) {
  try {
    if (await locator.first().isVisible({ timeout: 500 })) {
      await locator.first().click({ timeout: 3000 })
      return true
    }
  } catch {}
  return false
}

function assistantText(messages) {
  return (messages || [])
    .filter((m) => m.role === 'assistant')
    .map((m) => (m.content || '').trim())
    .filter(Boolean)
    .join('\n---\n')
}

async function runPrompt(sessionId, prompt, tag) {
  const textarea = page.getByTestId('chat-input-textarea')
  await textarea.waitFor({ state: 'visible', timeout: 30000 })
  await textarea.fill(prompt)
  await shot(`${tag}-prompt-typed`)
  await page.getByTestId('chat-send-button').click()
  const t0 = Date.now()
  let lastShot = Date.now()
  let n = 0
  let sawRunning = false
  let status = null
  let idleSince = null
  const clicked = []
  while (Date.now() - t0 < 12 * 60 * 1000) {
    await sleep(4000)
    // Allow file-access / path confirmations raised by the agent's tools.
    for (const label of [re('Allow', 'Autoriser')]) {
      if (await clickIfVisible(page.getByRole('button', { name: label }))) clicked.push(`Allow@${Math.round((Date.now() - t0) / 1000)}s`)
    }
    const s = await api(`/api/sessions/${sessionId}/status`).catch(() => null)
    status = s?.body
    if (status?.state === 'running') sawRunning = true
    if (Date.now() - lastShot > 60000) {
      await shot(`${tag}-progress-${++n}`)
      lastShot = Date.now()
    }
    const idle = status && status.state !== 'running' && !status.waitingForUser
    if (idle && (sawRunning || Date.now() - t0 > 20000)) {
      idleSince = idleSince ?? Date.now()
      if (Date.now() - idleSince > 6000) break
    } else {
      idleSince = null
    }
    if (status?.waitingForUser) {
      const full = await api(`/api/sessions/${sessionId}`)
      if ((full.body?.pendingQuestions || []).length) {
        report.facts[`${tag}-pendingQuestions`] = full.body.pendingQuestions
        break
      }
    }
  }
  const seconds = Math.round((Date.now() - t0) / 1000)
  const full = await api(`/api/sessions/${sessionId}?full=true`)
  fs.writeFileSync(path.join(process.env.QA_OUT || 'qa-out', `session-${tag}.json`), JSON.stringify(full.body, null, 2))
  return { seconds, status, clicked, messages: full.body?.messages || [] }
}

async function main() {
  report.facts.appExe = APP_EXE
  // 0. Launch the installed app with a CDP port.
  await step('launch installed app (CDP)', async () => {
    const child = spawn(APP_EXE, ['--remote-debugging-port=9222', ...RENDER_FLAGS], { detached: true, stdio: 'ignore', cwd: path.dirname(APP_EXE), env: { ...process.env, ACTELYO_OPENBOUSIC_LOG_LEVEL: 'debug' } })
    child.unref()
    let browser = null
    const t0 = Date.now()
    while (!browser && Date.now() - t0 < 120000) {
      try {
        const r = await fetch(`${CDP}/json/version`)
        if (r.ok) browser = await chromium.connectOverCDP(CDP)
      } catch {}
      if (!browser) await sleep(1000)
    }
    if (!browser) throw new Error('CDP endpoint did not come up')
    const t1 = Date.now()
    while (Date.now() - t1 < 150000) {
      const pages = browser.contexts().flatMap((c) => c.pages())
      page = pages.find((p) => p.url().startsWith(ORIGIN)) || null
      if (page) break
      await sleep(1000)
    }
    if (!page) throw new Error('app window never loaded ' + ORIGIN)
    await page.waitForLoadState('domcontentloaded')
    const h = await api('/api/health')
    report.facts.health = h
    report.facts.navigatorLanguage = await page.evaluate(() => navigator.language)
    report.facts.windowTitle = await page.title()
    await sleep(3000)
    await page.bringToFront().catch(() => {})
    try {
      const cdp = await page.context().newCDPSession(page)
      await cdp.send('Emulation.setFocusEmulationEnabled', { enabled: true })
    } catch (e) {
      console.log('focus emulation failed: ' + e.message)
    }
    report.facts.electronProbe = await page.evaluate(() => new Promise((res) => {
      const t = setTimeout(() => res({ raf: false, visibility: document.visibilityState, hasFocus: document.hasFocus() }), 3000)
      requestAnimationFrame(() => { clearTimeout(t); res({ raf: true, visibility: document.visibilityState, hasFocus: document.hasFocus() }) })
    })).catch((e) => ({ error: e.message }))
    fs.writeFileSync(path.join(OUT, '..', 'electron-dom-start.html'), await page.content().catch(() => ''))
    let electronShotOk = true
    try {
      await page.screenshot({ path: path.join(OUT, `${String(++shotIndex).padStart(2, '0')}-app-started-electron.png`), timeout: 15000 })
    } catch (e) {
      electronShotOk = false
      report.facts.electronScreenshotError = e.message.split('\n')[0]
    }
    await shot('app-started-desktop', { desktop: true })
    report.facts.driver = 'electron-cdp'
    if (!electronShotOk || !report.facts.electronProbe?.raf) {
      // The Electron renderer does not paint for CDP: drive the same server's web UI
      // with Playwright Chromium instead (same backend, same state).
      fallbackBrowser = await chromium.launch({ headless: false })
      const ctx = await fallbackBrowser.newContext({ viewport: { width: 1400, height: 900 }, locale: report.facts.navigatorLanguage || 'en-US' })
      page = await ctx.newPage()
      await page.goto(ORIGIN + '/')
      await page.waitForLoadState('networkidle').catch(() => {})
      report.facts.driver = 'chromium-fallback'
      await shot('app-started-chromium')
    }
    return `health=${h.status}, url=${page.url()}, lang=${report.facts.navigatorLanguage}, driver=${report.facts.driver}, electronProbe=${JSON.stringify(report.facts.electronProbe)}`
  })

  // 1. Onboarding: add a llama.cpp provider.
  await step('1a onboarding wizard visible', async () => {
    if (!page.url().includes('/onboarding')) await page.goto(`${ORIGIN}/onboarding`)
    await page.getByTestId('onboarding-add-provider-button').waitFor({ state: 'visible', timeout: 60000 })
    await shot('onboarding-step1', { desktop: true })
    return page.url()
  })

  await step('diag: app server model listing (capture proxy on :8081)', async () => {
    const http = await import('node:http')
    const seen = []
    const srv = http.createServer((req, res) => {
      const rec = { port: 8081, method: req.method, url: req.url, headers: req.headers }
      seen.push(rec)
      const up = http.request({ host: '127.0.0.1', port: 8080, path: req.url, method: req.method, headers: req.headers }, (ur) => {
        const chunks = []
        ur.on('data', (c) => chunks.push(c))
        ur.on('end', () => {
          const buf = Buffer.concat(chunks)
          rec.upstreamStatus = ur.statusCode
          rec.upstreamHeaders = ur.headers
          rec.upstreamBody = buf.toString('utf8').slice(0, 600)
          res.writeHead(ur.statusCode, ur.headers)
          res.end(buf)
        })
      })
      up.on('error', (e) => { rec.upstreamError = String(e); res.writeHead(502); res.end(String(e)) })
      req.pipe(up)
    })
    await new Promise((r) => srv.listen(8081, '127.0.0.1', r))
    const canned = http.createServer((req, res) => {
      seen.push({ port: 8082, method: req.method, url: req.url })
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ object: 'list', data: [{ id: 'qwen3-0.6b', object: 'model', owned_by: 'llamacpp' }] }))
    })
    await new Promise((r) => canned.listen(8082, '127.0.0.1', r))
    const results = {}
    for (const q of ['url=http://127.0.0.1:8081&backend=llamacpp', 'url=http://127.0.0.1:8082&backend=llamacpp', 'url=http://127.0.0.1:8082']) {
      results[q] = await api(`/api/providers/models?${q}`)
    }
    srv.close()
    canned.close()
    report.facts.diagModels = { results, seen }
    fs.writeFileSync(path.join(OUT, '..', 'diag-models.json'), JSON.stringify({ results, seen }, null, 2))
    return JSON.stringify(Object.fromEntries(Object.entries(results).map(([k, v]) => [k, v.status]))) + ` requests seen=${seen.length}`
  }, { critical: false })

  await step('1b add provider (llama.cpp preset -> local llama-server)', async (rec) => {
    await page.getByTestId('onboarding-add-provider-button').click()
    await page.getByTestId('provider-modal-next').waitFor({ state: 'visible', timeout: 15000 })
    await shot('provider-modal-open')
    await page.locator('button', { hasText: /^\s*llama\.cpp\s*$/ }).first().click()
    const presetUrl = await page.getByTestId('provider-modal-url').inputValue()
    report.facts.presetUrl = presetUrl
    await shot('provider-preset-llamacpp')
    const modelsResp = page.waitForResponse((r) => r.url().includes('/api/providers/models'), { timeout: 60000 })
    await page.getByTestId('provider-modal-next').click()
    let resp = await modelsResp
    let body = await resp.json().catch(() => ({}))
    report.facts.modelsResponsePreset = { status: resp.status(), models: (body.models || []).map((m) => m.id), error: body.error }
    if (!resp.ok() || !(body.models || []).length) {
      // Preset URL failed: go back and point at 127.0.0.1 explicitly.
      rec.detail = `preset URL ${presetUrl} -> HTTP ${resp.status()} ${body.error || ''}; retried with 127.0.0.1`
      await shot('provider-models-preset-failed')
      await page.getByRole('button', { name: /Back|Retour/ }).click()
      await page.getByTestId('provider-modal-url').fill('http://127.0.0.1:8080')
      const again = page.waitForResponse((r) => r.url().includes('/api/providers/models'), { timeout: 60000 })
      await page.getByTestId('provider-modal-next').click()
      resp = await again
      body = await resp.json().catch(() => ({}))
      report.facts.modelsResponseRetry = { status: resp.status(), models: (body.models || []).map((m) => m.id), error: body.error }
      if (!(body.models || []).length) throw new Error(`model list empty: ${JSON.stringify(body).slice(0, 300)}`)
    }
    await sleep(1500)
    await shot('provider-models-listed')
    // Auto-config probes the single model; Save is disabled until it finishes.
    await page.waitForFunction(() => {
      const b = document.querySelector('[data-testid="provider-modal-save"]')
      return b && !b.disabled
    }, null, { timeout: 300000 })
    await shot('provider-autoconfig-done')
    await page.getByTestId('provider-modal-save').click()
    const prov = await api('/api/providers')
    report.facts.providersAfterSave = prov.body
    return `${rec.detail ? rec.detail + '; ' : ''}models=${JSON.stringify(body.models.map((m) => m.id))}`
  })

  await step('1c wizard advances to Projects Folder', async () => {
    await page.getByTestId('onboarding-workdir-input').waitFor({ state: 'visible', timeout: 30000 })
    const prefilled = await page.getByTestId('onboarding-workdir-input').inputValue()
    report.facts.workdirPrefilled = prefilled
    await shot('onboarding-step2-folder')
    return `prefilled workdir="${prefilled}"`
  })

  // 2. Projects folder + vision.
  await step('2a set projects folder', async () => {
    await page.getByTestId('onboarding-workdir-input').fill(WORKDIR)
    await shot('onboarding-step2-folder-filled')
    await page.getByTestId('onboarding-workdir-continue-button').click()
    await page.getByTestId('onboarding-skip-button').waitFor({ state: 'visible', timeout: 30000 })
    await shot('onboarding-step3-vision')
    return WORKDIR
  })

  await step('2b skip Vision and finish onboarding', async () => {
    const cfgResp = page.waitForResponse((r) => r.url().includes('/api/init/config'), { timeout: 30000 })
    await page.getByTestId('onboarding-skip-button').click()
    const r = await cfgResp
    await sleep(3000)
    await shot('onboarding-finished', { desktop: true })
    const cfg = await api('/api/config').catch(() => null)
    report.facts.configAfterOnboarding = cfg?.body
    if (!r.ok()) throw new Error(`/api/init/config -> ${r.status()}`)
    return `/api/init/config -> ${r.status()}, url=${page.url()}`
  })

  // 3. Project + session + chat.
  let sessionId = null
  await step('3a create project', async () => {
    if (page.url().includes('/onboarding')) await page.goto(`${ORIGIN}/`)
    await page.waitForLoadState('networkidle').catch(() => {})
    await sleep(2000)
    await shot('home')
    await page.getByRole('button', { name: /Open Project|Ouvrir un projet/ }).first().click()
    await page.getByTestId('open-project-create-button').click()
    await page.getByTestId('create-project-name-input').fill(PROJECT)
    await shot('create-project-modal')
    await page.getByTestId('create-project-submit-button').click()
    await page.waitForURL(/\/p\/[a-f0-9-]+/, { timeout: 30000 })
    await sleep(1500)
    await shot('project-page')
    report.facts.projectDirExists = fs.existsSync(PROJECT_DIR)
    const projects = await api('/api/projects')
    report.facts.projects = projects.body
    return `url=${page.url()}, dir ${PROJECT_DIR} exists=${report.facts.projectDirExists}`
  })

  await step('3b start a session', async () => {
    await page.getByTestId('create-new-session-button').click()
    await page.waitForURL(/\/p\/[a-f0-9-]+\/s\/[a-f0-9-]+/, { timeout: 30000 })
    sessionId = page.url().match(/\/s\/([a-f0-9-]+)/)[1]
    await page.getByTestId('chat-input-textarea').waitFor({ state: 'visible', timeout: 30000 })
    await sleep(1500)
    await shot('session-open')
    const s = await api(`/api/sessions/${sessionId}`)
    report.facts.sessionInitial = s.body?.session
    return `session=${sessionId} mode=${s.body?.session?.mode ?? '?'}`
  })

  await step('3c switch agent to Builder (so it may write files)', async () => {
    await page.getByTitle(/Switch agent|Changer d’agent/).first().click()
    await sleep(500)
    await shot('agent-menu')
    await page.locator('button', { hasText: /^\s*Builder\s*$/ }).first().click()
    await sleep(1500)
    // An effort gate dialog may ask to apply or keep the effort.
    for (const l of [/^\s*(Apply|Appliquer)/i, /^\s*(Keep|Conserver|Garder)/i]) {
      if (await clickIfVisible(page.getByRole('button', { name: l }))) break
    }
    await sleep(1000)
    await shot('agent-builder')
    const s = await api(`/api/sessions/${sessionId}`)
    const mode = s.body?.session?.mode
    if (mode && mode !== 'builder') throw new Error(`mode is ${mode}`)
    return `mode=${mode}`
  }, { critical: false })

  let reply = ''
  await step('3d send coding prompt and get a model reply', async (rec) => {
    const r = await runPrompt(sessionId, PROMPTS[0], 'chat1')
    reply = assistantText(r.messages)
    report.facts.chat1 = { seconds: r.seconds, status: r.status, clicked: r.clicked, reply: reply.slice(0, 4000), toolCalls: r.messages.flatMap((m) => (m.toolCalls || []).map((t) => t.name || t.function?.name || t.toolName)).filter(Boolean) }
    await shot('chat1-reply', { desktop: true })
    if (!reply) {
      rec.okOverride = false
      return `no assistant text after ${r.seconds}s (state=${r.status?.state}, phase=${r.status?.phase}); tools=${JSON.stringify(report.facts.chat1.toolCalls)}`
    }
    return `reply in ${r.seconds}s (${reply.length} chars), tools=${JSON.stringify(report.facts.chat1.toolCalls)}: ${reply.slice(0, 160).replace(/\s+/g, ' ')}`
  }, { critical: false })

  await step('3e (bonus) agent wrote hello.py', async (rec) => {
    const file = path.join(PROJECT_DIR, 'hello.py')
    let attempts = 1
    if (!fs.existsSync(file)) {
      attempts = 2
      const r = await runPrompt(sessionId, PROMPTS[1], 'chat2')
      report.facts.chat2 = { seconds: r.seconds, status: r.status, clicked: r.clicked, reply: assistantText(r.messages).slice(-3000) }
      await shot('chat2-reply')
    }
    const exists = fs.existsSync(file)
    report.facts.projectFiles = fs.existsSync(PROJECT_DIR) ? fs.readdirSync(PROJECT_DIR) : []
    if (!exists) {
      rec.okOverride = false
      return `hello.py not created after ${attempts} prompt(s); project files=${JSON.stringify(report.facts.projectFiles)}`
    }
    const content = fs.readFileSync(file, 'utf8')
    report.facts.helloPy = content
    try {
      report.facts.helloPyRun = execFileSync('python', [file], { timeout: 20000 }).toString()
    } catch (e) {
      report.facts.helloPyRun = `ERR ${e.message}`
    }
    return `created after ${attempts} prompt(s): ${JSON.stringify(content.slice(0, 200))}; python output=${JSON.stringify(report.facts.helloPyRun)}`
  }, { critical: false })

  // 4. Terminal panel.
  await step('4 open terminal panel', async () => {
    await page.getByTitle(/Toggle terminal|Basculer le terminal/).first().click()
    await page.locator('.xterm').first().waitFor({ state: 'visible', timeout: 30000 })
    await sleep(4000)
    await page.locator('.xterm').first().click()
    await page.keyboard.type('cd')
    await page.keyboard.press('Enter')
    await sleep(800)
    await page.keyboard.type('dir')
    await page.keyboard.press('Enter')
    await sleep(1500)
    if (fs.existsSync(path.join(PROJECT_DIR, 'hello.py'))) {
      await page.keyboard.type('python hello.py')
      await page.keyboard.press('Enter')
    }
    await sleep(4000)
    const text = await page.locator('.xterm-rows').first().innerText().catch(() => '')
    report.facts.terminalText = text.slice(0, 3000)
    await shot('terminal-panel', { desktop: true })
    return `xterm visible; text sample: ${text.replace(/\s+/g, ' ').slice(0, 200)}`
  }, { critical: false })
}

try {
  await main()
} catch (e) {
  console.log(`stopped: ${e.message}`)
  report.aborted = e.message
}
report.endedAt = new Date().toISOString()
report.passed = report.steps.filter((s) => !s.name.includes('(bonus)')).every((s) => s.ok)
save()
const md = ['| Step | Result | Detail |', '|---|---|---|', ...report.steps.map((s) => `| ${s.name} | ${s.ok ? 'PASS' : 'FAIL'} | ${String(s.detail).replace(/\|/g, '\\|').replace(/\n/g, ' ').slice(0, 300)} |`)].join('\n')
fs.writeFileSync(path.join(process.env.QA_OUT || 'qa-out', 'summary.md'), md + '\n')
console.log('\n' + md)
process.exit(0)
