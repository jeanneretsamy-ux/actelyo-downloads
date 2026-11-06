import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {assertActionableControl} from '../suite/qa/ui-control.mjs';
const require=createRequire(new URL('../suite/qa/runtime/package.json',import.meta.url));
const {chromium}=require('playwright-core');
const browser=await chromium.launch({channel:'chrome',headless:true});
try {
 const page=await browser.newPage();
 await page.route('http://127.0.0.1:19999/**',route=>route.fulfill({contentType:'text/html',body:`
  <button>Select project...</button><div style="position:fixed;inset:0;background:white">
  <button data-testid="onboarding-add-provider-button" onclick="document.querySelector('dialog').showModal();window.opened=(window.opened||0)+1">Add Provider</button></div>
  <dialog><button data-testid="provider-modal-next">Next</button><button onclick="document.querySelector('dialog').close()">Cancel</button></dialog>`}));
 await page.goto('http://127.0.0.1:19999/onboarding');
 await assert.rejects(page.locator('button:visible:not(:disabled)').first().click({trial:true,timeout:500}));
 // Exercise the same bounded action timeout as the installed-suite verifier.
 // A cold hosted Chrome can take more than two seconds to produce stable frames.
 await assertActionableControl(page,'openbousic');
 assert.equal(await page.evaluate(()=>window.opened),1);
 assert.equal(await page.locator('dialog').isVisible(),false);
 await page.getByTestId('onboarding-add-provider-button').evaluate(button=>button.setAttribute('aria-label','Configure a provider'));
 await assertActionableControl(page,'openbousic');
 assert.equal(await page.evaluate(()=>window.opened),2);
 await page.getByTestId('onboarding-add-provider-button').evaluate(button=>button.removeAttribute('aria-label'));
 await page.getByTestId('onboarding-add-provider-button').evaluate(button=>button.removeAttribute('data-testid'));
 await assertActionableControl(page,'openbousic');
 assert.equal(await page.evaluate(()=>window.opened),3);
 await page.getByRole('button',{name:'Add Provider',exact:true}).evaluate(button=>button.onclick=null);
 await assert.rejects(assertActionableControl(page,'openbousic',500));
 await page.setContent('<body>Blank or broken application</body>');
 await assert.rejects(assertActionableControl(page,'erp',500));
 console.log('PASS covered header reproduced; actual onboarding dialog exercised; broken and blank interfaces still rejected');
} finally {await browser.close();}
