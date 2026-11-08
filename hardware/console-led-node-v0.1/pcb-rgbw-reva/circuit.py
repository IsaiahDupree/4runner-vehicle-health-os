"""Rev A evaluation circuit. Named interfaces are proposals, never Toyota/M8 pin evidence."""
from __future__ import annotations

def design(headers):
    parts = []
    def add(ref, value, footprint, nets, xy, angle=0, names=None, types=None, mpn=None, note='', section='power'):
        pins = {str(k): v for k, v in nets.items()}
        parts.append(dict(ref=ref, value=value, footprint=footprint, nets=pins,
                          xy_mm=list(xy), angle_deg=angle, pin_names=names or {},
                          pin_types=types or {}, mpn=mpn, note=note, section=section))
    rfp = 'Resistor_SMD:R_0603_1608Metric'
    cfp = 'Capacitor_SMD:C_0603_1608Metric'
    def resistor(ref, val, a, b, xy, angle=0, section='power', fp=rfp):
        add(ref, val, fp, {1:a,2:b}, xy, angle, section=section, note='1%, final orderable manufacturer suffix pending')
    def cap(ref, val, a, b, xy, angle=0, fp=cfp, mpn=None, section='power'):
        add(ref, val, fp, {1:a,2:b}, xy, angle, mpn=mpn, section=section)
    add('J1','CONSOLE_BRANCH_ONLY','Connector_Molex:Molex_Micro-Fit_3.0_43045-0600_2x03_P3.00mm_Horizontal',
        {1:'ISO_ILL1_P',2:'ISO_ILL1_N',3:'ISO_ILL2_P',4:'ISO_ILL2_N',5:'GND',6:'ACC_FUSED'},(5,44),90,
        mpn='43045-0600',note='Conditional adapter map; exact Toyota cavities remain unverified. External branch fuse required.',section='headers')
    add('J2','R- G- B- W- LED_GND','Connector_Phoenix_MC:PhoenixContact_MC_1,5_5-G-3.81_1x05_P3.81mm_Horizontal',
        {1:'LED_R_NEG',2:'LED_G_NEG',3:'LED_B_NEG',4:'LED_W_NEG',5:'GND'},(-3,27),270,
        mpn='1803303',note='Dry-cabin connector. Common LED positive is supplied externally, outside PCB. Mate 1803604.',section='outputs')
    add('D1','STPS2H100AY','Diode_SMD:D_SMA',{1:'VIN_PROT',2:'ACC_FUSED'},(18,39),0,
        names={'1':'K','2':'A'},mpn='STPS2H100AY',note='Series reverse-battery diode; surge/fuse coordination unqualified')
    add('D2','SMBJ24A','Diode_SMD:D_SMB',{1:'VIN_PROT',2:'GND'},(18,45),0,
        names={'1':'K','2':'A'},mpn='SMBJ24A',note='Logic input clamp candidate; not a complete load-dump qualification')
    cap('C1','10u 63V EEEFK1J100P','VIN_PROT','GND',(24,43),fp='Capacitor_SMD:CP_Elec_6.3x5.8',
        mpn='EEEFK1J100P',section='power')
    parts[-1]['note']='Polar bulk damping candidate; manufacturer 6.3mm diameter, 5.8mm body height. Cable-response/ripple validation pending.'
    cap('C2','2.2u 100V X7R','VIN_PROT','GND',(26,33.6),90,
        'Capacitor_SMD:C_1210_3225Metric','CGA6N3X7R2A225K230AB')
    cap('C3','2.2u 100V X7R','VIN_PROT','GND',(22.5,33.6),90,
        'Capacitor_SMD:C_1210_3225Metric','CGA6N3X7R2A225K230AB')
    add('U1','LM5164QDDARQ1','Package_SO:HSOP-8-1EP_3.9x4.9mm_P1.27mm_EP2.41x3.1mm',
        {1:'GND',2:'VIN_PROT',3:'UVLO',4:'RON',5:'FB',6:'PGOOD',7:'BST',8:'SW',9:'GND'},(31,33),0,
        names={'1':'GND','2':'VIN','3':'EN_UVLO','4':'RON','5':'FB','6':'PGOOD','7':'BST','8':'SW','9':'EP_GND'},
        types={'1':'power_in','2':'power_in','3':'input','4':'passive','5':'input','6':'open_collector','7':'passive','8':'power_out','9':'power_in'},
        mpn='LM5164QDDARQ1',note='5V logic only; target 0.5A evaluation load, thermal and transient tests pending')
    add('L1','68u MSS1246T-683MLC','Inductor_SMD:L_Coilcraft_MSS1246T-XXX',{1:'SW',2:'V5_LOGIC'},(40,32),0,
        mpn='MSS1246T-683MLC')
    resistor('R1','41.2k','RON','GND',(26,28),0)
    resistor('R2','1M','VIN_PROT','UVLO',(24,37.5),0)
    resistor('R3','221k','UVLO','GND',(28,37.5),0)
    resistor('R4','158k','V5_LOGIC','FB',(32,26.5),0)
    resistor('R5','49.9k','FB','GND',(28,25),0)
    resistor('R6','150k','SW','RIPPLE',(36,24),0)
    cap('C4','2.2n 50V X7R','BST','SW',(34.5,35),90)
    cap('C5','3.3n 50V X7R','RIPPLE','V5_LOGIC',(40,24),0)
    cap('C6','180p C0G','RIPPLE','FB',(32,23),0)
    for ref,xy in [('C7',(43,40.5)),('C8',(39,40.5))]:
        cap(ref,'22u 25V X7R','V5_LOGIC','GND',xy,90,'Capacitor_SMD:C_1210_3225Metric','TMK325B7226KMHT')
    resistor('R7','100k','V5_LOGIC','PGOOD',(31,40.5),0)
    add('JP1','OPEN: USB ISOLATION','Jumper:SolderJumper-2_P1.3mm_Open_RoundedPad1.0x1.5mm',
        {1:'V5_LOGIC',2:'ESP_5V'},(34.5,6.5),0,note='DEFAULT OPEN. Bridge only for qualified shield feed with USB physically disconnected.',section='headers')
    # Official UNO positions are nominal references, not measured ShengYang geometry.
    header_nets={
        'IOL':{3:'PWM_R',4:'PWM_G',8:'PWM_B'},
        'IOH':{1:'ENABLE_REQ',7:'GND'},
        'AD':{1:'PWM_W'},
        'POWER':{5:'ESP_5V',6:'GND',7:'GND'},
    }
    for name,ref in [('IOL','H1'),('IOH','H2'),('POWER','H3'),('AD','H4')]:
        group=next(g for g in headers['headers'] if g['name']==name)
        pts=group['pads'];n=group['count'];nets={i:header_nets[name].get(i) for i in range(1,n+1)}
        add(ref,name+'_NOMINAL',f'Connector_PinSocket_2.54mm:PinSocket_1x{n:02d}_P2.54mm_Vertical',nets,(pts[0]['x_mm'],pts[0]['y_mm']),
            types={str(k):'output' for k in header_nets[name] if header_nets[name][k].startswith(('PWM_','ENABLE_'))},
            note='UNO R3 nominal center coordinates; exact board continuity and stack hardware pending',section='headers')
        parts[-1]['absolute_pads_mm']=pts
    for ref,x,net in [('TP1',9,'ISO_ILL1_P'),('TP2',13,'ISO_ILL1_N'),('TP3',17,'ISO_ILL2_P'),('TP4',21,'ISO_ILL2_N')]:
        add(ref,net,'TestPoint:TestPoint_Pad_D1.0mm',{1:net},(x,30),section='headers')
    for ref,net,xy in [('TP5','V5_LOGIC',(46,45)),('TP6','GND',(42,45)),('TP7','PGOOD',(34,44)),('TP8','ENABLE_REQ',(29,7))]:
        add(ref,net,'TestPoint:TestPoint_Pad_D1.0mm',{1:net},xy,section='headers')
    for ref,xy,na,nb in [('U2',(25,13),'R','G'),('U3',(37,13),'B','W')]:
        add(ref,'UCC27524AQDRQ1','Package_SO:SOIC-8_3.9x4.9mm_P1.27mm',
            {1:'ENABLE_REQ',2:'PWM_'+na,3:'GND',4:'PWM_'+nb,5:'DRV_'+nb,6:'V5_LOGIC',7:'DRV_'+na,8:'ENABLE_REQ'},xy,
            names={'1':'ENA','2':'INA','3':'GND','4':'INB','5':'OUTB','6':'VDD','7':'OUTA','8':'ENB'},
            types={'1':'input','2':'input','3':'power_in','4':'input','5':'output','6':'power_in','7':'output','8':'input'},
            mpn='UCC27524AQDRQ1',note='5V gate drive; enables have internal pullups overridden by external 2.2k pulldown',section='outputs')
    for ref,xy in [('C9',(28.5,10.5)),('C11',(40.5,10.5))]:
        cap(ref,'100n 25V X7R','V5_LOGIC','GND',xy,90,section='outputs')
    for ref,xy in [('C10',(29,15.5)),('C12',(41,15.5))]:
        cap(ref,'1u 25V X7R','V5_LOGIC','GND',xy,90,section='outputs')
    resistor('R8','2.2k','ENABLE_REQ','GND',(24,7),0,section='outputs')
    # Four separate LFPAK56 devices give accessible source/gate/drain landmarks.
    for i,(color,xy) in enumerate([('R',(11,10)),('G',(11,21)),('B',(22,10)),('W',(22,21))],1):
        add('Q'+str(i),'BUK9Y15-60E','Package_TO_SOT_SMD:LFPAK56',
            {1:'GND',2:'GND',3:'GND',4:'GATE_'+color,5:'LED_'+color+'_NEG'},xy,0,
            names={'1':'S1','2':'S2','3':'S3','4':'G','5':'D_MB'},mpn='BUK9Y15-60E,115',
            note='60V; 15mOhm max at 5V gate, 25C. Layout/current ratings remain evaluation targets.',section='outputs')
        resistor('R'+str(8+i),'100','DRV_'+color,'GATE_'+color,(xy[0]-3,xy[1]-4.5),0,section='outputs')
        resistor('R'+str(12+i),'10k','GATE_'+color,'GND',(xy[0]+1,xy[1]-4.5),0,section='outputs')
        resistor('R'+str(16+i),'100k','PWM_'+color,'GND',(28+4*(i-1),20),90,section='outputs')
        add('D'+str(2+i),'SMBJ24CA','Diode_SMD:D_SMB',{1:'LED_'+color+'_NEG',2:'GND'},(3.5,9+8*(i-1)),90,
            mpn='SMBJ24CA',note='Bidirectional output clamp candidate; cable-energy test pending',section='outputs')
    positions={'D1':(12,37),'D2':(34,45),'C1':(21,44),'C2':(23.2,36.3),'C3':(18,36.3),
               'U1':(29.7,34.5),'L1':(41.2,32),'R1':(26,28),'R2':(25.5,39),'R3':(29,39.5),
               'C4':(33.3,39),'C7':(45.5,43.5),'C8':(40.5,43.5),'R7':(31,41.8),
               'U2':(32,12),'U3':(42,12),'C9':(36.8,10.5),'C10':(36.8,14.5),
               'C11':(46.8,10.5),'C12':(46.8,14.5),'R8':(29,7),
               'TP5':(46,48),'TP6':(42,48),'TP7':(39.5,48),'TP8':(27,16.5)}
    for p in parts:
        if p['ref'] in positions:p['xy_mm']=list(positions[p['ref']])
        if p['ref'] in ('C2','C3'):p['angle_deg']=180
        if p['ref'] in ('C7','C8'):p['angle_deg']=0
        if p['ref'] in ('C9','C11'):p['angle_deg']=270
    for i,xy in enumerate([(-6,5.2),(-5,34)],1):
        add('MH'+str(i),'M3 SUPPORT','MountingHole:MountingHole_3.2mm_M3',{},xy,section='headers',note='Mechanical support; nominal carrier tower only')
    return parts
