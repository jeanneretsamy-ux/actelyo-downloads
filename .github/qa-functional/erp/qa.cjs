// Functional QA of the installed Actelyo ERP Desktop (Windows).
// - Starts two llama-server instances (chat + embeddings) and an
//   LM Studio-compatible router on 127.0.0.1:1234.
// - Drives the real installed .exe through Playwright (Electron/CDP),
//   native file dialogs through UI Automation (dialog.ps1).
// - Writes report.json + screenshots + logs into OUT.
'use strict';
const fs = require('fs'), path = require('path'), http = require('http');
const { spawn } = require('child_process');
const { _electron, chromium } = require('playwright');
const JSZip = require('jszip');

const OUT = process.env.QA_OUT;
const EXE = process.env.ERP_EXE;
const HERE = __dirname;
const SHOTS = path.join(OUT, 'screenshots');
const LOGS = path.join(OUT, 'logs');
const FIX = path.join(OUT, 'fixtures');
for (const d of [SHOTS, LOGS, FIX]) fs.mkdirSync(d, { recursive: true });

const report = { app: 'Actelyo ERP Desktop', exe: EXE, startedAt: new Date().toISOString(), launchMode: null, appVersion: null, steps: [], pageErrors: [], consoleErrors: [], cloudRequests: [], notes: [] };
const log = (...a) => { const line = `[${new Date().toISOString()}] ${a.join(' ')}`; console.log(line); fs.appendFileSync(path.join(LOGS, 'qa.log'), line + '\n'); };
process.on('unhandledRejection', e => log('unhandledRejection', e && e.message));
const sleep = ms => new Promise(r => setTimeout(r, ms));
let shotN = 0;

// ---------------------------------------------------------------- engines
const CHAT_PORT = 1240, EMBED_PORT = 1241, PROXY_PORT = 1234;
const CHAT_ID = 'legalya-v36-r2', EMBED_ID = 'actelyo-embed';
const children = [];
function startProc(name, exe, args) {
  const out = fs.createWriteStream(path.join(LOGS, name + '.log'));
  out.write(`$ ${exe} ${args.join(' ')}\n`);
  const p = spawn(exe, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  p.stdout.pipe(out); p.stderr.pipe(out);
  p.on('exit', c => log(name, 'exited', c));
  children.push(p); return p;
}
function startEngines() {
  const bin = path.join(process.env.LLAMA_DIR, 'llama-server.exe');
  startProc('llama-chat', bin, ['-m', process.env.CHAT_GGUF, '-a', CHAT_ID, '--host', '127.0.0.1', '--port', String(CHAT_PORT),
    '-c', '8192', '-t', '4', '--jinja', '--chat-template-kwargs', '{"enable_thinking":false}', '--reasoning-budget', '0', '--no-webui']);
  startProc('llama-embed', bin, ['-m', process.env.EMBED_GGUF, '-a', EMBED_ID, '--host', '127.0.0.1', '--port', String(EMBED_PORT),
    '--embeddings', '--pooling', 'mean', '-c', '2048', '-b', '2048', '-ub', '2048', '-t', '2', '--no-webui']);
}
const proxyLog = fs.createWriteStream(path.join(LOGS, 'lmstudio-proxy.log'));
function lmModels(native) {
  const base = [{ id: CHAT_ID, type: 'llm' }, { id: EMBED_ID, type: 'embeddings' }];
  return { object: 'list', data: base.map(m => native
    ? { id: m.id, object: 'model', type: m.type, publisher: 'qa', arch: m.type === 'llm' ? 'qwen3' : 'nomic-bert', compatibility_type: 'gguf', quantization: m.type === 'llm' ? 'Q8_0' : 'Q4_K_M', state: 'loaded', max_context_length: m.type === 'llm' ? 8192 : 2048 }
    : { id: m.id, object: 'model', owned_by: 'llama.cpp' }) };
}
function startProxy() {
  // LM Studio-compatible facade: /v1/models, /api/v0/models, chat → Qwen3, embeddings → nomic.
  const server = http.createServer((req, res) => {
    const t0 = Date.now(); const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS' };
    const done = (status, extra = '') => proxyLog.write(`${new Date().toISOString()} ${req.method} ${req.url} -> ${status} ${Date.now() - t0}ms ${extra}\n`);
    if (req.method === 'OPTIONS') { res.writeHead(204, cors); res.end(); return done(204); }
    const url = req.url.split('?')[0];
    if (req.method === 'GET' && (url === '/v1/models' || url === '/api/v0/models')) { res.writeHead(200, { ...cors, 'Content-Type': 'application/json' }); res.end(JSON.stringify(lmModels(url.startsWith('/api')))); return done(200); }
    const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => {
      const body = Buffer.concat(chunks); let model = '';
      try { model = JSON.parse(body.toString('utf8') || '{}').model || ''; } catch { }
      const embed = /embeddings$/.test(url) || model === EMBED_ID;
      const target = url.replace(/^\/api\/v0\//, '/v1/');
      const up = http.request({ host: '127.0.0.1', port: embed ? EMBED_PORT : CHAT_PORT, method: req.method, path: target, headers: { 'Content-Type': 'application/json', 'Content-Length': body.length } }, r => {
        const resChunks = []; r.on('data', c => resChunks.push(c)); r.on('end', () => {
          const resBody = Buffer.concat(resChunks);
          res.writeHead(r.statusCode, { ...cors, 'Content-Type': r.headers['content-type'] || 'application/json' }); res.end(resBody);
          let summary = `model=${model} backend=${embed ? 'embed' : 'chat'} req=${body.length}B res=${resBody.length}B`;
          if (!embed) { try { const j = JSON.parse(resBody.toString('utf8')); summary += ' content=' + JSON.stringify(String(j.choices?.[0]?.message?.content ?? '').slice(0, 300)); } catch { } }
          done(r.statusCode, summary);
        });
      });
      up.on('error', e => { res.writeHead(502, cors); res.end(JSON.stringify({ error: e.message })); done(502, e.message); });
      up.end(body);
    });
  });
  return new Promise(r => server.listen(PROXY_PORT, '127.0.0.1', () => r(server)));
}
async function httpJson(method, url, body, timeout = 120000) {
  const r = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(timeout) });
  const text = await r.text(); if (!r.ok) throw new Error(`HTTP ${r.status} ${text.slice(0, 300)}`); return JSON.parse(text);
}
async function waitHealth(port, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { const r = await fetch(`http://127.0.0.1:${port}/health`); if (r.ok) return; } catch { } await sleep(1000); }
  throw new Error('llama-server not healthy on port ' + port);
}

// ---------------------------------------------------------------- helpers
function runPs(script, args, timeoutMs = 120000) {
  return new Promise(resolve => {
    const p = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(HERE, script), ...args], { windowsHide: true });
    let out = ''; p.stdout.on('data', d => out += d); p.stderr.on('data', d => out += d);
    const t = setTimeout(() => { try { p.kill(); } catch { } }, timeoutMs);
    p.on('exit', code => { clearTimeout(t); resolve({ code, out: out.trim() }); });
  });
}
let app = null, page = null, browser = null, appProc = null;
async function shot(step, label) {
  const base = `${String(++shotN).padStart(2, '0')}-${label}`;
  const names = [];
  if (page) { try { await page.screenshot({ path: path.join(SHOTS, base + '-app.png'), animations: 'disabled', timeout: 20000 }); names.push(base + '-app.png'); } catch (e) { log('page screenshot failed', e.message); } }
  const d = await runPs('desktop-shot.ps1', ['-Out', path.join(SHOTS, base + '-desktop.png')], 30000);
  if (d.code === 0) names.push(base + '-desktop.png'); else log('desktop shot failed', d.out);
  if (step) step.screenshots.push(...names);
  return names;
}
async function nativeDialog(step, filePath, label) {
  const shotName = `${String(++shotN).padStart(2, '0')}-${label}-native-dialog-desktop.png`;
  const r = await runPs('dialog.ps1', ['-Path', filePath, '-Shot', path.join(SHOTS, shotName), '-TimeoutSec', '60'], 120000);
  log('dialog.ps1 exit', r.code, r.out.replace(/\r?\n/g, ' | '));
  if (fs.existsSync(path.join(SHOTS, shotName))) step.screenshots.push(shotName);
  step.details.push('Native dialog (UI Automation): ' + r.out.replace(/\r?\n/g, ' | '));
  return r.code === 0;
}
async function waitEither(okLoc, badLoc, timeout) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await okLoc.first().isVisible().catch(() => false)) return 'ok';
    if (badLoc && await badLoc.first().isVisible().catch(() => false)) return 'bad';
    await sleep(500);
  }
  return 'timeout';
}
const erpRows = table => page.evaluate(t => window.electronAPI.erp.query({ table: t, operation: 'select', filters: [] }).then(r => r.data), table);
async function step(id, name, fn) {
  const s = { id, name, status: 'fail', details: [], screenshots: [], startedAt: new Date().toISOString() };
  report.steps.push(s); log('=== STEP', id, name);
  try { await fn(s); if (s.status === 'fail') s.status = 'pass'; }
  catch (e) {
    s.status = 'fail'; s.error = String(e && e.stack || e).slice(0, 3000); log('STEP FAIL', id, e && e.message);
    try { s.bodyText = (await page.locator('body').innerText({ timeout: 5000 })).slice(-3000); } catch { }
    try { await shot(s, id + '-failure'); } catch { }
  }
  s.endedAt = new Date().toISOString(); writeReport(); return s;
}
function writeReport() { report.summary = Object.fromEntries(report.steps.map(s => [s.id, s.status])); fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2)); }

async function go(route) {
  if (await page.getByRole('dialog').count()) { await page.keyboard.press('Escape'); await sleep(500); }
  await page.evaluate(r => { window.location.hash = r; }, route);
  await sleep(1500);
}
async function clickNav(label, route) {
  // Real sidebar click when available; hash navigation otherwise.
  const link = page.getByRole('link', { name: label, exact: true }).first();
  if (await link.count() && await link.isVisible().catch(() => false)) { await link.click(); await sleep(1500); return 'sidebar'; }
  await go(route); return 'hash';
}

let appLogStream = fs.createWriteStream(path.join(LOGS, 'app-stdout.log'), { flags: 'a' });
function attachPage(p) {
  p.on('pageerror', e => report.pageErrors.push(e.message));
  p.on('console', m => { if (m.type() === 'error') report.consoleErrors.push(m.text().slice(0, 500)); fs.appendFileSync(path.join(LOGS, 'renderer-console.log'), `[${m.type()}] ${m.text()}\n`); });
  p.on('request', r => { if (/supabase\.co/.test(r.url())) report.cloudRequests.push(r.url()); });
}
async function launch(tag) {
  appLogStream.write(`\n===== launch ${tag} ${new Date().toISOString()}\n`);
  const env = { ...process.env }; delete env.ELECTRON_RUN_AS_NODE; delete env.VITE_DEV_SERVER_URL; delete env.NODE_PATH;
  try {
    app = await _electron.launch({ executablePath: EXE, args: ['--disable-renderer-backgrounding'], env, timeout: 180000 });
    app.process().stdout.on('data', d => appLogStream.write(d)); app.process().stderr.on('data', d => appLogStream.write(d));
    page = await app.firstWindow({ timeout: 120000 });
    for (let i = 0; i < 30 && !page.url().startsWith('actelyo://'); i++) { const w = app.windows().find(x => x.url().startsWith('actelyo://')); if (w) { page = w; break; } await sleep(1000); }
    report.launchMode = 'playwright._electron.launch (CDP + inspector)';
  } catch (e) {
    log('_electron.launch failed, falling back to --remote-debugging-port', e.message);
    report.notes.push('_electron.launch failed: ' + e.message.slice(0, 300));
    app = null;
    appProc = spawn(EXE, ['--remote-debugging-port=9222', '--disable-renderer-backgrounding'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    appProc.stdout.on('data', d => appLogStream.write(d)); appProc.stderr.on('data', d => appLogStream.write(d));
    let lastErr;
    for (let i = 0; i < 90; i++) { try { browser = await chromium.connectOverCDP('http://127.0.0.1:9222'); break; } catch (err) { lastErr = err; await sleep(1000); } }
    if (!browser) throw lastErr;
    for (let i = 0; i < 60 && !page; i++) { for (const c of browser.contexts()) for (const p of c.pages()) if (p.url().startsWith('actelyo://')) page = p; if (!page) await sleep(1000); }
    if (!page) throw new Error('No actelyo:// page over CDP');
    report.launchMode = 'spawn --remote-debugging-port=9222 + chromium.connectOverCDP';
  }
  attachPage(page);
  await page.waitForLoadState('domcontentloaded');
  if (app) { try { report.appVersion = await app.evaluate(({ app }) => app.getVersion()); await app.evaluate(({ BrowserWindow }) => { const w = BrowserWindow.getAllWindows()[0]; w.maximize(); w.show(); w.focus(); }); } catch (e) { log('app.evaluate failed', e.message); } }
  log('launched', report.launchMode, page.url());
}
async function closeApp() {
  if (app) { await app.close().catch(e => log('close', e.message)); app = null; }
  else if (browser) { try { await page.evaluate(() => window.close()); } catch { } await sleep(3000); try { appProc.kill(); } catch { } await browser.close().catch(() => { }); browser = null; }
  page = null; await sleep(4000);
}

// ---------------------------------------------------------------- fixture
async function makeDocx(file) {
  const { Document, Packer, Paragraph, HeadingLevel } = require('docx');
  const doc = new Document({ sections: [{ children: [
    new Paragraph({ text: 'Bail commercial — Leroy contre Bernard', heading: HeadingLevel.HEADING_1 }),
    new Paragraph('Entre la SCI Bernard Immobilier, bailleur, et Madame Julie Leroy, preneur, il est convenu ce qui suit.'),
    new Paragraph('Article 1 — Durée. Le bail est consenti pour une durée de neuf années à compter du 1er janvier 2026.'),
    new Paragraph('Article 2 — Loyer. Le loyer annuel est fixé à 18 600 euros hors taxes, payable trimestriellement et d’avance.'),
    new Paragraph('Article 3 — Dépôt de garantie. Le preneur verse un dépôt de garantie de 4 650 euros à la signature.'),
    new Paragraph('Article 4 — Destination. Les locaux situés 12 rue des Lilas à Lyon sont destinés à une activité de librairie.'),
  ] }] });
  fs.writeFileSync(file, await Packer.toBuffer(doc));
}

// ---------------------------------------------------------------- main
(async () => {
  const DOCX = path.join(FIX, 'bail-leroy-bernard.docx');
  const EXPORT = path.join(OUT, 'export-reponse-qa.docx');
  const QUESTION = 'Quel est le montant exact du loyer annuel dans le bail de Julie Leroy ?';
  const PROMPT = 'Crée le dossier Leroy contre Bernard pour notre cliente Julie Leroy, bail commercial, et pose une échéance de conclusions le 23/12/2026.';
  let dossier = null, identity = null;

  await step('S0', 'Local LLM engine (llama.cpp) behind LM Studio-compatible API on 127.0.0.1:1234', async s => {
    startEngines(); await startProxy();
    await waitHealth(CHAT_PORT, 300000); await waitHealth(EMBED_PORT, 300000);
    const models = await httpJson('GET', `http://127.0.0.1:${PROXY_PORT}/api/v0/models`);
    s.details.push('models: ' + models.data.map(m => m.id + '/' + m.type + '/' + m.state).join(', '));
    const t0 = Date.now();
    const chat = await httpJson('POST', `http://127.0.0.1:${PROXY_PORT}/v1/chat/completions`, { model: CHAT_ID, messages: [{ role: 'user', content: 'Réponds seulement : connexion locale établie.' }], max_tokens: 32, temperature: 0 });
    const content = chat.choices?.[0]?.message?.content || '';
    s.details.push(`chat (${Date.now() - t0}ms): ${JSON.stringify(content)}`);
    if (!content.trim()) throw new Error('empty chat content');
    const emb = await httpJson('POST', `http://127.0.0.1:${PROXY_PORT}/v1/embeddings`, { model: EMBED_ID, input: ['search_query: test'] });
    s.details.push('embedding dims: ' + emb.data[0].embedding.length);
    await makeDocx(DOCX); s.details.push('fixture: ' + DOCX + ' (' + fs.statSync(DOCX).size + ' B)');
  });

  await launch('first');

  await step('S1', 'First launch: new user / continue without account (local mode, no Supabase)', async s => {
    const btn = page.getByRole('button', { name: /Je suis nouvel utilisateur|Continuer sans compte/ }).first();
    await btn.waitFor({ timeout: 120000 });
    await shot(s, 'S1-welcome');
    s.details.push('clicked: ' + (await btn.innerText()).trim());
    await btn.click();
    await page.getByRole('textbox', { name: 'Demander au copilote' }).waitFor({ timeout: 120000 });
    identity = await page.evaluate(() => window.electronAPI.erp.identity());
    const mode = await page.evaluate(() => localStorage.getItem('actelyo.desktop.account-mode'));
    s.details.push(`url=${page.url()} account-mode=${mode} identity.aud=${identity.aud} role=${identity.role} access_token=${!!identity.access_token}`);
    if (identity.aud !== 'desktop-local') throw new Error('identity is not desktop-local');
    await shot(s, 'S1-dashboard');
    if (report.cloudRequests.length) throw new Error('Supabase requests observed: ' + report.cloudRequests.length);
  });

  await step('S1b', 'Connect local engine via UI (Modèles et moteurs locaux → LM Studio → Tester → Utiliser ce modèle)', async s => {
    const open = page.getByRole('button', { name: 'Choisir les modèles locaux' }).first();
    await open.waitFor({ timeout: 30000 }); await open.click();
    const dlg = page.getByRole('dialog').filter({ hasText: 'Modèles et moteurs locaux' });
    await dlg.waitFor({ timeout: 30000 });
    await page.getByRole('button', { name: 'Choisir LM Studio' }).click();
    await dlg.getByText('Serveur connecté', { exact: true }).waitFor({ timeout: 60000 });
    const sel = dlg.getByLabel('Modèle de rédaction local'), esel = dlg.getByLabel('Modèle d’embeddings local');
    if (await sel.inputValue() !== CHAT_ID) await sel.selectOption(CHAT_ID);
    if (await esel.inputValue() !== EMBED_ID) await esel.selectOption(EMBED_ID);
    s.details.push(`selected chat=${await sel.inputValue()} embed=${await esel.inputValue()}`);
    await shot(s, 'S1b-engine-detected');
    await dlg.getByRole('button', { name: 'Tester le modèle' }).click();
    const ok = dlg.getByText(/Réponse de legalya-v36-r2/);
    const r1 = await waitEither(ok, dlg.getByRole('alert'), 180000);
    if (r1 !== 'ok') throw new Error('model test ' + r1 + ': ' + await dlg.getByRole('alert').first().innerText().catch(() => ''));
    s.details.push('test: ' + (await ok.innerText()).slice(0, 200));
    await dlg.getByRole('button', { name: 'Utiliser ce modèle' }).click();
    await dlg.getByText(/Modèle actif/).waitFor({ timeout: 30000 });
    await shot(s, 'S1b-engine-active');
    await page.keyboard.press('Escape'); await sleep(800);
    const st = await page.evaluate(() => window.electronAPI.local.status());
    s.details.push('stored config: ' + JSON.stringify(st.config));
    if (st.config.model !== CHAT_ID || st.config.embeddingModel !== EMBED_ID) throw new Error('engine config not stored');
  }).then(async s => {
    if (s.status === 'fail') { // keep later steps testable; flagged in notes
      try { await page.keyboard.press('Escape'); await page.evaluate(c => window.electronAPI.local.configure(c), { provider: 'lmstudio', baseUrl: 'http://127.0.0.1:1234/v1', model: CHAT_ID, embeddingModel: EMBED_ID }); report.notes.push('S1b failed in UI: engine configured through IPC (desktop-local:configure) so later steps can run.'); } catch (e) { report.notes.push('IPC configure fallback failed: ' + e.message); }
    }
  });

  await step('S2', 'Create a dossier with client + échéance via the Copilot, accepted with « Autoriser »', async s => {
    if (!page.url().includes('/dashboard')) await go('/dashboard');
    const box = page.getByRole('textbox', { name: 'Demander au copilote' }).first();
    await box.waitFor({ timeout: 30000 }); await box.fill(PROMPT); await box.press('Enter');
    const dlg = page.getByRole('dialog', { name: 'Autoriser la création locale' });
    await dlg.waitFor({ timeout: 60000 });
    s.details.push('proposal: ' + (await dlg.innerText()).replace(/\s+/g, ' ').slice(0, 500));
    if ((await erpRows('client_dossiers')).length !== 0) throw new Error('dossier created before approval');
    await shot(s, 'S2-copilot-proposal');
    await dlg.getByRole('button', { name: 'Autoriser', exact: true }).click();
    await dlg.waitFor({ state: 'hidden', timeout: 60000 });
    await sleep(1500); await shot(s, 'S2-copilot-confirmed');
    const cases = await erpRows('client_dossiers'), clients = await erpRows('parapheur_clients'), deadlines = await erpRows('folder_deadlines'), tasks = await erpRows('collaborative_tasks');
    dossier = cases.find(c => c.name === 'Leroy contre Bernard');
    s.details.push(`rows: dossiers=${cases.length} clients=${clients.map(c => c.nom).join('|')} deadlines=${deadlines.map(d => d.name + '@' + d.end_date).join('|')} tasks=${tasks.length}`);
    if (!dossier) throw new Error('dossier not stored');
    if (cases.length !== 1) throw new Error('expected 1 dossier, got ' + cases.length);
    if (!clients.some(c => c.nom === 'Julie Leroy') || dossier.client_id !== clients.find(c => c.nom === 'Julie Leroy').id) throw new Error('client not linked');
    if (!deadlines.some(d => d.end_date === '2026-12-23' && d.folder_id === dossier.id)) throw new Error('échéance missing');
    s.details.push(`dossier id=${dossier.id} ref=${dossier.reference_dossier} type=${dossier.dossier_type}`);
    s.details.push('nav: ' + await clickNav('Dossiers', '/dossiers'));
    await page.getByText('Leroy contre Bernard', { exact: true }).first().waitFor({ timeout: 30000 });
    await shot(s, 'S2-dossiers-list');
    await page.getByText('Leroy contre Bernard', { exact: true }).first().click();
    await sleep(2500);
    s.details.push('detail url: ' + page.url());
    if ((await page.locator('body').innerText()).includes('Erreur de rendu')) throw new Error('render error on dossier detail');
    await shot(s, 'S2-dossier-detail');
    await go('/deadlines');
    await page.getByText('Leroy contre Bernard').first().waitFor({ timeout: 30000 }).then(() => s.details.push('échéance visible in /deadlines'), () => s.details.push('WARN: échéance not found in /deadlines view'));
    await shot(s, 'S2-deadlines');
  }).then(async s => {
    if (s.status === 'fail' && !dossier) {
      try {
        const existing = (await erpRows('client_dossiers')).find(c => c.name === 'Leroy contre Bernard');
        if (existing) dossier = existing; else {
          const p = await page.evaluate(() => window.electronAPI.erp.prepareAction({ type: 'create_case', name: 'Leroy contre Bernard', clientName: 'Julie Leroy', deadline: '2026-12-23', dossierType: 'baux', deadlineName: 'Conclusions' }));
          dossier = (await page.evaluate(id => window.electronAPI.erp.resolveAction(id, true), p.id)).dossier;
        }
        report.notes.push('S2 failed: dossier obtained through IPC fallback so later steps can run.');
      } catch (e) { report.notes.push('S2 IPC fallback failed: ' + e.message); }
    }
  });

  await step('S3', 'Import a .docx into the dossier and index it (Documents → Espaces et pièces → Ajouter des fichiers)', async s => {
    if (!dossier) throw new Error('no dossier');
    s.details.push('nav: ' + await clickNav('Documents', '/documents'));
    let picker = page.getByLabel('Pièces du dossier');
    if (!await picker.count()) { await go('/documents'); picker = page.getByLabel('Pièces du dossier'); }
    await picker.waitFor({ timeout: 30000 });
    await picker.selectOption(dossier.id);
    await page.getByRole('button', { name: 'Espaces et pièces', exact: true }).click();
    const add = page.getByRole('button', { name: 'Ajouter des fichiers', exact: true });
    await add.waitFor({ timeout: 30000 });
    await shot(s, 'S3-resources');
    await add.click();
    let ok = await nativeDialog(s, DOCX, 'S3-open');
    if (!ok && app) {
      report.notes.push('S3: native Open dialog could not be driven; dialog.showOpenDialog stubbed in main process (same IPC/ingest path).');
      await sleep(2000);
      await app.evaluate(({ dialog }, f) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [f] }); }, DOCX);
      await add.click(); ok = true; s.details.push('FALLBACK: stubbed showOpenDialog');
    }
    if (!ok) throw new Error('native dialog failed');
    const notice = page.getByText(/fichier\(s\) importé\(s\)/).first();
    await notice.waitFor({ timeout: 300000 });
    s.details.push('notice: ' + (await notice.innerText()).replace(/\s+/g, ' ').slice(0, 400));
    await sleep(1000); await shot(s, 'S3-imported');
    const links = (await erpRows('erp_knowledge_links')).filter(l => l.dossier_id === dossier.id);
    const st = await page.evaluate(() => window.electronAPI.local.status());
    const doc = st.documents.find(d => d.name === 'bail-leroy-bernard.docx');
    s.details.push(`links=${links.length} documents=${st.totalDocuments} chunks=${st.chunks} embeddedChunks=${st.embeddedChunks} doc=${doc && JSON.stringify(doc)}`);
    if (!/1 fichier\(s\) importé/.test(await notice.innerText())) throw new Error('import notice does not report 1 file');
    if (!doc) throw new Error('document not indexed');
    if (!links.some(l => l.knowledge_id === doc.id)) throw new Error('document not linked to dossier');
    if (!(st.embeddedChunks > 0)) throw new Error('no embedded chunks (embeddings not produced)');
  });

  let answer = null;
  await step('S4', 'Ask a question about the document in Conversation → sourced answer', async s => {
    await page.getByRole('button', { name: 'Conversation', exact: true }).click();
    const q = page.getByLabel('Question sur les pièces'); await q.waitFor({ timeout: 30000 });
    await q.fill(QUESTION);
    const t0 = Date.now();
    await page.getByRole('button', { name: 'Envoyer la question', exact: true }).click();
    await sleep(1500); await shot(s, 'S4-asking');
    const src = page.getByText(/Sources citées/), err = page.locator('p[role="alert"]');
    const r2 = await waitEither(src, err, 420000);
    if (r2 !== 'ok') throw new Error('conversation ' + r2 + ': ' + await err.first().innerText().catch(() => ''));
    s.details.push(`answer time ${Date.now() - t0}ms`);
    const msgs = (await erpRows('local_rag_messages')).filter(m => m.role === 'assistant');
    answer = msgs[msgs.length - 1];
    s.details.push('model label: ' + answer.model);
    s.details.push('answer: ' + JSON.stringify(answer.content).slice(0, 800));
    s.details.push('sources: ' + (answer.sources || []).map(x => x.name).join(', '));
    s.answerKind = /Extrait vérifié/.test(answer.content) ? 'Extrait vérifié (extractive fallback)' : 'LLM generated';
    s.details.push('answer kind: ' + s.answerKind);
    const sum = page.locator('details summary').first(); if (await sum.count()) await sum.click().catch(() => { });
    await sleep(800); await shot(s, 'S4-answer');
    if (!(answer.sources || []).some(x => x.name === 'bail-leroy-bernard.docx')) throw new Error('answer not sourced from the imported document');
    if (!answer.content.replace(/[^\d]/g, '').includes('18600')) throw new Error('answer does not contain the exact rent 18 600');
  });

  await step('S5', 'Export the answer to Word (« Exporter en Word » → native Save dialog)', async s => {
    const btn = page.getByRole('button', { name: 'Exporter en Word', exact: true }).last();
    await btn.waitFor({ timeout: 30000 }); await btn.click();
    let ok = await nativeDialog(s, EXPORT, 'S5-save');
    if (!ok && app) {
      report.notes.push('S5: native Save dialog could not be driven; dialog.showSaveDialog stubbed in main process.');
      await sleep(2000);
      await app.evaluate(({ dialog }, f) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: f }); }, EXPORT);
      await btn.click(); ok = true; s.details.push('FALLBACK: stubbed showSaveDialog');
    }
    for (let i = 0; i < 30 && !fs.existsSync(EXPORT); i++) await sleep(1000);
    if (!fs.existsSync(EXPORT)) throw new Error('export file not written');
    await sleep(1000);
    const zip = await JSZip.loadAsync(fs.readFileSync(EXPORT));
    const xml = await zip.file('word/document.xml').async('string');
    const text = xml.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
    fs.writeFileSync(path.join(OUT, 'export-reponse-qa.txt'), text);
    s.details.push(`export ${fs.statSync(EXPORT).size} B; text: ${text.slice(0, 600)}`);
    await shot(s, 'S5-exported');
    if (!text.includes('Sources locales')) throw new Error('export lacks "Sources locales"');
    if (!text.includes('bail-leroy-bernard.docx')) throw new Error('export lacks source file name');
    if (!text.replace(/[^\d]/g, '').includes('18600')) throw new Error('export lacks the answer amount');
  });

  await step('S6', 'Restart the app and check the dossier (and conversation) persisted', async s => {
    await closeApp();
    await launch('restart');
    const box = page.getByRole('textbox', { name: 'Demander au copilote' }).first();
    const welcome = page.getByRole('button', { name: /Je suis nouvel utilisateur|Continuer sans compte/ }).first();
    const r3 = await waitEither(box, welcome, 120000);
    if (r3 === 'bad') { await shot(s, 'S6-relaunch-welcome'); throw new Error('restart landed on the welcome/account choice again'); }
    if (r3 !== 'ok') throw new Error('dashboard not shown after restart');
    await shot(s, 'S6-relaunched-dashboard');
    const id2 = await page.evaluate(() => window.electronAPI.erp.identity());
    const cases = await erpRows('client_dossiers');
    s.details.push(`owner same=${identity && id2.id === identity.id} dossiers=${cases.map(c => c.name).join('|')}`);
    if (identity && id2.id !== identity.id) throw new Error('local owner changed after restart');
    if (!cases.some(c => dossier && c.id === dossier.id)) throw new Error('dossier missing after restart');
    s.details.push('nav: ' + await clickNav('Dossiers', '/dossiers'));
    await page.getByText('Leroy contre Bernard', { exact: true }).first().waitFor({ timeout: 30000 });
    await shot(s, 'S6-dossiers-after-restart');
    const st = await page.evaluate(() => window.electronAPI.local.status());
    s.details.push(`after restart: documents=${st.totalDocuments} embeddedChunks=${st.embeddedChunks} engine=${st.config.model}`);
    await go('/documents');
    const picker = page.getByLabel('Pièces du dossier'); await picker.waitFor({ timeout: 30000 }); await picker.selectOption(dossier.id);
    const conv = page.getByRole('button', { name: /Quel est le montant exact/ }).first();
    await conv.waitFor({ timeout: 30000 }); await conv.click();
    await page.getByText(/Sources citées/).first().waitFor({ timeout: 30000 });
    s.details.push('conversation and sources restored');
    await shot(s, 'S6-conversation-after-restart');
  });

  report.endedAt = new Date().toISOString();
  report.passed = report.steps.every(s => s.status === 'pass');
  writeReport();
})().catch(e => { log('FATAL', e && e.stack || e); report.fatal = String(e && e.stack || e); report.passed = false; writeReport(); })
  .finally(async () => {
    try { if (page) await shot(null, 'final'); } catch { }
    await closeApp().catch(() => { });
    for (const c of children) { try { c.kill(); } catch { } }
    writeReport(); log('DONE passed=' + report.passed);
    setTimeout(() => process.exit(report.passed ? 0 : 1), 2000);
  });
