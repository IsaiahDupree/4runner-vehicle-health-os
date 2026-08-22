from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


class ContractError(ValueError):
    pass


SCHEMA_BY_CONTRACT = {
    "ai.claim": "ai-claim.schema.json",
    "can.discovery.report": "can-discovery-report.schema.json",
    "can.signal-hypothesis-evaluation": "can-signal-hypothesis-evaluation.schema.json",
    "can.signal-hypothesis-pack": "can-signal-hypothesis-pack.schema.json",
    "can.replay.corpus": "can-replay-corpus.schema.json",
    "transport.link-reliability-matrix": "transport-link-reliability-matrix.schema.json",
    "calculation.run": "calculation-run.schema.json",
    "can.reference-correlation-report": "can-reference-correlation-report.schema.json",
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
                raise ContractError(f"Unable to read schema {path.name}: {exc}") from exc
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
        errors = sorted(validator.iter_errors(document), key=lambda item: list(item.path))
        if errors:
            details = "; ".join(_format_error(error.path, error.message) for error in errors)
            raise ContractError(f"{contract} validation failed: {details}")
        _validate_contract_semantics(contract, document)


def _validate_contract_semantics(contract: str, document: dict[str, Any]) -> None:
    if contract != "vhos.discovery.capture-session":
        return

    capture_id = document["id"]
    start = document["start_monotonic_microseconds"]
    end = document["end_monotonic_microseconds"]
    first_sequence = document["first_source_sequence"]
    last_sequence = document["last_source_sequence"]
    gateway_sessions = set(document["gateway_session_ids"])
    if start > end:
        raise ContractError(f"{contract} semantic validation failed: capture time is reversed")
    if first_sequence > last_sequence:
        raise ContractError(f"{contract} semantic validation failed: source sequence is reversed")

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
            if gateway_session_id is not None and gateway_session_id not in gateway_sessions:
                raise ContractError(
                    f"{contract} semantic validation failed: {collection_name} session mismatch"
                )
            nearest_sequence = record.get("nearest_can_sequence")
            if nearest_sequence is not None and not first_sequence <= nearest_sequence <= last_sequence:
                raise ContractError(
                    f"{contract} semantic validation failed: {collection_name} sequence outside capture"
                )


def _format_error(path: Iterable[Any], message: str) -> str:
    location = ".".join(str(part) for part in path) or "<root>"
    return f"{location}: {message}"
