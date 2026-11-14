"""Generate the Rev F JLCPCB BOM, CPL and dated assembly estimates."""

import argparse
from collections import Counter
from decimal import Decimal
import json
from pathlib import Path
import re

from prepare_quote import HERE, read_csv, unique, write_csv
from prepare_reve_stock_quote import PART_CODE, estimate


REV_E = HERE.parent.parent / "pcb-rgbw-reve" / "jlcpcb"
REV_F = HERE.parent.parent / "pcb-rgbw-revf" / "jlcpcb"
CATALOG_COLUMNS = list(read_csv(REV_E / "catalog-snapshot.csv")[0])
PROTOTYPE_QUANTITIES = (2, 5, 10)
NEW_CATALOG_IDS = {"base": "Basic", "expand": "Extended"}


def refresh_snapshot(path, codes):
    raw = json.loads(path.read_text(encoding="utf-8"))
    rows = []
    for code in sorted(codes, key=lambda value: int(value[1:])):
        record = raw[code]
        item = record["data"]
        if item["componentCode"] != code:
            raise ValueError(f"Catalog response did not match {code}")
        rows.append(dict(zip(CATALOG_COLUMNS, (
            record["utc"], code, item["componentBrandEn"], item["componentModelEn"],
            NEW_CATALOG_IDS[item["componentLibraryType"]], item["overseasStockCount"],
            item["assemblyProcess"], item["componentSpecificationEn"], item["minPurchaseNum"] or 1,
            item["leastPatchNumber"] or 0, item["lossNumber"] or 0, str(item["xrayFlag"]).lower(),
            " ".join(f'{p["startNumber"]}:{p["productPrice"]}' for p in item["prices"]),
            f"https://jlcpcb.com/partdetail/{item['componentModelEn']}/{code}",
        ), strict=True)))
    return rows


def table(in_dir, catalog):
    bom_by_ref = unique(read_csv(in_dir / "PCB-BOM.csv"), "ref")
    positions = unique(read_csv(in_dir / "prototype-fabrication/SMT-placement.csv"), "Ref")
    parts = {ref: part for ref, part in bom_by_ref.items() if part["jlcpcb_part"]}
    if set(parts) != positions.keys() or set(bom_by_ref) - parts.keys() != {"F1", "F2"}:
        raise ValueError("Rev F native footprints and stock selection do not agree")
    bom, cpl = {}, []
    for ref, p in positions.items():
        part = parts[ref]
        code = part["jlcpcb_part"]
        package = part["footprint"].split(":")[-1]
        if p["Package"] != package or p["Side"] != "top" or p["Val"] != part["value"]:
            raise ValueError(f"Wrong native package, placement side or value at {ref}")
        if part["mpn"] != catalog[code]["mpn"] or catalog[code]["assembly_process"] != "SMT":
            raise ValueError(f"Wrong JLCPCB catalog mapping at {ref}")
        if code in bom:
            if bom[code]["Footprint"] != package:
                raise ValueError(f"{code} mapped to more than one footprint")
            bom[code]["Designator"] += "," + ref
        else:
            bom[code] = {"Comment": part["mpn"], "Designator": ref, "Footprint": package, PART_CODE: code}
        cpl.append({"Designator": ref, "Mid X": p["PosX"] + "mm", "Mid Y": p["PosY"] + "mm",
                    "Rotation": str((Decimal(p["Rot"]) + 360) % 360), "Layer": "T"})
    copper = next((in_dir / "prototype-fabrication/gerbers").glob("*-F_Cu.gtl")).read_text(encoding="ascii")
    joints = Counter(ref for ref, _ in set(re.findall(r"%TO.P,([^,]+),([^,*]+)\*%", copper)))
    if any(not joints[ref] for ref in parts):
        raise ValueError("A placed part is missing front-side copper pads")
    return list(bom.values()), cpl, joints


def main(native, out, raw):
    out.mkdir(parents=True, exist_ok=True)
    baseline = {name: read_csv(REV_E / name / "BOM.csv") for name in
                ("stock-lm5164-smt", "stock-lm5164-clamps-smt")}
    catalog_file = out / "catalog-snapshot.csv"
    if raw is not None:
        codes = {r["jlcpcb_part"] for r in read_csv(native / "PCB-BOM.csv") if r["jlcpcb_part"]}
        codes.update(row[PART_CODE] for bom in baseline.values() for row in bom)
        write_csv(catalog_file, CATALOG_COLUMNS,
                  (row.values() for row in refresh_snapshot(raw, codes)))
    catalog = unique(read_csv(catalog_file), "jlcpcb_part")
    bom, cpl, joints = table(native, catalog)
    rows = estimate("rev-f-full-smt", PROTOTYPE_QUANTITIES, bom, joints, catalog)
    for name, previous in baseline.items():
        quantities = PROTOTYPE_QUANTITIES if name == "stock-lm5164-smt" else (2, 5)
        rows.extend(estimate("rev-e-" + name, quantities, previous, joints, catalog))
    write_csv(out / "BOM.csv", list(bom[0]), (row.values() for row in bom))
    write_csv(out / "CPL.csv", list(cpl[0]), (row.values() for row in cpl))
    (out / "assembly-estimate.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True, help="Verified Orion output")
    parser.add_argument("--out", type=Path, default=REV_F)
    parser.add_argument("--raw-catalog", type=Path, help="Dated map of JLCPCB public component responses")
    args = parser.parse_args()
    main(args.native, args.out, args.raw_catalog)
