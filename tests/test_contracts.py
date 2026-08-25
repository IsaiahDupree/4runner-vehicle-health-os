import hashlib
import json
import struct

import pytest

from vhos.contracts import ContractCatalog, ContractError
from vhos.ids import deterministic_id


def test_all_json_schemas_are_valid() -> None:
    checked = ContractCatalog.load().check_schemas()

    assert len(checked) >= 23


def test_vehicle_interpretation_requires_evidence() -> None:
    catalog = ContractCatalog.load()
    claim = {
        "contract": "ai.claim",
        "contract_version": "1.0.0",
        "claim_id": deterministic_id("claim", "unsupported", timestamp_ms=1_000),
        "text": "The battery is failing.",
        "claim_type": "VEHICLE_OBSERVATION_INTERPRETATION",
        "evidence_refs": [],
        "confidence": 0.9,
        "hypothesis": False,
        "authority": "NON_AUTHORITATIVE",
    }

    with pytest.raises(ContractError, match="evidence_refs"):
        catalog.validate(claim)


def test_hypothesis_must_be_labeled() -> None:
    catalog = ContractCatalog.load()
    claim = {
        "contract": "ai.claim",
        "contract_version": "1.0.0",
        "claim_id": deterministic_id("claim", "hypothesis", timestamp_ms=1_000),
        "text": "A leak is one plausible cause.",
        "claim_type": "HYPOTHESIS",
        "evidence_refs": [
            deterministic_id("finding", "air-suspension", timestamp_ms=1_000)
        ],
        "confidence": 0.68,
        "hypothesis": False,
        "authority": "NON_AUTHORITATIVE",
    }

    with pytest.raises(ContractError, match="hypothesis"):
        catalog.validate(claim)


def test_recovery_sync_manifest_v2_requires_explicit_non_authority() -> None:
    catalog = ContractCatalog.load()
    manifest = {
        "contract": "vhos.evidence-sync-bundle",
        "contract_version": "2.0.0",
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
                "sha256": "a" * 64,
                "byte_count": 1,
                "record_count": 1,
            }
        ],
        "recovery": {
            "classification": "RECOVERED_PORTABLE_EVIDENCE",
            "vehicle_claims_authorized": False,
            "source_ledger_sha256": "a" * 64,
        },
    }

    catalog.validate(manifest)
    manifest["recovery"]["source_ledger_sha256"] = "b" * 64
    with pytest.raises(ContractError, match="source ledger SHA-256"):
        catalog.validate(manifest)
    manifest["recovery"]["source_ledger_sha256"] = "a" * 64
    manifest["recovery"]["vehicle_claims_authorized"] = True
    with pytest.raises(ContractError, match="vehicle_claims_authorized"):
        catalog.validate(manifest)


def test_import_provenance_receipt_binds_exact_record_links() -> None:
    catalog = ContractCatalog.load()
    links = [
        {"record_id": "esp32:1:" + "a" * 64, "record_sha256": "b" * 64},
        {"record_id": "esp32:2:" + "c" * 64, "record_sha256": "d" * 64},
    ]
    hasher = hashlib.sha256()
    for link in links:
        encoded = json.dumps(
            link, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        hasher.update(struct.pack(">Q", len(encoded)))
        hasher.update(encoded)
    receipt = {
        "contract": "vhos.portable-evidence-import-receipt",
        "contract_version": "2.0.0",
        "bundle_id": "11111111-2222-5333-8444-555555555555",
        "manifest_sha256": "1" * 64,
        "archive_sha256": "2" * 64,
        "creator": {
            "platform": "IOS",
            "application_id": "com.isaiahdupree.VehicleHealthOS",
            "application_version": "0.3.23",
            "device_model": "iPhone17,2",
        },
        "recovery": {
            "classification": "RECOVERED_PORTABLE_EVIDENCE",
            "vehicle_claims_authorized": False,
            "source_ledger_sha256": "3" * 64,
        },
        "record_count": len(links),
        "record_link_chain_sha256": hasher.hexdigest(),
        "record_links": links,
    }

    catalog.validate(receipt)
    receipt["record_links"][1]["record_id"] = "tampered"
    with pytest.raises(ContractError, match="record link chain"):
        catalog.validate(receipt)


def test_recovered_can_wrapper_preserves_explicit_non_authority() -> None:
    catalog = ContractCatalog.load()
    wrapper = {
        "contract": "can.recovered-passive-can-observation",
        "contract_version": "1.0.0",
        "source_classification": "RECOVERED_PORTABLE_EVIDENCE",
        "vehicle_claims_authorized": False,
        "observation": {
            "contract": "gateway.passive-can-observation",
            "contract_version": "1.0.0",
            "gateway_id": "esp32-field-node",
            "session_id": 42,
            "source_sequence": 10,
            "monotonic_microseconds": 1_000_000,
            "bitrate_bps": 500_000,
            "identifier": 0x2D0,
            "extended": False,
            "remote_request": False,
            "listen_only": True,
            "data_length": 8,
            "data": [1, 2, 3, 4, 5, 6, 7, 8],
            "evidence_source": "gateway-flash",
            "ingested_at": "2026-08-22T16:36:18Z",
        },
    }

    catalog.validate(wrapper)
    wrapper["vehicle_claims_authorized"] = True
    with pytest.raises(ContractError, match="vehicle_claims_authorized"):
        catalog.validate(wrapper)
