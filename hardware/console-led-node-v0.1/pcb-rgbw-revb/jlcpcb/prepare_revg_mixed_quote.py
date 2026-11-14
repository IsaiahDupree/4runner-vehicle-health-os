"""Create the Rev G quote variant with factory-soldered fuse holders."""

import argparse
from decimal import Decimal, ROUND_HALF_UP
import json
from pathlib import Path

from prepare_quote import FEEDER_USD, THT, part_cost, read_csv, through_hole_centroids, write_csv
from prepare_revf_quote import CATALOG_COLUMNS, refresh_snapshot
from prepare_revg_quote import REV_G


HOLDER_CODE = "C3205378"
HOLDER_REFS = ("F1", "F2")
MANUAL_SETUP_USD = Decimal("3.58")
MANUAL_JOINT_USD = Decimal(".0164")


def build(assembly, out, catalog):
    refs = {ref: THT[ref] for ref in HOLDER_REFS}
    native = assembly.parent / "generated" / "vhos_rgbw_revg.kicad_pcb"
    positions = through_hole_centroids(native.read_text(encoding="utf-8"), refs)
    if (catalog["jlcpcb_part"], catalog["mpn"], catalog["assembly_process"], catalog["library"]) != (
            HOLDER_CODE, "3568-10", "THT", "Extended"):
        raise ValueError("Unexpected JLCPCB fuse-holder catalog entry")

    bom = read_csv(assembly / "BOM.csv")
    cpl = read_csv(assembly / "CPL.csv")
    if {row["Designator"] for row in cpl} & refs.keys():
        raise ValueError("SMT placement file already includes a fuse holder")
    bom.append({"Comment": "3568-10", "Designator": ",".join(HOLDER_REFS),
                "Footprint": "Keystone_3568_MINI_Vertical", "JLCPCB Part #": HOLDER_CODE})
    for ref in HOLDER_REFS:
        pos = positions[ref]
        cpl.append({"Designator": ref, "Mid X": pos["PosX"] + "mm", "Mid Y": pos["PosY"] + "mm",
                    "Rotation": pos["Rot"], "Layer": "T"})

    def usd(value):
        return str(value.quantize(Decimal(".01"), rounding=ROUND_HALF_UP))

    estimate = json.loads((assembly / "assembly-estimate.json").read_text(encoding="utf-8"))
    two_boards, = (r for r in estimate["estimates"] if r["boards_assembled"] == 2)
    joints_per_board = sum(spec[3] for spec in refs.values())
    placement_count = len(HOLDER_REFS) * 2
    holders = part_cost(catalog, placement_count, reserve=True)
    labor = MANUAL_SETUP_USD + MANUAL_JOINT_USD * joints_per_board * 2
    increment = holders + FEEDER_USD + labor
    report = {
        "population": "Top-side Economic SMT plus factory THT fuse holders",
        "catalog_timestamp": catalog["observed_utc"],
        "boards_assembled": 2,
        "smt_placements_per_board": len(cpl) - len(refs),
        "manual_joints_per_board": joints_per_board,
        "holder_stock": int(catalog["stock"]),
        "holders_required": placement_count,
        "holder_parts_usd": usd(holders),
        "holder_feeder_allowance_usd": usd(FEEDER_USD),
        "hand_solder_setup_and_joints_usd": usd(labor),
        "factory_holder_increment_usd": usd(increment),
        "smt_assembly_subtotal_usd": two_boards["estimated_assembly_subtotal_usd"],
        "assembly_with_holders_usd": usd(Decimal(two_boards["estimated_assembly_subtotal_usd"]) + increment),
        "checkout_verified": False,
    }
    out.mkdir(parents=True, exist_ok=True)
    write_csv(out / "BOM.csv", list(bom[0]), (row.values() for row in bom))
    write_csv(out / "CPL.csv", list(cpl[0]), (row.values() for row in cpl))
    write_csv(out / "holder-catalog.csv", CATALOG_COLUMNS, [[catalog[key] for key in CATALOG_COLUMNS]])
    (out / "assembly-estimate.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assembly", type=Path, default=REV_G)
    parser.add_argument("--out", type=Path, default=REV_G / "factory-holders")
    parser.add_argument("--raw-snapshot", type=Path)
    args = parser.parse_args()
    if args.raw_snapshot is None:
        catalog, = read_csv(args.assembly / "factory-holders" / "holder-catalog.csv")
    else:
        catalog, = refresh_snapshot(args.raw_snapshot, {HOLDER_CODE})
    print(json.dumps(build(args.assembly, args.out, catalog), indent=2))
