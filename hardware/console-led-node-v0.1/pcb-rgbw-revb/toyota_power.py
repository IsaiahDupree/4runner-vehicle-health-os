"""Build the direct-lead variants of the existing routed RGBW shield."""

import json
from pathlib import Path
import re
import shutil

from design import REV_C_NAME


ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "toyota-power.json").read_text(encoding="utf-8"))
REVB_PADS = {
    "J1": "VHOS_RevB:Molex_Mega-Fit_76825-0002_2x01_P5.70mm_Horizontal",
    "J2": "VHOS_RevB:Molex_Micro-Fit_3.0_43045-0800_2x04_P3.00mm_Horizontal",
}
DIRECT_LEADS = {
    "J1": ("Toyota_Power_2_Pads", "TOYOTA POWER IN"),
    "J2": ("RGBW_Output_5_Pads", "RGBW OUT"),
}


def replace_one(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Expected one instance of {old}")
    return source.replace(old, new, 1)


def prepare_native(inputs, out, name, *, dedicated_pads=False):
    """Prepare the native files for the selected direct-lead build."""
    output_name = REV_C_NAME if dedicated_pads else name
    pcb = inputs / (name + ".kicad_pcb")
    raw = pcb.read_text(encoding="utf-8")
    schematic = inputs / (name + ".kicad_sch")
    raw_schematic = schematic.read_text(encoding="utf-8")
    library_text = (inputs / "VHOS.kicad_sym").read_text(encoding="utf-8")
    if dedicated_pads:
        raw_schematic, library_text = direct_lead_symbols(raw_schematic, library_text)
        raw_schematic = raw_schematic.replace(f'(project "{name}"', f'(project "{output_name}"')
    else:
        raw = mark_connectors_dnp(raw)
        for ref in REVB_PADS:
            pattern = rf'(\(symbol \(lib_id "VHOS:{ref}"\)[^\n]*?\(dnp )no(\))'
            raw_schematic, count = re.subn(pattern, r"\g<1>yes\2", raw_schematic, count=1)
            if count != 1:
                raise ValueError(f"Missing placed {ref} schematic symbol")
    (out / (output_name + ".kicad_pcb")).write_text(raw, encoding="utf-8")
    (out / (output_name + ".kicad_sch")).write_text(raw_schematic, encoding="utf-8")
    project = inputs / (name + ".kicad_pro")
    if dedicated_pads:
        config = json.loads(project.read_text(encoding="utf-8"))
        config["meta"]["filename"] = output_name + ".kicad_pro"
        (out / config["meta"]["filename"]).write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    else:
        shutil.copyfile(project, out / project.name)
    for library in ("fp-lib-table", "sym-lib-table"):
        shutil.copyfile(inputs / library, out / library)
    (out / "VHOS.kicad_sym").write_text(library_text, encoding="utf-8")
    shutil.copytree(inputs / "VHOS_RevB.pretty", out / "VHOS_RevB.pretty")
    (out / "models").mkdir()
    shutil.copyfile(inputs / "models/MINI-3568.step", out / "models/MINI-3568.step")


def mark_connectors_dnp(raw):
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
    return "".join(blocks)


def direct_lead_symbols(schematic, library):
    def edit_definition(match):
        text = match[0]
        ref = match[1]
        text = replace_one(text, REVB_PADS[ref], f"VHOS_RevB:{DIRECT_LEADS[ref][0]}")
        text = replace_one(text, "(in_bom yes)", "(in_bom no)")
        if ref == "J1":
            return replace_one(text, '"VEHICLE IN"', f'"{DIRECT_LEADS[ref][1]}"')
        text, count = re.subn(r'\(pin passive line \(at [^)]*\) \(length [\d.]+\) '
                              r'\(name "[678]" \(effects \(font \(size .8 .8\)\)\)\) '
                              r'\(number "[678]" \(effects \(font \(size .8 .8\)\)\)\)\)', "", text)
        if count != 3:
            raise ValueError("Expected three unused J2 symbol pins")
        return text

    def edit_placed(match):
        text = match[0]
        ref = match[1]
        text = replace_one(text, REVB_PADS[ref], f"VHOS_RevB:{DIRECT_LEADS[ref][0]}")
        text = replace_one(text, "(in_bom yes)", "(in_bom no)")
        text, count = re.subn(r'\(property "MPN" "[\d-]+" \(at [^)]*\) '
                              r'\(effects \(font \(size .9 .9\)\) hide\)\)', "", text)
        if count != 1:
            raise ValueError(f"Missing {ref} MPN field")
        if ref == "J1":
            return replace_one(text, '"VEHICLE IN"', f'"{DIRECT_LEADS[ref][1]}"')
        text, count = re.subn(r'\(pin "[678]" \(uuid "[0-9a-f-]+"\)\)', "", text)
        if count != 3:
            raise ValueError("Expected three unused J2 placed pins")
        return text

    # The generated definitions can be adjacent on the same line. Stop at
    # the next top-level symbol definition rather than consuming other parts.
    definitions = r'\(symbol "(?:VHOS:)?(J[12])" \(pin_names .*?(?=\(symbol "(?:VHOS:)?[A-Z]+\d+"|\(symbol "(?:VHOS:)?PWR_FLAG")'
    schematic, count = re.subn(definitions, edit_definition, schematic, flags=re.DOTALL)
    library, library_count = re.subn(definitions, edit_definition, library, flags=re.DOTALL)
    if count != 2 or library_count != 2:
        raise ValueError("Expected both harness symbol definitions in each library")
    placed = r'\(symbol \(lib_id "VHOS:(J[12])"\).*?\(instances \(project "[^"]+" \(path "[^"]+" \(reference "J[12]"\) \(unit 1\)\)\)\)\)'
    schematic, count = re.subn(placed, edit_placed, schematic, flags=re.DOTALL)
    if count != 2:
        raise ValueError("Expected both placed harness symbols")
    schematic, count = re.subn(r'\(no_connect \(at 148\.59 (?:340\.36|342\.9|345\.44)\) '
                              r'\(uuid "[0-9a-f-]+"\)\)', "", schematic)
    if count != 3:
        raise ValueError("Expected three removed J2 no-connect markers")
    schematic = replace_one(schematic, '(title "4Runner two-connector RGBW shield") (rev "B")',
                            '(title "4Runner Toyota-powered RGBW shield") (rev "C")')
    return schematic, library


def check_reports(out):
    erc = json.loads((out / "erc.json").read_text(encoding="utf-8"))
    drc = json.loads((out / "drc.json").read_text(encoding="utf-8"))
    findings = {"erc": sum(len(sheet["violations"]) for sheet in erc["sheets"]),
                **{key: len(drc.get(key, [])) for key in ("violations", "unconnected_items", "schematic_parity")}}
    if any(findings.values()):
        raise ValueError(f"Direct-lead KiCad findings: {findings}")
    return findings
