"""Rev F stocked population, manufacturer land pattern and case revisions."""

import csv
from itertools import product
import json
from math import hypot
from pathlib import Path

import single_board as rev_e


NAME = "vhos_rgbw_revf"
TITLE = "4Runner RGBW controller with onboard ESP32-S3"
CONTRACT = "vhos_rgbw_revf_stocked_single_board_v1"
INDUCTOR = "TDK_SPM6545VT-D"
DIODE = "onsemi_SOD-323_477"
PACKAGE_ENVELOPES = {INDUCTOR: (7.4, 6.9, 4.5), DIODE: (2.70, 1.35, 1.00), "TI_DRR0012E": (3.1, 3.1, .8)}
LAND_PATTERNS = {
    INDUCTOR: {"centers_x_mm": (-2.95, 2.95), "size_xy_mm": (2.3, 3.3)},
    DIODE: {"centers_x_mm": (-1.115, 1.115), "size_xy_mm": (.63, .83)},
}
FOOTPRINTS = {ref: f"VHOS_RevB:{footprint}" for ref, footprint in
              (("L1", INDUCTOR), ("D7", DIODE), ("D8", DIODE))}
CASE_FLOOR_MM = 2.8
LID_RECESS_DEPTH_MM = .9
# x, y, width and depth from the installed front-left corner.
LID_RECESSES = ((35, 9, 50, 26), (91, 9, 47, 26), (35, 41, 50, 26), (91, 41, 47, 26))


def selection():
    with Path(__file__).with_name("stock_board_parts.csv").open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    by_ref = {row["ref"]: row for row in rows}
    if len(by_ref) != len(rows):
        raise ValueError("Duplicate Rev F assembly designator")
    return by_ref


def parts():
    selected = selection()
    definitions = rev_e.parts()
    if set(selected) != {p["ref"] for p in definitions if p["mpn"]} - {"F1", "F2"}:
        raise ValueError("Rev F stock selection must cover the entire SMT population")
    notes = {
        "L1": "TDK automotive inductor. Land pattern and maximum envelope from the TDK drawing.",
        "D1": "28 V standoff bidirectional input TVS after the 58 V fuse.",
        "R30": "ADC isolation sets attenuation and keeps GPIO above -0.3 V for a -0.5 V switch output.",
        "R31": "ADC isolation sets attenuation and keeps GPIO above -0.3 V for a -0.5 V switch output.",
    }
    for part in definitions:
        ref = part["ref"]
        if ref in selected:
            row = selected[ref]
            part["mpn"] = row["mpn"]
            part["value"] = row["value"] or part["value"]
            if part["note"].startswith("Yageo RC0603") and row["mpn"].startswith("0603WAF"):
                part["note"] = "Uniroyal 0603 thick film, 1%, 0.1 W."
            part["note"] = notes.get(ref, part["note"])
            if ref in FOOTPRINTS:
                part["footprint"] = FOOTPRINTS[ref]
    return definitions


def resistance(definitions, ref):
    value = definitions[ref]["value"].split()[0]
    return float(value[:-1]) * {"k": 1e3, "M": 1e6}[value[-1]]


def electrical_screen():
    """Datasheet and tolerance screen at the board's protected supply node."""
    definitions = {p["ref"]: p for p in parts()}
    ron, r4, r5, ra, r34, r35 = [resistance(definitions, ref) for ref in ("R1", "R4", "R5", "R6", "R34", "R35")]
    # 1% initial tolerance + 100 ppm/°C over the -40..65°C module range.
    # Take resistor TCR independently and use the full rated IC reference range.
    tolerance = .0165

    def extremes(value, error=tolerance):
        return value * (1 - error), value * (1 + error)

    rows = []
    # RON model allowance includes timing variance beyond resistor tolerance.
    # CA allowance includes initial and dielectric variation. Its DC sees only ripple.
    for vin, voc, top, bottom, timing, ripple_r, ripple_c, gain in product(
        (7.5, 8.75, 13.8, 16.1), (1.181, 1.218), extremes(r4), extremes(r5),
        extremes(ron), extremes(ra), (2.475e-9, 4.125e-9), (.8, 1.2),
    ):
        # TI equations 8 and 25 with half the injected peak-to-peak ramp added
        # through the feedback divider. Solve the linear ripple/load model.
        ratio = 1 + top / bottom
        ripple_factor = (timing / 2.5e9) / (gain * ripple_r * ripple_c)
        v5 = ratio * (voc + ripple_factor / 2) / (1 + ratio * ripple_factor / (2 * vin))
        fsw = gain * 2.5e9 * v5 / timing
        vpp = ripple_factor * (1 - v5 / vin)
        # Inductance at the low initial tolerance with another 10% bias allowance.
        current_pp = v5 * (1 - v5 / vin) / (68e-6 * .8 * .9 * fsw)
        rows.append((v5, fsw, vpp, .5 + current_pp / 2, hypot(.5, current_pp / (12 ** .5))))
    v5, hz, vpp, peak, rms = zip(*rows)
    nominal_frequency = 2.5e9 * (1.2 * (1 + r4 / r5)) / ron
    ramp_nominal = (1 - 5.1 / 13.8) * ron / (2.5e9 * ra * 3.3e-9)
    coupling_us = 1e6 * 3 * r4 * (1 - tolerance) * 180e-12 * .95
    frequency_min_hz = min(hz)
    rpar_min = extremes(r4)[0] * extremes(r5)[0] / (extremes(r4)[0] + extremes(r5)[0])
    ripple_c_min_f = 10 / (frequency_min_hz * rpar_min)
    v3 = [ref * (1 + top / bottom) for ref, top, bottom in
          product((.588, .612), extremes(r34, .001 + 65 * .000025), extremes(r35))]
    reset_release = 3.08 * 1.02 * 1.015
    uvlo = [threshold * (1 + r2 / r3) for threshold, r2, r3 in
            product((1.45, 1.55), extremes(resistance(definitions, "R2")), extremes(resistance(definitions, "R3")))]
    ov_range = [threshold * (1 + (top + switch) / bottom) + leak * (top + switch)
                for threshold, top, bottom, switch, leak in product(
                    (1.195, 1.267), extremes(resistance(definitions, "R21"), .002625),
                    extremes(resistance(definitions, "R22"), .002625), (10, 46), (0, 200e-9))]
    # Calculate both populated analog channels including independent
    # resistor tolerance and TCR. The ADC pin has a 100 nF capacitor.
    pos_limit = 2.5 + .038 + .001
    sense = {}
    for name, series, termination, isolate, pull in (
        ("TAIL", ("R24", "R25"), "R28", "R30", "R32"),
        ("DIM", ("R26", "R27"), "R29", "R31", "R33"),
    ):
        gains, corners, clamp, time_constants = [], [], [], []
        # Use up to 50 ppm/°C for the four precision sense resistors.
        precise = .001 + .00005 * 65
        for a, b, term, isolation, load in product(
            *(extremes(resistance(definitions, ref), precise) for ref in (*series, termination)),
            extremes(resistance(definitions, isolate)), extremes(resistance(definitions, pull), precise),
        ):
            r_series = a + b
            r_parallel = 1 / (1 / term + 1 / (isolation + load))
            adc_fraction = load / (isolation + load)
            gains.append(r_parallel / (r_series + r_parallel) * adc_fraction)
            # TI's switch pin limit is an input condition for this calculation.
            # The Schottky drop at cold temperature still requires measurement.
            corners.append(-.5 * adc_fraction)
            clamp.append((100 - pos_limit) / r_series - pos_limit / term - pos_limit / (isolation + load))
            r_adc = 1 / (1 / load + 1 / (isolation + 1 / (1 / term + 1 / r_series)))
            time_constants.append(r_adc * 100e-9 * 1000)
        sense[name] = {
            "adc_v_at_14_4_v": [14.4 * min(gains), 14.4 * max(gains)],
            "adc_gain": [min(gains), max(gains)],
            "adc_min_v_if_switch_is_minus_0_5_v": min(corners),
            "positive_clamp_min_current_at_100v_ma": 1000 * min(clamp),
            "positive_clamp_max_current_at_100v_ma": 1000 * max(clamp),
            "rc_time_ms_at_nominal_capacitance": [min(time_constants), max(time_constants)],
            "computed_resistor_corners": len(gains),
        }
    checks = {
        "logic_rail_within_gate_driver_and_buck_input_range": min(v5) >= 4.5 and max(v5) <= 5.5,
        "regulator_timing_and_ripple": 20e-3 <= ramp_nominal and 12e-3 <= min(vpp) and max(hz) < 1e6,
        "input_ov_cutoff_within_screened_rail_range": 14.8 < min(ov_range) and max(ov_range) < 16.1,
        "type_3_ripple_capacitor": ripple_c_min_f <= 2.475e-9 and coupling_us >= 75,
        "inductor_and_regulator_peak": max(peak) < min(1.25, 2.9) and max(rms) < 1.7,
        "esp_supply_static_margin": min(v3) - reset_release >= .06 and 3.6 - max(v3) >= .08,
        "adc_limit_with_switch_at_minus_0_5v": all(
            channel["adc_min_v_if_switch_is_minus_0_5_v"] > -.3 for channel in sense.values()),
        "adc_sense_gain_at_14_4v": all(
            .9 < channel["adc_v_at_14_4_v"][0] <= channel["adc_v_at_14_4_v"][1] < 1.1
            for channel in sense.values()),
        "positive_clamp_current_and_voltage_at_100v": pos_limit < 3.0 and all(
            .068 < channel["positive_clamp_min_current_at_100v_ma"]
            <= channel["positive_clamp_max_current_at_100v_ma"] < 15 for channel in sense.values()),
    }
    if not all(checks.values()):
        raise ValueError(f"Rev F electrical screen failed: {checks}")
    return {
        "contract": CONTRACT, "method": "Steady-state equations and component corner limits",
        "corner_count": (len(rows) + len(v3) + len(uvlo) + len(ov_range)
                         + sum(channel["computed_resistor_corners"] for channel in sense.values())),
        "protected_input_evaluated_v": [7.5, 16.1], "thermal_resistor_allowance_c": [-40, 65],
        "restarting_input_v": [min(uvlo), max(uvlo)], "cutoff_input_v": [min(ov_range), max(ov_range)],
        "five_volt_static_v": [min(v5), max(v5)],
        "switch_nominal_hz": nominal_frequency, "switch_corner_hz": [min(hz), max(hz)],
        "feedback_nominal_ripple_mv": 1000 * ramp_nominal,
        "feedback_corner_ripple_mv": [1000 * min(vpp), 1000 * max(vpp)],
        "coupling_settling_target_supported_us": coupling_us, "min_ripple_capacitance_f": ripple_c_min_f,
        "estimated_buck_amps_peak_at_500ma_load": max(peak), "estimated_inductor_amps_rms": max(rms),
        "inductor_copper_loss_w_at_100c": max(rms) ** 2 * .374 * (1 + .00393 * 75),
        "three_volt_nominal_v": .6 * (1 + r34 / r35), "three_volt_static_v": [min(v3), max(v3)],
        "max_reset_release_v": reset_release, "adc_channels": sense, "positive_clamp_high_v": pos_limit,
        "checks": checks,
        "physical_tests_pending": ["Buck startup, dropout, load steps and transient rail limits",
                                   "Inductor/driver thermals and LED current",
                                   "Cold negative pulses and hot ADC leakage",
                                   "RF link and vehicle fit"],
    }


if __name__ == "__main__":
    print(json.dumps(electrical_screen(), indent=2))
