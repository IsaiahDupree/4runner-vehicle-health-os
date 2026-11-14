"""Verify the published Rev F hardware and quote files describe the same assembly."""

from collections import Counter
import csv
from hashlib import sha256
import json
from pathlib import Path
import re
from zipfile import ZipFile


PROJECT = Path(__file__).resolve().parents[1] / "hardware" / "console-led-node-v0.1"
REV = PROJECT / "pcb-rgbw-revf"
GENERATED = REV / "generated"


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def read_csv(path):
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def test_published_files_have_verified_digests_and_a_clean_native_board():
    receipt = read_json(GENERATED / "verification.json")
    for name, digest in receipt["published_sha256"].items():
        assert sha256((REV / name).read_bytes()).hexdigest() == digest, name
    assert receipt["kicad_findings"] == {
        "erc": 0, "violations": 0, "unconnected_items": 0, "schematic_parity": 0,
    }
    assert receipt["populated_board_count"] == 1
    assert receipt["tool_axes_passed"] == 8
    assert receipt["slices_with_zero_support_segments"] == 5

    wires = read_json(GENERATED / "wiring-interfaces.json")
    assert wires["factory_tee"] == {str(n): {"through_to": n} for n in range(1, 7)}
    assert wires["reserve_tails"] == {"3": "IR1-3 TAIL", "4": "IR1-4 DIM"}
    assert {pin: row["net"] for pin, row in wires["J1"].items()} == {
        "1": "GND", "2": "VEH_ACC", "3": "TAIL_12V", "4": "DIM_RETURN",
    }
    assert {pin: row["net"] for pin, row in wires["J2"].items()} == {
        "1": "LED_R_NEG", "2": "LED_G_NEG", "3": "LED_B_NEG", "4": "LED_POS", "5": "LED_W_NEG",
    }


def test_jlc_parts_and_placements_match_native_copper_and_stock():
    native = {row["ref"]: row for row in read_csv(GENERATED / "PCB-BOM.csv")}
    catalog = {row["jlcpcb_part"]: row for row in read_csv(REV / "jlcpcb/catalog-snapshot.csv")}
    cpl = read_csv(REV / "jlcpcb/CPL.csv")
    selected = Counter()
    for group in read_csv(REV / "jlcpcb/BOM.csv"):
        code = group["JLCPCB Part #"]
        refs = group["Designator"].split(",")
        part = catalog[code]
        assert part["assembly_process"] == "SMT"
        assert int(part["stock"]) >= max(5 * len(refs) + int(part["extra_parts"]), int(part["minimum_assembly"]))
        for ref in refs:
            assert native[ref]["jlcpcb_part"] == code
            assert native[ref]["mpn"] == part["mpn"] == group["Comment"]
            assert native[ref]["footprint"].split(":")[-1] == group["Footprint"]
        selected.update(refs)

    assert len(cpl) == len(selected) == 90
    assert set(selected.values()) == {1}
    assert Counter(row["Designator"] for row in cpl) == selected
    assert {row["Layer"] for row in cpl} == {"T"}
    assert set(native) - selected.keys() == {"F1", "F2"}

    with ZipFile(GENERATED / "4Runner_RGBW_RevF_Gerbers.zip") as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert len([name for name in names if name.endswith((".gtl", ".g1", ".g2", ".gbl"))]) == 4
        assert len([name for name in names if name.endswith(".drl")]) == 2
        copper = archive.read("vhos_rgbw_revf-F_Cu.gtl").decode("ascii")
    pads = Counter(ref for ref, _ in set(re.findall(r"%TO.P,([^,]+),([^,*]+)\*%", copper)))
    assert all(pads[ref] for ref in selected)
    assert sum(pads[ref] for ref in selected) == 288


def test_rev_f_rail_and_clamp_screen_stays_in_its_design_window():
    report = read_json(GENERATED / "electrical-screen.json")
    assert all(report["checks"].values())
    low, high = report["five_volt_static_v"]
    assert 4.5 <= low < high <= 5.5
    low, high = report["three_volt_static_v"]
    assert report["max_reset_release_v"] < low < high <= 3.6
    assert report["estimated_buck_amps_peak_at_500ma_load"] < 1.25
    for channel in report["adc_channels"].values():
        low, high = channel["adc_v_at_14_4_v"]
        assert .95 <= low < high <= 1.03
        assert channel["adc_min_v_if_switch_is_minus_0_5_v"] > -.3
        assert channel["positive_clamp_min_current_at_100v_ma"] > .068
