"""Pair the Rev E LM5164 population with the native top-side placements."""

import argparse
from decimal import Decimal
from pathlib import Path

from prepare_quote import HERE, read_csv, unique, write_csv
from prepare_revd_quote import HAND_SMT, NEW_PARTS as SENSE_PARTS


NEW_PARTS = (
    ("ESP32-S3-WROOM-1-N16R8", "U11", "ESP32-S3-WROOM-1", "C2913202"),
    ("TLV62569DBVR", "U9", "SOT-23-5", "C141836"),
    ("TLV803EC30DBZR", "U10", "SOT-23", "C2877924"),
    ("SRN4018-2R2M", "L2", "L_Bourns-SRN4018", "C913207"),
    ("EMK316BB7226ML-T", "C22,C23,C24", "C_1206_3216Metric", "C385906"),
    ("RC0603FR-07453KL", "R34", "R_0603_1608Metric", "C273765"),
)
ADDITIONAL_EXISTING_PARTS = {"C14663": "C18,C19,C20,C21,C25", "C29936": "C26",
                             "C25803": "R35", "C25804": "R36,R37,R38"}


def main(native, out):
    bom = read_csv(HERE / "truck-smt" / "BOM.csv")
    native_pos = unique(read_csv(native), "Ref")
    for row in bom:
        additional = ADDITIONAL_EXISTING_PARTS.get(row["JLCPCB Part #"])
        if additional:
            row["Designator"] += "," + additional
    fields = list(bom[0])
    bom.extend(dict(zip(fields, row, strict=True)) for row in (*SENSE_PARTS, *NEW_PARTS))
    unique(bom, "JLCPCB Part #")
    refs = [ref for row in bom for ref in row["Designator"].split(",")]
    if len(refs) != len(set(refs)) or set(refs) != native_pos.keys() - HAND_SMT:
        raise ValueError("Rev E quote and native SMT population differ")
    for row in bom:
        for ref in row["Designator"].split(","):
            p = native_pos[ref]
            if p["Package"] != row["Footprint"] or p["Side"] != "top":
                raise ValueError(f"Rev E quote placement or footprint changed for {ref}")
    placements = [(ref, p["PosX"] + "mm", p["PosY"] + "mm", str((Decimal(p["Rot"]) + 360) % 360), "T")
                  for ref, p in native_pos.items() if ref in refs]
    out.mkdir(parents=True, exist_ok=True)
    write_csv(out / "BOM.csv", fields, (row.values() for row in bom))
    write_csv(out / "CPL.csv", ["Designator", "Mid X", "Mid Y", "Rotation", "Layer"], placements)
    print(f"Validated {len(placements)} Rev E top-side quote positions")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    main(args.native, args.out)
