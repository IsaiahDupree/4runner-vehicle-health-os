"""Add the protected ACC voltage branch to the actual accepted Rev H PCB."""
import csv
import json
import math
from pathlib import Path
import shutil
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import terminal_design as design
import native_pcb as native
import illumination_pcb
import lean_board_pcb
import pcbnew
native.pcbnew = pcbnew
native.base.pcbnew = pcbnew


def build(out):
    inputs = design.ROOT/'inputs'
    for ext in ('kicad_pcb','kicad_pro'):
        shutil.copyfile(inputs/f'vhos_rgbw_revh.{ext}',out/f'{design.NAME}.{ext}')
    for folder in ('VHOS_RevB.pretty','models'):
        shutil.copytree(inputs/folder,out/folder)
    shutil.copyfile(inputs/'fp-lib-table',out/'fp-lib-table')
    project=out/f'{design.NAME}.kicad_pro'
    data=json.loads(project.read_text());data['meta']['filename']=project.name
    project.write_text(json.dumps(data,indent=2)+'\n')
    board,path=illumination_pcb.load(native,out,name=design.NAME)
    definitions={p['ref']:p for p in design.parts()}
    sheet=native.schematic(definitions.values(),out,name=design.NAME,title=design.TITLE,rev='I')
    existing={fp.GetReference():fp for fp in board.GetFootprints()}
    centers=[pad.GetPosition() for pad in existing['U5'].Pads() if pad.GetNumber() in {'9','10'}]
    def mm(point): return pcbnew.ToMM(point.x),pcbnew.ToMM(point.y)
    def distance(point,a,b):
        x,y=mm(point);ax,ay=mm(a);bx,by=mm(b)
        vx,vy=bx-ax,by-ay
        f=max(0,min(1,((x-ax)*vx+(y-ay)*vy)/(vx*vx+vy*vy))) if vx*vx+vy*vy else 0
        return math.hypot(x-ax-f*vx,y-ay-f*vy)
    removed=[]
    for track in list(board.GetTracks()):
        if track.GetNetname()=='/GND' and any(distance(c,track.GetStart(),track.GetEnd())<.8 for c in centers):
            removed.append({'class':track.GetClass(),'start_mm':mm(track.GetStart()),'end_mm':mm(track.GetEnd())})
            board.Delete(track)
        else: track.SetLocked(True)
    baseline={'track_segments':native.locked_copper(board),'vias':illumination_pcb.via_identity(board)}
    poses={r:[mm(fp.GetPosition()),fp.GetOrientationDegrees()] for r,fp in existing.items()}
    for ref,part in definitions.items():
        fp=existing.get(ref)
        if fp is None:
            fp,_=native.load_footprint(part,out)
            fp.SetReference(ref);fp.SetValue(part['value'])
            fp.SetPosition(native.xy(part['xy_mm']))
            fp.SetOrientationDegrees(part['angle_deg'])
            field=pcbnew.PCB_FIELD(fp,pcbnew.FIELD_T_USER,'MPN')
            field.SetText(part['mpn']);field.SetVisible(False);field.SetLayer(pcbnew.F_Fab);fp.Add(field)
            for field in (fp.Reference(),fp.Value()): field.SetLayer(pcbnew.F_Fab)
            board.Add(fp)
        fp.SetPath(pcbnew.KIID_PATH('/'+sheet+'/'+native.uid(ref)))
        for pad in fp.Pads():
            netname=part['nets'].get(pad.GetNumber())
            if not netname: continue
            full='/'+netname
            net=board.FindNet(full)
            if net is None: net=pcbnew.NETINFO_ITEM(board,full);board.Add(net)
            pad.SetNet(net)
    for item in board.GetDrawings():
        if item.GetClass()=='PCB_TEXT' and item.GetText()=='4RUNNER RGBW H':item.SetText('4RUNNER RGBW I')
    title=board.GetTitleBlock();title.SetRevision('I');title.SetTitle(design.TITLE);board.SetTitleBlock(title)
    native.save_json(out/'revi-route-baseline.json',baseline)
    native.save_json(out/'voltage-change.json',{
        'existing_footprint_poses':poses,'removed_ground_segments_at_U5_pads_9_10':removed,
        'new_refs':['R40','R41','R42','R43','R44','U12','D10','C32'],
        'sensor_node':'ACC_FUSED','gpio':1,'reuses_switch':'U5 channel 3',
        'external_inlets_added':0,'manufacturing_released':False})
    pcbnew.ZONE_FILLER(board).Fill(board.Zones());pcbnew.SaveBoard(str(path),board,True)
    nets={str(p.GetNetname()) for fp in board.GetFootprints() for p in fp.Pads() if p.GetNetname()}
    for zone in list(board.Zones()):
        if not zone.GetIsRuleArea():board.Remove(zone)
    if not pcbnew.ExportSpecctraDSN(board,str(out/'shield.dsn')):raise RuntimeError('Routing export failed')
    widths={'/'+n:w for w,names in lean_board_pcb.WIDTH_CLASSES.values() for n in names}
    widths['/VEH_ACC']=1.5
    rules=[{'net':n,'class':'Width_'+str(widths.get(n,.2)),'width_mm':widths.get(n,.2),'clearance_mm':.19} for n in sorted(nets)]
    native.base.bind_dsn_rules(out,rules)
    route=out/'shield.dsn'
    route.write_text(route.read_text().replace('(clearance 270)','(clearance 190)').replace('(width 250) (clearance 190)','(width 200) (clearance 190)'))


def finish(out):
    board=illumination_pcb.import_route(native,out,name=design.NAME,baseline_file='revi-route-baseline.json')
    previous=json.loads((out/'voltage-change.json').read_text())
    actual={}
    for fp in board.GetFootprints():
        actual[fp.GetReference()]={'mpn':fp.GetField('MPN').GetText() if fp.GetField('MPN') else None,
          'footprint':fp.GetFPID().Format(),'value':fp.GetValue(),'x_mm':pcbnew.ToMM(fp.GetPosition().x),
          'y_mm':pcbnew.ToMM(fp.GetPosition().y),'rotation_deg':fp.GetOrientationDegrees(),
          'pad_nets':{p.GetNumber():str(p.GetNetname()) for p in fp.Pads()}}
    for ref,(xy,angle) in previous['existing_footprint_poses'].items():
        a=actual[ref]
        if [a['x_mm'],a['y_mm']]!=xy or a['rotation_deg']!=angle:raise RuntimeError('Existing pose moved: '+ref)
    if actual['U5']['pad_nets']['9']!='/VOLT_SW' or actual['U5']['pad_nets']['10']!='/VOLT_CLAMP':raise RuntimeError('Switch wiring')
    if actual['U11']['pad_nets']['39']!='/VOLT_ADC':raise RuntimeError('ADC pin wiring')
    for ref,pin in [('JT3','1'),('JT3','2'),('JT6','2')]:
        net=actual[ref]['pad_nets'][pin]
        if not net.startswith('unconnected-') or any(t.GetNetname()==net for t in board.GetTracks()):raise RuntimeError('Reserve isolation')
    native.save_json(out/'native-parts.json',actual)
    native.save_json(out/'voltage-native-audit.json',{'existing_poses_unchanged':True,'reserve_isolation':True,
        'source_node':'ACC_FUSED','gpio':1,'added_populated_positions':8,'board_count':1,'passed':True,'physical_validation':False})
    with (out/'PCB-BOM.csv').open('w',newline='') as stream:
        w=csv.DictWriter(stream,fieldnames=['ref','mpn','value','footprint']);w.writeheader()
        for ref,p in sorted(actual.items()):w.writerow({'ref':ref,**{k:p[k] for k in ['mpn','value','footprint']}})


if __name__=='__main__':
    action,folder=sys.argv[1:]
    {'build':build,'finish':finish}[action](Path(folder))
