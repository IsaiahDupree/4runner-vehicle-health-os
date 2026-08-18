import pytest

from vhos.contracts import ContractCatalog, ContractError
from vhos.ids import deterministic_id


def test_all_json_schemas_are_valid() -> None:
    checked = ContractCatalog.load().check_schemas()

    assert len(checked) >= 19


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
