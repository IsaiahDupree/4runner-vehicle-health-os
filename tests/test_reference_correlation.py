from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

from vhos.contracts import ContractCatalog
from vhos.reference_correlation import (
    ReferenceCorrelationError,
    correlate_can_with_reference,
)


def _observation(sequence: int, monotonic: int, identifier: int, data: bytes) -> dict[str, object]:
    padded = list(data) + [0] * (8 - len(data))
    return {
        "contract": "gateway.passive-can-observation",
        "contract_version": "1.0.0",
        "gateway_id": "esp32-9454c5b08d14",
        "session_id": 42,
        "source_sequence": sequence,
        "monotonic_microseconds": monotonic,
        "bitrate_bps": 500_000,
        "identifier": identifier,
        "extended": False,
        "remote_request": False,
        "listen_only": True,
        "data_length": len(data),
        "data": padded,
        "evidence_source": "gateway-flash",
        "ingested_at": "2026-08-18T12:00:00Z",
    }


def test_correlates_raw_big_endian_word_without_promoting_signal(tmp_path: Path) -> None:
    can_path = tmp_path / "passive.ndjson"
    reference_path = tmp_path / "reference.csv"
    can_documents: list[dict[str, object]] = []
    reference_rows: list[dict[str, object]] = []
    for index in range(10):
        raw = 4_000 + index * 437
        monotonic = 1_000_000 + index * 200_000
        can_documents.append(
            _observation(index + 1, monotonic, 0x2C4, raw.to_bytes(2, "big") + bytes(6))
        )
        reference_rows.append(
            {
                "gateway_monotonic_microseconds": monotonic + 5_000,
                "signal_id": "reference.engine.speed",
                "value": raw / 4,
                "unit": "rpm",
                "source": "SAE_J1979",
            }
        )
    can_path.write_text(
        "".join(json.dumps(item) + "\n" for item in can_documents), encoding="utf-8"
    )
    with reference_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(reference_rows[0]))
        writer.writeheader()
        writer.writerows(reference_rows)

    report = correlate_can_with_reference([can_path], [reference_path])
    ContractCatalog.load().validate(report)

    candidate = next(
        item
        for item in report["ranked_candidates"]
        if item["identifier"] == "0x2C4" and item["field"] == "be16_0"
    )
    assert candidate["paired_samples"] == 10
    assert candidate["pearson_correlation"] == 1.0
    assert candidate["linear_scale"] == 0.25
    assert candidate["linear_offset"] == 0.0
    assert candidate["rmse"] == 0.0
    assert report["promotion_allowed"] is False
    assert report["status"] == "VALIDATION_CANDIDATE"


def test_reference_unit_conflict_is_rejected(tmp_path: Path) -> None:
    can_path = tmp_path / "passive.ndjson"
    can_path.write_text(
        json.dumps(_observation(1, 1_000_000, 0x2C4, bytes(8))) + "\n",
        encoding="utf-8",
    )
    reference_path = tmp_path / "reference.csv"
    reference_path.write_text(
        "gateway_monotonic_microseconds,signal_id,value,unit,source\n"
        "1000000,reference.engine.speed,1000,rpm,SAE_J1979\n"
        "1100000,reference.engine.speed,16.67,Hz,TECHSTREAM\n",
        encoding="utf-8",
    )

    with pytest.raises(ReferenceCorrelationError, match="units are inconsistent"):
        correlate_can_with_reference([can_path], [reference_path])
