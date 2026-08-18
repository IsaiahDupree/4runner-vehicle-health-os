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


def _format_error(path: Iterable[Any], message: str) -> str:
    location = ".".join(str(part) for part in path) or "<root>"
    return f"{location}: {message}"
