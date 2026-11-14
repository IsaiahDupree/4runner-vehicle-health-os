"""Export the Rev E JLCPCB populations and estimate Economic PCBA from the snapshot."""

import argparse
from collections import Counter
from decimal import Decimal
import json
from pathlib import Path
import re
from shutil import copyfile
from zipfile import ZipFile

from prepare_quote import (
    FEEDER_USD,
    HERE,
    SETUP_AND_STENCIL_USD,
    SMT_JOINT_USD,
    money,
    part_cost,
    read_csv,
    unique,
    write_csv,
)


QUOTE = HERE.parent.parent / "pcb-rgbw-reve" / "jlcpcb"
BASELINE = QUOTE / "truck-lm5164-smt"
GENERATED = QUOTE.parent / "generated"
PART_CODE = "JLCPCB Part #"
STOCK_SWAPS = {
    "C23341": "C22961",   # R3, 221 kΩ to 220 kΩ at the buck's enable divider.
    "C110776": "C21190",  # R30/R31, 1 kΩ ADC isolation.
}
POSITIVE_CLAMPS = {"C2872469": ("U6", "U7")}
NEGATIVE_CLAMPS = {"C426769": ("D7", "D8")}
X_RAY_PER_PART_USD = Decimal("1.64")  # Published tier for up to ten inspected placements.


def estimate(variant, quantities, bom, joint_counts, catalog):
    extended = sum(catalog[row[PART_CODE]]["library"] == "Extended" for row in bom)
    feeders = extended * FEEDER_USD
    totals = []
    for count in quantities:
        parts = Decimal(0)
        joints = x_ray_count = 0
        for row in bom:
            refs = row["Designator"].split(",")
            part = catalog[row[PART_CODE]]
            placed = len(refs) * count
            parts += part_cost(part, placed)
            joints += sum(joint_counts[ref] for ref in refs) * count
            if part["x_ray_flag"] == "true":
                x_ray_count += placed
        if x_ray_count > 10:
            raise ValueError("X-ray quantity exceeds the modeled price tier")
        labor = joints * SMT_JOINT_USD
        x_ray = x_ray_count * X_RAY_PER_PART_USD
        totals.append({
            "variant": variant,
            "boards_assembled": count,
            "parts_usd": money(parts),
            "extended_codes_assumed_billable": extended,
            "feeder_usd": money(feeders),
            "setup_and_stencil_usd": money(SETUP_AND_STENCIL_USD),
            "smt_joint_count": joints,
            "smt_placement_usd": money(labor),
            "catalog_flagged_x_ray_placements": x_ray_count,
            "x_ray_usd": money(x_ray),
            "estimated_assembly_subtotal_usd": money(parts + feeders + SETUP_AND_STENCIL_USD + labor + x_ray),
        })
    return totals


def main(out):
    catalog = unique(read_csv(QUOTE / "catalog-snapshot.csv"), "jlcpcb_part")
    baseline = unique(read_csv(BASELINE / "BOM.csv"), PART_CODE)
    existing = unique(read_csv(BASELINE / "CPL.csv"), "Designator")
    if any(position["Layer"] != "T" for position in existing.values()):
        raise ValueError("The baseline includes a placement outside top-side assembly")
    hand_placements = unique(read_csv(QUOTE / "hand-smt-placement.csv"), "Ref")
    footprints = {row["ref"]: row["footprint"].split(":")[-1]
                  for row in read_csv(GENERATED / "PCB-BOM.csv")}
    with ZipFile(GENERATED / "4Runner_RGBW_RevE_Gerbers.zip") as archive:
        copper = archive.read("vhos_rgbw_reve-F_Cu.gtl").decode("ascii")
    pins = set(re.findall(r"%TO.P,([^,]+),([^,*]+)\*%", copper))
    joint_counts = Counter(ref for ref, _ in pins)
    if set(hand_placements) != {"L1", "D7", "D8", "U6", "U7"}:
        raise ValueError("The Rev E hand-assembly positions changed")

    variants = (
        (BASELINE.name, {}, {}, (2, 5, 10)),
        ("stock-lm5164-smt", STOCK_SWAPS, {}, (2, 5, 10)),
        ("stock-lm5164-clamps-smt", STOCK_SWAPS, POSITIVE_CLAMPS, (2, 5)),
        ("bench-lm5164-smt", {**STOCK_SWAPS, "C2072225": "C477928"},
         {**POSITIVE_CLAMPS, **NEGATIVE_CLAMPS}, (2, 5)),
    )
    out.mkdir(parents=True, exist_ok=True)
    estimates = []
    for name, swaps, additions, quantities in variants:
        if not swaps.keys() <= baseline.keys():
            raise ValueError(f"{name} references a part outside the stock baseline")
        bom = []
        for original_code, row in baseline.items():
            code = swaps.get(original_code, original_code)
            if code == original_code and row["Comment"] != catalog[code]["mpn"]:
                raise ValueError(f"Catalog MPN mismatch for {code}")
            bom.append({**row, "Comment": catalog[code]["mpn"], PART_CODE: code})
        for code, refs in additions.items():
            bom.append({"Comment": catalog[code]["mpn"], "Designator": ",".join(refs),
                        "Footprint": footprints[refs[0]], PART_CODE: code})
        refs = [ref for row in bom for ref in row["Designator"].split(",")]
        added = {ref for group in additions.values() for ref in group}
        if not added <= hand_placements.keys():
            raise ValueError(f"Missing native coordinates for a new placement in {name}")
        if len(set(refs)) != len(refs) or set(refs) != existing.keys() | added:
            raise ValueError(f"BOM and placement designators differ for {name}")
        unique(bom, PART_CODE)
        for row in bom:
            code = row[PART_CODE]
            if catalog[code]["assembly_process"] != "SMT":
                raise ValueError(f"{code} is outside the SMT assembly process")
            for ref in row["Designator"].split(","):
                if not joint_counts[ref] or footprints[ref] != row["Footprint"]:
                    raise ValueError(f"Physical footprint mismatch for {ref}")
        estimates.extend(estimate(name, quantities, bom, joint_counts, catalog))
        if name == BASELINE.name:
            continue
        folder = out / name
        folder.mkdir(exist_ok=True)
        write_csv(folder / "BOM.csv", list(bom[0]), (row.values() for row in bom))
        if not added:
            copyfile(BASELINE / "CPL.csv", folder / "CPL.csv")
            continue
        positions = list(existing.values())
        for ref, pos in hand_placements.items():
            if ref not in added:
                continue
            if pos["Side"] != "top" or pos["Package"] != footprints[ref]:
                raise ValueError(f"Placement layer or package mismatch for {ref}")
            rotation = (Decimal(pos["Rot"]) + 360) % 360
            positions.append({
                "Designator": ref, "Mid X": f'{pos["PosX"]}mm', "Mid Y": f'{pos["PosY"]}mm',
                "Rotation": str(rotation), "Layer": "T",
            })
        write_csv(folder / "CPL.csv", list(positions[0]), (pos.values() for pos in positions))

    (out / "assembly-estimate.json").write_text(json.dumps(estimates, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=QUOTE)
    main(parser.parse_args().out)
