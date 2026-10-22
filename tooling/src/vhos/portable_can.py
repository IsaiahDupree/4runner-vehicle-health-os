from __future__ import annotations

import base64
import copy
import hashlib
import io
import json
import os
import re
import shutil
import uuid
import zipfile
from dataclasses import dataclass
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Sequence

from .can_discovery import MAX_RECORDS, PassiveCANRecord
from .can_replay import (
    CAPTURE_LOG_CHUNK_MESSAGE_TYPE,
    LIVE_CAN_MESSAGE_TYPE,
    GatewayFrameStreamDecoder,
    _decode_wire_observations,
    _record_document,
    _record_semantic_tuple,
)


PORTABLE_CONTRACT = "vhos.portable-logical-frame"
PORTABLE_VERSION = "1.0.0"
EXTRACTION_CONTRACT = "can.portable-evidence-extraction"
EXTRACTION_VERSION = "1.0.0"
RECOVERED_OBSERVATION_CONTRACT = "can.recovered-passive-can-observation"
RECOVERED_OBSERVATION_VERSION = "1.0.0"
SOURCE_CLASSIFICATION = "RECOVERED_PORTABLE_EVIDENCE"
REQUIRED_DISPLAY_LABEL = "RECOVERED EVIDENCE • NOT LIVE"
CAN_MESSAGE_TYPES = {LIVE_CAN_MESSAGE_TYPE, CAPTURE_LOG_CHUNK_MESSAGE_TYPE}
SYNC_BUNDLE_CONTRACT = "vhos.evidence-sync-bundle"
SYNC_BUNDLE_VERSIONS = {"1.0.0", "2.0.0"}
SYNC_MANIFEST_PATH = "manifest.json"
MAX_SYNC_ENTRY_BYTES = 16 * 1024 * 1024
MAX_SYNC_TOTAL_BYTES = 17 * 1024 * 1024
MAX_SYNC_ARCHIVE_BYTES = 18 * 1024 * 1024
MAX_SYNC_MANIFEST_BYTES = 1024 * 1024
MAX_SYNC_ENTRY_COUNT = 33
MAX_SYNC_RECORDS = 20_000
MAX_ANALYSIS_ENTRY_BYTES = 128 * 1024 * 1024
MAX_ANALYSIS_TOTAL_BYTES = 128 * 1024 * 1024
MAX_PORTABLE_SOURCE_FILES = 1024
MAX_PORTABLE_SOURCE_ID_CHARACTERS = 160
MAX_PORTABLE_BASE64_CHARACTERS = 2_097_152
MAX_CREATOR_APPLICATION_ID_CHARACTERS = 160
MAX_CREATOR_APPLICATION_VERSION_CHARACTERS = 80
MAX_CREATOR_DEVICE_MODEL_CHARACTERS = 160
MAX_PROVENANCE_NAME_CHARACTERS = 1024

_CANONICAL_UINT64_RE = re.compile(r"^(0|[1-9][0-9]{0,19})$")
_RFC3339_WALL_TIME_RE = re.compile(
    r"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    r"[Tt](?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]"
    r"(?:\.[0-9]+)?(?:[Zz]|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"
)

PORTABLE_FRAME_KEYS = {
    "contract",
    "contract_version",
    "source_role",
    "source_id",
    "source_sequence",
    "source_monotonic_microseconds",
    "protocol_major",
    "protocol_minor",
    "message_type",
    "flags",
    "ingested_at",
    "envelope_sha256",
    "envelope_base64",
}
PASSIVE_OBSERVATION_KEYS = {
    "contract",
    "contract_version",
    "gateway_id",
    "session_id",
    "source_sequence",
    "monotonic_microseconds",
    "bitrate_bps",
    "identifier",
    "extended",
    "remote_request",
    "listen_only",
    "data_length",
    "data",
    "evidence_source",
    "ingested_at",
}
RECOVERED_OBSERVATION_KEYS = {
    "contract",
    "contract_version",
    "source_classification",
    "vehicle_claims_authorized",
    "observation",
}


class PortableCANError(ValueError):
    """Raised when portable iOS evidence cannot be projected safely into CAN records."""


class _DuplicateJSONKeyError(ValueError):
    pass


@dataclass(frozen=True)
class _PortableSource:
    name: str
    data: bytes
    bundle_provenance: dict[str, Any] | None = None


def load_portable_can_records(
    paths: Iterable[Path],
    *,
    session_ids: Sequence[int] = (),
) -> tuple[list[PassiveCANRecord], dict[str, Any]]:
    """Validate portable envelopes and project only listen-only OBD/CAN observations.

    Exact live/history overlap is reconciled by physical CAN identity, with
    gateway-flash provenance preferred. Conflicting same-identity evidence fails closed.
    """

    files = _resolve_portable_inputs(paths)
    selected_sessions = _validate_session_filter(session_ids)
    by_identity: dict[tuple[str, int, int], PassiveCANRecord] = {}
    source_files: list[dict[str, Any]] = []
    source_bundles: dict[str, dict[str, Any]] = {}
    portable_records = 0
    non_can_frames = 0
    decoded_observations = 0
    exact_duplicates = 0
    preferred_flash_replacements = 0

    for source in files:
        raw_file = source.data
        file_records = 0
        for line_number, line in enumerate(raw_file.splitlines(), start=1):
            if not line.strip():
                continue
            file_records += 1
            portable_records += 1
            if portable_records > MAX_RECORDS:
                raise PortableCANError(
                    "Portable evidence exceeds the analysis record limit."
                )
            location = f"{source.name}:{line_number}"
            document = _load_document(line, location)
            frame, source_id, source_role, ingested_at = _validated_frame(
                document, location
            )
            if frame.message_type not in CAN_MESSAGE_TYPES:
                non_can_frames += 1
                continue
            if source_role != "OBD_CAN":
                raise PortableCANError(
                    f"{location}: a CAN envelope is not attributed to the OBD_CAN source role."
                )
            try:
                observations = _decode_wire_observations(frame, source_id)
            except Exception as error:
                raise PortableCANError(
                    f"{location}: CAN payload validation failed: {error}"
                ) from error
            evidence_source = (
                "ble-live"
                if frame.message_type == LIVE_CAN_MESSAGE_TYPE
                else "gateway-flash"
            )
            for observation in observations:
                decoded_observations += 1
                if decoded_observations > MAX_RECORDS:
                    raise PortableCANError(
                        "Decoded portable CAN observations exceed the analysis record limit."
                    )
                observation = replace(
                    observation,
                    evidence_source=evidence_source,
                    ingested_at=ingested_at,
                )
                if not observation.listen_only:
                    raise PortableCANError(
                        f"{location}: recovered CAN evidence does not retain listen-only proof."
                    )
                if (
                    selected_sessions
                    and observation.session_id not in selected_sessions
                ):
                    continue
                existing = by_identity.get(observation.identity)
                if existing is None:
                    if len(by_identity) >= MAX_RECORDS:
                        raise PortableCANError(
                            "Recovered portable CAN observations exceed the analysis record limit."
                        )
                    by_identity[observation.identity] = observation
                    continue
                if _record_semantic_tuple(existing) != _record_semantic_tuple(
                    observation
                ):
                    raise PortableCANError(
                        f"{location}: conflicting observation identity {observation.identity}."
                    )
                exact_duplicates += 1
                if (
                    existing.evidence_source == "ble-live"
                    and observation.evidence_source == "gateway-flash"
                ):
                    by_identity[observation.identity] = observation
                    preferred_flash_replacements += 1
        source_file = {
            "name": source.name,
            "byte_count": len(raw_file),
            "record_count": file_records,
            "sha256": hashlib.sha256(raw_file).hexdigest(),
        }
        if source.bundle_provenance is not None:
            source_file["source_bundle_sha256"] = source.bundle_provenance["sha256"]
            source_file["source_bundle_manifest_sha256"] = source.bundle_provenance[
                "manifest_sha256"
            ]
            existing_bundle = source_bundles.setdefault(
                source.bundle_provenance["sha256"], source.bundle_provenance
            )
            if existing_bundle != source.bundle_provenance:
                raise PortableCANError(
                    "Portable evidence repeats a bundle digest with conflicting provenance."
                )
        source_files.append(source_file)

    records = sorted(
        by_identity.values(),
        key=lambda record: (
            record.gateway_id,
            record.session_id,
            record.monotonic_microseconds,
            record.source_sequence,
        ),
    )
    if not records:
        detail = " for the selected session filter" if selected_sessions else ""
        raise PortableCANError(f"No portable CAN observations were found{detail}.")
    statistics = {
        "portable_records": portable_records,
        "validated_envelopes": portable_records,
        "non_can_frames": non_can_frames,
        "decoded_can_observations": decoded_observations,
        "exact_duplicate_observations": exact_duplicates,
        "preferred_gateway_flash_replacements": preferred_flash_replacements,
        "recovered_unique_observations": len(records),
        "sessions": len({(record.gateway_id, record.session_id) for record in records}),
        "unique_identifiers": len(
            {(record.identifier, record.extended) for record in records}
        ),
        "listen_only_observations": sum(record.listen_only for record in records),
        "ble_live_observations": sum(
            record.evidence_source == "ble-live" for record in records
        ),
        "gateway_flash_observations": sum(
            record.evidence_source == "gateway-flash" for record in records
        ),
        "bitrates_bps": sorted({record.bitrate_bps for record in records}),
    }
    return records, {
        "source_files": source_files,
        "source_bundles": list(source_bundles.values()),
        "session_filter": sorted(selected_sessions),
        "statistics": statistics,
    }


def extract_portable_can(
    paths: Iterable[Path],
    output: Path,
    *,
    session_ids: Sequence[int] = (),
) -> dict[str, Any]:
    """Create a new checksum-inventoried projection without overwriting source evidence."""

    output = output.resolve()
    if output.exists():
        raise PortableCANError(
            f"Portable CAN extraction output already exists: {output}"
        )
    records, context = load_portable_can_records(paths, session_ids=session_ids)
    staging = output.parent / f".{output.name}.staging-{uuid.uuid4().hex}"
    if staging.exists():
        raise PortableCANError(
            f"Portable CAN extraction staging path already exists: {staging}"
        )

    try:
        grouped: dict[tuple[str, int], list[PassiveCANRecord]] = {}
        for record in records:
            grouped.setdefault((record.gateway_id, record.session_id), []).append(
                record
            )

        output_files: list[dict[str, Any]] = []
        for (gateway_id, session_id), session_records in sorted(grouped.items()):
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", gateway_id):
                raise PortableCANError(
                    f"Recovered gateway ID is unsafe for output: {gateway_id!r}"
                )
            relative = Path("sessions") / gateway_id / f"{session_id}.ndjson"
            path = staging / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = b"".join(
                json.dumps(
                    {
                        "contract": RECOVERED_OBSERVATION_CONTRACT,
                        "contract_version": RECOVERED_OBSERVATION_VERSION,
                        "source_classification": SOURCE_CLASSIFICATION,
                        "vehicle_claims_authorized": False,
                        "observation": _record_document(record),
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
                + b"\n"
                for record in session_records
            )
            path.write_bytes(payload)
            output_files.append(
                {
                    "path": relative.as_posix(),
                    "gateway_id": gateway_id,
                    "session_id": session_id,
                    "record_count": len(session_records),
                    "byte_count": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            )

        manifest = {
            "contract": EXTRACTION_CONTRACT,
            "contract_version": EXTRACTION_VERSION,
            "source_classification": SOURCE_CLASSIFICATION,
            "vehicle_claims_authorized": False,
            "source_files": context["source_files"],
            "source_bundles": context["source_bundles"],
            "session_filter": context["session_filter"],
            "statistics": context["statistics"],
            "output_files": output_files,
            "display_policy": {
                "required_label": REQUIRED_DISPLAY_LABEL,
                "provenance": (
                    "CRC- and SHA-validated iOS portable VHOS envelopes projected into their "
                    "original passive CAN observation contract."
                ),
                "prohibited_claims": [
                    "live vehicle state",
                    "accepted CAN signal meaning",
                    "vehicle health conclusion",
                    "control authority",
                ],
            },
        }
        staging.mkdir(parents=True, exist_ok=True)
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        recovered, _ = load_recovered_can_extraction(staging)
        if recovered != records:
            raise PortableCANError(
                "Recovered portable CAN staging output failed its exact read-back check."
            )
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staging, output)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging)
        raise

    return manifest


def load_recovered_can_extraction(
    root: Path,
) -> tuple[list[PassiveCANRecord], dict[str, Any]]:
    """Read a complete recovery projection without laundering its authority boundary."""

    root = root.resolve()
    if not root.is_dir():
        raise PortableCANError(f"Recovered CAN extraction does not exist: {root}")
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise PortableCANError(
            "Recovered CAN extraction manifest is missing or unsafe."
        )
    manifest_size = manifest_path.stat().st_size
    if manifest_size > MAX_SYNC_MANIFEST_BYTES:
        raise PortableCANError(
            "Recovered CAN extraction manifest exceeds the size limit."
        )
    manifest_bytes = manifest_path.read_bytes()
    manifest = _load_document(manifest_bytes, f"{root.name}:manifest.json")
    validated_manifest = _validate_extraction_manifest(manifest, root.name)
    output_files = validated_manifest["output_files"]

    actual_files: set[str] = set()
    for candidate in root.rglob("*"):
        if candidate.is_symlink():
            raise PortableCANError(
                f"{root.name}: recovered extraction contains a symbolic link."
            )
        if candidate.is_file():
            actual_files.add(candidate.relative_to(root).as_posix())
            if len(actual_files) > MAX_SYNC_ENTRY_COUNT:
                raise PortableCANError(
                    f"{root.name}: recovered extraction contains too many files."
                )
    expected_files = {"manifest.json", *(item["path"] for item in output_files)}
    if actual_files != expected_files:
        raise PortableCANError(
            f"{root.name}: recovered extraction files do not exactly match its manifest."
        )

    records: list[PassiveCANRecord] = []
    identities: set[tuple[str, int, int]] = set()
    source_files: list[dict[str, Any]] = []
    total_bytes = manifest_size
    for declaration in output_files:
        path = root / declaration["path"]
        file_size = path.stat().st_size
        total_bytes += file_size
        if total_bytes > MAX_ANALYSIS_TOTAL_BYTES:
            raise PortableCANError(
                f"{root.name}: recovered extraction exceeds the aggregate size limit."
            )
        if file_size != declaration["byte_count"]:
            raise PortableCANError(
                f"{root.name}: recovered extraction byte count mismatch."
            )
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != declaration["sha256"]:
            raise PortableCANError(
                f"{root.name}: recovered extraction SHA-256 mismatch."
            )
        file_records = 0
        for line_number, line in enumerate(raw.splitlines(), start=1):
            if not line.strip():
                continue
            file_records += 1
            if len(records) >= MAX_RECORDS:
                raise PortableCANError(
                    "Recovered portable CAN observations exceed the analysis record limit."
                )
            location = f"{declaration['path']}:{line_number}"
            wrapper = _load_document(line, location)
            if set(wrapper) != RECOVERED_OBSERVATION_KEYS:
                raise PortableCANError(
                    f"{location}: recovered observation fields are invalid."
                )
            if (
                wrapper.get("contract") != RECOVERED_OBSERVATION_CONTRACT
                or wrapper.get("contract_version") != RECOVERED_OBSERVATION_VERSION
                or wrapper.get("source_classification") != SOURCE_CLASSIFICATION
                or wrapper.get("vehicle_claims_authorized") is not False
            ):
                raise PortableCANError(
                    f"{location}: recovered observation authority boundary is invalid."
                )
            observation_document = wrapper.get("observation")
            if (
                not isinstance(observation_document, dict)
                or set(observation_document) != PASSIVE_OBSERVATION_KEYS
            ):
                raise PortableCANError(
                    f"{location}: recovered passive observation fields are invalid."
                )
            try:
                record = PassiveCANRecord.from_document(
                    observation_document, line_number=line_number
                )
            except Exception as error:
                raise PortableCANError(
                    f"{location}: recovered passive observation is invalid: {error}"
                ) from error
            if record.gateway_id != declaration["gateway_id"] or (
                record.session_id != declaration["session_id"]
            ):
                raise PortableCANError(
                    f"{location}: recovered observation lineage does not match its file declaration."
                )
            if record.identity in identities:
                raise PortableCANError(
                    f"{location}: duplicate recovered observation identity {record.identity}."
                )
            identities.add(record.identity)
            records.append(record)
        if file_records != declaration["record_count"]:
            raise PortableCANError(
                f"{root.name}: recovered extraction record count mismatch."
            )
        source_files.append(
            {
                "name": declaration["path"],
                "byte_count": len(raw),
                "record_count": file_records,
                "sha256": declaration["sha256"],
            }
        )
    if not records:
        raise PortableCANError("No recovered portable CAN observations were found.")
    _validate_loaded_extraction_statistics(manifest["statistics"], records, root.name)
    return records, {
        "source_classification": SOURCE_CLASSIFICATION,
        "vehicle_claims_authorized": False,
        "required_display_label": REQUIRED_DISPLAY_LABEL,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "extraction_manifest": {
            "name": "manifest.json",
            "contract": EXTRACTION_CONTRACT,
            "contract_version": EXTRACTION_VERSION,
            "byte_count": manifest_size,
            "sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        },
        "source_files": source_files,
        "original_source_files": copy.deepcopy(validated_manifest["source_files"]),
        "source_bundles": copy.deepcopy(validated_manifest["source_bundles"]),
        "output_files": copy.deepcopy(output_files),
    }


def _validate_extraction_manifest(
    manifest: dict[str, Any], extraction_name: str
) -> dict[str, Any]:
    expected_keys = {
        "contract",
        "contract_version",
        "source_classification",
        "vehicle_claims_authorized",
        "source_files",
        "source_bundles",
        "session_filter",
        "statistics",
        "output_files",
        "display_policy",
    }
    if set(manifest) != expected_keys:
        raise PortableCANError(
            f"{extraction_name}: recovered extraction manifest fields are invalid."
        )
    if (
        manifest.get("contract") != EXTRACTION_CONTRACT
        or manifest.get("contract_version") != EXTRACTION_VERSION
        or manifest.get("source_classification") != SOURCE_CLASSIFICATION
        or manifest.get("vehicle_claims_authorized") is not False
    ):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction authority boundary is invalid."
        )
    source_files = _validate_extraction_source_files(
        manifest.get("source_files"), extraction_name
    )
    source_bundles = _validate_extraction_source_bundles(
        manifest.get("source_bundles"), extraction_name
    )
    _cross_bind_extraction_sources(source_files, source_bundles, extraction_name)
    session_filter = manifest.get("session_filter")
    if (
        not isinstance(session_filter, list)
        or any(
            isinstance(session_id, bool)
            or not isinstance(session_id, int)
            or not 0 <= session_id <= 0xFFFF_FFFF
            for session_id in session_filter
        )
        or session_filter != sorted(set(session_filter))
    ):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction session filter is invalid."
        )
    statistics = _validate_extraction_statistics(
        manifest.get("statistics"), source_files, extraction_name
    )
    display_policy = manifest.get("display_policy")
    expected_prohibited_claims = [
        "live vehicle state",
        "accepted CAN signal meaning",
        "vehicle health conclusion",
        "control authority",
    ]
    if (
        not isinstance(display_policy, dict)
        or set(display_policy) != {"required_label", "provenance", "prohibited_claims"}
        or display_policy.get("required_label") != REQUIRED_DISPLAY_LABEL
        or not isinstance(display_policy.get("provenance"), str)
        or not display_policy["provenance"]
        or display_policy.get("prohibited_claims") != expected_prohibited_claims
    ):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction display policy is invalid."
        )
    output_files = manifest.get("output_files")
    if not isinstance(output_files, list) or not 1 <= len(output_files) <= 32:
        raise PortableCANError(
            f"{extraction_name}: recovered extraction output inventory is invalid."
        )
    expected_output_keys = {
        "path",
        "gateway_id",
        "session_id",
        "record_count",
        "byte_count",
        "sha256",
    }
    validated: list[dict[str, Any]] = []
    declared_total_bytes = 0
    declared_total_records = 0
    for declaration in output_files:
        if (
            not isinstance(declaration, dict)
            or set(declaration) != expected_output_keys
        ):
            raise PortableCANError(
                f"{extraction_name}: recovered output declaration is invalid."
            )
        path = declaration.get("path")
        gateway_id = declaration.get("gateway_id")
        session_id = declaration.get("session_id")
        record_count = declaration.get("record_count")
        byte_count = declaration.get("byte_count")
        sha256 = declaration.get("sha256")
        if not isinstance(path, str):
            raise PortableCANError(
                f"{extraction_name}: recovered output path is invalid."
            )
        _validate_archive_path(path, extraction_name)
        if (
            not isinstance(gateway_id, str)
            or re.fullmatch(r"[A-Za-z0-9._-]{1,128}", gateway_id) is None
            or isinstance(session_id, bool)
            or not isinstance(session_id, int)
            or not 0 <= session_id <= 0xFFFF_FFFF
            or isinstance(record_count, bool)
            or not isinstance(record_count, int)
            or not 1 <= record_count <= MAX_RECORDS
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or not 1 <= byte_count <= MAX_ANALYSIS_ENTRY_BYTES
            or not isinstance(sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", sha256) is None
            or Path(path).parts != ("sessions", gateway_id, f"{session_id}.ndjson")
        ):
            raise PortableCANError(
                f"{extraction_name}: recovered output integrity metadata is invalid."
            )
        declared_total_bytes += byte_count
        declared_total_records += record_count
        if declared_total_bytes > MAX_ANALYSIS_TOTAL_BYTES:
            raise PortableCANError(
                f"{extraction_name}: recovered output exceeds the aggregate size limit."
            )
        if declared_total_records > MAX_RECORDS:
            raise PortableCANError(
                f"{extraction_name}: recovered output exceeds the record limit."
            )
        validated.append(declaration)
    if len({item["path"] for item in validated}) != len(validated):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction repeats an output path."
        )
    if declared_total_records != statistics["recovered_unique_observations"]:
        raise PortableCANError(
            f"{extraction_name}: recovered output record inventory is inconsistent."
        )
    if len(validated) != statistics["sessions"]:
        raise PortableCANError(
            f"{extraction_name}: recovered output session inventory is inconsistent."
        )
    return {
        "source_files": source_files,
        "source_bundles": source_bundles,
        "output_files": validated,
    }


def _validate_extraction_source_files(
    value: Any, extraction_name: str
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_PORTABLE_SOURCE_FILES:
        raise PortableCANError(
            f"{extraction_name}: recovered source-file inventory is invalid."
        )
    basic_keys = {"name", "byte_count", "record_count", "sha256"}
    bundled_keys = basic_keys | {
        "source_bundle_sha256",
        "source_bundle_manifest_sha256",
    }
    validated: list[dict[str, Any]] = []
    total_bytes = 0
    total_records = 0
    for declaration in value:
        if not isinstance(declaration, dict) or frozenset(declaration) not in {
            frozenset(basic_keys),
            frozenset(bundled_keys),
        }:
            raise PortableCANError(
                f"{extraction_name}: recovered source-file declaration is invalid."
            )
        name = declaration.get("name")
        byte_count = declaration.get("byte_count")
        record_count = declaration.get("record_count")
        sha256 = declaration.get("sha256")
        if (
            not _is_provenance_name(name)
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or not 0 <= byte_count <= MAX_SYNC_ENTRY_BYTES
            or isinstance(record_count, bool)
            or not isinstance(record_count, int)
            or not 0 <= record_count <= MAX_SYNC_RECORDS
            or not _is_sha256(sha256)
        ):
            raise PortableCANError(
                f"{extraction_name}: recovered source-file integrity metadata is invalid."
            )
        if set(declaration) == bundled_keys and (
            not _is_sha256(declaration.get("source_bundle_sha256"))
            or not _is_sha256(declaration.get("source_bundle_manifest_sha256"))
        ):
            raise PortableCANError(
                f"{extraction_name}: recovered source-file bundle binding is invalid."
            )
        total_bytes += byte_count
        total_records += record_count
        if total_bytes > MAX_ANALYSIS_TOTAL_BYTES or total_records > MAX_RECORDS:
            raise PortableCANError(
                f"{extraction_name}: recovered source-file inventory exceeds its limits."
            )
        validated.append(declaration)
    if len({item["name"] for item in validated}) != len(validated):
        raise PortableCANError(
            f"{extraction_name}: recovered source-file inventory repeats a name."
        )
    return validated


def _validate_extraction_source_bundles(
    value: Any, extraction_name: str
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > MAX_PORTABLE_SOURCE_FILES:
        raise PortableCANError(
            f"{extraction_name}: recovered source-bundle inventory is invalid."
        )
    expected_keys = {
        "name",
        "byte_count",
        "sha256",
        "manifest_sha256",
        "contract_version",
        "recovery",
    }
    validated: list[dict[str, Any]] = []
    for declaration in value:
        if not isinstance(declaration, dict) or set(declaration) != expected_keys:
            raise PortableCANError(
                f"{extraction_name}: recovered source-bundle declaration is invalid."
            )
        version = declaration.get("contract_version")
        byte_count = declaration.get("byte_count")
        recovery = declaration.get("recovery")
        if (
            not _is_provenance_name(declaration.get("name"))
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or not 1 <= byte_count <= MAX_SYNC_ARCHIVE_BYTES
            or not _is_sha256(declaration.get("sha256"))
            or not _is_sha256(declaration.get("manifest_sha256"))
            or version not in SYNC_BUNDLE_VERSIONS
        ):
            raise PortableCANError(
                f"{extraction_name}: recovered source-bundle integrity metadata is invalid."
            )
        if version == "1.0.0":
            if recovery is not None:
                raise PortableCANError(
                    f"{extraction_name}: v1 source bundle carries recovery metadata."
                )
        elif not _is_valid_recovery_metadata(recovery):
            raise PortableCANError(
                f"{extraction_name}: v2 source-bundle recovery metadata is invalid."
            )
        validated.append(declaration)
    if len({item["name"] for item in validated}) != len(validated) or len(
        {item["sha256"] for item in validated}
    ) != len(validated):
        raise PortableCANError(
            f"{extraction_name}: recovered source-bundle inventory is ambiguous."
        )
    return validated


def _cross_bind_extraction_sources(
    source_files: list[dict[str, Any]],
    source_bundles: list[dict[str, Any]],
    extraction_name: str,
) -> None:
    bundles_by_sha = {bundle["sha256"]: bundle for bundle in source_bundles}
    files_by_bundle: dict[str, list[dict[str, Any]]] = {
        digest: [] for digest in bundles_by_sha
    }
    for source_file in source_files:
        bundle_sha256 = source_file.get("source_bundle_sha256")
        if bundle_sha256 is None:
            continue
        bundle = bundles_by_sha.get(bundle_sha256)
        if (
            bundle is None
            or source_file["source_bundle_manifest_sha256"] != bundle["manifest_sha256"]
            or not source_file["name"].startswith(f"{bundle['name']}!")
        ):
            raise PortableCANError(
                f"{extraction_name}: recovered source bundle/file binding is invalid."
            )
        files_by_bundle[bundle_sha256].append(source_file)

    for bundle_sha256, bundle in bundles_by_sha.items():
        bundled_files = files_by_bundle[bundle_sha256]
        if not bundled_files:
            raise PortableCANError(
                f"{extraction_name}: recovered source bundle has no matching source file."
            )
        if bundle["contract_version"] == "2.0.0":
            expected_name = f"{bundle['name']}!segments/logical-frames.ndjson"
            if (
                len(bundled_files) != 1
                or bundled_files[0]["name"] != expected_name
                or bundled_files[0]["sha256"]
                != bundle["recovery"]["source_ledger_sha256"]
            ):
                raise PortableCANError(
                    f"{extraction_name}: recovered v2 source ledger binding is invalid."
                )


def _validate_extraction_statistics(
    value: Any, source_files: list[dict[str, Any]], extraction_name: str
) -> dict[str, Any]:
    expected_keys = {
        "portable_records",
        "validated_envelopes",
        "non_can_frames",
        "decoded_can_observations",
        "exact_duplicate_observations",
        "preferred_gateway_flash_replacements",
        "recovered_unique_observations",
        "sessions",
        "unique_identifiers",
        "listen_only_observations",
        "ble_live_observations",
        "gateway_flash_observations",
        "bitrates_bps",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise PortableCANError(
            f"{extraction_name}: recovered extraction statistics are invalid."
        )
    integer_keys = expected_keys - {"bitrates_bps"}
    if any(
        isinstance(value[key], bool)
        or not isinstance(value[key], int)
        or not 0 <= value[key] <= MAX_RECORDS
        for key in integer_keys
    ):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction statistics are invalid."
        )
    bitrates = value["bitrates_bps"]
    if (
        not isinstance(bitrates, list)
        or bitrates != sorted(set(bitrates))
        or any(bitrate not in {250_000, 500_000} for bitrate in bitrates)
    ):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction bitrate statistics are invalid."
        )
    if (
        value["portable_records"]
        != sum(source_file["record_count"] for source_file in source_files)
        or value["validated_envelopes"] != value["portable_records"]
        or value["non_can_frames"] > value["portable_records"]
        or value["decoded_can_observations"] < value["recovered_unique_observations"]
        or value["preferred_gateway_flash_replacements"]
        > value["exact_duplicate_observations"]
        or value["listen_only_observations"] != value["recovered_unique_observations"]
        or value["ble_live_observations"] + value["gateway_flash_observations"]
        != value["recovered_unique_observations"]
    ):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction statistics are inconsistent."
        )
    return value


def _is_provenance_name(value: Any) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= MAX_PROVENANCE_NAME_CHARACTERS
        and value.isprintable()
    )


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _is_valid_recovery_metadata(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value)
        == {"classification", "vehicle_claims_authorized", "source_ledger_sha256"}
        and value.get("classification") == SOURCE_CLASSIFICATION
        and value.get("vehicle_claims_authorized") is False
        and _is_sha256(value.get("source_ledger_sha256"))
    )


def _validate_loaded_extraction_statistics(
    statistics: dict[str, Any],
    records: list[PassiveCANRecord],
    extraction_name: str,
) -> None:
    actual = {
        "recovered_unique_observations": len(records),
        "sessions": len({(record.gateway_id, record.session_id) for record in records}),
        "unique_identifiers": len(
            {(record.identifier, record.extended) for record in records}
        ),
        "listen_only_observations": sum(record.listen_only for record in records),
        "ble_live_observations": sum(
            record.evidence_source == "ble-live" for record in records
        ),
        "gateway_flash_observations": sum(
            record.evidence_source == "gateway-flash" for record in records
        ),
        "bitrates_bps": sorted({record.bitrate_bps for record in records}),
    }
    if any(statistics[key] != value for key, value in actual.items()):
        raise PortableCANError(
            f"{extraction_name}: recovered extraction statistics do not match its records."
        )


def _resolve_portable_inputs(paths: Iterable[Path]) -> list[_PortableSource]:
    files: list[Path] = []
    for raw_path in paths:
        path = raw_path.resolve()
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(
                candidate
                for candidate in path.rglob("*.vhossync")
                if candidate.is_file()
            )
            files.extend(
                candidate
                for candidate in path.rglob("logical-frames.ndjson")
                if candidate.is_file()
            )
        else:
            raise PortableCANError(f"Portable evidence input does not exist: {path}")
    unique = sorted(set(files))
    if not unique:
        raise PortableCANError(
            "No .vhossync or logical-frames.ndjson portable evidence was found."
        )
    if len(unique) > MAX_PORTABLE_SOURCE_FILES:
        raise PortableCANError("Portable evidence contains too many source files.")
    sources: list[_PortableSource] = []
    source_bytes = 0
    for path in unique:
        if path.suffix.lower() == ".vhossync":
            loaded = _load_sync_bundle(path)
        else:
            loaded = [
                _PortableSource(
                    name=path.name,
                    data=_read_bounded_file(
                        path,
                        maximum_bytes=MAX_SYNC_ENTRY_BYTES,
                        description="portable logical-frame ledger",
                    ),
                )
            ]
        source_bytes += sum(len(source.data) for source in loaded)
        if source_bytes > MAX_ANALYSIS_TOTAL_BYTES:
            raise PortableCANError(
                "Portable evidence exceeds the aggregate source size limit."
            )
        sources.extend(loaded)
    return sources


def _load_sync_bundle(path: Path) -> list[_PortableSource]:
    archive = _read_bounded_file(
        path,
        maximum_bytes=MAX_SYNC_ARCHIVE_BYTES,
        description=".vhossync archive",
    )
    try:
        with zipfile.ZipFile(io.BytesIO(archive), "r") as bundle:
            infos = bundle.infolist()
            if len(infos) > MAX_SYNC_ENTRY_COUNT:
                raise PortableCANError(
                    f"{path.name}: bundle contains too many entries."
                )
            names = [info.filename for info in infos]
            if len(names) != len(set(names)):
                raise PortableCANError(
                    f"{path.name}: bundle contains duplicate entries."
                )
            for info in infos:
                _validate_archive_path(info.filename, path.name)
                if info.is_dir():
                    raise PortableCANError(
                        f"{path.name}: bundle contains a directory entry."
                    )
                if info.compress_type != zipfile.ZIP_STORED:
                    raise PortableCANError(
                        f"{path.name}: bundle compression is unsupported."
                    )
                if info.file_size > MAX_SYNC_ENTRY_BYTES:
                    raise PortableCANError(
                        f"{path.name}: bundle entry exceeds the size limit."
                    )
            if sum(info.file_size for info in infos) > MAX_SYNC_TOTAL_BYTES:
                raise PortableCANError(
                    f"{path.name}: bundle exceeds the aggregate uncompressed size limit."
                )
            info_by_name = {info.filename: info for info in infos}
            manifest_info = info_by_name.get(SYNC_MANIFEST_PATH)
            if manifest_info is None:
                raise PortableCANError(f"{path.name}: bundle manifest is missing.")
            if manifest_info.file_size > MAX_SYNC_MANIFEST_BYTES:
                raise PortableCANError(
                    f"{path.name}: bundle manifest exceeds the size limit."
                )
            manifest_bytes = _read_zip_entry(
                bundle,
                manifest_info,
                path.name,
                maximum_bytes=MAX_SYNC_MANIFEST_BYTES,
            )
            manifest = _load_document(
                manifest_bytes, f"{path.name}:{SYNC_MANIFEST_PATH}"
            )
            version, segments, recovery = _validate_sync_manifest(manifest, path.name)
            declared = {SYNC_MANIFEST_PATH, *(segment["path"] for segment in segments)}
            if set(info_by_name) != declared:
                raise PortableCANError(
                    f"{path.name}: bundle entries do not exactly match its manifest."
                )
            entries = {
                segment["path"]: _read_zip_entry(
                    bundle,
                    info_by_name[segment["path"]],
                    path.name,
                    maximum_bytes=segment["byte_count"],
                )
                for segment in segments
            }
    except (zipfile.BadZipFile, OSError, RuntimeError) as error:
        raise PortableCANError(
            f"{path.name}: invalid .vhossync ZIP archive."
        ) from error

    bundle_sha256 = hashlib.sha256(archive).hexdigest()
    provenance = {
        "name": path.name,
        "byte_count": len(archive),
        "sha256": bundle_sha256,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "contract_version": version,
        "recovery": recovery,
    }
    sources: list[_PortableSource] = []
    for segment in segments:
        segment_bytes = entries[segment["path"]]
        if len(segment_bytes) != segment["byte_count"]:
            raise PortableCANError(f"{path.name}: segment byte count mismatch.")
        if hashlib.sha256(segment_bytes).hexdigest() != segment["sha256"]:
            raise PortableCANError(f"{path.name}: segment SHA-256 mismatch.")
        record_count = sum(bool(line.strip()) for line in segment_bytes.splitlines())
        if record_count != segment["record_count"]:
            raise PortableCANError(f"{path.name}: segment record count mismatch.")
        sources.append(
            _PortableSource(
                name=f"{path.name}!{segment['path']}",
                data=segment_bytes,
                bundle_provenance=provenance,
            )
        )
    return sources


def _validate_sync_manifest(
    manifest: dict[str, Any], bundle_name: str
) -> tuple[str, list[dict[str, Any]], dict[str, Any] | None]:
    common_keys = {
        "contract",
        "contract_version",
        "bundle_id",
        "created_at",
        "creator",
        "segments",
    }
    if manifest.get("contract") != SYNC_BUNDLE_CONTRACT:
        raise PortableCANError(f"{bundle_name}: bundle contract is unsupported.")
    version = manifest.get("contract_version")
    if version not in SYNC_BUNDLE_VERSIONS:
        raise PortableCANError(
            f"{bundle_name}: bundle contract version is unsupported."
        )
    allowed_keys = common_keys | ({"recovery"} if version == "2.0.0" else set())
    if set(manifest) != allowed_keys:
        raise PortableCANError(f"{bundle_name}: bundle manifest fields are invalid.")
    try:
        uuid.UUID(_required_string(manifest, "bundle_id", bundle_name))
        _required_wall_time(manifest, "created_at", bundle_name)
    except (PortableCANError, ValueError) as error:
        raise PortableCANError(
            f"{bundle_name}: bundle identity or timestamp is invalid."
        ) from error

    creator = manifest.get("creator")
    creator_keys = {"platform", "application_id", "application_version", "device_model"}
    if not isinstance(creator, dict) or set(creator) != creator_keys:
        raise PortableCANError(f"{bundle_name}: bundle creator is invalid.")
    if creator.get("platform") not in {"IOS", "ANDROID"}:
        raise PortableCANError(f"{bundle_name}: bundle creator is invalid.")
    try:
        _bounded_string_value(
            creator.get("application_id"),
            "application_id",
            bundle_name,
            MAX_CREATOR_APPLICATION_ID_CHARACTERS,
        )
        _bounded_string_value(
            creator.get("application_version"),
            "application_version",
            bundle_name,
            MAX_CREATOR_APPLICATION_VERSION_CHARACTERS,
        )
        _bounded_string_value(
            creator.get("device_model"),
            "device_model",
            bundle_name,
            MAX_CREATOR_DEVICE_MODEL_CHARACTERS,
        )
    except PortableCANError as error:
        raise PortableCANError(f"{bundle_name}: bundle creator is invalid.") from error

    segments = manifest.get("segments")
    if not isinstance(segments, list) or not 1 <= len(segments) <= 32:
        raise PortableCANError(f"{bundle_name}: bundle segments are invalid.")
    segment_keys = {"path", "media_type", "sha256", "byte_count", "record_count"}
    validated_segments: list[dict[str, Any]] = []
    for segment in segments:
        if not isinstance(segment, dict) or set(segment) != segment_keys:
            raise PortableCANError(
                f"{bundle_name}: bundle segment declaration is invalid."
            )
        segment_path = segment.get("path")
        if not isinstance(segment_path, str):
            raise PortableCANError(f"{bundle_name}: bundle segment path is invalid.")
        _validate_archive_path(segment_path, bundle_name)
        if (
            len(segment_path) > 256
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", segment_path) is None
        ):
            raise PortableCANError(f"{bundle_name}: bundle segment path is invalid.")
        sha256 = segment.get("sha256")
        byte_count = segment.get("byte_count")
        record_count = segment.get("record_count")
        if (
            segment.get("media_type") != "application/x-ndjson"
            or not isinstance(sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", sha256) is None
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or not 0 <= byte_count <= MAX_SYNC_ENTRY_BYTES
            or isinstance(record_count, bool)
            or not isinstance(record_count, int)
            or not 0 <= record_count <= MAX_SYNC_RECORDS
        ):
            raise PortableCANError(
                f"{bundle_name}: bundle segment integrity metadata is invalid."
            )
        validated_segments.append(segment)
    if len({segment["path"] for segment in validated_segments}) != len(
        validated_segments
    ):
        raise PortableCANError(f"{bundle_name}: bundle repeats a segment path.")
    if (
        sum(segment["byte_count"] for segment in validated_segments)
        > MAX_SYNC_TOTAL_BYTES
    ):
        raise PortableCANError(
            f"{bundle_name}: declared segments exceed the aggregate size limit."
        )
    if sum(segment["record_count"] for segment in validated_segments) > MAX_SYNC_RECORDS:
        raise PortableCANError(
            f"{bundle_name}: declared segments exceed the aggregate record limit."
        )

    recovery = manifest.get("recovery")
    if version == "1.0.0":
        return version, validated_segments, None
    recovery_keys = {
        "classification",
        "vehicle_claims_authorized",
        "source_ledger_sha256",
    }
    if not isinstance(recovery, dict) or set(recovery) != recovery_keys:
        raise PortableCANError(
            f"{bundle_name}: recovery provenance is missing or invalid."
        )
    source_sha256 = recovery.get("source_ledger_sha256")
    if (
        recovery.get("classification") != SOURCE_CLASSIFICATION
        or recovery.get("vehicle_claims_authorized") is not False
        or not isinstance(source_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", source_sha256) is None
        or len(validated_segments) != 1
        or validated_segments[0]["path"] != "segments/logical-frames.ndjson"
        or validated_segments[0]["sha256"] != source_sha256
    ):
        raise PortableCANError(
            f"{bundle_name}: recovery provenance binding is invalid."
        )
    return version, validated_segments, recovery


def _validate_archive_path(path: str, bundle_name: str) -> None:
    components = path.split("/")
    if (
        not path
        or path.startswith("/")
        or "\\" in path
        or any(component in {"", ".", ".."} for component in components)
    ):
        raise PortableCANError(f"{bundle_name}: unsafe archive path {path!r}.")


def _read_zip_entry(
    bundle: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    bundle_name: str,
    *,
    maximum_bytes: int = MAX_SYNC_ENTRY_BYTES,
) -> bytes:
    try:
        with bundle.open(info, "r") as stream:
            data = stream.read(maximum_bytes + 1)
    except (zipfile.BadZipFile, OSError, RuntimeError) as error:
        raise PortableCANError(
            f"{bundle_name}: ZIP CRC validation failed for {info.filename}."
        ) from error
    if len(data) > maximum_bytes:
        raise PortableCANError(f"{bundle_name}: bundle entry exceeds the size limit.")
    return data


def _read_bounded_file(path: Path, *, maximum_bytes: int, description: str) -> bytes:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise PortableCANError(
            f"Unable to inspect {description}: {path.name}"
        ) from error
    if size > maximum_bytes:
        raise PortableCANError(f"{path.name}: {description} exceeds the size limit.")
    try:
        return path.read_bytes()
    except OSError as error:
        raise PortableCANError(f"Unable to read {description}: {path.name}") from error


def _validate_session_filter(session_ids: Sequence[int]) -> set[int]:
    selected: set[int] = set()
    for session_id in session_ids:
        if isinstance(session_id, bool) or not isinstance(session_id, int):
            raise PortableCANError("Portable CAN session filters must be integers.")
        if not 0 <= session_id <= 0xFFFF_FFFF:
            raise PortableCANError(
                f"Portable CAN session filter is out of range: {session_id}"
            )
        selected.add(session_id)
    return selected


def _load_document(line: bytes, location: str) -> dict[str, Any]:
    try:
        document = json.loads(line, object_pairs_hook=_unique_json_object)
    except _DuplicateJSONKeyError as error:
        raise PortableCANError(f"{location}: duplicate JSON field {error}.") from error
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PortableCANError(f"{location}: invalid JSON.") from error
    if not isinstance(document, dict):
        raise PortableCANError(f"{location}: portable frame must be an object.")
    return document


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise _DuplicateJSONKeyError(repr(key))
        document[key] = value
    return document


def _validated_frame(
    document: dict[str, Any], location: str
) -> tuple[Any, str, str, str]:
    if set(document) != PORTABLE_FRAME_KEYS:
        raise PortableCANError(f"{location}: portable frame fields are invalid.")
    if document.get("contract") != PORTABLE_CONTRACT:
        raise PortableCANError(f"{location}: portable frame contract is unsupported.")
    if document.get("contract_version") != PORTABLE_VERSION:
        raise PortableCANError(
            f"{location}: portable frame contract version is unsupported."
        )
    source_id = _bounded_string_value(
        document.get("source_id"),
        "source_id",
        location,
        MAX_PORTABLE_SOURCE_ID_CHARACTERS,
    )
    source_role = _required_string(document, "source_role", location)
    if source_role not in {"OBD_CAN", "AC_SENSOR"}:
        raise PortableCANError(f"{location}: source_role is invalid.")
    expected_sequence = _required_uint64_string(document, "source_sequence", location)
    expected_monotonic = _required_uint64_string(
        document, "source_monotonic_microseconds", location
    )
    expected_protocol_major = _required_byte(document, "protocol_major", location)
    expected_protocol_minor = _required_byte(document, "protocol_minor", location)
    expected_message_type = _required_byte(
        document, "message_type", location, minimum=1
    )
    expected_flags = _required_byte(document, "flags", location)
    ingested_at = _required_wall_time(document, "ingested_at", location)

    envelope_sha256 = _required_string(document, "envelope_sha256", location)
    if not re.fullmatch(r"[0-9a-f]{64}", envelope_sha256):
        raise PortableCANError(f"{location}: envelope_sha256 is invalid.")
    encoded = _required_string(document, "envelope_base64", location)
    if len(encoded) > MAX_PORTABLE_BASE64_CHARACTERS:
        raise PortableCANError(f"{location}: envelope_base64 is too long.")
    try:
        envelope = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise PortableCANError(f"{location}: envelope_base64 is invalid.") from error
    if hashlib.sha256(envelope).hexdigest() != envelope_sha256:
        raise PortableCANError(f"{location}: envelope SHA-256 mismatch.")

    decoder = GatewayFrameStreamDecoder()
    frames = decoder.append(envelope)
    if (
        len(frames) != 1
        or decoder.buffer
        or decoder.discarded_bytes
        or decoder.recoveries
        or decoder.corrupt_candidates
    ):
        raise PortableCANError(
            f"{location}: envelope is not one exact CRC-valid VHOS frame."
        )
    frame = frames[0]
    if (
        len(envelope) < 36
        or envelope[4] != expected_protocol_major
        or envelope[5] != expected_protocol_minor
        or frame.message_type != expected_message_type
        or envelope[7] != expected_flags
        or frame.sequence != expected_sequence
        or frame.monotonic_microseconds != expected_monotonic
    ):
        raise PortableCANError(
            f"{location}: portable metadata does not match the VHOS envelope."
        )
    return frame, source_id, source_role, ingested_at


def _required_string(document: dict[str, Any], key: str, location: str) -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value:
        raise PortableCANError(f"{location}: {key} must be a non-empty string.")
    return value


def _required_uint64_string(document: dict[str, Any], key: str, location: str) -> int:
    value = _required_string(document, key, location)
    if _CANONICAL_UINT64_RE.fullmatch(value) is None:
        raise PortableCANError(
            f"{location}: {key} must be a canonical unsigned decimal string."
        )
    parsed = int(value)
    if not 0 <= parsed <= 0xFFFF_FFFF_FFFF_FFFF:
        raise PortableCANError(f"{location}: {key} is out of range.")
    return parsed


def _required_byte(
    document: dict[str, Any], key: str, location: str, *, minimum: int = 0
) -> int:
    value = document.get(key)
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not minimum <= value <= 0xFF
    ):
        raise PortableCANError(f"{location}: {key} must be a byte.")
    return value


def _bounded_string_value(
    value: Any, key: str, location: str, maximum_characters: int
) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= maximum_characters:
        raise PortableCANError(
            f"{location}: {key} must contain 1 to {maximum_characters} characters."
        )
    return value


def _required_wall_time(document: dict[str, Any], key: str, location: str) -> str:
    value = _required_string(document, key, location)
    if _RFC3339_WALL_TIME_RE.fullmatch(value) is None:
        raise PortableCANError(f"{location}: {key} is not an RFC 3339 date-time.")
    normalized = value.replace("t", "T").replace("z", "+00:00").replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError("timestamp has no UTC offset")
    except ValueError as error:
        raise PortableCANError(f"{location}: {key} is invalid.") from error
    return value
