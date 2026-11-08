"""Bounded file/mesh integrity checks; does not run CAD or contact a vehicle."""
from __future__ import annotations
import ast
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import struct

ROOT=Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mesh_observation(path):
    data=path.read_bytes()
    if len(data)<84: raise ValueError('short STL')
    count=struct.unpack_from('<I',data,80)[0]
    if not 1<=count<=20000 or len(data)!=84+50*count:
        raise ValueError('bounded binary STL required')
    edges=Counter();vertices=[];volume=0.0
    for i in range(count):
        points=[struct.unpack_from('<3f',data,84+50*i+12+12*j) for j in range(3)]
        a,b,c=points
        volume+=(a[0]*(b[1]*c[2]-b[2]*c[1])+a[1]*(b[2]*c[0]-b[0]*c[2])+a[2]*(b[0]*c[1]-b[1]*c[0]))/6
        vertices.extend(points)
        for j in range(3): edges[tuple(sorted((points[j],points[(j+1)%3])))]+=1
    if any(n!=2 for n in edges.values()): raise ValueError('mesh edge not shared by exactly two facets')
    if volume<=0: raise ValueError('mesh signed volume must be positive')
    return {'triangles':count,'edge_pairs':len(edges),'signed_volume_mm3':volume,
            'bbox_mm':[max(p[j] for p in vertices)-min(p[j] for p in vertices) for j in range(3)]}


def main():
    inputs=json.loads((ROOT/'design-inputs.json').read_text())
    manifest=json.loads((ROOT/'cad/manifest.json').read_text())
    request=json.loads((ROOT/'request.json').read_text())['params']
    assert request==manifest['request']
    assert request['expected_source_sha256']==digest(ROOT/'case_job.py')
    assert request['expected_inputs_sha256']==digest(ROOT/'design-inputs.json')
    assert not any(inputs['release'].values())
    assert inputs['factory_pin_assignments'] is None
    assert manifest['execution_device']=='orion' and manifest['status']=='FIT_CHECK_ONLY'
    assert manifest['manufacturing_released'] is False and manifest['print_started'] is False
    job=json.loads((ROOT/'evidence/orion-job.json').read_text())['result']
    assert job['status']=='succeeded' and job['exit_code']==0 and job['params']==request
    for entry in manifest['artifacts']:
        name=entry['name'];assert Path(name).name==name
        path=ROOT/'cad'/name
        assert path.is_file() and path.stat().st_size==entry['bytes'] and digest(path)==entry['sha256']
    native=manifest['observation']
    assert all(abs(v)<=.01 for v in native['retained_solid_checks'].values())
    observations={}
    for name,n in native['parts'].items():
        m=mesh_observation(ROOT/'cad'/(name+'.stl'))
        assert n['valid'] is True and n['solids']==1 and n['mesh_closed'] is True
        assert all(abs(x-y)<.02 for x,y in zip(m['bbox_mm'],n['bbox_mm']))
        assert abs(m['signed_volume_mm3']-n['volume_mm3'])/n['volume_mm3']<.003
        observations[name]=m
    assert all(abs(x-y)<.02 for x,y in zip(observations['case_base']['bbox_mm'],[130,86,42]))
    assert all(abs(x-y)<.02 for x,y in zip(observations['case_lid']['bbox_mm'],[116,86,3]))
    for name in ('BOM.csv','PINMAP.csv'):
        rows=list(csv.DictReader((ROOT/name).open(newline='')))
        assert rows and all(None not in row and None not in row.values() for row in rows)
    for name in ('case_job.py','run_isolated_case.py'):
        ast.parse((ROOT/name).read_text())
    result={'ok':True,'verification_scope':'source/retained-artifact integrity and independent STL topology, dimensions and volume',
            'orion_job_id':job['job_id'],'cad_artifact_count':len(manifest['artifacts']),
            'meshes':observations,'physical_fit_verified':False,'electrical_design_released':False,'print_started':False}
    print(json.dumps(result,indent=2))
    return 0


if __name__=='__main__':
    raise SystemExit(main())
