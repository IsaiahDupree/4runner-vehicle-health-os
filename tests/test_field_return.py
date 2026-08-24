from __future__ import annotations

import base64
import hashlib
import json
import struct
from pathlib import Path

import pytest

from vhos.can_discovery import PassiveCANRecord
from vhos.can_replay import (
    LIVE_CAN_MESSAGE_TYPE,
    _encode_gateway_frame,
    _encode_live_record,
)
from vhos.contracts import ContractCatalog
from vhos.field_return import FieldReturnAnalysisError, analyze_field_return


def _observation(index: int) -> PassiveCANRecord:
    identifiers = (0x025, 0x224, 0x2C1, 0x2C4, 0x2D0)
    identifier = identifiers[index % len(identifiers)]
    data = (
        (index >> 8) & 0xFF,
        index & 0xFF,
        (index * 3) & 0xFF,
        (index * 5) & 0xFF,
        (index * 7) & 0xFF,
        (index * 11) & 0xFF,
        (index * 13) & 0xFF,
        (index * 17) & 0xFF,
    )
    return PassiveCANRecord(
        gateway_id="esp32-field-node",
        session_id=42,
        source_sequence=index + 1,
        monotonic_microseconds=1_000_000 + index * 10_000,
        bitrate_bps=500_000,
        identifier=identifier,
        extended=False,
        remote_request=False,
        listen_only=True,
        data_length=8,
        data=data,
        evidence_source="ble-live",
        ingested_at="2026-08-24T18:00:00Z",
    )


def _portable_document(record: PassiveCANRecord, index: int) -> dict[str, object]:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        10_000 + index,
        record.monotonic_microseconds,
        _encode_live_record(record),
    )
    return {
        "contract": "vhos.portable-logical-frame",
        "contract_version": "1.0.0",
        "source_role": "OBD_CAN",
        "source_id": record.gateway_id,
        "source_sequence": str(struct.unpack_from("<Q", wire, 12)[0]),
        "source_monotonic_microseconds": str(struct.unpack_from("<Q", wire, 20)[0]),
        "protocol_major": wire[4],
        "protocol_minor": wire[5],
        "message_type": wire[6],
        "flags": wire[7],
        "ingested_at": record.ingested_at,
        "envelope_sha256": hashlib.sha256(wire).hexdigest(),
        "envelope_base64": base64.b64encode(wire).decode("ascii"),
    }


def _write_app_data(root: Path, documents: list[dict[str, object]]) -> Path:
    ledger = root / "VHOSPortableFrames/v1/logical-frames.ndjson"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        "".join(
            json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
            for document in documents
        ),
        encoding="utf-8",
    )
    return ledger


def test_one_command_field_return_recovers_delta_replays_and_stress_tests(
    tmp_path: Path,
) -> None:
    documents = [
        _portable_document(_observation(index), index) for index in range(440)
    ]
    baseline = tmp_path / "baseline"
    current = tmp_path / "current"
    baseline_ledger = _write_app_data(baseline, documents[:220])
    current_ledger = _write_app_data(current, documents)
    baseline_sha = hashlib.sha256(baseline_ledger.read_bytes()).hexdigest()
    current_sha = hashlib.sha256(current_ledger.read_bytes()).hexdigest()

    output = tmp_path / "analysis"
    manifest = analyze_field_return(
        current,
        output,
        baseline=baseline,
        soak_cycles=1,
    )

    ContractCatalog.load().validate(manifest)
    assert manifest["status"] == "PASS"
    assert manifest["vehicle_claims_authorized"] is False
    assert manifest["append_comparison"]["status"] == "EXACT_PREFIX"
    assert manifest["append_comparison"]["appended_portable_records"] == 220
    assert manifest["append_comparison"]["appended_can_observations"] == 220
    assert manifest["analysis_scopes"]["full"]["records"] == 440
    assert manifest["analysis_scopes"]["appended"]["records"] == 220
    assert manifest["analysis_scopes"]["full"]["reliability_status"] == "PASS"
    assert manifest["analysis_scopes"]["appended"]["reliability_status"] == "PASS"
    assert manifest["analysis_scopes"]["full"]["marker_correlation"]["status"] == (
        "NOT_AVAILABLE"
    )
    assert (output / "manifest.json").is_file()
    assert "OFFLINE FIELD EVIDENCE" in (output / "SUMMARY.md").read_text()
    assert hashlib.sha256(baseline_ledger.read_bytes()).hexdigest() == baseline_sha
    assert hashlib.sha256(current_ledger.read_bytes()).hexdigest() == current_sha
    assert all((output / item["path"]).is_file() for item in manifest["artifacts"])


def test_field_return_rejects_non_prefix_baseline_without_partial_output(
    tmp_path: Path,
) -> None:
    current_documents = [
        _portable_document(_observation(index), index) for index in range(3)
    ]
    baseline_documents = list(current_documents[:2])
    baseline_documents[1] = _portable_document(_observation(99), 99)
    current = tmp_path / "current"
    baseline = tmp_path / "baseline"
    _write_app_data(current, current_documents)
    _write_app_data(baseline, baseline_documents)
    output = tmp_path / "analysis"

    with pytest.raises(FieldReturnAnalysisError, match="not an exact append-only"):
        analyze_field_return(current, output, baseline=baseline, soak_cycles=1)

    assert not output.exists()
    assert not list(tmp_path.glob(".analysis.staging-*"))


def test_field_return_without_baseline_runs_full_scope_only(tmp_path: Path) -> None:
    documents = [
        _portable_document(_observation(index), index) for index in range(220)
    ]
    current = tmp_path / "current"
    _write_app_data(current, documents)

    output = tmp_path / "analysis"
    manifest = analyze_field_return(current, output, soak_cycles=1)

    assert manifest["append_comparison"]["status"] == "NOT_REQUESTED"
    assert manifest["append_comparison"]["appended_portable_records"] is None
    assert manifest["append_comparison"]["appended_can_observations"] is None
    assert manifest["analysis_scopes"]["full"]["records"] == 220
    assert manifest["analysis_scopes"]["appended"] is None
    ContractCatalog.load().validate(manifest)


def test_field_return_rejects_invalid_ndjson_before_creating_output(
    tmp_path: Path,
) -> None:
    current = tmp_path / "current"
    ledger = current / "VHOSPortableFrames/v1/logical-frames.ndjson"
    ledger.parent.mkdir(parents=True)
    ledger.write_text('{"contract":"first","contract":"second"}\n')
    output = tmp_path / "analysis"

    with pytest.raises(FieldReturnAnalysisError, match="duplicate"):
        analyze_field_return(current, output, soak_cycles=1)

    assert not output.exists()
