from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .bundles import canonical_json, load_validated_bundle
from .contracts import ContractCatalog
from .ids import deterministic_id


@dataclass(frozen=True)
class ReplayResult:
    capture_id: str
    observation_count: int
    signal_sample_count: int
    signal_ids: tuple[str, ...]
    semantic_digest: str
    samples: tuple[dict[str, Any], ...]


def replay_bundle(
    bundle_directory: Path,
    *,
    catalog: ContractCatalog | None = None,
) -> ReplayResult:
    validator = catalog or ContractCatalog.load()
    manifest, observations = load_validated_bundle(
        bundle_directory, catalog=validator
    )
    samples: list[dict[str, Any]] = []
    for observation in observations:
        samples.extend(_decode_observation(observation))
    for sample in samples:
        validator.validate(sample)

    serialized = "".join(f"{canonical_json(sample)}\n" for sample in samples).encode(
        "utf-8"
    )
    signal_ids = tuple(sorted({sample["signal_id"] for sample in samples}))
    return ReplayResult(
        capture_id=manifest["capture_id"],
        observation_count=len(observations),
        signal_sample_count=len(samples),
        signal_ids=signal_ids,
        semantic_digest=hashlib.sha256(serialized).hexdigest(),
        samples=tuple(samples),
    )


def _decode_observation(observation: dict[str, Any]) -> list[dict[str, Any]]:
    source = observation["source"]
    if source["kind"] != "SIMULATOR":
        raise ValueError(
            f"No E0 decoder for source {source['kind']} channel {source['channel']}"
        )
    if source["channel"] == "sim.powertrain.v1":
        return _decode_powertrain(observation)
    if source["channel"] == "sim.ac.telemetry.v1":
        return _decode_ac_telemetry(observation)
    raise ValueError(
        f"No E0 decoder for source {source['kind']} channel {source['channel']}"
    )


def _decode_powertrain(observation: dict[str, Any]) -> list[dict[str, Any]]:
    payload = bytes.fromhex(observation["payload"]["data"])
    if len(payload) != 8:
        raise ValueError(
            f"SIMULATOR_STATE_V1 payload must be 8 bytes, got {len(payload)}"
        )
    rpm_x4, speed_deci_kph, coolant_deci_c, system_mv = struct.unpack(
        ">HHhH", payload
    )
    decoded = (
        ("sim.engine.rpm", rpm_x4 / 4.0, "rpm"),
        ("sim.vehicle.speed", speed_deci_kph / 10.0, "km/h"),
        ("sim.engine.coolant-temp", coolant_deci_c / 10.0, "Cel"),
        ("sim.electrical.system-voltage", system_mv / 1000.0, "V"),
    )
    return _make_samples(observation, decoded, decoder_id="sim.powertrain-state-v1")


def _decode_ac_telemetry(observation: dict[str, Any]) -> list[dict[str, Any]]:
    payload = bytes.fromhex(observation["payload"]["data"])
    if len(payload) != 40:
        raise ValueError(
            f"SIM_AC_TELEMETRY_V1 payload must be 40 bytes, got {len(payload)}"
        )
    (
        sample_counter,
        high_deci_kpa,
        low_deci_kpa,
        atmospheric_deci_kpa,
        high_line_deci_c,
        low_line_deci_c,
        ambient_deci_c,
        cabin_return_deci_c,
        center_vent_deci_c,
        board_deci_c,
        vin_mv,
        sensor_5v_mv,
        logic_3v3_mv,
        status_bits,
        fault_mask,
    ) = struct.unpack(">IIIIhhhhhhHHHHI", payload)
    decoded = (
        ("sim.ac.sample-counter", float(sample_counter), "count"),
        ("sim.ac.pressure.high.absolute", high_deci_kpa / 10.0, "kPa"),
        ("sim.ac.pressure.low.absolute", low_deci_kpa / 10.0, "kPa"),
        ("sim.ac.pressure.atmospheric", atmospheric_deci_kpa / 10.0, "kPa"),
        ("sim.ac.temperature.high-line", high_line_deci_c / 10.0, "Cel"),
        ("sim.ac.temperature.low-line", low_line_deci_c / 10.0, "Cel"),
        ("sim.ac.temperature.ambient", ambient_deci_c / 10.0, "Cel"),
        ("sim.ac.temperature.cabin-return", cabin_return_deci_c / 10.0, "Cel"),
        ("sim.ac.temperature.center-vent", center_vent_deci_c / 10.0, "Cel"),
        ("sim.ac.node.board-temperature", board_deci_c / 10.0, "Cel"),
        ("sim.ac.node.vin", vin_mv / 1000.0, "V"),
        ("sim.ac.node.sensor-5v", sensor_5v_mv / 1000.0, "V"),
        ("sim.ac.node.logic-3v3", logic_3v3_mv / 1000.0, "V"),
        ("sim.ac.node.high-sensor-ok", float(bool(status_bits & 0x0001)), "1"),
        ("sim.ac.node.low-sensor-ok", float(bool(status_bits & 0x0002)), "1"),
        ("sim.ac.node.adc-reference-ok", float(bool(status_bits & 0x0004)), "1"),
        ("sim.ac.node.storage-ok", float(bool(status_bits & 0x0008)), "1"),
        ("sim.ac.node.fault-mask", float(fault_mask), "bitmask"),
    )
    return _make_samples(observation, decoded, decoder_id="sim.ac-telemetry-v1")


def _make_samples(
    observation: dict[str, Any],
    decoded: tuple[tuple[str, float, str], ...],
    *,
    decoder_id: str,
) -> list[dict[str, Any]]:
    timestamp_ms = _timestamp_ms_from_domain_id(observation["observation_id"])
    return [
        {
            "contract": "signal.sample",
            "contract_version": "1.0.0",
            "sample_id": deterministic_id(
                "sample",
                f"{observation['observation_id']}:{signal_id}",
                timestamp_ms=timestamp_ms,
            ),
            "vehicle_id": observation["vehicle_id"],
            "observation_id": observation["observation_id"],
            "signal_id": signal_id,
            "value": value,
            "unit": unit,
            "observed_at_monotonic_us": observation["observed_at_monotonic_us"],
            "wall_time": observation["wall_time"],
            "quality": observation["quality"],
            "source": {
                "kind": "SIMULATOR",
                "decoder_id": decoder_id,
            },
            "versions": {"decoder": "1.0.0"},
        }
        for signal_id, value, unit in decoded
    ]


def _timestamp_ms_from_domain_id(domain_id: str) -> int:
    body = domain_id.split("_", 1)[1]
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    value = 0
    for character in body:
        value = (value << 5) | alphabet.index(character)
    return value >> 80
