from __future__ import annotations

import hashlib
import math
import struct
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from .ids import deterministic_id

SIMULATOR_VERSION = "1.0.0"
SCENARIO_ID = "sim.cold-start-idle"
SCENARIO_VERSION = "1.0.0"
PAYLOAD_CHANNEL = "sim.powertrain.v1"
BASE_TIME = datetime(2026, 8, 16, 16, 0, 0, tzinfo=timezone.utc)
BASE_TIMESTAMP_MS = int(BASE_TIME.timestamp() * 1000)
SAMPLE_TIMES_SECONDS = (0, 1, 2, 3, 5, 10, 30, 60, 120, 180, 240, 300, 420, 540, 660, 780, 900)


@dataclass(frozen=True)
class ScenarioCapture:
    capture_id: str
    vehicle_id: str
    observations: tuple[dict[str, Any], ...]
    labels: tuple[dict[str, Any], ...]


def _state_at(second: int) -> tuple[float, float, float, float]:
    """Return rpm, speed_kph, coolant_deg_c, and system_voltage.

    This is an explicit engineering simulator model, not vehicle data. It models
    a stationary cold start so ingestion, freshness, and replay can be exercised.
    """
    if second < 2:
        rpm = 0.0
        voltage = 12.6
    elif second < 5:
        rpm = 260.0
        voltage = 10.8
    else:
        running_seconds = second - 5
        rpm = 760.0 + 440.0 * math.exp(-running_seconds / 42.0)
        voltage = 14.15 - 0.15 * math.exp(-running_seconds / 60.0)

    running_seconds = max(0, second - 5)
    coolant = 20.0 + 70.0 * (1.0 - math.exp(-running_seconds / 260.0))
    speed_kph = 0.0
    return rpm, speed_kph, coolant, voltage


def encode_simulator_state(
    rpm: float,
    speed_kph: float,
    coolant_deg_c: float,
    system_voltage: float,
) -> bytes:
    """Encode SIMULATOR_STATE_V1 as >HHhH.

    Units are rpm*4, km/h*10, degC*10, and volts*1000 respectively.
    """
    return struct.pack(
        ">HHhH",
        round(rpm * 4),
        round(speed_kph * 10),
        round(coolant_deg_c * 10),
        round(system_voltage * 1000),
    )


def generate_cold_start_idle() -> ScenarioCapture:
    vehicle_id = deterministic_id(
        "veh", "simulator.vehicle.v1", timestamp_ms=BASE_TIMESTAMP_MS
    )
    capture_id = deterministic_id(
        "capture", f"{SCENARIO_ID}@{SCENARIO_VERSION}", timestamp_ms=BASE_TIMESTAMP_MS
    )

    observations = tuple(
        _observation(capture_id, vehicle_id, sequence, second)
        for sequence, second in enumerate(SAMPLE_TIMES_SECONDS)
    )
    labels = (
        {"label": "key_on", "at_monotonic_us": 0, "note": "Simulator state transition"},
        {"label": "cranking", "at_monotonic_us": 2_000_000, "note": "Simulator state transition"},
        {"label": "engine_start", "at_monotonic_us": 5_000_000, "note": "Simulator state transition"},
        {"label": "warm_idle_end", "at_monotonic_us": 900_000_000, "note": "Scenario boundary"},
    )
    return ScenarioCapture(capture_id, vehicle_id, observations, labels)


def _observation(
    capture_id: str,
    vehicle_id: str,
    sequence: int,
    second: int,
) -> dict[str, Any]:
    wall_time = BASE_TIME + timedelta(seconds=second)
    timestamp_ms = BASE_TIMESTAMP_MS + second * 1000
    payload = encode_simulator_state(*_state_at(second))
    payload_hex = payload.hex()
    return {
        "contract": "raw.observation",
        "contract_version": "1.0.0",
        "observation_id": deterministic_id(
            "obs",
            f"{capture_id}:{sequence}:{payload_hex}",
            timestamp_ms=timestamp_ms,
        ),
        "vehicle_id": vehicle_id,
        "capture_id": capture_id,
        "sequence": sequence,
        "observed_at_monotonic_us": second * 1_000_000,
        "wall_time": _format_time(wall_time),
        "source": {
            "kind": "SIMULATOR",
            "source_id": "sim.powertrain-state",
            "channel": PAYLOAD_CHANNEL,
        },
        "payload": {
            "encoding": "HEX",
            "data": payload_hex,
            "sha256": hashlib.sha256(payload).hexdigest(),
        },
        "quality": "GOOD",
        "versions": {"source": SIMULATOR_VERSION},
    }


def _format_time(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )
