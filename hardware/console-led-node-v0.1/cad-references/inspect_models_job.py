"""Inspect six byte-pinned reference STEP models on native Orion, without healing."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
JOB_TYPE='cad.vhos_console_reference_inspection'
CONTRACT='vhos_console_cad_references_v1'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest():
    path=ROOT/'reference-models.json'
    if path.is_symlink() or not path.is_file(): raise ValueError('regular pinned manifest required')
    value=json.loads(path.read_text())
    if value.get('contract')!=CONTRACT or len(value.get('models',[]))!=6:
        raise ValueError('exact six-model reference contract required')
    for item in value['models']:
        name=item['name']
        if Path(name).name!=name or Path(name).suffix.lower() not in ('.step','.stp'):
            raise ValueError('only regular named STEP inputs admitted')
        if not 1<=item['bytes']<=16_000_000: raise ValueError('bounded reference size required')
    return value


def validate(p):
    keys={'expected_source_sha256','expected_manifest_sha256','research_only','timeout_sec'}
    if not isinstance(p,dict) or set(p)!=keys or p['research_only'] is not True:
        raise ValueError('source/manifest hashes, research_only and bounded timeout required')
    if p['expected_source_sha256']!=sha(Path(__file__)) or p['expected_manifest_sha256']!=sha(ROOT/'reference-models.json'):
        raise ValueError('registered source/manifest drift')
    if type(p['timeout_sec']) is not int or not 60<=p['timeout_sec']<=600:
        raise ValueError('integer timeout in 60..600 required')
    manifest()
    return dict(p)


def register(m):
    m.JOB_TYPES[JOB_TYPE]={'runtime':'python','script':Path(__file__),
        'description':'Read six fixed STEP files, report units/bounds/validity, and export reference-view meshes/FCStd; no repair or assembly fit claim.',
        'params':{'expected_source_sha256':'registered source hash','expected_manifest_sha256':'registered manifest hash',
                  'research_only':'true','timeout_sec':'integer 60..600'}}


NATIVE=r'''
import os,json,FreeCAD as App,Part,MeshPart
from FreeCAD import Vector as V
OUT=__OUT__
INPUT=__INPUT__
MODELS=__MODELS__
doc=App.newDocument('Console_CAD_Reference_Catalog')
observations=[]
for i,entry in enumerate(MODELS):
    shape=Part.Shape();shape.read(os.path.join(INPUT,entry['name']))
    b=shape.BoundBox
    obs={'name':entry['name'],'source_class':entry['source_class'],'valid':shape.isValid(),'solids':len(shape.Solids),'shells':len(shape.Shells),'faces':len(shape.Faces),'volume_mm3':shape.Volume,'bounds_mm':[b.XMin,b.YMin,b.ZMin,b.XMax,b.YMax,b.ZMax],'size_mm':[b.XLength,b.YLength,b.ZLength],'physical_match_verified':False}
    if shape.isNull() or max(b.XLength,b.YLength,b.ZLength)>150 or shape.Volume<=0:
        raise ValueError('invalid or implausible imported reference '+entry['name'])
    original=doc.addObject('PartDesign::Feature','Reference_'+str(i));original.Label=entry['label']+' ['+entry['source_class']+']';original.Shape=shape
    # Separate positions are a catalog arrangement, not installed/mated coordinates.
    original.Placement.Base=V((i%3)*38-b.XMin,(i//3)*43-b.YMin,-b.ZMin)
    mesh=MeshPart.meshFromShape(Shape=shape,LinearDeflection=.06,AngularDeflection=.18,Relative=False)
    mesh.write(os.path.join(OUT,'reference_'+str(i)+'.stl'))
    obs['mesh_closed']=mesh.isSolid()
    mb=mesh.BoundBox
    obs['tessellated_size_mm']=[mb.XLength,mb.YLength,mb.ZLength]
    obs['native_bbox_excess_mm']=[a-b for a,b in zip(obs['size_mm'],obs['tessellated_size_mm'])]
    observations.append(obs)
doc.recompute();doc.saveAs(os.path.join(OUT,'reference_catalog.FCStd'))
open(os.path.join(OUT,'native_inspection.json'),'w').write(json.dumps({'models':observations,'units':'mm after native STEP import','geometry_repaired':False,'catalog_only_not_installed_assembly':True,'physical_fit_verified':False},indent=2))
'''


RENDER=r'''
import bpy,os,json
from mathutils import Vector
OUT=__OUT__
obs=json.load(open(os.path.join(OUT,'native_inspection.json')))['models']
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
colors=[(.11,.23,.29,1),(.17,.31,.39,1),(.72,.59,.29,1),(.2,.56,.43,1),(.78,.57,.22,1),(.40,.31,.52,1)]
for i,item in enumerate(obs):
    before=set(bpy.data.objects);bpy.ops.wm.stl_import(filepath=os.path.join(OUT,'reference_'+str(i)+'.stl'))
    o=next(o for o in bpy.data.objects if o not in before);o.name=item['name'];o.color=colors[i]
    b=item['bounds_mm'];o.location=((i%3)*38-b[0],(i//3)*43-b[1],-b[2])
    curve=bpy.data.curves.new('label','FONT');curve.body=['PCB HEADER','CABLE HOUSING','CRIMP CONTACT','ESP32 MODULE','M3 INSERT','PACKAGE ONLY'][i];curve.size=2.3
    label=bpy.data.objects.new('label',curve);bpy.context.collection.objects.link(label);label.location=((i%3)*38,(i//3)*43-5,0);label.color=(.12,.15,.2,1)
s=bpy.context.scene;s.render.engine='BLENDER_WORKBENCH';s.render.resolution_x=1700;s.render.resolution_y=1100;s.render.resolution_percentage=100
s.display.shading.light='STUDIO';s.display.shading.color_type='OBJECT';s.display.shading.show_shadows=True;s.display.shading.show_cavity=True;s.display.shading.background_type='WORLD';s.world.color=(.89,.91,.92)
camera_data=bpy.data.cameras.new('catalog');camera_data.type='ORTHO'
camera=bpy.data.objects.new('catalog',camera_data);bpy.context.collection.objects.link(camera);s.camera=camera
target=Vector((51,29,0));camera.location=target+Vector((40,-100,160));camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
bpy.context.view_layer.update()
points=[obj.matrix_world@Vector(vertex) for obj in s.objects if obj.type in ('MESH','FONT') for vertex in obj.bound_box]
local=[camera.matrix_world.inverted()@point for point in points]
xmin,xmax=min(p.x for p in local),max(p.x for p in local)
ymin,ymax=min(p.y for p in local),max(p.y for p in local)
camera.location+=camera.rotation_euler.to_quaternion()@Vector(((xmin+xmax)/2,(ymin+ymax)/2,0))
camera_data.ortho_scale=1.20*max(xmax-xmin,(ymax-ymin)*(1700/1100))
s.render.image_settings.file_format='PNG';s.render.filepath=os.path.join(OUT,'reference_catalog.png');bpy.ops.render.render(write_still=True)
'''


def run(p,out):
    if platform.system()!='Windows': raise RuntimeError('native inspection requires Orion Windows')
    p=validate(p);m=manifest()
    input_root=ROOT/'inputs'
    for item in m['models']:
        path=input_root/item['name']
        if path.is_symlink() or not path.is_file() or path.stat().st_size!=item['bytes'] or sha(path)!=item['sha256']:
            raise ValueError('reference bytes do not match manifest: '+item['name'])
    sys.path.insert(0,os.environ['ORION_CONSOLE_CONTROL_ROOT'])
    from modeling.jobs.ac_diagnostic_enclosure import find_freecad,find_blender
    from modeling.jobs.ac_handheld import run_freecad
    freecad,blender=find_freecad(),find_blender()
    if not freecad or not blender: raise RuntimeError('existing native FreeCAD and Blender required')
    out.mkdir(parents=True,exist_ok=True);start=time.monotonic()
    code=NATIVE.replace('__OUT__',repr(str(out))).replace('__INPUT__',repr(str(input_root))).replace('__MODELS__',repr(m['models']))
    run_freecad(freecad,code,out,p['timeout_sec']-60)
    render=out/'_render.py';render.write_text(RENDER.replace('__OUT__',repr(str(out))),encoding='utf-8')
    with (out/'blender.log').open('wb') as log:
        subprocess.run([str(blender),'--factory-startup','--disable-autoexec','-b','--threads','2','--python-exit-code','1','--python',str(render)],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=max(1,int(p['timeout_sec']-(time.monotonic()-start))))
    validate(p)
    for item in m['models']:
        if sha(input_root/item['name'])!=item['sha256']: raise ValueError('input changed during inspection')
    names=['native_inspection.json','reference_catalog.FCStd','reference_catalog.png']+['reference_'+str(i)+'.stl' for i in range(6)]
    if any(not (out/n).is_file() or not (out/n).stat().st_size for n in names): raise ValueError('missing inspection artifact')
    result={'contract':CONTRACT,'request':p,'execution_device':'orion','geometry_repaired':False,'installed_assembly_verified':False,'physical_fit_verified':False,'manufacturing_released':False,'artifacts':[{'name':n,'bytes':(out/n).stat().st_size,'sha256':sha(out/n)} for n in names]}
    (out/'inspection-manifest.json').write_text(json.dumps(result,indent=2)+'\n')
    return {'status':'inspected','models':6,'physical_fit_verified':False}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--params',type=Path,required=True);parser.add_argument('--out',type=Path,required=True);a=parser.parse_args()
    try: print(json.dumps(run(json.loads(a.params.read_text()),a.out.resolve())))
    except Exception as error: print(str(error),file=sys.stderr);raise SystemExit(1)
