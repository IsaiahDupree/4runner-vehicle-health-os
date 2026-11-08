"""Copy a verified native result; package bytes only, with no EDA/CAD execution."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile
from verify_artifacts import verify

ROOT=Path(__file__).resolve().parent
NAME='vhos_rgbw_reva'

def copy_native(source,dest):
    raw=source.read_bytes();published=raw
    if source.suffix in ('.step','.kicad_sch'):
        published=re.sub(rb'[ \t]+(?=\r?$)',b'',raw,flags=re.MULTILINE)
        # Only EOL spaces/tabs change; preserve line endings and every token.
        assert re.sub(rb'\s+',b'',published)==re.sub(rb'\s+',b'',raw)
    dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(published)
    return {'sha256':hashlib.sha256(published).hexdigest(),'native_sha256':hashlib.sha256(raw).hexdigest(),'normalization':'TRAILING_EOL_SPACES_ONLY' if published!=raw else 'NONE'}

def publish(source):
    verified=verify(source)
    assert verified['digital_checks_clean'], 'Unfinished or failing electrical draft refused'
    assert set(verified.get('nominal_interferences_mm3',{}))<={'nominal_mating_plug_vs_original_lid'}, 'Revised assembly has a nominal interference'
    native=json.loads((source/'engineering-manifest.json').read_text())
    for name,expected in native['source_pins'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==expected,'Current source differs: '+name
    target=ROOT/'generated';target.mkdir(exist_ok=True);copied=[]
    names=[NAME+suffix for suffix in ('.kicad_pcb','.kicad_sch','.kicad_pro')]+[
        'VHOS.kicad_sym','fp-lib-table','sym-lib-table','BOM-DRAFT.csv','erc.json','drc.json',
        'connectivity-reconciliation.json','routed-width-audit.json','dsn-rule-binding.json',
        'footprint-sources.json','effective-netclasses.json','pcb-outline.json','circuit-design.json',
        'native-toolchain.json','schematic.pdf','pcb-layers.pdf','schematic-overview.png',
        'routed_shield_top.png','routed_shield_isometric.png']
    for path in (source/'VHOS_Connectors.pretty').glob('*.kicad_mod'):names.append(path.relative_to(source).as_posix())
    for name in names:
        dest=target/name;receipt=copy_native(source/name,dest)
        copied.append({'path':dest.relative_to(ROOT).as_posix(),'native_artifact':name,**receipt})
    for part in ('case_base_rgbw_reva','case_lid_rgbw_reva','carrier_rgbw_reva'):
        for suffix in ('.step','.stl'):
            name=part+suffix;dest=target/'case'/name;receipt=copy_native(source/name,dest)
            copied.append({'path':dest.relative_to(ROOT).as_posix(),'native_artifact':name,**receipt})
    shutil.copyfile(source/'mechanical-observation.json',target/'mechanical-observation.json')
    copied.append({'path':'generated/mechanical-observation.json','native_artifact':'mechanical-observation.json','sha256':hashlib.sha256((target/'mechanical-observation.json').read_bytes()).hexdigest()})
    evidence=ROOT/'evidence'
    (evidence/'final-verification.json').write_text(json.dumps(verified,indent=2)+'\n')
    (evidence/'published-artifacts.json').write_text(json.dumps({'source_set_sha256':verified['source_set_sha256'],'files':copied,'manufacturing_released':False},indent=2)+'\n')
    shutil.copyfile(source/'engineering-manifest.json',evidence/'final-engineering-manifest.json')
    # Keep downloaded reference geometry and native assembly binaries outside Git.
    archive=source.parent/'4runner-rgbw-reva-evaluation.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as z:
        for path in sorted(source.rglob('*')):
            if path.is_file():z.write(path,path.relative_to(source).as_posix())
        notes=(ROOT/'README.md').read_text().replace('generated/case/','.').replace('generated/','').replace('evidence/final-verification.json','review/final-verification.json')
        z.writestr('README.md',notes)
        z.write(ROOT/'verify_artifacts.py','verify_artifacts.py')
        for name in ('orion_client.py','publish_verified.py','verify_artifacts.py'):
            z.write(ROOT/name,'source/'+name)
        z.write(evidence/'final-verification.json','review/final-verification.json')
    result={'published_files':len(copied),'archive':str(archive),'archive_bytes':archive.stat().st_size,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'electrical_checks_clean':True,'manufacturing_released':False}
    (evidence/'package.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('artifact_dir',type=Path);args=parser.parse_args();publish(args.artifact_dir.resolve())
