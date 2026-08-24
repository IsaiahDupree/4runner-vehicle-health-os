from __future__ import annotations

import hashlib
import json
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .can_discovery import MAX_INPUT_BYTES, PassiveCANRecord, load_passive_can_ndjson
from .contracts import ContractCatalog


REPORT_CONTRACT = "can.marker-correlation-report"
REPORT_VERSION = "1.0.0"
LEDGER_CONTRACT = "vhos.ios.discovery-marker-ledger-record"
LEDGER_VERSION = "1.0.0"
# Event markers are bound to the latest accepted gateway observation.  A zero
# settle interval therefore preserves an exact marker/observation match.  The
# recorder currently retains a sparse rotating sample of identifiers, so the
# final state needs a bounded four-second window to see the next occurrence of
# a low-density identifier.  Intermediate windows are still clipped at the
# next marker and can never consume observations from the following state.
DEFAULT_SETTLE_MICROSECONDS = 0
DEFAULT_WINDOW_MICROSECONDS = 4_000_000
MAXIMUM_CANDIDATES = 100
FULL_DENSITY_OBSERVATIONS_PER_MARKER = 3


class MarkerCorrelationError(ValueError):
    """Raised when marker evidence cannot be correlated without losing lineage."""


class _DuplicateJSONKeyError(ValueError):
    pass


@dataclass(frozen=True)
class DiscoveryMarker:
    marker_id: str
    test_run_id: str
    template_id: str
    capture_id: str
    gateway_id: str
    session_id: int
    monotonic_microseconds: int
    nearest_can_sequence: int | None
    kind: str
    label: str


@dataclass(frozen=True)
class _Window:
    marker: DiscoveryMarker
    start_microseconds: int
    end_microseconds: int


def correlate_can_with_markers(
    can_paths: Iterable[Path],
    marker_paths: Iterable[Path],
    *,
    settle_microseconds: int = DEFAULT_SETTLE_MICROSECONDS,
    window_microseconds: int = DEFAULT_WINDOW_MICROSECONDS,
) -> dict[str, Any]:
    if not 0 <= settle_microseconds <= 1_000_000:
        raise MarkerCorrelationError(
            "Marker settle time must be between 0 and 1,000,000 us."
        )
    if not 100_000 <= window_microseconds <= 10_000_000:
        raise MarkerCorrelationError(
            "Marker window must be between 100,000 and 10,000,000 us."
        )

    records, can_sources = load_passive_can_ndjson(can_paths)
    markers, marker_sources = load_marker_ledgers(marker_paths)
    by_run: dict[str, list[DiscoveryMarker]] = defaultdict(list)
    for marker in markers:
        by_run[marker.test_run_id].append(marker)

    ranked: list[dict[str, Any]] = []
    run_summaries: list[dict[str, Any]] = []
    for run_id, run_markers in sorted(by_run.items()):
        ordered_markers = sorted(
            run_markers,
            key=lambda item: (item.monotonic_microseconds, item.marker_id),
        )
        if len(ordered_markers) < 3:
            continue
        gateways = {item.gateway_id for item in ordered_markers}
        sessions = {item.session_id for item in ordered_markers}
        templates = {item.template_id for item in ordered_markers}
        captures = {item.capture_id for item in ordered_markers}
        if any(
            len(values) != 1 for values in (gateways, sessions, templates, captures)
        ):
            raise MarkerCorrelationError(
                f"Test run {run_id} crosses gateway, session, template, or capture lineage."
            )
        gateway_id = next(iter(gateways))
        session_id = next(iter(sessions))
        session_records = [
            item
            for item in records
            if item.gateway_id == gateway_id and item.session_id == session_id
        ]
        analysis_markers = [
            marker for marker in ordered_markers if marker.kind != "CUSTOM"
        ]
        if len(analysis_markers) < 3:
            continue
        windows = _build_windows(
            analysis_markers,
            settle_microseconds=settle_microseconds,
            window_microseconds=window_microseconds,
        )
        candidates = _rank_run_candidates(run_id, windows, session_records)
        ranked.extend(candidates)
        run_summaries.append(
            {
                "test_run_id": run_id,
                "template_id": next(iter(templates)),
                "capture_id": next(iter(captures)),
                "gateway_id": gateway_id,
                "gateway_session_id": session_id,
                "marker_count": len(ordered_markers),
                "marker_kinds": sorted({item.kind for item in ordered_markers}),
                "can_records_in_session": len(session_records),
                "candidate_count": len(candidates),
            }
        )

    if not run_summaries:
        raise MarkerCorrelationError(
            "No marker run contains the minimum three synchronized markers."
        )
    ranked.sort(
        key=lambda item: (
            -item["score"],
            -item["within_window_stability"],
            item["identifier"],
            item["field"],
            item["test_run_id"],
        )
    )
    report = {
        "contract": REPORT_CONTRACT,
        "contract_version": REPORT_VERSION,
        "status": "DISCOVERY_CANDIDATE",
        "authority": (
            "Observed user markers and retained listen-only CAN evidence support repeatable "
            "state-association candidates only. Marker timing, correlation, and return-state "
            "agreement do not establish Toyota semantics, scale, unit, exact-vehicle "
            "applicability, parked/motion authority, or a production signal definition."
        ),
        "parameters": {
            "settle_microseconds": settle_microseconds,
            "window_microseconds": window_microseconds,
        },
        "source_files": [
            *(
                {
                    "role": "PASSIVE_CAN",
                    "name": item["name"],
                    "sha256": item["sha256"],
                    "byte_count": item["byte_count"],
                    "record_count": item["record_count"],
                }
                for item in can_sources
            ),
            *marker_sources,
        ],
        "test_runs": run_summaries,
        "ranked_candidates": ranked[:MAXIMUM_CANDIDATES],
        "promotion_allowed": False,
    }
    ContractCatalog.load().validate(report)
    return report


def load_marker_ledgers(
    paths: Iterable[Path],
) -> tuple[list[DiscoveryMarker], list[dict[str, Any]]]:
    files = _resolve_marker_inputs(paths)
    markers: list[DiscoveryMarker] = []
    sources: list[dict[str, Any]] = []
    marker_ids: set[str] = set()
    total_bytes = 0
    for path in files:
        raw = path.read_bytes()
        total_bytes += len(raw)
        if total_bytes > MAX_INPUT_BYTES:
            raise MarkerCorrelationError(
                "Marker input exceeds the aggregate byte limit."
            )
        file_records = 0
        for line_number, raw_line in enumerate(raw.splitlines(), start=1):
            if not raw_line.strip():
                continue
            location = f"{path.name}:{line_number}"
            try:
                document = json.loads(raw_line, object_pairs_hook=_unique_json_object)
            except _DuplicateJSONKeyError as error:
                raise MarkerCorrelationError(
                    f"{location}: duplicate JSON field {error}."
                ) from error
            except json.JSONDecodeError as error:
                raise MarkerCorrelationError(f"{location}: invalid JSON.") from error
            marker = _parse_marker_wrapper(document, location)
            if marker.marker_id in marker_ids:
                raise MarkerCorrelationError(
                    f"{location}: duplicate marker identity {marker.marker_id}."
                )
            marker_ids.add(marker.marker_id)
            markers.append(marker)
            file_records += 1
        sources.append(
            {
                "role": "EVENT_MARKER",
                "name": path.name,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "byte_count": len(raw),
                "record_count": file_records,
            }
        )
    if not markers:
        raise MarkerCorrelationError("No discovery event markers were found.")
    return markers, sources


def _resolve_marker_inputs(paths: Iterable[Path]) -> list[Path]:
    resolved: set[Path] = set()
    for candidate in paths:
        path = candidate.resolve()
        if path.is_symlink():
            raise MarkerCorrelationError(
                f"Marker input may not be a symbolic link: {candidate}"
            )
        if path.is_file():
            resolved.add(path)
        elif path.is_dir():
            for child in path.rglob("*.ndjson"):
                if child.is_symlink():
                    raise MarkerCorrelationError(
                        f"Marker input may not contain a symbolic link: {child}"
                    )
                if child.is_file():
                    resolved.add(child.resolve())
        else:
            raise MarkerCorrelationError(f"Marker input does not exist: {candidate}")
    if not resolved:
        raise MarkerCorrelationError("No marker NDJSON files were found.")
    return sorted(resolved)


def _parse_marker_wrapper(document: Any, location: str) -> DiscoveryMarker:
    required = {
        "contract",
        "contract_version",
        "gateway_id",
        "gateway_session_id",
        "marker",
        "template_id",
        "test_run_id",
    }
    if not isinstance(document, dict) or set(document) != required:
        raise MarkerCorrelationError(f"{location}: marker ledger fields are invalid.")
    if (
        document.get("contract") != LEDGER_CONTRACT
        or document.get("contract_version") != LEDGER_VERSION
    ):
        raise MarkerCorrelationError(f"{location}: marker ledger contract is invalid.")
    nested = document.get("marker")
    if not isinstance(nested, dict):
        raise MarkerCorrelationError(f"{location}: nested event marker is invalid.")
    try:
        ContractCatalog.load().validate(nested)
    except Exception as error:
        raise MarkerCorrelationError(
            f"{location}: nested event marker failed its contract: {error}"
        ) from error
    gateway_id = document.get("gateway_id")
    session_id = document.get("gateway_session_id")
    if nested.get("gateway_session_id") != session_id:
        raise MarkerCorrelationError(f"{location}: marker session lineage conflicts.")
    string_values = {
        "marker_id": nested.get("id"),
        "test_run_id": document.get("test_run_id"),
        "template_id": document.get("template_id"),
        "capture_id": nested.get("capture_id"),
        "gateway_id": gateway_id,
        "kind": nested.get("kind"),
        "label": nested.get("label"),
    }
    if any(not isinstance(value, str) or not value for value in string_values.values()):
        raise MarkerCorrelationError(f"{location}: marker identity fields are invalid.")
    if isinstance(session_id, bool) or not isinstance(session_id, int):
        raise MarkerCorrelationError(f"{location}: marker session is invalid.")
    monotonic = nested.get("gateway_monotonic_microseconds")
    nearest = nested.get("nearest_can_sequence")
    if isinstance(monotonic, bool) or not isinstance(monotonic, int):
        raise MarkerCorrelationError(f"{location}: marker monotonic time is invalid.")
    if nearest is not None and (
        isinstance(nearest, bool) or not isinstance(nearest, int)
    ):
        raise MarkerCorrelationError(f"{location}: nearest CAN sequence is invalid.")
    return DiscoveryMarker(
        **string_values,
        session_id=session_id,
        monotonic_microseconds=monotonic,
        nearest_can_sequence=nearest,
    )


def _build_windows(
    markers: list[DiscoveryMarker],
    *,
    settle_microseconds: int,
    window_microseconds: int,
) -> list[_Window]:
    windows: list[_Window] = []
    for index, marker in enumerate(markers):
        start = marker.monotonic_microseconds + settle_microseconds
        proposed_end = start + window_microseconds
        if index + 1 < len(markers):
            next_boundary = (
                markers[index + 1].monotonic_microseconds - settle_microseconds
            )
            end = min(proposed_end, next_boundary)
        else:
            end = proposed_end
        if end <= start:
            raise MarkerCorrelationError(
                f"Marker {marker.marker_id} and its successor do not leave a usable settled window."
            )
        windows.append(_Window(marker, start, end))
    return windows


def _rank_run_candidates(
    run_id: str,
    windows: list[_Window],
    records: list[PassiveCANRecord],
) -> list[dict[str, Any]]:
    by_identifier: dict[tuple[int, bool], list[PassiveCANRecord]] = defaultdict(list)
    for record in records:
        by_identifier[(record.identifier, record.extended)].append(record)
    candidates: list[dict[str, Any]] = []
    for (identifier, extended), identifier_records in sorted(by_identifier.items()):
        feature_names = sorted(
            {
                feature
                for record in identifier_records
                for feature in _raw_features(record)
            },
            key=_feature_sort_key,
        )
        record_features = [
            (record, _raw_features(record)) for record in identifier_records
        ]
        for feature in feature_names:
            samples: list[dict[str, Any]] = []
            total_observations = 0
            for window in windows:
                values = [
                    features[feature]
                    for record, features in record_features
                    if window.start_microseconds
                    <= record.monotonic_microseconds
                    < window.end_microseconds
                    and feature in features
                ]
                if not values:
                    break
                counts = Counter(values)
                mode_value, mode_count = min(
                    counts.items(), key=lambda item: (-item[1], item[0])
                )
                total_observations += len(values)
                samples.append(
                    {
                        "marker_id": window.marker.marker_id,
                        "label": window.marker.label,
                        "kind": window.marker.kind,
                        "value": mode_value,
                        "mode_fraction": round(mode_count / len(values), 6),
                        "observations": len(values),
                    }
                )
            if len(samples) != len(windows):
                continue
            signature = [item["value"] for item in samples]
            if len(set(signature)) <= 1:
                continue
            stability = statistics.fmean(item["mode_fraction"] for item in samples)
            repeated_groups: dict[str, list[int]] = defaultdict(list)
            for sample in samples:
                repeated_groups[sample["kind"]].append(sample["value"])
            repeat_scores = [
                max(Counter(values).values()) / len(values)
                for values in repeated_groups.values()
                if len(values) > 1
            ]
            return_repeatability = (
                statistics.fmean(repeat_scores) if repeat_scores else 0.5
            )
            transitions = [
                left["value"] != right["value"]
                for left, right in zip(samples, samples[1:], strict=False)
                if left["kind"] != right["kind"]
            ]
            transition_fraction = (
                sum(transitions) / len(transitions) if transitions else 0.0
            )
            unique_kinds = len(repeated_groups)
            kind_modes = [
                min(Counter(values).items(), key=lambda item: (-item[1], item[0]))[0]
                for values in repeated_groups.values()
            ]
            state_distinctness = len(set(kind_modes)) / unique_kinds
            association_score = (
                0.4 * stability
                + 0.25 * return_repeatability
                + 0.25 * transition_fraction
                + 0.1 * state_distinctness
            )
            evidence_density = statistics.fmean(
                min(item["observations"], FULL_DENSITY_OBSERVATIONS_PER_MARKER)
                / FULL_DENSITY_OBSERVATIONS_PER_MARKER
                for item in samples
            )
            score = association_score * evidence_density
            values_to_kinds: dict[int, set[str]] = defaultdict(set)
            for sample in samples:
                values_to_kinds[sample["value"]].add(sample["kind"])
            ambiguous = [
                sorted(kinds)
                for _, kinds in sorted(values_to_kinds.items())
                if len(kinds) > 1
            ]
            candidates.append(
                {
                    "test_run_id": run_id,
                    "identifier": (
                        f"0x{identifier:08X}" if extended else f"0x{identifier:03X}"
                    ),
                    "extended": extended,
                    "field": feature,
                    "behavior_shape": (
                        "BOOLEAN" if feature.startswith("bit") else "STATE_CODE"
                    ),
                    "marker_samples": len(samples),
                    "window_observations": total_observations,
                    "minimum_window_observations": min(
                        item["observations"] for item in samples
                    ),
                    "evidence_density": round(evidence_density, 6),
                    "within_window_stability": round(stability, 6),
                    "return_state_repeatability": round(return_repeatability, 6),
                    "transition_fraction": round(transition_fraction, 6),
                    "state_distinctness": round(state_distinctness, 6),
                    "association_score": round(association_score, 6),
                    "score": round(score, 6),
                    "signature": samples,
                    "ambiguous_marker_kinds": ambiguous,
                    "status": "DISCOVERY_CANDIDATE",
                }
            )
    candidates.sort(
        key=lambda item: (
            -item["score"],
            item["identifier"],
            _feature_sort_key(item["field"]),
        )
    )
    return _deduplicate_signatures(candidates)[:MAXIMUM_CANDIDATES]


def _raw_features(record: PassiveCANRecord) -> dict[str, int]:
    payload = record.payload
    features: dict[str, int] = {}
    for index, value in enumerate(payload):
        features[f"byte{index}"] = value
        for bit in range(8):
            features[f"bit{index}_{bit}"] = (value >> bit) & 1
    for index in range(max(0, len(payload) - 1)):
        pair = payload[index : index + 2]
        features[f"be16_{index}"] = int.from_bytes(pair, "big")
        features[f"le16_{index}"] = int.from_bytes(pair, "little")
    return features


def _feature_sort_key(value: str) -> tuple[int, str]:
    if value.startswith("byte"):
        return (0, value)
    if value.startswith("bit"):
        return (1, value)
    if value.startswith("be16"):
        return (2, value)
    return (3, value)


def _deduplicate_signatures(
    candidates: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    seen: set[tuple[str, tuple[int, ...]]] = set()
    result: list[dict[str, Any]] = []
    for candidate in candidates:
        values = tuple(item["value"] for item in candidate["signature"])
        ordinal_by_value: dict[int, int] = {}
        partition = tuple(
            ordinal_by_value.setdefault(value, len(ordinal_by_value))
            for value in values
        )
        key = (candidate["identifier"], partition)
        if key in seen:
            continue
        seen.add(key)
        result.append(candidate)
    return result


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise _DuplicateJSONKeyError(key)
        document[key] = value
    return document
