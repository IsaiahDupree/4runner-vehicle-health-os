from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import uuid
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

from .can_discovery import PassiveCANRecord, analyze_passive_can, load_passive_can_ndjson
from .can_replay import (
    build_can_replay_corpus,
    replay_can_corpus,
    run_link_reliability_matrix,
)
from .contracts import ContractCatalog
from .marker_correlation import (
    DEFAULT_SETTLE_MICROSECONDS,
    DEFAULT_WINDOW_MICROSECONDS,
    correlate_can_with_markers,
    load_marker_ledgers,
)
from .portable_can import (
    PortableCANError,
    extract_portable_can,
    load_portable_can_records,
    load_recovered_can_extraction,
)
from .signal_hypotheses import evaluate_can_hypotheses


FIELD_RETURN_CONTRACT = "vhos.field-return-analysis"
FIELD_RETURN_VERSION = "1.0.0"
SOURCE_CLASSIFICATION = "RECOVERED_PORTABLE_EVIDENCE"
REQUIRED_DISPLAY_LABEL = "OFFLINE FIELD EVIDENCE • NOT LIVE"
PORTABLE_LEDGER = Path("VHOSPortableFrames/v1/logical-frames.ndjson")
EVENT_MARKER_LEDGER = Path("VHOSDiscoveryEvidence/v1/event-markers.ndjson")
PASSIVE_CAN_DIRECTORY = Path("VHOS/PassiveCAN")
MAXIMUM_INPUT_FILES = 10_000
MAXIMUM_INPUT_BYTES = 1024 * 1024 * 1024
MAXIMUM_ARTIFACT_FILES = 20_000


class FieldReturnAnalysisError(ValueError):
    """Raised when a copied iPhone field return cannot be analyzed safely."""


class _DuplicateJSONKeyError(ValueError):
    pass


@dataclass(frozen=True)
class _SourceFile:
    relative_path: str
    byte_count: int
    record_count: int | None
    sha256: str


@dataclass(frozen=True)
class _SourceSnapshot:
    root: Path
    portable_ledger: Path
    files: tuple[_SourceFile, ...]


def analyze_field_return(
    app_data: Path,
    output: Path,
    *,
    baseline: Path | None = None,
    soak_cycles: int = 20,
    hypothesis_pack: Path | None = None,
    marker_settle_microseconds: int = DEFAULT_SETTLE_MICROSECONDS,
    marker_window_microseconds: int = DEFAULT_WINDOW_MICROSECONDS,
) -> dict[str, Any]:
    """Run the complete offline field-return pipeline and publish it atomically.

    The copied app-data sources are never rewritten or copied over. Every input and
    generated artifact is checksum inventoried, and the completed output directory
    appears only after every validation, replay, and reliability gate passes.
    """

    if not 1 <= soak_cycles <= 1_000:
        raise FieldReturnAnalysisError("soak_cycles must be between 1 and 1,000.")
    output = output.resolve()
    if output.exists():
        raise FieldReturnAnalysisError(f"Field-return output already exists: {output}")

    current = _snapshot_app_data(app_data)
    prior = _snapshot_app_data(baseline) if baseline is not None else None
    _reject_output_inside_source(output, current.root)
    if prior is not None:
        _reject_output_inside_source(output, prior.root)

    staging = output.parent / f".{output.name}.staging-{uuid.uuid4().hex}"
    if staging.exists():
        raise FieldReturnAnalysisError(
            f"Field-return staging path already exists: {staging}"
        )
    staging.mkdir(parents=True)

    try:
        current_lines = _portable_record_lines(current.portable_ledger)
        current_records, _ = load_portable_can_records([current.portable_ledger])
        baseline_lines: list[bytes] = []
        baseline_records: list[PassiveCANRecord] = []
        if prior is not None:
            baseline_lines = _portable_record_lines(prior.portable_ledger)
            baseline_records, _ = load_portable_can_records([prior.portable_ledger])

        append_comparison, appended_lines = _compare_append_only_ledgers(
            current_lines,
            baseline_lines if prior is not None else None,
        )
        append_comparison["current_message_types"] = _message_type_counts(current_lines)
        if prior is not None:
            append_comparison["baseline_message_types"] = _message_type_counts(
                baseline_lines
            )
            append_comparison["appended_message_types"] = _message_type_counts(
                appended_lines
            )
        else:
            append_comparison["baseline_message_types"] = None
            append_comparison["appended_message_types"] = None
            append_comparison["appended_can_observations"] = None
            append_comparison["new_identifiers"] = []
            append_comparison["continued_identifiers"] = []

        direct_can, direct_only_records = _validate_direct_passive_can(
            current, current_records
        )
        markers = _marker_source(current)

        full = _analyze_scope(
            scope="full",
            portable_source=current.portable_ledger,
            root=staging / "full",
            current_sha256=_file_entry(current, PORTABLE_LEDGER).sha256,
            soak_cycles=soak_cycles,
            hypothesis_pack=hypothesis_pack,
            marker_source=markers,
            marker_settle_microseconds=marker_settle_microseconds,
            marker_window_microseconds=marker_window_microseconds,
            supplemental_records=direct_only_records,
        )

        appended: dict[str, Any] | None = None
        if prior is not None and appended_lines:
            appended_portable = staging / "appended" / "portable" / PORTABLE_LEDGER.name
            appended_portable.parent.mkdir(parents=True)
            appended_portable.write_bytes(b"\n".join(appended_lines) + b"\n")
            try:
                appended_records, _ = load_portable_can_records([appended_portable])
            except PortableCANError as error:
                if "No portable CAN observations were found" not in str(error):
                    raise
                append_comparison["appended_can_observations"] = 0
                append_comparison["new_identifiers"] = []
                append_comparison["continued_identifiers"] = []
                appended = {
                    "status": "NO_CAN_OBSERVATIONS",
                    "portable_path": _relative(staging, appended_portable),
                    "portable_records": len(appended_lines),
                }
            else:
                baseline_identifiers = {
                    (record.identifier, record.extended) for record in baseline_records
                }
                appended_identifiers = {
                    (record.identifier, record.extended) for record in appended_records
                }
                append_comparison["appended_can_observations"] = len(appended_records)
                append_comparison["new_identifiers"] = _identifier_labels(
                    appended_identifiers - baseline_identifiers
                )
                append_comparison["continued_identifiers"] = _identifier_labels(
                    appended_identifiers & baseline_identifiers
                )
                appended = _analyze_scope(
                    scope="appended",
                    portable_source=appended_portable,
                    root=staging / "appended",
                    current_sha256=hashlib.sha256(
                        appended_portable.read_bytes()
                    ).hexdigest(),
                    soak_cycles=soak_cycles,
                    hypothesis_pack=hypothesis_pack,
                    marker_source=markers,
                    marker_settle_microseconds=marker_settle_microseconds,
                    marker_window_microseconds=marker_window_microseconds,
                    supplemental_records=(),
                )
                appended["portable_path"] = _relative(staging, appended_portable)
        elif prior is not None:
            append_comparison["appended_can_observations"] = 0
            append_comparison["new_identifiers"] = []
            append_comparison["continued_identifiers"] = []

        current_identifiers = {
            (record.identifier, record.extended) for record in current_records
        }
        baseline_identifiers = {
            (record.identifier, record.extended) for record in baseline_records
        }
        append_comparison["current_can_observations"] = len(current_records)
        append_comparison["baseline_can_observations"] = (
            len(baseline_records) if prior is not None else None
        )
        append_comparison["current_identifiers"] = _identifier_labels(
            current_identifiers
        )
        if prior is not None:
            append_comparison["identifiers_absent_from_current"] = _identifier_labels(
                baseline_identifiers - current_identifiers
            )
        else:
            append_comparison["identifiers_absent_from_current"] = []

        summary = _human_summary(
            current=current,
            prior=prior,
            append_comparison=append_comparison,
            direct_can=direct_can,
            full=full,
            appended=appended,
        )
        summary_path = staging / "SUMMARY.md"
        summary_path.write_text(summary, encoding="utf-8")

        _verify_snapshot(current)
        if prior is not None:
            _verify_snapshot(prior)

        artifacts = _artifact_inventory(staging)
        manifest = {
            "contract": FIELD_RETURN_CONTRACT,
            "contract_version": FIELD_RETURN_VERSION,
            "analysis_id": _analysis_id(
                _snapshot_digest(current),
                _snapshot_digest(prior) if prior else None,
                soak_cycles,
                marker_settle_microseconds,
                marker_window_microseconds,
                full["hypothesis_pack_sha256"],
            ),
            "created_at": datetime.now(timezone.utc).isoformat().replace(
                "+00:00", "Z"
            ),
            "status": "PASS",
            "source_classification": SOURCE_CLASSIFICATION,
            "vehicle_claims_authorized": False,
            "required_display_label": REQUIRED_DISPLAY_LABEL,
            "parameters": {
                "soak_cycles": soak_cycles,
                "marker_settle_microseconds": marker_settle_microseconds,
                "marker_window_microseconds": marker_window_microseconds,
            },
            "inputs": {
                "current_root": str(current.root),
                "baseline_root": str(prior.root) if prior is not None else None,
                "source_files": [
                    *_source_inventory("CURRENT", current),
                    *(_source_inventory("BASELINE", prior) if prior else []),
                ],
            },
            "append_comparison": append_comparison,
            "direct_passive_can": direct_can,
            "analysis_scopes": {
                "full": full,
                "appended": appended,
            },
            "artifacts": artifacts,
            "summary_path": "SUMMARY.md",
            "authority": (
                "Offline acquisition, replay, impairment, and discovery-candidate evidence only. "
                "No candidate in this bundle is an accepted Toyota signal definition, live "
                "vehicle state, parked/motion authority, health conclusion, or control authority."
            ),
        }
        ContractCatalog.load().validate(manifest)
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staging, output)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging)
        raise

    return manifest


def _analyze_scope(
    *,
    scope: str,
    portable_source: Path,
    root: Path,
    current_sha256: str,
    soak_cycles: int,
    hypothesis_pack: Path | None,
    marker_source: Path | None,
    marker_settle_microseconds: int,
    marker_window_microseconds: int,
    supplemental_records: Sequence[PassiveCANRecord],
) -> dict[str, Any]:
    root.mkdir(parents=True, exist_ok=True)
    extraction_root = root / "recovered"
    extraction_manifest = extract_portable_can([portable_source], extraction_root)
    records, recovery = load_recovered_can_extraction(extraction_root)
    all_records = list(records)
    identities = {record.identity for record in all_records}
    for record in supplemental_records:
        if record.identity in identities:
            raise FieldReturnAnalysisError(
                f"Supplemental direct CAN identity was not de-duplicated: {record.identity}."
            )
        identities.add(record.identity)
        all_records.append(record)
    replay_inputs = _write_replay_inputs(all_records, root / "replay-input")

    discovery = analyze_passive_can(records, sources=recovery["source_files"])
    discovery["recovery_provenance"] = {
        "source_classification": recovery["source_classification"],
        "vehicle_claims_authorized": recovery["vehicle_claims_authorized"],
        "required_display_label": recovery["required_display_label"],
        "extraction_manifest": recovery["extraction_manifest"],
        "source_files": recovery["original_source_files"],
        "source_bundles": recovery["source_bundles"],
        "output_files": recovery["output_files"],
    }
    discovery["authority"] = (
        "RECOVERED_PORTABLE_EVIDENCE; vehicle_claims_authorized=false. "
        + discovery["authority"]
    )
    discovery["display_policy"]["proven_now"].insert(
        0,
        "recovery provenance and explicit non-authority verified from the complete extraction",
    )
    ContractCatalog.load().validate(discovery)
    discovery_path = root / "discovery.json"
    _write_json(discovery_path, discovery)

    hypotheses = evaluate_can_hypotheses(replay_inputs, pack_path=hypothesis_pack)
    hypotheses_path = root / "hypotheses.json"
    _write_json(hypotheses_path, hypotheses)

    corpus_id = f"field-return-{scope}-{current_sha256[:16]}"
    corpus_root = root / "replay-corpus"
    corpus = build_can_replay_corpus(
        replay_inputs,
        corpus_root,
        corpus_id=corpus_id,
    )
    live_replay = replay_can_corpus(corpus_root, mode="live")
    history_replay = replay_can_corpus(corpus_root, mode="history")
    if live_replay["status"] != "PASS" or history_replay["status"] != "PASS":
        raise FieldReturnAnalysisError(
            f"{scope} replay failed its exact payload/order gate."
        )
    replay_path = root / "replay.json"
    _write_json(
        replay_path,
        {"live": live_replay, "history": history_replay},
    )

    reliability = run_link_reliability_matrix(
        corpus_root,
        soak_cycles=soak_cycles,
    )
    ContractCatalog.load().validate(reliability)
    if reliability["acceptance_status"] != "PASS":
        raise FieldReturnAnalysisError(
            f"{scope} link reliability matrix did not pass."
        )
    reliability_path = root / "link-reliability.json"
    _write_json(reliability_path, reliability)

    marker = _run_marker_correlation(
        all_records,
        replay_inputs,
        marker_source,
        root / "marker-correlation.json",
        settle_microseconds=marker_settle_microseconds,
        window_microseconds=marker_window_microseconds,
    )
    if "report_path" in marker:
        marker["report_path"] = _relative(
            root.parent, root / marker["report_path"]
        )

    dynamic_hypotheses = [
        {
            "hypothesis_id": item["hypothesis_id"],
            "identifier_hex": item["identifier_hex"],
            "candidate_semantic": item["candidate_semantic"],
            "records": item["records"],
        }
        for item in hypotheses["hypothesis_evaluations"]
        if item["target_evidence_status"] == "FIELD_PRESENT_DYNAMIC"
    ]
    return {
        "status": "PASS",
        "recovery_path": _relative(root.parent, extraction_root),
        "replay_input_paths": [_relative(root.parent, path) for path in replay_inputs],
        "records": len(all_records),
        "portable_recovered_records": extraction_manifest["statistics"][
            "recovered_unique_observations"
        ],
        "supplemental_direct_records": len(supplemental_records),
        "sessions": len(
            {(record.gateway_id, record.session_id) for record in all_records}
        ),
        "unique_identifiers": len(
            {(record.identifier, record.extended) for record in all_records}
        ),
        "discovery_path": _relative(root.parent, discovery_path),
        "checksum_candidates": len(discovery["checksum_candidates"]),
        "relationship_candidates": len(
            discovery["raw_word_relationship_candidates"]
        ),
        "hypotheses_path": _relative(root.parent, hypotheses_path),
        "hypothesis_pack_sha256": hypotheses["pack"]["sha256"],
        "hypothesis_pack_version": hypotheses["pack"]["pack_version"],
        "dynamic_hypotheses": dynamic_hypotheses,
        "accepted_signal_definitions": hypotheses["accepted_signal_definitions"],
        "marker_correlation": marker,
        "corpus_path": _relative(root.parent, corpus_root),
        "corpus_id": corpus["corpus_id"],
        "semantic_digest": corpus["semantic_digest"],
        "replay_path": _relative(root.parent, replay_path),
        "live_replay_status": live_replay["status"],
        "history_replay_status": history_replay["status"],
        "reliability_path": _relative(root.parent, reliability_path),
        "reliability_status": reliability["acceptance_status"],
        "reliability_scenarios": reliability["scenario_count"],
        "soak_cycles": reliability["soak_cycles"],
    }


def _run_marker_correlation(
    records: Sequence[PassiveCANRecord],
    replay_inputs: Sequence[Path],
    marker_source: Path | None,
    output: Path,
    *,
    settle_microseconds: int,
    window_microseconds: int,
) -> dict[str, Any]:
    if marker_source is None:
        return {"status": "NOT_AVAILABLE", "reason": "No event marker ledger was copied."}
    markers, sources = load_marker_ledgers([marker_source])
    sessions = {(record.gateway_id, record.session_id) for record in records}
    counts: Counter[str] = Counter(
        marker.test_run_id
        for marker in markers
        if (marker.gateway_id, marker.session_id) in sessions
    )
    applicable = sorted(run_id for run_id, count in counts.items() if count >= 3)
    if not applicable:
        return {
            "status": "NOT_APPLICABLE",
            "reason": (
                "The marker ledger is valid, but no run has at least three markers bound "
                "to a recovered gateway session."
            ),
            "marker_records": len(markers),
            "source_sha256": sources[0]["sha256"],
        }
    report = correlate_can_with_markers(
        replay_inputs,
        [marker_source],
        settle_microseconds=settle_microseconds,
        window_microseconds=window_microseconds,
    )
    _write_json(output, report)
    highlights = [
        {
            "identifier": item["identifier"],
            "field": item["field"],
            "score": item["score"],
            "evidence_density": item["evidence_density"],
            "minimum_window_observations": item["minimum_window_observations"],
            "signature": [
                f"{sample['kind']}={sample['value']}"
                for sample in item["signature"]
            ],
            "ambiguous_marker_kinds": item["ambiguous_marker_kinds"],
        }
        for item in report["ranked_candidates"][:5]
    ]
    return {
        "status": "COMPLETE",
        "report_path": output.name,
        "test_runs": len(report["test_runs"]),
        "applicable_test_run_ids": applicable,
        "ranked_candidates": len(report["ranked_candidates"]),
        "candidate_highlights": highlights,
        "promotion_allowed": report["promotion_allowed"],
        "coverage_note": (
            "Zero ranked candidates means the retained CAN windows were too sparse or "
            "insufficiently state-distinct; it is not evidence that no associated signal exists."
            if not report["ranked_candidates"]
            else "Candidates remain discovery-only until independent corroboration."
        ),
    }


def _snapshot_app_data(root: Path | None) -> _SourceSnapshot:
    if root is None:
        raise FieldReturnAnalysisError("App-data directory is required.")
    unresolved = root.expanduser()
    if unresolved.is_symlink():
        raise FieldReturnAnalysisError(
            f"Copied iPhone app-data directory is a symbolic link: {unresolved}"
        )
    resolved = unresolved.resolve()
    if not resolved.is_dir():
        raise FieldReturnAnalysisError(
            f"Copied iPhone app-data directory is missing or unsafe: {resolved}"
        )
    portable = resolved / PORTABLE_LEDGER
    if not portable.is_file() or portable.is_symlink():
        raise FieldReturnAnalysisError(
            f"Canonical portable ledger is missing or unsafe: {portable}"
        )

    files: list[_SourceFile] = []
    total_bytes = 0
    for path in sorted(resolved.rglob("*")):
        if path.is_symlink():
            raise FieldReturnAnalysisError(
                f"Copied app data contains a symbolic link: {path}"
            )
        if not path.is_file():
            continue
        if len(files) >= MAXIMUM_INPUT_FILES:
            raise FieldReturnAnalysisError("Copied app data contains too many files.")
        raw = path.read_bytes()
        total_bytes += len(raw)
        if total_bytes > MAXIMUM_INPUT_BYTES:
            raise FieldReturnAnalysisError("Copied app data exceeds the byte limit.")
        record_count = _validate_ndjson(path, raw) if path.suffix == ".ndjson" else None
        files.append(
            _SourceFile(
                relative_path=path.relative_to(resolved).as_posix(),
                byte_count=len(raw),
                record_count=record_count,
                sha256=hashlib.sha256(raw).hexdigest(),
            )
        )
    return _SourceSnapshot(resolved, portable, tuple(files))


def _validate_ndjson(path: Path, raw: bytes) -> int:
    count = 0
    for line_number, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line, object_pairs_hook=_unique_json_object)
        except _DuplicateJSONKeyError as error:
            raise FieldReturnAnalysisError(
                f"{path.name}:{line_number}: duplicate JSON field {error}."
            ) from error
        except json.JSONDecodeError as error:
            raise FieldReturnAnalysisError(
                f"{path.name}:{line_number}: invalid append-only JSON: {error}"
            ) from error
        if not isinstance(value, dict):
            raise FieldReturnAnalysisError(
                f"{path.name}:{line_number}: append-only record must be an object."
            )
        count += 1
    return count


def _portable_record_lines(path: Path) -> list[bytes]:
    lines = [line for line in path.read_bytes().splitlines() if line.strip()]
    if not lines:
        raise FieldReturnAnalysisError(f"Portable ledger is empty: {path}")
    return lines


def _compare_append_only_ledgers(
    current: Sequence[bytes],
    baseline: Sequence[bytes] | None,
) -> tuple[dict[str, Any], list[bytes]]:
    if baseline is None:
        return (
            {
                "status": "NOT_REQUESTED",
                "baseline_portable_records": None,
                "current_portable_records": len(current),
                "appended_portable_records": None,
            },
            [],
        )
    if len(baseline) > len(current):
        raise FieldReturnAnalysisError(
            "Current portable ledger is shorter than the requested baseline."
        )
    for index, expected in enumerate(baseline):
        if current[index] != expected:
            raise FieldReturnAnalysisError(
                "Current portable ledger is not an exact append-only continuation of the "
                f"baseline (first mismatch at record {index + 1})."
            )
    appended = list(current[len(baseline) :])
    return (
        {
            "status": "EXACT_PREFIX",
            "baseline_portable_records": len(baseline),
            "current_portable_records": len(current),
            "appended_portable_records": len(appended),
        },
        appended,
    )


def _message_type_counts(lines: Iterable[bytes]) -> dict[str, int]:
    counts: Counter[int] = Counter()
    for line in lines:
        document = json.loads(line)
        value = document.get("message_type")
        if isinstance(value, int) and not isinstance(value, bool):
            counts[value] += 1
    return {str(key): counts[key] for key in sorted(counts)}


def _write_replay_inputs(
    records: Iterable[PassiveCANRecord], output: Path
) -> list[Path]:
    grouped: dict[tuple[str, int], list[PassiveCANRecord]] = defaultdict(list)
    for record in records:
        grouped[(record.gateway_id, record.session_id)].append(record)
    paths: list[Path] = []
    for (gateway_id, session_id), session_records in sorted(grouped.items()):
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", gateway_id):
            raise FieldReturnAnalysisError(
                f"Recovered gateway ID is unsafe for replay output: {gateway_id!r}"
            )
        path = output / gateway_id / f"{session_id}.ndjson"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "".join(
                json.dumps(
                    _observation_document(record),
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
                for record in sorted(
                    session_records,
                    key=lambda item: (
                        item.monotonic_microseconds,
                        item.source_sequence,
                    ),
                )
            ),
            encoding="utf-8",
        )
        paths.append(path)
    load_passive_can_ndjson(paths)
    return paths


def _observation_document(record: PassiveCANRecord) -> dict[str, Any]:
    return {
        "contract": "gateway.passive-can-observation",
        "contract_version": "1.0.0",
        "gateway_id": record.gateway_id,
        "session_id": record.session_id,
        "source_sequence": record.source_sequence,
        "monotonic_microseconds": record.monotonic_microseconds,
        "bitrate_bps": record.bitrate_bps,
        "identifier": record.identifier,
        "extended": record.extended,
        "remote_request": record.remote_request,
        "listen_only": record.listen_only,
        "data_length": record.data_length,
        "data": list(record.data),
        "evidence_source": record.evidence_source,
        "ingested_at": record.ingested_at,
    }


def _validate_direct_passive_can(
    snapshot: _SourceSnapshot,
    recovered: Sequence[PassiveCANRecord],
) -> tuple[dict[str, Any], list[PassiveCANRecord]]:
    direct_root = snapshot.root / PASSIVE_CAN_DIRECTORY
    if not direct_root.is_dir():
        return {"status": "NOT_AVAILABLE", "files": 0, "records": 0}, []
    paths = sorted(direct_root.rglob("*.ndjson"))
    if not paths:
        return {"status": "NOT_AVAILABLE", "files": 0, "records": 0}, []
    records, sources = load_passive_can_ndjson(paths)
    recovered_by_identity = {record.identity: record for record in recovered}
    overlap = 0
    missing_from_portable = 0
    supplemental: list[PassiveCANRecord] = []
    for record in records:
        portable = recovered_by_identity.get(record.identity)
        if portable is None:
            missing_from_portable += 1
            supplemental.append(record)
            continue
        overlap += 1
        if _physical_tuple(record) != _physical_tuple(portable):
            raise FieldReturnAnalysisError(
                f"Direct and portable CAN evidence conflict at {record.identity}."
            )
    return (
        {
            "status": "VALIDATED",
            "files": len(paths),
            "records": len(records),
            "sessions": len(
                {(record.gateway_id, record.session_id) for record in records}
            ),
            "matching_portable_identities": overlap,
            "identities_not_in_portable_ledger": missing_from_portable,
            "supplemental_replay_records": len(supplemental),
            "source_files": sources,
        },
        supplemental,
    )


def _physical_tuple(record: PassiveCANRecord) -> tuple[Any, ...]:
    return (
        record.gateway_id,
        record.session_id,
        record.source_sequence,
        record.monotonic_microseconds,
        record.bitrate_bps,
        record.identifier,
        record.extended,
        record.remote_request,
        record.listen_only,
        record.data_length,
        record.data,
    )


def _marker_source(snapshot: _SourceSnapshot) -> Path | None:
    path = snapshot.root / EVENT_MARKER_LEDGER
    if not path.exists():
        return None
    if not path.is_file() or path.is_symlink():
        raise FieldReturnAnalysisError(f"Event marker ledger is unsafe: {path}")
    return path


def _artifact_inventory(root: Path) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise FieldReturnAnalysisError(
                f"Generated analysis contains a symbolic link: {path}"
            )
        if not path.is_file() or path.name == "manifest.json" and path.parent == root:
            continue
        if len(artifacts) >= MAXIMUM_ARTIFACT_FILES:
            raise FieldReturnAnalysisError("Generated analysis contains too many files.")
        raw = path.read_bytes()
        artifacts.append(
            {
                "path": path.relative_to(root).as_posix(),
                "sha256": hashlib.sha256(raw).hexdigest(),
                "byte_count": len(raw),
            }
        )
    return artifacts


def _source_inventory(role: str, snapshot: _SourceSnapshot) -> list[dict[str, Any]]:
    return [
        {
            "input_role": role,
            "path": item.relative_path,
            "sha256": item.sha256,
            "byte_count": item.byte_count,
            "record_count": item.record_count,
        }
        for item in snapshot.files
    ]


def _verify_snapshot(snapshot: _SourceSnapshot) -> None:
    after = _snapshot_app_data(snapshot.root)
    if after.files != snapshot.files:
        raise FieldReturnAnalysisError(
            f"Copied app data changed while analysis was running: {snapshot.root}"
        )


def _file_entry(snapshot: _SourceSnapshot, relative: Path) -> _SourceFile:
    name = relative.as_posix()
    for item in snapshot.files:
        if item.relative_path == name:
            return item
    raise FieldReturnAnalysisError(f"Source inventory is missing {name}.")


def _snapshot_digest(snapshot: _SourceSnapshot) -> str:
    hasher = hashlib.sha256()
    for item in snapshot.files:
        encoded = json.dumps(
            {
                "path": item.relative_path,
                "sha256": item.sha256,
                "byte_count": item.byte_count,
                "record_count": item.record_count,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        hasher.update(len(encoded).to_bytes(8, "big"))
        hasher.update(encoded)
    return hasher.hexdigest()


def _identifier_labels(values: Iterable[tuple[int, bool]]) -> list[str]:
    return [
        f"0x{identifier:08X}" if extended else f"0x{identifier:03X}"
        for identifier, extended in sorted(values)
    ]


def _analysis_id(
    current_sha: str,
    baseline_sha: str | None,
    soak_cycles: int,
    marker_settle_microseconds: int,
    marker_window_microseconds: int,
    hypothesis_pack_sha256: str,
) -> str:
    material = (
        f"{current_sha}:{baseline_sha or '-'}:{soak_cycles}:"
        f"{marker_settle_microseconds}:{marker_window_microseconds}:"
        f"{hypothesis_pack_sha256}"
    ).encode()
    return f"field-return-{hashlib.sha256(material).hexdigest()[:24]}"


def _human_summary(
    *,
    current: _SourceSnapshot,
    prior: _SourceSnapshot | None,
    append_comparison: dict[str, Any],
    direct_can: dict[str, Any],
    full: dict[str, Any],
    appended: dict[str, Any] | None,
) -> str:
    marker = full["marker_correlation"]
    lines = [
        "# VHOS offline field-return analysis",
        "",
        "Status: **PASS**",
        "",
        (
            f"The copied iPhone evidence was validated without modifying its source files. "
            f"The portable ledger recovered **{full['portable_recovered_records']:,} CAN "
            f"observations** and the direct archive contributed "
            f"**{full['supplemental_direct_records']:,} additional identities**, producing "
            f"**{full['records']:,} replay observations** "
            f"across **{full['sessions']:,} sessions** and **{full['unique_identifiers']:,} "
            "identifiers**."
        ),
        "",
        "## One-pass results",
        "",
        f"- Current app-data copy: `{current.root}`",
        f"- Prior baseline: `{prior.root}`" if prior else "- Prior baseline: not supplied",
        f"- Portable ledger comparison: `{append_comparison['status']}`",
        (
            f"- Appended portable records: {append_comparison['appended_portable_records']:,}"
            if append_comparison["appended_portable_records"] is not None
            else "- Appended portable records: not calculated without a baseline"
        ),
        f"- Direct PassiveCAN archive: `{direct_can['status']}`",
        f"- Clean live replay: `{full['live_replay_status']}`",
        f"- Clean history replay: `{full['history_replay_status']}`",
        (
            f"- Link reliability: `{full['reliability_status']}` across "
            f"{full['reliability_scenarios']} scenarios × {full['soak_cycles']} soak cycles"
        ),
        (
            f"- Marker correlation: `{marker['status']}`; "
            f"{marker.get('ranked_candidates', 0)} ranked candidates"
        ),
        f"- Accepted signal definitions created automatically: {full['accepted_signal_definitions']}",
        "",
        "## Appended evidence",
        "",
    ]
    if appended is None:
        lines.append(
            "No appended-analysis scope was created because no baseline was supplied or the "
            "current ledger had no records after the exact baseline prefix."
        )
    elif appended.get("status") == "NO_CAN_OBSERVATIONS":
        lines.append(
            "The appended portable records were retained, but they contained no passive CAN "
            "observations, so CAN replay and mapping were not claimed for the delta."
        )
    else:
        lines.extend(
            [
                f"- New recovered CAN observations: {appended['records']:,}",
                f"- Sessions represented: {appended['sessions']:,}",
                f"- Identifiers represented: {appended['unique_identifiers']:,}",
                f"- Delta reliability: `{appended['reliability_status']}`",
                (
                    "- Identifier(s) not present in the baseline: "
                    + (", ".join(append_comparison["new_identifiers"]) or "none")
                ),
            ]
        )
    lines.extend(
        [
            "",
            "## Candidate interpretations",
            "",
        ]
    )
    highlights = marker.get("candidate_highlights", [])
    if highlights:
        lines.append("Synchronized selector-marker associations:")
        lines.append("")
        for item in highlights:
            signature = ", ".join(item["signature"])
            ambiguity = (
                f"; ambiguity: {item['ambiguous_marker_kinds']}"
                if item["ambiguous_marker_kinds"]
                else ""
            )
            lines.append(
                f"- `{item['identifier']}.{item['field']}` → {signature}; "
                f"score {item['score']:.3f}, density {item['evidence_density']:.3f}, "
                f"minimum {item['minimum_window_observations']} observation(s)/window"
                f"{ambiguity}"
            )
        lines.extend(
            [
                "",
                "Low evidence density is explicitly penalized. These associations guide the "
                "next capture but cannot prove selector semantics or parked state.",
                "",
            ]
        )
    dynamic = full["dynamic_hypotheses"]
    if dynamic:
        for item in dynamic[:12]:
            lines.append(
                f"- `{item['identifier_hex']}` / `{item['hypothesis_id']}` — "
                f"{item['candidate_semantic']} ({item['records']:,} retained records)"
            )
    else:
        lines.append("No checked-in hypothesis field was dynamic in this evidence.")
    lines.extend(
        [
            "",
            "These are unverified discovery candidates, not production mappings. The workflow "
            "deliberately creates zero accepted Toyota signal definitions without independent "
            "corroboration.",
            "",
            "## What can now be done away from the vehicle",
            "",
            "The `replay-corpus` directories are immutable, checksum-verified real-evidence "
            "inputs. They can drive iOS, Android, decoder, graph, reconnect, duplicate, loss, "
            "corruption, reorder, timeout, and bounded-queue tests without the car or ESP32.",
            "",
            "## Remaining field dependency",
            "",
            (
                marker.get("coverage_note")
                or "Synchronized labels/reference measurements are still required to promote a mapping."
            ),
            "A future vehicle visit should be one guided capture that downloads retained history "
            "and records repeated markers/reference values. Normal coding, replay, load testing, "
            "UI playback, and candidate ranking should use this bundle offline.",
            "",
            "Authority boundary: **OFFLINE FIELD EVIDENCE • NOT LIVE**. No parked/motion state, "
            "vehicle-health result, or control authority is created by this report.",
            "",
        ]
    )
    return "\n".join(lines)


def _write_json(path: Path, document: dict[str, Any]) -> None:
    if path.exists():
        raise FieldReturnAnalysisError(f"Generated output already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _relative(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError as error:
        raise FieldReturnAnalysisError(
            f"Generated artifact escapes its analysis scope: {path}"
        ) from error


def _reject_output_inside_source(output: Path, source: Path) -> None:
    if output == source or source in output.parents:
        raise FieldReturnAnalysisError(
            "Field-return output must not be created inside copied source evidence."
        )


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise _DuplicateJSONKeyError(key)
        document[key] = value
    return document
