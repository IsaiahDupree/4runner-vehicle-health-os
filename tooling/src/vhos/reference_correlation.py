from __future__ import annotations

import bisect
import csv
import hashlib
import math
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .can_discovery import PassiveCANRecord, load_passive_can_ndjson
from .contracts import ContractCatalog


CORRELATION_CONTRACT = "can.reference-correlation-report"
CONTRACT_VERSION = "1.0.0"
DEFAULT_TARGET_IDENTIFIERS = (0x2C4, 0x025, 0x2C1)
DEFAULT_PAIRING_WINDOW_US = 250_000
MINIMUM_PAIRS = 5


class ReferenceCorrelationError(ValueError):
    """Raised when synchronized reference evidence is incomplete or invalid."""


@dataclass(frozen=True)
class ReferenceSample:
    gateway_monotonic_microseconds: int
    signal_id: str
    value: float
    unit: str
    source: str


def load_reference_csv(paths: Iterable[Path]) -> tuple[list[ReferenceSample], list[dict[str, Any]]]:
    samples: list[ReferenceSample] = []
    sources: list[dict[str, Any]] = []
    required = {
        "gateway_monotonic_microseconds",
        "signal_id",
        "value",
        "unit",
        "source",
    }
    for candidate in paths:
        path = candidate.resolve()
        if not path.is_file():
            raise ReferenceCorrelationError(f"Reference CSV does not exist: {candidate}")
        raw = path.read_bytes()
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames is None or not required.issubset(reader.fieldnames):
                raise ReferenceCorrelationError(
                    f"{path.name}: reference CSV requires columns {sorted(required)}."
                )
            for line_number, row in enumerate(reader, start=2):
                try:
                    monotonic = int(row["gateway_monotonic_microseconds"])
                    value = float(row["value"])
                except (TypeError, ValueError) as error:
                    raise ReferenceCorrelationError(
                        f"{path.name}:{line_number}: invalid timestamp or numeric value."
                    ) from error
                signal_id = (row["signal_id"] or "").strip()
                unit = (row["unit"] or "").strip()
                source = (row["source"] or "").strip()
                if monotonic < 0 or not math.isfinite(value):
                    raise ReferenceCorrelationError(
                        f"{path.name}:{line_number}: reference sample is out of range."
                    )
                if not signal_id or not unit or not source:
                    raise ReferenceCorrelationError(
                        f"{path.name}:{line_number}: reference identity, unit, and source are required."
                    )
                samples.append(ReferenceSample(monotonic, signal_id, value, unit, source))
        sources.append(
            {
                "role": "REFERENCE",
                "name": path.name,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "byte_count": len(raw),
            }
        )
    if not samples:
        raise ReferenceCorrelationError("No reference samples were found.")
    units: dict[str, set[str]] = {}
    for sample in samples:
        units.setdefault(sample.signal_id, set()).add(sample.unit)
    conflicts = {key: value for key, value in units.items() if len(value) != 1}
    if conflicts:
        raise ReferenceCorrelationError(f"Reference signal units are inconsistent: {conflicts}")
    return samples, sources


def correlate_can_with_reference(
    can_paths: Iterable[Path],
    reference_paths: Iterable[Path],
    *,
    identifiers: Iterable[int] = DEFAULT_TARGET_IDENTIFIERS,
    maximum_pairing_delta_us: int = DEFAULT_PAIRING_WINDOW_US,
) -> dict[str, Any]:
    if not 1 <= maximum_pairing_delta_us <= 1_000_000:
        raise ReferenceCorrelationError("Pairing window must be between 1 and 1,000,000 us.")
    records, can_sources = load_passive_can_ndjson(can_paths)
    reference_samples, reference_sources = load_reference_csv(reference_paths)
    target_identifiers = set(identifiers)
    if not target_identifiers or any(not 0 <= value <= 0x7FF for value in target_identifiers):
        raise ReferenceCorrelationError("Target identifiers must be non-empty 11-bit CAN IDs.")

    by_identifier: dict[int, list[PassiveCANRecord]] = {}
    for identifier in sorted(target_identifiers):
        values = sorted(
            (item for item in records if not item.extended and item.identifier == identifier),
            key=lambda item: item.monotonic_microseconds,
        )
        if values:
            by_identifier[identifier] = values

    ranked: list[dict[str, Any]] = []
    for signal_id in sorted({item.signal_id for item in reference_samples}):
        references = sorted(
            (item for item in reference_samples if item.signal_id == signal_id),
            key=lambda item: item.gateway_monotonic_microseconds,
        )
        for identifier, can_records in by_identifier.items():
            paired = _nearest_pairs(can_records, references, maximum_pairing_delta_us)
            if len(paired) < MINIMUM_PAIRS:
                continue
            fields = sorted({name for record, _ in paired for name in _raw_fields(record)})
            for field in fields:
                raw_values: list[float] = []
                reference_values: list[float] = []
                deltas: list[int] = []
                for record, reference in paired:
                    values = _raw_fields(record)
                    if field not in values:
                        continue
                    raw_values.append(float(values[field]))
                    reference_values.append(reference.value)
                    deltas.append(
                        abs(
                            record.monotonic_microseconds
                            - reference.gateway_monotonic_microseconds
                        )
                    )
                if len(raw_values) < MINIMUM_PAIRS:
                    continue
                correlation = _pearson(raw_values, reference_values)
                if correlation is None:
                    continue
                scale, offset, rmse = _linear_fit(raw_values, reference_values)
                ranked.append(
                    {
                        "reference_signal": signal_id,
                        "reference_unit": references[0].unit,
                        "identifier": f"0x{identifier:03X}",
                        "field": field,
                        "paired_samples": len(raw_values),
                        "maximum_pairing_delta_us": max(deltas),
                        "pearson_correlation": round(correlation, 6),
                        "linear_scale": round(scale, 9),
                        "linear_offset": round(offset, 6),
                        "rmse": round(rmse, 6),
                        "status": "VALIDATION_CANDIDATE",
                    }
                )
    ranked.sort(
        key=lambda item: (
            item["reference_signal"],
            -abs(item["pearson_correlation"]),
            item["rmse"],
            item["identifier"],
            item["field"],
        )
    )
    trimmed: list[dict[str, Any]] = []
    per_signal: dict[str, int] = {}
    for item in ranked:
        count = per_signal.get(item["reference_signal"], 0)
        if count >= 20:
            continue
        per_signal[item["reference_signal"]] = count + 1
        trimmed.append(item)

    report = {
        "contract": CORRELATION_CONTRACT,
        "contract_version": CONTRACT_VERSION,
        "status": "VALIDATION_CANDIDATE",
        "authority": (
            "Time-aligned statistical candidates only. A high correlation does not establish "
            "Toyota signal semantics, scale, unit, applicability, or causal vehicle health meaning."
        ),
        "source_files": [
            *(
                {
                    "role": "PASSIVE_CAN",
                    "name": item["name"],
                    "sha256": item["sha256"],
                    "byte_count": item["byte_count"],
                }
                for item in can_sources
            ),
            *reference_sources,
        ],
        "reference_signals": sorted({item.signal_id for item in reference_samples}),
        "ranked_candidates": trimmed,
        "promotion_allowed": False,
    }
    ContractCatalog.load().validate(report)
    return report


def _nearest_pairs(
    records: list[PassiveCANRecord],
    references: list[ReferenceSample],
    maximum_delta: int,
) -> list[tuple[PassiveCANRecord, ReferenceSample]]:
    times = [item.monotonic_microseconds for item in records]
    result: list[tuple[PassiveCANRecord, ReferenceSample]] = []
    for reference in references:
        index = bisect.bisect_left(times, reference.gateway_monotonic_microseconds)
        candidates = records[max(0, index - 1) : min(len(records), index + 1)]
        if not candidates:
            continue
        closest = min(
            candidates,
            key=lambda item: abs(
                item.monotonic_microseconds - reference.gateway_monotonic_microseconds
            ),
        )
        if (
            abs(closest.monotonic_microseconds - reference.gateway_monotonic_microseconds)
            <= maximum_delta
        ):
            result.append((closest, reference))
    return result


def _raw_fields(record: PassiveCANRecord) -> dict[str, int]:
    payload = record.payload
    values = {f"byte{index}": value for index, value in enumerate(payload)}
    for index in range(max(0, len(payload) - 1)):
        pair = payload[index : index + 2]
        values[f"be16_{index}"] = int.from_bytes(pair, "big")
        values[f"le16_{index}"] = int.from_bytes(pair, "little")
    return values


def _pearson(left: list[float], right: list[float]) -> float | None:
    if len(left) != len(right) or len(left) < MINIMUM_PAIRS:
        return None
    left_mean = statistics.fmean(left)
    right_mean = statistics.fmean(right)
    numerator = sum(
        (left_item - left_mean) * (right_item - right_mean)
        for left_item, right_item in zip(left, right, strict=True)
    )
    left_energy = sum((item - left_mean) ** 2 for item in left)
    right_energy = sum((item - right_mean) ** 2 for item in right)
    denominator = math.sqrt(left_energy * right_energy)
    return numerator / denominator if denominator > 0 else None


def _linear_fit(raw: list[float], reference: list[float]) -> tuple[float, float, float]:
    raw_mean = statistics.fmean(raw)
    reference_mean = statistics.fmean(reference)
    denominator = sum((item - raw_mean) ** 2 for item in raw)
    if denominator <= 0:
        raise ReferenceCorrelationError("Cannot fit a constant CAN field.")
    scale = sum(
        (raw_item - raw_mean) * (reference_item - reference_mean)
        for raw_item, reference_item in zip(raw, reference, strict=True)
    ) / denominator
    offset = reference_mean - scale * raw_mean
    residuals = [
        reference_item - (scale * raw_item + offset)
        for raw_item, reference_item in zip(raw, reference, strict=True)
    ]
    rmse = math.sqrt(statistics.fmean(item * item for item in residuals))
    return scale, offset, rmse
