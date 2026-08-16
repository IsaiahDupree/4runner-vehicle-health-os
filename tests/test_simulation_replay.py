from __future__ import annotations

import copy
from pathlib import Path

import pytest

from vhos.bundles import BundleError, load_validated_bundle, write_simulator_bundle
from vhos.replay import replay_bundle
from vhos.simulator import ScenarioCapture, generate_cold_start_idle


def test_simulator_bundle_is_valid_and_replayable(tmp_path: Path) -> None:
    capture = generate_cold_start_idle()
    bundle = tmp_path / "capture"

    manifest = write_simulator_bundle(capture, bundle)
    loaded_manifest, observations = load_validated_bundle(bundle)
    replay = replay_bundle(bundle)

    assert manifest == loaded_manifest
    assert len(observations) == 17
    assert replay.observation_count == 17
    assert replay.signal_sample_count == 68
    assert replay.signal_ids == (
        "sim.electrical.system-voltage",
        "sim.engine.coolant-temp",
        "sim.engine.rpm",
        "sim.vehicle.speed",
    )


def test_same_scenario_has_identical_bundle_and_replay_digests(tmp_path: Path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"

    first_manifest = write_simulator_bundle(generate_cold_start_idle(), first)
    second_manifest = write_simulator_bundle(generate_cold_start_idle(), second)

    assert first_manifest["semantic_digest"] == second_manifest["semantic_digest"]
    assert (first / "observations.ndjson").read_bytes() == (
        second / "observations.ndjson"
    ).read_bytes()
    assert replay_bundle(first).semantic_digest == replay_bundle(second).semantic_digest


def test_segment_corruption_is_rejected(tmp_path: Path) -> None:
    bundle = tmp_path / "capture"
    write_simulator_bundle(generate_cold_start_idle(), bundle)
    segment = bundle / "observations.ndjson"
    segment.write_bytes(segment.read_bytes() + b"\n")

    with pytest.raises(BundleError, match="byte count mismatch"):
        load_validated_bundle(bundle)


def test_replace_refuses_unrelated_directory(tmp_path: Path) -> None:
    unrelated = tmp_path / "unrelated"
    unrelated.mkdir()
    (unrelated / "keep.txt").write_text("owner data", encoding="utf-8")

    with pytest.raises(BundleError, match="not an existing simulator bundle"):
        write_simulator_bundle(generate_cold_start_idle(), unrelated, replace=True)

    assert (unrelated / "keep.txt").read_text(encoding="utf-8") == "owner data"


def test_payload_corruption_is_rejected_even_with_valid_segment_hash(tmp_path: Path) -> None:
    original = generate_cold_start_idle()
    observations = [copy.deepcopy(item) for item in original.observations]
    observations[0]["payload"]["data"] = "0000000000000000"
    capture = ScenarioCapture(
        original.capture_id,
        original.vehicle_id,
        tuple(observations),
        original.labels,
    )
    bundle = tmp_path / "payload-corruption"
    write_simulator_bundle(capture, bundle)

    with pytest.raises(BundleError, match="payload SHA-256 mismatch"):
        load_validated_bundle(bundle)


def test_sequence_gap_is_rejected(tmp_path: Path) -> None:
    original = generate_cold_start_idle()
    observations = [copy.deepcopy(item) for item in original.observations]
    observations[5]["sequence"] = 42
    capture = ScenarioCapture(
        original.capture_id,
        original.vehicle_id,
        tuple(observations),
        original.labels,
    )
    bundle = tmp_path / "sequence-gap"
    write_simulator_bundle(capture, bundle)

    with pytest.raises(BundleError, match="Non-contiguous observation sequence"):
        load_validated_bundle(bundle)


def test_timestamp_disorder_is_rejected(tmp_path: Path) -> None:
    original = generate_cold_start_idle()
    observations = [copy.deepcopy(item) for item in original.observations]
    observations[5]["observed_at_monotonic_us"] = observations[4][
        "observed_at_monotonic_us"
    ]
    capture = ScenarioCapture(
        original.capture_id,
        original.vehicle_id,
        tuple(observations),
        original.labels,
    )
    bundle = tmp_path / "timestamp-disorder"
    write_simulator_bundle(capture, bundle)

    with pytest.raises(BundleError, match="Non-increasing monotonic timestamp"):
        load_validated_bundle(bundle)
