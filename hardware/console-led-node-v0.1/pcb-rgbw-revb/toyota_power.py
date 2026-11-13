"""Build the direct-lead population of the existing routed Rev B shield."""

import json
from pathlib import Path
import re
import shutil


ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "toyota-power.json").read_text(encoding="utf-8"))


def prepare_native(inputs, out, name):
    """Mark the two removable headers DNP without changing any copper or nets."""
    pcb = inputs / (name + ".kicad_pcb")
    raw = pcb.read_text(encoding="utf-8")
    matches = set()
    blocks = re.split(r"(?=^\t\(footprint )", raw, flags=re.MULTILINE)
    for index, block in enumerate(blocks[1:], 1):
        match = re.search(r'^\t\t\(property "Reference" "(J[12])"$', block, flags=re.MULTILINE)
        if not match:
            continue
        ref = match[1]
        pads = {}
        for pad in re.split(r'(?=^\t\t\(pad )', block, flags=re.MULTILINE)[1:]:
            number = re.match(r'^\t\t\(pad "(\d+)" thru_hole ', pad)
            net = re.search(r'^\t\t\t\(net "/([^"]+)"\)$', pad, flags=re.MULTILINE)
            if number and net:
                pads[number[1]] = net[1]
        if pads != SPEC["pad_assignments"][ref]:
            raise ValueError(f"{ref} plated pad assignments changed: {pads}")
        blocks[index], count = re.subn(r'^\t\t\(attr through_hole\)$',
                                      "\t\t(attr through_hole dnp)", block, count=1, flags=re.MULTILINE)
        if count != 1 or ref in matches:
            raise ValueError(f"Expected one unmodified through-hole {ref} footprint")
        matches.add(ref)
    if matches != set(SPEC["pad_assignments"]):
        raise ValueError("Expected both Rev B connector footprints")
    (out / pcb.name).write_text("".join(blocks), encoding="utf-8")

    schematic = inputs / (name + ".kicad_sch")
    raw_schematic = schematic.read_text(encoding="utf-8")
    for ref in sorted(matches):
        pattern = rf'(\(symbol \(lib_id "VHOS:{ref}"\)[^\n]*?\(dnp )no(\))'
        raw_schematic, count = re.subn(pattern, r"\g<1>yes\2", raw_schematic, count=1)
        if count != 1:
            raise ValueError(f"Missing placed {ref} schematic symbol")
    (out / schematic.name).write_text(raw_schematic, encoding="utf-8")
    project = inputs / (name + ".kicad_pro")
    shutil.copyfile(project, out / project.name)
    for library in ("fp-lib-table", "sym-lib-table", "VHOS.kicad_sym"):
        shutil.copyfile(inputs / library, out / library)
    shutil.copytree(inputs / "VHOS_RevB.pretty", out / "VHOS_RevB.pretty")
    (out / "models").mkdir()
    shutil.copyfile(inputs / "models/MINI-3568.step", out / "models/MINI-3568.step")


def check_reports(out):
    erc = json.loads((out / "erc.json").read_text(encoding="utf-8"))
    drc = json.loads((out / "drc.json").read_text(encoding="utf-8"))
    findings = {"erc": sum(len(sheet["violations"]) for sheet in erc["sheets"]),
                **{key: len(drc.get(key, [])) for key in ("violations", "unconnected_items", "schematic_parity")}}
    if any(findings.values()):
        raise ValueError(f"Direct-lead KiCad findings: {findings}")
    return findings
