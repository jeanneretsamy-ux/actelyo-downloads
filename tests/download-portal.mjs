import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const require=createRequire(new URL('../suite/qa/runtime/package.json',import.meta.url));
const {chromium}=require('playwright-core');
const catalog=JSON.parse(fs.readFileSync(path.join(root,'catalog.json'),'utf8').replace(/^\uFEFF/,''));
const files={'/':'index.html','/index.html':'index.html','/desktop-catalog.json':'desktop-catalog.json'};
const server=http.createServer((req,res)=>{
 const file=files[new URL(req.url,'http://localhost').pathname];
 if(!file){res.writeHead(404);res.end();return}
 res.setHeader('Content-Type',file.endsWith('.json')?'application/json':'text/html; charset=utf-8');
 res.end(fs.readFileSync(path.join(root,'docs',file)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await chromium.launch({channel:process.env.ACTELYO_QA_BROWSER_CHANNEL||'msedge',headless:true});
 const context=await browser.newContext();const page=await context.newPage();
 // Exercise the actual fallback UI under a controlled primary-catalog outage.
 await page.route('https://raw.githubusercontent.com/jeanneretsamy-ux/actelyo-downloads/main/catalog.json',route=>route.fulfill({status:503,body:'Controlled QA outage'}));
 const url=process.argv[2]||'http://127.0.0.1:'+server.address().port+'/';
 await page.goto(url,{waitUntil:'domcontentloaded'});
 await page.locator('#item-openbousic').waitFor({timeout:30000});
 assert.match(await page.locator('#message').innerText(),/Catalogue embarqué ou en cache/,'The test must actually enter fallback mode');
 const checked=[];
 for(const item of catalog.items.filter(i=>i.category==='desktop')){
  const card=page.locator('#item-'+item.id);await card.waitFor();
  assert((await card.innerText()).includes('Disponible · '+item.version),'Wrong fallback version: '+item.id);
  const href=await card.locator('.card-actions a').getAttribute('href');
  assert.equal(href,item.parts?(item.kitUrl||catalog.kitUrl):item.url,'Wrong fallback download URL: '+item.id);
  checked.push({id:item.id,version:item.version,url:href});
 }
 assert.equal(checked.length,6);
 const proof={status:'pass',scope:'Real browser UI with primary catalogue deliberately unavailable',url,checked};
 if(process.env.ACTELYO_QA_PORTAL_OUT){const out=path.resolve(process.env.ACTELYO_QA_PORTAL_OUT);fs.mkdirSync(out,{recursive:true});await page.screenshot({path:path.join(out,'portal-fallback.png'),fullPage:true});fs.writeFileSync(path.join(out,'portal-fallback.json'),JSON.stringify(proof,null,2));}
 console.log(JSON.stringify(proof));
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
