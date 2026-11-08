"""Reopen native routed STEP and audit a separately generated nominal cabin assembly."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import sys

ROOT=Path(__file__).resolve().parent
CAD=r'''
import FreeCAD as App, Part, MeshPart, json, os
from FreeCAD import Vector as V
OUT=__OUT__;DATA=__DATA__;INPUT=__INPUT__
g=DATA['case_geometry_mm'];revision=DATA['revision_geometry'];W=g['width'];D=g['depth'];T=g['wall'];F=g['floor'];H=revision['case_body_height_mm']
def box(x,y,z,w,d,h):return Part.makeBox(w,d,h,V(x,y,z))
def cyl(x,y,z,r,h):return Part.makeCylinder(r,h,V(x,y,z))
def read(name):s=Part.Shape();s.read(os.path.join(INPUT,name));return s
def rounded(w,d,h,r,p):
 s=Part.makeBox(w,d,h,p);edges=[e for e in s.Edges if len(e.Vertexes)==2 and abs(e.Vertexes[0].Point.z-e.Vertexes[1].Point.z)>h-.001]
 return s.makeFillet(r,edges)
base=rounded(W,D,H,g['outer_corner_radius'],V(0,0,0)).cut(rounded(W-2*T,D-2*T,H,g['outer_corner_radius']-T,V(T,T,F)))
lid_axes=[(x,y) for x in (7,W-7) for y in (7,D-7)]
for x,y in lid_axes:
 px=2.2 if x<W/2 else W-11.2;py=2.2 if y<D/2 else D-11.2
 base=base.fuse(box(px,py,F,9,9,H-F)).cut(cyl(x,y,H-g['insert_pocket_depth'],g['insert_pilot_diameter']/2,g['insert_pocket_depth']+.1))
cx,cy=g['carrier_origin_x'],g['carrier_origin_y'];cw,cd=g['carrier_width'],g['carrier_depth'];cz=F+g['carrier_standoff_height'];ct=revision['carrier_plate_thickness_mm']
axes=[(cx+x,cy+y) for x in (5,cw-5) for y in (5,cd-5)]
for x,y in axes:
 base=base.fuse(cyl(x,y,F,g['carrier_boss_diameter']/2,g['carrier_standoff_height'])).cut(cyl(x,y,cz-g['insert_pocket_depth'],g['insert_pilot_diameter']/2,g['insert_pocket_depth']+.1))
for x in (-g['ear_extension'],W-.4):base=base.fuse(box(x,D/2-8,0,g['ear_extension']+.4,16,F))
for x in (-g['ear_extension']/2,W+g['ear_extension']/2):base=base.cut(cyl(x,D/2,-.1,1.6,F+.2))
# Large upper service aperture accommodates the nominal connectors and harness.
base=base.cut(box(-1,15,26,T+2,59,H-25))
# USB service opening is estimated from the controller photograph, not a measured plug.
base=base.cut(box(-1,44,13,T+2,18,9))
base=base.removeSplitter()
lid=read('case_lid.step');installed_lid=lid.copy();installed_lid.translate(V(0,0,H))
carrier=box(cx,cy,cz,cw,cd,ct)
for x,y in axes:carrier=carrier.cut(cyl(x,y,cz-.1,1.6,ct+.2))
controller_z=cz+ct;shield_top=controller_z+15+1.6
outline=json.load(open(os.path.join(OUT,'pcb-outline.json')))
mounts=[(26+x,18+y) for x,y in outline['mounts_mm']]
for (x,y),diameter in zip(mounts,revision['shield_tower_diameters_mm']):
 carrier=carrier.fuse(cyl(x,y,controller_z,diameter/2,15)).cut(cyl(x,y,controller_z+15-6.8,2,6.9))
carrier=carrier.removeSplitter()
pcb=read(os.path.join(OUT,'routed_shield.step'))
boards=[s for s in pcb.Solids if abs(s.BoundBox.XLength-78.58)<.1 and abs(s.BoundBox.YLength-53.34)<.1 and abs(s.BoundBox.ZLength-1.6)<.1]
if len(boards)!=1:raise RuntimeError('cannot resolve exact exported PCB body datum')
datum=boards[0].BoundBox
if abs(datum.XMin+10)>.1 or abs(datum.YMin)>.1:raise RuntimeError('unexpected native STEP XY origin')
pcb.translate(V(26,18,shield_top-datum.ZMax))
if not pcb.isValid():raise RuntimeError('native exported assembly invalid')
controller=box(26,18,controller_z,68.58,53.34,1.6)
components=[box(24,24,controller_z+1.6,12,8.5,10),box(25,48,controller_z+1.6,7,9,3.3)]
esp=read('ESP32-S3-WROOM-1.step');esp.rotate(V(0,0,0),V(0,0,1),-90);b=esp.BoundBox;esp.translate(V(26+42.5-b.XMin,18+13-b.YMin,controller_z+1.6-b.ZMin));components.append(esp)
nominal_lower=Part.makeCompound([controller]+components)
oldbase=read('case_base.step');oldlid=lid.copy();oldlid.translate(V(0,0,g['body_height']))
# Mating plug envelope is deliberately estimated; retain it as a different evidence class.
plug=box(13,25,shield_top,15,22,14)
usb_corridor=box(-1,47,controller_z+1.8,28,11,5.5)
led_corridor=box(-1,26,shield_top,28,20,14)
input_corridor=box(-1,49,shield_top,30,23,13)
check={}
def measure(name,a,b):
 volume=a.common(b).Volume;distance=a.distToShape(b)[0];check[name]={'intersection_mm3':volume,'minimum_distance_mm':distance}
measure('exported_shield_vs_nominal_lower_components',pcb,nominal_lower)
measure('exported_shield_vs_revised_case',pcb,base)
measure('exported_shield_vs_revised_lid',pcb,installed_lid)
measure('nominal_mating_plug_vs_original_lid',plug,oldlid)
measure('nominal_mating_plug_vs_revised_lid',plug,installed_lid)
measure('nominal_mating_plug_vs_revised_case',plug,base)
measure('estimated_usb_service_path_vs_revised_case',usb_corridor,base)
measure('estimated_led_service_path_vs_revised_case',led_corridor,base)
measure('estimated_input_service_path_vs_revised_case',input_corridor,base)
measure('nominal_controller_vs_revised_carrier',nominal_lower,carrier)
measure('exported_shield_vs_revised_carrier',pcb,carrier)
heads=Part.makeCompound([cyl(x,y,controller_z,2.8,3.1) for x,y in axes])
measure('estimated_carrier_screw_heads_vs_towers',heads,carrier)
measure('estimated_carrier_screw_heads_vs_nominal_controller',heads,nominal_lower)
for i,(x,y) in enumerate(mounts):
 access=cyl(x,y,shield_top+.1,3,25)
 measure('lid_removed_screwdriver_'+str(i+1)+'_vs_shield_components',access,pcb)
artifacts=[];doc=App.newDocument('VHOS_RGBW_RevA_NOMINAL_FIT')
for name,shape,color,authority in [('case_base_rgbw_reva',base,(.1,.28,.32),'custom revised cabin shell'),('case_lid_rgbw_reva',lid,(.13,.37,.43),'retained original lid interface'),('carrier_rgbw_reva',carrier,(.65,.67,.7),'custom carrier and integral shield towers'),('routed_shield',pcb,(.05,.36,.25),'native KiCad STEP; header and controller measurements provisional'),('controller_nominal',nominal_lower,(.32,.15,.46),'estimated controller + manufacturer module at estimated position'),('mating_plug_estimated',plug,(.4,.2,.1),'estimated mating plug keepout only')]:
 if not shape.isValid():raise RuntimeError('invalid generated shape '+name)
 if name.startswith(('case_','carrier_')):
  if len(shape.Solids)!=1:raise RuntimeError('printable shape must be a single solid '+name)
  path=os.path.join(OUT,name+'.step');shape.exportStep(path);reopened=Part.Shape();reopened.read(path)
  mesh=MeshPart.meshFromShape(Shape=reopened,LinearDeflection=.08,AngularDeflection=.18,Relative=False)
  if not mesh.isSolid():raise RuntimeError('printable mesh not closed '+name)
  mesh.write(os.path.join(OUT,name+'.stl'));artifacts.append({'name':name,'valid':True,'solids':len(reopened.Solids),'mesh_closed':True})
 obj=doc.addObject('PartDesign::Feature',name);obj.Shape=shape;obj.Label=name+' ['+authority+']'
 if name=='case_lid_rgbw_reva':obj.Placement.Base=V(0,0,H)
doc.recompute();doc.saveAs(os.path.join(OUT,'rgbw_nominal_assembly.FCStd'))
observation={'units':'mm','case_body_height_mm':H,'carrier_plate_thickness_mm':ct,'tower_height_mm':15,'nominal_shield_top_z_mm':shield_top,'checks':check,'printable_parts':artifacts,'exported_native_step_valid':True,'underlying_controller_geometry':'SPECIFICATION_AND_PHOTO_ESTIMATE','mating_plug_geometry':'ESTIMATED','service_states_sampled':['installed','lid_removed_vertical_screwdriver_access','straight_unplug_corridors'],'continuous_service_sweep_verified':False,'physical_fit_verified':False,'rf_keepout_qualified':False,'electrical_qualification':False,'manufacturing_released':False,'header_tail_length_must_be_verified':True}
observation['carrier_screw_head_geometry']='ESTIMATED 5.6mm diameter x 3.1mm height; no carrier washers; exact fastener selection pending'
open(os.path.join(OUT,'mechanical-observation.json'),'w').write(json.dumps(observation,indent=2))
from PySide2 import QtCore, QtGui, QtSvg, QtWidgets
app=QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
svg_dir=os.path.join(OUT,'schematic-svg')
svg_files=[os.path.join(svg_dir,n) for n in os.listdir(svg_dir) if n.endswith('.svg')]
if len(svg_files)!=1:raise RuntimeError('single schematic SVG required')
renderer=QtSvg.QSvgRenderer(svg_files[0])
if not renderer.isValid():raise RuntimeError('invalid native schematic SVG')
picture=QtGui.QImage(2600,1840,QtGui.QImage.Format_ARGB32);picture.fill(QtCore.Qt.white)
painter=QtGui.QPainter(picture);renderer.render(painter);painter.end()
if not picture.save(os.path.join(OUT,'schematic-overview.png')):raise RuntimeError('schematic raster export failed')
'''

def main():
    if platform.system()!='Windows':raise RuntimeError('Orion Windows CAD only')
    parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path,required=True);a=parser.parse_args()
    control=Path(os.environ['ORION_CONSOLE_CONTROL_ROOT']);sys.path.insert(0,str(control))
    from modeling.jobs.ac_diagnostic_enclosure import find_freecad
    from modeling.jobs.ac_handheld import run_freecad
    native=find_freecad()
    if not native:raise RuntimeError('native FreeCAD unavailable')
    code=CAD.replace('__OUT__',repr(str(a.out.resolve()))).replace('__DATA__',repr(json.loads((ROOT/'engineering-inputs.json').read_text()))).replace('__INPUT__',repr(str(ROOT/'inputs')))
    run_freecad(native,code,a.out,140)
if __name__=='__main__':main()
