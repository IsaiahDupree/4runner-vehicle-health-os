from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from vhos.contracts import ContractCatalog, ContractError


EXAMPLES = Path(__file__).resolve().parents[1] / "contracts" / "examples" / "v1"


def _load(name: str) -> dict[str, object]:
    return json.loads((EXAMPLES / name).read_text(encoding="utf-8"))


def test_all_discovery_interop_examples_validate() -> None:
    catalog = ContractCatalog.load()
    examples = sorted(EXAMPLES.glob("discovery-*.json"))

    assert len(examples) == 9
    for path in examples:
        catalog.validate(json.loads(path.read_text(encoding="utf-8")))


def test_observed_and_candidate_records_cannot_claim_more_authority() -> None:
    catalog = ContractCatalog.load()
    for name in (
        "discovery-capture-session.real-can-2026-08-18.json",
        "discovery-event-marker.real-can-2026-08-18.json",
        "discovery-candidate-signal.real-can-2026-08-18.json",
    ):
        document = _load(name)
        document["authority"] = "PROMOTED"
        with pytest.raises(ContractError):
            catalog.validate(document)


def test_promotion_decision_fails_closed_on_contradictory_wire_state() -> None:
    catalog = ContractCatalog.load()
    blocked = _load("discovery-signal-promotion-decision.blocked.json")

    contradictory = copy.deepcopy(blocked)
    contradictory["promotion_allowed"] = True
    with pytest.raises(ContractError):
        catalog.validate(contradictory)

    no_blockers = copy.deepcopy(blocked)
    no_blockers["blockers"] = []
    with pytest.raises(ContractError):
        catalog.validate(no_blockers)


def test_vehicle_validated_checklist_requires_complete_reviewed_evidence() -> None:
    catalog = ContractCatalog.load()
    incomplete = _load("discovery-signal-validation-checklist.blocked.json")
    incomplete["authority"] = "VEHICLE_VALIDATED"
    with pytest.raises(ContractError):
        catalog.validate(incomplete)


def test_capture_session_rejects_conflicting_duplicate_marker_identity() -> None:
    catalog = ContractCatalog.load()
    capture = _load("discovery-capture-session.real-can-2026-08-18.json")
    marker = _load("discovery-event-marker.real-can-2026-08-18.json")
    conflicting = copy.deepcopy(marker)
    conflicting["label"] = "A different assertion under the same immutable identity"
    capture["event_markers"] = [marker, conflicting]

    with pytest.raises(ContractError, match="duplicate event_markers identity"):
        catalog.validate(capture)


def test_capture_session_rejects_marker_outside_declared_lineage() -> None:
    catalog = ContractCatalog.load()
    capture = _load("discovery-capture-session.real-can-2026-08-18.json")
    marker = _load("discovery-event-marker.real-can-2026-08-18.json")
    marker["gateway_session_id"] = 1
    capture["event_markers"] = [marker]

    with pytest.raises(ContractError, match="event_markers session mismatch"):
        catalog.validate(capture)
