"""Verify real downloaded CAD/data/Orion evidence; no CAD work on the Mac."""
from pathlib import Path
import argparse,csv,hashlib,json
ROOT=Path(__file__).resolve().parent

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--asset-root',type=Path,required=True);a=p.parse_args()
 manifest=json.loads((ROOT/'reference-models.json').read_text())
 refs=manifest['models']+json.loads((ROOT/'supporting-downloads.json').read_text())['files']
 assert len(manifest['models'])==3 and manifest['physical_fit_verified'] is False and manifest['manufacturing_released'] is False
 for item in refs:
  f=a.asset_root/'references'/item['name']
  assert f.is_file() and f.stat().st_size==item['bytes'] and sha(f)==item['sha256'],item['name']
 j=json.loads((ROOT/'evidence/orion-job.json').read_text())['result']
 assert j['status']=='succeeded' and j['exit_code']==0 and j['job_type']=='cad.vhos_console_connector_inspection'
 assert j['params']['expected_source_sha256']==sha(ROOT/'inspect_models_job.py')
 assert j['params']['expected_manifest_sha256']==sha(ROOT/'reference-models.json')
 im=json.loads((ROOT/'evidence/inspection-manifest.json').read_text())
 for item in im['artifacts']:
  f=a.asset_root/'inspection'/item['name']
  assert f.is_file() and f.stat().st_size==item['bytes'] and sha(f)==item['sha256'],item['name']
 assert im['physical_fit_verified'] is False and im['manufacturing_released'] is False
 n=json.loads((ROOT/'evidence/native_inspection.json').read_text())
 assert len(n['models'])==3 and all(x['valid'] for x in n['models']) and n['physical_fit_verified'] is False
 size=n['models'][0]['size_mm'];assert all(abs(x-y)<0.001 for x,y in zip(size,[21.1,21.4,38]))
 assert n['models'][0]['mesh_closed'] is False  # preserved observation, no printable-connector claim
 h=json.loads((ROOT/'uno-r3-reference-header-coordinates.json').read_text())
 assert sum(x['count'] for x in h['headers'])==32 and len(h['mounting_holes'])==4 and h['physical_fit_verified'] is False
 rows=list(csv.DictReader((ROOT/'PINMAP-DRAFT.csv').open()))
 assert len(rows)==6 and {int(x['proposed_pcb_cavity']) for x in rows}==set(range(1,7))
 assert all(x['physical_vehicle_connection']=='UNCONNECTED' and x['release_status']=='CONDITIONAL_DESIGN_DRAFT' for x in rows)
 print(json.dumps({'status':'pass','download_hashes':len(refs),'native_models':3,'draft_map_rows':6,'physical_fit_verified':False,'manufacturing_released':False}))
if __name__=='__main__': main()
