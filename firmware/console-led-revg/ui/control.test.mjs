import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {centi,rgb,percent,validateConfig,ControllerClient} from './app.mjs';

test('actual UI conversion preserves supported units and rejects malformed values',()=>{
  assert.equal(centi('16383.75',0),1638375);
  assert.equal(centi('-40',2),-4000);
  assert.equal(centi('215',2),21500);
  assert.equal(centi('255',1),25500);
  assert.equal(centi('100',3),10000);
  assert.equal(centi('1',4),100); assert.equal(centi('0.5',4),50);
  for(const [v,s] of [['1e3',0],[' 20',0],['',0],['NaN',0],['16383.76',0],['-40.01',2],['1.01',4],['20',9]])
    assert.throws(()=>centi(v,s));
  assert.deepEqual(rgb('#ff8000'),[255,128,0]);
  assert.throws(()=>rgb('#fff')); assert.throws(()=>rgb('javascript:alert(1)'));
  assert.equal(percent(0),0); assert.equal(percent(255),100);
});
const valid=()=>({'signal':4,'on-centi':100,'off-centi':100,'red':255,'green':128,'blue':0,'white':0,
  'brightness':96,'tail-enabled':0,'tail-on-mv':0,'tail-off-mv':0,'dim-enabled':0,
  'dim-min-mv':0,'dim-max-mv':0,'dim-at-min-percent':100,'dim-at-max-percent':100});
test('rule validation enforces native limits, calibrated input spans and hysteresis',()=>{
  assert.equal(validateConfig(valid()).signal,4);
  for(const [key,value] of [['brightness',0],['red',256],['white',-1],['signal',5],['signal',1.5],
    ['on-centi',99],['off-centi',101],['tail-enabled',1],['dim-enabled',1],['dim-at-min-percent',101]])
    assert.throws(()=>validateConfig({...valid(),[key]:value}));
  const inverted={...valid(),'tail-enabled':1,'tail-on-mv':100,'tail-off-mv':300,
    'dim-enabled':1,'dim-min-mv':100,'dim-max-mv':1100,'dim-at-min-percent':100,'dim-at-max-percent':0};
  assert.doesNotThrow(()=>validateConfig(inverted));
});
test('the real static UI server serves assets and cannot masquerade as controller status',async()=>{
  const server=http.createServer(async(req,res)=>{
    const paths={'/':'index.html','/app.mjs':'app.mjs','/style.css':'style.css'};
    if(!paths[req.url]){res.writeHead(404);res.end('Not found');return;}
    const content=await readFile(new URL(paths[req.url],import.meta.url));
    res.writeHead(200,{'Content-Type':req.url.endsWith('.mjs')?'text/javascript':'text/plain'});res.end(content);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin='http://127.0.0.1:'+server.address().port;
  try{
    const page=await fetch(origin); assert.equal(page.status,200);
    const client=new ControllerClient('local-test-key-for-transport',origin);
    await assert.rejects(client.request('status'),/Controller unavailable \(404\)/);
    await assert.rejects(client.request('arbitrary-can-transmit'),/Unsupported controller operation/);
    assert.throws(()=>new ControllerClient('short'));
    assert.throws(()=>new ControllerClient('spaces are forbidden'));
  }finally{await new Promise(resolve=>server.close(resolve));}
});
