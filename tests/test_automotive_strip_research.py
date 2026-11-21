"""Real manufacturer observations and actual native PCB compatibility checks."""
import csv
from decimal import Decimal
import importlib.util
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOT = REPO / 'hardware/console-led-node-v0.1/pcb-rgbw-revh/strips'
spec = importlib.util.spec_from_file_location('strip_research_screen', ROOT / 'screen.py')
screen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screen)


def profiles():
    return {r['id']: r for r in screen.report()['profiles']}


def test_strip_research_report_reproduces_from_real_sources_and_native_limits():
    assert screen.report() == json.loads((ROOT / 'screen-results.json').read_text())
    sources = {s['id']: s for s in json.loads((ROOT / 'sources.json').read_text())}
    candidates = json.loads((ROOT / 'candidates.json').read_text())
    assert not candidates['physical_qualification'] and candidates['selected_for_purchase'] is None
    for c in candidates['candidates']:
        assert all(s in sources and sources[s]['url'].startswith('https://') for s in c['source_ids'])
    limits = screen.native_limits()
    assert limits['max_channel_a'] == .5 and limits['max_total_a'] == 1
    assert 15.85 < limits['dc_upper_proxy_v'] < 15.86


def test_real_teknoware_current_envelopes_exclude_meter_but_do_not_qualify_shorter_strip():
    rows = profiles()
    one = rows['teknoware_rgbw_1m']
    assert Decimal(one['peak_total_a']) == Decimal('1.810')
    assert {'peak_total_current', 'peak_channel_current:W'} <= set(one['electrical_failures'])
    short = rows['teknoware_rgbw_400mm']
    assert Decimal(short['peak_total_a']) == Decimal('.724')
    assert not short['electrical_failures']
    assert short['static_electrical_state'] == 'incomplete'
    assert {'water', 'vibration', 'short_circuit', 'load_dump', 'brownout_restart', 'pwm', 'sealed_termination'} <= set(short['undocumented_evidence_categories'])


def test_real_tecniq_voltage_and_peak_currents_fail_independently_of_pwm_brightness():
    r = profiles()['tecniq_e46']
    assert {'high_voltage_headroom', 'peak_total_current', 'peak_channel_current:G', 'peak_channel_current:B'} <= set(r['electrical_failures'])
    assert Decimal(r['peak_total_a']) == Decimal('2.05')
    assert r['static_electrical_state'] == 'fails'


def test_rugged_white_or_24_volt_candidates_are_not_silently_substituted_for_rgbw():
    r = profiles()
    assert 'not_requested_rgb_or_rgbw' in r['labcraft_orizon_white']['electrical_failures']
    assert 'nominal_white_channel_already_excessive' in r['labcraft_orizon_white']['electrical_failures']
    assert 'high_voltage_headroom' in r['grote_xtl_white']['electrical_failures']
    assert 'low_voltage_headroom' in r['ofolux_gs_rgb']['electrical_failures']
    assert r['aspoeck_rgbw_oem']['static_electrical_state'] == 'incomplete'
    assert 'worst_case_channel_currents' in r['aspoeck_rgbw_oem']['electrical_unknowns']


def test_strip_wiring_plan_matches_native_outputs_and_retains_four_channel_bus():
    parts = json.loads((ROOT.parent / 'generated/native-parts.json').read_text())
    expected = {'JT4': {'1': '/LED_R_NEG', '2': '/LED_G_NEG'},
                'JT5': {'1': '/LED_B_NEG', '2': '/LED_POS'}}
    assert all(parts[ref]['pad_nets'] == nets for ref, nets in expected.items())
    assert parts['JT6']['pad_nets']['1'] == '/LED_W_NEG'
    assert parts['JT6']['pad_nets']['2'].startswith('unconnected-')
    source = (REPO / 'firmware/console-led-revg/wled/revg_usermod.cpp').read_text()
    assert 'bus->getType() == TYPE_ANALOG_4CH' in source
    with (ROOT / 'STRIP-BOM.csv').open(newline='') as f:
        removed = {r['Item'] for r in csv.DictReader(f) if r['Action'] == 'Remove from strip build'}
    assert removed == {'DD7440 optional pod', 'DD4084 M8 donor'}
