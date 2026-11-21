"""Bounded DC/tolerance screen of the real Rev I divider; not a transient simulation."""
from decimal import Decimal as D
import itertools
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
import terminal_design


def screen():
    parts={p['ref']:p for p in terminal_design.parts()}
    expected={'R40':('49.9k 0.1%','RT1206BRD0749K9L'),'R41':('49.9k 0.1%','RT1206BRD0749K9L'),
      'R42':('22k 1%','0603WAF2202T5E'),'R43':('18k 1%','0603WAF1802T5E'),
      'R44':('22k 1%','0603WAF2202T5E'),'U12':('LM4040 2.5V','LM4040C25QFTA'),
      'D10':('NSVBAT54HT1G','NSVBAT54HT1G'),'C32':('100n 50V','CC0603KRX7R9BB104')}
    for ref,(value,mpn) in expected.items():
        if (parts[ref]['value'],parts[ref]['mpn'])!=(value,mpn):raise ValueError('Unexpected sensor part '+ref)
    gains=[];neg=[];clamp=[]
    nominal=[D(49900),D(49900),D(22000),D(18000),D(22000)]
    for signs in itertools.product((-1,1),repeat=5):
        a,b,c,d,e=[n*(1+D(s)*tol) for n,s,tol in zip(nominal,signs,[D('.001'),D('.001'),D('.01'),D('.01'),D('.01')])]
        parallel=1/(1/c+1/(d+e))
        gains.append(parallel/(a+b+parallel)*e/(d+e))
        neg.append(D('-.5')*e/(d+e));clamp.append(D('2.55')*e/(d+e))
    catalog=json.loads((ROOT.parent/'pcb-rgbw-revh/jlcpcb/catalog-live.json').read_text())
    by_mpn={row['mpn']:row for row in catalog['rows']}
    delta=sum(D(str(by_mpn[mpn]['unit_usd_at_one_board_quantity'])) for _,mpn in expected.values())
    return {'contract':'vhos.revi.voltage-screen@1.0.0','method':'32 resistor tolerance corners; static clamp assumptions',
      'source_node':'ACC_FUSED','gpio':1,'gain_nominal':float((1/(1/D(22000)+1/D(40000)))/(D(99800)+1/(1/D(22000)+1/D(40000)))*D(22000)/D(40000)),
      'gain_min_max':[float(min(gains)),float(max(gains))],
      'adc_v_at_14_4_input':[float(D('14.4')*min(gains)),float(D('14.4')*max(gains))],
      'adc_negative_bound_v_assuming_switch_minus_0_5_v':float(min(neg)),
      'adc_positive_bound_v_assuming_clamp_2_55_v':float(max(clamp)),
      'added_populated_positions':8,'added_unique_manufacturer_skus':0,
      'material_delta_usd_at_retained_snapshot':str(delta),
      'total_component_material_usd_at_retained_snapshot':str(D(str(catalog['material_subtotal_usd_at_one_board_quantity']))+delta),
      'catalog_snapshot':'../pcb-rgbw-revh/jlcpcb/catalog-live.json',
      'assumptions':['Existing SN3257-Q1 channel 3 switches to ground until CHIP_EN releases.',
        'Existing automotive LM4040 and BAT54 clamp behavior/energy require the same physical acceptance as TAIL/DIM.',
        'Nominal transfer uses two 49.9k, a 22k shunt, 18k ADC isolation and 22k ADC pull-down.',
        'Nominal DC estimates are uncalibrated; two-point calibration is required for a calibrated reading.',
        'The input is switched ACC, not a battery-post or ignition-off measurement.'],
      'physical_or_transient_qualification':False,'manufacturing_released':False}


if __name__=='__main__':
    report=screen()
    print(json.dumps(report,indent=2))
