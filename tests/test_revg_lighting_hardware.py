"""Check the routed one-board build, assembly data and qualification boundaries."""

from collections import Counter
import csv
from decimal import Decimal
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
import sys
from zipfile import ZipFile


REV = Path(__file__).resolve().parents[1] / "hardware/console-led-node-v0.1/pcb-rgbw-revg"
GENERATED = REV / "generated"
ASSEMBLY = REV / "jlcpcb"


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def read_csv(path):
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def test_native_board_reports_and_prints_match_the_published_package():
    result = read_json(GENERATED / "verification.json")
    for name, digest in result["published_sha256"].items():
        assert sha256((REV / name).read_bytes()).hexdigest() == digest, name
    assert result["populated_board_count"] == 1
    assert not any(result["kicad_findings"].values())
    assert result["case_checks_passed"] == 34
    assert result["wire_checks_passed"] == 92
    assert result["tool_axes_passed"] == 8
    assert result["slices_with_zero_support_segments"] == 5
    assert result["physical_print_fit_and_electrical_qualification"] is False
    print_evidence = read_json(GENERATED / "support-free.json")
    assert all(row["pass"] and not row["support_segments"]
               for row in print_evidence["offline_slices"].values())
    assert len(print_evidence["offline_slices"]) == 5


def test_integrated_power_driver_and_sense_routes_preserve_the_wiring_contract():
    report = read_json(GENERATED / "electrical-screen.json")
    assert all(report["checks"].values())
    pins = report["native_pin_checks"]
    assert pins["J1"] == {"1": "GND", "2": "VEH_ACC", "3": "TAIL_12V", "4": "DIM_RETURN"}
    assert pins["F1"] == {"1": "VEH_ACC", "2": "ACC_FUSED"}
    assert pins["F2"] == {"1": "LED_POS", "2": "VIN_PROT"}
    assert pins["U4"]["8"] == pins["U4"]["17"] == "EFUSE_RTN"
    assert pins["U4"]["9"] == "GND"
    assert pins["U1"]["5"] == "VIN_PROT"
    assert pins["U11"]["2"] == "ESP_3V3"
    assert [pins["U2"][str(n)] for n in (3, 4, 6, 7)] == [
        "LED_R_NEG", "LED_G_NEG", "LED_B_NEG", "LED_W_NEG",
    ]
    assert pins["D9"] == {"1": "LED_POS", "2": "GND"}
    assert report["driver_disable_logic_high_min_v"] > 2.0
    low, high = report["three_volt_static_v"]
    assert report["max_reset_release_v"] < low < high < 3.6
    assert report["pod_screen"]["wire_and_copper_drop_allowance_v"] >= .3
    assert report["pod_screen"]["at_pod_v"] >= 9.0
    wire = read_json(GENERATED / "wiring-interfaces.json")
    assert wire["factory_tee"] == {str(n): {"through_to": n} for n in range(1, 7)}
    assert wire["reserve_tails"] == {"3": "IR1-3 TAIL", "4": "IR1-4 DIM"}
    assert {pin: row["net"] for pin, row in wire["J2"].items()} == pins["J2"]


def test_economic_assembly_matches_native_gerbers_and_loaded_catalog_quantities():
    native = {row["ref"]: row for row in read_csv(GENERATED / "PCB-BOM.csv")}
    catalog = {row["jlcpcb_part"]: row for row in read_csv(ASSEMBLY / "catalog-snapshot.csv")}
    quote = read_json(ASSEMBLY / "assembly-estimate.json")
    cpl = read_csv(ASSEMBLY / "CPL.csv")
    placed = Counter()
    for grouped in read_csv(ASSEMBLY / "BOM.csv"):
        code = grouped["JLCPCB Part #"]
        spec = catalog[code]
        refs = grouped["Designator"].split(",")
        assert spec["assembly_process"] == "SMT"
        for count in (2, 5, 10):
            loaded = max(count * len(refs) + int(spec["extra_parts"]),
                         int(spec["minimum_assembly"]), int(spec["minimum_purchase"]))
            assert loaded == quote["loaded_stock_requirements"][str(count)][code] <= int(spec["stock"])
        for ref in refs:
            assert native[ref]["jlcpcb_part"] == code
            assert native[ref]["mpn"] == spec["mpn"] == grouped["Comment"]
            assert native[ref]["footprint"].split(":")[-1] == grouped["Footprint"]
        placed.update(refs)

    assert len(cpl) == len(placed) == quote["smt_placements_per_board"] == 59
    assert set(placed.values()) == {1}
    assert Counter(row["Designator"] for row in cpl) == placed
    assert {row["Layer"] for row in cpl} == {"T"}
    assert set(native) - placed.keys() == {"F1", "F2"}
    with ZipFile(GENERATED / "4Runner_RGBW_RevG_Gerbers.zip") as gerbers:
        assert gerbers.testzip() is None
        assert len([name for name in gerbers.namelist() if name.endswith((".gtl", ".g1", ".g2", ".gbl"))]) == 4
        assert len([name for name in gerbers.namelist() if name.endswith(".drl")]) == 2
        copper = gerbers.read("vhos_rgbw_revg-F_Cu.gtl").decode("ascii")
    pads = Counter(ref for ref, _ in set(re.findall(r"%TO.P,([^,]+),([^,*]+)\*%", copper)))
    assert all(pads[ref] for ref in placed)
    assert sum(pads[ref] for ref in placed) == quote["priced_joints_per_board"]
    two = quote["estimates"][0]
    assert two["boards_assembled"] == 2
    assert Decimal(two["estimated_assembly_subtotal_usd"]) < Decimal(100)
    assert two["rev_f_assembly_savings_usd"] == "89.67"
    assert quote["assembly_only"] and quote["checkout_verified"] is False


def test_factory_assembly_adds_both_fuse_holders_at_native_top_side_positions(tmp_path):
    mixed = ASSEMBLY / "factory-holders"
    generator = REV.parent / "pcb-rgbw-revb" / "jlcpcb" / "prepare_revg_mixed_quote.py"
    subprocess.run([sys.executable, "-B", str(generator), "--out", str(tmp_path)], check=True)
    for name in ("BOM.csv", "CPL.csv", "holder-catalog.csv", "assembly-estimate.json"):
        assert (tmp_path / name).read_bytes() == (mixed / name).read_bytes(), name

    factory_bom = read_csv(mixed / "BOM.csv")
    assert factory_bom[:-1] == read_csv(ASSEMBLY / "BOM.csv")
    assert factory_bom[-1] == {
        "Comment": "3568-10", "Designator": "F1,F2",
        "Footprint": "Keystone_3568_MINI_Vertical", "JLCPCB Part #": "C3205378",
    }
    factory_cpl = read_csv(mixed / "CPL.csv")
    assert factory_cpl[:-2] == read_csv(ASSEMBLY / "CPL.csv")
    assert factory_cpl[-2:] == [
        {"Designator": "F1", "Mid X": "79mm", "Mid Y": "-106.94mm", "Rotation": "0", "Layer": "T"},
        {"Designator": "F2", "Mid X": "103.5mm", "Mid Y": "-107.34mm", "Rotation": "0", "Layer": "T"},
    ]
    quote = read_json(mixed / "assembly-estimate.json")
    holder, = read_csv(mixed / "holder-catalog.csv")
    needed = 2 * len(factory_cpl[-2:]) + int(holder["extra_parts"])
    assert int(holder["minimum_purchase"]) <= quote["holders_required"] == needed <= int(holder["stock"])
    assert quote["manual_joints_per_board"] == 8
    assert quote["assembly_with_holders_usd"] == "118.53"
    bare = read_json(mixed / "bare-board-calculator.json")["rev_g"]["lead_free_hasl"]
    assert sum(Decimal(bare[k]) for k in ("engineering_usd", "finish_usd", "board_usd")) == Decimal("34.30")
    assert Decimal(bare["calculated_price_usd"]) + Decimal(quote["assembly_with_holders_usd"]) == Decimal("152.83")


def test_wire_mount_disconnects_match_native_rev_g_and_ir1_cavities():
    native = read_json(GENERATED / "wiring-interfaces.json")
    schedule = read_csv(REV / "glands" / "WIRE-DISCONNECTS.csv")
    for port, plug in (("J1", "Toyota 4-way"), ("J2", "RGBW 6-way")):
        rows = [row for row in schedule if row["Plug"] == plug]
        fitted = [row for row in rows if row["PCB pad"]]
        assert {row["Connector cavity"]: row["Net"] for row in fitted} == {
            pin: info["net"] for pin, info in native[port].items()
        }
        assert all(row["PCB pad"] == f"{port}-{row['Connector cavity']}" for row in fitted)
        assert len(rows) == (4 if port == "J1" else 6)
    assert {row["External destination"] for row in schedule if row["Plug"] == "Toyota 4-way"} == {
        f"IR1-{row['cavity']}" for row in native["J1"].values()
    }
    empty, = [row for row in schedule if row["Net"] == "NC"]
    assert (empty["Plug"], empty["Connector cavity"], empty["PCB pad"]) == ("RGBW 6-way", "6", "")


def test_wled_config_follows_pcb_pin_order_and_private_endpoint():
    root = REV.parents[2]
    firmware = root / "firmware/console-led-revg/wled"
    env = (firmware / "platformio_override.ini").read_text()
    policy = (firmware / "revg_policy.h").read_text()
    assert "board_build.arduino.memory_type = qio_qspi" in env
    assert "-DPIXEL_COUNTS=1" in env and "-DLED_TYPES=44" in env
    pins, = re.findall(r"^  -DDATA_PINS=([\d,]+)$", env, re.MULTILINE)
    assert pins == "18,17,14,2"
    assert "{18, 17, 14, 2}" in policy
    assert all(token in policy for token in ("enablePin = 21", "tailPin = 5", "dimPin = 4"))
    patch = (firmware / "build_orion.py").read_text()
    relay = (root / "ios/Core/Sources/VHOSCore/LightingRelay.swift").read_text()
    assert "http://192.168.88.1" in patch and "http://192.168.88.1" in relay


def test_revg_gland_cad_receipts_bind_to_the_three_support_free_stls():
    output = REV / "glands" / "generated"
    fit = read_json(output / "gland-fit.json")
    sliced = read_json(output / "support-free.json")
    assert fit["passed"] and fit["gland_center_spacing_mm"] == 27
    assert len(fit["checks"]) == 60 and all(row["pass"] for row in fit["checks"])
    assert len(fit["tool_axes"]) == 8 and all(axis["pass"] for axis in fit["tool_axes"])
    assert not fit["physical_pull_seal_or_vehicle_fit_verified"]
    assert sliced["supports_disabled_all_parts_passed"]
    assert set(sliced["offline_slices"]) == {"case_base", "case_lid", "gland_plate"}
    for name, row in sliced["offline_slices"].items():
        assert row["pass"] and row["support_segments"] == 0
        assert sha256((output / f"{name}.stl").read_bytes()).hexdigest() == sliced["mesh_checks"][name]["sha256"]


def test_revg_service_gallery_matches_the_released_assembly_and_motion_checks():
    output = REV / "glands" / "generated"
    gallery = output / "gallery"
    report = read_json(gallery / "service-clearance.json")
    assert report["source_assembly_sha256"] == sha256(
        (output / "4Runner_RevG_Gland_Assembly.FCStd").read_bytes()
    ).hexdigest()
    assert report["passed"] and report["physical_validation"] is False
    assert report["horizontal_allowance_mm_per_side"] == .10
    assert report["gland_plate_lift_mm"] == 34
    assert report["disconnect_lift_mm"] == 28 and report["unmate_reserve_mm"] == 12
    checks = {row["check"]: row for row in report["checks"]}
    assert Counter(row["expected"] for row in report["checks"]) == {
        "clear": 54, "blocked": 4, "positive margin": 4,
    }
    assert len(checks) == 62 and all(row["passed"] for row in checks.values())
    assert checks["Lid blocks plate removal after taking up the seated gap"]["overlap_mm3"] > 0
    for port in ("J1", "J2"):
        assert checks[f"{port} above-rim axial unmating reserve"]["passed"]
        assert checks[f"{port} complete vertical removal vs populated PCB and fuses"]["passed"]
        margins = report["manufacturer_dimensions"]["housing_envelope_margins"][port]
        assert margins["length_margin_mm"] > 0 and margins["width_margin_mm"] > 0
    assert len(list(gallery.glob("*.png"))) == 5
