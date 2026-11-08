"""Verify actual downloaded assets and retained Orion metadata; no CAD on Mac."""
from __future__ import annotations
import argparse
import ast
import hashlib
import json
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--asset-root',type=Path,required=True)
    args=parser.parse_args()
    references=json.loads((ROOT/'reference-models.json').read_text())
    request=json.loads((ROOT/'inspection-request.json').read_text())['params']
    assert request['expected_source_sha256']==sha(ROOT/'inspect_models_job.py')
    assert request['expected_manifest_sha256']==sha(ROOT/'reference-models.json')
    job=json.loads((ROOT/'evidence/orion-job.json').read_text())['result']
    assert job['status']=='succeeded' and job['exit_code']==0 and job['params']==request
    obs=json.loads((ROOT/'evidence/native_inspection.json').read_text())
    assert obs['units']=='mm after native STEP import' and obs['geometry_repaired'] is False
    assert obs['catalog_only_not_installed_assembly'] is True and len(obs['models'])==6
    for item,result in zip(references['models'],obs['models']):
        path=args.asset_root/item['name']
        assert path.name==item['name'] and path.is_file() and not path.is_symlink()
        assert path.stat().st_size==item['bytes'] and sha(path)==item['sha256']
        assert path.read_bytes()[:100].find(b'ISO-10303-21')>=0
        assert result['name']==item['name'] and result['valid'] is True and result['solids']>0
        assert result['physical_match_verified'] is False
        assert all(0<d<150 for d in result['tessellated_size_mm'])
    module=obs['models'][3]['tessellated_size_mm']
    assert all(abs(x-y)<.01 for x,y in zip(module,[18,25.5,3.1]))
    insert=obs['models'][4]['tessellated_size_mm']
    assert all(abs(x-y)<.02 for x,y in zip(insert,[4.6,4.6,5.7]))
    support=json.loads((ROOT/'supporting-downloads.json').read_text())
    for name,entry in [('Molex_43045-0600_manufacturer_3D.pdf',support['manufacturer_pdf']),
                       (support['diyables_wiring_asset']['name'],support['diyables_wiring_asset']),
                       (support['kicad_header_footprint']['name'],support['kicad_header_footprint'])]:
        p=args.asset_root/name;assert p.stat().st_size==entry['bytes'] and sha(p)==entry['sha256']
    with zipfile.ZipFile(args.asset_root/support['diyables_wiring_asset']['name']) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist())==set(support['diyables_wiring_asset']['files'])
    output=json.loads((args.asset_root/'inspection/inspection-manifest.json').read_text())
    assert output['request']==request and output['execution_device']=='orion'
    assert output['installed_assembly_verified'] is False and output['manufacturing_released'] is False
    for item in output['artifacts']:
        p=args.asset_root/'inspection'/item['name']
        assert p.stat().st_size==item['bytes'] and sha(p)==item['sha256']
    for name in ('inspect_models_job.py','run_isolated_models.py','verify_references.py'):
        ast.parse((ROOT/name).read_text())
    print(json.dumps({'ok':True,'reference_steps':6,'supporting_files':3,'orion_job_id':job['job_id'],
                      'native_step_imports_valid':6,'source_and_artifact_hashes_verified':True,
                      'model_mating_or_physical_fit_claim':False},indent=2))


if __name__=='__main__':
    main()
