"""Publish only verified native outputs and reconcile factory placement metadata."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parent
TEXT = {".json", ".csv", ".kicad_pcb", ".kicad_sch", ".kicad_pro", ".kicad_mod", ".kicad_sym", ".gtl",
        ".gbl", ".g1", ".g2", ".gts", ".gbs", ".gto", ".gbo", ".gtp", ".gm1", ".drl", ".gbrjob"}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def board_parts(path):
    """Read actual saved KiCad footprint properties, positions and pad nets."""
    stack, root = [], None
    for token in re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+', path.read_text()):
        if token == "(":
            node = []
            if stack:
                stack[-1].append(node)
            else:
                root = node
            stack.append(node)
        elif token == ")":
            stack.pop()
        else:
            stack[-1].append(json.loads(token) if token.startswith('"') else token)
    if stack or root[0] != "kicad_pcb":
        raise ValueError("Invalid native board expression")
    parts = {}
    for fp in (n for n in root if isinstance(n, list) and n[0] == "footprint"):
        fields = {n[1]: n[2] for n in fp if isinstance(n, list) and n[0] == "property"}
        at = next(n for n in fp if isinstance(n, list) and n[0] == "at")
        pads = {}
        for pad in (n for n in fp if isinstance(n, list) and n[0] == "pad"):
            net = next((n for n in pad if isinstance(n, list) and n[0] == "net"), None)
            pads[pad[1]] = net[-1] if net else None
        parts[fields["Reference"]] = {"value": fields.get("Value"), "mpn": fields.get("MPN"),
            "footprint": fp[1], "x_mm": float(at[1]), "y_mm": float(at[2]),
            "rotation_deg": float(at[3]) if len(at) > 3 else 0, "pad_nets": pads}
    return parts


def checked(folder):
    job = json.loads((folder / "job.json").read_text())
    if job["status"] != "succeeded" or job["exit_code"] != 0:
        raise ValueError("Successful native job required")
    for row in job["artifacts"]:
        file = folder / "output" / row["name"]
        if file.stat().st_size != row["bytes"] or sha(file) != row["sha256"]:
            raise ValueError("Native artifact differs: " + row["name"])
    return job


def main():
    ap = argparse.ArgumentParser()
    for name in ("pcb", "case", "pictures"):
        ap.add_argument("--" + name, type=Path, required=True)
    args = ap.parse_args()
    jobs = {k: checked(getattr(args, k)) for k in ("pcb", "case", "pictures")}
    published = {}

    def copy(source, relative):
        target = ROOT / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        raw = source.read_bytes()
        is_text = source.suffix in TEXT or source.name.endswith("lib-table")
        data = raw.replace(b"\r\n", b"\n") if is_text else raw
        target.write_bytes(data)
        published[relative] = {"sha256": sha(target), "native_sha256": hashlib.sha256(raw).hexdigest(),
                              "normalization": "CRLF to LF" if data != raw else "none"}

    pcb = args.pcb / "output"
    for name in ("vhos_rgbw_revh.kicad_pcb", "vhos_rgbw_revh.kicad_pro", "vhos_rgbw_revh.kicad_sch",
                 "VHOS.kicad_sym", "fp-lib-table", "sym-lib-table", "erc.json", "drc.json", "terminal-map.json",
                 "terminal-electrical-audit.json", "electrical-screen.json", "copper-audit.json", "interface-change.json",
                 "factory-metadata-audit.json", "routed_shield.step", "schematic.pdf", "board.png"):
        copy(pcb / name, "generated/" + name)
    for directory in ("VHOS_RevB.pretty", "models", "fabrication"):
        for file in (pcb / directory).rglob("*"):
            if file.is_file():
                copy(file, "generated/" + file.relative_to(pcb).as_posix())
    case = args.case / "output"
    for name in ("4Runner_RevH_Terminal_Assembly.FCStd", "4Runner_RevH_Terminal_Assembly.step", "gland-fit.json",
                 "support-free.json", "wire-cut-routing.csv", "case_base.step", "case_base.stl", "case_lid.step",
                 "case_lid.stl", "gland_plate.step", "gland_plate.stl"):
        copy(case / name, "generated/" + name)
    for file in (args.pictures / "output").iterdir():
        if file.suffix in {".png", ".blend"} or file.name == "picture-checks.json":
            copy(file, "images/" + file.name)

    parts = board_parts(ROOT / "generated/vhos_rgbw_revh.kicad_pcb")
    (ROOT / "generated/native-parts.json").write_text(json.dumps(parts, indent=2) + "\n")
    with (ROOT / "jlcpcb/BOM.csv").open() as stream:
        bom = list(csv.DictReader(stream))
    expected = {}
    for line in bom:
        for ref in line["Designator"].split(","):
            if ref in expected or parts[ref]["mpn"] != line["Comment"]:
                raise ValueError("Native BOM identity mismatch: " + ref)
            expected[ref] = line
    actual = {ref for ref, p in parts.items() if p["mpn"] and not ref.startswith(("TP", "MH"))}
    if expected.keys() != actual or len(actual) != 67:
        raise ValueError("Factory BOM must cover all 67 populated positions")
    with (ROOT / "jlcpcb/CPL.csv").open() as stream:
        cpl = list(csv.DictReader(stream))
    if {row["Designator"] for row in cpl} != actual or len(cpl) != 67:
        raise ValueError("Factory placement coverage differs")
    for line in cpl:
        ref = line["Designator"]
        part = parts[ref]
        x, y = part["x_mm"], part["y_mm"]
        if ref.startswith("JT"):
            x, y = x - .05, y + 2.54
        if abs(float(line["Mid X"].removesuffix("mm")) - x) > .001 or abs(float(line["Mid Y"].removesuffix("mm")) + y) > .001:
            raise ValueError("Factory centroid differs from native board: " + ref)
        if (float(line["Rotation"]) - part["rotation_deg"]) % 360 > .001:
            raise ValueError("Factory rotation differs: " + ref)
    case_report = json.loads((case / "gland-fit.json").read_text())
    slicer = json.loads((case / "support-free.json").read_text())
    pcb_report = json.loads((pcb / "job-result.json").read_text())
    runtime_sources = {"terminal_design.py": args.pcb, "terminal_pcb.py": args.pcb,
                       "terminal_cad.py": args.case, "terminal_render.py": args.pictures}
    for name, folder in runtime_sources.items():
        if sha(ROOT / name) != sha(folder / "output/source" / name):
            raise ValueError("Published runtime source differs from accepted native job: " + name)
    for name in ("jlcpcb/BOM.csv", "jlcpcb/CPL.csv", "jlcpcb/catalog-live.json", "HARNESS-AND-CASE.csv",
                 "WIRE-REGISTER.csv", "generated/native-parts.json", *runtime_sources):
        published.setdefault(name, {"sha256": sha(ROOT / name), "normalization": "none"})
    manifest = {"populated_board_count": 1, "factory_populated_positions": 67,
                "kicad_findings": pcb_report["native_findings"],
                "case_and_wire_checks_passed": sum(c["pass"] for c in case_report["checks"]),
                "tool_axes_passed": sum(c["pass"] for c in case_report["tool_axes"]),
                "slices_with_zero_support_segments": sum(c["pass"] and c["support_segments"] == 0 for c in slicer["offline_slices"].values()),
                "native_jobs": {k: {field: j[field] for field in ("job_id", "status", "completed_at", "duration_sec", "params")}
                                for k, j in jobs.items()},
                "published_files": published, "physical_qualification": False, "manufacturing_released": False}
    (ROOT / "generated/verification.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({k: v for k, v in manifest.items() if k not in {"published_files", "native_jobs"}}))


if __name__ == "__main__":
    main()
