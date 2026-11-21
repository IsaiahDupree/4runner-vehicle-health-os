// Bounded UI verification on owned hardware; no fabricated controller responses.
const {webkit}=require(process.env.VHOS_PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs');
const path=require('path');
(async()=>{
 const browser=await webkit.launch({headless:true});
 const out=path.join(__dirname,'evidence');fs.mkdirSync(out,{recursive:true});
 const results=[];
 try {
  for(const [name,width,height] of [['head-unit',1280,800],['phone',390,844]]){
   const context=await browser.newContext({viewport:{width,height},deviceScaleFactor:1});
   const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.goto(process.env.VHOS_UI_URL || 'http://127.0.0.1:8874',{waitUntil:'networkidle'});
   await page.getByRole('button',{name:'Teal',exact:true}).click();
   if(!(await page.locator('#previewLabel').textContent()).startsWith('Teal'))throw Error('Color preview did not update');
   if(!(await page.locator('#applyColor').isDisabled()))throw Error('Offline hardware control enabled');
   await page.waitForFunction(()=>getComputedStyle(document.querySelector('.strip-line')).stroke==='rgb(53, 188, 164)');
   if(await page.getByRole('button',{name:'Teal',exact:true}).getAttribute('aria-pressed')!=='true')throw Error('Color selection mismatch');
   await page.screenshot({path:path.join(out,name+'-lights.png'),fullPage:true,animations:'disabled'});
   await page.locator('[data-tab=automations]').click();
   await page.locator('#signal').selectOption('4');
   if(await page.locator('#enter').inputValue()!=='1')throw Error('Activity threshold mismatch');
   await page.screenshot({path:path.join(out,name+'-automation.png'),fullPage:true,animations:'disabled'});
   await page.locator('[data-tab=setup]').click();
   await page.screenshot({path:path.join(out,name+'-wiring.png'),fullPage:true,animations:'disabled'});
   const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
   if(overflow || errors.length)throw Error(JSON.stringify({name,overflow,errors}));
   await page.locator('[data-tab=lights]').click();
   await page.locator('#relayKey').fill('offline-ui-transport-check');
   await page.getByRole('button',{name:'Connect',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#connectionLabel').textContent.includes('404'));
   if(!(await page.locator('#applyColor').isDisabled()))throw Error('404 enabled hardware controls');
   if(await page.locator('#voltageValue').textContent()!=='— V')throw Error('Unavailable voltage presented as a reading');
   results.push({viewport:name,width,height,localColorPreview:true,activityUnits:true,noHorizontalOverflow:!overflow,
      missingControllerRejected:true,noInventedVoltage:true,browserErrors:errors});
   await context.close();
  }
  fs.writeFileSync(path.join(out,'ui-checks.json'),JSON.stringify({browser:'Playwright WebKit',
    source:'Actual editable UI served by local static HTTP server',controllerConnected:false,
    simulatedControllerResponses:false,checks:results},null,2)+'\n');
  console.log(JSON.stringify(results));
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
