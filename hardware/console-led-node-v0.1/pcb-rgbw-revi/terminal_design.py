"""Rev I electrical interfaces and manufacturer-drawing terminal dimensions (mm)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
LEGACY = ROOT / "legacy"
if not LEGACY.is_dir():
    LEGACY = ROOT.parent / "pcb-rgbw-revb"
sys.path.insert(0, str(LEGACY))
import lean_board
from design import component
import single_board
# Legacy design.py loads its reference library at sys.path[0]. Restore the
# integrated-board helpers ahead of that earlier revision's native module.
sys.path.insert(0, str(LEGACY))

NAME = "vhos_rgbw_revi"
TITLE = "4Runner single-board RGBW controller - protected ACC voltage sense"
MPN = "KF128-5.08-2P-AA"
CODE = "C474952"
FOOTPRINT = "VHOS_RevB:KEFA_KF128_5.08_2P"
# Origin is pin 1. -90 degree placement makes side entry face the gland plate.
# PCB numbering is ours; the family drawing does not assign electrical numbers.
PITCH = 5.08
BODY = (-2.54, -5.30, 10.16, 10.70, 14.10)
DRILL = 1.40
PIN_LENGTH = 4.30
PAD_DIAMETER = 2.80
TERMINALS = (
    ("JT1", (45.5, 118.77), ("GND", "VEH_ACC"), ("GND", "ACC"), (5, 6)),
    ("JT2", (45.5, 108.01), ("TAIL_12V", "DIM_RETURN"), ("TAIL", "DIM"), (1, 2)),
    ("JT3", (45.5, 97.25), (None, None), ("RSV3", "RSV4"), (3, 4)),
    ("JT4", (48.5, 151.05), ("LED_R_NEG", "LED_G_NEG"), ("R-", "G-"), (None, None)),
    ("JT5", (48.5, 140.29), ("LED_B_NEG", "LED_POS"), ("B-", "+LED"), (None, None)),
    ("JT6", (48.5, 129.53), ("LED_W_NEG", None), ("W-", "NC"), (None, None)),
)
CONNECTOR_NETS = {n for _, _, nets, _, _ in TERMINALS for n in nets if n}


def parts():
    values = [p for p in lean_board.parts() if p["ref"] not in {"J1", "J2"}]
    for ref, xy, nets, labels, _ in TERMINALS:
        values.append(component(ref, "/".join(labels), FOOTPRINT,
                                dict(enumerate(nets, 1)), single_board.board_xy(xy), MPN,
                                angle=-90,
                                section="headers", names={str(i): n for i, n in enumerate(labels, 1)},
                                note="Factory wave-soldered screw block; no wire soldering. "
                                     "NC/reserve pads isolated from circuit and copper pours."))
    for part in values:
        if part["ref"] == "D7":
            part["xy_mm"] = list(single_board.board_xy((56.7, 128.7)))
        elif part["ref"] == "MH1":
            part["xy_mm"] = list(single_board.board_xy((59, 150.67)))
        elif part["ref"] in {"F1", "F2"}:
            part["mpn"] = "3568-10"
    base = {p["ref"]: p for p in values}
    base["U5"]["nets"]["9"] = "VOLT_SW"
    base["U5"]["nets"]["10"] = "VOLT_CLAMP"
    base["U11"]["nets"]["39"] = "VOLT_ADC"
    # Clone the actual optimized Rev H frontend, including its 18k isolation
    # resistor and automotive-qualified clamp. No new manufacturer SKU.
    import copy
    added = (
        ("R24", "R40", {1: "ACC_FUSED", 2: "VOLT_SERIES"}, (95, 124)),
        ("R25", "R41", {1: "VOLT_SERIES", 2: "VOLT_CLAMP"}, (101, 124)),
        ("R28", "R42", {1: "VOLT_CLAMP", 2: "GND"}, (106, 125)),
        ("U6", "U12", {1: "VOLT_CLAMP", 2: "GND", 3: "GND"}, (106, 129.5)),
        ("D7", "D10", {1: "VOLT_CLAMP", 2: "GND"}, (110.5, 125)),
        ("R30", "R43", {1: "VOLT_SW", 2: "VOLT_ADC"}, (142, 128)),
        ("R32", "R44", {1: "VOLT_ADC", 2: "GND"}, (142, 132)),
        ("C19", "C32", {1: "VOLT_ADC", 2: "GND"}, (145, 129.5)),
    )
    for source, ref, nets, site in added:
        part = copy.deepcopy(base[source])
        part.update(ref=ref, nets={str(k): v for k,v in nets.items()},
                    xy_mm=list(single_board.board_xy(site)), angle_deg=0,
                    note="Rev I protected ACC_FUSED voltage sense; switched off until CHIP_EN releases.")
        values.append(part)
    return values


def case_xy(pcb_xy):
    return pcb_xy[0] - 14.0, 164.67 - pcb_xy[1]


def footprint_text():
    pads = "\n".join(
        f'(pad "{i + 1}" thru_hole {"rect" if i == 0 else "circle"} (at {i * PITCH} 0) '
        f'(size {PAD_DIAMETER} {PAD_DIAMETER}) (drill {DRILL}) (layers "*.Cu" "*.Mask"))'
        for i in range(2))
    return f'''(footprint "KEFA_KF128_5.08_2P" (version 20240108) (generator "pcbnew")
      (layer "F.Cu") (descr "KEFA KF128-5.08 family drawing Rev A 2021-03-13; 2P AA listing C474952")
      (attr through_hole)
      (property "Reference" "REF**" (at 2.54 -6.5) (layer "F.SilkS") (effects (font (size .8 .8))))
      (property "Value" "KF128-5.08-2P-AA" (at 2.54 7) (layer "F.Fab") (effects (font (size .8 .8))))
      (fp_rect (start -2.54 -5.3) (end 7.62 5.4) (stroke (width .12) (type default)) (fill none) (layer "F.Fab"))
      (fp_rect (start -2.65 -5.41) (end 7.73 5.51) (stroke (width .12) (type default)) (fill none) (layer "F.SilkS"))
      (fp_rect (start -2.79 -5.55) (end 7.87 5.65) (stroke (width .05) (type default)) (fill none) (layer "F.CrtYd"))
      {pads}
      (model "${{KIPRJMOD}}/models/KEFA_KF128_5.08_2P.step"
        (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0))))'''
