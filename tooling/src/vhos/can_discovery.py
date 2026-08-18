from __future__ import annotations

import bisect
import hashlib
import json
import math
import re
import statistics
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


ANALYSIS_CONTRACT = "can.discovery.report"
ANALYSIS_VERSION = "1.0.0"
OBSERVATION_CONTRACT = "gateway.passive-can-observation"
OBSERVATION_VERSION = "1.0.0"
VALID_BITRATES = {250_000, 500_000}
MAX_RECORDS = 1_000_000
PAIRING_WINDOW_MICROSECONDS = 250_000


class CANDiscoveryError(ValueError):
    """Raised when passive CAN evidence cannot be safely analyzed."""


@dataclass(frozen=True)
class PassiveCANRecord:
    gateway_id: str
    session_id: int
    source_sequence: int
    monotonic_microseconds: int
    bitrate_bps: int
    identifier: int
    extended: bool
    remote_request: bool
    listen_only: bool
    data_length: int
    data: tuple[int, ...]
    evidence_source: str
    ingested_at: str

    @property
    def identity(self) -> tuple[str, int, int]:
        return self.gateway_id, self.session_id, self.source_sequence

    @property
    def identifier_hex(self) -> str:
        width = 8 if self.extended else 3
        return f"0x{self.identifier:0{width}X}"

    @property
    def payload(self) -> tuple[int, ...]:
        return self.data[: self.data_length]

    @classmethod
    def from_document(cls, document: dict[str, Any], *, line_number: int) -> PassiveCANRecord:
        location = f"line {line_number}"
        if document.get("contract") != OBSERVATION_CONTRACT:
            raise CANDiscoveryError(f"{location}: passive CAN contract is unsupported.")
        if document.get("contract_version") != OBSERVATION_VERSION:
            raise CANDiscoveryError(f"{location}: passive CAN contract version is unsupported.")

        gateway_id = _required_string(document, "gateway_id", location)
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", gateway_id):
            raise CANDiscoveryError(f"{location}: gateway_id is invalid.")
        session_id = _required_integer(document, "session_id", location, 0, 0xFFFF_FFFF)
        source_sequence = _required_integer(
            document, "source_sequence", location, 0, 0xFFFF_FFFF_FFFF_FFFF
        )
        monotonic = _required_integer(
            document, "monotonic_microseconds", location, 0, 0xFFFF_FFFF_FFFF_FFFF
        )
        bitrate = _required_integer(document, "bitrate_bps", location, 1, 10_000_000)
        if bitrate not in VALID_BITRATES:
            raise CANDiscoveryError(f"{location}: unsupported CAN bitrate {bitrate}.")
        extended = _required_boolean(document, "extended", location)
        remote_request = _required_boolean(document, "remote_request", location)
        listen_only = _required_boolean(document, "listen_only", location)
        if not listen_only:
            raise CANDiscoveryError(f"{location}: evidence does not retain listen-only proof.")
        identifier = _required_integer(
            document,
            "identifier",
            location,
            0,
            0x1FFF_FFFF if extended else 0x7FF,
        )
        data_length = _required_integer(document, "data_length", location, 0, 8)
        raw_data = document.get("data")
        if not isinstance(raw_data, list) or len(raw_data) != 8:
            raise CANDiscoveryError(f"{location}: data must contain exactly eight bounded bytes.")
        data = tuple(
            _bounded_integer(value, f"{location}: data[{index}]", 0, 255)
            for index, value in enumerate(raw_data)
        )
        evidence_source = _required_string(document, "evidence_source", location)
        if evidence_source not in {"gateway-flash", "ble-live"}:
            raise CANDiscoveryError(f"{location}: evidence_source is unsupported.")
        ingested_at = _required_string(document, "ingested_at", location)
        try:
            parsed_ingested_at = datetime.fromisoformat(ingested_at.replace("Z", "+00:00"))
            if parsed_ingested_at.tzinfo is None:
                raise ValueError("timestamp has no UTC offset")
        except ValueError as error:
            raise CANDiscoveryError(f"{location}: ingested_at is invalid.") from error
        return cls(
            gateway_id=gateway_id,
            session_id=session_id,
            source_sequence=source_sequence,
            monotonic_microseconds=monotonic,
            bitrate_bps=bitrate,
            identifier=identifier,
            extended=extended,
            remote_request=remote_request,
            listen_only=listen_only,
            data_length=data_length,
            data=data,
            evidence_source=evidence_source,
            ingested_at=ingested_at,
        )


def load_passive_can_ndjson(paths: Iterable[Path]) -> tuple[list[PassiveCANRecord], list[dict[str, Any]]]:
    files = _resolve_inputs(paths)
    records: list[PassiveCANRecord] = []
    sources: list[dict[str, Any]] = []
    identities: set[tuple[str, int, int]] = set()
    for path in files:
        raw = path.read_bytes()
        file_records = 0
        for line_number, line in enumerate(raw.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                document = json.loads(line)
            except json.JSONDecodeError as error:
                raise CANDiscoveryError(f"{path.name}:{line_number}: invalid JSON.") from error
            if not isinstance(document, dict):
                raise CANDiscoveryError(f"{path.name}:{line_number}: record must be an object.")
            record = PassiveCANRecord.from_document(document, line_number=line_number)
            if record.identity in identities:
                raise CANDiscoveryError(
                    f"{path.name}:{line_number}: duplicate observation identity {record.identity}."
                )
            identities.add(record.identity)
            records.append(record)
            file_records += 1
            if len(records) > MAX_RECORDS:
                raise CANDiscoveryError("Passive CAN input exceeds the analysis record limit.")
        sources.append(
            {
                "name": path.name,
                "byte_count": len(raw),
                "record_count": file_records,
                "sha256": hashlib.sha256(raw).hexdigest(),
            }
        )
    if not records:
        raise CANDiscoveryError("No passive CAN observations were found.")
    return records, sources


def analyze_passive_can(
    records: Iterable[PassiveCANRecord],
    *,
    sources: Iterable[dict[str, Any]] = (),
) -> dict[str, Any]:
    ordered = sorted(
        records,
        key=lambda item: (
            item.gateway_id,
            item.session_id,
            item.monotonic_microseconds,
            item.source_sequence,
        ),
    )
    if not ordered:
        raise CANDiscoveryError("No passive CAN observations were provided.")
    identities = [item.identity for item in ordered]
    if len(set(identities)) != len(identities):
        raise CANDiscoveryError("Duplicate passive CAN observation identities were provided.")

    by_session: dict[tuple[str, int], list[PassiveCANRecord]] = defaultdict(list)
    by_identifier: dict[tuple[int, bool], list[PassiveCANRecord]] = defaultdict(list)
    for record in ordered:
        by_session[(record.gateway_id, record.session_id)].append(record)
        by_identifier[(record.identifier, record.extended)].append(record)

    sessions = [_session_summary(key, values) for key, values in sorted(by_session.items())]
    total_duration = sum(item["duration_seconds"] for item in sessions)
    total_sequence_span = sum(item["sequence_span"] for item in sessions)
    total_observed_intervals = sum(max(0, item["sequence_span"] - 1) for item in sessions)
    identifier_summaries = [
        _identifier_summary(key, values)
        for key, values in sorted(by_identifier.items(), key=lambda item: item[0])
    ]
    identifier_summaries.sort(
        key=lambda item: (
            -item["dynamic_byte_count"],
            -item["unique_payloads"],
            -item["records"],
            item["identifier"],
        )
    )

    relationships = _correlation_candidates(by_identifier, by_session)
    repeated_groups = _repeated_channel_candidates(by_identifier)
    checksum_candidates = [
        {
            "identifier": item["identifier"],
            "checked": item["checksum_candidate"]["checked"],
            "matches": item["checksum_candidate"]["matches"],
            "match_rate": item["checksum_candidate"]["match_rate"],
            "status": "DISCOVERY_CANDIDATE",
        }
        for item in identifier_summaries
        if item["checksum_candidate"]["candidate"]
    ]

    acquisition = {
        "records": len(ordered),
        "gateways": len({item.gateway_id for item in ordered}),
        "sessions": len(by_session),
        "unique_identifiers": len(by_identifier),
        "bitrates_bps": sorted({item.bitrate_bps for item in ordered}),
        "listen_only_records": sum(item.listen_only for item in ordered),
        "standard_identifier_records": sum(not item.extended for item in ordered),
        "extended_identifier_records": sum(item.extended for item in ordered),
        "remote_request_records": sum(item.remote_request for item in ordered),
        "capture_duration_seconds": _round(total_duration),
        "estimated_observed_frames": total_sequence_span,
        "estimated_observed_rate_fps": _round(
            total_observed_intervals / total_duration if total_duration > 0 else 0.0
        ),
        "retained_record_rate_fps": _round(
            len(ordered) / total_duration if total_duration > 0 else 0.0
        ),
        "sequence_coverage": _round(
            len(ordered) / total_sequence_span if total_sequence_span else 0.0, digits=6
        ),
    }
    return {
        "contract": ANALYSIS_CONTRACT,
        "contract_version": ANALYSIS_VERSION,
        "status": "DISCOVERY_CANDIDATE",
        "authority": (
            "Acquisition facts and raw statistics only. No CAN identifier, field, unit, scale, "
            "vehicle subsystem, or health meaning is accepted by this report."
        ),
        "source_files": list(sources),
        "acquisition": acquisition,
        "sessions": sessions,
        "identifier_activity": identifier_summaries,
        "checksum_candidates": checksum_candidates,
        "raw_word_relationship_candidates": relationships,
        "repeated_channel_candidates": repeated_groups,
        "display_policy": {
            "proven_now": [
                "capture/session/source identity",
                "listen-only, identifier-format, RTR, bitrate, and DLC evidence",
                "retained records, identifier population, raw payloads, and raw byte ranges",
                "sequence-derived observed-rate estimate and explicit retained coverage",
            ],
            "candidate_only": [
                "checksum family matches",
                "raw word correlations and ratios",
                "repeated-channel agreement",
                "counter, signedness, scale, offset, and vehicle-signal hypotheses",
            ],
            "blocked_until_correlated": [
                "RPM, speed, gear, throttle, steering, brake, temperature, or pressure labels",
                "normal/abnormal thresholds and vehicle-health conclusions",
            ],
        },
    }


def _session_summary(
    key: tuple[str, int], records: list[PassiveCANRecord]
) -> dict[str, Any]:
    gateway_id, session_id = key
    sequences = [item.source_sequence for item in records]
    monotonic = [item.monotonic_microseconds for item in records]
    duration = (max(monotonic) - min(monotonic)) / 1_000_000
    span = max(sequences) - min(sequences) + 1
    return {
        "gateway_id": gateway_id,
        "session_id": session_id,
        "records": len(records),
        "duration_seconds": _round(duration),
        "first_source_sequence": min(sequences),
        "last_source_sequence": max(sequences),
        "sequence_span": span,
        "estimated_observed_rate_fps": _round(
            (span - 1) / duration if duration > 0 else 0.0
        ),
        "retained_record_rate_fps": _round(len(records) / duration if duration > 0 else 0.0),
        "sequence_coverage": _round(len(records) / span if span else 0.0, digits=6),
        "unique_identifiers": len({(item.identifier, item.extended) for item in records}),
    }


def _identifier_summary(
    key: tuple[int, bool], records: list[PassiveCANRecord]
) -> dict[str, Any]:
    identifier, extended = key
    records = sorted(
        records,
        key=lambda item: (item.gateway_id, item.session_id, item.monotonic_microseconds),
    )
    payloads = [item.payload for item in records]
    min_length = min(item.data_length for item in records)
    byte_ranges = []
    for index in range(min_length):
        values = [item.data[index] for item in records]
        byte_ranges.append({"byte": index, "minimum": min(values), "maximum": max(values)})
    dynamic_positions = [
        item["byte"] for item in byte_ranges if item["minimum"] != item["maximum"]
    ]
    transitions = 0
    changes = 0
    previous_by_session: dict[tuple[str, int], tuple[int, ...]] = {}
    for record in records:
        session = (record.gateway_id, record.session_id)
        previous = previous_by_session.get(session)
        if previous is not None:
            transitions += 1
            changes += previous != record.payload
        previous_by_session[session] = record.payload
    word_values = [((item.data[0] << 8) | item.data[1]) for item in records if item.data_length >= 2]
    checksum_checked = 0
    checksum_matches = 0
    for record in records:
        if record.extended or record.remote_request or record.data_length < 1:
            continue
        checksum_checked += 1
        checksum_matches += _toyota_additive_checksum_matches(record)
    checksum_rate = checksum_matches / checksum_checked if checksum_checked else 0.0
    return {
        "identifier": f"0x{identifier:0{8 if extended else 3}X}",
        "identifier_value": identifier,
        "extended": extended,
        "records": len(records),
        "sessions": len({(item.gateway_id, item.session_id) for item in records}),
        "data_lengths": sorted({item.data_length for item in records}),
        "unique_payloads": len(set(payloads)),
        "payload_change_rate": _round(changes / transitions if transitions else 0.0, digits=6),
        "dynamic_byte_count": len(dynamic_positions),
        "dynamic_byte_positions": dynamic_positions,
        "byte_ranges": byte_ranges,
        "first_big_endian_word": _numeric_summary(word_values),
        "checksum_candidate": {
            "algorithm": "toyota-additive-id-dlc-payload-v0",
            "checked": checksum_checked,
            "matches": checksum_matches,
            "match_rate": _round(checksum_rate, digits=6),
            "candidate": checksum_checked >= 5 and checksum_rate >= 0.95,
            "status": "DISCOVERY_CANDIDATE",
        },
        "status": "DISCOVERY_CANDIDATE",
    }


def _numeric_summary(values: list[int]) -> dict[str, Any] | None:
    if not values:
        return None
    return {
        "byte_order": "BIG_ENDIAN",
        "bit_range": "0:16",
        "minimum": min(values),
        "maximum": max(values),
        "mean": _round(statistics.fmean(values)),
        "standard_deviation": _round(statistics.pstdev(values)),
        "status": "DISCOVERY_CANDIDATE",
    }


def _toyota_additive_checksum_matches(record: PassiveCANRecord) -> bool:
    payload = record.payload
    expected = (
        ((record.identifier >> 8) & 0xFF)
        + (record.identifier & 0xFF)
        + record.data_length
        + sum(payload[:-1])
    ) & 0xFF
    return expected == payload[-1]


def _correlation_candidates(
    by_identifier: dict[tuple[int, bool], list[PassiveCANRecord]],
    by_session: dict[tuple[str, int], list[PassiveCANRecord]],
) -> list[dict[str, Any]]:
    identifier_keys = [
        key
        for key, values in sorted(by_identifier.items())
        if not key[1]
        and sum(item.data_length >= 2 for item in values) >= 10
        and len({(item.data[0] << 8) | item.data[1] for item in values if item.data_length >= 2}) > 1
    ]
    pairs: list[dict[str, Any]] = []
    for left_index, left_key in enumerate(identifier_keys):
        for right_key in identifier_keys[left_index + 1 :]:
            left_values: list[float] = []
            right_values: list[float] = []
            for session_records in by_session.values():
                left = [
                    (item.monotonic_microseconds, float((item.data[0] << 8) | item.data[1]))
                    for item in session_records
                    if (item.identifier, item.extended) == left_key and item.data_length >= 2
                ]
                right = [
                    (item.monotonic_microseconds, float((item.data[0] << 8) | item.data[1]))
                    for item in session_records
                    if (item.identifier, item.extended) == right_key and item.data_length >= 2
                ]
                paired = _nearest_pairs(left, right)
                left_values.extend(item[0] for item in paired)
                right_values.extend(item[1] for item in paired)
            if len(left_values) < 10:
                continue
            correlation = _pearson(left_values, right_values)
            if correlation is None or abs(correlation) < 0.95:
                continue
            ratios = [right / left for left, right in zip(left_values, right_values) if left != 0]
            pairs.append(
                {
                    "left": f"0x{left_key[0]:03X}[0:16]",
                    "right": f"0x{right_key[0]:03X}[0:16]",
                    "paired_samples": len(left_values),
                    "maximum_pairing_delta_us": PAIRING_WINDOW_MICROSECONDS,
                    "pearson_correlation": _round(correlation, digits=6),
                    "median_right_to_left_ratio": (
                        _round(statistics.median(ratios), digits=6) if ratios else None
                    ),
                    "status": "DISCOVERY_CANDIDATE",
                }
            )
    pairs.sort(
        key=lambda item: (-abs(item["pearson_correlation"]), -item["paired_samples"], item["left"])
    )
    return pairs[:12]


def _nearest_pairs(
    left: list[tuple[int, float]], right: list[tuple[int, float]]
) -> list[tuple[float, float]]:
    if not left or not right:
        return []
    right = sorted(right)
    times = [item[0] for item in right]
    paired: list[tuple[float, float]] = []
    for timestamp, value in sorted(left):
        insertion = bisect.bisect_left(times, timestamp)
        candidates = [index for index in (insertion - 1, insertion) if 0 <= index < len(right)]
        if not candidates:
            continue
        nearest = min(candidates, key=lambda index: abs(times[index] - timestamp))
        if abs(times[nearest] - timestamp) <= PAIRING_WINDOW_MICROSECONDS:
            paired.append((value, right[nearest][1]))
    return paired


def _pearson(left: list[float], right: list[float]) -> float | None:
    if len(left) != len(right) or len(left) < 2:
        return None
    left_mean = statistics.fmean(left)
    right_mean = statistics.fmean(right)
    left_delta = [value - left_mean for value in left]
    right_delta = [value - right_mean for value in right]
    denominator = math.sqrt(
        sum(value * value for value in left_delta) * sum(value * value for value in right_delta)
    )
    if denominator == 0:
        return None
    return sum(a * b for a, b in zip(left_delta, right_delta)) / denominator


def _repeated_channel_candidates(
    by_identifier: dict[tuple[int, bool], list[PassiveCANRecord]],
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for (identifier, extended), records in sorted(by_identifier.items()):
        if extended or len(records) < 5:
            continue
        minimum_length = min(item.data_length for item in records)
        columns: dict[tuple[int, ...], list[int]] = defaultdict(list)
        for index in range(minimum_length):
            vector = tuple(item.data[index] for item in records)
            if len(set(vector)) > 1:
                columns[vector].append(index)
        for vector, positions in columns.items():
            if len(positions) < 2:
                continue
            results.append(
                {
                    "identifier": f"0x{identifier:03X}",
                    "byte_positions": positions,
                    "records_compared": len(records),
                    "minimum": min(vector),
                    "maximum": max(vector),
                    "maximum_disagreement": 0,
                    "status": "DISCOVERY_CANDIDATE",
                }
            )
    results.sort(key=lambda item: (-item["records_compared"], item["identifier"]))
    return results


def _resolve_inputs(paths: Iterable[Path]) -> list[Path]:
    resolved: set[Path] = set()
    for candidate in paths:
        path = candidate.expanduser().resolve()
        if path.is_dir():
            resolved.update(item for item in path.rglob("*.ndjson") if item.is_file())
        elif path.is_file():
            resolved.add(path)
        else:
            raise CANDiscoveryError(f"Passive CAN input does not exist: {candidate}")
    if not resolved:
        raise CANDiscoveryError("No NDJSON input files were selected.")
    return sorted(resolved)


def _required_string(document: dict[str, Any], key: str, location: str) -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value:
        raise CANDiscoveryError(f"{location}: {key} must be a non-empty string.")
    return value


def _required_integer(
    document: dict[str, Any], key: str, location: str, minimum: int, maximum: int
) -> int:
    return _bounded_integer(document.get(key), f"{location}: {key}", minimum, maximum)


def _bounded_integer(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise CANDiscoveryError(f"{name} must be an integer from {minimum} through {maximum}.")
    return value


def _required_boolean(document: dict[str, Any], key: str, location: str) -> bool:
    value = document.get(key)
    if not isinstance(value, bool):
        raise CANDiscoveryError(f"{location}: {key} must be a boolean.")
    return value


def _round(value: float, *, digits: int = 3) -> float:
    return round(value, digits)
