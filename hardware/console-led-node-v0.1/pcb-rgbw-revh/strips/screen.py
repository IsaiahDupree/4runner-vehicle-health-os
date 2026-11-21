"""Screen actual strip observations against the published native Rev H limits.

This is a static sourcing calculation, not a transient simulation or hardware test.
It never grants purchase/vehicle qualification; absent evidence remains absent.
"""
import hashlib
import json
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REV = ROOT.parent


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_limits():
    verification = read(REV / 'generated/verification.json')
    file = REV / 'generated/electrical-screen.json'
    if sha(file) != verification['published_files']['generated/electrical-screen.json']['sha256']:
        raise ValueError('Native electrical-screen identity differs')
    screen = read(file)
    return {'max_total_a': screen['pod_screen']['combined_a'],
            'max_channel_a': screen['pod_screen']['channel_a'],
            'dc_upper_proxy_v': max(screen['efuse_ovp_rising_v']),
            'screened_loaded_floor_v': screen['pod_screen']['at_pod_v'],
            'native_source_sha256': sha(file),
            'voltage_method': 'Loaded-floor estimate and maximum static OVP corner only; no transient-overshoot bound or regulated 12 V output.'}


def assess(profile, limits):
    failures, unknowns = [], []
    colors = profile['colors']
    if colors is None:
        unknowns.append('color_configuration')
    elif not {'R', 'G', 'B'} <= set(colors):
        failures.append('not_requested_rgb_or_rgbw')
    if profile['control'] is None:
        unknowns.append('common_positive_analog_pinout')
    elif profile['control'] != 'analog_common_positive':
        failures.append('output_interface')
    lo, hi = profile['voltage_min_v'], profile['voltage_max_v']
    if lo is None or hi is None:
        unknowns.append('operating_voltage_interval')
    else:
        if Decimal(lo) > Decimal(str(limits['screened_loaded_floor_v'])):
            failures.append('low_voltage_headroom')
        if Decimal(hi) < Decimal(str(limits['dc_upper_proxy_v'])):
            failures.append('high_voltage_headroom')
    currents = profile['max_channel_current_a']
    total = None
    if currents is None:
        unknowns.append('worst_case_channel_currents')
    else:
        values = {channel: Decimal(value) for channel, value in currents.items()}
        if any(c not in 'RGBW' or len(c) != 1 or not v.is_finite() or v < 0 for c, v in values.items()):
            raise ValueError('Finite nonnegative R/G/B/W current observations required')
        total = sum(values.values())
        if total > Decimal(str(limits['max_total_a'])):
            failures.append('peak_total_current')
        failures.extend('peak_channel_current:' + c for c, v in values.items()
                        if v > Decimal(str(limits['max_channel_a'])))
    if profile.get('current_is_estimate'):
        unknowns.append('supplier_confirmation_of_current_values')
    # A nominal load already above a ceiling fails even when peak data is absent.
    nominal_a = None
    if profile['nominal_power_w'] is not None:
        nominal_a = Decimal(profile['nominal_power_w']) / Decimal(profile['nominal_voltage_v'])
        if nominal_a > Decimal(str(limits['max_total_a'])):
            failures.append('nominal_total_current_already_excessive')
        if colors == ['W'] and nominal_a > Decimal(str(limits['max_channel_a'])):
            failures.append('nominal_white_channel_already_excessive')
    missing = [key for key, value in profile['evidence'].items() if value is None]
    return {'id': profile['id'], 'name': profile['name'],
            'static_electrical_state': 'fails' if failures else 'incomplete' if unknowns else 'within_available_static_bounds',
            'electrical_failures': failures, 'electrical_unknowns': unknowns,
            'peak_total_a': str(total) if total is not None else None,
            'nominal_input_a': str(nominal_a) if nominal_a is not None else None,
            'undocumented_evidence_categories': missing,
            'manufacturer_claims': {k: v for k, v in profile['evidence'].items() if v is not None},
            'qualification': 'Research candidate; no approved physical assembly or complete protection qualification',
            'notes': profile['notes']}


def report():
    candidates = read(ROOT / 'candidates.json')
    limits = native_limits()
    return {'method': 'Static calculations using real published product observations and hash-bound native board limits',
            'owner_choice': candidates['owner_choice'],
            'candidate_source_sha256': sha(ROOT / 'candidates.json'),
            'research_source_index_sha256': sha(ROOT / 'sources.json'),
            'screen_source_sha256': sha(Path(__file__)),
            'board_limits': limits,
            'profiles': [assess(p, limits) for p in candidates['candidates']],
            'selected_for_purchase': candidates['selected_for_purchase'],
            'physical_qualification': candidates['physical_qualification']}


if __name__ == '__main__':
    result = report()
    (ROOT / 'screen-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'profiles': len(result['profiles']), 'physical_qualification': result['physical_qualification'],
                      'states': {p['id']: p['static_electrical_state'] for p in result['profiles']}}, indent=2))
