from __future__ import annotations

import json
from pathlib import Path

import pytest

from vhos.contracts import ContractCatalog
from vhos.ids import deterministic_id
from vhos.marker_correlation import (
    DEFAULT_SETTLE_MICROSECONDS,
    DEFAULT_WINDOW_MICROSECONDS,
    MarkerCorrelationError,
    correlate_can_with_markers,
)


GATEWAY_ID = "esp32-9454c5b08d14"
SESSION_ID = 3_025_357_416
CAPTURE_ID = deterministic_id("capture", "selector-capture", timestamp_ms=1_000)
RUN_ID = deterministic_id("run", "selector-run", timestamp_ms=1_000)
TEMPLATE_ID = "discovery.transmission.selector-bootstrap"


def _observation(
    sequence: int, monotonic: int, identifier: int, data: list[int]
) -> dict[str, object]:
    return {
        "contract": "gateway.passive-can-observation",
        "contract_version": "1.0.0",
        "gateway_id": GATEWAY_ID,
        "session_id": SESSION_ID,
        "source_sequence": sequence,
        "monotonic_microseconds": monotonic,
        "bitrate_bps": 500_000,
        "identifier": identifier,
        "extended": False,
        "remote_request": False,
        "listen_only": True,
        "data_length": 8,
        "data": data,
        "evidence_source": "ble-live",
        "ingested_at": "2026-08-22T16:36:18Z",
    }


def _marker(
    index: int, kind: str, monotonic: int, nearest_sequence: int
) -> dict[str, object]:
    nested = {
        "contract": "vhos.discovery.event-marker",
        "contract_version": "1.0.0",
        "id": deterministic_id(
            "marker", f"selector-{index}", timestamp_ms=1_000 + index
        ),
        "capture_id": CAPTURE_ID,
        "gateway_session_id": SESSION_ID,
        "gateway_monotonic_microseconds": monotonic,
        "recorded_at": f"2026-08-22T16:36:{10 + index:02d}Z",
        "kind": kind,
        "label": kind.replace("_", " "),
        "source": "USER",
        "nearest_can_sequence": nearest_sequence,
        "note": "Controlled selector test marker.",
        "authority": "OBSERVED",
    }
    return {
        "contract": "vhos.ios.discovery-marker-ledger-record",
        "contract_version": "1.0.0",
        "gateway_id": GATEWAY_ID,
        "gateway_session_id": SESSION_ID,
        "marker": nested,
        "template_id": TEMPLATE_ID,
        "test_run_id": RUN_ID,
    }


def _write_ndjson(path: Path, documents: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(document, sort_keys=True) + "\n" for document in documents),
        encoding="utf-8",
    )


def _selector_fixture(tmp_path: Path) -> tuple[Path, Path]:
    marker_times = [500_000, 1_000_000, 3_000_000, 5_000_000, 7_000_000, 9_000_000]
    markers = [
        _marker(0, "CUSTOM", marker_times[0], 1),
        _marker(1, "SELECTOR_PARK", marker_times[1], 10),
        _marker(2, "SELECTOR_REVERSE", marker_times[2], 20),
        _marker(3, "SELECTOR_NEUTRAL", marker_times[3], 30),
        _marker(4, "SELECTOR_DRIVE", marker_times[4], 40),
        _marker(5, "SELECTOR_PARK", marker_times[5], 50),
    ]
    can = [
        _observation(10, 1_000_000, 0x2D0, [7, 8, 8, 0, 32, 0, 0, 17]),
        _observation(20, 3_500_000, 0x2D0, [5, 243, 2, 0, 32, 0, 0, 244]),
        _observation(30, 6_000_000, 0x2D0, [6, 159, 8, 0, 32, 0, 0, 167]),
        _observation(40, 7_000_000, 0x2D0, [0, 0, 16, 0, 32, 0, 1, 11]),
        _observation(41, 7_500_000, 0x2D0, [0, 0, 16, 0, 32, 0, 1, 11]),
        _observation(50, 12_500_000, 0x2D0, [7, 10, 8, 0, 32, 0, 0, 19]),
    ]
    can_path = tmp_path / "selector-can.ndjson"
    marker_path = tmp_path / "selector-markers.ndjson"
    _write_ndjson(can_path, can)
    _write_ndjson(marker_path, markers)
    return can_path, marker_path


def test_sparse_selector_markers_rank_candidates_without_claiming_mapping(
    tmp_path: Path,
) -> None:
    can_path, marker_path = _selector_fixture(tmp_path)

    report = correlate_can_with_markers([can_path], [marker_path])
    ContractCatalog.load().validate(report)

    assert report["parameters"] == {
        "settle_microseconds": DEFAULT_SETTLE_MICROSECONDS,
        "window_microseconds": DEFAULT_WINDOW_MICROSECONDS,
    }
    candidate = next(
        item
        for item in report["ranked_candidates"]
        if item["identifier"] == "0x2D0" and item["field"] == "byte2"
    )
    assert [item["kind"] for item in candidate["signature"]] == [
        "SELECTOR_PARK",
        "SELECTOR_REVERSE",
        "SELECTOR_NEUTRAL",
        "SELECTOR_DRIVE",
        "SELECTOR_PARK",
    ]
    assert [item["value"] for item in candidate["signature"]] == [8, 2, 8, 16, 8]
    assert candidate["ambiguous_marker_kinds"] == [
        ["SELECTOR_NEUTRAL", "SELECTOR_PARK"]
    ]
    assert candidate["minimum_window_observations"] == 1
    assert candidate["evidence_density"] < 0.5
    assert candidate["score"] < candidate["association_score"]
    assert report["promotion_allowed"] is False
    assert "do not establish Toyota semantics" in report["authority"]


def test_marker_correlation_rejects_duplicate_marker_identity(tmp_path: Path) -> None:
    can_path, marker_path = _selector_fixture(tmp_path)
    first = marker_path.read_text(encoding="utf-8").splitlines()[0]
    with marker_path.open("a", encoding="utf-8") as handle:
        handle.write(first + "\n")

    with pytest.raises(MarkerCorrelationError, match="duplicate marker identity"):
        correlate_can_with_markers([can_path], [marker_path])
