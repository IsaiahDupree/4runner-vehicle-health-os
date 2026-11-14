"""Rev E single-board architecture and enclosure datum."""

from design import CASE, component
from illumination import BASE_RESISTOR, CAPACITOR, SOT23, parts as rev_d_parts


NAME = "vhos_rgbw_reve"
TITLE = "4Runner RGBW controller with onboard ESP32-S3"
CONTRACT = "vhos_rgbw_reve_single_board_v1"
MODULE = "ESP32-S3-WROOM-1-N16R8"
# The KiCad module's antenna starts 6.75 mm along its rotated +X axis.
MODULE_XY = (162.25, 126.7)
BOARD_EDGE_X = MODULE_XY[0] + 6.75
OUTLINE = [(47, 153.34), (BOARD_EDGE_X, 153.34), (BOARD_EDGE_X, 100), (47, 100)]
MOUNTS = {"MH1": (54, 148.54), "MH2": (58, 102.84), "MH3": (145.2, 148.55), "MH4": (150.75, 104.1)}
CASE_DIMS = {**CASE, "width_mm": 150, "body_height_mm": 36, "esp_pcb_bottom_mm": 13.0,
             "stack_pitch_mm": 0, "insert_depth_mm": 7.0}
PROGRAM_PADS = {
    "TP9": ("GND", (155, 151.55)), "TP10": ("UART_TX", (157.95, 151.55)),
    "TP11": ("UART_RX", (160.9, 151.55)), "TP12": ("BOOT_N", (163.85, 151.55)),
    "TP13": ("CHIP_EN", (166.8, 151.55)), "TP14": ("ESP_3V3", (163.8, 103.4)),
}
REMOVED = {"H1", "H2", "H3", "H4", "JP1", *MOUNTS}
REROUTE = {"ESP_5V", "ESP_3V3", "TAIL_ADC", "DIM_ADC", "TAIL_SW", "DIM_SW",
           "PWM_R", "PWM_G", "PWM_B", "PWM_W", "ENABLE_REQ"}
PIN_NAMES = {
    1: "GND", 2: "3V3", 3: "EN", 4: "IO4", 5: "IO5", 6: "IO6", 7: "IO7", 8: "IO15",
    9: "IO16", 10: "IO17", 11: "IO18", 12: "IO8", 13: "IO19", 14: "IO20", 15: "IO3", 16: "IO46",
    17: "IO9", 18: "IO10", 19: "IO11", 20: "IO12", 21: "IO13", 22: "IO14", 23: "IO21", 24: "IO47",
    25: "IO48", 26: "IO45", 27: "IO0", 28: "IO35", 29: "IO36", 30: "IO37", 31: "IO38", 32: "IO39",
    33: "IO40", 34: "IO41", 35: "IO42", 36: "RXD0", 37: "TXD0", 38: "IO2", 39: "IO1", 40: "GND", 41: "EPAD",
}
MODULE_NETS = {1: "GND", 2: "ESP_3V3", 3: "CHIP_EN", 4: "DIM_ADC", 5: "TAIL_ADC",
               10: "PWM_G", 11: "PWM_R", 16: "DOWNLOAD_STRAP", 22: "PWM_B", 23: "ENABLE_REQ",
               27: "BOOT_N", 36: "UART_RX", 37: "UART_TX", 38: "PWM_W", 40: "GND", 41: "GND"}


def board_xy(xy):
    return xy[0] - 100, 153.34 - xy[1]


def parts():
    base = [part for part in rev_d_parts() if part["ref"] not in REMOVED]

    def part(ref, value, fp, nets, xy, mpn=None, **details):
        return component(ref, value, fp, nets, board_xy(xy), mpn, section="controller", **details)

    new = [
        part("U11", MODULE, "VHOS_RevB:ESP32-S3-WROOM-1", dict.fromkeys(PIN_NAMES) | MODULE_NETS,
             MODULE_XY, MODULE, angle=-90, names={str(pin): name for pin, name in PIN_NAMES.items()},
             types={"1": "power_in", "2": "power_in", "40": "power_in", "41": "power_in",
                    **dict.fromkeys(("3", "4", "5", "16", "27", "36"), "input"),
                    **dict.fromkeys(("10", "11", "22", "23", "37", "38"), "output")},
             note="Internal antenna overhangs the board edge. Module has 16 MB flash and 8 MB PSRAM."),
        part("U9", "TLV62569DBVR", "Package_TO_SOT_SMD:SOT-23-5",
             {1: "V5_LOGIC", 2: "GND", 3: "SW_3V3", 4: "V5_LOGIC", 5: "FB_3V3"},
             (153.4, 110.1), "TLV62569DBVR", names={"1": "EN", "2": "GND", "3": "SW", "4": "VIN", "5": "FB"},
             types={"1": "input", "2": "power_in", "3": "power_out", "4": "power_in", "5": "input"},
             note="Second-stage 5 V to 3.3 V synchronous buck. Target 500 mA transient load at module."),
        part("L2", "2.2uH", "Inductor_SMD:L_Bourns-SRN4018", {1: "SW_3V3", 2: "ESP_3V3"},
             (153.7, 114.1), "SRN4018-2R2M"),
        part("U10", "TLV803EC30DBZR", SOT23, {1: "CHIP_EN", 2: "GND", 3: "ESP_3V3"},
             (163.8, 111.7), "TLV803EC30DBZR", names={"1": "RESET_N", "2": "GND", "3": "VDD"},
             types={"1": "open_collector", "2": "power_in", "3": "power_in"},
             note="Open-drain 3.08 V reset supervisor, nominal 10 ms release. Allows the service adapter to pull EN low."),
    ]
    for ref, value, nets, pos, mpn in (
        ("R34", "453k 1%", ("ESP_3V3", "FB_3V3"), (157.9, 108.0), "RC0603FR-07453KL"),
        ("R35", "100k 1%", ("FB_3V3", "GND"), (157.9, 105.4), "RC0603FR-07100KL"),
        ("R36", "10k", ("ESP_3V3", "CHIP_EN"), (161.4, 106.0), "RC0603FR-0710KL"),
        ("R37", "10k", ("ESP_3V3", "BOOT_N"), (166, 138.8), "RC0603FR-0710KL"),
        ("R38", "10k", ("DOWNLOAD_STRAP", "GND"), (166, 142.2), "RC0603FR-0710KL"),
    ):
        new.append(part(ref, value, BASE_RESISTOR, dict(enumerate(nets, 1)), pos, mpn))
    for ref, site, net, angle in (("C22", (159.8, 111.1), "V5_LOGIC", 90),
                                  ("C23", (159.1, 115.35), "ESP_3V3", 0),
                                  ("C24", (153.5, 139.1), "ESP_3V3", 0)):
        new.append(part(ref, "22u 16V X7R", "Capacitor_SMD:C_1206_3216Metric", {1: net, 2: "GND"},
                        site, "EMK316BB7226ML-T", angle=angle))
    new.extend([
        part("C25", "100n 50V X7R", CAPACITOR, {1: "ESP_3V3", 2: "GND"},
             (166.05, 115.1), "GRM188R71H104KA93D"),
        part("C26", "1u 25V X7R", CAPACITOR, {1: "CHIP_EN", 2: "GND"},
             (165.1, 106.6), "GRM188R71E105KA12D"),
    ])
    new.extend(part(ref, net, "TestPoint:TestPoint_Pad_D1.5mm", {1: net}, site)
               for ref, (net, site) in PROGRAM_PADS.items())
    new.extend(part(ref, "M3 CASE SUPPORT", "MountingHole:MountingHole_3.2mm_M3", {}, site)
               for ref, site in MOUNTS.items())
    return base + new
