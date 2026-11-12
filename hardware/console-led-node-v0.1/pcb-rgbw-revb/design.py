"""Electrical and mechanical inputs for the two-connector RGBW shield."""

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
REFERENCE = ROOT / "reference"
if not REFERENCE.is_dir():
    REFERENCE = ROOT.parent / "pcb-rgbw-reva"
sys.path.insert(0, str(REFERENCE))
from circuit import design as rev_a_design


NAME = "vhos_rgbw_revb"
CONFIG = json.loads((ROOT / "engineering-inputs.json").read_text())
CONTRACT = CONFIG["contract"]
OUTLINE = CONFIG["outline"]
UPPER_MOUNTS = CONFIG["upper_mounts"]
CASE = CONFIG["case"]
PORTS = CONFIG["ports"]
FUSES = CONFIG["fuses"]
FUSE_GEOMETRY = CONFIG["fuse_geometry"]
FUSE_HOLDER = "VHOS_RevB:Keystone_3568_MINI_Vertical"



def component(ref, value, footprint, pins, xy, mpn=None, *, angle=0,
              section="power", names=None, types=None, note=""):
    return {
        "ref": ref, "value": value, "footprint": footprint,
        "nets": {str(key): value for key, value in pins.items()},
        "xy_mm": list(xy), "angle_deg": angle, "mpn": mpn,
        "pin_names": names or {}, "pin_types": types or {}, "note": note,
        "section": section,
    }


def design(headers):
    removed = {"J1", "J2", "D1", "D2", "TP1", "TP2", "TP3", "TP4", "MH1", "MH2", "JP1"}
    parts = [part for part in rev_a_design(headers) if part["ref"] not in removed]
    resistances = {
        "R1": "41K2", "R2": "1M", "R3": "221K", "R4": "158K", "R5": "49K9",
        "R6": "150K", "R7": "100K", "R8": "2K2",
        **{f"R{i}": "100R" for i in range(9, 13)},
        **{f"R{i}": "10K" for i in range(13, 17)},
        **{f"R{i}": "100K" for i in range(17, 21)},
    }
    caps = {
        "C4": "GRM188R71H222KA01D", "C5": "GRM188R71H332KA01D",
        "C6": "GRM1885C1H181JA01D", "C7": "MCAST32MSB7226KPNA1J",
        "C8": "MCAST32MSB7226KPNA1J", "C9": "GRM188R71H104KA93D",
        "C10": "GRM188R71E105KA12D", "C11": "GRM188R71H104KA93D",
        "C12": "GRM188R71E105KA12D",
    }
    for part in parts:
        ref = part["ref"]
        if ref in resistances:
            part["mpn"] = "RC0603FR-07" + resistances[ref] + "L"
            part["note"] = "Yageo RC0603, 1%, 0.1 W."
        if ref in caps:
            part["mpn"] = caps[ref]
        if ref == "D6":
            part["xy_mm"] = [6, 33]
        if ref in ("H1", "H2", "H3", "H4"):
            part["mpn"] = "PRT-11417"
            part["note"] = "One SparkFun kit supplies all four long-tail headers. Verify seating with the owned board."

    for ref, port in PORTS.items():
        parts.append(component(ref, port["name"], port["footprint"], port["pins"], port["xy"], port["mpn"],
                               angle=90, section="headers", note="Cable mate " + port["mate"]))
    for ref, fuse in FUSES.items():
        parts.append(component(ref, f'{fuse["amps"]}A MINI {fuse["label"]}', FUSE_HOLDER,
                               {1: fuse["in"], 2: fuse["out"]}, fuse["xy"], "3568",
                               note=f'Socket and removable element {fuse["element"]}'))

    # TI LM7480-Q1 Figure 10-1, common-drain input. SW and VSNS use the
    # controller's sense switch. The exposed pad remains electrically floating.
    parts += [
        component("U4", "LM74800-Q1", "Package_SON:WSON-12-1EP_3x3mm_P0.5mm_EP1.5x2.5mm",
                  {1: "DGATE", 2: "ACC_FUSED", 3: "ACC_FUSED", 4: "OV_FEED", 5: "OV_SENSE",
                   6: "POWER_MID", 7: "GND", 8: "HGATE", 9: "LED_POS", 10: "POWER_MID",
                   11: "CAP_PUMP", 12: "POWER_MID", 13: None}, (-18.5, 25.1), "LM74800QDRRRQ1",
                  names=dict(zip(map(str, range(1, 14)), ("DGATE", "A", "VSNS", "SW", "OV", "EN/UVLO",
                             "GND", "HGATE", "OUT", "VS", "CAP", "C", "RTN"))),
                  note="Common-drain reverse battery protection and OV cutoff. RTN exposed pad floating."),
        component("D1", "TPSMB33CA", "Diode_SMD:D_SMB", {1: "ACC_FUSED", 2: "GND"},
                  (-14.3, 39), "TPSMB33CA", note="Bidirectional input TVS after the 58 V fuse."),
        component("Q5", "BUK9Y15-100E", "Package_TO_SOT_SMD:LFPAK56",
                  {1: "ACC_FUSED", 2: "ACC_FUSED", 3: "ACC_FUSED", 4: "DGATE", 5: "POWER_MID"},
                  (-25, 32), "BUK9Y15-100E,115", note="100 V reverse-blocking NMOS, source on fused input."),
        component("Q6", "BUK9Y15-100E", "Package_TO_SOT_SMD:LFPAK56",
                  {1: "LED_POS", 2: "LED_POS", 3: "LED_POS", 4: "HGATE", 5: "POWER_MID"},
                  (-14, 32), "BUK9Y15-100E,115", angle=180,
                  note="100 V cutoff NMOS, source on protected output."),
        component("R21", "46.4k 0.1%", "Resistor_SMD:R_0603_1608Metric",
                  {1: "OV_FEED", 2: "OV_SENSE"}, (-21.0, 20.8), "RT0603BRD0746K4L"),
        component("R22", "4.02k 0.1%", "Resistor_SMD:R_0603_1608Metric",
                  {1: "OV_SENSE", 2: "GND"}, (-17.7, 20.8), "RT0603BRD074K02L"),
        component("R23", "100R", "Resistor_SMD:R_0603_1608Metric",
                  {1: "HGATE", 2: "INRUSH"}, (-13, 24.8), "RC0603FR-07100RL"),
        component("C13", "100n 100V X7R", "Capacitor_SMD:C_0805_2012Metric",
                  {1: "ACC_FUSED", 2: "GND"}, (-25.2, 38.4), "GRM21BR72A104KA01L"),
        component("C14", "100n 100V X7R", "Capacitor_SMD:C_0805_2012Metric",
                  {1: "POWER_MID", 2: "GND"}, (-22.8, 26.7), "GRM21BR72A104KA01L"),
        component("C15", "100n 50V X7R", "Capacitor_SMD:C_0603_1608Metric",
                  {1: "CAP_PUMP", 2: "POWER_MID"}, (-15.5, 27.8), "GRM188R71H104KA93D"),
        component("C16", "10n 100V X7R", "Capacitor_SMD:C_0805_2012Metric",
                  {1: "INRUSH", 2: "GND"}, (-9.3, 24.8), "GRM21BR72A103KA01L"),
        component("C17", "47u 50V", "Capacitor_SMD:CP_Elec_8x6.2",
                  {1: "LED_POS", 2: "GND"}, (-3.4, 34.2), "EEEFK1H470P"),
        component("JP1", "5V RUN SHUNT", "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
                  {1: "V5_LOGIC", 2: "ESP_5V"}, (33.5, 6.4), "TSW-102-07-G-S", angle=90,
                  section="headers", note="Fit SNT-100-BK-G shunt after standalone power and USB checks."),
    ]
    for index, xy in enumerate(UPPER_MOUNTS, start=1):
        parts.append(component(f"MH{index}", "M3 CASE SUPPORT", "MountingHole:MountingHole_3.2mm_M3",
                               {}, xy, section="headers"))
    return parts


def minimum_width(net):
    if net in {f"LED_{color}_NEG" for color in "RGBW"}:
        return 1.0
    if net in {"SW", "V5_LOGIC", "VIN_PROT"}:
        return 0.8
    return 0.20
