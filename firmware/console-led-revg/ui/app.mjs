// SPDX-License-Identifier: EUPL-1.2
export const signals = [
  {unit:'rpm', min:0, max:16383.75}, {unit:'km/h', min:0, max:255},
  {unit:'°C', min:-40, max:215}, {unit:'%', min:0, max:100}, {unit:'0 / 1', min:0, max:1}
];
export function centi(value, signal) {
  if (!Number.isInteger(signal) || !signals[signal] || !/^-?\d+(\.\d{1,2})?$/.test(String(value)))
    throw new Error('Enter a number with at most two decimal places.');
  const v=Number(value), spec=signals[signal];
  if (!Number.isFinite(v) || v<spec.min || v>spec.max)
    throw new Error('Value is outside the selected parameter range.');
  return Math.round(v*100);
}
export function rgb(hex) {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) throw new Error('Choose a valid RGB color.');
  return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16));
}
export function percent(n) { return Math.round(n*100/255); }
export function validateConfig(c) {
  const integer=(name,lo,hi)=>{ const v=c[name];
    if (!Number.isInteger(v) || v<lo || v>hi) throw new Error('Invalid '+name+'.'); return v; };
  const s=integer('signal',0,4), on=integer('on-centi',-4000,1638375), off=integer('off-centi',-4000,1638375);
  centi(String(on/100),s); centi(String(off/100),s);
  if (off>on) throw new Error('The off threshold must be at or below the on threshold.');
  for (const k of ['red','green','blue','white']) integer(k,0,255);
  integer('brightness',1,255);
  for (const k of ['tail-enabled','dim-enabled']) integer(k,0,1);
  for (const k of ['tail-on-mv','tail-off-mv','dim-min-mv','dim-max-mv']) integer(k,0,3300);
  for (const k of ['dim-at-min-percent','dim-at-max-percent']) integer(k,0,100);
  if (c['tail-enabled'] && Math.abs(c['tail-on-mv']-c['tail-off-mv'])<50)
    throw new Error('Measure TAIL boundaries at least 50 ADC mV apart.');
  if (c['dim-enabled'] && c['dim-max-mv']-c['dim-min-mv']<100)
    throw new Error('Measure a DIM span of at least 100 ADC mV.');
  return c;
}
export class ControllerClient {
  constructor(key, origin='') {
    if (!/^[!-~]{16,64}$/.test(key)) throw new Error('Use the controller’s 16–64 character relay key.');
    this.key=key; this.origin=origin;
  }
  async request(path, values) {
    if (!['status','config','manual','voltage'].includes(path)) throw new Error('Unsupported controller operation.');
    const controller=new AbortController(), timer=setTimeout(()=>controller.abort(),3000);
    try {
      const response=await fetch(this.origin+'/vhos/'+path, {
        method:values?'POST':'GET', redirect:'error', credentials:'omit', cache:'no-store',
        headers:{'X-VHOS-Key':this.key,...(values?{'Content-Type':'application/x-www-form-urlencoded'}:{})},
        body:values?new URLSearchParams(values).toString():undefined, signal:controller.signal
      });
      if (!response.ok) throw new Error(response.status===403?'Check the relay key.':
        response.status===409?'Controller is not ready. Check arming and configuration.':
        response.status===400?'The controller rejected these settings.':'Controller unavailable ('+response.status+').');
      if (path!=='status') return null;
      const s=await response.json();
      if (s.contract!=='vhos.lighting.status@1.0.0' || typeof s.ready!=='boolean' ||
          typeof s.canFresh!=='boolean' || !Number.isInteger(s.effectiveBrightness) ||
          s.effectiveBrightness<0 || s.effectiveBrightness>255 || !s.inputs || !s.voltage)
        throw new Error('Unsupported controller status. Update the lighting firmware.');
      validateConfig(s.config);
      return s;
    } finally { clearTimeout(timer); }
  }
}

if (typeof document!=='undefined') {
  const $=id=>document.getElementById(id);
  let client=null, state=null, loaded=false, pending=false, polling=null;
  const cabinKeys=['tail-enabled','tail-on-mv','tail-off-mv','dim-enabled','dim-min-mv','dim-max-mv','dim-at-min-percent','dim-at-max-percent'];
  function feedback(message) { $('feedback').textContent=message; $('feedback').hidden=false;
    clearTimeout(feedback.timer); feedback.timer=setTimeout(()=>$('feedback').hidden=true,6500); }
  function availability(connected) {
    for (const el of document.querySelectorAll('[data-connected]')) el.disabled=!connected || pending;
    for (const el of document.querySelectorAll('[data-output]')) el.disabled=!connected || !state?.ready || pending;
    $('calibrateVoltage').disabled=!connected || !state?.voltage.fitted || pending;
  }
  function disconnected(message='Controller disconnected') {
    state=null; loaded=false; availability(false); $('connectionLabel').textContent=message;
    $('connectionDot').classList.remove('live'); $('outputState').textContent='Unavailable';
    $('effectiveLevel').textContent='—'; $('mode').textContent='—'; $('canState').textContent='No live sample';
    $('voltageValue').textContent='— V'; $('voltageState').textContent='No live voltage reading';
    $('senseState').textContent='Not connected'; $('senseReadings').textContent='TAIL — · DIM — ADC mV';
    $('footerState').textContent='Live controller status unavailable'; $('automationBadge').textContent='NOT CONNECTED';
  }
  function preview(label='Custom') {
    document.documentElement.style.setProperty('--preview',$('rgb').value);
    $('previewLabel').textContent=label+' · local preview';
    $('whiteValue').textContent=percent(Number($('white').value))+'%';
    $('brightnessValue').textContent=percent(Number($('brightness').value))+'%';
  }
  function units() { const s=Number($('signal').value);
    for (const el of document.querySelectorAll('.unit')) el.textContent=signals[s].unit;
    for (const id of ['enter','exit']) { $(id).min=signals[s].min; $(id).max=signals[s].max; }
    if (s===4) { $('enter').value='1'; $('exit').value='1'; }
  }
  function loadSettings(s) {
    const c=s.config;
    $('signal').value=c.signal; units(); $('enter').value=c['on-centi']/100; $('exit').value=c['off-centi']/100;
    $('rgb').value='#'+['red','green','blue'].map(k=>c[k].toString(16).padStart(2,'0')).join('');
    $('white').value=c.white; $('brightness').value=c.brightness;
    for (const k of cabinKeys) {
      if ($(k).type==='checkbox') $(k).checked=c[k]===1; else $(k).value=c[k];
    }
    for (const [k,v] of Object.entries(s.voltageCalibration ?? {}))
      if (v!==0 && $('voltageForm').elements.namedItem(k)) $('voltageForm').elements.namedItem(k).value=v;
    preview('Configured color');
  }
  function render(s) {
    state=s; availability(true); $('connectionDot').classList.add('live');
    $('connectionLabel').textContent=s.ready?'Controller ready':'Controller connected · disarmed';
    $('boardLabel').textContent=s.board+' · ESP32-S3';
    $('outputState').textContent=s.effectiveBrightness?'Active':'Off';
    $('effectiveLevel').textContent=percent(s.effectiveBrightness)+'%';
    $('mode').textContent=s.mode==='can'?'CAN rule':s.mode==='manual'?'Manual':'Off';
    $('canState').textContent=s.canFresh?'Fresh relay sample':s.mode==='can'?'Waiting for data':'Relay not active';
    if (s.canFresh && Number.isInteger(s.sample?.centiUnits) && signals[s.sample.signal])
      $('canState').textContent=(s.sample.centiUnits/100).toLocaleString(undefined,{maximumFractionDigits:2})+' '+signals[s.sample.signal].unit;
    $('automationBadge').textContent=s.mode==='can'?(s.canFresh?'RELAY LIVE':'WAITING FOR DATA'):'NOT RUNNING';
    $('senseState').textContent=s.config['tail-enabled']?(s.tailAllowed?'TAIL gate open':'TAIL gate closed'):'Monitor only';
    const t=s.inputs.tailAdcMv, d=s.inputs.dimAdcMv;
    $('senseReadings').textContent='TAIL '+(t>=0?t:'—')+' · DIM '+(d>=0?d:'—')+' ADC mV';
    const v=s.voltage;
    $('voltageValue').textContent=v.fitted && Number.isInteger(v.inputMv)?
      (v.calibrated?'':'≈ ')+(v.inputMv/1000).toFixed(2)+' V':'— V';
    $('voltageState').textContent=!v.fitted?'Requires Rev I sense circuit':v.quality==='over-range'?
      'Outside monitor range':v.calibrated?'Calibrated ACC feed':'Uncalibrated supply estimate';
    $('footerState').textContent=s.reason+(s.configurationPendingSave?' · Save scheduled':'');
    if (!loaded) { loadSettings(s); loaded=true; }
  }
  async function poll() {
    clearTimeout(polling);
    if (!client) return;
    try { render(await client.request('status')); }
    catch (e) { disconnected(e.name==='AbortError'?'Controller timed out':e.message); }
    polling=setTimeout(poll,1500);
  }
  async function action(path, data, message) {
    if (!client || pending) return;
    pending=true; availability(!!state);
    try {
      await client.request(path,data);
      feedback(message);
      if (path==='config') {
        loaded=false;
        window.webkit?.messageHandlers?.vhosLighting?.postMessage({signal:Number(data.signal)});
      }
      await poll();
    } catch(e) { feedback(e.name==='AbortError'?'Request timed out; check controller status.':e.message); }
    finally { pending=false; availability(!!state); }
  }
  function config() {
    if (!state) throw new Error('Connect to the controller first.');
    const [red,green,blue]=rgb($('rgb').value);
    const signal=Number($('signal').value);
    const c={signal,'on-centi':centi($('enter').value,signal),'off-centi':centi($('exit').value,signal),
      red,green,blue,white:Number($('white').value),brightness:Math.max(1,Number($('brightness').value))};
    for (const k of cabinKeys) c[k]=$(k).type==='checkbox'?Number($(k).checked):Number($(k).value);
    return validateConfig(c);
  }
  $('connectForm').addEventListener('submit',e=>{ e.preventDefault();
    try { client=new ControllerClient($('relayKey').value); loaded=false; poll(); }
    catch(err) { feedback(err.message); }
  });
  for (const b of document.querySelectorAll('[data-tab]')) b.addEventListener('click',()=>{
    for (const el of document.querySelectorAll('[data-tab]')) el.setAttribute('aria-selected',String(el===b));
    for (const el of document.querySelectorAll('.panel')) el.hidden=el.id!==b.dataset.tab;
  });
  for (const b of document.querySelectorAll('[data-color]')) b.addEventListener('click',()=>{
    $('rgb').value=b.dataset.color;
    for (const el of document.querySelectorAll('[data-color]')) el.setAttribute('aria-pressed',String(el===b));
    preview(b.getAttribute('aria-label'));
  });
  for (const id of ['rgb','white','brightness']) $(id).addEventListener('input',()=>preview());
  $('signal').addEventListener('change',units);
  $('applyColor').addEventListener('click',()=>{const [red,green,blue]=rgb($('rgb').value);
    action('manual',{action:'set',red,green,blue,white:$('white').value,brightness:$('brightness').value},
      'Manual color requested. CAN automation stopped.'); });
  $('off').addEventListener('click',()=>action('manual',{action:'off'},'Off requested.'));
  for (const id of ['ruleForm','cabinForm']) $(id).addEventListener('submit',e=>{
    e.preventDefault(); try { action('config',config(),'Settings applied; save scheduled. Restart the CAN relay in VHOS.'); }
    catch(err) { feedback(err.message); }
  });
  $('voltageForm').addEventListener('submit',e=>{
    e.preventDefault(); const v=Object.fromEntries(new FormData(e.target));
    if (Number(v['high-adc-mv'])-Number(v['low-adc-mv'])<100 || Number(v['high-input-mv'])-Number(v['low-input-mv'])<1000)
      return feedback('Use two bench points at least 100 ADC mV and 1000 supply mV apart.');
    action('voltage',v,'Supply calibration applied; save scheduled.');
  });
  preview('Amber');
  if (typeof window.vhosNativeKey==='string') {
    document.body.classList.add('native');
    $('relayKey').value=window.vhosNativeKey;
    $('connectForm').requestSubmit();
  }
  window.addEventListener('pagehide',()=>{clearTimeout(polling); client=null;});
}
