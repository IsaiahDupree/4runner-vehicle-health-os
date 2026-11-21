"""Execute the actual controller policies, browser client and deterministic UI packer."""
import gzip
import importlib.util
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / 'firmware/console-led-revg'


def test_real_embedded_cpp_policies_under_undefined_behavior_sanitizer(tmp_path):
    for name in ('policy', 'relay', 'inputs'):
        binary = tmp_path/name
        subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                        '-fsanitize=undefined', '-fno-sanitize-recover=all',
                        str(FW/'tests'/f'{name}_test.cpp'), '-o', str(binary)], check=True, timeout=30)
        subprocess.run([str(binary)], check=True, timeout=10)


def test_real_browser_command_validation_and_local_http_failure_path():
    subprocess.run(['node', '--test', str(FW/'ui/control.test.mjs')], check=True, timeout=30)


def test_firmware_embeds_the_exact_editable_ui_with_no_external_assets(tmp_path):
    path = FW/'wled/embed_ui.py'
    spec = importlib.util.spec_from_file_location('lighting_embed', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    output = tmp_path/'revg_ui.h'
    result = module.embed(FW/'ui', output)
    assert output.read_bytes() == (FW/'wled/revg_ui.h').read_bytes()
    data = bytes(int(s,16) for s in re.findall(r'0x([0-9a-f]{2})', output.read_text()))
    html = gzip.decompress(data).decode()
    assert len(data) == result['gzip_bytes'] < 16000
    assert 'src="./app.mjs"' not in html and 'href="./style.css"' not in html
    assert not re.findall(r'(?:src|href)=["\']https?://', html)


def test_voltage_frontend_uses_actual_existing_skus_and_bounded_tolerance_screen():
    import json
    result = subprocess.run(['python3', '-B', str(ROOT/'hardware/console-led-node-v0.1/pcb-rgbw-revi/voltage_screen.py')],
                            check=True, capture_output=True, text=True, timeout=20)
    screen = json.loads(result.stdout)
    assert screen['source_node'] == 'ACC_FUSED' and screen['gpio'] == 1
    assert screen['added_unique_manufacturer_skus'] == 0 and screen['added_populated_positions'] == 8
    low, high = screen['adc_v_at_14_4_input']
    assert .95 < low < high < 1.03
    assert screen['adc_negative_bound_v_assuming_switch_minus_0_5_v'] > -.3
    assert screen['adc_positive_bound_v_assuming_clamp_2_55_v'] < 1.5
    assert not screen['physical_or_transient_qualification'] and not screen['manufacturing_released']


def test_latest_orion_firmware_images_and_every_usermod_source_match_the_receipt():
    import json
    from hashlib import sha256
    build=FW/'builds/revi-strip-ui-02'
    report=json.loads((build/'firmware-build.json').read_text())
    assert report['environment']=='vhos_revi_n16r2' and report['flash_offset']=='0x0'
    assert not report['hardware_flashing_or_vehicle_validation']
    for name,item in report['images'].items():
        data=(build/name).read_bytes()
        assert len(data)==item['bytes'] and sha256(data).hexdigest()==item['sha256']
    for name,digest in report['usermod_sha256'].items():
        assert sha256((FW/'wled'/name).read_bytes()).hexdigest()==digest, name
