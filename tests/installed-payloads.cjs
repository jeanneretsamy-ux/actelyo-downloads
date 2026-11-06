const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const patterns=[['Hugging Face token',/(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{30,}/g],['GitHub token',/(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{30,}/g],['provider secret',/(?<![A-Za-z0-9_])sk-(?:proj-|or-v1-)?[A-Za-z0-9_-]{32,}/g]];
// This exact public UI example is independently present in the released RAG source
// and upstream. Only its placeholder use is allowed; configuration values never are.
const publicChromaExample='b1a83683225268694948fae72478b4a3d0d8976edaa61f0d28136628543b024b';
function inspect(file,text,findings,examples){
 if(/^(?:dist|dist-electron)\/.*\.map$/i.test(file))findings.push({file,rule:'first-party source map'});
 for(const [rule,expression]of patterns)for(const match of text.matchAll(expression)){
  const hint=/placeholder\s*[:=]\s*["']$/.test(text.slice(Math.max(0,match.index-40),match.index));
  if(rule==='provider secret'&&hint&&crypto.createHash('sha256').update(match[0]).digest('hex')===publicChromaExample){examples.push({file,rule:'reviewed public Chroma UI placeholder',sha256:publicChromaExample});continue}
  findings.push({file,rule});
 }
 const normalized=text.replace(/\\r\\n|\\n/g,'\n');
 for(const match of normalized.matchAll(/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----([\s\S]*?)-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g)){
  if(/^[A-Za-z0-9+/=]{48,}$/.test(match[1].replace(/\s/g,'')))findings.push({file,rule:'private key material'});
 }
}
function scanArchive(archive){
 const fd=fs.openSync(archive,'r'),findings=[],examples=[];let count=0;
 try{
  const prefix=Buffer.alloc(16);assert.equal(fs.readSync(fd,prefix,0,16,0),16,'Truncated ASAR');
  const headerBytes=prefix.readUInt32LE(4),jsonBytes=prefix.readUInt32LE(12),total=fs.fstatSync(fd).size;
  assert(headerBytes<=64*1024*1024&&jsonBytes<=headerBytes&&16+jsonBytes<=total,'Invalid ASAR header');
  const header=Buffer.alloc(jsonBytes);fs.readSync(fd,header,0,jsonBytes,16);const tree=JSON.parse(header.toString('utf8'));
  function walk(node,base=''){
   for(const [name,item]of Object.entries(node.files||{})){
    assert(name!=='.'&&name!=='..'&&!/[\\/]/.test(name),'Archive entry escaped its parent');const file=base+name;
    if(name==='node_modules')continue;
    if(item.files){walk(item,file+'/');continue}
    count++;
    if(!/\.(?:js|mjs|cjs|json|html|css|txt|pem|map)$/i.test(file)||item.size>64*1024*1024)continue;
    let text;
    if(item.unpacked){const root=path.resolve(archive+'.unpacked'),candidate=path.resolve(root,file);assert(candidate.startsWith(root+path.sep),'Unpacked entry escaped');text=fs.readFileSync(candidate,'utf8');}
    else{const offset=8+headerBytes+Number(item.offset);assert(Number.isSafeInteger(offset)&&offset>=8+headerBytes&&offset+item.size<=total,'Invalid ASAR entry bounds');const bytes=Buffer.alloc(item.size);fs.readSync(fd,bytes,0,item.size,offset);text=bytes.toString('utf8');}
    inspect(file,text,findings,examples);
   }
  }
  walk(tree);return {entries:count,findings,reviewedPublicExamples:examples};
 }finally{fs.closeSync(fd)}
}
function scanDirectory(directory){
 const findings=[],examples=[];let count=0,archives=0;
 function walk(folder,base=''){
  for(const entry of fs.readdirSync(folder,{withFileTypes:true})){
   if(entry.isSymbolicLink())continue;
   const file=base+entry.name,absolute=path.join(folder,entry.name);
   if(entry.isDirectory()){
    if(['node_modules','uv-cache','venv','site-packages','storage','models','cache','locales'].includes(entry.name)||entry.name.endsWith('.asar.unpacked'))continue;
    walk(absolute,file+'/');continue;
   }
   if(entry.name==='app.asar'){const result=scanArchive(absolute);archives++;count+=result.entries;findings.push(...result.findings.map(x=>({...x,file:file+':'+x.file})));examples.push(...result.reviewedPublicExamples.map(x=>({...x,file:file+':'+x.file})));continue}
   if(!/\.(?:js|mjs|cjs|json|html|css|txt|pem|map)$/i.test(file)||fs.statSync(absolute).size>64*1024*1024)continue;
   count++;inspect(file,fs.readFileSync(absolute,'utf8'),findings,examples);
  }
 }
 walk(directory);assert(count>0,'No packaged application content inspected');return {entries:count,archives,findings,reviewedPublicExamples:examples,passed:findings.length===0};
}
function selfTest(){
 const os=require('node:os'),dir=fs.mkdtempSync(path.join(os.tmpdir(),'actelyo-payload-scan-'));
 try{
  fs.writeFileSync(path.join(dir,'main.js'),'console.log("public application");');assert(scanDirectory(dir).passed);
  const key=crypto.generateKeyPairSync('ed25519').privateKey.export({type:'pkcs8',format:'pem'});
  fs.writeFileSync(path.join(dir,'key.pem'),key);assert(!scanDirectory(dir).passed);
  fs.unlinkSync(path.join(dir,'key.pem'));fs.writeFileSync(path.join(dir,'config.json'),JSON.stringify({token:'hf_'+'A'.repeat(35)}));assert(!scanDirectory(dir).passed);
  fs.unlinkSync(path.join(dir,'config.json'));
  fs.writeFileSync(path.join(dir,'main.js'),'const hint={placeholder:"sk-'+crypto.randomBytes(24).toString('base64url')+'"};');assert(!scanDirectory(dir).passed,'Arbitrary provider keys in placeholders must still fail');
  fs.writeFileSync(path.join(dir,'main.js'),'const documentation="How-do-I-ask-a-question-or-send-a-message-to-a-mailing-list";');assert(scanDirectory(dir).passed,'Documentation anchors are not API tokens');
  fs.writeFileSync(path.join(dir,'config.json'),JSON.stringify({description:'Example: -----BEGIN RSA PRIVATE KEY-----\\n<key data>\\n-----END RSA PRIVATE KEY-----'}));assert(scanDirectory(dir).passed,'PEM format descriptions contain no key material');fs.unlinkSync(path.join(dir,'config.json'));
  const content=Buffer.from('hf_'+'B'.repeat(35)),json=Buffer.from(JSON.stringify({files:{'main.js':{size:content.length,offset:'0'}}})),headerBytes=8+json.length,prefix=Buffer.alloc(16);prefix.writeUInt32LE(headerBytes,4);prefix.writeUInt32LE(json.length,12);const archive=path.join(dir,'app.asar');fs.writeFileSync(archive,Buffer.concat([prefix,json,content]));assert(!scanArchive(archive).findings.every(x=>x.rule!=='Hugging Face token'));
  console.log('PASS real directory and ASAR inspection detect synthetic secrets without exposing values');
 }finally{for(const name of ['main.js','key.pem','config.json','app.asar']){const p=path.join(dir,name);if(fs.existsSync(p))fs.unlinkSync(p)}fs.rmdirSync(dir)}
}
if(require.main===module){
 if(process.argv.includes('--self-test'))selfTest();
 else{
  const input=JSON.parse(fs.readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,'')),ids=['erp','llm','rag','law-harness','openbousic'];
  const applications=ids.map(id=>{const matches=input.applications.filter(x=>x.id===id);assert.equal(matches.length,1,'Exactly one installed app required: '+id);const app=matches[0];return {id,version:app.version,...scanDirectory(app.directory)};});
  const report={passed:applications.every(x=>x.passed),scope:'First-party installed ASAR and text files; high-confidence secret patterns and application source maps. Dependency trees and user/model stores excluded. No secret values emitted. This is not proof of legal/model quality.',applications};
  fs.writeFileSync(path.join(input.reportDirectory,'payload-cleanliness.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));if(!report.passed)process.exitCode=1;
 }
}
module.exports={scanArchive,scanDirectory};
