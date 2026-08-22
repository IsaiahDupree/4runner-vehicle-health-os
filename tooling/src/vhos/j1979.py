from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from .contracts import ContractCatalog
from .ids import deterministic_id


RESPONSE_CONTRACT = "obd.j1979-response"
SUPPORTED_CONTRACT = "obd.j1979-supported-pids"
SAMPLE_CONTRACT = "obd.j1979-standard-sample"
CONTRACT_VERSION = "1.0.0"
POSITIVE_MODE_01_RESPONSE = 0x41
SUPPORTED_BASE_PIDS = tuple(range(0x00, 0x100, 0x20))
MAX_RESPONSES = 100_000


class J1979Error(ValueError):
    """Raised when diagnostic evidence is invalid or cannot be decoded safely."""


@dataclass(frozen=True)
class J1979Response:
    gateway_id: str
    capture_id: str
    observed_at: str
    gateway_monotonic_microseconds: int
    source_sequence: int
    transport: str
    ecu_address: str
    request_pid: int
    payload: bytes

    @classmethod
    def from_document(cls, document: dict[str, Any], catalog: ContractCatalog) -> "J1979Response":
        catalog.validate(document)
        payload = bytes.fromhex(document["response_payload_hex"])
        if len(payload) < 2:
            raise J1979Error("J1979 response payload must contain response mode and PID.")
        if payload[0] != POSITIVE_MODE_01_RESPONSE:
            raise J1979Error(
                f"Expected positive Mode 01 response 0x41; received 0x{payload[0]:02X}."
            )
        if payload[1] != document["request_pid"]:
            raise J1979Error(
                f"Response PID 0x{payload[1]:02X} does not echo request PID "
                f"0x{document['request_pid']:02X}."
            )
        return cls(
            gateway_id=document["gateway_id"],
            capture_id=document["capture_id"],
            observed_at=document["observed_at"],
            gateway_monotonic_microseconds=document["gateway_monotonic_microseconds"],
            source_sequence=document["source_sequence"],
            transport=document["transport"],
            ecu_address=document["ecu_address"],
            request_pid=document["request_pid"],
            payload=payload,
        )

    @property
    def data(self) -> bytes:
        return self.payload[2:]

    @property
    def payload_hex(self) -> str:
        return self.payload.hex().upper()


@dataclass(frozen=True)
class PIDDefinition:
    pid: int
    signal_id: str
    name: str
    byte_count: int
    multiplier: float
    divisor: float
    offset: float
    unit: str

    def decode(self, data: bytes) -> float:
        if len(data) < self.byte_count:
            raise J1979Error(
                f"PID 0x{self.pid:02X} requires {self.byte_count} data bytes; "
                f"received {len(data)}."
            )
        raw = int.from_bytes(data[: self.byte_count], "big")
        return raw * self.multiplier / self.divisor + self.offset


def default_definition_registry() -> Path:
    return (
        Path(__file__).resolve().parents[3]
        / "vehicle-signal-packs"
        / "standards"
        / "j1979-mode01-obdb-d3259214.v1.json"
    )


def load_definition_registry(path: Path | None = None) -> tuple[dict[int, PIDDefinition], dict[str, str]]:
    registry_path = (path or default_definition_registry()).resolve()
    document = json.loads(registry_path.read_text(encoding="utf-8"))
    if document.get("contract") != "obd.j1979-definition-registry" or document.get(
        "contract_version"
    ) != CONTRACT_VERSION:
        raise J1979Error("J1979 definition registry contract is unsupported.")
    source = document.get("source")
    if not isinstance(source, dict):
        raise J1979Error("J1979 definition registry has no source provenance.")
    required_source = {"publisher", "repository", "revision", "license", "definition_path"}
    if not required_source.issubset(source):
        raise J1979Error("J1979 definition source provenance is incomplete.")
    definitions: dict[int, PIDDefinition] = {}
    for item in document.get("definitions", []):
        definition = PIDDefinition(
            pid=int(item["pid"]),
            signal_id=str(item["signal_id"]),
            name=str(item["name"]),
            byte_count=int(item["byte_count"]),
            multiplier=float(item["multiplier"]),
            divisor=float(item["divisor"]),
            offset=float(item["offset"]),
            unit=str(item["unit"]),
        )
        if definition.pid in definitions:
            raise J1979Error(f"Duplicate J1979 PID definition 0x{definition.pid:02X}.")
        if definition.byte_count not in {1, 2, 4} or definition.divisor == 0:
            raise J1979Error(f"Invalid J1979 definition for PID 0x{definition.pid:02X}.")
        definitions[definition.pid] = definition
    return definitions, {key: str(source[key]) for key in required_source}


def load_j1979_ndjson(paths: Iterable[Path]) -> tuple[list[J1979Response], list[dict[str, Any]]]:
    catalog = ContractCatalog.load()
    responses: list[J1979Response] = []
    sources: list[dict[str, Any]] = []
    for path in _resolve_inputs(paths):
        raw = path.read_bytes()
        count = 0
        for line_number, line in enumerate(raw.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                document = json.loads(line)
            except json.JSONDecodeError as error:
                raise J1979Error(f"{path.name}:{line_number}: invalid JSON.") from error
            if not isinstance(document, dict):
                raise J1979Error(f"{path.name}:{line_number}: response must be an object.")
            try:
                responses.append(J1979Response.from_document(document, catalog))
            except (J1979Error, ValueError) as error:
                raise J1979Error(f"{path.name}:{line_number}: {error}") from error
            count += 1
            if len(responses) > MAX_RESPONSES:
                raise J1979Error("J1979 input exceeds the response limit.")
        sources.append({"name": path.name, "record_count": count, "byte_count": len(raw)})
    if not responses:
        raise J1979Error("No J1979 responses were found.")
    identities = {(item.gateway_id, item.capture_id) for item in responses}
    if len(identities) != 1:
        raise J1979Error("One decode run must contain exactly one gateway and capture identity.")
    return responses, sources


def decode_supported_pid_bitmap(base_pid: int, bitmap: bytes) -> list[int]:
    if base_pid not in SUPPORTED_BASE_PIDS:
        raise J1979Error(f"PID 0x{base_pid:02X} is not a supported-PID base request.")
    if len(bitmap) != 4:
        raise J1979Error("Supported-PID response bitmap must contain exactly four bytes.")
    value = int.from_bytes(bitmap, "big")
    return [
        base_pid + offset
        for offset in range(1, 33)
        if base_pid + offset <= 0xFF and value & (1 << (32 - offset))
    ]


def enumerate_supported_pids(responses: Iterable[J1979Response]) -> dict[str, Any]:
    ordered = sorted(responses, key=lambda item: item.gateway_monotonic_microseconds)
    if not ordered:
        raise J1979Error("Supported-PID enumeration requires diagnostic responses.")
    grouped: dict[tuple[str, str], dict[int, J1979Response]] = defaultdict(dict)
    for response in ordered:
        if response.request_pid not in SUPPORTED_BASE_PIDS:
            continue
        if len(response.data) != 4:
            raise J1979Error(
                f"ECU {response.ecu_address} PID 0x{response.request_pid:02X} "
                "must return exactly four bitmap bytes."
            )
        grouped[(response.ecu_address, response.transport)][response.request_pid] = response
    if not grouped:
        raise J1979Error("No Mode 01 supported-PID bitmap responses were found.")

    ecu_results: list[dict[str, Any]] = []
    for (ecu_address, transport), by_base in sorted(grouped.items()):
        supported: set[int] = set()
        evidence: list[dict[str, Any]] = []
        for base_pid, response in sorted(by_base.items()):
            supported.update(decode_supported_pid_bitmap(base_pid, response.data))
            evidence.append(
                {
                    "base_pid": base_pid,
                    "bitmap_hex": response.data.hex().upper(),
                    "response_payload_hex": response.payload_hex,
                    "observed_at": response.observed_at,
                    "gateway_monotonic_microseconds": response.gateway_monotonic_microseconds,
                    "source_sequence": response.source_sequence,
                }
            )
        complete, reason = _enumeration_completeness(by_base, supported)
        ecu_results.append(
            {
                "ecu_address": ecu_address,
                "transport": transport,
                "enumeration_complete": complete,
                "incomplete_reason": reason,
                "queried_base_pids": sorted(by_base),
                "supported_pids": sorted(supported),
                "response_evidence": evidence,
            }
        )

    report = {
        "contract": SUPPORTED_CONTRACT,
        "contract_version": CONTRACT_VERSION,
        "gateway_id": ordered[0].gateway_id,
        "capture_id": ordered[0].capture_id,
        "generated_at": max(item.observed_at for item in ordered),
        "mode": 1,
        "authority": (
            "Per-ECU availability decoded from raw positive Mode 01 bitmap responses. "
            "Unsupported means absent, never a numeric zero."
        ),
        "ecu_results": ecu_results,
    }
    ContractCatalog.load().validate(report)
    return report


def decode_standard_samples(
    responses: Iterable[J1979Response], supported_report: dict[str, Any]
) -> list[dict[str, Any]]:
    definitions, source = load_definition_registry()
    supported_by_ecu = {
        (item["ecu_address"], item["transport"]): set(item["supported_pids"])
        for item in supported_report["ecu_results"]
        if item["enumeration_complete"]
    }
    samples: list[dict[str, Any]] = []
    for response in sorted(responses, key=lambda item: item.gateway_monotonic_microseconds):
        definition = definitions.get(response.request_pid)
        if definition is None or response.request_pid not in supported_by_ecu.get(
            (response.ecu_address, response.transport), set()
        ):
            continue
        value = definition.decode(response.data)
        timestamp = int(
            datetime.fromisoformat(response.observed_at.replace("Z", "+00:00")).timestamp()
            * 1000
        )
        sample = {
            "contract": SAMPLE_CONTRACT,
            "contract_version": CONTRACT_VERSION,
            "sample_id": deterministic_id(
                "sample",
                (
                    f"{response.gateway_id}:{response.capture_id}:{response.ecu_address}:"
                    f"{response.gateway_monotonic_microseconds}:{response.source_sequence}:"
                    f"{response.request_pid}"
                ),
                timestamp_ms=timestamp,
            ),
            "gateway_id": response.gateway_id,
            "capture_id": response.capture_id,
            "ecu_address": response.ecu_address,
            "observed_at": response.observed_at,
            "gateway_monotonic_microseconds": response.gateway_monotonic_microseconds,
            "source_sequence": response.source_sequence,
            "mode": 1,
            "pid": response.request_pid,
            "signal_id": definition.signal_id,
            "name": definition.name,
            "raw_data_hex": response.data[: definition.byte_count].hex().upper(),
            "value": round(value, 6),
            "unit": definition.unit,
            "quality": "GOOD",
            "support_verified": True,
            "definition_source": source,
        }
        ContractCatalog.load().validate(sample)
        samples.append(sample)
    return samples


def _enumeration_completeness(
    by_base: dict[int, J1979Response], supported: set[int]
) -> tuple[bool, str | None]:
    if 0 not in by_base:
        return False, "PID 0x00 availability response is missing."
    base = 0
    while base < 0xE0:
        continuation = base + 0x20
        if continuation not in supported:
            return True, None
        if continuation not in by_base:
            return False, f"PID 0x{continuation:02X} availability response is required."
        base = continuation
    return True, None


def _resolve_inputs(paths: Iterable[Path]) -> list[Path]:
    files: list[Path] = []
    for candidate in paths:
        path = candidate.resolve()
        if path.is_dir():
            files.extend(sorted(path.glob("*.ndjson")))
        elif path.is_file():
            files.append(path)
        else:
            raise J1979Error(f"J1979 input does not exist: {candidate}")
    unique = list(dict.fromkeys(files))
    if not unique:
        raise J1979Error("No J1979 NDJSON inputs were resolved.")
    return unique
