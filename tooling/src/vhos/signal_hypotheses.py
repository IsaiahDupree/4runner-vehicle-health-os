from __future__ import annotations

import hashlib
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from .can_discovery import PassiveCANRecord, _pearson, load_passive_can_ndjson
from .contracts import ContractCatalog


PACK_CONTRACT = "can.signal-hypothesis-pack"
PACK_VERSION = "1.0.0"
EVALUATION_CONTRACT = "can.signal-hypothesis-evaluation"
EVALUATION_VERSION = "1.0.0"


class SignalHypothesisError(ValueError):
    """Raised when a research-only CAN hypothesis pack cannot be evaluated safely."""


def default_hypothesis_pack_path() -> Path:
    return (
        Path(__file__).resolve().parents[3]
        / "vehicle-signal-packs"
        / "toyota-4runner-2005-passive-can-hypotheses.v1.json"
    )


def load_hypothesis_pack(path: Path | None = None) -> tuple[dict[str, Any], bytes]:
    pack_path = (path or default_hypothesis_pack_path()).resolve()
    try:
        raw = pack_path.read_bytes()
        document = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise SignalHypothesisError(
            f"Unable to read CAN signal hypothesis pack {pack_path}: {error}"
        ) from error
    if not isinstance(document, dict):
        raise SignalHypothesisError("CAN signal hypothesis pack must be a JSON object.")
    ContractCatalog.load().validate(document)
    _validate_pack_references(document)
    return document, raw


def evaluate_can_hypotheses(
    paths: Iterable[Path],
    *,
    pack_path: Path | None = None,
) -> dict[str, Any]:
    pack, pack_raw = load_hypothesis_pack(pack_path)
    records, sources = load_passive_can_ndjson(paths)
    ordered = sorted(
        records,
        key=lambda item: (
            item.gateway_id,
            item.session_id,
            item.monotonic_microseconds,
            item.source_sequence,
        ),
    )
    by_identifier: dict[tuple[int, bool], list[PassiveCANRecord]] = defaultdict(list)
    for record in ordered:
        by_identifier[(record.identifier, record.extended)].append(record)

    hypothesis_by_id = {
        hypothesis["hypothesis_id"]: hypothesis for hypothesis in pack["hypotheses"]
    }
    extracted: dict[str, list[tuple[PassiveCANRecord, float]]] = {}
    evaluations: list[dict[str, Any]] = []
    for hypothesis in pack["hypotheses"]:
        matching = by_identifier.get(
            (hypothesis["identifier"], hypothesis["extended"]), []
        )
        field = hypothesis["field"]
        values: list[tuple[PassiveCANRecord, float]] = []
        if field is not None:
            for record in matching:
                value = _extract_field(record, field)
                if value is not None:
                    values.append((record, float(value)))
        extracted[hypothesis["hypothesis_id"]] = values

        if not matching:
            evidence_status = "ABSENT"
        elif field is None:
            evidence_status = "ID_PRESENT"
        elif len({item[1] for item in values}) <= 1:
            evidence_status = "FIELD_PRESENT_STATIC"
        else:
            evidence_status = "FIELD_PRESENT_DYNAMIC"

        transform_evaluations = []
        for transform in hypothesis["candidate_transforms"]:
            transformed = [
                value * transform["scale"] + transform["offset"] for _, value in values
            ]
            if transformed:
                transform_evaluations.append(
                    {
                        "transform_id": transform["transform_id"],
                        "unit": transform["unit"],
                        "summary": _summary(transformed),
                        "source_ids": transform["source_ids"],
                    }
                )

        evaluations.append(
            {
                "hypothesis_id": hypothesis["hypothesis_id"],
                "identifier": hypothesis["identifier"],
                "identifier_hex": hypothesis["identifier_hex"],
                "candidate_semantic": hypothesis["candidate_semantic"],
                "hypothesis_status": hypothesis["status"],
                "target_evidence_status": evidence_status,
                "records": len(matching),
                "sessions": len({(item.gateway_id, item.session_id) for item in matching}),
                "field_values": _summary([item[1] for item in values]) if values else None,
                "transform_evaluations": transform_evaluations,
                "production_value_display_allowed": False,
                "limitations": hypothesis["limitations"],
            }
        )

    relationships = [
        _evaluate_relationship(item, hypothesis_by_id, extracted)
        for item in pack["relationships"]
    ]
    report = {
        "contract": EVALUATION_CONTRACT,
        "contract_version": EVALUATION_VERSION,
        "status": "DISCOVERY_ONLY",
        "promotion_allowed": False,
        "accepted_signal_definitions": 0,
        "pack": {
            "pack_id": pack["pack_id"],
            "pack_version": pack["pack_version"],
            "sha256": hashlib.sha256(pack_raw).hexdigest(),
        },
        "source_files": sources,
        "capture_summary": {
            "records": len(ordered),
            "sessions": len({(item.gateway_id, item.session_id) for item in ordered}),
            "gateways": len({item.gateway_id for item in ordered}),
            "unique_identifiers": len({(item.identifier, item.extended) for item in ordered}),
            "listen_only_records": sum(item.listen_only for item in ordered),
        },
        "hypothesis_evaluations": evaluations,
        "relationship_evaluations": relationships,
        "display_policy": {
            "required_badge": "UNVERIFIED CROSS-MODEL HYPOTHESIS",
            "allowed_surface": "ENGINEERING_RESEARCH",
            "blocked_surfaces": [
                "OWNER_HEALTH",
                "MAINTENANCE_DECISION",
                "FINDING",
                "RECOMMENDATION",
                "AUTOMATIC_BASELINE",
            ],
            "statement": (
                "Candidate transforms expose what published cross-model mappings would produce "
                "on the retained target bytes. Plausible values, correlations, and source "
                "agreement do not establish exact 2005 4Runner semantics or permit promotion."
            ),
        },
    }
    ContractCatalog.load().validate(report)
    return report


def _validate_pack_references(pack: dict[str, Any]) -> None:
    source_ids = {item["source_id"] for item in pack["sources"]}
    if len(source_ids) != len(pack["sources"]):
        raise SignalHypothesisError("Hypothesis pack contains duplicate source IDs.")
    hypothesis_ids = {item["hypothesis_id"] for item in pack["hypotheses"]}
    if len(hypothesis_ids) != len(pack["hypotheses"]):
        raise SignalHypothesisError("Hypothesis pack contains duplicate hypothesis IDs.")
    transform_ids: dict[str, set[str]] = {}
    for hypothesis in pack["hypotheses"]:
        unknown_sources = set(hypothesis["source_ids"]) - source_ids
        if unknown_sources:
            raise SignalHypothesisError(
                f"{hypothesis['hypothesis_id']} references unknown sources: "
                f"{sorted(unknown_sources)}"
            )
        ids = {item["transform_id"] for item in hypothesis["candidate_transforms"]}
        if len(ids) != len(hypothesis["candidate_transforms"]):
            raise SignalHypothesisError(
                f"{hypothesis['hypothesis_id']} contains duplicate transform IDs."
            )
        for transform in hypothesis["candidate_transforms"]:
            unknown_transform_sources = set(transform["source_ids"]) - source_ids
            if unknown_transform_sources:
                raise SignalHypothesisError(
                    f"{transform['transform_id']} references unknown sources: "
                    f"{sorted(unknown_transform_sources)}"
                )
        transform_ids[hypothesis["hypothesis_id"]] = ids
    for relationship in pack["relationships"]:
        left = relationship["left_hypothesis_id"]
        right = relationship["right_hypothesis_id"]
        if left not in hypothesis_ids or right not in hypothesis_ids:
            raise SignalHypothesisError(
                f"{relationship['relationship_id']} references an unknown hypothesis."
            )
        if relationship["left_transform_id"] not in transform_ids[left]:
            raise SignalHypothesisError(
                f"{relationship['relationship_id']} references an unknown left transform."
            )
        if relationship["right_transform_id"] not in transform_ids[right]:
            raise SignalHypothesisError(
                f"{relationship['relationship_id']} references an unknown right transform."
            )


def _extract_field(record: PassiveCANRecord, field: dict[str, Any]) -> int | None:
    start = field["byte_offset"]
    end = start + field["byte_length"]
    if end > record.data_length:
        return None
    byte_order = "big" if field["endianness"] == "BIG" else "little"
    value = int.from_bytes(bytes(record.data[start:end]), byteorder=byte_order, signed=False)
    value = (value & field["mask"]) >> field["right_shift"]
    signed_bits = field["signed_bits"]
    if signed_bits is not None:
        sign = 1 << (signed_bits - 1)
        value &= (1 << signed_bits) - 1
        if value & sign:
            value -= 1 << signed_bits
    return value


def _evaluate_relationship(
    relationship: dict[str, Any],
    hypothesis_by_id: dict[str, dict[str, Any]],
    extracted: dict[str, list[tuple[PassiveCANRecord, float]]],
) -> dict[str, Any]:
    left_hypothesis = hypothesis_by_id[relationship["left_hypothesis_id"]]
    right_hypothesis = hypothesis_by_id[relationship["right_hypothesis_id"]]
    left_transform = _transform_by_id(left_hypothesis, relationship["left_transform_id"])
    right_transform = _transform_by_id(right_hypothesis, relationship["right_transform_id"])
    left_by_session = _values_by_session(
        extracted[left_hypothesis["hypothesis_id"]], left_transform
    )
    right_by_session = _values_by_session(
        extracted[right_hypothesis["hypothesis_id"]], right_transform
    )
    paired: list[tuple[float, float, int]] = []
    for session in sorted(set(left_by_session) & set(right_by_session)):
        paired.extend(
            _nearest_pairs_with_window(
                left_by_session[session],
                right_by_session[session],
                relationship["maximum_pairing_delta_us"],
            )
        )
    left_values = [item[0] for item in paired]
    right_values = [item[1] for item in paired]
    differences = [abs(left - right) for left, right, _ in paired]
    ratios = [right / left for left, right, _ in paired if left != 0]
    correlation = _pearson(left_values, right_values) if len(paired) >= 2 else None
    return {
        "relationship_id": relationship["relationship_id"],
        "left_hypothesis_id": left_hypothesis["hypothesis_id"],
        "right_hypothesis_id": right_hypothesis["hypothesis_id"],
        "pairs": len(paired),
        "pearson_correlation": _round(correlation) if correlation is not None else None,
        "mean_absolute_difference": (
            _round(statistics.fmean(differences)) if differences else None
        ),
        "root_mean_square_difference": (
            _round(math.sqrt(statistics.fmean([item * item for item in differences])))
            if differences
            else None
        ),
        "median_right_to_left_ratio": (
            _round(statistics.median(ratios)) if ratios else None
        ),
        "maximum_pairing_delta_us": max((item[2] for item in paired), default=None),
        "status": "RAW_RELATIONSHIP_PRESENT" if paired else "NO_PAIRED_EVIDENCE",
        "interpretation": relationship["interpretation"],
        "production_value_display_allowed": False,
    }


def _transform_by_id(hypothesis: dict[str, Any], transform_id: str) -> dict[str, Any]:
    return next(
        item for item in hypothesis["candidate_transforms"] if item["transform_id"] == transform_id
    )


def _values_by_session(
    values: list[tuple[PassiveCANRecord, float]], transform: dict[str, Any]
) -> dict[tuple[str, int], list[tuple[int, float]]]:
    grouped: dict[tuple[str, int], list[tuple[int, float]]] = defaultdict(list)
    for record, raw in values:
        grouped[(record.gateway_id, record.session_id)].append(
            (
                record.monotonic_microseconds,
                raw * transform["scale"] + transform["offset"],
            )
        )
    return grouped


def _nearest_pairs_with_window(
    left: list[tuple[int, float]],
    right: list[tuple[int, float]],
    maximum_delta: int,
) -> list[tuple[float, float, int]]:
    left = sorted(left)
    right = sorted(right)
    pairs: list[tuple[float, float, int]] = []
    left_index = 0
    right_index = 0
    while left_index < len(left) and right_index < len(right):
        left_time, left_value = left[left_index]
        right_time, right_value = right[right_index]
        signed_delta = right_time - left_time
        if signed_delta < -maximum_delta:
            right_index += 1
            continue
        if signed_delta > maximum_delta:
            left_index += 1
            continue
        delta = abs(signed_delta)
        if left_index + 1 < len(left) and abs(right_time - left[left_index + 1][0]) < delta:
            left_index += 1
            continue
        if right_index + 1 < len(right) and abs(right[right_index + 1][0] - left_time) < delta:
            right_index += 1
            continue
        pairs.append((left_value, right_value, delta))
        left_index += 1
        right_index += 1
    return pairs


def _summary(values: list[float]) -> dict[str, Any]:
    return {
        "count": len(values),
        "minimum": _round(min(values)),
        "maximum": _round(max(values)),
        "mean": _round(statistics.fmean(values)),
        "standard_deviation": _round(statistics.pstdev(values)),
    }


def _round(value: float, *, digits: int = 6) -> float:
    return round(value, digits)
