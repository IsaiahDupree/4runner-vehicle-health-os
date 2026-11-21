"""Real native Rev H artifacts, factory data and cable interface consistency."""
from collections import Counter
import csv
from decimal import Decimal
from hashlib import sha256
import json
from pathlib import Path


REV = Path(__file__).resolve().parents[1] / "hardware/console-led-node-v0.1/pcb-rgbw-revh"
GEN = REV / "generated"


def read(name):
    return json.loads((REV / name).read_text())


def rows(name):
    with (REV / name).open(newline="") as stream:
        return list(csv.DictReader(stream))


def test_native_outputs_and_published_runtime_sources_are_bound_to_successful_jobs():
    receipt = read("generated/verification.json")
    for name, item in receipt["published_files"].items():
        assert sha256((REV / name).read_bytes()).hexdigest() == item["sha256"], name
    assert all(j["status"] == "succeeded" for j in receipt["native_jobs"].values())
    assert receipt["kicad_findings"] == dict.fromkeys(("erc", "violations", "unconnected_items", "schematic_parity"), 0)
    assert receipt["populated_board_count"] == 1
    assert receipt["factory_populated_positions"] == 67
    assert not receipt["physical_qualification"] and not receipt["manufacturing_released"]
    metadata = read("generated/factory-metadata-audit.json")
    assert metadata["all_tracks_vias_pads_and_footprint_poses_unchanged"]
    assert metadata["step_reused_exact_sha256"] == receipt["published_files"]["generated/routed_shield.step"]["native_sha256"]


def test_all_six_toyota_wires_have_homes_and_only_acc_is_the_power_inlet():
    parts = read("generated/native-parts.json")
    assert parts["JT1"]["pad_nets"] == {"1": "/GND", "2": "/VEH_ACC"}
    assert parts["JT2"]["pad_nets"] == {"1": "/TAIL_12V", "2": "/DIM_RETURN"}
    assert parts["F1"]["pad_nets"] == {"1": "/VEH_ACC", "2": "/ACC_FUSED"}
    assert "J1" not in parts and "J2" not in parts
    assert {r["Toyota cavity"] for r in rows("WIRE-REGISTER.csv") if r["Toyota cavity"]} == set("123456")
    assert len([r for r in rows("WIRE-REGISTER.csv") if r["Toyota cavity"]]) == 6
    for ref in ("JT3", "JT6"):
        for pin, net in parts[ref]["pad_nets"].items():
            if ref == "JT3" or pin == "2":
                assert net.startswith("unconnected-"), (ref, pin, net)
    isolated = [p for p in read("generated/terminal-electrical-audit.json")["pads"] if p["isolated"]]
    assert len(isolated) == 3
    assert all(p["track_and_via_count"] == 0 and p["pass"] for p in isolated)
    assert parts["JT5"]["pad_nets"]["2"] == "/LED_POS"
    assert parts["U11"]["mpn"] == "ESP32-S3-WROOM-1-N16R2"


def test_factory_bom_covers_every_actual_component_and_current_catalog_identity():
    parts = read("generated/native-parts.json")
    catalog = {r["code"]: r for r in read("jlcpcb/catalog-live.json")["rows"]}
    selected = Counter()
    subtotal = Decimal(0)
    for group in rows("jlcpcb/BOM.csv"):
        refs = group["Designator"].split(",")
        row = catalog[group["JLCPCB Part #"]]
        assert row["status"] == "captured" and row["mpn"] == group["Comment"]
        assert row["observed_stock"] >= len(refs)
        assert row["quantity_per_board"] == len(refs)
        subtotal += Decimal(str(row["unit_usd_at_one_board_quantity"])) * len(refs)
        for ref in refs:
            assert parts[ref]["mpn"] == group["Comment"]
            assert parts[ref]["footprint"].split(":")[-1] == group["Footprint"]
        selected.update(refs)
    assert len(selected) == 67 and set(selected.values()) == {1}
    assert Counter(r["Designator"] for r in rows("jlcpcb/CPL.csv")) == selected
    assert {r for r in selected if r.startswith("JT")} == {f"JT{i}" for i in range(1, 7)}
    assert parts["F1"]["mpn"] == parts["F2"]["mpn"] == "3568-10"
    assert subtotal == Decimal(str(read("jlcpcb/catalog-live.json")["material_subtotal_usd_at_one_board_quantity"]))
    assert not read("jlcpcb/catalog-live.json")["finished_product_quote_verified"]


def test_exact_wires_fasteners_tools_and_print_exports_pass_the_native_audits():
    report = read("generated/gland-fit.json")
    assert report["passed"] and len(report["checks"]) == 497
    assert all(r["pass"] for r in report["checks"])
    assert len(report["wires"]) == 11
    assert Counter(r["cable"] for r in report["wires"]) == {"J1": 6, "J2": 5}
    assert all(r["minimum_centerline_bend_radius_mm"] >= 5 for r in report["wires"])
    assert report["installed_inserts"] == report["installed_screws"] == 8
    assert report["installed_insulating_washers"] == 4
    assert len(report["tool_axes"]) == 8 and all(r["pass"] for r in report["tool_axes"])
    assert not report["physical_pull_torque_vibration_seal_electrical_or_vehicle_verified"]
    slices = read("generated/support-free.json")
    assert len(slices["offline_slices"]) == 3
    assert all(r["pass"] and r["support_segments"] == 0 for r in slices["offline_slices"].values())
    assert all(r["pass"] for r in slices["mesh_checks"].values())
    pictures = read("images/picture-checks.json")
    assert len(pictures["views"]) == 3 and all(v["pass"] for v in pictures["views"])
