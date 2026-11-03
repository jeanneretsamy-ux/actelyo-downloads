import fs from 'node:fs';import path from 'node:path';import {createRequire} from 'node:module';import {spawn} from 'node:child_process';import {pathToFileURL} from 'node:url';import assert from 'node:assert/strict';
const require=createRequire(new URL('../suite/qa/runtime/package.json',import.meta.url)),{_electron}=require('playwright-core');
const receipt=JSON.parse(fs.readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,'')),item=receipt.applications[0],out=receipt.reportDirectory;
const root=path.join(out,'isolated-law'),data=path.join(root,'desktop');fs.mkdirSync(data,{recursive:true});
const env={...process.env};for(const k of Object.keys(env))if(/TOKEN|SECRET|PASSWORD|API.?KEY|^GH_|^GITHUB_|^HERMES_|^ACTELYO_|^ELECTRON_RUN_AS_NODE$|^NODE_OPTIONS$/i.test(k))delete env[k];
Object.assign(env,{HERMES_HOME:path.join(root,'hermes'),HERMES_DESKTOP_USER_DATA_DIR:data,HERMES_DESKTOP_DISABLE_GPU:'1',APPDATA:path.join(root,'Roaming'),USERPROFILE:path.join(root,'Home'),HOME:path.join(root,'Home')});
for(const p of [env.HERMES_HOME,env.APPDATA,env.HOME])fs.mkdirSync(p,{recursive:true});
const app=await _electron.launch({executablePath:item.executable,cwd:item.directory,args:['--user-data-dir='+data],env,timeout:180000});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
try{
 const page=await app.firstWindow({timeout:180000});await page.waitForLoadState('domcontentloaded');
 const identity=await app.evaluate(({app})=>({name:app.getName(),userData:app.getPath('userData')}));assert(path.resolve(identity.userData).startsWith(root+path.sep));
 let ready=false;for(let i=0;i<600;i++){
  const defer=page.getByRole('button',{name:/^(I'll choose a provider later|Je choisirai un fournisseur plus tard)$/i});if(await defer.isVisible().catch(()=>false))await defer.click();
  try{await page.getByRole('button',{name:'Atelier Actelyo',exact:true}).click({trial:true,timeout:500});ready=true;break}catch{}await sleep(500);
 }
 assert(ready,'Installed Atelier unavailable');await page.getByRole('button',{name:'Atelier Actelyo',exact:true}).click();await page.getByRole('heading',{name:'Atelier Actelyo',exact:true}).waitFor();await page.screenshot({path:path.join(out,'law-atelier.png')});
 const payload=path.join(item.directory,'resources/agent-payload'),source=path.join(payload,'hermes-agent');
 const python=fs.readdirSync(path.join(payload,'tools')).filter(n=>n.startsWith('python-')).map(n=>path.join(payload,'tools',n,'python.exe')).filter(p=>fs.existsSync(p));assert.equal(python.length,1);
 const file=path.join(out,'source-qa.txt'),text='Le 03/11/2026, le dossier QA-LOGO-LAW indique un montant de 7429 euros.';fs.writeFileSync(file,text);
 const sources=[{id:'qa-source',name:'Pièce synthétique',url:pathToFileURL(file).href,text}],input=path.join(out,'source-qa.json');fs.writeFileSync(input,JSON.stringify(sources));
 const code='import runpy,sys;sys.path.insert(0,sys.argv.pop(1));runpy.run_module("hermes_cli.atelier",run_name="__main__")';
 const call=args=>new Promise((resolve,reject)=>{const child=spawn(python[0],['-c',code,source,...args],{cwd:source,env:{...env,PYTHONPATH:[source,path.join(payload,'venv/Lib/site-packages')].join(path.delimiter)},windowsHide:true,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';const timer=setTimeout(()=>{child.kill();reject(Error('Installed source verifier timed out'))},120000);child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);child.once('error',reject);child.once('close',n=>{clearTimeout(timer);n===0?resolve(JSON.parse(stdout)):reject(Error(stderr))})});
 const passages=await call(['catalog',input]),passage=passages.find(p=>p.quote.includes('7429'));assert(passage);
 const bundle={schema_version:1,id:'qa-branding',name:'QA logo',kind:'chronology',sources,events:[{id:'qa-event',date:'2026-11-03',title:'Montant du dossier',passage_ids:[passage.passage_id]}]},bundleFile=path.join(out,'bundle-qa.json');fs.writeFileSync(bundleFile,JSON.stringify(bundle));
 const saved=await call(['save',bundleFile]);assert.equal(saved.source_binding,'verified');assert.equal(saved.semantic_review,'human_required');assert.equal(saved.events[0].evidence[0].quote,text);
 const proof={status:'pass',version:item.version,identity,atelierOpened:true,sourceBinding:saved.source_binding,semanticReview:saved.semantic_review,exactQuoteVerified:true,scope:'Installed desktop Atelier and installed Python reference verifier, synthetic data, no model legal-entailment claim'};
 fs.writeFileSync(path.join(out,'functional-proof.json'),JSON.stringify(proof,null,2));console.log(JSON.stringify(proof));
}finally{await app.close();}
