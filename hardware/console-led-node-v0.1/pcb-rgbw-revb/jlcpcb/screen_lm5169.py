"""Reproduce the first-order LM5169-Q1 current, startup and ripple estimates."""

from itertools import product
import json


def screen():
    # TI SNVSBZ3A electrical characteristics and equations 2, 18 and 21.
    # The broader frequency and effective L/C bands are sensitivity inputs.
    divider = (1 + 154_000 * .99 / (49_900 * 1.01), 1 + 154_000 * 1.01 / (49_900 * .99))
    enable = (1 + 1_000_000 * .99 / (180_000 * 1.01), 1 + 1_000_000 * 1.01 / (180_000 * .99))
    nominal_switching_hz = 2500 * 5 / 49.9 * 1000
    frequencies = (.8 * nominal_switching_hz, 1.2 * nominal_switching_hz)
    peak, feedback_ripple = [], []
    for vin, vout, frequency, inductance, resistance, capacitance in product(
        (8.7, 17.0), (4.75, 5.25), frequencies,
        (48.96e-6, 81.6e-6), (68_000 * .99, 68_000 * 1.01), (2.64e-9, 3.96e-9),
    ):
        buck_factor = vout * (1 - vout / vin) / frequency
        peak.append(.5 + buck_factor / (2 * inductance))
        feedback_ripple.append(buck_factor / (resistance * capacitance))
    nominal_ripple = 5 * (1 - 5 / 13.8) / (nominal_switching_hz * 68_000 * 3.3e-9)
    return {
        "nominal_frequency_khz": round(nominal_switching_hz / 1000, 2),
        "nominal_enable_on_v": round(1.5 * (1 + 1_000_000 / 180_000), 2),
        "nominal_enable_off_v": round(1.4 * (1 + 1_000_000 / 180_000), 2),
        "estimated_enable_on_v": [round(1.45 * enable[0], 2), round(1.55 * enable[1], 2)],
        "estimated_enable_off_v": [round(1.35 * enable[0], 2), round(1.44 * enable[1], 2)],
        "voltage_setpoint_before_ripple_v": [round(1.181 * divider[0], 3), round(1.218 * divider[1], 3)],
        "nominal_injected_ripple_at_13_8_v_mv_pp": round(1000 * nominal_ripple, 1),
        "min_injected_ripple_mv_pp": round(1000 * min(feedback_ripple), 1),
        "max_ideal_inductor_peak_at_0_5_a_a": round(max(peak), 4),
        "min_datasheet_peak_limit_a": .71,
        "estimated_peak_margin_ma": round(1000 * (.71 - max(peak)), 1),
        "bench_verified": False,
    }


if __name__ == "__main__":
    print(json.dumps(screen(), indent=2))
