from __future__ import annotations

from pathlib import Path

from vhos.contracts import ContractCatalog
from vhos.signal_hypotheses import evaluate_can_hypotheses, load_hypothesis_pack


ROOT = Path(__file__).resolve().parents[1]
REAL_CAPTURE = ROOT / "test-replay" / "real-can-2026-08-18" / "sessions"


def _evaluation(report: dict[str, object], hypothesis_id: str) -> dict[str, object]:
    evaluations = report["hypothesis_evaluations"]
    assert isinstance(evaluations, list)
    return next(
        item
        for item in evaluations
        if isinstance(item, dict) and item["hypothesis_id"] == hypothesis_id
    )


def test_hypothesis_pack_is_discovery_only_and_reference_complete() -> None:
    pack, _ = load_hypothesis_pack()

    assert pack["authority"]["status"] == "DISCOVERY_ONLY"
    assert pack["authority"]["accepted_signal_definitions"] == 0
    assert pack["authority"]["production_value_display_allowed"] is False
    assert pack["authority"]["automatic_promotion_allowed"] is False
    assert all(
        hypothesis["production_value_display_allowed"] is False
        for hypothesis in pack["hypotheses"]
    )


def test_real_4runner_capture_evaluates_cross_model_candidates_without_promotion() -> None:
    report = evaluate_can_hypotheses([REAL_CAPTURE])
    ContractCatalog.load().validate(report)

    assert report["status"] == "DISCOVERY_ONLY"
    assert report["promotion_allowed"] is False
    assert report["accepted_signal_definitions"] == 0
    assert report["capture_summary"] == {
        "records": 5_176,
        "sessions": 8,
        "gateways": 1,
        "unique_identifiers": 17,
        "listen_only_records": 5_176,
    }

    engine = _evaluation(report, "toyota.2c4.engine-speed.be16")
    assert engine["records"] == 659
    assert engine["target_evidence_status"] == "FIELD_PRESENT_DYNAMIC"
    assert engine["field_values"]["minimum"] == 0.0
    assert engine["field_values"]["maximum"] == 5_660.0
    assert engine["transform_evaluations"][0]["summary"]["maximum"] == 4_421.875
    assert engine["production_value_display_allowed"] is False

    turbine = _evaluation(report, "toyota.2d0.turbine-speed.be16")
    assert turbine["records"] == 626
    assert turbine["transform_evaluations"][0]["summary"]["maximum"] == 4_429.296875

    relationship = report["relationship_evaluations"][0]
    assert relationship["pairs"] == 625
    assert relationship["pearson_correlation"] == 0.99213
    assert relationship["median_right_to_left_ratio"] == 0.989529
    assert relationship["production_value_display_allowed"] is False


def test_conflicting_steering_scales_and_static_brake_capture_remain_unresolved() -> None:
    report = evaluate_can_hypotheses([REAL_CAPTURE])

    steering = _evaluation(report, "toyota.025.steering-angle.signed12")
    assert steering["field_values"]["minimum"] == -12.0
    assert steering["field_values"]["maximum"] == 39.0
    assert {
        item["transform_id"] for item in steering["transform_evaluations"]
    } == {
        "opendbc-toyota-signed12-x1p5-deg",
        "opendbc-iq-signed12-x1-deg",
        "fj-signed12-xneg0p087890625-deg",
    }

    brake = _evaluation(report, "toyota.224.brake-pressure.be16-low9")
    assert brake["target_evidence_status"] == "FIELD_PRESENT_STATIC"
    assert brake["field_values"]["minimum"] == 0.0
    assert brake["field_values"]["maximum"] == 0.0
    assert report["display_policy"]["allowed_surface"] == "ENGINEERING_RESEARCH"
    assert "OWNER_HEALTH" in report["display_policy"]["blocked_surfaces"]
