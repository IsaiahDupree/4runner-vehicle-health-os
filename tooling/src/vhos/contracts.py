from __future__ import annotations

import json
import hashlib
import struct
from datetime import date
from decimal import Decimal, InvalidOperation
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


class ContractError(ValueError):
    pass


ISO_4217_CODES = frozenset(
    "AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWL".split()
)


SCHEMA_BY_CONTRACT = {
    "ai.claim": "ai-claim.schema.json",
    "can.discovery.report": "can-discovery-report.schema.json",
    "can.signal-hypothesis-evaluation": "can-signal-hypothesis-evaluation.schema.json",
    "can.signal-hypothesis-pack": "can-signal-hypothesis-pack.schema.json",
    "can.replay.corpus": "can-replay-corpus.schema.json",
    "can.marker-correlation-report": "can-marker-correlation-report.schema.json",
    "vhos.field-return-analysis": "field-return-analysis.schema.json",
    "transport.link-reliability-matrix": "transport-link-reliability-matrix.schema.json",
    "calculation.run": "calculation-run.schema.json",
    "can.reference-correlation-report": "can-reference-correlation-report.schema.json",
    "can.recovered-passive-can-observation": "recovered-passive-can-observation.schema.json",
    "capture.bundle.manifest": "capture-bundle-manifest.schema.json",
    "vhos.discovery.capture-session": "discovery-capture-session.schema.json",
    "vhos.discovery.evidence-summary": "discovery-evidence-summary.schema.json",
    "vhos.discovery.boolean-candidate-evaluation": "discovery-boolean-candidate-evaluation.schema.json",
    "vhos.discovery.test-template": "discovery-test-template.schema.json",
    "vhos.discovery.event-marker": "discovery-event-marker.schema.json",
    "vhos.discovery.physical-measurement": "discovery-physical-measurement.schema.json",
    "vhos.discovery.vehicle-capability-snapshot": "discovery-vehicle-capability-snapshot.schema.json",
    "vhos.discovery.candidate-signal": "discovery-candidate-signal.schema.json",
    "vhos.discovery.signal-validation-checklist": "discovery-signal-validation-checklist.schema.json",
    "vhos.discovery.signal-promotion-decision": "discovery-signal-promotion-decision.schema.json",
    "vhos.discovery.recommended-test": "discovery-recommended-test.schema.json",
    "evidence.outbox-envelope": "evidence-outbox-envelope.schema.json",
    "vhos.evidence-sync-bundle": "evidence-sync-bundle.schema.json",
    "vhos.portable-evidence-import-receipt": "portable-evidence-import-receipt.schema.json",
    "equation.definition": "equation-definition.schema.json",
    "platform.head-unit-inventory": "head-unit-inventory.schema.json",
    "raw.observation": "raw-observation.schema.json",
    "obd.j1979-response": "j1979-response.schema.json",
    "obd.j1979-standard-sample": "j1979-standard-sample.schema.json",
    "obd.j1979-supported-pids": "j1979-supported-pids.schema.json",
    "sensor.node.post": "sensor-node-post.schema.json",
    "sensor.node.telemetry": "sensor-node-telemetry.schema.json",
    "signal.definition": "signal-definition.schema.json",
    "signal.sample": "signal-sample.schema.json",
    "vehicle.configuration-profile": "vehicle-profile.schema.json",
    "vehicle.asset": "vehicle-asset.schema.json",
    "vehicle.component-registry-entry": "vehicle-component-revision.schema.json",
    "vehicle.maintenance-record": "maintenance-record-revision.schema.json",
    "vehicle.maintenance-audit-event": "maintenance-audit-event.schema.json",
    "vehicle.maintenance-requirement": "maintenance-requirement.schema.json",
    "vehicle.maintenance-source-manifest": "maintenance-source-manifest.schema.json",
    "vehicle.digital-twin.snapshot": "vehicle-digital-twin-snapshot.schema.json",
    "vehicle.health-assessment": "vehicle-health-assessment.schema.json",
}


def default_schema_directory() -> Path:
    return Path(__file__).resolve().parents[3] / "contracts" / "jsonschema" / "v1"


@dataclass(frozen=True)
class ContractCatalog:
    schema_directory: Path
    schemas: dict[str, dict[str, Any]]
    registry: Registry

    @classmethod
    def load(cls, schema_directory: Path | None = None) -> "ContractCatalog":
        directory = (schema_directory or default_schema_directory()).resolve()
        if not directory.is_dir():
            raise ContractError(f"Schema directory does not exist: {directory}")

        schemas: dict[str, dict[str, Any]] = {}
        resources: list[tuple[str, Resource[Any]]] = []
        for path in sorted(directory.glob("*.schema.json")):
            try:
                schema = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ContractError(
                    f"Unable to read schema {path.name}: {exc}"
                ) from exc
            schema_id = schema.get("$id")
            if not isinstance(schema_id, str) or not schema_id:
                raise ContractError(f"Schema {path.name} has no non-empty $id")
            if schema_id in schemas:
                raise ContractError(f"Duplicate schema $id: {schema_id}")
            schemas[schema_id] = schema
            resources.append((schema_id, Resource.from_contents(schema)))

        registry = Registry().with_resources(resources)
        return cls(directory, schemas, registry)

    def check_schemas(self) -> list[str]:
        checked: list[str] = []
        for schema_id, schema in sorted(self.schemas.items()):
            try:
                Draft202012Validator.check_schema(schema)
            except Exception as exc:
                raise ContractError(f"Invalid schema {schema_id}: {exc}") from exc
            checked.append(schema_id)
        return checked

    def schema_for_contract(self, contract: str) -> dict[str, Any]:
        filename = SCHEMA_BY_CONTRACT.get(contract)
        if filename is None:
            raise ContractError(f"No schema registered for contract {contract!r}")
        schema_id = f"https://schemas.vhos.dev/v1/{filename}"
        try:
            return self.schemas[schema_id]
        except KeyError as exc:
            raise ContractError(f"Registered schema is missing: {schema_id}") from exc

    def validate(self, document: dict[str, Any]) -> None:
        contract = document.get("contract")
        if not isinstance(contract, str):
            raise ContractError("Document has no string contract field")
        schema = self.schema_for_contract(contract)
        validator = Draft202012Validator(
            schema,
            registry=self.registry,
            format_checker=FormatChecker(),
        )
        errors = sorted(
            validator.iter_errors(document), key=lambda item: list(item.path)
        )
        if errors:
            details = "; ".join(
                _format_error(error.path, error.message) for error in errors
            )
            raise ContractError(f"{contract} validation failed: {details}")
        _validate_contract_semantics(contract, document)


def _validate_contract_semantics(contract: str, document: dict[str, Any]) -> None:
    if contract == "vhos.evidence-sync-bundle":
        if document["contract_version"] == "2.0.0":
            segment_sha256 = document["segments"][0]["sha256"]
            source_ledger_sha256 = document["recovery"]["source_ledger_sha256"]
            if segment_sha256 != source_ledger_sha256:
                raise ContractError(
                    f"{contract} semantic validation failed: recovery source ledger SHA-256 "
                    "does not match the canonical segment"
                )
        return

    if contract == "vhos.portable-evidence-import-receipt":
        links = document["record_links"]
        if document["record_count"] != len(links):
            raise ContractError(
                f"{contract} semantic validation failed: record_count does not match record_links"
            )
        hasher = hashlib.sha256()
        for link in links:
            encoded = json.dumps(
                link, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            hasher.update(struct.pack(">Q", len(encoded)))
            hasher.update(encoded)
        if document["record_link_chain_sha256"] != hasher.hexdigest():
            raise ContractError(
                f"{contract} semantic validation failed: record link chain SHA-256 mismatch"
            )
        return

    if contract == "can.discovery.report":
        _validate_recovered_discovery_provenance(document)
        return

    if contract == "vehicle.asset":
        if document["revision_id"] == document["supersedes_revision_id"]:
            raise ContractError(
                f"{contract} semantic validation failed: revision cannot supersede itself"
            )
        _validate_vehicle_asset(document)
        return

    if contract == "vehicle.component-registry-entry":
        _validate_component_revision(document)
        return

    if contract == "vehicle.maintenance-record":
        _validate_maintenance_record(document)
        return

    if contract == "vehicle.maintenance-audit-event":
        if document["revision_id"] == document["prior_revision_id"]:
            raise ContractError(
                f"{contract} semantic validation failed: revision cannot be its own prior revision"
            )
        return

    if contract == "vehicle.maintenance-requirement":
        _validate_maintenance_requirement(document)
        return

    if contract == "vehicle.maintenance-source-manifest":
        _validate_maintenance_source_manifest(document)
        return

    if contract != "vhos.discovery.capture-session":
        return

    capture_id = document["id"]
    start = document["start_monotonic_microseconds"]
    end = document["end_monotonic_microseconds"]
    first_sequence = document["first_source_sequence"]
    last_sequence = document["last_source_sequence"]
    gateway_sessions = set(document["gateway_session_ids"])
    if start > end:
        raise ContractError(
            f"{contract} semantic validation failed: capture time is reversed"
        )
    if first_sequence > last_sequence:
        raise ContractError(
            f"{contract} semantic validation failed: source sequence is reversed"
        )

    for collection_name in ("event_markers", "physical_measurements"):
        records = document[collection_name]
        identities = [record["id"] for record in records]
        if len(identities) != len(set(identities)):
            raise ContractError(
                f"{contract} semantic validation failed: duplicate {collection_name} identity"
            )
        for record in records:
            if record["capture_id"] != capture_id:
                raise ContractError(
                    f"{contract} semantic validation failed: {collection_name} capture mismatch"
                )
            monotonic = record["gateway_monotonic_microseconds"]
            if monotonic < start or monotonic > end:
                raise ContractError(
                    f"{contract} semantic validation failed: {collection_name} time outside capture"
                )
            gateway_session_id = record.get("gateway_session_id")
            if (
                gateway_session_id is not None
                and gateway_session_id not in gateway_sessions
            ):
                raise ContractError(
                    f"{contract} semantic validation failed: {collection_name} session mismatch"
                )
            nearest_sequence = record.get("nearest_can_sequence")
            if (
                nearest_sequence is not None
                and not first_sequence <= nearest_sequence <= last_sequence
            ):
                raise ContractError(
                    f"{contract} semantic validation failed: {collection_name} sequence outside capture"
                )


def _validate_recovered_discovery_provenance(document: dict[str, Any]) -> None:
    provenance = document.get("recovery_provenance")
    recovered_authority = document["authority"].startswith(
        "RECOVERED_PORTABLE_EVIDENCE; vehicle_claims_authorized=false."
    )
    if provenance is None:
        if recovered_authority:
            raise ContractError(
                "can.discovery.report semantic validation failed: recovered authority has no "
                "recovery_provenance"
            )
        return
    if not recovered_authority:
        raise ContractError(
            "can.discovery.report semantic validation failed: recovery_provenance is not bound "
            "to recovered non-authority"
        )

    output_files = provenance["output_files"]
    if len({item["path"] for item in output_files}) != len(output_files):
        raise ContractError(
            "can.discovery.report semantic validation failed: repeated extraction output file"
        )
    for output_file in output_files:
        expected_path = (
            f"sessions/{output_file['gateway_id']}/{output_file['session_id']}.ndjson"
        )
        if output_file["path"] != expected_path:
            raise ContractError(
                "can.discovery.report semantic validation failed: extraction output path is not "
                "bound to its gateway and session identity"
            )
    expected_analysis_sources = [
        {
            "name": item["path"],
            "byte_count": item["byte_count"],
            "record_count": item["record_count"],
            "sha256": item["sha256"],
        }
        for item in output_files
    ]
    if document["source_files"] != expected_analysis_sources:
        raise ContractError(
            "can.discovery.report semantic validation failed: analyzed source files are not "
            "the extraction manifest outputs"
        )

    source_files = provenance["source_files"]
    source_bundles = provenance["source_bundles"]
    if len({item["name"] for item in source_files}) != len(source_files):
        raise ContractError(
            "can.discovery.report semantic validation failed: repeated original source file"
        )
    if len({item["name"] for item in source_bundles}) != len(source_bundles) or len(
        {item["sha256"] for item in source_bundles}
    ) != len(source_bundles):
        raise ContractError(
            "can.discovery.report semantic validation failed: ambiguous original source bundle"
        )

    bundles_by_sha = {item["sha256"]: item for item in source_bundles}
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
            raise ContractError(
                "can.discovery.report semantic validation failed: original source bundle/file "
                "cross-link is invalid"
            )
        files_by_bundle[bundle_sha256].append(source_file)

    for bundle_sha256, bundle in bundles_by_sha.items():
        bundled_files = files_by_bundle[bundle_sha256]
        if not bundled_files:
            raise ContractError(
                "can.discovery.report semantic validation failed: original source bundle has no "
                "matching source file"
            )
        if bundle["contract_version"] == "2.0.0":
            expected_name = f"{bundle['name']}!segments/logical-frames.ndjson"
            if (
                len(bundled_files) != 1
                or bundled_files[0]["name"] != expected_name
                or bundled_files[0]["sha256"]
                != bundle["recovery"]["source_ledger_sha256"]
            ):
                raise ContractError(
                    "can.discovery.report semantic validation failed: recovered v2 source ledger "
                    "cross-link is invalid"
                )


def _validate_vehicle_asset(document: dict[str, Any]) -> None:
    contract = "vehicle.asset"
    _validate_trimmed_text(document, contract)
    attributes = document["configuration"]["attributes"]
    _require_unique(attributes, "key", contract, "configuration attributes")
    severe_use = document["severe_use_conditions"]
    _require_unique(severe_use, "condition_key", contract, "severe-use conditions")
    if document["configuration"]["resolution_status"] == "RESOLVED" and any(
        item["state"] == "UNKNOWN" for item in attributes
    ):
        raise ContractError(
            f"{contract} semantic validation failed: resolved configuration contains UNKNOWN"
        )
    active_pack = document["active_vehicle_pack"]
    if active_pack is not None and active_pack["matched_vehicle_revision_id"] != document["revision_id"]:
        raise ContractError(
            f"{contract} semantic validation failed: active pack is not bound to this vehicle revision"
        )


def _validate_component_revision(document: dict[str, Any]) -> None:
    contract = "vehicle.component-registry-entry"
    _validate_trimmed_text(document, contract)
    if document["revision_id"] == document["supersedes_revision_id"]:
        raise ContractError(f"{contract} semantic validation failed: revision cannot supersede itself")
    if document["component_id"] == document["parent_component_id"]:
        raise ContractError(f"{contract} semantic validation failed: component cannot parent itself")
    _require_unique(document["custom_fields"], "field_id", contract, "custom_fields")
    _validate_custom_fields(document["custom_fields"], contract)
    installed = document["installed_occurrence"]
    retired = document["retired_occurrence"]
    if installed is not None and retired is not None and retired["date"] < installed["date"]:
        raise ContractError(f"{contract} semantic validation failed: retirement precedes installation")


def _validate_maintenance_record(document: dict[str, Any]) -> None:
    contract = "vehicle.maintenance-record"
    if document["revision_id"] == document["supersedes_revision_id"]:
        raise ContractError(
            f"{contract} semantic validation failed: revision cannot supersede itself"
        )

    _validate_trimmed_text(document, contract)
    unique_keys = (
        ("line_items", "line_item_id"),
        ("measurements", "measurement_id"),
        ("custom_fields", "field_id"),
        ("attachments", "attachment_id"),
    )
    for collection_name, identity_key in unique_keys:
        identities = [item[identity_key] for item in document[collection_name]]
        if len(identities) != len(set(identities)):
            raise ContractError(
                f"{contract} semantic validation failed: duplicate {collection_name} identity"
            )

    known_systems = [item["system_key"] for item in document["systems"] if item["knowledge"] == "KNOWN"]
    if len(known_systems) != len(set(known_systems)):
        raise ContractError(f"{contract} semantic validation failed: duplicate known system reference")
    known_components = [item["component_id"] for item in document["components"] if item["component_knowledge"] == "KNOWN"]
    if len(known_components) != len(set(known_components)):
        raise ContractError(f"{contract} semantic validation failed: duplicate known component reference")
    if any(
        item["system_knowledge"] == "KNOWN" and item["system_key"] not in set(known_systems)
        for item in document["components"]
    ):
        raise ContractError(
            f"{contract} semantic validation failed: component references an undeclared system"
        )
    if any(
        item["component_id"] is not None
        and item["component_id"] == item["parent_component_id"]
        for item in document["components"]
    ):
        raise ContractError(f"{contract} semantic validation failed: component cannot parent itself")

    attachment_ids = {item["attachment_id"] for item in document["attachments"]}
    warranty = document["warranty"]
    if warranty is not None and any(
        identity not in attachment_ids
        for identity in warranty["document_attachment_ids"]
    ):
        raise ContractError(
            f"{contract} semantic validation failed: warranty references an absent attachment"
        )

    if document["engine_hours"] is not None:
        _canonical_decimal(document["engine_hours"], "engine_hours", contract, nonnegative=True)
    for item in document["line_items"]:
        _canonical_decimal(item["quantity"], "line_items.quantity", contract, positive=True)
        if item["cost"] is not None:
            _validate_money(item["cost"], contract)
    if document["total_cost"] is not None:
        _validate_money(document["total_cost"], contract)
    for item in document["measurements"]:
        if item["value_type"] == "DECIMAL":
            _canonical_decimal(item["value"], "measurements.value", contract)
    _validate_custom_fields(document["custom_fields"], contract)
    warranty = document["warranty"]
    if warranty is not None and warranty["expires_on"] is not None:
        if date.fromisoformat(warranty["expires_on"]) < date.fromisoformat(warranty["starts_on"]):
            raise ContractError(f"{contract} semantic validation failed: warranty expiry precedes start")

    completion_refs = document["completion_references"]
    completion_keys = [
        (item["requirement_id"], item["requirement_version"], item["task_id"], item["rule_id"], item["due_instance_id"], item["baseline_id"])
        for item in completion_refs
    ]
    if len(completion_keys) != len(set(completion_keys)):
        raise ContractError(f"{contract} semantic validation failed: duplicate completion reference")
    for item in completion_refs:
        role = item["completion_role"]
        due = item["due_instance_id"]
        baseline = item["baseline_id"]
        effect = item["effect"]
        if role == "DUE_INSTANCE" and (due is None or baseline is not None):
            raise ContractError(f"{contract} semantic validation failed: DUE_INSTANCE reference shape is invalid")
        if role == "BASELINE_ESTABLISHMENT" and (baseline is None or due is not None):
            raise ContractError(f"{contract} semantic validation failed: BASELINE_ESTABLISHMENT reference shape is invalid")
        if role == "DUE_AND_BASELINE" and (due is None or baseline is None):
            raise ContractError(f"{contract} semantic validation failed: DUE_AND_BASELINE requires both references")
        if role == "NON_COMPLETION" and (due is not None or baseline is not None or effect not in {"INSPECTION_ONLY", "DOES_NOT_SATISFY", "UNKNOWN"}):
            raise ContractError(f"{contract} semantic validation failed: NON_COMPLETION cannot satisfy a due/baseline")


def _validate_maintenance_requirement(document: dict[str, Any]) -> None:
    contract = "vehicle.maintenance-requirement"
    _validate_trimmed_text(document, contract)
    locators = document["source_locators"]
    _require_unique(locators, "locator_key", contract, "source locators")
    for locator in locators:
        _validate_locator(locator, contract)
    rule = document["rule"]
    for threshold_name in ("initial_due", "recurrence"):
        threshold = rule[threshold_name]
        if threshold is not None and all(threshold[key] is None for key in ("distance", "elapsed_months", "engine_hours")):
            raise ContractError(f"{contract} semantic validation failed: {threshold_name} has no threshold")
        if threshold is not None and threshold["engine_hours"] is not None:
            _canonical_decimal(threshold["engine_hours"], f"rule.{threshold_name}.engine_hours", contract, positive=True)
    if rule["schedule_policy"] == "ONE_TIME" and rule["recurrence"] is not None:
        raise ContractError(f"{contract} semantic validation failed: one-time rule has recurrence")
    for predicate in document["applicability"]["predicates"]:
        values = predicate["values"]
        if predicate["operator"] in {"EQUALS", "NOT_EQUALS"} and len(values) != 1:
            raise ContractError(f"{contract} semantic validation failed: equality predicate requires one value")
        if predicate["operator"] == "IN" and not values:
            raise ContractError(f"{contract} semantic validation failed: IN predicate requires values")
        if predicate["operator"] in {"IS_YES", "IS_NO"} and values:
            raise ContractError(f"{contract} semantic validation failed: Boolean predicate cannot carry values")


def _validate_maintenance_source_manifest(document: dict[str, Any]) -> None:
    contract = "vehicle.maintenance-source-manifest"
    _validate_trimmed_text(document, contract)
    documents = document["source_documents"]
    _require_unique(documents, "source_document_id", contract, "source documents")
    document_ids = {item["source_document_id"] for item in documents}
    scopes = document["review_scope"]
    _require_unique(scopes, "locator_key", contract, "review scope locators")
    locator_keys = {item["locator_key"] for item in scopes}
    for scope in scopes:
        if scope["source_document_id"] not in document_ids:
            raise ContractError(f"{contract} semantic validation failed: review scope references absent source")
        _validate_locator(scope, contract)
        if scope["review_status"] == "REVIEWED" and (scope["reviewed_by"] is None or scope["reviewed_at"] is None):
            raise ContractError(f"{contract} semantic validation failed: reviewed scope lacks reviewer receipt")
        if scope["review_status"] == "NOT_REVIEWED" and (scope["reviewed_by"] is not None or scope["reviewed_at"] is not None):
            raise ContractError(f"{contract} semantic validation failed: unreviewed scope has review receipt")
    candidates = document["normalized_rule_candidates"]
    _require_unique(candidates, "requirement_id", contract, "rule candidates")
    _require_unique(candidates, "candidate_key", contract, "candidate keys")
    for candidate in candidates:
        if any(locator not in locator_keys for locator in candidate["source_locators"]):
            raise ContractError(f"{contract} semantic validation failed: candidate references absent locator")

    if document["activated"]:
        if any(item["review_status"] != "REVIEWED" for item in scopes if item["required"]):
            raise ContractError(f"{contract} semantic validation failed: active manifest has unreviewed scope")
        if any(item["reuse_status"] != "APPROVED_FOR_NORMALIZED_FACTS" for item in documents):
            raise ContractError(f"{contract} semantic validation failed: active manifest lacks reuse approval")
        if any(item["status"] != "REVIEWED" for item in candidates):
            raise ContractError(f"{contract} semantic validation failed: active manifest has unreviewed candidates")
    elif document["status"] == "ACTIVE":
        raise ContractError(f"{contract} semantic validation failed: inactive manifest claims ACTIVE status")


def _validate_locator(locator: dict[str, Any], contract: str) -> None:
    if locator["pdf_page_start"] > locator["pdf_page_end"]:
        raise ContractError(f"{contract} semantic validation failed: reversed PDF page locator")
    printed_start = locator["printed_page_start"]
    printed_end = locator["printed_page_end"]
    if (printed_start is None) != (printed_end is None) or (
        printed_start is not None and printed_start > printed_end
    ):
        raise ContractError(f"{contract} semantic validation failed: invalid printed-page locator")


def _validate_custom_fields(fields: list[dict[str, Any]], contract: str) -> None:
    for item in fields:
        if item["type"] == "DECIMAL":
            _canonical_decimal(item["value"], "custom_fields.value", contract)
        elif item["type"] == "INTEGER":
            try:
                value = int(item["value"])
            except ValueError as exc:
                raise ContractError(f"{contract} semantic validation failed: custom integer is invalid") from exc
            if not -(2**63) <= value <= 2**63 - 1:
                raise ContractError(f"{contract} semantic validation failed: custom integer exceeds signed 64-bit range")


def _canonical_decimal(value: str, field: str, contract: str, *, positive: bool = False, nonnegative: bool = False) -> Decimal:
    try:
        parsed = Decimal(value)
    except InvalidOperation as exc:
        raise ContractError(f"{contract} semantic validation failed: {field} is not decimal") from exc
    if not parsed.is_finite() or str(parsed) != value:
        raise ContractError(f"{contract} semantic validation failed: {field} is not canonical decimal")
    if positive and parsed <= 0:
        raise ContractError(f"{contract} semantic validation failed: {field} must be greater than zero")
    if nonnegative and parsed < 0:
        raise ContractError(f"{contract} semantic validation failed: {field} must not be negative")
    return parsed


def _validate_money(money: dict[str, Any], contract: str) -> None:
    if money["currency_code"] not in ISO_4217_CODES:
        raise ContractError(f"{contract} semantic validation failed: currency is not a recognized ISO 4217 code")


def _require_unique(items: list[dict[str, Any]], key: str, contract: str, label: str) -> None:
    values = [item[key] for item in items]
    if len(values) != len(set(values)):
        raise ContractError(f"{contract} semantic validation failed: duplicate {label}")


TRIMMED_TEXT_KEYS = frozenset(
    {
        "display_name", "title", "name", "description", "manufacturer", "part_number",
        "specification", "quantity_unit", "method", "condition_grade", "provider", "terms",
        "notes", "label", "storage_key", "section_label", "summary", "publisher",
        "publication_title", "publication_number", "amendment_reason", "reason", "phone",
        "email", "address", "invoice_number", "serial_number"
    }
)


def _validate_trimmed_text(value: Any, contract: str, key: str | None = None) -> None:
    if isinstance(value, dict):
        for child_key, child in value.items():
            _validate_trimmed_text(child, contract, child_key)
    elif isinstance(value, list):
        for child in value:
            _validate_trimmed_text(child, contract, key)
    elif isinstance(value, str) and key in TRIMMED_TEXT_KEYS:
        if value != value.strip() or not value:
            raise ContractError(f"{contract} semantic validation failed: {key} has surrounding whitespace or is blank")


def _format_error(path: Iterable[Any], message: str) -> str:
    location = ".".join(str(part) for part in path) or "<root>"
    return f"{location}: {message}"
