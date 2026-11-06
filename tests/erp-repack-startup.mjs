import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { _electron } = createRequire(new URL('../suite/qa/runtime/package.json', import.meta.url))('playwright-core');
if (process.env.GITHUB_ACTIONS !== 'true') throw Error('Synthetic runner required');
const out = path.resolve('erp-repack'), profile = path.join(out, 'qa-profile');
const env = { ...process.env };
for (const key of Object.keys(env)) if (/TOKEN|SECRET|PASSWORD|API.?KEY|^GH_|^GITHUB_TOKEN$|^ELECTRON_RUN_AS_NODE$|^NODE_OPTIONS$/i.test(key)) delete env[key];
const app = await _electron.launch({ executablePath: process.env.ERP_REPACK_EXE, args: ['--data-dir=' + profile], env, timeout: 120000 });
try {
  const identity = await app.evaluate(({ app }) => ({ version: app.getVersion(), userData: app.getPath('userData') }));
  assert.equal(identity.version, '1.8.6-rc.4');
  assert.equal(path.resolve(identity.userData).toLowerCase(), profile.toLowerCase());
  const page = await app.firstWindow(); page.setDefaultTimeout(30000);
  await page.getByRole('button', { name: 'Continuer sans compte' }).click();
  await page.waitForURL('**/#/dashboard');
  await page.evaluate(() => { location.hash = '/legalya/llm'; });
  await page.getByRole('button', { name: 'Harnais & Actelyo RAG', exact: true }).click();
  await page.getByText('Modèle, RAG, sources et outils de cette conversation', { exact: true }).click();
  await page.getByText('Connecter un fournisseur cloud ou un routeur', { exact: true }).click();
  await page.getByLabel('Fournisseur', { exact: true }).selectOption('openrouter');
  assert.match(await page.getByLabel('Adresse de base de l’API', { exact: true }).inputValue(), /^https:\/\/openrouter\.ai\/api\/v1\/?$/);
  assert.equal(await page.getByLabel('Moteur', { exact: true }).inputValue(), 'local');
  await page.screenshot({ path: path.join(out, 'installed-providers.png') });
  fs.writeFileSync(path.join(out, 'startup-proof.json'), JSON.stringify({ identity, localOnboarding: true, conversationSettingsAccessible: true, openRouterPreset: true, cloudNotActivatedByPreset: true, realCloudInferenceTested: false }, null, 2));
} finally { await app.close(); }
