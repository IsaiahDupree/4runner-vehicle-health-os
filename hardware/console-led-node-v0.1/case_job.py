"""Source-pinned, fixed-contract fit-check enclosure job; execute CAD only on Orion."""
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

ROOT = Path(__file__).resolve().parent
JOB_TYPE = "cad.vhos_console_led_case"
CONTRACT = "vhos_console_led_case_fitcheck_v1"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(params: dict) -> dict:
    keys = {"expected_source_sha256", "expected_inputs_sha256", "timeout_sec"}
    if not isinstance(params, dict) or set(params) != keys:
        raise ValueError("exact source hash, inputs hash and timeout_sec required")
    if type(params["timeout_sec"]) is not int or not 60 <= params["timeout_sec"] <= 600:
        raise ValueError("timeout_sec must be an integer in 60..600")
    for field, path in (("expected_source_sha256", Path(__file__)),
                        ("expected_inputs_sha256", ROOT / "design-inputs.json")):
        if path.is_symlink() or not path.is_file() or params[field] != sha(path):
            raise ValueError(f"{field} must match the regular, registered source file")
    inputs = json.loads((ROOT / "design-inputs.json").read_text())
    if inputs["contract"] != CONTRACT or inputs["status"] != "FIT_CHECK_ONLY":
        raise ValueError("only the retained fit-check contract is admitted")
    if any(inputs["release"].values()):
        raise ValueError("this generator cannot authorize physical or electrical release")
    return dict(params)


def register(modeling) -> None:
    modeling.JOB_TYPES[JOB_TYPE] = {
        "runtime": "python", "script": Path(__file__).resolve(),
        "description": "Fixed 116 x 86 x 45 mm cabin case fit-check, lid, insert coupon and carrier drill template; no vehicle pinout or print dispatch.",
        "params": {"expected_source_sha256": "registered generator SHA256",
                   "expected_inputs_sha256": "registered design-input SHA256",
                   "timeout_sec": "integer 60..600"},
    }


CAD = r'''
import json, os, FreeCAD as App, Part, MeshPart
from FreeCAD import Vector as V
OUT = __OUT__
G = __GEOMETRY__
W,D,H,T,F,L = [G[k] for k in ('width','depth','body_height','wall','floor','lid')]
doc = App.newDocument('VHOS_Console_LED_Fitcheck')
def rounded(w,d,h,r,p):
    s=Part.makeBox(w,d,h,p)
    edges=[e for e in s.Edges if len(e.Vertexes)==2 and abs(e.Vertexes[0].Point.z-e.Vertexes[1].Point.z)>h-0.001]
    return s.makeFillet(r,edges)
base=rounded(W,D,H,G['outer_corner_radius'],V(0,0,0))
base=base.cut(rounded(W-2*T,D-2*T,H,G['outer_corner_radius']-T,V(T,T,F)))
lid_axes=[(x,y) for x in (7,W-7) for y in (7,D-7)]
for x,y in lid_axes:
    px=2.2 if x<W/2 else W-11.2
    py=2.2 if y<D/2 else D-11.2
    base=base.fuse(Part.makeBox(9,9,H-F,V(px,py,F)))
    base=base.cut(Part.makeCylinder(G['insert_pilot_diameter']/2,G['insert_pocket_depth']+.1,V(x,y,H-G['insert_pocket_depth'])))
cx,cy=G['carrier_origin_x'],G['carrier_origin_y']
cw,cd=G['carrier_width'],G['carrier_depth']
cz=F+G['carrier_standoff_height']
carrier_axes=[(cx+x,cy+y) for x in (5,cw-5) for y in (5,cd-5)]
for x,y in carrier_axes:
    base=base.fuse(Part.makeCylinder(G['carrier_boss_diameter']/2,G['carrier_standoff_height'],V(x,y,F)))
    base=base.cut(Part.makeCylinder(G['insert_pilot_diameter']/2,G['insert_pocket_depth']+.1,V(x,y,cz-G['insert_pocket_depth'])))
for x in (-G['ear_extension'],W-0.4):
    base=base.fuse(Part.makeBox(G['ear_extension']+.4,16,F,V(x,D/2-8,0)))
for x in (-G['ear_extension']/2,W+G['ear_extension']/2):
    base=base.cut(Part.makeCylinder(1.6,F+.2,V(x,D/2,-.1)))
for y in (16,58):
    base=base.cut(Part.makeBox(T+2,G['cable_slot_width'],G['cable_slot_depth']+1,V(-1,y,H-G['cable_slot_depth'])))
    bridge=Part.makeBox(8,5,5,V(4,y+3,F))
    bridge=bridge.cut(Part.makeBox(4,5.2,2,V(6,y+2.9,F+1)))
    base=base.fuse(bridge)
base=base.removeSplitter()
lid=rounded(W,D,L,G['outer_corner_radius'],V(0,0,0))
for x,y in lid_axes:
    lid=lid.cut(Part.makeCylinder(1.6,L+.2,V(x,y,-.1)))
lid=lid.removeSplitter()
carrier=Part.makeBox(cw,cd,G['carrier_thickness'],V(cx,cy,cz))
for x,y in carrier_axes:
    carrier=carrier.cut(Part.makeCylinder(1.6,3,V(x,y,cz-.1)))
gauge=Part.makeBox(cw,cd,1,V(0,0,0))
for x,y in carrier_axes:
    gauge=gauge.cut(Part.makeCylinder(1.6,1.2,V(x-cx,y-cy,-.1)))
coupon=rounded(40,16,9,2,V(0,0,0))
for x,diam in ((8,4.0),(20,4.1),(32,4.2)):
    coupon=coupon.cut(Part.makeCylinder(diam/2,6.8,V(x,8,2.3)))
controller=Part.makeBox(G['controller_reserved_width'],G['controller_reserved_depth'],G['controller_reserved_height'],V(26,18,cz+G['carrier_thickness']))
parts={'case_base':base,'case_lid':lid,'insert_coupon':coupon,'carrier_drill_template':gauge}
observations={}
for name,s in parts.items():
    if not s.isValid() or len(s.Solids)!=1 or s.Volume<=0:
        raise RuntimeError(name+' must be one valid, nonempty solid')
    feature=doc.addObject('PartDesign::Feature',name);feature.Shape=s
    if name=='case_lid': feature.Placement.Base=V(0,0,H+15)
    elif name=='insert_coupon': feature.Placement.Base=V(W+20,0,0)
    elif name=='carrier_drill_template': feature.Placement.Base=V(0,D+15,0)
    step=os.path.join(OUT,name+'.step');s.exportStep(step)
    # Reopen the exact exported solid, then mesh that retained artifact.
    retained=Part.Shape();retained.read(step)
    if not retained.isValid() or len(retained.Solids)!=1:
        raise RuntimeError('STEP roundtrip invalid: '+name)
    mesh=MeshPart.meshFromShape(Shape=retained,LinearDeflection=.08,AngularDeflection=.15,Relative=False)
    mesh.write(os.path.join(OUT,name+'.stl'))
    if not mesh.isSolid(): raise RuntimeError('non-closed exported mesh: '+name)
    bb=retained.BoundBox
    observations[name]={'valid':True,'solids':len(retained.Solids),'mesh_closed':True,'volume_mm3':retained.Volume,'bbox_mm':[bb.XLength,bb.YLength,bb.ZLength]}
carrier.exportStep(os.path.join(OUT,'carrier_REFERENCE_ONLY.step'))
controller.exportStep(os.path.join(OUT,'controller_ESTIMATED_KEEP_OUT.step'))
# Check independently reopened exports against the reserved envelopes.
actual_base=Part.Shape();actual_base.read(os.path.join(OUT,'case_base.step'))
actual_lid=Part.Shape();actual_lid.read(os.path.join(OUT,'case_lid.step'));actual_lid.translate(V(0,0,H))
actual_carrier=Part.Shape();actual_carrier.read(os.path.join(OUT,'carrier_REFERENCE_ONLY.step'))
actual_controller=Part.Shape();actual_controller.read(os.path.join(OUT,'controller_ESTIMATED_KEEP_OUT.step'))
checks={
 'base_lid_intersection_mm3':actual_base.common(actual_lid).Volume,
 'base_carrier_intersection_mm3':actual_base.common(actual_carrier).Volume,
 'base_controller_intersection_mm3':actual_base.common(actual_controller).Volume,
 'lid_controller_intersection_mm3':actual_lid.common(actual_controller).Volume,
 'carrier_controller_intersection_mm3':actual_carrier.common(actual_controller).Volume,
}
if any(v>0.01 for v in checks.values()): raise RuntimeError('retained-solid interference '+repr(checks))
doc.recompute();doc.saveAs(os.path.join(OUT,'console_led_fitcheck.FCStd'))
open(os.path.join(OUT,'cad_observation.json'),'w').write(json.dumps({'parts':observations,'retained_solid_checks':checks,'assembled_case_bbox_mm':[W+14,D,H+L],'carrier_axes_mm':carrier_axes,'lid_axes_mm':lid_axes,'controller_top_clearance_mm':H-actual_controller.BoundBox.ZMax,'physical_fit_verified':False},indent=2))
'''


RENDER = r'''
import bpy, os
from mathutils import Vector
OUT=__OUT__
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
for name,offset,color in [('case_base',(0,0,0),(.09,.23,.30,1)),('case_lid',(0,100,0),(.13,.37,.43,1)),('insert_coupon',(132,0,0),(.85,.53,.19,1)),('carrier_drill_template',(132,30,0),(.4,.55,.61,1))]:
    before=set(bpy.data.objects);bpy.ops.wm.stl_import(filepath=os.path.join(OUT,name+'.stl'))
    o=next(o for o in bpy.data.objects if o not in before);o.location=offset;o.color=color
s=bpy.context.scene;s.render.engine='BLENDER_WORKBENCH';s.render.resolution_x=1600;s.render.resolution_y=1200;s.render.resolution_percentage=100
s.display.shading.light='STUDIO';s.display.shading.color_type='OBJECT';s.display.shading.show_shadows=True;s.display.shading.show_cavity=True;s.display.shading.background_type='WORLD';s.world.color=(.87,.89,.9)
c=bpy.data.cameras.new('overview');c.type='ORTHO';c.ortho_scale=290;camera=bpy.data.objects.new('overview',c);bpy.context.collection.objects.link(camera);s.camera=camera
target=Vector((103,82,4));camera.location=target+Vector((-180,-260,300));camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
s.render.image_settings.file_format='PNG';s.render.filepath=os.path.join(OUT,'case_overview.png');bpy.ops.render.render(write_still=True)
'''


def run(params: dict, out: Path) -> dict:
    if platform.system() != "Windows":
        raise RuntimeError("CAD generation requires Orion Windows; no Mac fallback")
    params = validate(params)
    control_root = Path(os.environ["ORION_CONSOLE_CONTROL_ROOT"])
    sys.path.insert(0, str(control_root))
    from modeling.jobs.ac_diagnostic_enclosure import find_freecad, find_blender
    from modeling.jobs.ac_handheld import run_freecad
    freecad, blender = find_freecad(), find_blender()
    if not freecad or not blender:
        raise RuntimeError("registered Orion FreeCAD and Blender required")
    out.mkdir(parents=True, exist_ok=True)
    inputs = json.loads((ROOT / "design-inputs.json").read_text())
    started = time.monotonic()
    code = CAD.replace('__OUT__', repr(str(out))).replace('__GEOMETRY__', repr(inputs['geometry_mm']))
    run_freecad(freecad, code, out, params['timeout_sec'] - 45)
    render = out / '_render_case.py'
    render.write_text(RENDER.replace('__OUT__', repr(str(out))), encoding='utf-8')
    with (out / 'blender.log').open('wb') as stream:
        subprocess.run([str(blender),'--factory-startup','--disable-autoexec','-b','--threads','2',
                        '--python-exit-code','1','--python',str(render)],
                       stdout=stream,stderr=subprocess.STDOUT,check=True,
                       timeout=max(1, int(params['timeout_sec']-(time.monotonic()-started))))
    validate(params)
    names = ['case_base','case_lid','insert_coupon','carrier_drill_template']
    expected = [n+ext for n in names for ext in ('.step','.stl')]
    expected += ['carrier_REFERENCE_ONLY.step','controller_ESTIMATED_KEEP_OUT.step',
                 'console_led_fitcheck.FCStd','cad_observation.json','case_overview.png']
    if any(not (out/n).is_file() or not (out/n).stat().st_size for n in expected):
        raise RuntimeError('missing expected CAD output')
    manifest = {'contract':CONTRACT,'job_type':JOB_TYPE,'execution_device':'orion',
                'request':params,'geometry_mm':inputs['geometry_mm'],
                'observation':json.loads((out/'cad_observation.json').read_text()),
                'status':'FIT_CHECK_ONLY','manufacturing_released':False,
                'vehicle_fit_verified':False,'controller_fit_verified':False,'print_started':False,
                'runtimes':{'freecad':str(freecad),'blender':str(blender)},
                'artifacts':[{'name':n,'bytes':(out/n).stat().st_size,'sha256':sha(out/n)} for n in expected]}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    return {'status':'FIT_CHECK_ONLY','artifact_count':len(expected)+1,
            'manufacturing_released':False,'print_started':False}


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--params',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    try:
        print(json.dumps(run(json.loads(args.params.read_text()),args.out.resolve())))
        return 0
    except Exception as error:
        print(str(error),file=sys.stderr)
        return 1


if __name__=='__main__':
    raise SystemExit(main())
