"""Build the Rev G assembly files using the native top-side placements."""

import argparse
from collections import Counter
from decimal import Decimal, ROUND_HALF_UP
import json
from pathlib import Path

from prepare_quote import HERE, read_csv, unique, write_csv
from prepare_revf_quote import CATALOG_COLUMNS, REV_F, refresh_snapshot, table
from prepare_reve_stock_quote import PART_CODE, estimate

REV_G = HERE.parent.parent / "pcb-rgbw-revg" / "jlcpcb"


def main(native, out, raw=None):
    out.mkdir(parents=True, exist_ok=True)
    snapshot = out / "catalog-snapshot.csv"
    if raw is not None:
        codes = {row["jlcpcb_part"] for row in read_csv(native / "PCB-BOM.csv") if row["jlcpcb_part"]}
        rows = refresh_snapshot(raw, codes)
        write_csv(snapshot, CATALOG_COLUMNS, ([row[key] for key in CATALOG_COLUMNS] for row in rows))
    catalog = unique(read_csv(snapshot), "jlcpcb_part")
    bom, cpl, joints = table(native, catalog)
    quantities = (2, 5, 10)
    requirements = {}
    for count in quantities:
        requirements[count] = {}
        for row in bom:
            code = row[PART_CODE]
            part = catalog[code]
            placed = len(row["Designator"].split(",")) * count
            loaded = max(int(part["minimum_purchase"]), int(part["minimum_assembly"]), placed + int(part["extra_parts"]))
            if loaded > int(part["stock"]):
                raise ValueError(f"{code} needs {loaded} parts for {count} boards but has {part['stock']}")
            requirements[count][code] = loaded
    write_csv(out / "BOM.csv", list(bom[0]), (row.values() for row in bom))
    write_csv(out / "CPL.csv", list(cpl[0]), (row.values() for row in cpl))
    estimates = estimate("Rev G integrated SMT", quantities, bom, joints, catalog)
    prior = json.loads((REV_F / "assembly-estimate.json").read_text(encoding="utf-8"))
    rev_f = {row["boards_assembled"]: row for row in prior if row["variant"] == "rev-f-full-smt"}
    for row in estimates:
        count = row["boards_assembled"]
        subtotal = Decimal(row["estimated_assembly_subtotal_usd"])
        row["assembly_usd_per_board"] = str((subtotal / count).quantize(Decimal(".01"), rounding=ROUND_HALF_UP))
        row["headroom_to_100_order_target_usd"] = str(round(Decimal(100) - subtotal, 2))
        if count in rev_f:
            row["rev_f_assembly_savings_usd"] = str(
                Decimal(rev_f[count]["estimated_assembly_subtotal_usd"]) - subtotal)
    report = {
        "assembly_service": "JLCPCB Economic single-side SMT",
        "smt_placements_per_board": len(cpl),
        "catalog_codes": dict(Counter(item["library"] for item in catalog.values())),
        "assembly_only": True,
        "priced_joints_per_board": sum(joints[row["Designator"]] for row in cpl),
        "fee_schedule": "https://jlcpcb.com/help/article/pcb-assembly-price",
        "excluded": ["bare PCB fabrication", "vendor-added inspection", "hand-fitted fuse holders and wiring",
                     "case and mounting hardware", "LED pod", "shipping", "tariff and tax"],
        "estimates": estimates,
        "loaded_stock_requirements": requirements,
        "checkout_verified": False,
    }
    (out / "assembly-estimate.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("--native", required=True, type=Path)
    args.add_argument("--out", type=Path, default=REV_G)
    args.add_argument("--raw-snapshot", type=Path)
    options = args.parse_args()
    print(json.dumps(main(options.native, options.out, options.raw_snapshot), indent=2))
