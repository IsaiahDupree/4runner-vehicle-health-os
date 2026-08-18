from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from vhos.can_replay import (
    CANReplayError,
    REQUIRED_DISPLAY_LABEL,
    build_can_replay_corpus,
    load_validated_can_replay_corpus,
    replay_can_corpus,
)
from vhos.contracts import ContractCatalog


CORPUS = Path(__file__).resolve().parents[1] / "test-replay" / "real-can-2026-08-18"


def test_real_can_corpus_is_checksum_pinned_and_explicitly_not_live() -> None:
    corpus = load_validated_can_replay_corpus(CORPUS)
    ContractCatalog.load().validate(corpus.manifest)

    assert len(corpus.records) == 5_176
    assert corpus.manifest["statistics"] == {
        "bitrates_bps": [500_000],
        "listen_only_records": 5_176,
        "records": 5_176,
        "sessions": 8,
        "total_source_bytes": 2_081_023,
        "unique_identifiers": 17,
    }
    assert corpus.manifest["semantic_digest"] == (
        "94b5e7a86d062f81509c6a442aa9229800dc691860464abfb1dd22053b10aab5"
    )
    assert corpus.manifest["source_classification"] == "REAL_CAPTURE_REPLAY"
    assert corpus.manifest["vehicle_claims_authorized"] is False
    assert corpus.manifest["display_policy"]["required_label"] == REQUIRED_DISPLAY_LABEL


@pytest.mark.parametrize("mode", ["live", "history"])
def test_real_can_clean_replay_sustains_repeated_exact_payloads(mode: str) -> None:
    report = replay_can_corpus(CORPUS, mode=mode, repeat=5)

    assert report["status"] == "PASS"
    assert report["input_records"] == 25_880
    assert report["decoded_records"] == 25_880
    assert report["exact_record_order_and_payload_match"] is True
    assert report["decoder_recoveries"] == 0
    assert report["decoder_discarded_bytes"] == 0
    assert report["required_display_label"] == REQUIRED_DISPLAY_LABEL


@pytest.mark.parametrize(
    ("mode", "fault"),
    [
        ("live", "drop-fragment"),
        ("live", "corrupt-payload"),
        ("live", "disconnect-mid-frame"),
        ("history", "drop-fragment"),
        ("history", "corrupt-payload"),
        ("history", "disconnect-mid-frame"),
    ],
)
def test_real_can_fault_replay_recovers_without_mutating_later_records(
    mode: str, fault: str
) -> None:
    report = replay_can_corpus(
        CORPUS,
        mode=mode,
        fault=fault,
        fault_interval=97,
    )

    assert report["status"] == "PASS"
    assert report["faulted_wire_frames"] > 0
    assert report["expected_missing_records"] > 0
    assert report["decoded_records"] == report["expected_records_after_faults"]
    assert report["unexpected_record_delta"] == 0
    assert report["exact_record_order_and_payload_match"] is True
    assert report["decoder_recoveries"] > 0


def test_real_can_corpus_rebuild_preserves_semantics_and_source_hashes(tmp_path: Path) -> None:
    rebuilt = tmp_path / "rebuilt"
    manifest = build_can_replay_corpus(
        [CORPUS / "sessions"],
        rebuilt,
        corpus_id="real-can-rebuild-test",
    )

    expected = load_validated_can_replay_corpus(CORPUS).manifest
    assert manifest["semantic_digest"] == expected["semantic_digest"]
    assert manifest["source_files"] == expected["source_files"]
    assert manifest["statistics"] == expected["statistics"]


def test_real_can_corpus_rejects_one_byte_source_mutation(tmp_path: Path) -> None:
    tampered = tmp_path / "tampered"
    shutil.copytree(CORPUS, tampered)
    source = tampered / "sessions" / "627753796.ndjson"
    raw = bytearray(source.read_bytes())
    raw[128] ^= 0x01
    source.write_bytes(raw)

    with pytest.raises(CANReplayError, match="SHA-256 changed"):
        load_validated_can_replay_corpus(tampered)
