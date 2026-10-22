from __future__ import annotations

import json
from pathlib import Path

import pytest

from vhos.contracts import ContractCatalog
from vhos.j1979 import (
    J1979Error,
    decode_standard_samples,
    decode_supported_pid_bitmap,
    enumerate_supported_pids,
    load_j1979_ndjson,
)


def _bitmap(base: int, supported: set[int]) -> bytes:
    value = 0
    for pid in supported:
        offset = pid - base
        if 1 <= offset <= 32:
            value |= 1 << (32 - offset)
    return value.to_bytes(4, "big")


def _response(pid: int, data: bytes, monotonic: int) -> dict[str, object]:
    return {
        "contract": "obd.j1979-response",
        "contract_version": "1.0.0",
        "gateway_id": "esp32-9454c5b08d14",
        "capture_id": "capture-j1979-test",
        "observed_at": "2026-08-18T12:00:00Z",
        "gateway_monotonic_microseconds": monotonic,
        "source_sequence": monotonic // 1_000,
        "transport": "ISO_15765_11_500",
        "ecu_address": "0x7E8",
        "request_mode": 1,
        "request_pid": pid,
        "response_payload_hex": (bytes([0x41, pid]) + data).hex().upper(),
    }


def test_supported_pid_enumeration_and_standard_value_decode(tmp_path: Path) -> None:
    supported = {0x04, 0x05, 0x0C, 0x0D, 0x11, 0x1F, 0x20}
    documents = [
        _response(0x00, _bitmap(0x00, supported), 1_000_000),
        _response(0x20, bytes(4), 1_010_000),
        _response(0x0C, bytes.fromhex("156C"), 1_100_000),
        _response(0x11, bytes.fromhex("33"), 1_200_000),
        _response(0x05, bytes.fromhex("7F"), 1_300_000),
    ]
    input_path = tmp_path / "j1979.ndjson"
    input_path.write_text(
        "".join(json.dumps(item) + "\n" for item in documents), encoding="utf-8"
    )

    responses, _ = load_j1979_ndjson([input_path])
    report = enumerate_supported_pids(responses)
    samples = decode_standard_samples(responses, report)

    ContractCatalog.load().validate(report)
    assert report["ecu_results"][0]["enumeration_complete"] is True
    assert report["ecu_results"][0]["supported_pids"] == sorted(supported)
    assert {item["signal_id"] for item in samples} == {
        "obd.engine.speed",
        "obd.engine.throttle_position",
        "obd.engine.coolant_temperature",
    }
    rpm = next(item for item in samples if item["signal_id"] == "obd.engine.speed")
    assert rpm["value"] == 1371.0
    assert rpm["unit"] == "rpm"
    assert rpm["support_verified"] is True
    assert rpm["source_sequence"] == 1_100
    assert rpm["definition_source"]["revision"] == (
        "d3259214a9e0340c4a6cff9ec5f8ff5953eee6f2"
    )
    throttle = next(
        item for item in samples if item["signal_id"] == "obd.engine.throttle_position"
    )
    assert throttle["value"] == 20.0
    coolant = next(
        item for item in samples if item["signal_id"] == "obd.engine.coolant_temperature"
    )
    assert coolant["value"] == 87.0


def test_incomplete_enumeration_blocks_value_population(tmp_path: Path) -> None:
    supported = {0x0C, 0x20}
    documents = [
        _response(0x00, _bitmap(0x00, supported), 1_000_000),
        _response(0x0C, bytes.fromhex("156C"), 1_100_000),
    ]
    input_path = tmp_path / "incomplete.ndjson"
    input_path.write_text(
        "".join(json.dumps(item) + "\n" for item in documents), encoding="utf-8"
    )

    responses, _ = load_j1979_ndjson([input_path])
    report = enumerate_supported_pids(responses)

    assert report["ecu_results"][0]["enumeration_complete"] is False
    assert "0x20" in report["ecu_results"][0]["incomplete_reason"]
    assert decode_standard_samples(responses, report) == []


def test_bitmap_uses_most_significant_bit_for_base_plus_one() -> None:
    assert decode_supported_pid_bitmap(0x00, bytes.fromhex("80000001")) == [0x01, 0x20]


def test_final_bitmap_does_not_create_pid_256() -> None:
    assert decode_supported_pid_bitmap(0xE0, bytes.fromhex("00000001")) == []


def test_loader_rejects_mismatched_response_pid(tmp_path: Path) -> None:
    document = _response(0x0C, bytes.fromhex("156C"), 1_000_000)
    document["response_payload_hex"] = "410D00"
    input_path = tmp_path / "bad.ndjson"
    input_path.write_text(json.dumps(document) + "\n", encoding="utf-8")

    with pytest.raises(J1979Error, match="does not echo"):
        load_j1979_ndjson([input_path])
