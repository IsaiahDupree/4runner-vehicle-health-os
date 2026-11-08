"""Source-pinned Orion render of a placement concept, never a routed PCB."""
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
JOB_TYPE = 'cad.vhos_shield_placement_preview'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest():
    value = json.loads((ROOT / 'preview-inputs.json').read_text())
    if value['contract'] != 'vhos_shield_placement_preview_v1' or len(value['models']) != 3:
        raise ValueError('fixed three-model preview input set required')
    for item in value['models']:
        if Path(item['name']).name != item['name'] or not 1 <= item['bytes'] <= 16000000:
            raise ValueError('bounded regular named input required')
    return value

def validate(p):
    if set(p) != {'expected_source_sha256', 'expected_manifest_sha256', 'research_only', 'timeout_sec'}:
        raise ValueError('exact source-pinned preview parameters required')
    if p['research_only'] is not True or p['expected_source_sha256'] != sha(Path(__file__)) or p['expected_manifest_sha256'] != sha(ROOT / 'preview-inputs.json'):
        raise ValueError('preview source/input identity drift')
    if type(p['timeout_sec']) is not int or not 60 <= p['timeout_sec'] <= 600:
        raise ValueError('bounded 60..600 second timeout required')
    manifest()
    return dict(p)

def register(m):
    m.JOB_TYPES[JOB_TYPE] = {'runtime': 'python', 'script': Path(__file__),
        'description': 'Fixed nominal UNO shield placement visualization. Connector CAD plus estimated board/components. No routing, firmware, Gerbers or fit qualification.',
        'params': {'expected_source_sha256': 'exact source hash', 'expected_manifest_sha256': 'exact inputs hash', 'research_only': 'true', 'timeout_sec': 'integer 60..600'}}

NATIVE = r'''
import os,json,FreeCAD as App,Part,MeshPart
from FreeCAD import Vector as V
OUT=__OUT__
INPUT=__INPUT__
DATA=__DATA__
doc=App.newDocument('VHOS_Shield_PLACEMENT_CONCEPT')
entries=[];objects=[]
def box(x,y,z,w,d,h):return Part.makeBox(w,d,h,V(x,y,z))
def cyl(x,y,z,r,h):return Part.makeCylinder(r,h,V(x,y,z))
def add(name,shape,color,authority):
    if shape.isNull() or not shape.isValid():raise ValueError('invalid preview solid '+name)
    obj=doc.addObject('PartDesign::Feature',name);obj.Label=name+' ['+authority+']';obj.Shape=shape;objects.append(obj)
    mesh=MeshPart.meshFromShape(Shape=shape,LinearDeflection=.08,AngularDeflection=.22,Relative=False)
    mesh.write(os.path.join(OUT,name+'.stl'))
    b=shape.BoundBox
    entries.append({'name':name,'color':color,'authority':authority,'valid':shape.isValid(),'solids':len(shape.Solids),'bounds_mm':[b.XMin,b.YMin,b.ZMin,b.XMax,b.YMax,b.ZMax]})
headers=DATA['headers']['headers']
pads=[p for group in headers for p in group['pads']]
holes=DATA['headers']['mounting_holes']
def plate(z,cut=False):
    # Nominal UNO outline; not a measured ShengYang board.
    s=box(0,0,z,68.58,53.34,1.6)
    if cut:s=s.cut(box(50,10,z-1,20,22,4))
    for p in pads:s=s.cut(cyl(p['x_mm'],p['y_mm'],z-1,.51,4))
    for p in holes:s=s.cut(cyl(p['x_mm'],p['y_mm'],z-1,1.6,4))
    return s
add('controller_pcb',plate(0),(.31,.13,.50,1),'estimated UNO-style controller outline; nominal reference holes')
add('shield_pcb',plate(14.5,True),(.035,.29,.27,1),'custom placement-only shield; provisional RF opening')
socket_parts=[];pins=[];rings=[]
for g in headers:
    xs=[p['x_mm'] for p in g['pads']];y=g['pads'][0]['y_mm']
    for z in (1.6,16.1):
        s=box(min(xs)-1.25,y-1.25,z,max(xs)-min(xs)+2.5,2.5,8.5)
        for p in g['pads']:s=s.cut(cyl(p['x_mm'],p['y_mm'],z-1,.54,11))
        socket_parts.append(s)
    for p in g['pads']:
        x,y=p['x_mm'],p['y_mm']
        pins.append(box(x-.32,y-.32,7,.64,.64,9.1))
        rings.append(cyl(x,y,16.1,.94,.08).cut(cyl(x,y,16,.54,.3)))
add('stack_sockets',Part.makeCompound(socket_parts),(.045,.055,.065,1),'nominal 10+8+8+6 stacking-header envelopes')
add('header_pins',Part.makeCompound(pins),(.75,.59,.28,1),'estimated 0.64 mm pin envelopes; not chosen tail length')
add('plated_pads',Part.makeCompound(rings),(.79,.63,.29,1),'illustrative pad rings; no copper routing')

def imported(name,filename,rotation,minimum,color,authority):
    s=Part.Shape();s.read(os.path.join(INPUT,filename))
    if rotation:s.rotate(V(0,0,0),V(0,0,1),rotation)
    b=s.BoundBox;s.translate(V(minimum[0]-b.XMin,minimum[1]-b.YMin,minimum[2]-b.ZMin))
    add(name,s,color,authority)
imported('esp32_module','ESP32-S3-WROOM-1.step',-90,(42.5,13,1.6),(.50,.53,.55,1),'Espressif reference module; estimated board placement, exact fitted module unverified')
# Header's native pins extend below Z=0; seat that datum on the shield top.
s=Part.Shape();s.read(os.path.join(INPUT,'Molex_43045-0600.step'));s.rotate(V(0,0,0),V(0,0,1),90);s.translate(V(11,22,16.1))
add('input_header',s,(.065,.08,.095,1),'downloaded Molex 43045-0600 reference; proposed placement')
imported('adapter_plug','Molex_43025-0600.stp',90,(-18,19.5,15.5),(.10,.12,.14,1),'downloaded cable housing; shown detached, mating alignment not verified')

# Estimated component bodies deliberately contain no invented copper traces.
blocks=[];passives=[];metals=[]
for x,y,w,d,h in [(20,30,5,4,1.5),(30,30,5,6,1.2),(21,39,5,5,1.3),(29,37,7,7,3.2),(22,13,4.5,5,1.2),(28.5,13,4.5,5,1.2),(35,13,4.5,5,1.2),(25,21,6,5,1.1)]:
    blocks.append(box(x,y,16.1,w,d,h))
for x,y in [(18,38),(18,41),(35,29),(38,29),(20,25),(33,24),(37,24),(31,18),(22,18)]:
    passives.append(box(x,y,16.1,2.2,1.2,1.2))
    metals.extend([box(x-.1,y,16.1,.45,1.2,1.25),box(x+1.85,y,16.1,.45,1.2,1.25)])
add('placement_blocks',Part.makeCompound(blocks),(.15,.18,.21,1),'estimated protection, regulator and driver placement blocks; packages not frozen')
add('passive_blocks',Part.makeCompound(passives),(.50,.37,.19,1),'illustrative passive envelopes, values unselected')
add('passive_ends',Part.makeCompound(metals),(.68,.72,.73,1),'illustrative terminations')

body=box(2,9.5,16.1,15,7,5.5)
for i in range(4):body=body.cut(cyl(4.25+3.5*i,13,20.7,1.0,2))
add('led_output_envelope',body,(.12,.45,.25,1),'generic four-way output connector envelope; actual LED connector/current TBD')
screws=[]
for i in range(4):
    x=4.25+3.5*i;s=cyl(x,13,20.9,.83,.6);s=s.cut(box(x-.7,12.84,21.25,1.4,.32,.5));screws.append(s)
add('output_screws',Part.makeCompound(screws),(.67,.70,.72,1),'illustrative screw heads')

add('usb_reference',box(-1,30,1.6,7,9,3.3),(.70,.74,.77,1),'estimated USB-C access envelope')
add('barrel_reference',box(-2,6,1.6,12,8.5,10),(.08,.09,.11,1),'estimated barrel-jack access envelope')
doc.recompute();doc.saveAs(os.path.join(OUT,'shield_placement_concept.FCStd'))
Part.export(objects,os.path.join(OUT,'shield_placement_concept.step'))
reloaded=Part.Shape();reloaded.read(os.path.join(OUT,'shield_placement_concept.step'))
if not reloaded.isValid():raise ValueError('invalid exported placement STEP')
open(os.path.join(OUT,'preview_observation.json'),'w').write(json.dumps({'parts':entries,'units':'mm','exported_step_valid':reloaded.isValid(),'header_positions':len(pads),'electrical_routing_exists':False,'physical_fit_verified':False,'manufacturing_released':False,'rf_clearance_qualified':False,'status':'PLACEMENT_CONCEPT'},indent=2))
'''

RENDER = r'''
import bpy,json,os,math
from mathutils import Vector
OUT=__OUT__
data=json.load(open(os.path.join(OUT,'preview_observation.json')))
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
for item in data['parts']:
    before=set(bpy.data.objects);bpy.ops.wm.stl_import(filepath=os.path.join(OUT,item['name']+'.stl'))
    obj=next(o for o in bpy.data.objects if o not in before);obj.name=item['name'];obj.color=item['color']
    if item['name']=='esp32_module':
        for name,color in [('can',(.62,.65,.67,1)),('antenna',(.045,.06,.07,1)),('module_pcb',(.11,.23,.18,1))]:
            mat=bpy.data.materials.new(name);mat.diffuse_color=color;obj.data.materials.append(mat)
        for poly in obj.data.polygons:
            center=sum((obj.data.vertices[i].co for i in poly.vertices),Vector())/len(poly.vertices)
            poly.material_index=1 if center.x>61.5 else (0 if center.z>2.65 else 2)
def label(text,x,y,z,size=1.8,color=(.88,.94,.92,1),angle=0):
    c=bpy.data.curves.new('label','FONT');c.body=text;c.size=size;c.align_x='LEFT';c.extrude=.004
    o=bpy.data.objects.new(text,c);bpy.context.collection.objects.link(o);o.location=(x,y,z);o.rotation_euler.z=angle;o.color=color
label('VHOS  /  LED SHIELD',16,46,16.22,2.0)
label('A',14.5,24,16.22,3.0)
label('B',37,36.5,16.22,3.0)
label('C',19,10,16.22,3.0)
label('D',46.5,33.5,16.22,3.0)
label('POWER AREA',19,28,16.22,1.25)
label('LED DRIVER TBD',22,19,16.22,1.2)
label('LED OUT',2.4,17.5,16.22,1.3)
label('IO18  IO17  IO14',21,7,16.22,1.1)
label('IO21 ENABLE',29,4.8,16.22,1.05)
label('RF OPENING',50.5,34,16.22,1.0)
scene=bpy.context.scene;scene.render.engine='BLENDER_WORKBENCH';scene.render.resolution_percentage=100
scene.display.shading.light='STUDIO';scene.display.shading.color_type='MATERIAL';scene.display.shading.show_shadows=True;scene.display.shading.show_cavity=True
# Material colors for the source module, object colors for all other geometry.
for obj in scene.objects:
    if obj.type in ('MESH','FONT') and obj.name!='esp32_module':
        mat=bpy.data.materials.new(obj.name+'_color');mat.diffuse_color=obj.color;obj.data.materials.append(mat)
scene.display.shading.background_type='WORLD';scene.world.color=(.91,.94,.95)
camera_data=bpy.data.cameras.new('preview_camera');camera_data.type='ORTHO';camera=bpy.data.objects.new('preview_camera',camera_data);bpy.context.collection.objects.link(camera);scene.camera=camera
def render(name,size,offset):
    scene.render.resolution_x,scene.render.resolution_y=size
    target=Vector((27,26,11));camera.location=target+Vector(offset);camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler();bpy.context.view_layer.update()
    points=[o.matrix_world@Vector(v) for o in scene.objects if o.type in ('MESH','FONT') for v in o.bound_box]
    pts=[camera.matrix_world.inverted()@v for v in points]
    xmin,xmax=min(v.x for v in pts),max(v.x for v in pts);ymin,ymax=min(v.y for v in pts),max(v.y for v in pts)
    camera.location+=camera.rotation_euler.to_quaternion()@Vector(((xmin+xmax)/2,(ymin+ymax)/2,0))
    camera_data.ortho_scale=1.12*max(xmax-xmin,(ymax-ymin)*size[0]/size[1])
    scene.render.image_settings.file_format='PNG';scene.render.filepath=os.path.join(OUT,name);bpy.ops.render.render(write_still=True)
render('shield_isometric.png',(1550,1150),(-82,-115,165))
render('shield_top.png',(1100,950),(0,0,190))
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'shield_preview.blend'))
'''

def compose(out):
    from PIL import Image, ImageDraw, ImageFont
    canvas = Image.new('RGB', (2400, 1540), '#f4f7fa')
    d = ImageDraw.Draw(canvas)
    def font(n, bold=False):
        return ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf' if bold else 'C:/Windows/Fonts/arial.ttf', n)
    d.text((70,45), '4Runner  |  ESP32-S3 LED shield', font=font(56,True), fill='#13283a')
    d.text((72,119), 'ShengYang D1 UNO N16R8 reference  /  updated connector and GPIO placement', font=font(29), fill='#536879')
    left = Image.open(out/'shield_isometric.png').convert('RGB');left.thumbnail((1460,1050))
    canvas.paste(left,(40,215))
    top = Image.open(out/'shield_top.png').convert('RGB');top.thumbnail((870,790))
    canvas.paste(top,(1500,240))
    d.text((80,185),'STACKED PREVIEW',font=font(25,True),fill='#2b5260')
    d.text((1535,185),'SHIELD TOP VIEW',font=font(25,True),fill='#2b5260')
    lines=[('A  Locking 6-pin adapter input','Molex 43045-0600; cable housing shown detached'),
           ('B  Protected 5 V power section','Protection and regulator placement envelopes'),
           ('C  LED driver / output section','GPIO18 / 17 / 14; GPIO21 enable; LED type TBD'),
           ('D  Open module / antenna area','Provisional opening; RF clearance not qualified')]
    for i,(a,b) in enumerate(lines):
        y=1025+i*85
        d.text((1535,y),a,font=font(26,True),fill='#173948');d.text((1535,y+34),b,font=font(22),fill='#536879')
    d.rounded_rectangle((65,1350,2335,1495),radius=17,fill='#173948')
    d.text((95,1372),'PLACEMENT CONCEPT  -  NOT ROUTED',font=font(36,True),fill='white')
    d.text((95,1423),'Connector reference CAD + estimated board/component envelopes. No Gerbers or verified physical fit.',font=font(26),fill='#d6e8eb')
    canvas.save(out/'updated_shield_overview.png')

def run(p, out):
    if platform.system() != 'Windows': raise RuntimeError('CAD/render work requires native Orion')
    p=validate(p);m=manifest()
    for item in m['models']:
        f=ROOT/'inputs'/item['name']
        if f.is_symlink() or not f.is_file() or f.stat().st_size!=item['bytes'] or sha(f)!=item['sha256']:
            raise ValueError('pinned reference bytes drift')
    sys.path.insert(0,os.environ['ORION_CONSOLE_CONTROL_ROOT'])
    from modeling.jobs.ac_diagnostic_enclosure import find_freecad,find_blender
    from modeling.jobs.ac_handheld import run_freecad
    fc,bl=find_freecad(),find_blender()
    if not fc or not bl:raise RuntimeError('existing native FreeCAD and Blender required')
    out.mkdir(parents=True,exist_ok=True);start=time.monotonic()
    run_freecad(fc,NATIVE.replace('__OUT__',repr(str(out))).replace('__INPUT__',repr(str(ROOT/'inputs'))).replace('__DATA__',repr(m)),out,p['timeout_sec']-90)
    script=out/'_render.py';script.write_text(RENDER.replace('__OUT__',repr(str(out))),encoding='utf-8')
    with (out/'blender.log').open('wb') as log:
        subprocess.run([str(bl),'--factory-startup','--disable-autoexec','-b','--threads','2','--python-exit-code','1','--python',str(script)],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=max(1,int(p['timeout_sec']-(time.monotonic()-start)-15)))
    compose(out);validate(p)
    names=['shield_placement_concept.FCStd','shield_placement_concept.step','preview_observation.json','shield_preview.blend','shield_isometric.png','shield_top.png','updated_shield_overview.png']
    artifacts=[{'name':n,'bytes':(out/n).stat().st_size,'sha256':sha(out/n)} for n in names]
    (out/'preview-manifest.json').write_text(json.dumps({'contract':m['contract'],'request':p,'execution_device':'orion','status':'PLACEMENT_CONCEPT','electrical_routing_exists':False,'physical_fit_verified':False,'manufacturing_released':False,'artifacts':artifacts},indent=2)+'\n')
    return {'status':'rendered_placement_concept','physical_fit_verified':False,'electrical_routing_exists':False}

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--params',type=Path,required=True);parser.add_argument('--out',type=Path,required=True);a=parser.parse_args()
    print(json.dumps(run(json.loads(a.params.read_text()),a.out.resolve())))
