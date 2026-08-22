from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

from .contracts import ContractCatalog
from .ids import deterministic_id


@dataclass(frozen=True)
class ACSignalSet:
    high_pressure_absolute: str
    low_pressure_absolute: str
    cabin_return_temperature: str
    center_vent_temperature: str


SIMULATOR_AC_SIGNALS = ACSignalSet(
    high_pressure_absolute="sim.ac.pressure.high.absolute",
    low_pressure_absolute="sim.ac.pressure.low.absolute",
    cabin_return_temperature="sim.ac.temperature.cabin-return",
    center_vent_temperature="sim.ac.temperature.center-vent",
)


@dataclass(frozen=True)
class ACMetricsResult:
    runs: tuple[dict[str, Any], ...]
    unavailable: dict[str, str]


BLOCKED_METRICS = {
    "ac.r134a.saturation": (
        "Unavailable until a validated, versioned R134a property table/interpolator is installed."
    ),
    "ac.superheat": (
        "Unavailable until validated R134a saturation data and a calibrated low-line temperature input exist."
    ),
    "ac.subcooling": (
        "Unavailable until validated R134a saturation data and a calibrated high-line temperature input exist."
    ),
    "ac.condenser.approach": (
        "Unavailable until validated R134a saturation data and ambient temperature evidence exist."
    ),
    "ac.stabilization.time": (
        "Unavailable until versioned slope/window criteria are validated."
    ),
    "ac.baseline.delta": (
        "Unavailable until matched-condition vehicle baseline captures exist."
    ),
    "ac.diagnostic.hypotheses": (
        "Unavailable from this slice: pressure-only or simulator evidence cannot declare charge or component faults."
    ),
}


def calculate_ac_metrics(
    samples: Iterable[dict[str, Any]],
    *,
    signals: ACSignalSet,
    confidence: float,
    confidence_factors: dict[str, float],
    quality_notes: list[str],
    catalog: ContractCatalog | None = None,
) -> ACMetricsResult:
    """Calculate only equations that require no unfrozen tables or thresholds.

    Each result uses inputs decoded from the same raw observation so a metric
    cannot silently mix operating states. The caller supplies confidence and
    its factors; this module does not invent a confidence model.
    """
    if not 0 <= confidence <= 1:
        raise ValueError("confidence must be between 0 and 1")
    if not confidence_factors:
        raise ValueError("confidence_factors must not be empty")

    groups = _group_by_observation(samples)
    runs: list[dict[str, Any]] = []
    unavailable = dict(BLOCKED_METRICS)

    pressure_group = _latest_complete_group(
        groups,
        (signals.high_pressure_absolute, signals.low_pressure_absolute),
    )
    if pressure_group is None:
        unavailable["ac.pressure.delta"] = (
            "No matched observation contains both high- and low-side absolute pressure."
        )
        unavailable["ac.pressure.ratio"] = (
            "No matched observation contains both high- and low-side absolute pressure."
        )
    else:
        high = pressure_group[signals.high_pressure_absolute]
        low = pressure_group[signals.low_pressure_absolute]
        _require_units(high, low, expected="kPa")
        runs.append(
            _calculation_run(
                metric_id="ac.pressure.delta",
                equation_id="ac.pressure.delta",
                equation_version="1.0.0",
                inputs=(
                    ("high_pressure_absolute", high),
                    ("low_pressure_absolute", low),
                ),
                value=high["value"] - low["value"],
                unit="kPa",
                confidence=confidence,
                confidence_factors=confidence_factors,
                quality_notes=quality_notes
                + [
                    "Pressure lift is identical for absolute and gauge pressure because atmospheric pressure cancels in the subtraction."
                ],
            )
        )
        if low["value"] <= 0:
            unavailable["ac.pressure.ratio"] = (
                "Low-side absolute pressure must be greater than zero."
            )
        else:
            runs.append(
                _calculation_run(
                    metric_id="ac.pressure.ratio",
                    equation_id="ac.pressure.ratio",
                    equation_version="1.0.0",
                    inputs=(
                        ("high_pressure_absolute", high),
                        ("low_pressure_absolute", low),
                    ),
                    value=high["value"] / low["value"],
                    unit="1",
                    confidence=confidence,
                    confidence_factors=confidence_factors,
                    quality_notes=quality_notes,
                )
            )

    vent_group = _latest_complete_group(
        groups,
        (signals.cabin_return_temperature, signals.center_vent_temperature),
    )
    if vent_group is None:
        unavailable["ac.vent.delta"] = (
            "No matched observation contains cabin-return and center-vent temperature."
        )
    else:
        cabin = vent_group[signals.cabin_return_temperature]
        vent = vent_group[signals.center_vent_temperature]
        _require_units(cabin, vent, expected="Cel")
        runs.append(
            _calculation_run(
                metric_id="ac.vent.delta",
                equation_id="ac.vent.delta",
                equation_version="1.0.0",
                inputs=(
                    ("cabin_return_temperature", cabin),
                    ("center_vent_temperature", vent),
                ),
                value=cabin["value"] - vent["value"],
                unit="Cel",
                confidence=confidence,
                confidence_factors=confidence_factors,
                quality_notes=quality_notes,
            )
        )

    validator = catalog or ContractCatalog.load()
    for run in runs:
        validator.validate(run)
    return ACMetricsResult(tuple(runs), unavailable)


def _group_by_observation(
    samples: Iterable[dict[str, Any]],
) -> dict[str, dict[str, dict[str, Any]]]:
    groups: dict[str, dict[str, dict[str, Any]]] = {}
    for sample in samples:
        if sample.get("contract") != "signal.sample":
            raise ValueError("A/C calculations accept only signal.sample documents")
        groups.setdefault(sample["observation_id"], {})[sample["signal_id"]] = sample
    return groups


def _latest_complete_group(
    groups: dict[str, dict[str, dict[str, Any]]],
    required_signal_ids: tuple[str, ...],
) -> dict[str, dict[str, Any]] | None:
    candidates = [
        group
        for group in groups.values()
        if all(signal_id in group for signal_id in required_signal_ids)
    ]
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda group: max(
            group[signal_id]["observed_at_monotonic_us"]
            for signal_id in required_signal_ids
        ),
    )


def _require_units(*samples: dict[str, Any], expected: str) -> None:
    units = {sample["unit"] for sample in samples}
    if units != {expected}:
        raise ValueError(f"Expected {expected} inputs, received {sorted(units)}")


def _calculation_run(
    *,
    metric_id: str,
    equation_id: str,
    equation_version: str,
    inputs: tuple[tuple[str, dict[str, Any]], ...],
    value: float,
    unit: str,
    confidence: float,
    confidence_factors: dict[str, float],
    quality_notes: list[str],
) -> dict[str, Any]:
    vehicle_ids = {sample["vehicle_id"] for _, sample in inputs}
    wall_times = {sample["wall_time"] for _, sample in inputs}
    observation_ids = {sample["observation_id"] for _, sample in inputs}
    if len(vehicle_ids) != 1 or len(wall_times) != 1 or len(observation_ids) != 1:
        raise ValueError("Calculation inputs must share vehicle, wall time, and observation")
    executed_at = next(iter(wall_times))
    timestamp_ms = _timestamp_ms_from_domain_id(inputs[0][1]["sample_id"])
    calculation_id = deterministic_id(
        "calc",
        f"{equation_id}@{equation_version}:{','.join(sample['sample_id'] for _, sample in inputs)}",
        timestamp_ms=timestamp_ms,
    )
    return {
        "contract": "calculation.run",
        "contract_version": "1.0.0",
        "calculation_id": calculation_id,
        "vehicle_id": next(iter(vehicle_ids)),
        "metric_id": metric_id,
        "equation": {
            "equation_id": equation_id,
            "version": equation_version,
        },
        "versions": {
            "vehicle_config_pack": "0.0.0-simulator",
            "signal_pack": "0.0.0-simulator",
            "equation_contract": "1.0.0",
            "runtime": "0.1.0",
        },
        "inputs": [
            {
                "name": name,
                "value": sample["value"],
                "unit": sample["unit"],
                "evidence_ref": sample["sample_id"],
                "quality": sample["quality"],
            }
            for name, sample in inputs
        ],
        "intermediates": [],
        "output": {
            "value": value,
            "unit": unit,
            "truth_boundary": "ESTIMATED",
        },
        "confidence": confidence,
        "confidence_factors": confidence_factors,
        "quality_notes": quality_notes,
        "executed_at": executed_at,
    }


def _timestamp_ms_from_domain_id(domain_id: str) -> int:
    body = domain_id.split("_", 1)[1]
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    value = 0
    for character in body:
        value = (value << 5) | alphabet.index(character)
    return value >> 80
