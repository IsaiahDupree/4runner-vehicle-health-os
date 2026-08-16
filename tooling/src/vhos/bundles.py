from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any, Iterable

from .contracts import ContractCatalog, ContractError
from .simulator import (
    SCENARIO_ID,
    SCENARIO_VERSION,
    SIMULATOR_VERSION,
    ScenarioCapture,
)


class BundleError(ValueError):
    pass


def canonical_json(document: dict[str, Any]) -> str:
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def write_simulator_bundle(
    capture: ScenarioCapture,
    destination: Path,
    *,
    replace: bool = False,
    catalog: ContractCatalog | None = None,
) -> dict[str, Any]:
    resolved = destination.resolve()
    if resolved.exists():
        if not replace:
            raise BundleError(f"Destination already exists: {resolved}")
        if not resolved.is_dir():
            raise BundleError(f"Refusing to replace a non-directory destination: {resolved}")
        _assert_replaceable_simulator_bundle(resolved)

    validator = catalog or ContractCatalog.load()
    for observation in capture.observations:
        validator.validate(observation)

    parent = resolved.parent
    parent.mkdir(parents=True, exist_ok=True)
    temp_directory = Path(tempfile.mkdtemp(prefix=f".{resolved.name}.", dir=parent))
    try:
        observations_bytes = _ndjson_bytes(capture.observations)
        segment_path = temp_directory / "observations.ndjson"
        segment_path.write_bytes(observations_bytes)
        segment_hash = hashlib.sha256(observations_bytes).hexdigest()

        first = capture.observations[0]
        last = capture.observations[-1]
        manifest = {
            "contract": "capture.bundle.manifest",
            "contract_version": "1.0.0",
            "capture_id": capture.capture_id,
            "vehicle_id": capture.vehicle_id,
            "created_at": first["wall_time"],
            "capture_window": {
                "start_monotonic_us": first["observed_at_monotonic_us"],
                "end_monotonic_us": last["observed_at_monotonic_us"],
                "start_wall_time": first["wall_time"],
                "end_wall_time": last["wall_time"],
            },
            "profile": {
                "kind": "SIMULATOR",
                "scenario_id": SCENARIO_ID,
                "scenario_version": SCENARIO_VERSION,
            },
            "source": {
                "kind": "SIMULATOR",
                "source_id": "sim.powertrain-state",
                "source_version": SIMULATOR_VERSION,
            },
            "segments": [
                {
                    "path": "observations.ndjson",
                    "media_type": "application/x-ndjson",
                    "schema": "raw.observation@1.0.0",
                    "sha256": segment_hash,
                    "byte_count": len(observations_bytes),
                    "record_count": len(capture.observations),
                }
            ],
            "statistics": {
                "received_records": len(capture.observations),
                "dropped_records": 0,
                "sequence_gaps": 0,
                "crc_failures": 0,
                "transport_reconnects": 0,
            },
            "versions": {"raw_observation_contract": "1.0.0"},
            "labels": list(capture.labels),
            "semantic_digest": segment_hash,
        }
        validator.validate(manifest)
        (temp_directory / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

        if resolved.exists():
            shutil.rmtree(resolved)
        os.replace(temp_directory, resolved)
        return manifest
    except Exception:
        shutil.rmtree(temp_directory, ignore_errors=True)
        raise


def load_validated_bundle(
    bundle_directory: Path,
    *,
    catalog: ContractCatalog | None = None,
) -> tuple[dict[str, Any], tuple[dict[str, Any], ...]]:
    directory = bundle_directory.resolve()
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        raise BundleError(f"Bundle manifest is missing: {manifest_path}")

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BundleError(f"Unable to read bundle manifest: {exc}") from exc

    validator = catalog or ContractCatalog.load()
    try:
        validator.validate(manifest)
    except ContractError as exc:
        raise BundleError(str(exc)) from exc

    observations: list[dict[str, Any]] = []
    for segment in manifest["segments"]:
        segment_path = _safe_segment_path(directory, segment["path"])
        try:
            payload = segment_path.read_bytes()
        except OSError as exc:
            raise BundleError(f"Unable to read segment {segment['path']}: {exc}") from exc
        _verify_segment_bytes(segment, payload)
        lines = payload.splitlines()
        if len(lines) != segment["record_count"]:
            raise BundleError(
                f"Segment {segment['path']} record count mismatch: expected {segment['record_count']}, got {len(lines)}"
            )
        for line_number, line in enumerate(lines, start=1):
            try:
                observation = json.loads(line)
                validator.validate(observation)
            except (json.JSONDecodeError, ContractError) as exc:
                raise BundleError(
                    f"Invalid observation in {segment['path']} line {line_number}: {exc}"
                ) from exc
            observations.append(observation)

    _verify_observation_sequence(manifest, observations)
    if manifest["statistics"]["received_records"] != len(observations):
        raise BundleError("Manifest received_records does not match decoded observation count")
    return manifest, tuple(observations)


def _ndjson_bytes(documents: Iterable[dict[str, Any]]) -> bytes:
    return ("".join(f"{canonical_json(document)}\n" for document in documents)).encode(
        "utf-8"
    )


def _assert_replaceable_simulator_bundle(directory: Path) -> None:
    manifest_path = directory / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BundleError(
            f"Refusing to replace a directory that is not an existing simulator bundle: {directory}"
        ) from exc
    if (
        manifest.get("contract") != "capture.bundle.manifest"
        or manifest.get("source", {}).get("kind") != "SIMULATOR"
    ):
        raise BundleError(
            f"Refusing to replace a directory that is not an existing simulator bundle: {directory}"
        )


def _safe_segment_path(directory: Path, relative_path: str) -> Path:
    candidate = (directory / relative_path).resolve()
    try:
        candidate.relative_to(directory)
    except ValueError as exc:
        raise BundleError(f"Segment path escapes bundle directory: {relative_path}") from exc
    if not candidate.is_file():
        raise BundleError(f"Bundle segment is missing: {relative_path}")
    return candidate


def _verify_segment_bytes(segment: dict[str, Any], payload: bytes) -> None:
    if len(payload) != segment["byte_count"]:
        raise BundleError(
            f"Segment {segment['path']} byte count mismatch: expected {segment['byte_count']}, got {len(payload)}"
        )
    actual_hash = hashlib.sha256(payload).hexdigest()
    if actual_hash != segment["sha256"]:
        raise BundleError(
            f"Segment {segment['path']} SHA-256 mismatch: expected {segment['sha256']}, got {actual_hash}"
        )


def _verify_observation_sequence(
    manifest: dict[str, Any], observations: list[dict[str, Any]]
) -> None:
    if not observations:
        raise BundleError("Capture bundle contains no observations")
    previous_sequence: int | None = None
    previous_time: int | None = None
    for observation in observations:
        if observation["capture_id"] != manifest["capture_id"]:
            raise BundleError("Observation capture_id does not match manifest")
        if observation["vehicle_id"] != manifest["vehicle_id"]:
            raise BundleError("Observation vehicle_id does not match manifest")

        payload_bytes = bytes.fromhex(observation["payload"]["data"])
        payload_hash = hashlib.sha256(payload_bytes).hexdigest()
        if payload_hash != observation["payload"]["sha256"]:
            raise BundleError(
                f"Observation {observation['observation_id']} payload SHA-256 mismatch"
            )

        sequence = observation["sequence"]
        monotonic_us = observation["observed_at_monotonic_us"]
        if previous_sequence is not None and sequence != previous_sequence + 1:
            raise BundleError(
                f"Non-contiguous observation sequence: {previous_sequence} -> {sequence}"
            )
        if previous_time is not None and monotonic_us <= previous_time:
            raise BundleError(
                f"Non-increasing monotonic timestamp: {previous_time} -> {monotonic_us}"
            )
        previous_sequence = sequence
        previous_time = monotonic_us
