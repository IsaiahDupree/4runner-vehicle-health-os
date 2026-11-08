"""Closed, source-pinned Orion KiCad build/routing lane for the RGBW shield."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
JOB_TYPE='pcb.vhos_rgbw_engineering'
FILES=('engineering_job.py','native_pcb.py','circuit.py','mechanical_audit.py','run_isolated_engineering.py','engineering-inputs.json')
KICAD=Path('C:/Program Files/KiCad/10.0/bin')
CLI=KICAD/'kicad-cli.exe'
PYTHON=KICAD/'python.exe'
ROUTER=Path('C:/PCBToolchains/java25/jdk-25.0.4.1+1-jre/bin/java.exe')
ROUTER_JAR=Path('C:/PCBToolchains/freerouting/2.5.0/freerouting-2.5.0.jar')
NAME='vhos_rgbw_reva'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def pins():return {name:sha(ROOT/name) for name in FILES}
def source_pin():return hashlib.sha256(json.dumps(pins(),sort_keys=True,separators=(',',':')).encode()).hexdigest()
def validate(p):
    if set(p)!={'expected_source_set_sha256','stage','timeout_sec','evaluation_only'}:raise ValueError('exact bounded engineering request required')
    if p['evaluation_only'] is not True or p['expected_source_set_sha256']!=source_pin():raise ValueError('evaluation flag or source pin mismatch')
    if p['stage'] not in ('build','route','finish'):raise ValueError('fixed build/route/finish stage required')
    if type(p['timeout_sec']) is not int or not 60<=p['timeout_sec']<=900:raise ValueError('bounded timeout 60..900 required')
    inputs=json.loads((ROOT/'engineering-inputs.json').read_text())
    if inputs['contract']!='vhos_rgbw_eval_reva_v1':raise ValueError('fixed input contract required')
    if {a['name'] for a in inputs['assets']}!={'case_base.step','case_lid.step','ESP32-S3-WROOM-1.step'}:raise ValueError('fixed mechanical input set required')
    for item in inputs['assets']+[inputs['pcb_input_connector_model']]:
        path=ROOT/'inputs'/item['name']
        if path.is_symlink() or not path.is_file() or path.stat().st_size!=item['bytes'] or sha(path)!=item['sha256']:raise ValueError('mechanical input missing or changed '+item['name'])
    return dict(p)
def register(m):
    m.JOB_TYPES[JOB_TYPE]={'runtime':'python','script':Path(__file__),'description':'Native KiCad RGBW shield evaluation source, routing, reports and nominal-fit audit; no fabrication or installation release.',
        'params':{'expected_source_set_sha256':'fixed source set pin','stage':'build/route/finish','timeout_sec':'integer 60..900','evaluation_only':'true'}}

def run(p,out):
    if platform.system()!='Windows' or platform.node().split('.')[0].casefold()!='orion':raise RuntimeError('Orion Windows required')
    validate(p);out.mkdir(parents=True,exist_ok=True);started=time.monotonic();commands=[]
    snapshot=out/'source';snapshot.mkdir()
    for name in FILES:shutil.copyfile(ROOT/name,snapshot/name)
    for path in (CLI,PYTHON,ROUTER,ROUTER_JAR):
        if not path.is_file():raise RuntimeError('missing installed tool '+str(path))
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',OMP_NUM_THREADS='2',OPENBLAS_NUM_THREADS='2')
    def call(name,args,limit=180,allowed=(0,)):
        remaining=int(p['timeout_sec']-(time.monotonic()-started))
        if remaining<=0:raise TimeoutError('job deadline reached')
        path=out/(name+'.log')
        with path.open('wb') as stream:
            result=subprocess.run(list(map(str,args)),cwd=out,env=env,stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,timeout=min(limit,remaining))
        row={'name':name,'argv':list(map(str,args)),'exit_code':result.returncode,'log_sha256':sha(path)};commands.append(row)
        (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
        if result.returncode not in allowed:raise RuntimeError(name+' failed with '+str(result.returncode))
    try:
        call('native-build',[PYTHON,'-I','-B',ROOT/'native_pcb.py','build','--out',out])
        sch=out/(NAME+'.kicad_sch');pcb=out/(NAME+'.kicad_pcb')
        call('schematic-netlist',[CLI,'sch','export','netlist','--format','kicadxml','-o',out/'schematic.net.xml',sch])
        call('reconcile-build',[PYTHON,'-I','-B',ROOT/'native_pcb.py','reconcile','--out',out])
        call('erc',[CLI,'sch','erc','--format','json','--severity-all','-o',out/'erc.json',sch])
        call('schematic-pdf',[CLI,'sch','export','pdf','-o',out/'schematic.pdf',sch])
        if p['stage'] in ('route','finish'):
            call('router',[ROUTER,'-Xmx2g','-XX:ActiveProcessorCount=2','-Djava.awt.headless=true','-jar',ROUTER_JAR,
                '-de',out/'shield.dsn','-do',out/'shield.ses','--router.autorouter.max_passes=80',
                '--router.copper_to_edge_clearance_um=350',
                '--router.automatic_neckdown=false','--router.neck_width_um=0','--router.fanout.enabled=false',
                '--router.strict_drc=true','--router.optimizer.max_passes=2','-mt','1','-da','-dl',
                '--gui.enabled=false','--api_server.enabled=false','--router.result_json='+str(out/'router-result.json'),
                '--user_data_path='+str(out/'router-state')],240)
            call('native-import',[PYTHON,'-I','-B',ROOT/'native_pcb.py','import','--out',out])
            call('reconcile-routed',[PYTHON,'-I','-B',ROOT/'native_pcb.py','reconcile','--out',out])
        call('drc',[CLI,'pcb','drc','--format','json','--severity-all','--schematic-parity','-o',out/'drc.json',pcb])
        if p['stage']=='finish':
            call('schematic-svg',[CLI,'sch','export','svg','-o',out/'schematic-svg',sch])
            call('pcb-pdf',[CLI,'pcb','export','pdf','--layers','F.Cu,B.Cu,F.SilkS,Edge.Cuts','--mode-multipage','-o',out/'pcb-layers.pdf',pcb])
            call('pcb-step',[CLI,'pcb','export','step','--subst-models','--no-dnp','--user-origin','100x153.34mm','-f','-o',out/'routed_shield.step',pcb],180)
            call('pcb-render-top',[CLI,'pcb','render','--width','1600','--height','1100','--quality','basic','--background','opaque','--side','top','-o',out/'routed_shield_top.png',pcb],120)
            call('pcb-render-iso',[CLI,'pcb','render','--width','1600','--height','1100','--quality','basic','--background','opaque','--rotate','35,0,30','-o',out/'routed_shield_isometric.png',pcb],120)
            call('mechanical-audit',[sys.executable,'-I','-B',ROOT/'mechanical_audit.py','--out',out],150)
        return {'stage':p['stage'],'engineering_status':'EVALUATION_ONLY','manufacturing_released':False}
    finally:
        validate(p)
        names=[f for f in out.rglob('*') if f.is_file() and f.name!='engineering-manifest.json']
        manifest={'contract':'vhos_rgbw_eval_reva_v1','execution_device':'orion','source_pins':pins(),'source_set_sha256':source_pin(),'params':p,
            'runtimes':{k:{'path':str(v),'sha256':sha(v)} for k,v in [('kicad_cli',CLI),('kicad_python',PYTHON),('router_java',ROUTER),('router_jar',ROUTER_JAR)]},
            'elapsed_sec':round(time.monotonic()-started,3),'artifacts':[{'name':f.relative_to(out).as_posix(),'bytes':f.stat().st_size,'sha256':sha(f)} for f in names],
            'physical_fit_verified':False,'manufacturing_released':False,'vehicle_connection_released':False}
        (out/'engineering-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--params',type=Path,required=True);parser.add_argument('--out',type=Path,required=True);a=parser.parse_args()
    print(json.dumps(run(json.loads(a.params.read_text()),a.out.resolve())))
if __name__=='__main__':main()
