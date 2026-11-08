"""Lightweight evidence check; never runs EDA, CAD, a renderer or a solver."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

def findings(value):
    if isinstance(value,dict):
        if 'severity' in value and 'type' in value:yield value
        for item in value.values():yield from findings(item)
    elif isinstance(value,list):
        for item in value:yield from findings(item)

def verify(root):
    manifest=json.loads((root/'engineering-manifest.json').read_text())
    assert manifest['execution_device']=='orion'
    assert manifest['params']['evaluation_only'] is True
    assert manifest['manufacturing_released'] is False
    assert manifest['vehicle_connection_released'] is False
    assert manifest['physical_fit_verified'] is False
    for row in manifest['artifacts']:
        path=root/row['name']
        assert path.resolve().is_relative_to(root.resolve()) and not path.is_symlink()
        assert path.stat().st_size==row['bytes'],row['name']
        assert hashlib.sha256(path.read_bytes()).hexdigest()==row['sha256'],row['name']
    for name,expected in manifest['source_pins'].items():
        assert hashlib.sha256((root/'source'/name).read_bytes()).hexdigest()==expected,name
    pin=hashlib.sha256(json.dumps(manifest['source_pins'],sort_keys=True,separators=(',',':')).encode()).hexdigest()
    assert pin==manifest['source_set_sha256']
    counts={}
    for name in ('erc.json','drc.json'):
        found=list(findings(json.loads((root/name).read_text())))
        counts[name]=len(found)
    connectivity=json.loads((root/'connectivity-reconciliation.json').read_text())
    assert connectivity['schematic_matches_pcb'] is True
    assert connectivity['header_positions_match_official_nominal_reference']==32
    assert connectivity['physical_header_match_verified'] is False
    if (root/'routed-width-audit.json').exists():
        widths=json.loads((root/'routed-width-audit.json').read_text())
        assert widths['accepted_against_declared_minimums'] is True
        for item in widths['tracks']:assert item['minimum_width_mm']>=item['required_minimum_mm']-1e-6,item['net']
    result={'artifact_files_verified':len(manifest['artifacts']),'source_set_sha256':pin,'electrical_findings':counts,'digital_checks_clean':not any(counts.values()),'physical_fit_verified':False,'manufacturing_released':False}
    if (root/'mechanical-observation.json').exists():
        mechanical=json.loads((root/'mechanical-observation.json').read_text())
        assert mechanical['physical_fit_verified'] is False
        assert mechanical['manufacturing_released'] is False
        for part in mechanical['printable_parts']:assert part['valid'] and part['solids']==1 and part['mesh_closed']
        result['nominal_interferences_mm3']={k:v['intersection_mm3'] for k,v in mechanical['checks'].items() if v['intersection_mm3']>1e-6}
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('artifact_dir',type=Path);args=parser.parse_args()
    print(json.dumps(verify(args.artifact_dir.resolve()),indent=2))
