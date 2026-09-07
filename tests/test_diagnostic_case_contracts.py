from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from vhos.contracts import ContractCatalog, ContractError


ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "contracts" / "examples" / "v1" / "diagnostic-case-draft.json"

STATUSES = ("INTAKE", "INSPECTION", "FINDINGS", "VERIFY", "CLOSED", "VOIDED")
ACTIONS = (
    "CREATED",
    "AMENDED",
    "INSPECTION_STARTED",
    "FINDINGS_RECORDED",
    "VERIFICATION_STARTED",
    "CLOSED",
    "VOIDED",
)
VALID_TRANSITIONS = {
    ("CREATED", None, "INTAKE"),
    ("AMENDED", "INTAKE", "INTAKE"),
    ("AMENDED", "INSPECTION", "INSPECTION"),
    ("AMENDED", "FINDINGS", "FINDINGS"),
    ("AMENDED", "VERIFY", "VERIFY"),
    ("AMENDED", "CLOSED", "CLOSED"),
    ("INSPECTION_STARTED", "INTAKE", "INSPECTION"),
    ("FINDINGS_RECORDED", "INSPECTION", "FINDINGS"),
    ("VERIFICATION_STARTED", "FINDINGS", "VERIFY"),
    ("CLOSED", "VERIFY", "CLOSED"),
    ("VOIDED", "INTAKE", "VOIDED"),
    ("VOIDED", "INSPECTION", "VOIDED"),
    ("VOIDED", "FINDINGS", "VOIDED"),
    ("VOIDED", "VERIFY", "VOIDED"),
    ("VOIDED", "CLOSED", "VOIDED"),
}


def load() -> dict:
    return json.loads(EXAMPLE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def catalog() -> ContractCatalog:
    return ContractCatalog.load()


def case_for_transition(
    action: str, from_status: str | None, to_status: str
) -> dict:
    document = load()
    document["status"] = to_status
    document["transition"] = {
        "action": action,
        "from_status": from_status,
        "to_status": to_status,
        "reason": "Required workflow reason" if action in {"AMENDED", "VOIDED"} else None,
    }
    if action == "CREATED":
        document["revision_id"] = "caserev_00000000000000000000000001"
        document["supersedes_revision_id"] = None
        document["revision_number"] = 1
    else:
        document["revision_id"] = "caserev_00000000000000000000000006"
        document["supersedes_revision_id"] = "caserev_00000000000000000000000005"
        document["revision_number"] = 6
    return document


def evidence(document: dict, evidence_type: str) -> dict:
    return next(item for item in document["evidence"] if item["type"] == evidence_type)


def test_complete_draft_example_validates(catalog: ContractCatalog) -> None:
    catalog.validate(load())


def test_first_revision_is_created_intake_without_a_predecessor(
    catalog: ContractCatalog,
) -> None:
    document = case_for_transition("CREATED", None, "INTAKE")
    catalog.validate(document)


@pytest.mark.parametrize("transition", sorted(VALID_TRANSITIONS, key=repr))
def test_every_allowed_transition_validates(
    catalog: ContractCatalog, transition: tuple[str, str | None, str]
) -> None:
    catalog.validate(case_for_transition(*transition))


def test_every_unlisted_transition_fails_closed(catalog: ContractCatalog) -> None:
    from_states = (None, *STATUSES)
    for action in ACTIONS:
        for from_status in from_states:
            for to_status in STATUSES:
                transition = (action, from_status, to_status)
                if transition in VALID_TRANSITIONS:
                    continue
                with pytest.raises(ContractError):
                    catalog.validate(case_for_transition(*transition))


def test_transition_destination_must_match_snapshot_status(
    catalog: ContractCatalog,
) -> None:
    document = load()
    document["status"] = "FINDINGS"
    with pytest.raises(ContractError, match="destination does not match status"):
        catalog.validate(document)


def test_revision_cannot_supersede_itself(catalog: ContractCatalog) -> None:
    document = load()
    document["supersedes_revision_id"] = document["revision_id"]
    with pytest.raises(ContractError, match="revision cannot supersede itself"):
        catalog.validate(document)


def test_first_and_later_revision_shapes_are_enforced(catalog: ContractCatalog) -> None:
    document = load()
    document["supersedes_revision_id"] = None
    with pytest.raises(ContractError):
        catalog.validate(document)

    document = case_for_transition("CREATED", None, "INTAKE")
    document["revision_number"] = 2
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize(
    ("field", "invalid"),
    [
        ("authority", "VEHICLE_VALIDATED"),
        ("vehicle_claims_authorized", True),
        ("maintenance_history_authorized", True),
    ],
)
def test_draft_cannot_claim_external_authority(
    catalog: ContractCatalog, field: str, invalid: object
) -> None:
    document = load()
    document[field] = invalid
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_actor_enums_have_no_ai_authority(catalog: ContractCatalog) -> None:
    document = load()
    document["actor"]["source"] = "AI"
    with pytest.raises(ContractError):
        catalog.validate(document)

    document = load()
    document["finding"]["actor"]["source"] = "AI"
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize("source", ["OWNER", "IMPORT", "SYSTEM"])
def test_case_actor_must_be_a_technician(
    catalog: ContractCatalog, source: str
) -> None:
    document = load()
    document["actor"]["source"] = source
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_finding_must_be_recorded_by_a_technician(catalog: ContractCatalog) -> None:
    document = load()
    document["finding"]["actor"]["source"] = "SYSTEM"
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize("field", ["value", "unit", "method"])
def test_measurement_requires_value_unit_and_method(
    catalog: ContractCatalog, field: str
) -> None:
    document = load()
    evidence(document, "MEASUREMENT")[field] = None
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_optional_numeric_value_and_unit_are_a_pair(catalog: ContractCatalog) -> None:
    document = load()
    observation = evidence(document, "OBSERVATION")
    observation["value"] = "1"
    observation["unit"] = None
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize("dtc_code", ["p0300", "P4300", "P03", "0300", "P0G00"])
def test_dtc_code_uses_canonical_five_character_format(
    catalog: ContractCatalog, dtc_code: str
) -> None:
    document = load()
    evidence(document, "DTC")["dtc_code"] = dtc_code
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_non_dtc_evidence_cannot_carry_a_dtc_code(catalog: ContractCatalog) -> None:
    document = load()
    evidence(document, "OBSERVATION")["dtc_code"] = "P0300"
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize("evidence_type", ["PHOTO", "VIDEO", "AUDIO", "DOCUMENT", "SCAN_REPORT"])
def test_attachment_evidence_requires_content_addressed_metadata(
    catalog: ContractCatalog, evidence_type: str
) -> None:
    document = load()
    scan_report = evidence(document, "SCAN_REPORT")
    scan_report["type"] = evidence_type
    scan_report["attachment"] = None
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_attachment_hash_is_structurally_verified(catalog: ContractCatalog) -> None:
    document = load()
    evidence(document, "SCAN_REPORT")["attachment"]["sha256"] = "not-a-digest"
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_nullable_ui_fields_are_present_and_email_is_valid(
    catalog: ContractCatalog,
) -> None:
    document = load()
    document["customer"]["email"] = "not-an-email"
    with pytest.raises(ContractError):
        catalog.validate(document)

    document = load()
    del document["complaint"]["prior_work"]
    with pytest.raises(ContractError):
        catalog.validate(document)

    document = load()
    del evidence(document, "DTC")["expected_result_source"]
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_duplicate_domain_identities_are_rejected(catalog: ContractCatalog) -> None:
    document = load()
    document["evidence"].append(copy.deepcopy(document["evidence"][0]))
    with pytest.raises(ContractError, match="duplicate evidence identity"):
        catalog.validate(document)

    document = load()
    document["hypotheses"].append(copy.deepcopy(document["hypotheses"][0]))
    with pytest.raises(ContractError, match="duplicate hypothesis identity"):
        catalog.validate(document)

    document = load()
    duplicate_attachment = copy.deepcopy(evidence(document, "SCAN_REPORT"))
    duplicate_attachment["evidence_id"] = "evidence_0000000000000000000000000C"
    document["evidence"].append(duplicate_attachment)
    with pytest.raises(ContractError, match="duplicate attachment identity"):
        catalog.validate(document)


def test_hypothesis_evidence_links_must_be_unique_and_resolve(
    catalog: ContractCatalog,
) -> None:
    document = load()
    document["hypotheses"][0]["evidence_links"][0]["evidence_id"] = (
        "evidence_0000000000000000000000000Z"
    )
    with pytest.raises(ContractError, match="hypothesis references absent evidence"):
        catalog.validate(document)

    document = load()
    document["hypotheses"][0]["evidence_links"].append(
        copy.deepcopy(document["hypotheses"][0]["evidence_links"][0])
    )
    with pytest.raises(ContractError, match="hypothesis repeats evidence identity"):
        catalog.validate(document)


def test_verification_evidence_links_must_resolve(catalog: ContractCatalog) -> None:
    document = load()
    document["verification"]["evidence_ids"] = [
        "evidence_0000000000000000000000000Z"
    ]
    with pytest.raises(ContractError, match="verification references absent evidence"):
        catalog.validate(document)


@pytest.mark.parametrize("status", ["VERIFY", "CLOSED"])
def test_verify_and_closed_require_a_technician_finding(
    catalog: ContractCatalog, status: str
) -> None:
    document = load()
    document["status"] = status
    document["transition"]["to_status"] = status
    if status == "VERIFY":
        document["transition"]["action"] = "VERIFICATION_STARTED"
        document["transition"]["from_status"] = "FINDINGS"
    document["finding"] = None
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_closed_requires_a_verification_record(catalog: ContractCatalog) -> None:
    document = load()
    document["verification"] = None
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize("action", ["AMENDED", "VOIDED"])
def test_reasoned_mutations_require_a_reason(
    catalog: ContractCatalog, action: str
) -> None:
    transition = (
        (action, "CLOSED", "CLOSED")
        if action == "AMENDED"
        else (action, "CLOSED", "VOIDED")
    )
    document = case_for_transition(*transition)
    document["transition"]["reason"] = None
    with pytest.raises(ContractError, match="transition reason is required"):
        catalog.validate(document)


def test_not_performed_verification_requires_reason_and_no_evidence(
    catalog: ContractCatalog,
) -> None:
    document = load()
    document["verification"] = {
        "outcome": "NOT_PERFORMED",
        "method": None,
        "reason": "Customer declined post-repair verification.",
        "evidence_ids": [],
        "recorded_at": "2026-09-07T15:30:00Z",
    }
    catalog.validate(document)

    document["verification"]["reason"] = None
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize("field", ["method", "evidence_ids"])
def test_performed_verification_requires_method_and_evidence(
    catalog: ContractCatalog, field: str
) -> None:
    document = load()
    document["verification"][field] = None if field == "method" else []
    with pytest.raises(ContractError):
        catalog.validate(document)


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("customer", "display_name"), " Customer"),
        (("complaint", "operating_conditions"), "overnight "),
        (("finding", "next_action"), " Inspect"),
        (("evidence", 0, "test_point"), " battery terminal "),
    ],
)
def test_user_entered_text_must_be_trimmed(
    catalog: ContractCatalog, path: tuple[object, ...], value: str
) -> None:
    root = load()
    document: object = root
    for part in path[:-1]:
        document = document[part]  # type: ignore[index]
    document[path[-1]] = value  # type: ignore[index]
    with pytest.raises(ContractError, match="surrounding whitespace"):
        catalog.validate(root)
