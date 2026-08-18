from __future__ import annotations

import json
from pathlib import Path

import pytest

from vhos.can_discovery import (
    CANDiscoveryError,
    ANALYSIS_VERSION,
    _nearest_pairs,
    analyze_passive_can,
    load_passive_can_ndjson,
)
from vhos.contracts import ContractCatalog


def _observation(
    *,
    session_id: int,
    source_sequence: int,
    monotonic_microseconds: int,
    identifier: int,
    data: list[int],
) -> dict[str, object]:
    padded = (data + [0] * 8)[:8]
    return {
        "contract": "gateway.passive-can-observation",
        "contract_version": "1.0.0",
        "gateway_id": "esp32-9454c5b08d14",
        "session_id": session_id,
        "source_sequence": source_sequence,
        "monotonic_microseconds": monotonic_microseconds,
        "bitrate_bps": 500_000,
        "identifier": identifier,
        "extended": False,
        "remote_request": False,
        "listen_only": True,
        "data_length": len(data),
        "data": padded,
        "evidence_source": "gateway-flash",
        "ingested_at": "2026-08-18T01:06:10Z",
    }


def _with_checksum(identifier: int, values: list[int]) -> list[int]:
    data_length = len(values) + 1
    checksum = (((identifier >> 8) & 0xFF) + (identifier & 0xFF) + data_length + sum(values)) & 0xFF
    return values + [checksum]


def test_discovery_reports_acquisition_facts_and_candidate_boundaries(tmp_path: Path) -> None:
    path = tmp_path / "real-capture-excerpt.ndjson"
    documents: list[dict[str, object]] = []
    for index in range(12):
        first = 1_360 + index
        second = first * 2
        timestamp = 1_000_000 + index * 200_000
        documents.extend(
            [
                _observation(
                    session_id=740_616_386,
                    source_sequence=1 + index * 15,
                    monotonic_microseconds=timestamp,
                    identifier=0x2C4,
                    data=_with_checksum(0x2C4, [first >> 8, first & 0xFF, 0, 0, 0, 0, 0]),
                ),
                _observation(
                    session_id=740_616_386,
                    source_sequence=2 + index * 15,
                    monotonic_microseconds=timestamp + 10_000,
                    identifier=0x2D0,
                    data=_with_checksum(0x2D0, [second >> 8, second & 0xFF, 0, 0, 0, 0, 0]),
                ),
                _observation(
                    session_id=740_616_386,
                    source_sequence=3 + index * 15,
                    monotonic_microseconds=timestamp + 20_000,
                    identifier=0x025,
                    data=_with_checksum(0x025, [0, 0, 0, 0, 120 + index % 4, 120 + index % 4, 120 + index % 4]),
                ),
            ]
        )
    path.write_text("".join(json.dumps(item) + "\n" for item in documents), encoding="utf-8")

    records, sources = load_passive_can_ndjson([path])
    report = analyze_passive_can(records, sources=sources)
    ContractCatalog.load().validate(report)

    assert report["contract_version"] == ANALYSIS_VERSION
    assert report["status"] == "DISCOVERY_CANDIDATE"
    assert report["acquisition"]["records"] == 36
    assert report["acquisition"]["sessions"] == 1
    assert report["acquisition"]["unique_identifiers"] == 3
    assert report["acquisition"]["listen_only_records"] == 36
    assert report["acquisition"]["bitrates_bps"] == [500_000]
    assert "not a dropped-frame counter" in report["authority"]
    assert any(
        "intentional sampling density" in item
        for item in report["display_policy"]["proven_now"]
    )
    assert {item["identifier"] for item in report["checksum_candidates"]} == {
        "0x025",
        "0x2C4",
        "0x2D0",
    }
    relation = next(
        item
        for item in report["raw_word_relationship_candidates"]
        if item["left"] == "0x2C4[0:16]" and item["right"] == "0x2D0[0:16]"
    )
    assert relation["pearson_correlation"] == 1.0
    assert relation["median_right_to_left_ratio"] == 2.0
    assert relation["maximum_pairing_delta_us"] == 10_000
    repeated = next(
        item for item in report["repeated_channel_candidates"] if item["identifier"] == "0x025"
    )
    assert repeated["byte_positions"] == [4, 5, 6]
    assert "RPM" in report["display_policy"]["blocked_until_correlated"][0]


def test_loader_rejects_missing_listen_only_proof(tmp_path: Path) -> None:
    document = _observation(
        session_id=1,
        source_sequence=1,
        monotonic_microseconds=1,
        identifier=0x123,
        data=[1, 2, 3],
    )
    document["listen_only"] = False
    path = tmp_path / "unsafe.ndjson"
    path.write_text(json.dumps(document) + "\n", encoding="utf-8")

    with pytest.raises(CANDiscoveryError, match="listen-only proof"):
        load_passive_can_ndjson([path])


def test_loader_rejects_duplicate_source_identity(tmp_path: Path) -> None:
    document = _observation(
        session_id=1,
        source_sequence=1,
        monotonic_microseconds=1,
        identifier=0x123,
        data=[1, 2, 3],
    )
    path = tmp_path / "duplicate.ndjson"
    path.write_text(json.dumps(document) + "\n" + json.dumps(document) + "\n", encoding="utf-8")

    with pytest.raises(CANDiscoveryError, match="duplicate observation identity"):
        load_passive_can_ndjson([path])


def test_time_pairing_never_reuses_a_sparse_sample() -> None:
    left = [(0, 10.0), (10, 11.0), (20, 12.0), (30, 13.0)]
    right = [(9, 20.0), (29, 22.0)]

    assert _nearest_pairs(left, right) == [
        (11.0, 20.0, 1),
        (13.0, 22.0, 1),
    ]
