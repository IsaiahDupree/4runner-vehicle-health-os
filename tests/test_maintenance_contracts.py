from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from vhos.contracts import ContractCatalog, ContractError


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "contracts" / "examples" / "v1"
SOURCE_MANIFEST = (
    ROOT / "maintenance-rule-packs" / "drafts" / "toyota.4runner.2005" / "source-manifest.json"
)


def load(name: str) -> dict:
    return json.loads((EXAMPLES / name).read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def catalog() -> ContractCatalog:
    return ContractCatalog.load()


@pytest.mark.parametrize(
    "name",
    [
        "vehicle-asset.json",
        "vehicle-component-revision.json",
        "maintenance-record-revision.json",
        "maintenance-audit-event.json",
        "maintenance-requirement.json",
    ],
)
def test_examples_validate(catalog: ContractCatalog, name: str) -> None:
    catalog.validate(load(name))


def test_inactive_toyota_source_manifest_validates_and_cannot_claim_active(catalog: ContractCatalog) -> None:
    document = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    catalog.validate(document)
    assert document["activated"] is False
    assert document["status"] == "SOURCE_REVIEW_REQUIRED"
    assert document["activation_blockers"]

    document["status"] = "ACTIVE"
    with pytest.raises(ContractError, match="inactive manifest claims ACTIVE"):
        catalog.validate(document)


def test_source_manifest_activation_requires_all_executable_gates(catalog: ContractCatalog) -> None:
    document = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    document["activated"] = True
    document["status"] = "ACTIVE"
    document["activation_blockers"] = []

    with pytest.raises(ContractError, match="vehicle.maintenance-source-manifest validation failed"):
        catalog.validate(document)


def test_source_manifest_scope_covers_usage_schedule_and_explanations(catalog: ContractCatalog) -> None:
    document = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    scope = {item["locator_key"]: item for item in document["review_scope"]}
    assert (scope["guide.usage_and_special_conditions"]["printed_page_start"], scope["guide.usage_and_special_conditions"]["pdf_page_start"]) == (3, 5)
    assert (scope["guide.suv_and_truck_schedule"]["printed_page_start"], scope["guide.suv_and_truck_schedule"]["printed_page_end"]) == (20, 35)
    assert (scope["guide.maintenance_item_explanations"]["printed_page_start"], scope["guide.maintenance_item_explanations"]["printed_page_end"]) == (36, 39)


def test_vehicle_asset_rejects_odometer_unit_mismatch(catalog: ContractCatalog) -> None:
    document = load("vehicle-asset.json")
    document["current_odometer"]["unit"] = "KILOMETERS"
    with pytest.raises(ContractError, match="vehicle.asset validation failed"):
        catalog.validate(document)


def test_vehicle_asset_rejects_duplicate_configuration_and_unbound_pack(catalog: ContractCatalog) -> None:
    document = load("vehicle-asset.json")
    document["configuration"]["attributes"].append(copy.deepcopy(document["configuration"]["attributes"][0]))
    with pytest.raises(ContractError, match="duplicate configuration attributes"):
        catalog.validate(document)

    document = load("vehicle-asset.json")
    document["active_vehicle_pack"] = {
        "pack_id": "toyota.4runner.2005.us", "pack_version": "1.0.0",
        "source_manifest_sha256": "a" * 64, "activated_at": "2026-08-30T12:00:00Z",
        "applicability_status": "MATCHED", "matched_vehicle_revision_id": "vehrev_0000000000000000000000000F"
    }
    with pytest.raises(ContractError, match="active pack is not bound"):
        catalog.validate(document)


def test_occurrence_can_be_date_only_but_cannot_fake_an_instant(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    catalog.validate(document)
    document["occurrence"]["instant"] = "2026-08-30T12:15:00Z"
    with pytest.raises(ContractError, match="vehicle.maintenance-record validation failed"):
        catalog.validate(document)


def test_new_maintenance_record_cannot_start_voided(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["state"] = "VOIDED"
    document["amendment_reason"] = "Entered against the wrong vehicle."
    with pytest.raises(ContractError, match="vehicle.maintenance-record validation failed"):
        catalog.validate(document)


def test_amended_record_requires_reason(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["supersedes_revision_id"] = "maintrev_0000000000000000000000000G"
    with pytest.raises(ContractError, match="vehicle.maintenance-record validation failed"):
        catalog.validate(document)


def test_unknown_system_and_component_are_explicitly_valid(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["systems"] = [{"knowledge": "UNKNOWN", "system_key": None, "display_name": None}]
    document["components"] = [{
        "component_knowledge": "UNKNOWN", "component_id": None, "display_name": None,
        "system_knowledge": "UNKNOWN", "system_key": None, "parent_component_id": None
    }]
    catalog.validate(document)


def test_component_must_reference_declared_known_system(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["components"][0]["system_key"] = "steering"
    with pytest.raises(ContractError, match="component references an undeclared system"):
        catalog.validate(document)


def test_numeric_measurement_requires_unit(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["measurements"][0]["unit"] = None
    with pytest.raises(ContractError, match="vehicle.maintenance-record validation failed"):
        catalog.validate(document)


@pytest.mark.parametrize("quantity", ["0", "0.0", "-1", "01", "1e3"])
def test_line_item_quantity_rejects_zero_negative_and_noncanonical_forms(catalog: ContractCatalog, quantity: str) -> None:
    document = load("maintenance-record-revision.json")
    document["line_items"] = [{
        "line_item_id": "lineitem_0000000000000000000000000H", "type": "FLUID",
        "description": "Engine oil", "manufacturer": None, "part_number": None,
        "specification": None, "quantity": quantity, "quantity_unit": "quart", "cost": None
    }]
    with pytest.raises(ContractError):
        catalog.validate(document)


def test_canonical_exponent_decimal_is_supported(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["engine_hours"] = "1E+3"
    catalog.validate(document)


def test_currency_warranty_integer_bounds_and_whitespace_are_enforced(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["total_cost"] = {"currency_code": "ZZZ", "minor_units": 100}
    with pytest.raises(ContractError, match="recognized ISO 4217"):
        catalog.validate(document)

    document = load("maintenance-record-revision.json")
    document["warranty"] = {"provider": "Shop", "starts_on": "2026-08-30", "expires_on": "2026-08-29", "distance_limit": None, "terms": None, "document_attachment_ids": []}
    with pytest.raises(ContractError, match="warranty expiry precedes start"):
        catalog.validate(document)

    document = load("maintenance-record-revision.json")
    document["custom_fields"][0] = {"field_id": "inspection.counter", "label": "Counter", "type": "INTEGER", "value": "9223372036854775808", "unit": None}
    with pytest.raises(ContractError, match="signed 64-bit"):
        catalog.validate(document)

    document = load("maintenance-record-revision.json")
    document["title"] = " Front brake inspection"
    with pytest.raises(ContractError, match="whitespace"):
        catalog.validate(document)


def test_completion_reference_must_bind_due_and_baseline_by_role(catalog: ContractCatalog) -> None:
    document = load("maintenance-record-revision.json")
    document["completion_references"] = [{
        "requirement_id": "requirement_00000000000000000000000008", "requirement_version": "1.0.0",
        "vehicle_pack_id": "toyota.4runner.2005.us", "vehicle_pack_version": "1.0.0",
        "source_manifest_sha256": "a" * 64, "task_id": "mainttask_00000000000000000000000009",
        "rule_id": "maintrule_0000000000000000000000000A", "rule_sha256": "b" * 64,
        "completion_role": "DUE_INSTANCE", "due_instance_id": None, "baseline_id": None,
        "effect": "SATISFIES_REQUIREMENT"
    }]
    with pytest.raises(ContractError, match="DUE_INSTANCE reference shape"):
        catalog.validate(document)


def test_component_lifecycle_rejects_self_parent_and_reverse_dates(catalog: ContractCatalog) -> None:
    document = load("vehicle-component-revision.json")
    document["parent_component_id"] = document["component_id"]
    with pytest.raises(ContractError, match="component cannot parent itself"):
        catalog.validate(document)


def test_audit_amendment_requires_prior_revision_and_reason(catalog: ContractCatalog) -> None:
    document = load("maintenance-audit-event.json")
    document["action"] = "AMENDED"
    with pytest.raises(ContractError, match="vehicle.maintenance-audit-event validation failed"):
        catalog.validate(document)
