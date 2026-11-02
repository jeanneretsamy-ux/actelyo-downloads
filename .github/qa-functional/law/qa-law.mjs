// Functional QA of the installed Actelyo Law Harness desktop app, driven through
// Playwright's Electron support (same method as the repo's installed-app verifier).
// Usage: node qa-law.mjs <installed-dir> <out-dir> <llama-base-url>
import { createRequire } from 'node:module'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const require = createRequire(path.join(process.env.QA_NODE_DIR || process.cwd(), 'package.json'))
const { _electron } = require('playwright-core')

const [installedArg, outArg, baseUrl = 'http://127.0.0.1:8080/v1'] = process.argv.slice(2)
const installed = path.resolve(installedArg)
const out = path.resolve(outArg)
fs.mkdirSync(out, { recursive: true })
const exe = path.join(installed, 'Actelyo Law Harness.exe')
const hermesHome = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'hermes')

const steps = []
let shotN = 0
const appLog = fs.createWriteStream(path.join(out, 'app-stdio.log'), { flags: 'a' })
const t0 = Date.now()
const log = (...a) => { const s = `[${((Date.now() - t0) / 1000).toFixed(0)}s] ${a.join(' ')}`; console.log(s); appLog.write(s + '\n') }

async function shot(page, name) {
  const file = `${String(++shotN).padStart(2, '0')}-${name}.png`
  try { await page.screenshot({ path: path.join(out, file) }); return file } catch (e) { log('screenshot failed', file, e.message); return null }
}

async function step(id, name, page, fn) {
  log('STEP', id, name)
  const rec = { id, name, ok: false, detail: '', screenshots: [] }
  steps.push(rec)
  const started = Date.now()
  try {
    const detail = await fn(rec)
    rec.ok = true
    rec.detail = detail ? String(detail) : ''
  } catch (e) {
    rec.ok = false
    rec.detail = String(e?.message || e).slice(0, 1500)
    if (page()) rec.bodyText = (await page().locator('body').innerText().catch(() => '')).slice(0, 3000)
  }
  rec.seconds = Math.round((Date.now() - started) / 1000)
  if (page()) { const f = await shot(page(), `${id}-${rec.ok ? 'pass' : 'fail'}`); if (f) rec.screenshots.push(f) }
  log(rec.ok ? 'PASS' : 'FAIL', id, rec.detail.slice(0, 400))
  writeReport()
  return rec.ok
}

function writeReport() {
  fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify({
    app: 'Actelyo Law Harness', executable: exe, hermesHome, baseUrl,
    passed: steps.length > 0 && steps.every(s => s.ok), steps
  }, null, 2))
}

const cleanEnv = { ...process.env }
for (const k of ['HERMES_PYTHON', 'HERMES_RUNTIME_DIR', 'VIRTUAL_ENV', 'PYTHONPATH', 'PYTHONHOME', 'HERMES_HOME',
  'OPENAI_BASE_URL', 'OPENAI_API_KEY', 'GH_TOKEN', 'GITHUB_TOKEN']) delete cleanEnv[k]

async function launch(tag) {
  const app = await _electron.launch({
    executablePath: exe, cwd: installed,
    env: { ...cleanEnv, HERMES_DESKTOP_DISABLE_GPU: '1' },
    timeout: 180000
  })
  for (const s of [app.process().stdout, app.process().stderr]) s?.on('data', c => appLog.write(`[${tag}] ${c}`))
  const page = await app.firstWindow({ timeout: 180000 })
  page.on('console', m => { if (m.type() === 'error') appLog.write(`[${tag} console.error] ${m.text().slice(0, 500)}\n`) })
  try { await page.setViewportSize({ width: 1440, height: 900 }) } catch {}
  return { app, page }
}

const HAVE_KEY = /^(I have an API key|Vous avez une clé API \?)$/
const CAPS = /^(Capabilities|Capacités)$/

// Waits until the app is interactive: either the first-run provider picker or the chat shell.
async function waitForShell(page, timeout = 900000) {
  const deadline = Date.now() + timeout
  let last = ''
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: HAVE_KEY }).first().isVisible().catch(() => false)) return 'onboarding'
    const caps = page.getByText(CAPS).first()
    if (await caps.isVisible().catch(() => false)) {
      try { await caps.click({ trial: true, timeout: 1000 }); return 'shell' } catch {}
    }
    const txt = (await page.locator('[data-glass-opaque]').first().innerText().catch(() => '')).trim()
    if (txt && txt !== last) { last = txt; log('overlay:', txt.slice(0, 200).replace(/\s+/g, ' ')) }
    if (/installation failed|failed to start|startup failed/i.test(txt)) throw new Error('startup failed: ' + txt.slice(0, 800))
    await page.waitForTimeout(1000)
  }
  throw new Error('app not interactive; last overlay: ' + last.slice(0, 800))
}

async function composer(page) {
  const c = page.locator('[contenteditable][aria-label="Message"]').first()
  await c.waitFor({ state: 'visible', timeout: 120000 })
  return c
}

// Sends a prompt and waits for the assistant turn to finish streaming.
async function chat(page, prompt, timeout = 600000) {
  const c = await composer(page)
  const before = await page.locator('[data-role="assistant"]').count()
  await c.click()
  await page.keyboard.type(prompt)
  await page.keyboard.press('Enter')
  await page.locator('[data-role="user"]').filter({ hasText: prompt.slice(0, 30) }).first().waitFor({ timeout: 60000 })
  const deadline = Date.now() + timeout
  let text = '', stableSince = 0
  while (Date.now() < deadline) {
    await page.waitForTimeout(2000)
    const msgs = page.locator('[data-role="assistant"]')
    const n = await msgs.count()
    const cur = n > before ? (await msgs.nth(n - 1).innerText().catch(() => '')).trim() : ''
    const busy = await page.getByRole('button', { name: /^(Stop|Arrêter)$/ }).first().isVisible().catch(() => false)
    if (cur !== text) { text = cur; stableSince = Date.now() }
    if (cur && !busy && Date.now() - stableSince > 6000) break
  }
  const systemMsgs = await page.locator('[data-role="system"]').allInnerTexts().catch(() => [])
  return { text, systemMsgs }
}

async function waitBodyText(page, needle, timeout = 30000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if ((await page.locator('body').innerText().catch(() => '')).includes(needle)) return
    await page.waitForTimeout(500)
  }
  throw new Error('text not shown: ' + needle)
}

function readConfig() {
  const p = path.join(hermesHome, 'config.yaml')
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : ''
}

let app, page
const P = () => page
try {
  // ---------------- First launch: provider configuration ----------------
  await step('01-launch', 'Launch installed app (fresh profile)', P, async () => {
    ;({ app, page } = await launch('run1'))
    const id = await app.evaluate(({ app }) => ({ name: app.getName(), version: app.getVersion() }))
    const state = await waitForShell(page)
    return `${id.name} ${id.version}; first screen=${state}`
  })

  await step('02-provider', 'Configure custom OpenAI-compatible endpoint (I have an API key -> Local / custom endpoint)', P, async rec => {
    await page.getByRole('button', { name: HAVE_KEY }).first().waitFor({ timeout: 60000 })
    const f0 = await shot(page, 'onboarding-picker'); if (f0) rec.screenshots.push(f0)
    await page.getByRole('button', { name: HAVE_KEY }).first().click()
    await page.getByRole('button', { name: /Local \/ custom endpoint/ }).first().click()
    const url = page.getByPlaceholder('http://127.0.0.1:8000/v1')
    await url.fill(baseUrl)
    const f1 = await shot(page, 'local-endpoint-form'); if (f1) rec.screenshots.push(f1)
    await page.getByRole('button', { name: /^(Connect|Connecter)$/ }).last().click()
    const deadline = Date.now() + 300000
    while (Date.now() < deadline) {
      const err = (await page.locator('.text-destructive').allInnerTexts().catch(() => [])).filter(Boolean)
      const formGone = !(await url.isVisible().catch(() => false))
      if (formGone) break
      if (err.length) throw new Error('endpoint form error: ' + err.join(' | '))
      await page.waitForTimeout(1000)
    }
    const state = await waitForShell(page, 300000)
    if (state !== 'shell') throw new Error('onboarding still shown after Connect')
    const cfg = readConfig()
    fs.writeFileSync(path.join(out, 'config-after-setup.yaml'), cfg)
    if (!/provider:\s*['"]?custom/.test(cfg) || !cfg.includes('127.0.0.1:8080')) throw new Error('config.yaml lacks provider custom + base_url:\n' + cfg.slice(0, 600))
    const model = (cfg.match(/default:\s*['"]?([^\s'"]+)/) || [])[1]
    return `config.yaml: provider=custom base_url=${baseUrl} model=${model}`
  })

  await step('03-chat', 'Send a prompt in a new chat and get a non-empty reply from the local model', P, async rec => {
    const f = await shot(page, 'chat-empty'); if (f) rec.screenshots.push(f)
    const r = await chat(page, 'Answer in one short sentence and do not use any tools: what is a lease agreement?')
    fs.writeFileSync(path.join(out, 'chat1.json'), JSON.stringify(r, null, 2))
    if (!r.text) throw new Error('no assistant reply; system messages: ' + r.systemMsgs.join(' | '))
    if (/can't reach|cannot reach|error|erreur/i.test(r.text) && r.text.length < 300) throw new Error('assistant turn looks like an error: ' + r.text)
    return 'reply: ' + r.text.slice(0, 400).replace(/\s+/g, ' ')
  })

  await step('04-cabinet', 'Cabinet: open Droit des Sociétés space, add a client and a dossier', P, async rec => {
    await page.keyboard.press('Escape').catch(() => {})
    const cabinet = page.getByRole('navigation', { name: 'Domaines du cabinet juridique' })
    await cabinet.getByText('Droit des Sociétés', { exact: true }).click()
    await cabinet.getByRole('button', { name: '+ Créer un espace Droit des Sociétés', exact: true }).click()
    await page.getByRole('heading', { name: 'Cabinet juridique — Droit des Sociétés', exact: true }).waitFor({ timeout: 30000 })
    const f = await shot(page, 'cabinet-space'); if (f) rec.screenshots.push(f)
    await page.getByRole('button', { name: 'Clients et dossiers', exact: true }).click()
    await page.getByLabel('Nom du client', { exact: true }).fill('Client QA fonctionnel')
    await page.getByRole('button', { name: 'Ajouter le client', exact: true }).click()
    await page.getByLabel('Client du dossier', { exact: true }).selectOption({ label: 'Client QA fonctionnel' })
    await page.getByLabel('Intitulé du dossier', { exact: true }).fill('Dossier QA fonctionnel')
    await page.getByLabel('Type de dossier', { exact: true }).selectOption({ index: 1 })
    await page.getByRole('button', { name: 'Créer le dossier', exact: true }).click()
    await waitBodyText(page, 'Dossier QA fonctionnel')
    return 'client "Client QA fonctionnel" and dossier "Dossier QA fonctionnel" created'
  })

  await step('05-studio', 'Studio: open Actelyo Studio and show the hardware / models pane', P, async rec => {
    await page.keyboard.press('Escape').catch(() => {})
    await page.getByRole('button', { name: 'Actelyo Studio', exact: true }).click()
    await page.getByTestId('actelyo-studio').waitFor({ timeout: 30000 })
    const choose = page.getByRole('button', { name: /^(Let me choose|Configuration…)$/ })
    const machine = page.getByText(/^(This machine|Cette machine)$/).first()
    const deadline = Date.now() + 120000
    let clicked = false
    while (Date.now() < deadline) {
      if (await machine.isVisible().catch(() => false)) break
      if (!clicked && await choose.first().isVisible().catch(() => false)) {
        const f = await shot(page, 'studio-quickstart'); if (f) rec.screenshots.push(f)
        await choose.first().click(); clicked = true
      }
      await page.waitForTimeout(1000)
    }
    await machine.waitFor({ timeout: 5000 })
    const text = await page.getByTestId('actelyo-studio').locator('xpath=..').innerText().catch(() => '')
    fs.writeFileSync(path.join(out, 'studio.txt'), text)
    return (clicked ? 'clicked "Let me choose"; ' : '') + 'hardware section visible'
  })

  await step('06-close', 'Quit the app', P, async () => {
    await app.close()
    app = null
    page = null
    return 'closed'
  })

  // ---------------- Second launch: persistence ----------------
  await step('07-relaunch', 'Restart the app; provider config persisted (no onboarding, config.yaml intact)', P, async () => {
    ;({ app, page } = await launch('run2'))
    const state = await waitForShell(page, 600000)
    await page.waitForTimeout(5000)
    if (state === 'onboarding' || await page.getByRole('button', { name: HAVE_KEY }).first().isVisible().catch(() => false)) {
      throw new Error('provider onboarding shown again after restart')
    }
    const cfg = readConfig()
    fs.writeFileSync(path.join(out, 'config-after-restart.yaml'), cfg)
    if (!/provider:\s*['"]?custom/.test(cfg) || !cfg.includes('127.0.0.1:8080')) throw new Error('config lost after restart')
    return 'no onboarding; config.yaml still provider=custom base_url=' + baseUrl
  })

  await step('08-chat-after-restart', 'Chat again after restart (persisted provider works)', P, async () => {
    const newChat = page.getByRole('button', { name: /^(New chat|New session|Nouvelle conversation|Nouvelle session)$/ }).first()
    if (await newChat.isVisible().catch(() => false)) await newChat.click().catch(() => {})
    const r = await chat(page, 'Reply with one short sentence: name one type of court.')
    fs.writeFileSync(path.join(out, 'chat2.json'), JSON.stringify(r, null, 2))
    if (!r.text) throw new Error('no assistant reply after restart; system: ' + r.systemMsgs.join(' | '))
    return 'reply: ' + r.text.slice(0, 400).replace(/\s+/g, ' ')
  })

  await step('09-cabinet-persisted', 'Cabinet data persisted across restart', P, async () => {
    await page.keyboard.press('Escape').catch(() => {})
    const cabinet = page.getByRole('navigation', { name: 'Domaines du cabinet juridique' })
    await cabinet.getByText('Droit des Sociétés', { exact: true }).first().click()
    await cabinet.getByRole('button', { name: 'Clients et dossiers', exact: true }).first().click()
    await page.getByRole('heading', { name: 'Cabinet juridique — Droit des Sociétés', exact: true }).waitFor({ timeout: 30000 })
    await waitBodyText(page, 'Client QA fonctionnel', 20000)
    await waitBodyText(page, 'Dossier QA fonctionnel', 5000)
    return 'client "Client QA fonctionnel" and its dossier still listed'
  })
} finally {
  if (app) await app.close().catch(() => {})
  writeReport()
  appLog.end()
}
const failed = steps.filter(s => !s.ok)
console.log(`\n${steps.length - failed.length}/${steps.length} steps passed`)
process.exit(failed.length ? 1 : 0)
