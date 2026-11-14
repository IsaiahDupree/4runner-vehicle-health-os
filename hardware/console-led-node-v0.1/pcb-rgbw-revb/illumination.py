"""Rev D Toyota IR1 sense circuitry and the four-wire branch definition."""

from pathlib import Path
import json
import shutil

from design import REFERENCE, REV_C_NAME, component, design


NAME = "vhos_rgbw_revd"
TITLE = "4Runner RGBW shield with Toyota illumination inputs"
CONTRACT = "vhos_rgbw_revd_ir1_illumination_v1"
J1_NAME = "Toyota_IR1_4_Pads"
BRANCH = {
    "1": {"cavity": 5, "net": "GND", "label": "GND", "xy_mm": [61.0, 111.14],
          "awg": 20, "od_mm": 1.95, "bend_mm": 8.0, "gauge_mm": 1.2, "offset_yz_mm": [.68, -1.12],
          "rgb": [200, 206, 210]},
    "2": {"cavity": 6, "net": "VEH_ACC", "label": "ACC", "xy_mm": [66.5, 111.14],
          "awg": 20, "od_mm": 1.95, "bend_mm": 8.0, "gauge_mm": 1.2, "offset_yz_mm": [1.9, .83],
          "rgb": [209, 71, 131]},
    "3": {"cavity": 1, "net": "TAIL_12V", "label": "TAIL", "xy_mm": [62.5, 115.0],
          "awg": 22, "od_mm": 1.70, "bend_mm": 7.0, "gauge_mm": .85, "offset_yz_mm": [-1.48, -1.32],
          "rgb": [63, 175, 123]},
    "4": {"cavity": 2, "net": "DIM_RETURN", "label": "DIM", "xy_mm": [68.5, 115.0],
          "awg": 22, "od_mm": 1.70, "bend_mm": 7.0, "gauge_mm": .85, "offset_yz_mm": [-.48, 1.52],
          "rgb": [236, 213, 120]},
}
CASE_SLEEVE_OD = 7.2
BASE_RESISTOR = "Resistor_SMD:R_0603_1608Metric"
CAPACITOR = "Capacitor_SMD:C_0603_1608Metric"
SOT23 = "Package_TO_SOT_SMD:SOT-23"


def parts():
    headers = json.loads((REFERENCE / "engineering-inputs.json").read_text())["headers"]
    base = design(headers)
    existing = {p["ref"]: p for p in base}
    existing["J1"].update(value="TOYOTA IR1 IN", footprint=f"VHOS_RevB:{J1_NAME}", mpn=None,
                          nets={key: row["net"] for key, row in BRANCH.items()},
                          pin_names={key: f'IR1-{row["cavity"]}' for key, row in BRANCH.items()})
    existing["J2"].update(value="RGBW OUT", footprint="VHOS_RevB:RGBW_Output_5_Pads",
                          mpn=None, nets={k: v for k, v in existing["J2"]["nets"].items() if v})
    existing["H3"]["nets"]["4"] = "ESP_3V3"
    existing["H3"]["pin_names"]["4"] = "3V3"
    existing["H3"]["pin_types"]["4"] = "power_out"
    for pin, gpio, net in (("5", "GPIO5", "TAIL_ADC"), ("6", "GPIO4", "DIM_ADC")):
        existing["H4"]["nets"][pin] = net
        existing["H4"]["pin_names"][pin] = gpio
        existing["H4"]["pin_types"][pin] = "input"

    def add(ref, value, fp, nets, pcb_xy, mpn, **kw):
        return component(ref, value, fp, nets, (pcb_xy[0] - 100, 153.34 - pcb_xy[1]),
                         mpn, section="sense", **kw)

    sense = [
        add("U5", "SN3257-Q1", "Package_SO:TSSOP-16_4.4x5mm_P0.65mm",
            {1: "SENSE_READY", 2: "GND", 3: "TAIL_CLAMP", 4: "TAIL_SW",
             5: "GND", 6: "DIM_CLAMP", 7: "DIM_SW", 8: "GND",
             9: "GND", 10: "GND", 11: "GND", 12: "GND", 13: "GND",
             14: "GND", 15: "GND", 16: "ESP_3V3"}, (61.8, 133.1), "SN3257QPWRQ1",
            names=dict(zip(map(str, range(1, 17)), ("SEL", "S1A", "S1B", "D1", "S2A", "S2B", "D2",
                       "GND", "D3", "S3B", "S3A", "D4", "S4B", "S4A", "EN_N", "VDD"))),
            types={"1": "input", "8": "power_in", "15": "input", "16": "power_in"},
            note="A inputs at ground during 3.3 V startup. B inputs selected when the rail supervisor releases."),
        add("U8", "TLV809E 2.93V", SOT23, {1: "SENSE_READY", 2: "GND", 3: "ESP_3V3"},
            (70.1, 133.1), "TLV809ED29DBZR",
            names={"1": "RESET_N", "2": "GND", "3": "VDD"},
            types={"1": "output", "2": "power_in", "3": "power_in"},
            note="Keeps both ADC inputs at ground during supply transitions until 3.3 V is valid."),
    ]
    for prefix, raw, refs, sites in (
        ("TAIL", "TAIL_12V", (24, 25, 28, 30, 32, 6, 7, 19),
         ((60.1, 118.5), (55.4, 118.5), (53, 123.6), (153.8, 146.8),
          (156.5, 144.9), (58.2, 124.8), (53.7, 128.7), (157.0, 147.5))),
        ("DIM", "DIM_RETURN", (26, 27, 29, 31, 33, 7, 8, 20),
         ((67.9, 118.5), (65.0, 121.1), (61.2, 121.9), (161.0, 146.8),
          (164.0, 144.9), (66.4, 125.5), (64.5, 128.6), (164.0, 147.5))),
    ):
        r1, r2, r3, r4, r5, u, d, c = refs
        middle, clamp, switched, adc = (f"{prefix}_{suffix}" for suffix in ("SERIES", "CLAMP", "SW", "ADC"))
        for ref, nets, site in ((r1, (raw, middle), sites[0]), (r2, (middle, clamp), sites[1])):
            sense.append(add(f"R{ref}", "49.9k 0.1%", "Resistor_SMD:R_1206_3216Metric",
                             dict(enumerate(nets, 1)), site, "RT1206BRD0749K9L"))
        sense.extend([
            add(f"R{r3}", "22k 0.1%", BASE_RESISTOR, {1: clamp, 2: "GND"}, sites[2], "RT0603BRD0722KL"),
            add(f"R{r4}", "1k 0.1%", BASE_RESISTOR, {1: switched, 2: adc}, sites[3], "RT0603BRD071KL"),
            add(f"R{r5}", "22k 0.1%", BASE_RESISTOR, {1: adc, 2: "GND"}, sites[4], "RT0603BRD0722KL"),
            add(f"U{u}", "LM4040 2.5V", SOT23, {1: clamp, 2: "GND", 3: "GND"}, sites[5], "LM4040C25QDBZR",
                names={"1": "K", "2": "A", "3": "A/NC"}, note="Positive clamp to chassis reference."),
            add(f"D{d}", "BAT54H-Q", "Diode_SMD:D_SOD-123F", {1: clamp, 2: "GND"}, sites[6], "BAT54H-QX",
                names={"1": "K", "2": "A"}, note="Negative clamp. Check cold-pulse forward drop on the bench."),
            add(f"C{c}", "100n 50V", CAPACITOR, {1: adc, 2: "GND"}, sites[7], "GRM188R71H104KA93D"),
        ])
    for ref, site in (("C18", (66.6, 136.8)), ("C21", (71.5, 136.1))):
        sense.append(add(ref, "100n 50V", CAPACITOR, {1: "ESP_3V3", 2: "GND"}, site, "GRM188R71H104KA93D"))
    return base + sense


def stage_board(inputs, out):
    (out / (NAME + ".kicad_pcb")).write_bytes((inputs / (REV_C_NAME + ".kicad_pcb")).read_bytes())
    project = json.loads((inputs / (REV_C_NAME + ".kicad_pro")).read_text())
    project["meta"]["filename"] = NAME + ".kicad_pro"
    (out / project["meta"]["filename"]).write_text(json.dumps(project, indent=2) + "\n")
    for file in ("fp-lib-table", "models/MINI-3568.step"):
        (out / file).parent.mkdir(exist_ok=True)
        shutil.copyfile(inputs / file, out / file)
    shutil.copytree(inputs / "VHOS_RevB.pretty", out / "VHOS_RevB.pretty")


def electrical_screen():
    r_series, r_termination, r_isolation = 99_800, 22_000, 1_000
    r_parallel = 1 / (1 / r_termination + 1 / (r_isolation + r_termination))
    gain = r_parallel / (r_series + r_parallel) * r_termination / (r_termination + r_isolation)
    r_adc = 1 / (1 / r_termination + 1 / (r_isolation + 1 / (1 / r_termination + 1 / r_series)))
    step_tau = r_adc * 1e-7
    # The pulsed stress calculation bounds each series resistor with the
    # full source divided across both parts. It excludes parasitic overshoot.
    power_per_series_resistor = (100 / r_series) ** 2 * (r_series / 2)
    return {"nominal_gain": gain, "adc_at_14_4_v": 14.4 * gain, "adc_at_18_v": 18 * gain,
            "off_input_ua_at_14_4_v": 1e6 * 14.4 / (r_series + r_termination),
            "adc_time_constant_ms": step_tau * 1000,
            "off_leakage_adc_bound_v": 8e-6 * r_termination,
            "max_series_resistor_w_at_100_v_ideal": power_per_series_resistor,
            "nominal_positive_clamp_v": 2.5,
            "physical_transients_and_vehicle_signal_verified": False}
