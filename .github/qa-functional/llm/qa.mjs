// Functional QA of Actelyo LLM Studio, driven through its real UI over CDP (Playwright connectOverCDP).
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = process.env.QA_OUT;
const EXE = process.env.APP_EXE;
const MODEL = process.env.MODEL_FILE;
const HF_REPO = 'Qwen/Qwen3-0.6B-GGUF';
const HF_FILE = 'Qwen3-0.6B-Q8_0.gguf';
fs.mkdirSync(OUT, { recursive: true });

const report = { started: new Date().toISOString(), exe: EXE, model: MODEL, facts: {}, steps: [] };
const writeReport = () => fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2));
const sleep = ms => new Promise(r => setTimeout(r, ms));
let page, browser, child, shotIndex = 0;

function run(cmd, args, timeoutMs = 120000) {
  return new Promise(resolve => {
    const p = spawn(cmd, args, { windowsHide: true });
    let out = '';
    p.stdout.on('data', d => out += d); p.stderr.on('data', d => out += d);
    const timer = setTimeout(() => { p.kill(); out += '\n[timeout]'; }, timeoutMs);
    p.on('close', code => { clearTimeout(timer); resolve({ code, out }); });
  });
}
const pwsh = (script, ...args) => run('pwsh', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(HERE, script), ...args]);

async function shot(name, s) {
  const base = String(++shotIndex).padStart(2, '0') + '-' + name;
  try { await page?.screenshot({ path: path.join(OUT, base + '-app.png'), timeout: 15000 }); s?.shots.push(base + '-app.png'); } catch (e) { console.log('page shot failed', e.message); }
  await pwsh('shot.ps1', '-Path', path.join(OUT, base + '-desktop.png')); s?.shots.push(base + '-desktop.png');
}
async function uiError() { try { return await page.evaluate(() => { const e = document.querySelector('#error'); return e && !e.hidden ? e.textContent : null; }); } catch { return null; } }
async function clearNotice() { await page.evaluate(() => { for (const id of ['#error', '#notice']) { const e = document.querySelector(id); e.hidden = true; e.textContent = ''; } }); }
const status = () => page.evaluate(() => window.actelyoLLM.status());
async function nav(view) { await page.click(`aside button[data-view="${view}"]`); await page.waitForSelector(`#${view}-view:not([hidden])`, { timeout: 10000 }); }

async function step(id, title, fn, { required = true } = {}) {
  const s = { id, title, required, ok: false, detail: '', shots: [] };
  report.steps.push(s);
  const t0 = Date.now();
  console.log(`\n=== ${id} ${title}`);
  try { await clearNotice(); } catch {}
  try { const r = await fn(s); s.ok = true; if (r !== undefined) s.detail = typeof r === 'string' ? r : JSON.stringify(r); }
  catch (e) { s.ok = false; s.detail = String(e?.message || e).slice(0, 3000); }
  s.uiError = await uiError();
  s.seconds = Math.round((Date.now() - t0) / 100) / 10;
  await shot(id + (s.ok ? '' : '-FAIL'), s);
  console.log(`[${s.ok ? 'PASS' : 'FAIL'}] ${id} (${s.seconds}s) ${s.detail.slice(0, 600)}${s.uiError ? ' | UI error: ' + s.uiError : ''}`);
  writeReport();
  return s.ok;
}

// Waits for the chat turn to finish; returns the last assistant text or throws with the UI error.
async function sendPrompt(text, timeout = 300000) {
  await page.click('#new-chat');
  await page.waitForFunction(() => document.querySelector('#chat-title').textContent === 'Nouvelle conversation');
  await page.waitForSelector('#send:not([disabled])', { timeout: 15000 });
  await page.fill('#prompt', text);
  await page.press('#prompt', 'Enter');
  await page.waitForSelector('#stop:not([hidden])', { timeout: 10000 }).catch(() => {});
  const handle = await page.waitForFunction(() => {
    const e = document.querySelector('#error');
    if (!e.hidden && e.textContent) return { error: e.textContent };
    if (!document.querySelector('#stop').hidden) return false;
    const a = [...document.querySelectorAll('#messages .message.assistant .message-text')];
    return a.length && a.at(-1).textContent.trim() ? { text: a.at(-1).textContent, info: document.querySelector('#generation-info').textContent } : false;
  }, null, { timeout, polling: 500 });
  const r = await handle.jsonValue();
  if (r.error) throw Error('UI error: ' + r.error);
  const conv = await page.evaluate(() => conversation);
  const hist = await page.evaluate(id => window.actelyoLLM.history(id), conv);
  return { ...r, conversation: conv, persisted: hist.map(m => ({ role: m.role, chars: m.content.length })) };
}

async function main() {
  // ---------- launch ----------
  const log = fs.openSync(path.join(OUT, 'app-stdout.log'), 'a');
  child = spawn(EXE, ['--remote-debugging-port=9222', '--enable-logging'], { cwd: path.dirname(EXE), stdio: ['ignore', log, log], env: { ...process.env, ELECTRON_ENABLE_LOGGING: '1' } });
  child.on('exit', code => { report.facts.appExit = code; });
  const ok = await step('00-launch', 'Launch app with CDP and reach the Conversations view', async () => {
    let version;
    for (let i = 0; i < 120 && !version; i++) { try { version = await (await fetch('http://127.0.0.1:9222/json/version')).json(); } catch { await sleep(500); } }
    if (!version) throw Error('CDP endpoint never came up (fuses or launch failure)');
    report.facts.cdp = version;
    browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
    for (let i = 0; i < 120 && !page; i++) {
      page = browser.contexts().flatMap(c => c.pages()).find(p => p.url().startsWith('actelyollm://'));
      if (!page) await sleep(500);
    }
    if (!page) throw Error('no actelyollm:// page');
    page.on('console', m => fs.appendFileSync(path.join(OUT, 'renderer-console.log'), `[${m.type()}] ${m.text()}\n`));
    page.on('pageerror', e => fs.appendFileSync(path.join(OUT, 'renderer-console.log'), `[pageerror] ${e.stack || e}\n`));
    await page.waitForFunction(() => document.querySelector('#page-title')?.textContent === 'Conversations', null, { timeout: 30000 });
    await page.waitForFunction(() => !!window.actelyoLLM, null, { timeout: 10000 });
    await sleep(1500);
    console.log((await pwsh('shot.ps1', '-Maximize')).out);
    await sleep(1000);
    const st = await status();
    report.facts.initialStatus = { version: st.version, dataDirectory: st.dataDirectory, baseUrl: st.baseUrl, runtime: st.runtime, runtimes: st.runtimes, models: st.models.length };
    return { title: await page.title(), url: page.url(), version: st.version, dataDirectory: st.dataDirectory, baseUrl: st.baseUrl };
  });
  if (!ok) return;
  const dataDir = report.facts.initialStatus.dataDirectory;

  // ---------- 1. library ----------
  await step('01a-import-gguf-dialog', 'Ma bibliothèque > Importer un GGUF (native Open dialog driven via Win32 messages)', async s => {
    await nav('models');
    await page.click('#import');
    const r = await pwsh('file-dialog.ps1', '-File', MODEL, '-Shot', path.join(OUT, String(++shotIndex).padStart(2, '0') + '-01a-open-dialog-desktop.png'));
    s.shots.push(String(shotIndex).padStart(2, '0') + '-01a-open-dialog-desktop.png');
    console.log(r.out);
    if (r.code !== 0) throw Error('file dialog automation failed: ' + r.out);
    const row = page.locator('.model-row').filter({ hasText: MODEL });
    await row.first().waitFor({ timeout: 30000 });
    return { dialog: r.out.trim(), row: (await row.first().innerText()).replace(/\s+/g, ' ') };
  });

  await step('01b-discover-hf-download', 'Découvrir des modèles > search Hugging Face, download Qwen3-0.6B-Q8_0.gguf', async s => {
    await nav('discover');
    await page.waitForSelector('#search-button:not([disabled])', { timeout: 60000 });
    await page.fill('#search-query', HF_REPO);
    await page.click('#search-button');
    const card = page.locator('#hub-results .hub-card').filter({ hasText: HF_REPO });
    await card.first().waitFor({ timeout: 60000 });
    await card.first().click();
    const fileRow = page.locator('#hub-detail .file-row').filter({ hasText: HF_FILE });
    await fileRow.first().waitFor({ timeout: 60000 });
    await shot('01b-hub-detail', s);
    await fileRow.first().getByRole('button', { name: /Télécharger/ }).click();
    await page.waitForSelector('#transfers-view:not([hidden])', { timeout: 60000 });
    const t0 = Date.now(); let midShot = false, last;
    while (Date.now() - t0 < 20 * 60000) {
      const jobs = (await status()).downloads.filter(j => j.file === HF_FILE);
      last = jobs.at(-1);
      if (last?.state === 'completed') break;
      if (last?.state === 'failed') throw Error('download failed: ' + last.error);
      if (!midShot && last?.received > 50e6) { await shot('01b-downloading', s); midShot = true; }
      await sleep(2000);
    }
    if (last?.state !== 'completed') throw Error('download not completed in 20 min: ' + JSON.stringify(last));
    await page.waitForFunction(f => [...document.querySelectorAll('.transfer-card')].some(c => c.textContent.includes(f) && c.textContent.includes('Terminé')), HF_FILE, { timeout: 15000 });
    await shot('01b-transfer-done', s);
    await nav('models');
    const st = await status();
    const m = st.models.find(m => m.path === last.path);
    if (!m) throw Error('downloaded file not added to the library: ' + last.path);
    return { path: last.path, size: last.size, sha256Expected: last.sha256, matchesCatalog: last.sha256 === process.env.MODEL_SHA256, seconds: (Date.now() - t0) / 1000, libraryId: m.id };
  });

  await step('01c-scan-models-folder', 'Ma bibliothèque > Détecter les modèles (GGUF dropped in the library folder)', async () => {
    const target = path.join(dataDir, 'models', 'qa-scan', HF_FILE);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(MODEL, target);
    await nav('models');
    await page.click('#scan');
    await page.waitForFunction(() => /GGUF détecté/.test(document.querySelector('#notice').textContent), null, { timeout: 60000 });
    const noticeText = await page.textContent('#notice');
    const row = page.locator('.model-row').filter({ hasText: 'qa-scan' });
    await row.first().waitFor({ timeout: 15000 });
    return { notice: noticeText, folder: path.dirname(target), libraryCount: await page.textContent('#model-count') };
  });

  // ---------- 2. load + chat ----------
  let loadedId = null;
  await step('02a-load-model', 'Ma bibliothèque > Charger Qwen3-0.6B-Q8_0 (bundled llama.cpp engine)', async () => {
    await nav('models');
    const st = await status();
    const pick = st.models.find(m => m.path === MODEL) || st.models.find(m => /qa-scan/.test(m.path)) || st.models.find(m => /Qwen3-0\.6B/i.test(m.name));
    if (!pick) throw Error('no Qwen model in library');
    const row = page.locator('.model-row').filter({ hasText: pick.path }).first();
    await row.getByRole('button', { name: 'Charger', exact: true }).click();
    await page.waitForFunction(async id => {
      const e = document.querySelector('#error'); if (!e.hidden && e.textContent) return true;
      const st = await window.actelyoLLM.status(); return st.models.some(m => m.id === id && m.loaded);
    }, pick.id, { timeout: 240000, polling: 1000 });
    const err = await uiError(); if (err) throw Error('UI error: ' + err);
    await page.waitForFunction(p => [...document.querySelectorAll('.model-row')].some(r => r.textContent.includes(p) && /Décharger/.test(r.textContent)), pick.path, { timeout: 10000 });
    loadedId = pick.id;
    const after = await status();
    return { id: pick.id, runtime: after.runtime, badge: await page.textContent('#model-badge'), active: after.activeRequests };
  });

  await step('02b-chat-default', 'Nouvelle conversation > prompt with default settings (Qwen3 thinking left on)', async () => {
    await nav('chat');
    const r = await sendPrompt('Quelle est la capitale de la France ? Réponds en une phrase.');
    return r;
  }, { required: false });

  await step('02c-chat-no-think', 'Nouvelle conversation > prompt with Qwen3 thinking disabled (/no_think)', async () => {
    await nav('chat');
    const r = await sendPrompt('Donne trois couleurs primaires, séparées par des virgules. /no_think');
    if (!r.persisted.some(m => m.role === 'assistant')) throw Error('assistant message not persisted');
    const sidebar = await page.locator('#conversation-list button').allInnerTexts();
    return { ...r, sidebar: sidebar.slice(0, 5) };
  });

  // ---------- 3. server + API ----------
  let base;
  await step('03a-server-view', 'Serveur et API view shows the local endpoint', async s => {
    await nav('connections');
    const url = (await page.textContent('#base-url')).trim();
    if (!/^http:\/\/127\.0\.0\.1:\d+\/v1$/.test(url)) throw Error('unexpected base url ' + url);
    base = url.replace(/\/v1$/, '');
    await shot('03a-server-address', s);
    await page.locator('#api-example').scrollIntoViewIfNeeded();
    return { baseUrl: url, example: await page.textContent('#api-example') };
  });

  await step('03b-api-health-models-chat', 'OpenAI-compatible API: /health, /v1/models, /v1/chat/completions (plain + stream)', async () => {
    const health = await (await fetch(base + '/health')).json();
    if (health.status !== 'ok') throw Error('health ' + JSON.stringify(health));
    const models = await (await fetch(base + '/v1/models')).json();
    const loaded = models.data.find(m => m.state === 'loaded');
    if (!loaded) throw Error('no loaded model in /v1/models');
    const body = { model: loaded.id, messages: [{ role: 'user', content: 'Réponds uniquement par le mot OK. /no_think' }], max_tokens: 128, temperature: 0 };
    const r1 = await fetch(base + '/v1/chat/completions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const plain = await r1.json();
    fs.writeFileSync(path.join(OUT, 'api-chat-completion.json'), JSON.stringify(plain, null, 2));
    const text = plain.choices?.[0]?.message?.content;
    if (r1.status !== 200 || !text?.trim()) throw Error('chat completion HTTP ' + r1.status + ' ' + JSON.stringify(plain).slice(0, 500));
    const r2 = await fetch(base + '/v1/chat/completions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body, stream: true }) });
    const sse = await r2.text();
    fs.writeFileSync(path.join(OUT, 'api-chat-stream.txt'), sse);
    const streamed = sse.split('\n').filter(l => l.startsWith('data:') && !l.includes('[DONE]')).map(l => { try { return JSON.parse(l.slice(5)).choices?.[0]?.delta?.content || ''; } catch { return ''; } }).join('');
    if (!streamed.trim()) throw Error('stream returned no content');
    fs.writeFileSync(path.join(OUT, 'api-health-models.json'), JSON.stringify({ health, models }, null, 2));
    return { health, loadedModel: loaded.id, reply: text, streamed, usage: plain.usage, streamDone: sse.includes('[DONE]') };
  });

  await step('03c-api-origin-guard', 'API rejects a foreign browser Origin (403) and answers an allowed one', async () => {
    const bad = await fetch(base + '/v1/models', { headers: { Origin: 'https://evil.example' } });
    const good = await fetch(base + '/v1/models', { headers: { Origin: 'https://app.actelyo.fr' } });
    if (bad.status !== 403) throw Error('foreign origin got HTTP ' + bad.status);
    if (good.status !== 200 || good.headers.get('access-control-allow-origin') !== 'https://app.actelyo.fr') throw Error('allowed origin got ' + good.status);
    return { foreign: bad.status, allowed: good.status };
  }, { required: false });

  // ---------- 4. agent + hardware ----------
  await step('04a-agent-projects', 'Agent · Projets view opens', async () => {
    await nav('agent');
    await sleep(1500);
    const text = (await page.innerText('#agent-view')).replace(/\s+/g, ' ');
    if (text.length < 20) throw Error('agent view looks empty');
    return { title: await page.textContent('#page-title'), excerpt: text.slice(0, 400) };
  });

  await step('04b-hardware-engines', 'Matériel et moteurs view opens and lists hardware + engines', async () => {
    await nav('hardware');
    await page.waitForFunction(() => document.querySelector('#hardware-summary').textContent.trim().length > 10 && document.querySelector('#runtime-list').textContent.trim().length > 5, null, { timeout: 30000 });
    return { title: await page.textContent('#page-title'), hardware: (await page.innerText('#hardware-summary')).replace(/\s+/g, ' ').slice(0, 400), runtimes: (await page.innerText('#runtime-list')).replace(/\s+/g, ' ').slice(0, 600) };
  });

  await step('04c-hardware-benchmark', 'Matériel et moteurs > "Charger et tester le moteur sélectionné" (real test on this PC)', async () => {
    await nav('hardware');
    if (loadedId) await page.selectOption('#benchmark-model', loadedId).catch(() => {});
    await page.click('#run-benchmark');
    await page.waitForSelector('#run-benchmark[disabled]', { timeout: 5000 }).catch(() => {});
    await page.waitForSelector('#run-benchmark:not([disabled])', { timeout: 300000 });
    await sleep(500);
    const err = await uiError(); const result = await page.textContent('#benchmark-result');
    if (err) throw Error('UI error: ' + err + ' | result panel still shows: ' + result.slice(0, 200));
    return { result: result.slice(0, 800) };
  }, { required: false });

  await step('04d-benchmark-repro-api', 'Repro of 04c through the API: same prompt and max_tokens=64 as the benchmark', async () => {
    const models = await (await fetch(base + '/v1/models')).json();
    const loaded = models.data.find(m => m.state === 'loaded');
    const r = await fetch(base + '/v1/chat/completions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ model: loaded.id, messages: [{ role: 'system', content: 'Vous êtes un assistant utile. Répondez dans la langue de l’utilisateur.' }, { role: 'user', content: 'Réponds en une phrase : pourquoi le ciel est-il bleu ?' }], max_tokens: 64 }) });
    const data = await r.json();
    fs.writeFileSync(path.join(OUT, 'api-benchmark-repro.json'), JSON.stringify(data, null, 2));
    const msg = data.choices?.[0]?.message || {};
    return { http: r.status, finish_reason: data.choices?.[0]?.finish_reason, contentChars: (msg.content || '').length, reasoningChars: (msg.reasoning_content || '').length, completion_tokens: data.usage?.completion_tokens, reasoningStart: (msg.reasoning_content || '').slice(0, 160) };
  }, { required: false });

  // ---------- 5. logs + clean exit ----------
  await step('05-logs-and-exit', 'Collect engine logs, close the window, check the engine processes stop', async () => {
    const st = await status();
    fs.writeFileSync(path.join(OUT, 'final-status.json'), JSON.stringify(st, null, 2));
    await nav('settings');
    await page.evaluate(() => document.querySelector('#settings-view details:last-of-type')?.setAttribute('open', ''));
    fs.writeFileSync(path.join(OUT, 'engine-logs.txt'), await page.textContent('#engine-logs'));
    await shot('05-engine-log', report.steps.at(-1));
    page.evaluate(() => window.close()).catch(() => {});
    const t0 = Date.now();
    while (child.exitCode === null && Date.now() - t0 < 30000) await sleep(500);
    const exited = child.exitCode !== null;
    await sleep(2000);
    const tl = await run('tasklist', ['/FI', 'IMAGENAME eq llama-server.exe', '/FO', 'CSV', '/NH']);
    const orphan = /llama-server/i.test(tl.out);
    page = null;
    if (!exited) throw Error('app did not exit within 30s after closing its window');
    if (orphan) throw Error('llama-server.exe still running after app exit: ' + tl.out);
    return { exitCode: child.exitCode, closeSeconds: (Date.now() - t0) / 1000 };
  }, { required: false });
}

try { await main(); }
catch (e) { report.fatal = String(e?.stack || e); console.error(e); }
finally {
  try { await browser?.close(); } catch {}
  if (child && child.exitCode === null) { try { await run('taskkill', ['/F', '/T', '/PID', String(child.pid)]); } catch {} }
  // copy app data files useful for diagnosis (no secrets: only json/log files)
  try {
    const dataDir = report.facts.initialStatus?.dataDirectory;
    for (const f of ['models/downloads.json']) if (dataDir && fs.existsSync(path.join(dataDir, f))) fs.copyFileSync(path.join(dataDir, f), path.join(OUT, 'appdata-' + path.basename(f)));
  } catch {}
  report.finished = new Date().toISOString();
  report.passed = report.steps.length > 0 && !report.fatal && report.steps.every(s => s.ok || !s.required);
  writeReport();
  const lines = ['| step | result | seconds | detail |', '|---|---|---|---|', ...report.steps.map(s => `| ${s.id} ${s.title} | ${s.ok ? 'PASS' : s.required ? 'FAIL' : 'FAIL (non-blocking)'} | ${s.seconds} | ${(s.detail + (s.uiError ? ' UI error: ' + s.uiError : '')).replace(/\|/g, '/').replace(/\n/g, ' ').slice(0, 300)} |`)];
  fs.writeFileSync(path.join(OUT, 'summary.md'), `## Actelyo LLM Studio functional QA: ${report.passed ? 'PASSED' : 'FAILED'}\n\n${lines.join('\n')}\n`);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, fs.readFileSync(path.join(OUT, 'summary.md')));
  console.log(fs.readFileSync(path.join(OUT, 'summary.md'), 'utf8'));
  process.exit(report.passed ? 0 : 1);
}
