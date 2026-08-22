from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from vhos.ac_metrics import SIMULATOR_AC_SIGNALS, calculate_ac_metrics
from vhos.bundles import load_validated_bundle, write_simulator_bundle
from vhos.contracts import ContractCatalog, ContractError
from vhos.ids import deterministic_id
from vhos.replay import replay_bundle
from vhos.simulator import generate_ac_bench_sweep


def test_ac_bench_capture_replays_without_vehicle_claims(tmp_path: Path) -> None:
    bundle = tmp_path / "ac-bench"
    manifest = write_simulator_bundle(generate_ac_bench_sweep(), bundle)
    _, observations = load_validated_bundle(bundle)
    replay = replay_bundle(bundle)

    assert manifest["profile"] == {
        "kind": "SIMULATOR",
        "scenario_id": "sim.ac-bench-sweep",
        "scenario_version": "1.0.0",
    }
    assert manifest["source"]["source_id"] == "sim.ac-bench-node"
    assert len(observations) == 6
    assert replay.observation_count == 6
    assert replay.signal_sample_count == 108
    assert all(signal_id.startswith("sim.") for signal_id in replay.signal_ids)


def test_ac_calculations_have_exact_same_snapshot_evidence(tmp_path: Path) -> None:
    bundle = tmp_path / "ac-bench"
    write_simulator_bundle(generate_ac_bench_sweep(), bundle)
    replay = replay_bundle(bundle)
    result = calculate_ac_metrics(
        replay.samples,
        signals=SIMULATOR_AC_SIGNALS,
        confidence=0.0,
        confidence_factors={"source_quality": 0.0},
        quality_notes=["SIMULATOR-only; not vehicle evidence or diagnosis."],
    )

    runs = {run["metric_id"]: run for run in result.runs}
    assert set(runs) == {
        "ac.pressure.delta",
        "ac.pressure.ratio",
        "ac.vent.delta",
    }
    assert runs["ac.pressure.delta"]["output"] == {
        "value": 1340.0,
        "unit": "kPa",
        "truth_boundary": "ESTIMATED",
    }
    assert runs["ac.pressure.ratio"]["output"]["value"] == pytest.approx(
        1600.0 / 260.0
    )
    assert runs["ac.vent.delta"]["output"]["value"] == 15.0
    for run in runs.values():
        observation_ids = {
            next(
                sample["observation_id"]
                for sample in replay.samples
                if sample["sample_id"] == input_["evidence_ref"]
            )
            for input_ in run["inputs"]
        }
        assert len(observation_ids) == 1
        assert run["confidence"] == 0.0

    assert "ac.superheat" in result.unavailable
    assert "ac.subcooling" in result.unavailable
    assert "ac.diagnostic.hypotheses" in result.unavailable


def test_equation_library_is_contract_valid() -> None:
    catalog = ContractCatalog.load()
    equation_directory = Path(__file__).resolve().parents[1] / "equations" / "v1"
    documents = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in sorted(equation_directory.glob("*.json"))
    ]

    assert {document["equation_id"] for document in documents} == {
        "ac.pressure.delta",
        "ac.pressure.ratio",
        "ac.vent.delta",
    }
    for document in documents:
        catalog.validate(document)
        assert document["validation_status"] == "EXPERIMENTAL"


def test_pressure_value_requires_configured_calibration() -> None:
    catalog = ContractCatalog.load()
    telemetry = _valid_telemetry()
    telemetry["pressure"]["high"]["calibration"] = _unconfigured_calibration()

    with pytest.raises(ContractError, match="configured"):
        catalog.validate(telemetry)

    missing_pressure = copy.deepcopy(telemetry)
    missing_pressure["pressure"]["high"]["absolute_kpa"] = None
    missing_pressure["pressure"]["high"]["quality"] = "SENSOR_UNVERIFIED"
    catalog.validate(missing_pressure)


def test_sensor_post_contract_preserves_check_evidence() -> None:
    catalog = ContractCatalog.load()
    post = {
        "contract": "sensor.node.post",
        "contract_version": "1.0.0",
        "post_id": deterministic_id("post", "bench", timestamp_ms=1_000),
        "device_id": deterministic_id("device", "ac-node", timestamp_ms=1_000),
        "executed_at": "2026-08-16T16:00:00Z",
        "reset_reason": "POWER_ON",
        "identity": {
            "hardware_revision": "BENCH-A",
            "firmware_version": "0.1.0",
            "firmware_build_id": "bench-build",
            "device_config_revision": "0.1.0",
        },
        "configuration_crc32c": "0123abcd",
        "state": "DEGRADED",
        "checks": [
            {
                "check_id": "ac.post.pressure-calibration",
                "status": "FAIL",
                "critical": True,
                "quality": "SENSOR_UNVERIFIED",
                "detail": "Pressure transfer function is not configured.",
            }
        ],
    }

    catalog.validate(post)


def _valid_telemetry() -> dict[str, object]:
    timestamp_ms = 1_000
    return {
        "contract": "sensor.node.telemetry",
        "contract_version": "1.0.0",
        "telemetry_id": deterministic_id("telemetry", "sample", timestamp_ms=timestamp_ms),
        "vehicle_id": deterministic_id("veh", "vehicle", timestamp_ms=timestamp_ms),
        "capture_id": deterministic_id("capture", "capture", timestamp_ms=timestamp_ms),
        "device_id": deterministic_id("device", "ac-node", timestamp_ms=timestamp_ms),
        "sample_counter": 1,
        "observed_at_monotonic_us": 1_000_000,
        "wall_time": "2026-08-16T16:00:01Z",
        "identity": {
            "hardware_revision": "BENCH-A",
            "firmware_version": "0.1.0",
            "firmware_build_id": "bench-build",
            "device_config_revision": "0.1.0",
            "vehicle_profile_revision": "0.0.0-unresolved",
        },
        "pressure": {
            "high": _pressure_channel("ac.pressure.high.calibration", 1200.0),
            "low": _pressure_channel("ac.pressure.low.calibration", 300.0),
        },
        "temperatures": {
            name: {
                "value_c": None,
                "quality": "MISSING",
                "calibration": _unconfigured_calibration(),
            }
            for name in (
                "high_line",
                "low_line",
                "ambient",
                "cabin_return",
                "center_vent",
                "board",
            )
        },
        "atmospheric_pressure": {
            "value_kpa": 101.3,
            "quality": "MANUALLY_ENTERED",
            "source": "CONFIGURED_TEST_VALUE",
        },
        "power": {
            "vehicle_input_v": 12.6,
            "nano_vin_v": 7.0,
            "sensor_5v_v": 5.0,
            "logic_3v3_v": 3.3,
        },
        "health": {
            "state": "DEGRADED",
            "high_sensor_ok": True,
            "low_sensor_ok": True,
            "adc_reference_ok": True,
            "storage_ok": True,
            "ble_clients": 0,
            "wifi_clients": 0,
            "fault_mask": 0,
        },
    }


def _pressure_channel(calibration_id: str, value: float) -> dict[str, object]:
    return {
        "raw_adc_count": 1000,
        "signal_voltage_mv": 1000.0,
        "absolute_kpa": value,
        "quality": "GOOD",
        "sensor_powered": True,
        "calibration": {
            "configured": True,
            "calibration_id": calibration_id,
            "revision": "1.0.0",
            "validation_status": "BENCH_VALIDATED",
        },
    }


def _unconfigured_calibration() -> dict[str, object]:
    return {
        "configured": False,
        "calibration_id": None,
        "revision": None,
        "validation_status": None,
    }
