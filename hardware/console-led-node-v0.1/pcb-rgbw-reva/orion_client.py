"""Bounded Mac orchestration only; EDA/CAD execute on authenticated Orion."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from urllib.request import Request,urlopen

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
import engineering_job as job
REMOTE='C:/orion/projects/vhos-rgbw-shield-reva-20261107'
ARTIFACTS=ROOT.parents[3]/'artifacts/4runner-rgbw-shield-reva-2026-11-08'
def call(topic,body):
    token=(Path.home()/'.orion-control/token').read_text().strip()
    with urlopen(Request('http://127.0.0.1:8853/api/services/orion/'+topic,data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}),timeout=30) as response:return json.loads(response.read())
def save(path,obj):path.write_text(json.dumps(obj,indent=2)+'\n')
def issues(value):
    result=[]
    if isinstance(value,dict):
        if 'severity' in value and 'type' in value:result.append(value)
        for v in value.values():result.extend(issues(v))
    elif isinstance(value,list):
        for v in value:result.extend(issues(v))
    return result
def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['submit','status','fetch']);parser.add_argument('id');parser.add_argument('--stage',choices=['build','route','finish'],default='build');a=parser.parse_args()
    if not a.id.replace('-','').isalnum() or len(a.id)>60:raise ValueError('bounded alphanumeric task identity required')
    evidence=ROOT/'evidence';evidence.mkdir(exist_ok=True)
    submission=evidence/('submission-'+a.id+'.json')
    if a.action=='submit':
        if submission.exists():raise ValueError('existing request identity refused; inspect status')
        for f in ROOT.glob('*.py'):compile(f.read_text(),str(f),'exec')
        inputs=json.loads((ROOT/'engineering-inputs.json').read_text())
        roots=[ROOT/'inputs',ROOT.parent/'cad',ROOT.parents[3]/'artifacts/4runner-console-cad-2026-11-07']
        assets=[]
        for item in inputs['assets']+[inputs['pcb_input_connector_model']]:
            candidates=[folder/item['name'] for folder in roots]
            path=next((f for f in candidates if f.is_file() and not f.is_symlink() and f.stat().st_size==item['bytes'] and hashlib.sha256(f.read_bytes()).hexdigest()==item['sha256']),None)
            if path is None:raise FileNotFoundError('Place the source-pinned reference asset in '+str(ROOT/'inputs'/item['name']))
            assets.append(path)
        subprocess.run(['scp','-q','-o','BatchMode=yes',*map(str,assets),'orion:'+REMOTE+'/inputs/'],check=True,timeout=30)
        subprocess.run(['scp','-q','-o','BatchMode=yes',*[str(ROOT/n) for n in job.FILES],'orion:'+REMOTE+'/'],check=True,timeout=30)
        req={'actor':'vhos-rgbw-shield','request_id':'vhos-rgbw-'+a.id,'params':{'job_type':job.JOB_TYPE,'params':{'expected_source_set_sha256':job.source_pin(),'stage':a.stage,'timeout_sec':900 if a.stage=='finish' else 360,'evaluation_only':True}}}
        save(ROOT/('request-'+a.id+'.json'),req);res=call('modeling.submit',req);save(submission,res)
        print(json.dumps({k:res['result'].get(k) for k in ['job_id','status','params']}));return
    prev=json.loads(submission.read_text())['result'];res=call('modeling.status',{'actor':'vhos-rgbw-shield','params':{'job_id':prev['job_id']}});save(evidence/('status-'+a.id+'.json'),res);current=res['result']
    print(json.dumps({k:current.get(k) for k in ['job_id','status','duration_sec','error']}))
    if a.action=='fetch':
        if current['status'] not in ('succeeded','failed','cancelled'):raise RuntimeError('terminal job required')
        folder=ARTIFACTS/a.id;folder.mkdir(parents=True,exist_ok=True)
        subprocess.run(['scp','-q','-r','-o','BatchMode=yes','orion:'+current['job_dir'].replace('\\','/')+'/out/.',str(folder)],check=True,timeout=60)
        for row in current['artifacts']:
            path=folder/row['name']
            if path.stat().st_size!=row['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:raise RuntimeError('artifact mismatch '+row['name'])
        print('Verified artifacts: '+str(len(current['artifacts']))+' in '+str(folder))
        from collections import Counter
        for name in ('erc.json','drc.json'):
            path=folder/name
            if path.exists():
                report=json.loads(path.read_text());print(name,dict(Counter(x['type'] for x in issues(report))))
if __name__=='__main__':main()
