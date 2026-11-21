"""Reconcile the real routed Rev I board, factory files and native case exports."""
from collections import Counter
import csv
from decimal import Decimal
from hashlib import sha256
import importlib.util
import json
from pathlib import Path
import re
import zipfile


REV = Path(__file__).resolve().parents[1] / 'hardware/console-led-node-v0.1/pcb-rgbw-revi'
BASE = REV.parent / 'pcb-rgbw-revh'
ADDED = {'R40', 'R41', 'R42', 'R43', 'R44', 'U12', 'D10', 'C32'}


def read(path):
    return json.loads(path.read_text())


def rows(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))


def board():
    spec = importlib.util.spec_from_file_location('actual_board_parser', BASE/'publish_handoff.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.board_parts(REV/'generated/vhos_rgbw_revi.kicad_pcb')


def test_voltage_branch_and_existing_wire_reserves_in_actual_saved_board():
    parts = board()
    assert parts['F1']['pad_nets'] == {'1': '/VEH_ACC', '2': '/ACC_FUSED'}
    expected = {
        'R40': ('/ACC_FUSED', '/VOLT_SERIES'),
        'R41': ('/VOLT_SERIES', '/VOLT_CLAMP'),
        'R42': ('/VOLT_CLAMP', '/GND'),
        'R43': ('/VOLT_SW', '/VOLT_ADC'),
        'R44': ('/VOLT_ADC', '/GND'),
        'C32': ('/VOLT_ADC', '/GND'),
        'D10': ('/VOLT_CLAMP', '/GND'),
    }
    for ref, nets in expected.items():
        assert parts[ref]['pad_nets'] == dict(zip(('1', '2'), nets))
    assert parts['U12']['pad_nets'] == {'1': '/VOLT_CLAMP', '2': '/GND', '3': '/GND'}
    assert {pin: parts['U5']['pad_nets'][pin] for pin in ('9', '10', '11')} == {
        '9': '/VOLT_SW', '10': '/VOLT_CLAMP', '11': '/GND'}
    assert parts['U11']['pad_nets']['39'] == '/VOLT_ADC'
    change = read(REV/'generated/voltage-change.json')
    assert change['external_inlets_added'] == 0
    assert parts['JT1']['pad_nets'] == {'1': '/GND', '2': '/VEH_ACC'}
    assert parts['JT2']['pad_nets'] == {'1': '/TAIL_12V', '2': '/DIM_RETURN'}
    for ref, (xy, angle) in change['existing_footprint_poses'].items():
        assert [parts[ref]['x_mm'], parts[ref]['y_mm']] == xy
        assert parts[ref]['rotation_deg'] == angle
    for ref, pin in (('JT3', '1'), ('JT3', '2'), ('JT6', '2')):
        assert parts[ref]['pad_nets'][pin].startswith('unconnected-')
    wires = rows(REV/'WIRE-REGISTER.csv')
    assert wires == rows(BASE/'WIRE-REGISTER.csv')
    assert Counter(w['Toyota cavity'] for w in wires if w['Toyota cavity']) == Counter('123456')


def test_factory_bom_and_centroids_match_every_actual_populated_position():
    parts = board()
    catalog = read(REV/'jlcpcb/catalog-derived.json')
    assert catalog['source_catalog_sha256'] == sha256((BASE/'jlcpcb/catalog-live.json').read_bytes()).hexdigest()
    by_code = {r['code']: r for r in catalog['rows']}
    selected = Counter()
    subtotal = Decimal(0)
    for group in rows(REV/'jlcpcb/BOM.csv'):
        refs = group['Designator'].split(',')
        capture = by_code[group['JLCPCB Part #']]
        assert capture['mpn'] == group['Comment'] and capture['status'] == 'captured'
        assert capture['quantity_per_board'] == len(refs)
        for ref in refs:
            assert parts[ref]['mpn'] == group['Comment']
            assert parts[ref]['footprint'].split(':')[-1] == group['Footprint']
        subtotal += Decimal(str(capture['unit_usd_at_one_board_quantity'])) * len(refs)
        selected.update(refs)
    actual = {ref for ref, p in parts.items() if p['mpn'] and not ref.startswith(('TP', 'MH'))}
    assert set(selected) == actual and len(selected) == 75 and set(selected.values()) == {1}
    assert ADDED <= actual and len(by_code) == 31
    placements = rows(REV/'jlcpcb/CPL.csv')
    assert Counter(p['Designator'] for p in placements) == selected
    for placement in placements:
        ref = placement['Designator']
        p = parts[ref]
        x, y = p['x_mm'], p['y_mm']
        if ref.startswith('JT'):
            x -= .05
            y += 2.54
        assert abs(float(placement['Mid X'].removesuffix('mm')) - x) < .001
        assert abs(float(placement['Mid Y'].removesuffix('mm')) + y) < .001
        assert (float(placement['Rotation']) - p['rotation_deg']) % 360 < .001
    assert subtotal == Decimal(str(catalog['material_subtotal_usd_at_one_board_quantity'])) == Decimal('24.4326')
    assert not catalog['finished_product_quote_verified']


def test_native_pcb_case_and_print_evidence_are_consistent_and_hash_bound():
    receipt = read(REV/'generated/verification.json')
    for name, item in receipt['published_files'].items():
        assert sha256((REV/name).read_bytes()).hexdigest() == item['sha256'], name
    assert all(j['status'] == 'succeeded' for j in receipt['native_jobs'].values())
    erc = read(REV/'generated/erc.json')
    assert all(not sheet['violations'] for sheet in erc['sheets'])
    drc = read(REV/'generated/drc.json')
    assert all(not drc[k] for k in ('violations', 'unconnected_items', 'schematic_parity'))
    assert not receipt['physical_qualification'] and not receipt['manufacturing_released']
    assert receipt['case_input_step_sha256'] == sha256((REV/'generated/routed_shield.step').read_bytes()).hexdigest()
    step = (REV/'generated/routed_shield.step').read_text()
    for ref in ADDED:
        assert re.search(r"NEXT_ASSEMBLY_USAGE_OCCURRENCE\('[^']*','" + ref + r"'", step), ref
    fit = read(REV/'generated/gland-fit.json')
    assert fit['passed'] and len(fit['checks']) == 497 and all(c['pass'] for c in fit['checks'])
    assert len(fit['wires']) == 11 and all(w['minimum_centerline_bend_radius_mm'] >= 5 for w in fit['wires'])
    assert len(fit['tool_axes']) == 8 and all(c['pass'] for c in fit['tool_axes'])
    assert not fit['physical_pull_torque_vibration_seal_electrical_or_vehicle_verified']
    slices = read(REV/'generated/support-free.json')
    assert len(slices['offline_slices']) == 3
    for name, check in slices['mesh_checks'].items():
        assert sha256((REV/'generated'/f'{name}.stl').read_bytes()).hexdigest() == check['sha256']
        assert check['pass']
        assert slices['offline_slices'][name]['pass'] and slices['offline_slices'][name]['support_segments'] == 0
    with zipfile.ZipFile(REV/'generated/4Runner_RGBW_RevI_Gerbers.zip') as archive:
        assert archive.testzip() is None
        for name in archive.namelist():
            assert archive.read(name) == (REV/'generated/fabrication/gerbers'/name).read_bytes()
