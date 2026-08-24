from __future__ import annotations

import base64
import hashlib
import json
import struct
import zipfile
from collections.abc import Callable
from pathlib import Path

import pytest
import vhos.portable_can as portable_can_module

from vhos.can_discovery import (
    CANDiscoveryError,
    PassiveCANRecord,
    load_passive_can_ndjson,
)
from vhos.can_replay import (
    CAPTURE_LOG_CHUNK_MESSAGE_TYPE,
    LIVE_CAN_MESSAGE_TYPE,
    _encode_capture_log_chunk,
    _encode_gateway_frame,
    _encode_live_record,
)
from vhos.cli import main as cli_main
from vhos.contracts import ContractCatalog, ContractError
from vhos.portable_can import (
    PortableCANError,
    extract_portable_can,
    load_recovered_can_extraction,
)


def _observation(
    *,
    session_id: int = 42,
    source_sequence: int = 10,
    monotonic_microseconds: int = 1_000_000,
    data: tuple[int, ...] = (1, 2, 3, 4, 5, 6, 7, 8),
    listen_only: bool = True,
) -> PassiveCANRecord:
    return PassiveCANRecord(
        gateway_id="esp32-field-node",
        session_id=session_id,
        source_sequence=source_sequence,
        monotonic_microseconds=monotonic_microseconds,
        bitrate_bps=500_000,
        identifier=0x2D0,
        extended=False,
        remote_request=False,
        listen_only=listen_only,
        data_length=8,
        data=data,
        evidence_source="ble-live",
        ingested_at="2026-08-22T16:36:18Z",
    )


def _portable_document(
    wire: bytes,
    *,
    source_role: str = "OBD_CAN",
    source_id: str = "esp32-field-node",
) -> dict[str, object]:
    return {
        "contract": "vhos.portable-logical-frame",
        "contract_version": "1.0.0",
        "source_role": source_role,
        "source_id": source_id,
        "source_sequence": str(struct.unpack_from("<Q", wire, 12)[0]),
        "source_monotonic_microseconds": str(struct.unpack_from("<Q", wire, 20)[0]),
        "protocol_major": wire[4],
        "protocol_minor": wire[5],
        "message_type": wire[6],
        "flags": wire[7],
        "ingested_at": "2026-08-22T16:36:18Z",
        "envelope_sha256": hashlib.sha256(wire).hexdigest(),
        "envelope_base64": base64.b64encode(wire).decode("ascii"),
    }


def _write_portable(path: Path, documents: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(document, sort_keys=True) + "\n" for document in documents),
        encoding="utf-8",
    )


def _write_sync_bundle(
    path: Path,
    documents: list[dict[str, object]],
    *,
    version: str,
    recovery_sha256: str | None = None,
    uppercase_segment_sha256: bool = False,
    mutate_manifest: Callable[[dict[str, object]], None] | None = None,
) -> None:
    segment = "".join(
        json.dumps(document, sort_keys=True) + "\n" for document in documents
    ).encode("utf-8")
    segment_sha256 = hashlib.sha256(segment).hexdigest()
    manifest: dict[str, object] = {
        "contract": "vhos.evidence-sync-bundle",
        "contract_version": version,
        "bundle_id": "c8302c07-6e8d-4490-abf0-fe5505680c7e",
        "created_at": "2026-08-22T16:36:18Z",
        "creator": {
            "platform": "IOS",
            "application_id": "com.isaiahdupree.VehicleHealthOS",
            "application_version": "0.3.23",
            "device_model": "iPhone",
        },
        "segments": [
            {
                "path": "segments/logical-frames.ndjson",
                "media_type": "application/x-ndjson",
                "sha256": (
                    segment_sha256.upper()
                    if uppercase_segment_sha256
                    else segment_sha256
                ),
                "byte_count": len(segment),
                "record_count": len(documents),
            }
        ],
    }
    if version == "2.0.0":
        manifest["recovery"] = {
            "classification": "RECOVERED_PORTABLE_EVIDENCE",
            "vehicle_claims_authorized": False,
            "source_ledger_sha256": recovery_sha256 or segment_sha256,
        }
    if mutate_manifest is not None:
        mutate_manifest(manifest)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, sort_keys=True))
        archive.writestr("segments/logical-frames.ndjson", segment)


def _mutate_extraction_manifest(
    output: Path, mutation: Callable[[dict[str, object]], None]
) -> None:
    manifest_path = output / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    mutation(manifest)
    manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")


def _build_v2_extraction(tmp_path: Path, name: str = "field") -> Path:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    bundle = tmp_path / f"{name}.vhossync"
    _write_sync_bundle(bundle, [_portable_document(wire)], version="2.0.0")
    output = tmp_path / f"{name}-recovered"
    extract_portable_can([bundle], output)
    return output


def test_extracts_live_and_history_and_prefers_flash_overlap(tmp_path: Path) -> None:
    first = _observation()
    second = _observation(source_sequence=11, monotonic_microseconds=1_500_000)
    live = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(first),
    )
    history = _encode_gateway_frame(
        CAPTURE_LOG_CHUNK_MESSAGE_TYPE,
        101,
        2_500_000,
        _encode_capture_log_chunk(42, 0, [first, second], end_of_file=True),
    )
    handshake = _encode_gateway_frame(
        1, 99, 1_500_000, b'{"contract":"gateway.handshake"}'
    )
    source = tmp_path / "logical-frames.ndjson"
    _write_portable(
        source,
        [
            _portable_document(handshake),
            _portable_document(live),
            _portable_document(history),
        ],
    )

    manifest = extract_portable_can([source], tmp_path / "recovered")
    recovered, provenance = load_recovered_can_extraction(tmp_path / "recovered")

    assert len(recovered) == 2
    assert all(record.evidence_source == "gateway-flash" for record in recovered)
    assert manifest["source_classification"] == "RECOVERED_PORTABLE_EVIDENCE"
    assert manifest["vehicle_claims_authorized"] is False
    assert manifest["statistics"] == {
        "portable_records": 3,
        "validated_envelopes": 3,
        "non_can_frames": 1,
        "decoded_can_observations": 3,
        "exact_duplicate_observations": 1,
        "preferred_gateway_flash_replacements": 1,
        "recovered_unique_observations": 2,
        "sessions": 1,
        "unique_identifiers": 1,
        "listen_only_observations": 2,
        "ble_live_observations": 0,
        "gateway_flash_observations": 2,
        "bitrates_bps": [500_000],
    }
    assert (
        manifest["display_policy"]["required_label"] == "RECOVERED EVIDENCE • NOT LIVE"
    )
    assert provenance["vehicle_claims_authorized"] is False
    detached = next((tmp_path / "recovered" / "sessions").rglob("*.ndjson"))
    with pytest.raises(CANDiscoveryError, match="passive CAN fields are invalid"):
        load_passive_can_ndjson([detached])
    assert (
        b'"source_classification":"RECOVERED_PORTABLE_EVIDENCE"'
        in detached.read_bytes()
    )


@pytest.mark.parametrize("version", ["1.0.0", "2.0.0"])
def test_extracts_direct_vhossync_bundle_with_validated_manifest(
    tmp_path: Path, version: str
) -> None:
    observation = _observation()
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(observation),
    )
    bundle = tmp_path / f"field-{version}.vhossync"
    _write_sync_bundle(bundle, [_portable_document(wire)], version=version)

    manifest = extract_portable_can([bundle], tmp_path / f"recovered-{version}")
    recovered, _ = load_recovered_can_extraction(tmp_path / f"recovered-{version}")

    assert len(recovered) == 1
    assert manifest["source_bundles"][0]["contract_version"] == version
    assert (
        manifest["source_bundles"][0]["sha256"]
        == hashlib.sha256(bundle.read_bytes()).hexdigest()
    )
    assert (
        manifest["source_files"][0]["source_bundle_sha256"]
        == manifest["source_bundles"][0]["sha256"]
    )
    assert (
        manifest["source_files"][0]["source_bundle_manifest_sha256"]
        == manifest["source_bundles"][0]["manifest_sha256"]
    )
    if version == "2.0.0":
        assert manifest["source_bundles"][0]["recovery"] == {
            "classification": "RECOVERED_PORTABLE_EVIDENCE",
            "vehicle_claims_authorized": False,
            "source_ledger_sha256": manifest["source_files"][0]["sha256"],
        }
    else:
        assert manifest["source_bundles"][0]["recovery"] is None


def test_rejects_vhossync_recovery_ledger_binding_mismatch(tmp_path: Path) -> None:
    observation = _observation()
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(observation),
    )
    bundle = tmp_path / "spoofed.vhossync"
    _write_sync_bundle(
        bundle,
        [_portable_document(wire)],
        version="2.0.0",
        recovery_sha256="0" * 64,
    )

    with pytest.raises(
        PortableCANError, match="recovery provenance binding is invalid"
    ):
        extract_portable_can([bundle], tmp_path / "recovered")


def test_rejects_noncanonical_v2_segment_digest_even_when_bytes_match(
    tmp_path: Path,
) -> None:
    observation = _observation()
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(observation),
    )
    bundle = tmp_path / "uppercase-digest.vhossync"
    _write_sync_bundle(
        bundle,
        [_portable_document(wire)],
        version="2.0.0",
        uppercase_segment_sha256=True,
    )

    with pytest.raises(PortableCANError, match="segment integrity metadata is invalid"):
        extract_portable_can([bundle], tmp_path / "recovered")


def test_session_filter_recovers_only_requested_lineage(tmp_path: Path) -> None:
    documents = []
    for outer_sequence, session_id in [(100, 42), (101, 43)]:
        observation = _observation(
            session_id=session_id, source_sequence=outer_sequence
        )
        documents.append(
            _portable_document(
                _encode_gateway_frame(
                    LIVE_CAN_MESSAGE_TYPE,
                    outer_sequence,
                    outer_sequence * 10_000,
                    _encode_live_record(observation),
                )
            )
        )
    source = tmp_path / "logical-frames.ndjson"
    _write_portable(source, documents)

    manifest = extract_portable_can([source], tmp_path / "filtered", session_ids=[43])
    recovered, _ = load_recovered_can_extraction(tmp_path / "filtered")

    assert {record.session_id for record in recovered} == {43}
    assert manifest["session_filter"] == [43]


def test_rejects_conflicting_same_identity_payload(tmp_path: Path) -> None:
    first = _observation(data=(1, 2, 3, 4, 5, 6, 7, 8))
    conflict = _observation(data=(8, 7, 6, 5, 4, 3, 2, 1))
    source = tmp_path / "logical-frames.ndjson"
    _write_portable(
        source,
        [
            _portable_document(
                _encode_gateway_frame(2, 100, 2_000_000, _encode_live_record(first))
            ),
            _portable_document(
                _encode_gateway_frame(2, 101, 2_500_000, _encode_live_record(conflict))
            ),
        ],
    )

    with pytest.raises(PortableCANError, match="conflicting observation identity"):
        extract_portable_can([source], tmp_path / "recovered")


def test_rejects_hash_metadata_role_and_listen_only_failures(tmp_path: Path) -> None:
    safe = _observation()
    wire = _encode_gateway_frame(2, 100, 2_000_000, _encode_live_record(safe))
    mutations: list[tuple[str, dict[str, object], str]] = []

    bad_hash = _portable_document(wire)
    bad_hash["envelope_sha256"] = "0" * 64
    mutations.append(("hash", bad_hash, "SHA-256 mismatch"))

    bad_metadata = _portable_document(wire)
    bad_metadata["source_sequence"] = "101"
    mutations.append(("metadata", bad_metadata, "metadata does not match"))

    bad_role = _portable_document(wire, source_role="AC_SENSOR")
    mutations.append(("role", bad_role, "not attributed to the OBD_CAN"))

    unsafe = _observation(listen_only=False)
    unsafe_wire = _encode_gateway_frame(2, 102, 2_100_000, _encode_live_record(unsafe))
    mutations.append(
        ("listen", _portable_document(unsafe_wire), "does not retain listen-only proof")
    )

    for name, document, message in mutations:
        source = tmp_path / f"{name}.ndjson"
        _write_portable(source, [document])
        with pytest.raises(PortableCANError, match=message):
            extract_portable_can([source], tmp_path / f"output-{name}")


def test_rejects_unknown_and_duplicate_portable_frame_fields(tmp_path: Path) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    unknown = _portable_document(wire)
    unknown["vehicle_claims_authorized"] = True
    unknown_path = tmp_path / "unknown.ndjson"
    _write_portable(unknown_path, [unknown])
    with pytest.raises(PortableCANError, match="portable frame fields are invalid"):
        extract_portable_can([unknown_path], tmp_path / "unknown-output")

    original = json.dumps(_portable_document(wire), sort_keys=True)
    duplicate = original.replace(
        '"contract": "vhos.portable-logical-frame",',
        '"contract": "vhos.portable-logical-frame", "contract": "other",',
        1,
    )
    duplicate_path = tmp_path / "duplicate.ndjson"
    duplicate_path.write_text(duplicate + "\n", encoding="utf-8")
    with pytest.raises(PortableCANError, match="duplicate JSON field"):
        extract_portable_can([duplicate_path], tmp_path / "duplicate-output")


def test_recovered_extraction_rejects_manifest_or_record_authority_tampering(
    tmp_path: Path,
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    source = tmp_path / "logical-frames.ndjson"
    _write_portable(source, [_portable_document(wire)])
    output = tmp_path / "recovered"
    extract_portable_can([source], output)

    manifest_path = output / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["vehicle_claims_authorized"] = True
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(PortableCANError, match="authority boundary is invalid"):
        load_recovered_can_extraction(output)


def test_rejects_vhossync_with_too_many_entries_before_reading_segments(
    tmp_path: Path,
) -> None:
    bundle = tmp_path / "too-many.vhossync"
    with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
        for index in range(34):
            archive.writestr(f"entry-{index}.ndjson", b"")
    with pytest.raises(PortableCANError, match="too many entries"):
        extract_portable_can([bundle], tmp_path / "output")


def test_staging_read_back_failure_never_publishes_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    source = tmp_path / "logical-frames.ndjson"
    _write_portable(source, [_portable_document(wire)])
    output = tmp_path / "recovered"
    inspected: list[Path] = []

    def reject_staging(root: Path) -> tuple[list[PassiveCANRecord], dict[str, object]]:
        inspected.append(root)
        raise PortableCANError("injected staging verification failure")

    monkeypatch.setattr(
        portable_can_module, "load_recovered_can_extraction", reject_staging
    )
    with pytest.raises(PortableCANError, match="staging verification failure"):
        extract_portable_can([source], output)

    assert len(inspected) == 1
    assert ".recovered.staging-" in inspected[0].name
    assert not output.exists()
    assert not list(tmp_path.glob(".recovered.staging-*"))


def test_staging_read_back_requires_exact_records_before_publish(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    source = tmp_path / "logical-frames.ndjson"
    _write_portable(source, [_portable_document(wire)])
    output = tmp_path / "recovered"

    def mismatched_read_back(
        root: Path,
    ) -> tuple[list[PassiveCANRecord], dict[str, object]]:
        assert ".recovered.staging-" in root.name
        return [_observation(source_sequence=999)], {}

    monkeypatch.setattr(
        portable_can_module,
        "load_recovered_can_extraction",
        mismatched_read_back,
    )
    with pytest.raises(PortableCANError, match="exact read-back check"):
        extract_portable_can([source], output)

    assert not output.exists()
    assert not list(tmp_path.glob(".recovered.staging-*"))


def test_recovered_extraction_rejects_output_byte_and_record_inventory_tampering(
    tmp_path: Path,
) -> None:
    output = _build_v2_extraction(tmp_path)

    def mutate(manifest: dict[str, object]) -> None:
        manifest["output_files"][0]["byte_count"] += 1

    _mutate_extraction_manifest(output, mutate)
    with pytest.raises(PortableCANError, match="byte count mismatch"):
        load_recovered_can_extraction(output)


@pytest.mark.parametrize(
    ("field_owner", "field", "replacement", "message"),
    [
        ("source_file", "source_bundle_sha256", "1" * 64, "bundle/file binding"),
        (
            "source_file",
            "source_bundle_manifest_sha256",
            "2" * 64,
            "bundle/file binding",
        ),
        ("source_bundle", "manifest_sha256", "3" * 64, "bundle/file binding"),
        ("source_bundle", "sha256", "A" * 64, "integrity metadata"),
        ("recovery", "source_ledger_sha256", "4" * 64, "source ledger binding"),
    ],
)
def test_recovered_extraction_rejects_broken_source_provenance_bindings(
    tmp_path: Path,
    field_owner: str,
    field: str,
    replacement: str,
    message: str,
) -> None:
    output = _build_v2_extraction(tmp_path, field)

    def mutate(manifest: dict[str, object]) -> None:
        if field_owner == "source_file":
            manifest["source_files"][0][field] = replacement
        elif field_owner == "source_bundle":
            manifest["source_bundles"][0][field] = replacement
        else:
            manifest["source_bundles"][0]["recovery"][field] = replacement

    _mutate_extraction_manifest(output, mutate)
    with pytest.raises(PortableCANError, match=message):
        load_recovered_can_extraction(output)


def test_recovered_extraction_rejects_unbound_source_bundle(tmp_path: Path) -> None:
    output = _build_v2_extraction(tmp_path)

    def mutate(manifest: dict[str, object]) -> None:
        source_file = manifest["source_files"][0]
        del source_file["source_bundle_sha256"]
        del source_file["source_bundle_manifest_sha256"]

    _mutate_extraction_manifest(output, mutate)
    with pytest.raises(PortableCANError, match="no matching source file"):
        load_recovered_can_extraction(output)


def test_recovered_discovery_report_preserves_manifest_and_source_provenance(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    extraction = _build_v2_extraction(tmp_path)
    extraction_manifest_bytes = (extraction / "manifest.json").read_bytes()
    extraction_manifest = json.loads(extraction_manifest_bytes)
    report_path = tmp_path / "recovered-discovery.json"

    assert (
        cli_main(
            [
                "discover-recovered-can",
                str(extraction),
                "--output",
                str(report_path),
            ]
        )
        == 0
    )
    capsys.readouterr()
    report = json.loads(report_path.read_text(encoding="utf-8"))
    provenance = report["recovery_provenance"]

    assert provenance["source_classification"] == "RECOVERED_PORTABLE_EVIDENCE"
    assert provenance["vehicle_claims_authorized"] is False
    assert provenance["required_display_label"] == "RECOVERED EVIDENCE • NOT LIVE"
    assert provenance["extraction_manifest"] == {
        "name": "manifest.json",
        "contract": "can.portable-evidence-extraction",
        "contract_version": "1.0.0",
        "byte_count": len(extraction_manifest_bytes),
        "sha256": hashlib.sha256(extraction_manifest_bytes).hexdigest(),
    }
    assert provenance["source_files"] == extraction_manifest["source_files"]
    assert provenance["source_bundles"] == extraction_manifest["source_bundles"]
    assert provenance["output_files"] == extraction_manifest["output_files"]
    assert report["source_files"] == [
        {
            "name": item["path"],
            "byte_count": item["byte_count"],
            "record_count": item["record_count"],
            "sha256": item["sha256"],
        }
        for item in extraction_manifest["output_files"]
    ]
    ContractCatalog.load().validate(report)


@pytest.mark.parametrize(
    "tamper",
    ["missing-provenance", "analysis-output", "output-path", "bundle-cross-link"],
)
def test_recovered_discovery_report_rejects_broken_provenance_cross_links(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], tamper: str
) -> None:
    extraction = _build_v2_extraction(tmp_path, tamper)
    report_path = tmp_path / f"{tamper}-report.json"
    assert (
        cli_main(
            [
                "discover-recovered-can",
                str(extraction),
                "--output",
                str(report_path),
            ]
        )
        == 0
    )
    capsys.readouterr()
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if tamper == "missing-provenance":
        del report["recovery_provenance"]
        message = "recovered authority has no recovery_provenance"
    elif tamper == "analysis-output":
        report["source_files"][0]["sha256"] = "e" * 64
        message = "analyzed source files"
    elif tamper == "output-path":
        report["recovery_provenance"]["output_files"][0]["path"] = (
            "sessions/esp32-9454c5b08d14/0000000001.ndjson"
        )
        report["source_files"][0]["name"] = (
            "sessions/esp32-9454c5b08d14/0000000001.ndjson"
        )
        message = "output path"
    else:
        report["recovery_provenance"]["source_files"][0][
            "source_bundle_manifest_sha256"
        ] = "f" * 64
        message = "bundle/file cross-link"

    with pytest.raises(ContractError, match=message):
        ContractCatalog.load().validate(report)


@pytest.mark.parametrize(
    ("field", "replacement", "message"),
    [
        ("source_sequence", "0100", "canonical unsigned decimal"),
        (
            "source_monotonic_microseconds",
            "02000000",
            "canonical unsigned decimal",
        ),
        ("source_id", "", "1 to 160 characters"),
        ("source_id", "x" * 161, "1 to 160 characters"),
        ("source_role", "UNKNOWN", "source_role is invalid"),
        ("message_type", 0, "message_type must be a byte"),
        ("ingested_at", "2026-08-22 16:36:18+00:00", "RFC 3339"),
        ("envelope_sha256", "A" * 64, "envelope_sha256 is invalid"),
    ],
)
def test_portable_frame_scalars_match_published_schema(
    tmp_path: Path, field: str, replacement: object, message: str
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    document = _portable_document(wire)
    document[field] = replacement
    source = tmp_path / f"bad-{field}.ndjson"
    _write_portable(source, [document])

    with pytest.raises(PortableCANError, match=message):
        extract_portable_can([source], tmp_path / f"bad-{field}-output")


def test_portable_source_id_accepts_schema_characters_and_160_character_limit(
    tmp_path: Path,
) -> None:
    handshake = _encode_gateway_frame(
        1, 99, 1_500_000, b'{"contract":"gateway.handshake"}'
    )
    live = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )
    source = tmp_path / "logical-frames.ndjson"
    schema_source_id = "vehicle source / \u0394" + "x" * (
        160 - len("vehicle source / \u0394")
    )
    _write_portable(
        source,
        [
            _portable_document(
                handshake, source_role="AC_SENSOR", source_id=schema_source_id
            ),
            _portable_document(live),
        ],
    )

    manifest = extract_portable_can([source], tmp_path / "recovered")

    assert manifest["statistics"]["portable_records"] == 2
    assert manifest["statistics"]["non_can_frames"] == 1


@pytest.mark.parametrize(
    ("creator_field", "maximum"),
    [
        ("application_id", 160),
        ("application_version", 80),
        ("device_model", 160),
    ],
)
def test_bundle_creator_rejects_strings_beyond_schema_limits(
    tmp_path: Path, creator_field: str, maximum: int
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )

    def mutate(manifest: dict[str, object]) -> None:
        manifest["creator"][creator_field] = "x" * (maximum + 1)

    bundle = tmp_path / f"creator-{creator_field}.vhossync"
    _write_sync_bundle(
        bundle,
        [_portable_document(wire)],
        version="1.0.0",
        mutate_manifest=mutate,
    )
    with pytest.raises(PortableCANError, match="bundle creator is invalid"):
        extract_portable_can([bundle], tmp_path / f"output-{creator_field}")


def test_bundle_creator_accepts_exact_schema_limits(tmp_path: Path) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )

    def mutate(manifest: dict[str, object]) -> None:
        manifest["creator"] = {
            "platform": "ANDROID",
            "application_id": "a" * 160,
            "application_version": "v" * 80,
            "device_model": "d" * 160,
        }

    bundle = tmp_path / "creator-limits.vhossync"
    _write_sync_bundle(
        bundle,
        [_portable_document(wire)],
        version="1.0.0",
        mutate_manifest=mutate,
    )

    manifest = extract_portable_can([bundle], tmp_path / "output")

    assert manifest["source_bundles"][0]["contract_version"] == "1.0.0"


def test_bundle_rejects_non_rfc3339_wall_time_and_uppercase_v1_digest(
    tmp_path: Path,
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )

    def invalid_time(manifest: dict[str, object]) -> None:
        manifest["created_at"] = "2026-08-22 16:36:18+00:00"

    bad_time = tmp_path / "bad-time.vhossync"
    _write_sync_bundle(
        bad_time,
        [_portable_document(wire)],
        version="1.0.0",
        mutate_manifest=invalid_time,
    )
    with pytest.raises(PortableCANError, match="identity or timestamp is invalid"):
        extract_portable_can([bad_time], tmp_path / "bad-time-output")

    uppercase = tmp_path / "uppercase-v1.vhossync"
    _write_sync_bundle(
        uppercase,
        [_portable_document(wire)],
        version="1.0.0",
        uppercase_segment_sha256=True,
    )
    with pytest.raises(PortableCANError, match="segment integrity metadata is invalid"):
        extract_portable_can([uppercase], tmp_path / "uppercase-output")


def test_bundle_leap_second_is_rejected_by_schema_and_python_loader(
    tmp_path: Path,
) -> None:
    wire = _encode_gateway_frame(
        LIVE_CAN_MESSAGE_TYPE,
        100,
        2_000_000,
        _encode_live_record(_observation()),
    )

    def leap_second(manifest: dict[str, object]) -> None:
        manifest["created_at"] = "2026-08-22T16:36:60Z"

    bundle = tmp_path / "leap-second.vhossync"
    _write_sync_bundle(
        bundle,
        [_portable_document(wire)],
        version="1.0.0",
        mutate_manifest=leap_second,
    )
    with zipfile.ZipFile(bundle) as archive:
        manifest = json.loads(archive.read("manifest.json"))

    with pytest.raises(ContractError, match="created_at"):
        ContractCatalog.load().validate(manifest)
    with pytest.raises(PortableCANError, match="identity or timestamp is invalid"):
        extract_portable_can([bundle], tmp_path / "leap-second-output")
