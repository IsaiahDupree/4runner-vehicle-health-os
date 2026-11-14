"""Rev G power and LED circuit, retaining the native IR1 and RGBW interfaces."""

import csv
from itertools import product
from pathlib import Path

from design import component
import single_board
import stock_board

NAME = "vhos_rgbw_revg"
TITLE = "4Runner RGBW controller with integrated power and LED drivers"
CONTRACT = "vhos_rgbw_revg_integrated_single_board_v1"
MODULE = "ESP32-S3-WROOM-1-N16R2"
EPACKAGES = {"U2": ("TI_PWP0016J", (2.46, 3.55)), "U4": ("TI_PWP0016A", (3.30, 3.30))}
BASE = Path(__file__).resolve().parent

# Remove the second buck, discrete protection FETs, gate drivers, and their
# support circuits. References shared with earlier revisions retain their roles
# where possible to make continuity checks easier.
REPLACED = {
    "U1", "U2", "U4", "L1", "Q1", "D2", "C2", "C3", "C4", "C27",
    "R1", "R2", "R3", "R4", "R5", "R13", "R21", "R22", "TP5", "TP7",
}
REMOVED = REPLACED | {
    "U3", "U8", "U9", "L2", "Q2", "Q3", "Q4", "Q5", "Q6", "D3", "D4", "D5", "D6",
    "C1", "C5", "C6", "C7", "C8", "C9", "C10", "C11", "C12", "C14", "C15", "C16", "C21",
    "R6", "R7", "R8", "R9", "R10", "R11", "R12", "R14", "R15", "R16", "R23",
    "R34", "R35",
}

R0603 = "Resistor_SMD:R_0603_1608Metric"
C0603 = "Capacitor_SMD:C_0603_1608Metric"
C0805 = "Capacitor_SMD:C_0805_2012Metric"
C1210 = "Capacitor_SMD:C_1210_3225Metric"
MOVED = {
    "C13": ((79.6, 115.5), 0), "C17": ((79, 137.4), 0),
    "C22": ((141.85, 110.4), 180), "C23": ((141.85, 115.3), 180),
    "R17": ((70, 147), 180), "R18": ((70, 149), 180),
    "R19": ((70, 151), 180), "R20": ((65, 151), 180),
}


def selection():
    choices = stock_board.selection()
    with (BASE / "lean_board_parts.csv").open(newline="", encoding="utf-8") as stream:
        changed = list(csv.DictReader(stream))
    updates = {row["ref"]: row for row in changed}
    if len(updates) != len(changed) or not REPLACED - {"TP5", "TP7"} <= updates.keys():
        raise ValueError("Rev G replacement population is incomplete")
    return {ref: row for ref, row in choices.items() if ref not in REMOVED} | updates


def parts():
    def part(ref, fp, pins, xy, **details):
        return component(ref, "", fp, pins, single_board.board_xy(xy), **details)

    def circuit_pins(names, **types):
        return dict(enumerate(names.split(), 1)), {
            str(i): types.get(name, "passive") for i, name in enumerate(names.split(), 1)
        }

    def ic(ref, fp, pins, xy, names, *, pin_types, **details):
        by_pin, types = circuit_pins(names, **pin_types)
        return part(ref, fp, dict(enumerate(pins, 1)), xy, names={str(i): v for i, v in by_pin.items()},
                    types=types, **details)

    def pair(ref, a, b, xy, *, footprint=R0603, angle=0, section="power", note=""):
        return part(ref, footprint, {1: a, 2: b}, xy, angle=angle, section=section, note=note)

    new = [
        ic("U4", "VHOS_RevB:TI_PWP0016A",
           ("ACC_FUSED", "ACC_FUSED", "UVLO", None, "OVP", "EFUSE_RTN", None, "EFUSE_RTN",
            "GND", None, "ILIM", "SLEW", None, None, "LED_POS", "LED_POS", "EFUSE_RTN"),
           (80.5, 120), "IN IN UVLO NC OVP MODE SHDN RTN GND IMON ILIM DVDT NC FLT OUT OUT EPAD",
           pin_types={"IN": "power_in", "UVLO": "input", "OVP": "input", "MODE": "input",
                      "GND": "power_in", "FLT": "open_collector"},
           note="Programmable input protection. Local RTN island is isolated from system GND."),
        ic("U1", "Package_TO_SOT_SMD:SOT-23-6", ("BOOTCAP", "GND", "FB_3V3", "VIN_PROT", "VIN_PROT", "SW"),
           (125, 111.5), "CB GND FB EN VIN SW",
           pin_types={"GND": "power_in", "VIN": "power_in", "FB": "input", "EN": "input", "SW": "power_out"},
           note="65 V, 400 kHz synchronous buck directly to the ESP32 3.3 V rail."),
        ic("U2", "VHOS_RevB:TI_PWP0016J",
           ("LED_POS", "LED_POS", "LED_R_NEG", "LED_G_NEG", "GND", "LED_B_NEG", "LED_W_NEG", "LED_EN_N",
            "GND", "PWM_W", "PWM_B", "GND", "PWM_G", "PWM_R", None, None, "GND"),
           (64, 142.5), "VM VCLAMP OUT1 OUT2 GND OUT3 OUT4 NENBL RESET IN4 IN3 GND IN2 IN1 NC NFAULT EPAD",
           pin_types={**dict.fromkeys(("VM", "GND", "EPAD"), "power_in"),
                      **dict.fromkeys(("IN1", "IN2", "IN3", "IN4", "RESET", "NENBL"), "input"),
                      **dict.fromkeys(("OUT1", "OUT2", "OUT3", "OUT4"), "open_collector")},
           section="outputs", note="Four low-side channels with clamp diodes returned to the protected LED supply."),
        part("Q1", "Package_TO_SOT_SMD:SOT-23", {1: "ENABLE_REQ", 2: "GND", 3: "LED_EN_N"}, (72, 143),
             section="outputs", names={"1": "G", "2": "S", "3": "D"},
             note="Preserves the active-high enable command. External gate pull-down holds the driver disabled at boot."),
        pair("D2", "LED_POS", "GND", (78, 149), footprint="Diode_SMD:D_SMB", angle=180, section="outputs",
             note="Protected-side rail clamp for energy returned by the driver's output clamp diodes."),
        pair("D9", "LED_POS", "GND", (91, 138), footprint="Diode_SMD:D_SMA", angle=180,
             note="Cathode at eFuse output. Suppresses the negative output transient on fast cut-off."),
        pair("L1", "SW", "ESP_3V3", (135, 110.8), footprint="VHOS_RevB:" + stock_board.INDUCTOR),
        pair("C2", "VIN_PROT", "GND", (126.2, 117.5), footprint=C1210, angle=180),
        pair("C3", "VIN_PROT", "GND", (120.5, 117.5), footprint=C1210, angle=180),
        pair("C4", "SLEW", "EFUSE_RTN", (86.2, 121.4), footprint=C0603),
        pair("C27", "LED_POS", "GND", (58.8, 138), footprint=C0805, angle=90, section="outputs"),
        pair("C28", "BOOTCAP", "SW", (125, 108.8), footprint=C0603),
        pair("C29", "VIN_PROT", "GND", (125, 114.5), footprint=C0805, angle=180),
        pair("C30", "ACC_FUSED", "GND", (73.7, 113.9), footprint=C1210, angle=180),
        pair("C31", "ESP_3V3", "GND", (141.85, 119.2),
             footprint="Capacitor_SMD:C_1206_3216Metric", angle=180),
        pair("R1", "ILIM", "EFUSE_RTN", (85.9, 123.8)),
        pair("R2", "ACC_FUSED", "UVLO", (74.4, 117.7), angle=180),
        pair("R3", "UVLO", "EFUSE_RTN", (74.4, 120.2), angle=180),
        pair("R4", "ESP_3V3", "FB_3V3", (120.1, 110.1)),
        pair("R5", "FB_3V3", "GND", (120.1, 112.5), angle=180),
        pair("R13", "ESP_3V3", "LED_EN_N", (72, 139.8), section="outputs"),
        pair("R21", "ACC_FUSED", "OVP", (74.9, 122.7)),
        pair("R22", "OVP", "EFUSE_RTN", (75.5, 125.2), angle=180),
        part("TP5", "TestPoint:TestPoint_Pad_D1.0mm", {1: "LED_POS"}, (146, 105.34), section="headers"),
        part("TP7", "TestPoint:TestPoint_Pad_D1.0mm", {1: "VIN_PROT"}, (139.5, 105.34), section="headers"),
    ]
    updates = selection()
    definitions = [p for p in stock_board.parts() if p["ref"] not in REMOVED] + new
    if {p["ref"] for p in definitions if p["mpn"]} - {"F1", "F2"} - updates.keys():
        raise ValueError("Rev G SMT population is missing a stock code")
    definitions.append(pair("R39", "ENABLE_REQ", "GND", (84, 145.2), section="outputs"))
    for p in definitions:
        ref = p["ref"]
        if ref in updates:
            row = updates[ref]
            p["mpn"], p["value"] = row["mpn"], row["value"] or p["value"]
        if ref in MOVED:
            xy, p["angle_deg"] = MOVED[ref]
            p["xy_mm"] = single_board.board_xy(xy)
        if ref in {"C22", "C23"}:
            p["nets"]["1"] = "ESP_3V3"
        if ref == "U5":
            p["nets"]["1"] = "CHIP_EN"
            p["note"] = "The shared open-drain supervisor selects grounded inputs until the rail is up."
        if ref == "U10":
            p["note"] = "3.08 V open-drain supervisor releases both ESP32 and sense input selection."
        if ref == "U11":
            p["note"] = "16 MB flash and 2 MB PSRAM. On-module antenna extends beyond the PCB edge."
        if ref in {"C26", "R28", "R29", "R32", "R33"}:
            p["note"] = "Rev G stocked basic assembly part for the existing function."
        if ref in {"TP5", "TP7"}:
            p["value"] = p["nets"]["1"]
    if set(updates) != {p["ref"] for p in definitions if p["mpn"]} - {"F1", "F2"}:
        raise ValueError("Rev G stock manifest differs from the schematic population")
    return definitions


def electrical_screen():
    """Bound steady-state values from component limits and resistor corners."""
    definitions = {p["ref"]: p for p in parts()}
    r = stock_board.resistance
    general, precise = .01 + .0001 * 65, .001 + .000025 * 65

    def ends(value, error=general):
        return value * (1 - error), value * (1 + error)

    def divider(high, low, thresholds, *, error=general, leak=100e-9, rtn_drop=(0, .05)):
        return [
            threshold * (1 + top / bottom) + top * bias + offset
            for threshold, top, bottom, bias, offset in product(
                thresholds, ends(r(definitions, high), error), ends(r(definitions, low), error),
                (-leak, leak), rtn_drop)
        ]

    uv_on = divider("R2", "R3", (1.175, 1.225))
    uv_off = divider("R2", "R3", (1.08, 1.125))
    ov_on = divider("R21", "R22", (1.17, 1.225), error=precise)
    ov_off = divider("R21", "R22", (1.085, 1.125), error=precise)
    v3 = divider("R4", "R5", (.788, .812), leak=.2e-9, rtn_drop=(0,))
    current = [12e3 * gain / value
               for gain, value in product((.95, 1.05), ends(r(definitions, "R1")))]
    rail_load = .7
    ripple = [
        voltage * (1 - voltage / vin) / (22e-6 * .8 * .9 * fsw)
        for voltage, vin, fsw in product((min(v3), max(v3)), (6, 16), (340e3, 460e3))
    ]
    led_max_channel = .5
    led_total = 1.0
    ron_screen = 1.1  # 0.8 ohm specified max at 85 C plus thermal design allowance.
    efuse_ron_screen = .30  # Allowance above the 0.15 ohm room-temperature typical.
    min_input = 10.5
    wire_and_copper_drop = .30
    load_with_radio = led_total + max(v3) * rail_load / (min_input * .75)
    switch_loss = led_total * led_max_channel * ron_screen
    led_voltage = min_input - load_with_radio * efuse_ron_screen - led_max_channel * ron_screen - wire_and_copper_drop
    reset_high = 3.08 * 1.02 * 1.015
    disable_high = min(v3) - max(ends(r(definitions, "R13"))) * 100e-6
    # The three 22 uF converter capacitors must retain at least half their
    # nominal combined capacitance under bias, tolerance and temperature.
    c_min = 3 * 22e-6 * .50
    step_floor = min(v3) - .5 * 12e-6 / c_min
    sense = {}
    for name, refs in (("TAIL", (24, 25, 28, 30, 32)), ("DIM", (26, 27, 29, 31, 33))):
        gains, lowest, shunt = [], [], []
        for a, b, term, isolation, pulldown in product(
                *(ends(r(definitions, f"R{idx}"), .001 + .00005 * 65 if idx <= 27 else general)
                  for idx in refs)):
            parallel = 1 / (1 / term + 1 / (isolation + pulldown))
            fraction = pulldown / (pulldown + isolation)
            gains.append(14.4 * parallel / (a + b + parallel) * fraction)
            lowest.append(-.5 * fraction)
            shunt.append((100 - 2.539) / (a + b) - 2.539 / term - 2.539 / (isolation + pulldown))
        sense[name] = {"adc_v_at_14_4_v": [min(gains), max(gains)], "adc_min_v_at_switch_minus_0_5_v": min(lowest),
                       "shunt_current_at_100v_ma": [1000 * min(shunt), 1000 * max(shunt)]}
    checks = {
        "efuse_cutoff": 14.8 < min(ov_on) <= max(ov_on) < 16.0,
        "efuse_restart": 6.3 < min(uv_on) <= max(uv_on) < 7.4 and min(uv_off) > 5.8,
        "efuse_current_headroom": min(current) - load_with_radio > .025 and max(current) < 1.7,
        "module_dc_rail": min(v3) > reset_high + .025 and max(v3) < 3.6,
        "module_step_charge_budget": step_floor > 3.0,
        "led_driver_disable_logic_high": disable_high > 2.0,
        "buck_and_inductor_peaks": rail_load + max(ripple) / 2 < 1.25,
        "driver_thermal_and_pod_headroom": 65 + 39.6 * (switch_loss + 16 * .0021) < 95 and led_voltage >= 9,
        "transient_voltage_headroom_at_tvs_rated_pulse": 45.4 < min(60, 65, 50),
        "adc_limits": all(c["adc_min_v_at_switch_minus_0_5_v"] > -.3
                          and .9 < c["adc_v_at_14_4_v"][0] <= c["adc_v_at_14_4_v"][1] < 1.1
                          and .068 < c["shunt_current_at_100v_ma"][0] < c["shunt_current_at_100v_ma"][1] < 15
                          for c in sense.values()),
    }
    if not all(checks.values()):
        raise ValueError(f"Rev G electrical screen failed: {checks}")
    return {
        "contract": CONTRACT, "method": "Static tolerance bounds and first-order load, ripple and thermal equations",
        "checks": checks, "corner_count": sum(map(len, (uv_on, uv_off, ov_on, ov_off, current, v3, ripple))) + 64,
        "efuse_uvlo_rising_v": [min(uv_on), max(uv_on)], "efuse_uvlo_falling_v": [min(uv_off), max(uv_off)],
        "efuse_ovp_rising_v": [min(ov_on), max(ov_on)], "efuse_ovp_falling_v": [min(ov_off), max(ov_off)],
        "efuse_current_limit_a": [min(current), max(current)],
        "three_volt_nominal_v": .8 * (1 + r(definitions, "R4") / r(definitions, "R5")),
        "three_volt_static_v": [min(v3), max(v3)], "capacitor_step_floor_v": step_floor,
        "max_reset_release_v": reset_high, "driver_disable_logic_high_min_v": disable_high,
        "buck_inductor_peak_a": rail_load + max(ripple) / 2,
        "pod_screen": {"channel_a": led_max_channel, "combined_a": led_total, "total_with_radio_a": load_with_radio,
                       "min_j1_input_v": min_input, "wire_and_copper_drop_allowance_v": wire_and_copper_drop,
                       "at_pod_v": led_voltage, "driver_switch_loss_w": switch_loss},
        "illumination_sense": sense,
        "assumptions_to_bench_verify": ["RTN drop and eFuse timing", "buck loop and load step",
                                         "driver thermal resistance and switch resistance at low VM",
                                         "hot cable shorts and TVS pulse energy", "RF with cover and harness"],
        "vehicle_or_bench_tested": False,
    }
