"""Verify actual native artifacts and derive the complete 75-position factory package."""
import argparse
import copy
import csv
from decimal import Decimal
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import zipfile

ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'pcb-rgbw-revh'
TEXT={'.json','.csv','.kicad_pcb','.kicad_sch','.kicad_pro','.kicad_mod','.kicad_sym',
      '.gtl','.gbl','.g1','.g2','.gts','.gbs','.gto','.gbo','.gtp','.gm1','.drl','.gbrjob'}
ADDED={'R40','R41','R42','R43','R44','U12','D10','C32'}


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def read(p):return json.loads(p.read_text())

def checked(folder):
    job=read(folder/'status.json')
    if job['status']!='succeeded' or job.get('error'):raise ValueError('Successful native job required')
    for item in job['artifacts']:
        p=folder/'output'/item['name']
        if p.stat().st_size!=item['bytes'] or sha(p)!=item['sha256']:raise ValueError('Native artifact changed: '+item['name'])
    return job


def rows(p):
    with p.open(newline='') as f:return list(csv.DictReader(f))


def write_csv(p,data,columns):
    p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=columns,lineterminator='\n');w.writeheader();w.writerows(data)


def publish(pcb_folder,case_folder):
    jobs={'pcb':checked(pcb_folder),'case':checked(case_folder)}
    pcb,case=pcb_folder/'output',case_folder/'output'
    findings=read(pcb/'job-result.json')['native_findings']
    fit=read(case/'gland-fit.json');slices=read(case/'support-free.json')
    if any(findings.values()) or not fit['passed'] or not slices['supports_disabled_all_parts_passed']:
        raise ValueError('Native PCB, fit or slicing failed')
    case_input=read(case_folder/'stage/job-inputs.json')['inputs/routed_shield.step']
    if case_input!=sha(pcb/'routed_shield.step'):raise ValueError('Case used a different PCB STEP')
    spec=importlib.util.spec_from_file_location('revh_board_parser',BASE/'publish_handoff.py')
    parser=importlib.util.module_from_spec(spec);spec.loader.exec_module(parser)
    parts=parser.board_parts(pcb/'vhos_rgbw_revi.kicad_pcb')
    native=read(pcb/'native-parts.json')
    for ref,part in parts.items():
        for key in ('mpn','footprint','x_mm','y_mm','rotation_deg'):
            if native[ref][key]!=part[key]:raise ValueError('Native metadata differs: '+ref+'.'+key)
    actual={ref for ref,p in parts.items() if p['mpn'] and not ref.startswith(('TP','MH'))}
    if len(actual)!=75 or not ADDED<=actual:raise ValueError('Expected all 75 populated positions')
    step=(pcb/'routed_shield.step').read_text()
    if any(not re.search(r"NEXT_ASSEMBLY_USAGE_OCCURRENCE\('[^']*','"+ref+r"'",step) for ref in ADDED):
        raise ValueError('Added sensor component missing from actual exported STEP')
    published={}
    def save(source,relative):
        target=ROOT/relative;target.parent.mkdir(parents=True,exist_ok=True)
        raw=source.read_bytes();data=raw.replace(b'\r\n',b'\n') if source.suffix in TEXT or source.name.endswith('lib-table') else raw
        target.write_bytes(data)
        published[relative]={'sha256':sha(target),'native_sha256':hashlib.sha256(raw).hexdigest(),
            'normalization':'CRLF to LF' if raw!=data else 'none'}
    for name in ['vhos_rgbw_revi.kicad_pcb','vhos_rgbw_revi.kicad_pro','vhos_rgbw_revi.kicad_sch',
      'VHOS.kicad_sym','fp-lib-table','sym-lib-table','native-parts.json','erc.json','drc.json','copper-audit.json',
      'voltage-native-audit.json','voltage-change.json','routed_shield.step','schematic.pdf','board.png']:
        save(pcb/name,'generated/'+name)
    for directory in ('VHOS_RevB.pretty','models','fabrication'):
        for p in (pcb/directory).rglob('*'):
            if p.is_file():save(p,'generated/'+p.relative_to(pcb).as_posix())
    for name in ['4Runner_RevI_Terminal_Assembly.FCStd','4Runner_RevI_Terminal_Assembly.step','gland-fit.json',
      'support-free.json','wire-cut-routing.csv','case_base.step','case_base.stl','case_lid.step','case_lid.stl',
      'gland_plate.step','gland_plate.stl']:
        save(case/name,'generated/'+name)
    for name in ['terminal_design.py','terminal_pcb.py']:
        if sha(ROOT/name)!=sha(pcb/'source'/name):raise ValueError('Runtime source differs: '+name)
    if sha(ROOT/'terminal_cad.py')!=sha(case/'source/terminal_cad.py'):raise ValueError('CAD source differs')
    catalog=read(BASE/'jlcpcb/catalog-live.json');by_mpn={r['mpn']:r for r in catalog['rows']}
    bom=[];cpl=[];derived=[];subtotal=Decimal(0)
    for old in rows(BASE/'jlcpcb/BOM.csv'):
        refs=sorted([r for r in actual if parts[r]['mpn']==old['Comment']],key=lambda s:(re.sub(r'\d','',s),int(re.search(r'\d+',s)[0])))
        if not refs:raise ValueError('Existing SKU disappeared')
        footprints={parts[r]['footprint'].split(':')[-1] for r in refs}
        if footprints!={old['Footprint']}:raise ValueError('Factory footprint mismatch')
        line=dict(old);line['Designator']=','.join(refs);bom.append(line)
        capture=copy.deepcopy(by_mpn[old['Comment']]);capture['references']=line['Designator'];capture['quantity_per_board']=len(refs)
        material=Decimal(str(capture['unit_usd_at_one_board_quantity']))*len(refs)
        capture['one_board_material_usd']=float(material);derived.append(capture);subtotal+=material
        for ref in refs:
            p=parts[ref];x,y=p['x_mm'],p['y_mm']
            if ref.startswith('JT'):x-=.05;y+=2.54
            cpl.append({'Designator':ref,'Mid X':f'{x:.6f}mm','Mid Y':f'{-y:.6f}mm',
                        'Rotation':f'{p["rotation_deg"]%360:.6f}','Layer':'T'})
    if sum(len(b['Designator'].split(',')) for b in bom)!=75 or len(cpl)!=75 or len(bom)!=31:raise ValueError('Factory coverage mismatch')
    write_csv(ROOT/'jlcpcb/BOM.csv',bom,['Comment','Designator','Footprint','JLCPCB Part #'])
    write_csv(ROOT/'jlcpcb/CPL.csv',cpl,['Designator','Mid X','Mid Y','Rotation','Layer'])
    (ROOT/'jlcpcb/catalog-derived.json').write_text(json.dumps({'basis':'Retained Nov 21 manufacturer/stock captures; counts derived from actual Rev I PCB',
      'source_catalog_sha256':sha(BASE/'jlcpcb/catalog-live.json'),'rows':derived,'populated_positions':75,
      'unique_skus':31,'material_subtotal_usd_at_one_board_quantity':float(subtotal),'finished_product_quote_verified':False},indent=2)+'\n')
    save(BASE/'WIRE-REGISTER.csv','WIRE-REGISTER.csv')
    gerbers=ROOT/'generated/fabrication/gerbers'
    with zipfile.ZipFile(ROOT/'generated/4Runner_RGBW_RevI_Gerbers.zip','w',compression=zipfile.ZIP_STORED) as z:
        for p in sorted(gerbers.iterdir()):
            if p.is_file():z.write(p,p.name)
    with zipfile.ZipFile(ROOT/'generated/4Runner_RGBW_RevI_Gerbers.zip') as z:
        if z.testzip():raise ValueError('Gerber archive CRC error')
    for relative in ['WIRE-REGISTER.csv','jlcpcb/BOM.csv','jlcpcb/CPL.csv','jlcpcb/catalog-derived.json',
      'generated/4Runner_RGBW_RevI_Gerbers.zip','terminal_design.py','terminal_pcb.py','terminal_cad.py']:
        published.setdefault(relative,{'sha256':sha(ROOT/relative),'normalization':'none'})
    report={'revision':'I','populated_board_count':1,'factory_populated_positions':75,'unique_skus':31,
      'kicad_findings':findings,'case_and_wire_checks_passed':sum(c['pass'] for c in fit['checks']),
      'tool_axes_passed':sum(c['pass'] for c in fit['tool_axes']),
      'supports_off_slices_passed':sum(c['pass'] and c['support_segments']==0 for c in slices['offline_slices'].values()),
      'added_sensor_references':sorted(ADDED),'all_added_parts_in_native_step':True,'case_input_step_sha256':case_input,
      'native_jobs':{k:{field:j.get(field) for field in ('job_id','status','completed_at','duration_sec','params')} for k,j in jobs.items()},
      'published_files':published,'physical_qualification':False,'manufacturing_released':False}
    (ROOT/'generated/verification.json').write_text(json.dumps(report,indent=2)+'\n')
    return {k:v for k,v in report.items() if k not in ('published_files','native_jobs')}


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--pcb',type=Path,required=True);p.add_argument('--case',type=Path,required=True)
    a=p.parse_args();print(json.dumps(publish(a.pcb,a.case),indent=2))
