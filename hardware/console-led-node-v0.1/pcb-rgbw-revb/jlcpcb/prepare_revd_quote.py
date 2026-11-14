"""Pair the Rev D placements with the existing LM5169 assembly selection."""

import argparse
from decimal import Decimal
from pathlib import Path

from prepare_quote import HERE, read_csv, unique, write_csv


NEW_PARTS = (
    ("SN3257QPWRQ1", "U5", "TSSOP-16_4.4x5mm_P0.65mm", "C1858301"),
    ("TLV809ED29DBZR", "U8", "SOT-23", "C2864833"),
    ("RT1206BRD0749K9L", "R24,R25,R26,R27", "R_1206_3216Metric", "C706414"),
    ("AT0603BRD0722KL", "R28,R29,R32,R33", "R_0603_1608Metric", "C5455453"),
    ("RT0603BRD071KL", "R30,R31", "R_0603_1608Metric", "C110776"),
)
HAND_SMT = {"L1", "D7", "D8", "U6", "U7"}


def main(native, out):
    previous = HERE / "truck-lm5169-smt"
    bom = read_csv(previous / "BOM.csv")
    old_pos = unique(read_csv(previous / "CPL.csv"), "Designator")
    native_pos = unique(read_csv(native), "Ref")

    def place(ref, row):
        if row["Side"] != "top":
            raise ValueError(f"{ref} is outside the top-side assembly")
        return {"Designator": ref, "Mid X": row["PosX"] + "mm", "Mid Y": row["PosY"] + "mm",
                "Rotation": str((Decimal(row["Rot"]) + 360) % 360), "Layer": "T"}

    for ref, old in old_pos.items():
        current = place(ref, native_pos[ref])
        if current != old:
            raise ValueError(f"Existing LM5169 assembly placement changed for {ref}")
    caps = next(row for row in bom if row["JLCPCB Part #"] == "C14663")
    caps["Designator"] += ",C18,C19,C20,C21"
    bom_fields = list(bom[0])
    bom.extend(dict(zip(bom_fields, row, strict=True)) for row in NEW_PARTS)
    unique(bom, "JLCPCB Part #")
    refs = [ref for row in bom for ref in row["Designator"].split(",")]
    if len(refs) != len(set(refs)) or set(refs) != native_pos.keys() - HAND_SMT:
        raise ValueError("Rev D BOM and native SMT population differ")
    if any(native_pos[ref]["Package"] != row["Footprint"] for row in bom for ref in row["Designator"].split(",")):
        raise ValueError("Rev D BOM and CPL footprints differ")
    placements = [place(ref, row) for ref, row in native_pos.items() if ref in refs]
    out.mkdir(parents=True, exist_ok=True)
    write_csv(out / "BOM.csv", bom_fields, (row.values() for row in bom))
    write_csv(out / "CPL.csv", list(placements[0]), (row.values() for row in placements))
    print(f"Validated {len(placements)} Rev D top-side positions, with {len(HAND_SMT)} placements left for hand assembly.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    main(args.native, args.out)
