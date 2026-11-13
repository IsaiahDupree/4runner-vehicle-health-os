"""Export Rev B JLCPCB quote inputs and compare costs from the dated catalog."""

import argparse
from collections import defaultdict
import csv
from decimal import Decimal
import json
from pathlib import Path
import re
from zipfile import ZipFile


HERE = Path(__file__).resolve().parent
NATIVE = HERE.parent / "generated"
FEEDER_USD = Decimal("3.07")
SETUP_AND_STENCIL_USD = Decimal("9.71")
SMT_JOINT_USD = Decimal("0.0016")
# Native rotation, body centroid offset from the footprint origin, and joint count.
THT = {"J1": (90, 0, -4.25, 2), "J2": (90, 4.5, -2.335, 8),
       "F1": (0, 0, 0, 4), "F2": (0, 0, 0, 4)}
VARIANTS = (
    ("truck-smt", ()),
    ("truck-mixed", ("mixed assembly",)),
    ("bench-smt", ("bench only",)),
    ("truck-lm5169-smt", ("truck LM5169",)),
    ("truck-lm5169-mixed", ("truck LM5169", "mixed assembly")),
    ("truck-lm5169-fuses", ("truck LM5169", "mixed assembly", "factory fuse holders")),
)


def read_csv(path):
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def write_csv(path, columns, rows):
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(columns)
        writer.writerows(rows)


def unique(rows, key):
    indexed = {row[key]: row for row in rows}
    if len(indexed) != len(rows):
        raise ValueError(f"duplicate {key}")
    return indexed


def through_hole_centroids(board_text):
    """Use native footprint origins and the manufacturers' nominal body centers."""
    centers = {}
    for footprint in board_text.split('\n\t(footprint ')[1:]:
        match = re.search(r'\(property "Reference" "([^"]+)"', footprint)
        if not match or match[1] not in THT:
            continue
        ref = match[1]
        rotation, dx, dy, joints = THT[ref]
        position = re.search(r'^\t\t\(at ([\d.]+) ([\d.]+)(?: ([\d.]+))?\)$',
                             footprint, re.MULTILINE)
        if position is None or '(layer "F.Cu")' not in footprint:
            raise ValueError(f"{ref} through-hole footprint origin changed")
        plated_pads = re.findall(r'^\t\t\(pad "[^"]+" thru_hole ', footprint, re.MULTILINE)
        if Decimal(position[3] or "0") != rotation or len(plated_pads) != joints:
            raise ValueError(f"{ref} orientation or physical joint count changed")
        x, y = map(Decimal, position.groups()[:2])
        dx, dy = (Decimal(str(coordinate)) for coordinate in (dx, dy))
        # Rotate the centroid by the native footprint angle, then invert board Y.
        offset_x, offset_y = (dy, -dx) if rotation == 90 else (dx, dy)
        centers[ref] = {"Ref": ref, "PosX": str(x + offset_x), "PosY": str(-y - offset_y),
                        "Rot": str(rotation), "Side": "top"}
    if centers.keys() != THT.keys():
        raise ValueError("missing native through-hole placements")
    return centers


def part_cost(part, count, *, reserve=False):
    amount = max(count + int(part["extra_parts"]), int(part["minimum_assembly"]))
    if reserve:
        amount = max(amount, int(part["minimum_purchase"]))
    if amount > int(part["stock"]):
        raise ValueError(f'{part["jlcpcb_part"]} has inadequate snapshot stock for {amount} pieces')
    tiers = [entry.split(":") for entry in part["price_tiers_usd"].split()]
    return amount * next(Decimal(price) for start, price in reversed(tiers) if int(start) <= amount)


def money(amount):
    return str(amount.quantize(Decimal("0.01")))


def grouped_selection(selection, uses):
    defaults, overrides = {}, {}
    for row in selection:
        use = row["Use"]
        if use != "all" and use not in uses:
            continue
        selected = defaults if use == "all" else overrides
        for ref in row["Designators"].split(","):
            if ref in selected:
                raise ValueError(f"multiple selected parts for {ref}")
            selected[ref] = row["JLCPCB Part #"]
    groups = defaultdict(list)
    for ref, code in {**defaults, **overrides}.items():
        groups[code].append(ref)
    return groups


def main(output):
    bom = unique(read_csv(NATIVE / "PCB-BOM.csv"), "ref")
    smt = unique(read_csv(NATIVE / "SMT-placement.csv"), "Ref")
    catalog = unique(read_csv(HERE / "catalog-snapshot.csv"), "jlcpcb_part")
    selection = read_csv(HERE / "selection.csv")
    placements = {**smt, **through_hole_centroids((NATIVE / "vhos_rgbw_revb.kicad_pcb").read_text())}
    with ZipFile(NATIVE / "Prototype_PCB_Gerbers.zip") as fab:
        top_copper = fab.read("vhos_rgbw_revb-F_Cu.gtl").decode("ascii")
    pins = set(re.findall(r"%TO.P,([^,]+),([^,*]+)\*%", top_copper))
    output.mkdir(parents=True, exist_ok=True)

    estimates = []
    for label, uses in VARIANTS:
        required_tht = set()
        if "mixed assembly" in uses:
            required_tht.update(("J1", "J2"))
        if "factory fuse holders" in uses:
            required_tht.update(("F1", "F2"))
        refs, rows = set(), []
        for code, selected in grouped_selection(selection, uses).items():
            part = catalog[code]
            for ref in selected:
                process = "SMT" if ref in smt else "THT"
                if ref in refs or part["assembly_process"] != process:
                    raise ValueError(f"duplicate designator or assembly process mismatch for {ref}")
                refs.add(ref)
            footprints = {bom[ref]["footprint"].split(":")[-1] for ref in selected}
            if len(footprints) != 1:
                raise ValueError(f"{code} groups unlike footprints")
            rows.append([part["mpn"], ",".join(selected), footprints.pop(), code])
        required = (smt.keys() - {"L1"}) | required_tht
        if refs != required or any(placements[ref]["Side"] != "top" for ref in refs):
            raise ValueError(f"{label} has an incomplete or off-side placement list")

        folder = output / label
        folder.mkdir(exist_ok=True)
        write_csv(folder / "BOM.csv", ["Comment", "Designator", "Footprint", "JLCPCB Part #"], rows)
        write_csv(folder / "CPL.csv", ["Designator", "Mid X", "Mid Y", "Rotation", "Layer"],
                  [[ref, f'{pos["PosX"]}mm', f'{pos["PosY"]}mm', str((Decimal(pos["Rot"]) + 360) % 360), "T"]
                   for ref, pos in placements.items() if ref in refs])
        parts_per_board = {row[3]: len(row[1].split(",")) for row in rows}
        if len(parts_per_board) != len(rows):
            raise ValueError(f"{label} repeats a part number across BOM rows")
        fees = sum(catalog[code]["library"] == "Extended" for code in parts_per_board) * FEEDER_USD
        joints = sum(ref in refs and ref in smt for ref, _ in pins)
        through_hole_joints = sum(THT[ref][3] for ref in required_tht)
        manual = Decimal("3.58") if required_tht else Decimal(0)
        quantities = (2,) if "factory fuse holders" in uses else (2, 5, 10)
        for qty in quantities:
            parts = sum(part_cost(catalog[code], qty * count) for code, count in parts_per_board.items())
            labor = joints * qty * SMT_JOINT_USD + manual + through_hole_joints * qty * Decimal("0.0164")
            low = SETUP_AND_STENCIL_USD + fees + parts + labor
            estimates.append({"variant": label, "boards_assembled": qty, "parts_usd": money(parts),
                              "feeder_usd": money(fees), "setup_and_stencil_usd": money(SETUP_AND_STENCIL_USD),
                              "manual_joints_per_board": through_hole_joints,
                              "placement_and_manual_usd": money(labor), "subtotal_usd": money(low),
                              "if_U4_xray_required_usd": money(low + qty * Decimal("1.64"))})

    swaps = [row for row in selection if row["Original JLCPCB Part # for savings comparison"]]
    stocked_swaps = sum(int(catalog[row["Original JLCPCB Part # for savings comparison"]]["stock"]) > 0
                        for row in swaps)
    if any(catalog[row["JLCPCB Part #"]]["library"] != "Basic" or
           catalog[row["Original JLCPCB Part # for savings comparison"]]["library"] != "Extended" for row in swaps):
        raise ValueError("check fee classification before comparing the original passives")
    costs = {"economic_smt_joints_per_board": joints, "modeled_economic_assembly": estimates,
             "feeder_savings_vs_original_all_parts_available_usd": money(len(swaps) * FEEDER_USD),
             "feeder_savings_from_original_stocked_passives_usd": money(stocked_swaps * FEEDER_USD),
             "fee_free_basic_replacement_for_original_shortage": len(swaps) - stocked_swaps,
             "bench_u1_two_board_optional_preorder_premium_usd": money(
                 part_cost(catalog["C477928"], 2, reserve=True) - part_cost(catalog["C477928"], 2))}
    (output / "assembly-estimate.json").write_text(json.dumps(costs, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=HERE)
    main(parser.parse_args().out)
