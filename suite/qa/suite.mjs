import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const require = createRequire(new URL('./runtime/package.json', import.meta.url));
const { _electron } = require('playwright-core');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
const out = path.resolve(input.reportDirectory);
const applications = new Map(input.applications.map(a => [a.id, a]));
const active = new Map();
const completed = new Map();
const profiles = path.join(out, 'profiles');
fs.mkdirSync(profiles, { recursive: true });
const report = { schemaVersion: 1, startedAt: new Date().toISOString(), status: 'running',
  scope: 'Real installed applications, shared LLM Studio server, embeddings, ERP retrieval, secondary RAG, source transfer to Law Harness, RAG Desktop and OpenBousic protocol interoperability. Synthetic data only; not legal accuracy, browser control or exhaustive per-app feature certification.',
  catalogRevision: input.catalog.revision, applications: input.applications, steps: [] };
const erpProbe=process.argv.includes('--erp-probe');
const erpChecks=new Set(['llm-launch','llm-models','llm-chat-and-embeddings','erp-launch','erp-shared-model-and-retrieval']);
if(erpProbe){report.diagnosticOnly=true;report.scope='Focused ERP to real LLM Studio diagnostic; does not certify the complete suite.';}
const save = () => fs.writeFileSync(path.join(out, 'qa.json'), JSON.stringify(report, null, 2));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const localAppData = process.env.LOCALAPPDATA;
const clean = { ...process.env };
for (const key of Object.keys(clean)) {
  if (/TOKEN|SECRET|PASSWORD|API.?KEY|^OPENAI_|^ANTHROPIC_|^GROQ_|^GH_|^GITHUB_|^HERMES_|^ACTELYO_|^LITELLM_|^VITE_DEV_SERVER_URL$|^STORAGE_DIR$|^DATABASE_URL$|^LLM_PROVIDER$|^EMBEDDING_|^GENERIC_OPEN_AI_|^VECTOR_DB$|^SERVER_PORT$|^COLLECTOR_PORT$|^ELECTRON_RUN_AS_NODE$|^NODE_OPTIONS$|^NODE_PATH$|^SSLKEYLOGFILE$/i.test(key)) delete clean[key];
}
let studio, chatId, embeddingId, document, retrieved;
const marker = 'ACTELYO-SUITE-' + randomUUID();
const fixture = path.join(out, 'piece-qa.txt');
fs.writeFileSync(fixture, `Pièce synthétique ${marker}. Le 03/11/2026, le dossier ${marker} indique un montant de 7429 euros.\n`);

async function step(id, dependencies, fn) {
  if(erpProbe && !erpChecks.has(id))return;
  const item = { id, status: 'running', startedAt: new Date().toISOString() };
  report.steps.push(item); save();
  if (dependencies.some(d => completed.get(d) !== 'pass')) {
    item.status = 'blocked'; item.error = 'Prerequisite failed: ' + dependencies.filter(d => completed.get(d) !== 'pass').join(', ');
  } else {
    try { item.detail = await fn(); item.status = 'pass'; }
    catch (e) { item.status = 'fail'; item.error = String(e.stack || e).slice(0, 5000); }
  }
  item.finishedAt = new Date().toISOString(); completed.set(id, item.status); save();
  console.log(`${item.status.toUpperCase()} ${id}${item.error ? ': ' + item.error.split('\n')[0] : ''}`);
}
async function freePort() {
  return new Promise((resolve, reject) => { const s = net.createServer(); s.once('error', reject); s.listen(0, '127.0.0.1', () => { const port = s.address().port; s.close(() => resolve(port)); }); });
}
async function json(url, body, headers = {}, timeout = 180000) {
  const u = new URL(url);
  assert(['127.0.0.1','localhost','[::1]'].includes(u.hostname), 'QA endpoints must be local');
  const response = await fetch(u, { method: body === undefined ? 'GET' : 'POST', headers: { 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeout) });
  const text = await response.text();
  assert(response.ok, `HTTP ${response.status} ${u.pathname}: ${text.slice(0, 500)}`);
  return JSON.parse(text);
}
async function launch(id, extraEnv = {}, extraArgs = []) {
  const definition = applications.get(id); assert(definition?.executable, `Installed executable missing: ${id}`);
  const root = path.join(profiles, id); const data = path.join(root, 'desktop');
  const env = { ...clean, APPDATA: path.join(root, 'Roaming'), LOCALAPPDATA: path.join(root, 'Local'), USERPROFILE: path.join(root, 'Home'), HOME: path.join(root, 'Home'), ...extraEnv };
  for (const dir of [data, env.APPDATA, env.LOCALAPPDATA, env.USERPROFILE]) fs.mkdirSync(dir, { recursive: true });
  const app = await _electron.launch({ executablePath: definition.executable, cwd: definition.directory,
    args: ['--user-data-dir=' + data, '--disable-renderer-backgrounding', ...extraArgs], env, timeout: 180000 });
  active.set(id, { app, root, data });
  const log = fs.createWriteStream(path.join(out, id + '-runtime.log'));
  for (const stream of [app.process().stdout, app.process().stderr]) stream?.pipe(log, { end: false });
  const page = await app.firstWindow({ timeout: 180000 });
  await page.waitForLoadState('domcontentloaded');
  const identity = await app.evaluate(({ app }) => ({ name: app.getName(), version: app.getVersion(), userData: app.getPath('userData') }));
  const relative = path.relative(root, identity.userData);
  assert(relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative), `Profile isolation unsupported by ${id}; no QA data will be imported into its normal profile`);
  active.set(id, { app, page, root, data, log, identity });
  await page.screenshot({ path: path.join(out, id + '-launch.png') });
  return { identity, executable: definition.executable };
}
async function chooseFiles(id, files, fn) {
  const { app } = active.get(id);
  await app.evaluate(({ dialog }, files) => { globalThis.__suiteDialog = dialog.showOpenDialog; dialog.showOpenDialog = async () => ({ canceled: false, filePaths: files }); }, files);
  try { return await fn(); }
  finally { await app.evaluate(({ dialog }) => { dialog.showOpenDialog = globalThis.__suiteDialog; delete globalThis.__suiteDialog; }); }
}
function command(exe, args, cwd, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(exe, args, { cwd, env, windowsHide: true, stdio: ['ignore','pipe','pipe'] });
    let stdout = '', stderr = '';
    const timer = setTimeout(() => { child.kill(); reject(Error('Installed command timed out')); }, 180000);
    child.stdout.on('data', b => { stdout += b; if (stdout.length > 4e6) { child.kill(); } });
    child.stderr.on('data', b => { stderr = (stderr + b).slice(-16000); });
    child.once('error', e => { clearTimeout(timer); reject(e); });
    child.once('close', code => { clearTimeout(timer); code === 0 ? resolve(stdout) : reject(Error(`Installed command exited ${code}: ${stderr}`)); });
  });
}
try {
  await step('llm-launch', [], () => launch('llm', { ACTELYO_LLM_DATA: path.join(profiles, 'llm', 'desktop'), ACTELYO_LLM_PORT: '0' }));
  await step('llm-models', ['llm-launch'], async () => {
    const modelItems = ['qwen-small','nomic-embeddings'].map(id => input.catalog.items.find(i => i.id === id));
    const files = [];
    for (const item of modelItems) {
      const file = path.join(input.modelsDirectory, item.file); assert(fs.existsSync(file), `Test model missing: ${item.file}`);
      const hash = createHash('sha256');
      for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
      assert.equal(hash.digest('hex'), item.sha256); files.push(file);
    }
    const { page } = active.get('llm');
    await page.waitForFunction(() => !!window.actelyoLLM?.status);
    await chooseFiles('llm', files, () => page.evaluate(() => window.actelyoLLM.import()));
    let status = await page.evaluate(() => window.actelyoLLM.status());
    chatId = status.models.find(m => m.kind === 'llm')?.id;
    embeddingId = status.models.find(m => m.kind === 'embedding')?.id;
    assert(chatId && embeddingId, 'Both model types must be imported');
    const loads=[{id:chatId,options:{context:8192,threads:2,backend:'cpu'}},
      {id:embeddingId,options:{context:2048,threads:2,backend:'cpu',batch:2048,microBatch:2048}}];
    // Non-causal document embeddings require each input to fit in the physical batch.
    // The default microBatch=64 can answer tiny probes but fails on real document chunks.
    for (const load of loads) await page.evaluate(({id,options}) => window.actelyoLLM.load(id, options), load);
    status = await page.evaluate(() => window.actelyoLLM.status()); studio = status.baseUrl;
    assert(status.models.filter(m => m.loaded).length >= 2, 'Both actual model processes must be ready');
    return { baseUrl: studio, chatModel: chatId, embeddingModel: embeddingId,loadSettings:loads, modelHashes: modelItems.map(m => ({ id:m.id, sha256:m.sha256 })) };
  });
  await step('llm-chat-and-embeddings', ['llm-models'], async () => {
    const response = await json(studio + '/chat/completions', { model: chatId, messages: [{role:'user',content:'Say hello in one word. /no_think'}], max_tokens:128, stream:false, chat_template_kwargs:{enable_thinking:false} });
    assert(response.choices?.[0]?.message?.content?.trim(), 'Empty model response');
    const embeddings = await json(studio + '/embeddings', { model:embeddingId, input:['search_query: '+marker] });
    const vector = embeddings.data?.[0]?.embedding;
    assert(Array.isArray(vector) && vector.length > 0 && vector.every(Number.isFinite), 'No valid embeddings');
    return { reply: response.choices[0].message.content, dimensions:vector.length, model:response.model };
  });
  await step('erp-launch', [], () => launch('erp', { LOCALAPPDATA:localAppData }));
  await step('erp-shared-model-and-retrieval', ['erp-launch','llm-chat-and-embeddings'], async () => {
    const {page} = active.get('erp'); await page.waitForFunction(() => !!window.electronAPI?.local?.configure);
    await page.evaluate(c => window.electronAPI.local.configure(c), {provider:'actelyo',baseUrl:studio,model:chatId,embeddingModel:embeddingId});
    const selected = await chooseFiles('erp', [fixture], () => page.evaluate(() => window.electronAPI.local.select('corpus')));
    assert.equal(selected.files.length, 1);
    document = await page.evaluate(token => window.electronAPI.local.ingest(token), selected.files[0].token);
    report.erpIngest=document;
    report.erpStatus=await page.evaluate(()=>window.electronAPI.local.status());save();
    assert(document.embedded, 'ERP did not confirm shared embeddings: '+JSON.stringify(document));
    retrieved = await page.evaluate(({marker,id}) => window.electronAPI.local.search(marker,[id]), {marker,id:document.id});
    assert(retrieved.sources.some(s => s.id === document.id && s.text.includes(marker)), 'ERP did not retrieve its actual imported source');
    const answer = await page.evaluate(id => window.electronAPI.local.query({question:'Quel est le montant du dossier ? /no_think',mode:'question',skillIds:[],documentIds:[id]}), document.id);
    assert(answer.content?.trim() && answer.sources?.some(s => s.id === document.id));
    return {documentId:document.id,retrieval:retrieved.retrieval,answerModel:answer.model,extractiveFallback:answer.model !== chatId};
  });
  await step('erp-rag-anything', ['erp-shared-model-and-retrieval'], async () => {
    assert(applications.has('rag-anything'), 'Secondary engine not installed');
    const {page} = active.get('erp');
    const probe = await page.evaluate(() => window.electronAPI.local.checkRagAnything());
    await page.evaluate(() => window.electronAPI.local.setRagProvider('raganything'));
    try {
      const result = await page.evaluate(({marker,id}) => window.electronAPI.local.search(marker,[id]), {marker,id:document.id});
      assert(result.sources.some(s => s.id === document.id && s.text.includes(marker)), 'Secondary engine failed source-preserving retrieval');
      return {probe,retrieval:result.retrieval,sources:result.sources.map(s=>s.id)};
    } finally { await page.evaluate(() => window.electronAPI.local.setRagProvider('native')); }
  });
  await step('law-launch', [], async () => {
    const identity = await launch('law-harness', {HERMES_HOME:path.join(profiles,'law-harness','hermes'),HERMES_DESKTOP_USER_DATA_DIR:path.join(profiles,'law-harness','desktop'),HERMES_DESKTOP_DISABLE_GPU:'1'});
    const {page}=active.get('law-harness');
    const deadline=Date.now()+300000;let interactive=false;
    while(Date.now()<deadline){
      const defer=page.getByRole('button',{name:/^(I'll choose a provider later|Je choisirai un fournisseur plus tard)$/i});
      if(await defer.isVisible().catch(()=>false))await defer.click();
      try{await page.getByRole('button',{name:'Atelier Actelyo',exact:true}).click({trial:true,timeout:1000});interactive=true;break;}catch{}
      await sleep(500);
    }
    assert(interactive,'Installed Law Harness did not finish startup');
    await page.getByRole('button',{name:'Atelier Actelyo',exact:true}).click();
    await page.getByRole('heading',{name:'Atelier Actelyo',exact:true}).waitFor();
    await page.screenshot({path:path.join(out,'law-atelier.png')});await page.keyboard.press('Escape');
    return {...identity,atelierOpened:true};
  });
  await step('erp-law-source-binding', ['erp-shared-model-and-retrieval','law-launch'], async () => {
    const root = path.join(applications.get('law-harness').directory,'resources','agent-payload');
    const source = path.join(root,'hermes-agent');
    const python = [path.join(root,'venv','Scripts','python.exe'),path.join(root,'python','python.exe')].find(p=>fs.existsSync(p));
    assert(python, 'Installed Law Harness Python missing');
    const sources = retrieved.sources.map((s,i)=>({id:'source-'+i,document_id:s.id,name:s.name,url:pathToFileURL(fixture).href,text:s.text,page:s.page}));
    const file = path.join(out,'erp-to-law-sources.json'); fs.writeFileSync(file,JSON.stringify(sources));
    const env = {...clean,HERMES_HOME:path.join(profiles,'law-harness','hermes')};
    const code='import runpy,sys;sys.path.insert(0,sys.argv.pop(1));runpy.run_module("hermes_cli.atelier",run_name="__main__")';
    const call = async args => JSON.parse(await command(python,['-c',code,source,...args],source,env));
    const passages = await call(['catalog',file]); const selected = passages.filter(p=>p.quote.includes(marker) && p.quote.includes('03/11/2026'));
    assert(selected.length, 'Transferred source text was lost');
    const bundle={schema_version:1,id:'suite-qa',name:'Suite QA',kind:'chronology',sources,events:[{id:'qa-event',date:'2026-11-03',title:'Montant du dossier synthétique',passage_ids:[selected[0].passage_id]}]};
    const bundleFile=path.join(out,'law-bundle.json');fs.writeFileSync(bundleFile,JSON.stringify(bundle));
    const saved=await call(['save',bundleFile]);
    assert.equal(saved.source_binding,'verified');assert(saved.events[0].evidence[0].quote.includes(marker));
    assert.equal(saved.semantic_review,'human_required');
    return {sourceBinding:saved.source_binding,revision:saved.revision,quote:saved.events[0].evidence[0].quote,semanticReview:saved.semantic_review,scope:'Real installed Law source verifier; not model legal entailment or Law chat inference'};
  });
  await step('rag-launch', ['llm-chat-and-embeddings'], async () => {
    const data=path.join(profiles,'rag','desktop');fs.mkdirSync(path.join(data,'server'),{recursive:true});
    // The SDK requires a key field even for the actual anonymous loopback server.
    // This public placeholder is not a user credential and is never sent off-machine.
    const settings={LLM_PROVIDER:'generic-openai',GENERIC_OPEN_AI_BASE_PATH:studio,GENERIC_OPEN_AI_API_KEY:'actelyo-local',GENERIC_OPEN_AI_MODEL_PREF:chatId,GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT:'8192',GENERIC_OPEN_AI_MAX_TOKENS:'256',EMBEDDING_ENGINE:'generic-openai',EMBEDDING_BASE_PATH:studio,GENERIC_OPEN_AI_EMBEDDING_API_KEY:'actelyo-local',GENERIC_OPEN_AI_EMBEDDING_MAX_CONCURRENT_CHUNKS:'4',GENERIC_OPEN_AI_EMBEDDING_PASSAGE_PREFIX:'search_document: ',GENERIC_OPEN_AI_EMBEDDING_QUERY_PREFIX:'search_query: ',EMBEDDING_MODEL_PREF:embeddingId,EMBEDDING_MODEL_MAX_CHUNK_LENGTH:'512',VECTOR_DB:'lancedb',DISABLE_TELEMETRY:'true'};
    fs.writeFileSync(path.join(data,'server','.env'),Object.entries(settings).map(([k,v])=>k+'='+v).join('\n'));
    await launch('rag',{},['--data-dir='+data]);
    const {page}=active.get('rag');await page.waitForURL(u=>u.hostname==='127.0.0.1',{timeout:240000});
    active.get('rag').origin=new URL(page.url()).origin;return {origin:active.get('rag').origin};
  });
  await step('rag-shared-model-retrieval', ['rag-launch'], async () => {
    const origin=active.get('rag').origin;
    const created=await json(origin+'/api/workspace/new',{name:'Suite QA '+marker});
    const slug=created.workspace?.slug;assert(slug,'No real RAG workspace created');
    const generated=await json(origin+'/api/system/generate-api-key',{});
    const key=generated.apiKey?.secret;assert(key,'No QA-only RAG API key');
    const headers={Authorization:'Bearer '+key};
    const form=new FormData();form.set('file',new Blob([fs.readFileSync(fixture)],{type:'text/plain'}),'piece-qa.txt');
    const upload=await fetch(origin+'/api/v1/document/upload',{method:'POST',headers,body:form,signal:AbortSignal.timeout(120000)});
    const uploadText=await upload.text();
    assert(upload.ok,'RAG real upload failed: '+upload.status+' '+uploadText.slice(0,1200));const data=JSON.parse(uploadText);
    const locations=data.documents?.map(d=>d.location);assert(locations?.length,'RAG document collector returned no document');
    await json(origin+'/api/v1/workspace/'+slug+'/update-embeddings',{adds:locations,deletes:[]},headers);
    const result=await json(origin+'/api/v1/workspace/'+slug+'/vector-search',{query:marker,topN:5},headers);
    assert(JSON.stringify(result).includes(marker),'RAG vector search did not retrieve the imported source');
    const answer=await json(origin+'/api/v1/workspace/'+slug+'/chat',{message:'Quel montant est indiqué dans la pièce ? /no_think',mode:'query'},headers);
    assert(answer.textResponse?.trim(),'RAG returned no response through the shared model');
    assert(answer.sources?.length,'RAG response has no sources');
    return {workspace:slug,sources:answer.sources.length,model:chatId,embeddingModel:embeddingId};
  });
  let openPort;
  await step('openbousic-launch', ['llm-chat-and-embeddings'], async () => {
    openPort=await freePort();
    const identity=await launch('openbousic',{ACTELYO_OPENBOUSIC_PORT:String(openPort),ACTELYO_OPENBOUSIC_LLM_URL:studio,ACTELYO_OPENBOUSIC_MODEL_NAME:chatId,ACTELYO_OPENBOUSIC_BACKEND:'llamacpp'});
    await active.get('openbousic').page.waitForURL(u=>u.hostname==='127.0.0.1' && u.port===String(openPort),{timeout:120000});
    await json('http://127.0.0.1:'+openPort+'/api/health');
    return {...identity,serverReady:true};
  });
  await step('openbousic-shared-model-generation', ['openbousic-launch'], async () => {
    const origin='http://127.0.0.1:'+openPort;
    const models=await json(origin+'/api/providers/models?url='+encodeURIComponent(studio));
    assert(models.models?.some(m=>m.id===chatId),'OpenBousic cannot discover the real shared model');
    const result=await json(origin+'/api/providers/test-params',{url:studio,model:chatId,backend:'llamacpp',mode:'non-thinking',modelConfig:{maxTokens:128,nonThinkingEnabled:true}}, {},60000);
    assert(result.success && result.message?.content?.trim(),'OpenBousic shared model generation failed');
    return {model:chatId,reply:result.message.content,scope:'Provider generation path, not autonomous file editing or browser control'};
  });
  await step('simultaneous-coexistence', ['llm-models','erp-launch','law-launch','rag-launch','openbousic-launch'], async () => {
    const identities=[];
    for(const [id,instance] of active){assert(instance.app.process().exitCode===null,id+' exited');assert(!instance.page.isClosed(),id+' window closed');identities.push({id,...instance.identity});}
    assert.equal(identities.length,5,'All five GUI applications must remain running');
    await json(studio.replace(/\/v1\/?$/,'')+'/health');
    return {applications:identities,secondaryEngine:'exercised via ERP, not a separate GUI'};
  });
} finally {
  for(const [id,instance] of [...active].reverse()){
    try { await instance.app.close(); } catch(e){
      report.cleanupErrors??=[];report.cleanupErrors.push({id,error:String(e)});
      const owned=instance.app.process();
      if(process.platform==='win32' && owned.pid && owned.exitCode===null){
        await command('taskkill',['/PID',String(owned.pid),'/T','/F'],process.cwd(),clean).catch(()=>{});
      }
    }
    instance.log?.end();
  }
  const passed=report.steps.length>0 && report.steps.every(s=>s.status==='pass') && !report.cleanupErrors?.length;
  report.status=passed?(erpProbe?'diagnostic-pass':'pass'):'fail';
  report.finishedAt=new Date().toISOString();save();
  const escape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  fs.writeFileSync(path.join(out,'rapport.html'),`<!doctype html><meta charset="utf-8"><title>QA Suite Actelyo</title><style>body{font:16px Segoe UI;max-width:1000px;margin:40px auto;padding:20px}td,th{padding:12px;text-align:left;border-bottom:1px solid #ddd}pre{white-space:pre-wrap}</style><h1>Suite Actelyo — ${escape(report.status)}</h1><p>${escape(report.scope)}</p><table><tr><th>Contrôle</th><th>Résultat</th><th>Détail</th></tr>${report.steps.map(s=>`<tr><td>${escape(s.id)}</td><td>${escape(s.status)}</td><td><pre>${escape(s.error||JSON.stringify(s.detail,null,2))}</pre></td></tr>`).join('')}</table>`);
  process.exitCode=passed?0:1;
}
