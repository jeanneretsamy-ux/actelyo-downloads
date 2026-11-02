// Functional QA driver for Actelyo RAG Desktop (AnythingLLM-based Electron app).
// Connects to the running app over CDP and walks the real UI. Every step takes a
// screenshot and records pass/fail in report.json.
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const OUT = process.env.QA_OUT;
const SHOTS = path.join(OUT, 'screens');
const DOM = path.join(OUT, 'dom');
const DATA = process.env.QA_DATA;
const RUNTIME = process.env.QA_RUNTIME; // <install>\resources\runtime
const LLM_BASE = process.env.QA_LLM_BASE || 'http://127.0.0.1:8080/v1';
const EMB_BASE = process.env.QA_EMB_BASE || 'http://127.0.0.1:8081/v1';
const LLM_MODEL = process.env.QA_LLM_MODEL || 'qwen3-0.6b';
const EMB_MODEL = process.env.QA_EMB_MODEL || 'nomic-embed-text';
const DOC = path.join(DATA, 'bail-commercial-QX7429.txt');
for (const d of [SHOTS, DOM]) fs.mkdirSync(d, { recursive: true });

const report = { app: 'Actelyo RAG Desktop 1.0.3', startedAt: new Date().toISOString(), steps: [], notes: [] };
let page; let origin; let shotNo = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const save = () => fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2));

async function shot(name) {
  const file = `${String(++shotNo).padStart(2, '0')}-${name}.png`;
  try { await page.screenshot({ path: path.join(SHOTS, file), timeout: 20000 }); }
  catch (e) { log('screenshot failed', file, e.message); return null; }
  return file;
}
async function dumpDom(name) {
  try {
    fs.writeFileSync(path.join(DOM, `${name}.html`), await page.content());
    const text = await page.evaluate(() => document.body.innerText);
    fs.writeFileSync(path.join(DOM, `${name}.txt`), text);
  } catch (e) { log('dom dump failed', e.message); }
}
async function step(id, title, fn) {
  const rec = { id, title, status: 'running', screenshots: [], details: {} };
  report.steps.push(rec); save();
  const t0 = Date.now();
  log(`=== ${id} ${title}`);
  try {
    await fn(rec);
    rec.status = rec.status === 'running' ? 'pass' : rec.status;
  } catch (e) {
    rec.status = 'fail';
    rec.error = String(e?.stack || e).slice(0, 4000);
    log(`FAIL ${id}: ${e?.message}`);
    if (page) { const s = await shot(`${id}-FAIL`); if (s) rec.screenshots.push(s); await dumpDom(`${id}-FAIL`); }
  }
  rec.seconds = Math.round((Date.now() - t0) / 1000);
  log(`=== ${id} -> ${rec.status} (${rec.seconds}s)`);
  save();
  return rec.status === 'pass';
}
async function api(p, init = {}) {
  const r = await fetch(origin + p, { ...init, headers: { 'Content-Type': 'application/json', ...(init.headers || {}) } });
  const text = await r.text();
  let json = null; try { json = JSON.parse(text); } catch {}
  return { status: r.status, json, text: json ? null : text.slice(0, 300) };
}
async function clickIfVisible(locator, timeout = 1500) {
  try { await locator.first().waitFor({ state: 'visible', timeout }); await locator.first().click(); return true; }
  catch { return false; }
}
async function dismissPopups() {
  for (let i = 0; i < 2; i++) { await page.keyboard.press('Escape').catch(() => {}); await sleep(200); }
}
async function settings() { return (await api('/api/setup-complete')).json?.results || {}; }

async function connect() {
  const deadline = Date.now() + 360000;
  let browser;
  while (Date.now() < deadline) {
    try { browser = await chromium.connectOverCDP('http://127.0.0.1:9222', { timeout: 10000 }); break; }
    catch (e) { log('CDP not ready', e.message.split('\n')[0]); await sleep(3000); }
  }
  if (!browser) throw new Error('CDP endpoint never became available');
  while (Date.now() < deadline) {
    const pages = browser.contexts().flatMap((c) => c.pages());
    const app = pages.find((p) => p.url().startsWith('http://127.0.0.1'));
    if (app) { page = app; break; }
    const splash = pages.find((p) => p.url().startsWith('file:'));
    if (splash) {
      page = splash;
      const status = await splash.evaluate(() => document.body.innerText).catch(() => '');
      log('splash:', status.replace(/\s+/g, ' ').slice(0, 200));
    }
    await sleep(3000);
  }
  if (!page || !page.url().startsWith('http')) throw new Error('App page (http://127.0.0.1:PORT) never loaded; still on splash');
  origin = new URL(page.url()).origin;
  page.setDefaultTimeout(30000);
  try {
    const cdp = await page.context().newCDPSession(page);
    const { windowId } = await cdp.send('Browser.getWindowForTarget');
    await cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'maximized' } });
  } catch (e) { log('maximize via CDP failed', e.message); }
  await page.waitForLoadState('domcontentloaded');
  await sleep(4000);
  return browser;
}

async function ensureWorkspace(name) {
  await page.goto(origin + '/');
  await sleep(2500);
  await dismissPopups();
  const btn = page.getByRole('button', { name: /new workspace/i });
  if (!(await clickIfVisible(btn, 8000))) {
    const alt = page.locator('[data-tooltip-id="new-workspace-tooltip"], button:has-text("New Workspace")');
    await alt.first().click();
  }
  const input = page.locator('input[name="name"]');
  await input.waitFor({ state: 'visible' });
  await input.fill(name);
  const s = await shot(`new-workspace-modal-${name.replace(/\W+/g, '-')}`);
  await page.getByRole('button', { name: /^save$/i }).click();
  await page.waitForURL(/\/workspace\//, { timeout: 30000 });
  await sleep(2000);
  const slug = decodeURIComponent(new URL(page.url()).pathname.split('/')[2]);
  return { slug, shot: s };
}

async function uploadAndEmbed(rec, slug, files, prefix) {
  await page.goto(`${origin}/workspace/${slug}`);
  await sleep(2500);
  await dismissPopups();
  const up = page.locator('button[data-tooltip-id="upload-workspace"]');
  await up.first().waitFor({ state: 'attached' });
  await up.first().click({ force: true });
  const fileInput = page.locator('input[type="file"]');
  await fileInput.first().waitFor({ state: 'attached', timeout: 20000 });
  await sleep(1500);
  rec.screenshots.push(await shot(`${prefix}-manage-modal`));
  await fileInput.first().setInputFiles(files);
  const titles = files.map((f) => path.basename(f));
  // Wait until every uploaded file is listed in "My Documents".
  const deadline = Date.now() + 180000;
  for (const t of titles) {
    const row = page.locator('tr', { hasText: t.slice(0, 18) });
    await row.first().waitFor({ state: 'visible', timeout: Math.max(5000, deadline - Date.now()) });
  }
  await sleep(1500);
  rec.screenshots.push(await shot(`${prefix}-uploaded`));
  for (const t of titles) {
    const row = page.locator('tr', { hasText: t.slice(0, 18) }).first();
    await row.scrollIntoViewIfNeeded().catch(() => {});
    await row.getByText(t.slice(0, 18)).first().click();
    await sleep(400);
    const checked = await row.locator('input[type="checkbox"], [role="checkbox"]').first()
      .evaluate((el) => el.checked === true || el.getAttribute('aria-checked') === 'true').catch(() => null);
    if (checked === false) {
      await row.locator('input[type="checkbox"], [role="checkbox"]').first().click({ force: true });
      await sleep(400);
    }
  }
  await dumpDom(`${prefix}-selected`);
  rec.screenshots.push(await shot(`${prefix}-selected`));
  await page.getByRole('button', { name: /move to workspace/i }).first().click();
  await sleep(1500);
  rec.screenshots.push(await shot(`${prefix}-moved`));
  await page.getByRole('button', { name: /save and embed/i }).first().click();
  // Embedding: wait until the workspace lists the documents (server side truth).
  const t0 = Date.now();
  let docs = [];
  while (Date.now() - t0 < 300000) {
    const ws = (await api(`/api/workspace/${slug}`)).json?.workspace;
    docs = ws?.documents || [];
    if (docs.length >= files.length) break;
    await sleep(3000);
  }
  rec.details.embedSeconds = Math.round((Date.now() - t0) / 1000);
  await sleep(2000);
  rec.screenshots.push(await shot(`${prefix}-embedded`));
  const toast = await page.locator('.Toastify').innerText().catch(() => '');
  rec.details.toast = toast.slice(0, 300);
  rec.details.workspaceDocuments = docs.map((d) => d.filename || d.docpath);
  if (docs.length < files.length) throw new Error(`only ${docs.length}/${files.length} documents embedded in ${slug}; toast="${toast}"`);
  await page.keyboard.press('Escape');
  await sleep(1000);
  const closeBtn = page.locator('button[aria-label="Close"], button:has(svg) >> nth=0');
  if (await page.locator('input[type="file"]').count()) await clickIfVisible(page.locator('button[aria-label="Close"]'), 1500);
  void closeBtn;
}

async function main() {
  let browser;
  await step('S00', 'Launch app and connect over CDP', async (rec) => {
    browser = await connect();
    rec.details.origin = origin;
    rec.details.url = page.url();
    rec.details.ping = (await api('/api/ping')).json;
    rec.screenshots.push(await shot('welcome'));
    await dumpDom('S00-welcome');
    report.origin = origin;
    const s = await settings();
    rec.details.initial = { LLMProvider: s.LLMProvider, EmbeddingEngine: s.EmbeddingEngine, VectorDB: s.VectorDB, version: s.version };
  });
  if (!page) { report.finishedAt = new Date().toISOString(); save(); return; }

  await step('S01', 'Onboarding: Generic OpenAI LLM -> local llama-server', async (rec) => {
    if (!/\/onboarding/.test(page.url())) await page.goto(origin + '/onboarding');
    await sleep(1500);
    await page.getByRole('button', { name: /get started/i }).click();
    await page.waitForURL(/llm-preference/);
    await sleep(1500);
    rec.screenshots.push(await shot('onboarding-llm-list'));
    await page.getByPlaceholder(/search llm providers/i).fill('Generic');
    await page.getByText('Generic OpenAI', { exact: true }).first().click();
    const base = page.locator('input[name="GenericOpenAiBasePath"]');
    await base.waitFor();
    await base.fill(LLM_BASE);
    await page.locator('input[name="GenericOpenAiKey"]').fill('sk-local-qa');
    // Model: a <select> filled from llama-server /v1/models, or a free-text input.
    const model = page.locator('[name="GenericOpenAiModelPref"]').first();
    const dl = Date.now() + 30000;
    while (Date.now() < dl && (await model.isDisabled().catch(() => true))) await sleep(500);
    const tag = await model.evaluate((el) => el.tagName);
    if (tag === 'SELECT') {
      const opts = await model.locator('option').allTextContents();
      rec.details.modelOptions = opts;
      await model.selectOption({ label: opts.find((o) => o.includes(LLM_MODEL)) || opts[0] });
    } else await model.fill(LLM_MODEL);
    await page.locator('input[name="GenericOpenAiTokenLimit"]').fill('8192');
    const maxTok = page.locator('input[name="GenericOpenAiMaxTokens"]');
    if (await maxTok.count()) await maxTok.fill('512');
    rec.screenshots.push(await shot('onboarding-llm-filled'));
    await page.locator('button[aria-label="Continue"]').click();
    await page.waitForURL(/user-setup/, { timeout: 30000 });
    await sleep(1000);
    rec.screenshots.push(await shot('onboarding-user-setup'));
    await page.getByRole('button', { name: /just me/i }).click();
    await sleep(500);
    await page.getByRole('button', { name: /^no$/i }).click();
    await sleep(500);
    rec.screenshots.push(await shot('onboarding-just-me'));
    await page.locator('button[aria-label="Continue"]').click();
    await page.waitForURL(/data-handling/, { timeout: 30000 });
    await sleep(1500);
    rec.screenshots.push(await shot('onboarding-data-handling'));
    await page.locator('button[aria-label="Continue"]').click();
    await page.waitForURL(/survey/, { timeout: 30000 });
    await sleep(1000);
    rec.screenshots.push(await shot('onboarding-survey'));
    await page.getByRole('button', { name: /skip survey/i }).click();
    await page.waitForURL((u) => !/onboarding/.test(u.pathname), { timeout: 30000 });
    await sleep(2500);
    rec.screenshots.push(await shot('home-after-onboarding'));
    await dumpDom('S01-home');
    const s = await settings();
    rec.details.saved = { LLMProvider: s.LLMProvider, GenericOpenAiBasePath: s.GenericOpenAiBasePath, GenericOpenAiModelPref: s.GenericOpenAiModelPref, GenericOpenAiTokenLimit: s.GenericOpenAiTokenLimit };
    if (s.LLMProvider !== 'generic-openai' || s.GenericOpenAiBasePath !== LLM_BASE) throw new Error('LLM settings not persisted: ' + JSON.stringify(rec.details.saved));
  });

  await step('S02', 'Embedder: Generic OpenAI -> nomic-embed-text (llama-server --embedding)', async (rec) => {
    await page.goto(origin + '/settings/embedding-preference');
    await sleep(2500);
    await dismissPopups();
    rec.screenshots.push(await shot('embedder-page'));
    await page.getByText(/^(AnythingLLM|Actelyo RAG) Embedder$/).first().click();
    await sleep(800);
    const search = page.locator('input[name="embedder-search"], input[placeholder*="embedding provider" i]');
    if (await search.count()) await search.first().fill('Generic');
    await page.getByText('Generic OpenAI', { exact: true }).first().click();
    await page.locator('input[name="EmbeddingBasePath"]').fill(EMB_BASE);
    await page.locator('input[name="EmbeddingModelPref"]').fill(EMB_MODEL);
    const chunk = page.locator('input[name="EmbeddingModelMaxChunkLength"]');
    if (await chunk.count()) await chunk.fill('1000');
    const key = page.locator('input[name="GenericOpenAiEmbeddingApiKey"]');
    if (await key.count()) await key.fill('sk-local-qa');
    rec.screenshots.push(await shot('embedder-filled'));
    await page.getByRole('button', { name: /save/i }).first().click();
    await sleep(800);
    // Confirm the re-embed warning if it shows.
    await clickIfVisible(page.getByRole('button', { name: /confirm/i }), 1500);
    await sleep(2000);
    rec.screenshots.push(await shot('embedder-saved'));
    const s = await settings();
    rec.details.saved = { EmbeddingEngine: s.EmbeddingEngine, EmbeddingBasePath: s.EmbeddingBasePath, EmbeddingModelPref: s.EmbeddingModelPref, VectorDB: s.VectorDB };
    if (s.EmbeddingEngine !== 'generic-openai') throw new Error('embedder not persisted: ' + JSON.stringify(rec.details.saved));
  });

  let slug = null;
  await step('S03', 'Create workspace "QA Bail"', async (rec) => {
    const r = await ensureWorkspace('QA Bail');
    slug = r.slug; rec.details.slug = slug;
    rec.screenshots.push(r.shot, await shot('workspace-created'));
    const ws = (await api(`/api/workspace/${slug}`)).json?.workspace;
    if (!ws) throw new Error('workspace not found via API');
  });

  await step('S04', 'Upload bail-commercial-QX7429.txt and embed it', async (rec) => {
    if (!slug) throw new Error('no workspace');
    await uploadAndEmbed(rec, slug, [DOC], 'doc');
  });

  const Q = 'Quel est le montant du dépôt de garantie prévu par le bail commercial QX-7429 ?';
  async function ask(rec, label) {
    await page.goto(`${origin}/workspace/${slug}`);
    await sleep(2500);
    await dismissPopups();
    const health = {};
    for (const [k, u] of [['llm', LLM_BASE], ['emb', EMB_BASE]]) {
      try { health[k] = (await fetch(u.replace(/\/v1$/, '/health'), { signal: AbortSignal.timeout(5000) })).status; } catch (e) { health[k] = 'DOWN ' + e.message; }
    }
    const input = page.locator('#primary-prompt-input');
    await input.waitFor();
    await input.fill(Q);
    rec.screenshots.push(await shot(`chat-${label}-question`));
    await input.press('Enter');
    const t0 = Date.now();
    let last = null; let uiError = null;
    while (Date.now() - t0 < 300000) {
      await sleep(3000);
      const m = new URL(page.url()).pathname.match(/\/workspace\/[^/]+\/t\/([^/]+)/);
      const ep = m ? `/api/workspace/${slug}/thread/${m[1]}/chats` : `/api/workspace/${slug}/chats`;
      const h = (await api(ep)).json?.history || [];
      last = [...h].reverse().find((x) => x.role === 'assistant');
      if (last && (last.content || '').length) break;
      const body = await page.evaluate(() => document.body.innerText).catch(() => '');
      const e = body.match(/Could not respond to message\.?\s*\n?([^\n]*)/);
      if (e) { uiError = e[0].replace(/\s+/g, ' ').trim(); break; }
    }
    await sleep(2500);
    const out = { label, health, seconds: Math.round((Date.now() - t0) / 1000), url: page.url(), uiError };
    rec.screenshots.push(await shot(`chat-${label}-answer`));
    await dumpDom(`S05-${label}`);
    if (last) {
      out.answer = last.content;
      out.sources = (last.sources || []).map((x) => ({ title: x.title, score: x.score }));
      out.factFound = (last.content || '').replace(/[\s  .,]/g, '').includes('4817');
      const refBtn = page.getByText(/\d+\s+(references?|référence)/i).last();
      out.citationButtonVisible = await refBtn.isVisible().catch(() => false);
      if (out.citationButtonVisible) {
        await refBtn.click();
        await sleep(1500);
        rec.screenshots.push(await shot(`chat-${label}-citations`));
        out.citationShowsDoc = (await page.evaluate(() => document.body.innerText)).includes('bail-commercial-QX7429');
      }
    }
    return out;
  }
  await step('S05', 'Ask a question in chat; answer uses the fact and shows a citation', async (rec) => {
    if (!slug) throw new Error('no workspace');
    rec.details.question = Q;
    const ws = (await api(`/api/workspace/${slug}`)).json?.workspace;
    rec.details.defaultChatMode = ws?.chatMode;
    const first = await ask(rec, `mode-${ws?.chatMode || 'default'}`);
    rec.details.attempts = [first];
    const ok = (r) => r.factFound && r.sources?.length && r.citationButtonVisible;
    if (!ok(first)) {
      // Retry with the workspace in "Query" mode (RAG only, no agent routing), set through the UI.
      await page.goto(`${origin}/workspace/${slug}/settings/chat-settings`);
      await sleep(2500);
      rec.screenshots.push(await shot('chat-settings'));
      let via = 'ui';
      if (await clickIfVisible(page.getByRole('button', { name: /^query$/i }), 4000)) {
        await sleep(500);
        await clickIfVisible(page.getByRole('button', { name: /update workspace/i }), 4000);
        await sleep(2000);
      }
      if ((await api(`/api/workspace/${slug}`)).json?.workspace?.chatMode !== 'query') {
        via = 'api';
        await api(`/api/workspace/${slug}/update`, { method: 'POST', body: JSON.stringify({ chatMode: 'query' }) });
      }
      rec.screenshots.push(await shot('chat-settings-query'));
      const second = await ask(rec, 'mode-query');
      second.modeSetVia = via;
      rec.details.attempts.push(second);
      if (ok(second)) {
        rec.status = 'fail';
        rec.error = `Default chat mode "${ws?.chatMode}" failed (${first.uiError || 'no fact/citation'}); works only after switching the workspace to Query mode.`;
        return;
      }
    }
    const last = rec.details.attempts.at(-1);
    if (!ok(last)) throw new Error(`fact=${last.factFound} sources=${last.sources?.length} citationBtn=${last.citationButtonVisible} uiError=${last.uiError}`);
  });

  // ---- Legal import via native menu ----
  let manifest = null; let outDir = null;
  await step('S06', 'Menu "Préparer un corpus juridique…" (Import juridique local par article)', async (rec) => {
    const parent = path.join(OUT, 'legal-out');
    const r = spawnSync('python', [path.join(process.env.QA_HELPERS, 'native.py'),
      'legal-import', '--json', path.join(DATA, 'corpus-juridique.json'), '--outparent', parent, '--shots', SHOTS],
    { encoding: 'utf8', timeout: 240000 });
    fs.writeFileSync(path.join(OUT, 'native-legal.stderr.txt'), r.stderr || '');
    let res = {};
    try { res = JSON.parse((r.stdout || '').trim().split('\n').pop()); } catch { res = { ok: false, error: 'bad helper output', stdout: r.stdout }; }
    rec.screenshots.push(...(res.screens || []).filter(Boolean));
    rec.details = { menuMode: res.menuMode, resultDialog: res.resultDialog, dialogTexts: res.dialogTexts, outputs: res.outputs, error: res.error, trace: res.trace, menuTree: res.menuTree, windowTree: res.windowTree, log: res.log };
    rec.screenshots.push(await shot('legal-app-after'));
    manifest = res.manifest; outDir = res.outputDir;
    if (!res.ok) throw new Error(res.error || `legal import failed (dialog=${res.resultDialog})`);
    rec.details.counts = manifest.counts;
    if (manifest.counts.current !== 4 || manifest.counts.repealed !== 1) throw new Error('unexpected counts ' + JSON.stringify(manifest.counts));
  });

  let legalSlug = null;
  await step('S07', 'Import prepared current/ articles into workspace "QA Juridique"', async (rec) => {
    if (!manifest) throw new Error('no prepared corpus (S06 failed)');
    const r = await ensureWorkspace('QA Juridique');
    legalSlug = r.slug; rec.details.slug = legalSlug;
    rec.screenshots.push(r.shot);
    const files = manifest.articles.filter((a) => !a.is_repealed).map((a) => path.join(outDir, a.file));
    await uploadAndEmbed(rec, legalSlug, files, 'legal');
  });

  await step('S08', 'Recall@k / MRR evaluation (rag-eval.cjs bundled in runtime)', async (rec) => {
    if (!legalSlug) throw new Error('no legal workspace (S07 failed)');
    // API key through the UI (Settings > API Keys).
    let apiKey = null;
    await page.goto(origin + '/settings/api-keys');
    await sleep(2500);
    await dismissPopups();
    rec.screenshots.push(await shot('api-keys-page'));
    if (await clickIfVisible(page.getByRole('button', { name: /generate new api key/i }), 5000)) {
      await sleep(1000);
      const nameInput = page.locator('input[name="name"]');
      if (await nameInput.count()) await nameInput.fill('qa-rag-eval');
      await page.getByRole('button', { name: /create api key/i }).click();
      await sleep(2000);
      rec.screenshots.push(await shot('api-key-created'));
      apiKey = await page.locator('input[readonly], input[type="text"]').evaluateAll((els) =>
        els.map((e) => e.value).find((v) => v && v.length > 20) || null);
      await dismissPopups();
    }
    if (!apiKey) {
      rec.details.apiKeyVia = 'REST fallback';
      apiKey = (await api('/api/system/generate-api-key', { method: 'POST', body: '{}' })).json?.apiKey?.secret;
    } else rec.details.apiKeyVia = 'UI';
    if (!apiKey) throw new Error('could not obtain an API key');
    const benchmark = { schemaVersion: 1, cases: JSON.parse(fs.readFileSync(path.join(DATA, 'benchmark-queries.json'), 'utf8')).map((c) => ({
      id: c.id, language: c.language, query: c.query,
      relevant: [path.basename(manifest.articles.find((a) => a.id === c.article).file)] })) };
    const evalDir = path.join(OUT, 'rag-eval');
    fs.mkdirSync(evalDir, { recursive: true });
    const bench = path.join(evalDir, 'benchmark.json');
    fs.writeFileSync(bench, JSON.stringify(benchmark, null, 2));
    const node = path.join(RUNTIME, 'node.exe');
    const env = { ...process.env, ACTELYO_RAG_API_KEY: apiKey };
    // 1. Documented command, exactly as RAG_EVALUATION.md describes for the packaged Desktop.
    const cli = spawnSync(node, [path.join(RUNTIME, 'server/scripts/rag-eval.cjs'), '--benchmark', bench, '--workspace', legalSlug,
      '--base-url', origin, '--source-field', 'title', '--output', path.join(evalDir, 'rag-eval.json'), '--prometheus', path.join(evalDir, 'rag-eval.prom')],
    { encoding: 'utf8', env, timeout: 300000 });
    rec.details.documentedCli = { exit: cli.status, stdout: (cli.stdout || '').trim(), stderr: (cli.stderr || '').trim().slice(0, 800) };
    const direct = await fetch(`${origin}/v1/workspace/${legalSlug}/vector-search`, { method: 'POST', headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: 'bail', topN: 5 }) });
    rec.details.probeNoApiPrefix = { status: direct.status, contentType: direct.headers.get('content-type') };
    const real = await fetch(`${origin}/api/v1/workspace/${legalSlug}/vector-search`, { method: 'POST', headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: 'bail', topN: 5 }) });
    rec.details.probeWithApiPrefix = { status: real.status, contentType: real.headers.get('content-type') };
    // 2. Same evaluator (evaluate() from the installed script) against the developer API under /api.
    const harness = path.join(evalDir, 'eval-harness.cjs');
    fs.writeFileSync(harness, `const { evaluate } = require(${JSON.stringify(path.join(RUNTIME, 'server/scripts/rag-eval.cjs'))});
const { prometheus } = require(${JSON.stringify(path.join(RUNTIME, 'server/utils/ragEvaluation.cjs'))});
const fs = require('fs');
const cfg = { benchmark: process.argv[2], workspace: process.argv[3], baseUrl: process.argv[4], sourceField: 'title', topN: 5, threshold: 0 };
const req = (url, init) => fetch(url.replace(cfg.baseUrl + '/v1/', cfg.baseUrl + '/api/v1/'), init);
evaluate(cfg, process.env.ACTELYO_RAG_API_KEY, req).then((r) => { fs.writeFileSync(process.argv[5], JSON.stringify(r, null, 2)); fs.writeFileSync(process.argv[5] + '.prom', prometheus(r)); console.log(JSON.stringify(r.overall)); })
  .catch((e) => { console.error(e.message); process.exitCode = 1; });
`);
    const h = spawnSync(node, [harness, bench, legalSlug, origin, path.join(evalDir, 'rag-eval-api-prefix.json')], { encoding: 'utf8', env, timeout: 300000 });
    rec.details.evaluatorViaApiPrefix = { exit: h.status, stdout: (h.stdout || '').trim().slice(0, 1500), stderr: (h.stderr || '').trim().slice(0, 800) };
    try { rec.details.metrics = JSON.parse(h.stdout.trim()); } catch {}
    try {
      const full = JSON.parse(fs.readFileSync(path.join(evalDir, 'rag-eval-api-prefix.json'), 'utf8'));
      rec.details.perCase = full.cases.map((c) => ({ id: c.id, expected: c.expected, retrieved: c.retrieved, rr: c.metrics.reciprocalRank }));
    } catch {}
    // Show the result in the app window for the screenshot.
    await page.goto(`${origin}/workspace/${legalSlug}`);
    await sleep(2000);
    await page.evaluate((txt) => {
      const pre = document.createElement('pre');
      pre.id = 'qa-overlay';
      pre.style.cssText = 'position:fixed;right:12px;bottom:12px;z-index:99999;max-width:46%;max-height:70%;overflow:auto;background:#111c;color:#7fffd4;padding:12px;font:12px monospace;border:1px solid #7fffd4;white-space:pre-wrap';
      pre.textContent = txt;
      document.body.appendChild(pre);
    }, `QA overlay (not app UI) - rag-eval results\n\nDocumented CLI (--base-url ${origin}):\nexit=${cli.status}\n${(cli.stdout || '') + (cli.stderr || '')}\n\nPOST /v1/... -> ${direct.status} ${direct.headers.get('content-type')}\nPOST /api/v1/... -> ${real.status} ${real.headers.get('content-type')}\n\nevaluate() via /api/v1 prefix:\n${h.stdout || h.stderr}`);
    rec.screenshots.push(await shot('rag-eval-results'));
    await page.evaluate(() => document.getElementById('qa-overlay')?.remove());
    const m = rec.details.metrics;
    if (!m) throw new Error('evaluator produced no metrics');
    if (cli.status !== 0) {
      rec.status = 'fail';
      rec.error = `Documented rag-eval CLI fails against the packaged Desktop: ${rec.details.documentedCli.stderr || rec.details.documentedCli.stdout}. Metrics only obtainable through /api/v1 (Recall@5=${m['recall@5']}, MRR=${m.mrr}).`;
    }
  });

  await step('S09', 'Final state screenshot', async (rec) => {
    await page.goto(`${origin}/workspace/${slug || ''}`);
    await sleep(2000);
    rec.screenshots.push(await shot('final'));
  });
  report.finishedAt = new Date().toISOString();
  save();
  await browser?.close().catch(() => {});
}

main().catch((e) => { report.fatal = String(e?.stack || e); save(); console.error(e); }).finally(() => {
  const summary = report.steps.map((s) => `${s.id} ${s.status.toUpperCase().padEnd(5)} ${s.title}`).join('\n');
  console.log('\n' + summary);
  fs.writeFileSync(path.join(OUT, 'summary.txt'), summary + '\n');
  process.exit(0);
});
