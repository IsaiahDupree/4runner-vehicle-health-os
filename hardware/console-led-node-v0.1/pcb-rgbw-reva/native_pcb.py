"""Deterministic KiCad source/Specctra bridge, executed only on Orion Windows."""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import sys
import uuid
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
from circuit import design

NAME='vhos_rgbw_reva'
KICAD=Path('C:/Program Files/KiCad/10.0')
LIB=KICAD/'share/kicad/footprints'
NS=uuid.UUID('1b792146-6b86-4ac1-aef1-3810119f1d92')
def uid(x):return str(uuid.uuid5(NS,x))
def quote(x):return json.dumps(str(x))
def save_json(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def xy(p):return pcbnew.VECTOR2I(round((100+p[0])*1e6),round((153.34-p[1])*1e6))

def bind_dsn_rules(out,effective):
    """Translate verified native rules; KiCad's DSN exporter used minimums only.

    Keep the original export and compare the full expression tree. Only the
    structure rule and network class declarations may change. No geometry,
    placement, net membership, pin identity or pre-routed copper is rewritten.
    """
    path=out/'shield.dsn';raw=path.read_text();(out/'shield-native-export.dsn').write_text(raw)
    tokens=re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+',raw);stack=[];root=None
    for token in tokens:
        if token=='(':
            node=[]
            if stack:stack[-1].append(node)
            else:root=node
            stack.append(node)
        elif token==')':stack.pop()
        else:stack[-1].append(token)
    if stack or root[0]!='pcb':raise RuntimeError('DSN parse failed')
    structure=next(n for n in root if isinstance(n,list) and n[0]=='structure')
    network=next(n for n in root if isinstance(n,list) and n[0]=='network')
    def invariant():
        clean=[]
        for n in root:
            if isinstance(n,list) and n[0] in ('structure','network'):
                omit='rule' if n[0]=='structure' else 'class'
                clean.append([v for v in n if not isinstance(v,list) or v[0]!=omit])
            else:clean.append(n)
        return hashlib.sha256(json.dumps(clean,separators=(',',':')).encode()).hexdigest()
    before=invariant()
    via=next(n[1] for n in structure if isinstance(n,list) and n[0]=='via')
    structure[:]=[n for n in structure if not isinstance(n,list) or n[0]!='rule']
    structure.append(['rule',['width','250'],['clearance','270']])
    network[:]=[n for n in network if not isinstance(n,list) or n[0]!='class']
    groups={}
    for item in effective:groups.setdefault((item['class'],item['width_mm']),[]).append(item['net'])
    for (name,width),nets in sorted(groups.items()):
        network.append(['class',quote(name),*[quote(n) for n in sorted(nets)],['circuit',['use_via',via]],['rule',['width',str(round(width*1000))],['clearance','270']]])
    def emit(node):return '('+' '.join(emit(n) if isinstance(n,list) else n for n in node)+')'
    path.write_text(emit(root)+'\n')
    after=invariant()
    if before!=after:raise RuntimeError('DSN non-rule geometry or connectivity changed')
    save_json(out/'dsn-rule-binding.json',{'native_export_sha256':sha(out/'shield-native-export.dsn'),'router_input_sha256':sha(path),'non_rule_tree_sha256':after,'native_netclasses':effective,'router_clearance_mm':.27,'router_edge_clearance_mm':.35,'geometry_unchanged':True})

def text(board,value,pos,size=.8,layer=None):
    t=pcbnew.PCB_TEXT(board);t.SetText(value);t.SetPosition(xy(pos));t.SetTextSize(pcbnew.VECTOR2I(round(size*1e6),round(size*1e6)))
    t.SetTextThickness(round(.13*1e6));t.SetLayer(pcbnew.F_SilkS if layer is None else layer);board.Add(t)

def ground_zone(board,layer,poly):
    zone=pcbnew.ZONE(board);zone.SetLayer(layer);zone.SetNet(board.FindNet('/GND'));zone.SetLocalClearance(pcbnew.FromMM(.25));zone.SetThermalReliefGap(pcbnew.FromMM(.3));zone.SetThermalReliefSpokeWidth(pcbnew.FromMM(.4))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL);zone.SetMinThickness(pcbnew.FromMM(.2))
    outline=zone.Outline();outline.NewOutline()
    for p in poly:v=xy(p);outline.Append(v.x,v.y)
    board.Add(zone)

def symbol_definition(p):
    ref=p['ref'];pins=sorted(p['nets'],key=lambda x:int(x));n=len(pins)
    left=pins[:math.ceil(n/2)];right=pins[math.ceil(n/2):]
    rows=max(len(left),len(right));height=max(2.54,(rows-1)*2.54/2+1.27);width=5.08 if n>2 else 2.54
    coords={}
    definitions=[]
    for side,seq in ((-1,left),(1,right)):
        for i,num in enumerate(seq):
            y=(len(seq)-1)*1.27-i*2.54;x=side*(width+2.54);angle=0 if side<0 else 180
            coords[num]=(x,y,side)
            pin_name=p['pin_names'].get(num,num)
            typ=p['pin_types'].get(num,'passive')
            definitions.append(f'(pin {typ} line (at {x} {y} {angle}) (length 2.54) (name {quote(pin_name)} (effects (font (size .8 .8)))) (number {quote(num)} (effects (font (size .8 .8)))))')
    bom='no' if ref.startswith(('TP','MH','JP')) else 'yes'
    s=f'''(symbol "VHOS:{ref}" (pin_names (offset .6)) (in_bom {bom}) (on_board yes)
      (property "Reference" {quote(ref)} (at 0 {height+2.54} 0) (effects (font (size 1 1))))
      (property "Value" {quote(p['value'])} (at 0 {-height-2.54} 0) (effects (font (size .9 .9))))
      (property "Footprint" {quote(p['footprint'])} (at 0 0 0) (effects (font (size 1 1)) hide))
      (symbol "{ref}_0_1" (rectangle (start {-width} {height}) (end {width} {-height}) (stroke (width .254) (type default)) (fill (type background))))
      (symbol "{ref}_1_1" {''.join(definitions)}))'''
    return s,coords,height

def schematic(parts,out):
    root_uuid=uid('sheet');symbols=[];items=[]
    sections={'power':(25,45,70,43,6),'headers':(25,245,70,43,6),'outputs':(25,390,70,43,6)}
    counts={k:0 for k in sections}
    # A1 provides room for explicit pin names and net labels without crossed wiring.
    for p in parts:
        section=p['section'];sx,sy,dx,dy,cols=sections[section];i=counts[section];counts[section]+=1
        x=round(round((sx+(i%cols)*dx+20)/1.27)*1.27,4);y=round(round((sy+(i//cols)*dy)/1.27)*1.27,4)
        definition,coords,height=symbol_definition(p);symbols.append(definition)
        ref=p['ref'];u=uid(ref)
        bom='no' if ref.startswith(('TP','MH','JP')) else 'yes'
        flags=f'(in_bom {bom}) (on_board yes) (dnp no)'
        items.append(f'''(symbol (lib_id "VHOS:{ref}") (at {x} {y} 0) (unit 1) {flags} (uuid "{u}")
          (property "Reference" {quote(ref)} (at {x} {y-height-3} 0) (effects (font (size 1 1))))
          (property "Value" {quote(p['value'])} (at {x} {y+height+3} 0) (effects (font (size .9 .9))))
          (property "Footprint" {quote(p['footprint'])} (at {x} {y} 0) (effects (font (size 1 1)) hide))
          (property "MPN" {quote(p['mpn'] or 'SELECTION_PENDING')} (at {x} {y} 0) (effects (font (size 1 1)) hide))
          {''.join('(pin '+quote(k)+' (uuid '+quote(uid(ref+'.pin.'+k))+'))' for k in coords)}
          (instances (project "{NAME}" (path "/{root_uuid}" (reference "{ref}") (unit 1)))))''')
        for number,(px,py,side) in coords.items():
            gx,gy=x+px,y-py;net=p['nets'][number]
            if net is None:
                items.append(f'(no_connect (at {gx} {gy}) (uuid "{uid(ref+number+"NC")}"))')
            else:
                end=gx+side*2.54
                items.append(f'(wire (pts (xy {gx} {gy}) (xy {end} {gy})) (stroke (width 0) (type default)) (uuid "{uid(ref+number+"wire")}"))')
                items.append(f'(label {quote(net)} (at {end} {gy} {180 if side<0 else 0}) (effects (font (size .8 .8)) (justify left bottom)) (uuid "{uid(ref+number+"label")}"))')
    # Power flags state the real intended sources beyond passive diode/inductor boundaries.
    flag='''(symbol "VHOS:PWR_FLAG" (power) (pin_names (offset 0) hide) (in_bom no) (on_board no)
      (property "Reference" "#FLG" (at 0 2.54 0) (effects (font (size 1 1)) hide))
      (property "Value" "PWR_FLAG" (at 0 3.81 0) (effects (font (size 1 1))))
      (symbol "PWR_FLAG_0_1" (polyline (pts (xy 0 0) (xy 0 1.27) (xy -.8 2) (xy 0 2.7) (xy .8 2) (xy 0 1.27)) (stroke (width .15) (type default)) (fill (type none))))
      (symbol "PWR_FLAG_1_1" (pin power_out line (at 0 0 90) (length 0) (name "pwr" (effects (font (size 1 1)))) (number "1" (effects (font (size 1 1)))))))'''
    symbols.append(flag)
    for i,net in enumerate(('GND','ACC_FUSED','VIN_PROT','V5_LOGIC')):
        x=round(round((470+i*45)/1.27)*1.27,4);y=44.45;ref='#FLG0'+str(i+1)
        items.append(f'''(symbol (lib_id "VHOS:PWR_FLAG") (at {x} {y} 0) (unit 1) (in_bom no) (on_board no) (dnp no) (uuid "{uid(ref)}")
          (property "Reference" "{ref}" (at {x} {y+2.54} 0) (effects (font (size 1 1)) hide))
          (property "Value" "PWR_FLAG" (at {x} {y-3.81} 0) (effects (font (size 1 1))))
          (pin "1" (uuid "{uid(ref+'pin')}"))
          (instances (project "{NAME}" (path "/{root_uuid}" (reference "{ref}") (unit 1)))))
          (label "{net}" (at {x} {y} 0) (effects (font (size 1 1)) (justify left bottom)) (uuid "{uid(ref+'net')}"))''')
    for title,y in [('PROTECTED 5V LOGIC - EXTERNAL BRANCH FUSE REQUIRED',20),('NOMINAL UNO HEADERS / ISOLATED ILL BREAKOUT',220),('ONE RGBW ZONE - EXTERNALLY POWERED LEDS',365)]:
        items.append(f'(text "{title}" (at 25 {y} 0) (effects (font (size 2 2)) (justify left bottom)) (uuid "{uid(title)}"))')
    items.append(f'(text "EVALUATION DRAFT / NO VEHICLE CONNECTION RELEASE. JP1 DEFAULT OPEN. M8 & TOYOTA CAVITIES UNVERIFIED." (at 25 586 0) (effects (font (size 1.3 1.3)) (justify left bottom)) (uuid "{uid("notice")}"))')
    source=f'''(kicad_sch (version 20250114) (generator "eeschema") (generator_version "10.0")
      (uuid "{root_uuid}") (paper "A1")
      (title_block (title "VHOS RGBW SHIELD - EVALUATION REV A") (rev "A") (company "4Runner Vehicle Health OS"))
      (lib_symbols {''.join(symbols)}) {''.join(items)} (sheet_instances (path "/" (page "1"))) (embedded_fonts no))'''
    (out/(NAME+'.kicad_sch')).write_text(source,encoding='utf-8')
    (out/'VHOS.kicad_sym').write_text('(kicad_symbol_lib (version 20250114) (generator "kicad_symbol_editor") '+''.join(s.replace('(symbol "VHOS:','(symbol "',1) for s in symbols)+')',encoding='utf-8')
    (out/'sym-lib-table').write_text('(sym_lib_table (lib (name "VHOS") (type "KiCad") (uri "${KIPRJMOD}/VHOS.kicad_sym") (options "") (descr "Rev A source-bound circuit symbols")))',encoding='utf-8')
    return root_uuid

def project(out):
    base={'clearance':.25,'track_width':.25,'via_diameter':.7,'via_drill':.3,'microvia_diameter':.3,'microvia_drill':.1,'diff_pair_width':.25,'diff_pair_gap':.25,'diff_pair_via_gap':.25,'wire_width':6,'bus_width':12,'line_style':0,'name':'Default','priority':2147483647,'schematic_color':'rgba(0, 0, 0, 0.000)','pcb_color':'rgba(0, 0, 0, 0.000)'}
    power={**base,'name':'Power','track_width':.8,'priority':0}
    led={**base,'name':'LED','track_width':1.0,'priority':1}
    p={'meta':{'filename':NAME+'.kicad_pro','version':3},'board':{'design_settings':{'rules':{'min_clearance':.2,'min_track_width':.2,'min_via_diameter':.6,'min_through_hole_diameter':.3,'min_via_annular_width':.15,'min_copper_edge_clearance':.3},'drc_exclusions':[]}},
       'net_settings':{'classes':[base,power,led],'netclass_patterns':[{'pattern':'LED_*','netclass':'LED'},{'pattern':'SW','netclass':'Power'},{'pattern':'V5_LOGIC','netclass':'Power'},{'pattern':'VIN_PROT','netclass':'Power'},{'pattern':'ACC_FUSED','netclass':'Power'}]},'erc':{'erc_exclusions':[]}}
    for rule in p['net_settings']['netclass_patterns']:rule['pattern']='/'+rule['pattern']
    save_json(out/(NAME+'.kicad_pro'),p)

def load_project(board,out):
    mgr=pcbnew.GetSettingsManager()
    if not mgr.LoadProject(str(out/(NAME+'.kicad_pro'))):raise RuntimeError('native project load failed')
    board.SetProject(mgr.Prj())
    return mgr

def observation(board):
    return sorted([{'ref':fp.GetReference(),'value':fp.GetValue(),'footprint':fp.GetFPID().GetUniStringLibId(),
                    'xy_nm':[fp.GetPosition().x,fp.GetPosition().y],'angle':fp.GetOrientationDegrees(),
                    'pads':sorted([[p.GetNumber(),str(p.GetNetname()),p.GetPosition().x,p.GetPosition().y] for p in fp.Pads() if p.GetNumber()])}
                   for fp in board.GetFootprints()],key=lambda x:x['ref'])

def build(out,inputs):
    parts=design(inputs['headers'])
    for p in parts:
        if p['ref'] in ('J1','J2'):
            p['source_footprint']=p['footprint'];p['footprint']='VHOS_Connectors:'+p['footprint'].split(':',1)[1]
    project(out);sheet=schematic(parts,out)
    print('BUILD: schematic written',flush=True)
    board=pcbnew.BOARD();board.GetDesignSettings().SetBoardThickness(pcbnew.FromMM(1.6))
    print('BUILD: new board initialized',flush=True)
    net_names=sorted({n for p in parts for n in p['nets'].values() if n});nets={}
    for name in net_names:
        net=pcbnew.NETINFO_ITEM(board,'/'+name);board.Add(net);nets[name]=net
    for p in parts:
        for pin,name in p['nets'].items():
            if name is None:
                key=f"unconnected-({p['ref']}-Pad{pin})";net=pcbnew.NETINFO_ITEM(board,key);board.Add(net);nets[key]=net
    libraries={};footprint_sources=[]
    model_info=inputs['pcb_input_connector_model'];model_dir=out/'models';model_dir.mkdir()
    import shutil
    shutil.copyfile(ROOT/'inputs'/model_info['name'],model_dir/model_info['name'])
    for p in parts:
        print('BUILD: footprint '+p['ref'],flush=True)
        lib,fpname=p.get('source_footprint',p['footprint']).split(':',1);path=LIB/(lib+'.pretty')
        if not (path/(fpname+'.kicad_mod')).is_file():raise FileNotFoundError(p['footprint'])
        fp=pcbnew.FootprintLoad(str(path),fpname)
        if fp is None:raise RuntimeError('missing footprint '+p['footprint'])
        libraries[lib]='${KICAD10_FOOTPRINT_DIR}/'+lib+'.pretty'
        footprint_sources.append({'id':p['footprint'],'sha256':sha(path/(fpname+'.kicad_mod'))})
        fp.SetFPID(pcbnew.LIB_ID(lib,fpname))
        fp.SetReference(p['ref']);fp.SetValue(p['value']);fp.SetPosition(xy(p['xy_mm']));fp.SetOrientationDegrees(p['angle_deg'])
        field=pcbnew.PCB_FIELD(fp,pcbnew.FIELD_T_USER,'MPN');field.SetText(p['mpn'] or 'SELECTION_PENDING');field.SetVisible(False);field.SetLayer(pcbnew.F_Fab);fp.Add(field)
        fp.SetPath(pcbnew.KIID_PATH('/'+sheet+'/'+uid(p['ref'])))
        if p.get('absolute_pads_mm'):
            found=False
            for a in (0,90,180,270):
                fp.SetOrientationDegrees(a)
                positions={p2.GetNumber():p2.GetPosition() for p2 in fp.Pads()}
                if all((positions[p3['eagle_pad']]-xy([p3['x_mm'],p3['y_mm']])).EuclideanNorm()<5 for p3 in p['absolute_pads_mm']):
                    found=True;break
            if not found:raise RuntimeError('no exact nominal header transform '+p['ref'])
        for pad in fp.Pads():
            name=p['nets'].get(pad.GetNumber())
            if name:pad.SetNet(nets[name])
            elif pad.GetNumber() in p['nets']:pad.SetNet(nets[f"unconnected-({p['ref']}-Pad{pad.GetNumber()})"])
        if p['ref'] in ('J1','J2'):
            for graphic in fp.GraphicalItems():
                if graphic.GetLayer()==pcbnew.F_SilkS:graphic.SetLayer(pcbnew.F_Fab)
            if p['ref']=='J1':
                fp.Models().clear();model=pcbnew.FP_3DMODEL();model.m_Filename='${KIPRJMOD}/models/'+model_info['name'];fp.Models().push_back(model)
            custom=out/'VHOS_Connectors.pretty';custom.mkdir(exist_ok=True)
            pcbnew.PCB_IO_MGR.FindPlugin(pcbnew.PCB_IO_MGR.KICAD_SEXP).FootprintSave(str(custom),fp)
            fp.SetFPID(pcbnew.LIB_ID('VHOS_Connectors',fpname))
            libraries['VHOS_Connectors']='${KIPRJMOD}/VHOS_Connectors.pretty'
        for field in (fp.Reference(),fp.Value()):field.SetLayer(pcbnew.F_Fab);field.SetVisible(True)
        board.Add(fp)
    # A left mounting wing carries connector loads into two independent case posts.
    polygon=[(-10,0),(68.58,0),(68.58,10),(48,10),(48,43),(68.58,43),(68.58,53.34),(-10,53.34)]
    for a,b in zip(polygon,polygon[1:]+polygon[:1]):
        edge=pcbnew.PCB_SHAPE(board);edge.SetShape(pcbnew.SHAPE_T_SEGMENT);edge.SetStart(xy(a));edge.SetEnd(xy(b));edge.SetLayer(pcbnew.Edge_Cuts);edge.SetWidth(pcbnew.FromMM(.05));board.Add(edge)
    mounts=[(-6,5.2),(-5,34)]
    # Reserve short 0.8mm VDD/decoupler links before global routing. The two
    # capacitor VDD pads face each other; their ground pads face outward.
    fps={fp.GetReference():fp for fp in board.GetFootprints()}
    def pad(ref,num):return next(p.GetPosition() for p in fps[ref].Pads() if p.GetNumber()==str(num))
    def copper(start,end,net,width=.8):
        track=pcbnew.PCB_TRACK(board);track.SetStart(start);track.SetEnd(end);track.SetWidth(pcbnew.FromMM(width));track.SetLayer(pcbnew.F_Cu);track.SetNet(nets[net]);track.SetLocked(True);board.Add(track)
    for driver,first,second,x in [('U2','C9','C10',36.8),('U3','C11','C12',46.8)]:
        copper(pad(driver,6),pad(first,1),'V5_LOGIC')
        middle=xy((x,12.5));copper(pad(first,1),middle,'V5_LOGIC');copper(middle,pad(second,1),'V5_LOGIC')
        via=pcbnew.PCB_VIA(board);via.SetPosition(middle);via.SetWidth(pcbnew.FromMM(.7));via.SetDrill(pcbnew.FromMM(.3));via.SetLayerPair(pcbnew.F_Cu,pcbnew.B_Cu);via.SetNet(nets['V5_LOGIC']);via.SetLocked(True);board.Add(via)
    # Keep switching-stage ground beneath the exposed pad free of signal tracks.
    keepout=pcbnew.ZONE(board);keepout.SetLayer(pcbnew.B_Cu);keepout.SetIsRuleArea(True);keepout.SetDoNotAllowTracks(True);keepout.SetDoNotAllowVias(False);keepout.SetDoNotAllowZoneFills(False)
    polygon2=keepout.Outline();polygon2.NewOutline()
    for p in [(28.45,32.9),(30.95,32.9),(30.95,36.1),(28.45,36.1)]:v=xy(p);polygon2.Append(v.x,v.y)
    board.Add(keepout)
    # Export a real ground plane so the router can fan SMD returns into it.
    ground_zone(board,pcbnew.B_Cu,polygon)
    text(board,'VHOS RGBW A / BENCH ONLY',(54,46),1)
    text(board,'JP1 OPEN: USB',(34,9),.65,pcbnew.F_Fab)
    for label,y in [('R-',27),('G-',23.19),('B-',19.38),('W-',15.57),('GND',11.76)]:text(board,label,(0,y),.8)
    text(board,'RF OPENING - POSITION UNVERIFIED',(53,26),.8,pcbnew.Dwgs_User)
    text(board,'EXTERNAL LED + / NO LED + ON PCB',(15,29),.6,pcbnew.Dwgs_User)
    board.SetAuxOrigin(xy((0,0))) if hasattr(board,'SetAuxOrigin') else None
    pcbnew.SaveBoard(str(out/(NAME+'.kicad_pcb')),board,True)
    table='(fp_lib_table\n'+''.join(f'(lib (name "{k}")(type "KiCad")(uri "{v}")(options "")(descr "Installed Orion KiCad 10.0.6 reference"))\n' for k,v in sorted(libraries.items()))+')\n'
    (out/'fp-lib-table').write_text(table,encoding='utf-8')
    save_json(out/'circuit-design.json',parts);save_json(out/'placed-identity.json',observation(board));save_json(out/'footprint-sources.json',footprint_sources)
    with (out/'BOM-DRAFT.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=['ref','value','mpn','footprint','note']);w.writeheader();w.writerows({k:p[k] for k in w.fieldnames} for p in parts)
    save_json(out/'pcb-outline.json',{'polygon_mm':polygon,'mounts_mm':mounts,'units':'mm','physical_fit_verified':False})
    # LoadBoard initializes the native KiCad project context before settings access.
    board=pcbnew.LoadBoard(str(out/(NAME+'.kicad_pcb')));manager=load_project(board,out)
    board.BuildConnectivity()
    effective=[]
    for name,net in board.GetNetsByName().items():
        if not str(name):continue
        nc=net.GetNetClassSlow();width=nc.GetTrackWidth();expected=1.0 if str(name).startswith('/LED_') else (.8 if str(name) in ['/SW','/V5_LOGIC','/VIN_PROT','/ACC_FUSED'] else .25)
        if width!=pcbnew.FromMM(expected):raise RuntimeError('native netclass width differs from project '+str(name))
        effective.append({'net':str(name),'class':str(nc.GetName()),'width_mm':pcbnew.ToMM(width),'clearance_mm':pcbnew.ToMM(nc.GetClearance())})
    save_json(out/'effective-netclasses.json',effective)
    if not pcbnew.ExportSpecctraDSN(board,str(out/'shield.dsn')):raise RuntimeError('DSN export failed')
    bind_dsn_rules(out,effective)
    save_json(out/'native-toolchain.json',{'version':pcbnew.GetBuildVersion(),'python_sha256':sha(Path(sys.executable)),'pcbnew_sha256':sha(Path(pcbnew.__file__))})
    return {'components':len(parts),'nets':len(net_names),'nominal_header_positions':32,'source_routed':False}

def import_route(out):
    path=out/(NAME+'.kicad_pcb');board=pcbnew.LoadBoard(str(path));manager=load_project(board,out);before=observation(board)
    if not pcbnew.ImportSpecctraSES(board,str(out/'shield.ses')):raise RuntimeError('SES import failed')
    if before!=observation(board):raise RuntimeError('router changed part or pad identities')
    for dx in (-.55,.55):
        for dy in (-.9,.9):
            via=pcbnew.PCB_VIA(board);via.SetPosition(xy((29.7+dx,34.5+dy)));via.SetWidth(pcbnew.FromMM(.7));via.SetDrill(pcbnew.FromMM(.3));via.SetLayerPair(pcbnew.F_Cu,pcbnew.B_Cu);via.SetNet(board.FindNet('/GND'));via.SetLocked(True);board.Add(via)
    # Fill both real copper planes on the actual native board; never render a fake copper image.
    gnd=board.FindNet('/GND')
    poly=json.loads((out/'pcb-outline.json').read_text())['polygon_mm']
    ground_zone(board,pcbnew.F_Cu,poly)
    filler=pcbnew.ZONE_FILLER(board);filler.Fill(board.Zones());board.BuildConnectivity()
    pcbnew.SaveBoard(str(path),board,True)
    if observation(pcbnew.LoadBoard(str(path)))!=before:raise RuntimeError('saved routed board identity drift')
    save_json(out/'route-identity.json',{'part_identity_preserved':True,'segments':sum(t.GetClass()=='PCB_TRACK' for t in board.GetTracks()),'vias':sum(t.GetClass()=='PCB_VIA' for t in board.GetTracks()),'zones':len(board.Zones()),'parts':before})
    widths=[]
    for net in sorted({str(t.GetNetname()) for t in board.GetTracks()}):
        tracks=[t for t in board.GetTracks() if t.GetClass()=='PCB_TRACK' and str(t.GetNetname())==net]
        if not tracks:continue
        required=1.0 if net.startswith('/LED_') else (.8 if net in ['/SW','/V5_LOGIC','/VIN_PROT','/ACC_FUSED'] else .25)
        actual=min(pcbnew.ToMM(t.GetWidth()) for t in tracks)
        if actual<required-1e-6:raise RuntimeError('routed copper width below declared minimum '+net)
        widths.append({'net':net,'minimum_width_mm':actual,'required_minimum_mm':required,'total_length_mm':sum(pcbnew.ToMM(t.GetLength()) for t in tracks)})
    save_json(out/'routed-width-audit.json',{'tracks':widths,'ground_strategy':'0.25mm logic pad escapes plus F/B solid-connected pours; LED return ampacity unqualified','accepted_against_declared_minimums':True})

def reconcile(out):
    board=pcbnew.LoadBoard(str(out/(NAME+'.kicad_pcb')))
    expected={p['ref']:{k:n for k,n in p['nets'].items() if n} for p in json.loads((out/'circuit-design.json').read_text())}
    root=ET.parse(out/'schematic.net.xml').getroot();actual={r:{} for r in expected}
    for net in root.findall('./nets/net'):
        name=net.attrib['name']
        if name.startswith('/'):name=name[1:]
        for node in net.findall('node'):
            ref,pin=node.attrib['ref'],node.attrib['pin']
            if ref in actual and pin in expected[ref]:actual[ref][pin]=name
    if actual!=expected:raise RuntimeError('schematic pin/net map differs from design '+repr([(r,expected[r],actual[r]) for r in actual if actual[r]!=expected[r]]))
    pcb_map={fp.GetReference():{p.GetNumber():str(p.GetNetname()).removeprefix('/') for p in fp.Pads() if p.GetNumber() and str(p.GetNetname()) and not str(p.GetNetname()).startswith('unconnected-(')} for fp in board.GetFootprints() if fp.GetReference() in expected}
    if pcb_map!=expected:raise RuntimeError('PCB pin/net map differs from schematic')
    save_json(out/'connectivity-reconciliation.json',{'schematic_matches_pcb':True,'components':len(expected),'connected_pin_instances':sum(map(len,expected.values())),'header_positions_match_official_nominal_reference':32,'physical_header_match_verified':False})

def main():
    global pcbnew
    if platform.system()!='Windows' or platform.node().split('.')[0].casefold()!='orion':raise RuntimeError('Orion native execution required')
    import pcbnew
    if pcbnew.GetBuildVersion()!='10.0.6':raise RuntimeError('KiCad 10.0.6 required')
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['build','import','reconcile']);parser.add_argument('--out',type=Path,required=True);a=parser.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    if a.action=='build':print(json.dumps(build(a.out,json.loads((ROOT/'engineering-inputs.json').read_text()))))
    elif a.action=='import':import_route(a.out)
    else:reconcile(a.out)
if __name__=='__main__':main()
