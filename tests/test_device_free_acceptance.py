from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

import pytest


SCRIPT = (
    Path(__file__).resolve().parents[1] / "ios/tools/vhos_device_free_acceptance.py"
)
SPEC = importlib.util.spec_from_file_location("vhos_device_free_acceptance", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
acceptance = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = acceptance
SPEC.loader.exec_module(acceptance)


def load_summary(output: Path) -> dict[str, object]:
    return json.loads((output / "summary.json").read_text(encoding="utf-8"))


def test_real_subprocess_gate_records_command_log_duration_and_hash(
    tmp_path: Path,
) -> None:
    output = tmp_path / "acceptance"
    run = acceptance.DeviceFreeAcceptanceRun(output, {"fixture": "tiny-real-command"})
    gate = acceptance.GateSpec(
        "tiny-pass",
        (sys.executable, "-c", "print('durable gate output')"),
        tmp_path,
        10,
    )

    run.run_gate(gate)
    run.succeed(["tiny-pass"])

    summary = load_summary(output)
    assert summary["outcome"] == "PASS_DEVICE_FREE"
    assert summary["device_free_gates_passed"] is True
    assert summary["offline_passed_gates"] == ["tiny-pass"]
    assert summary["release_ready"] is False
    assert summary["remaining_physical_gates"]
    recorded = summary["gates"][0]
    assert recorded["result"] == "PASS"
    assert recorded["command"] == list(gate.command)
    assert recorded["cwd"] == str(tmp_path)
    assert recorded["duration_seconds"] >= 0
    log = output / recorded["log"]["path"]
    assert "durable gate output" in log.read_text(encoding="utf-8")
    assert recorded["log"]["sha256"] == acceptance.sha256_file(log)


def test_nonzero_real_subprocess_is_terminal_and_fail_closed(tmp_path: Path) -> None:
    output = tmp_path / "acceptance"
    run = acceptance.DeviceFreeAcceptanceRun(output, {"fixture": "tiny-real-failure"})
    failing = acceptance.GateSpec(
        "tiny-fail",
        (sys.executable, "-c", "print('before failure'); raise SystemExit(7)"),
        tmp_path,
        10,
    )

    with pytest.raises(acceptance.GateFailure, match="exited 7"):
        run.run_gate(failing)

    summary = load_summary(output)
    assert summary["outcome"] == "FAIL"
    assert summary["device_free_gates_passed"] is False
    assert summary["release_ready"] is False
    assert summary["gates"][0]["result"] == "FAIL"
    assert summary["gates"][0]["returncode"] == 7
    assert summary["failure"]["gate"] == "tiny-fail"
    with pytest.raises(RuntimeError, match="already terminal"):
        run.run_gate(failing)


def test_required_artifact_is_hashed_without_following_symlinks(tmp_path: Path) -> None:
    output = tmp_path / "acceptance"
    artifact = tmp_path / "artifact.bin"
    artifact.write_bytes(b"real build artifact")
    run = acceptance.DeviceFreeAcceptanceRun(output, {"fixture": "artifact"})

    run.add_artifacts([artifact], kind="test-artifact", expected_root=tmp_path)

    summary = load_summary(output)
    assert summary["artifacts"] == [
        {
            "kind": "test-artifact",
            "path": str(artifact),
            "expected_root": str(tmp_path),
            "bytes": len(b"real build artifact"),
            "sha256": acceptance.sha256_file(artifact),
        }
    ]

    linked = tmp_path / "linked-artifact.bin"
    linked.symlink_to(artifact)
    with pytest.raises(FileNotFoundError, match="must not contain a symbolic link"):
        run.add_artifacts(
            [linked], kind="test-artifact", expected_root=tmp_path
        )


def test_required_artifact_rejects_a_symlinked_parent_directory(
    tmp_path: Path,
) -> None:
    output = tmp_path / "acceptance"
    real_directory = tmp_path / "real-products"
    real_directory.mkdir()
    artifact = real_directory / "app.apk"
    artifact.write_bytes(b"real APK")
    linked_directory = tmp_path / "build-products"
    linked_directory.symlink_to(real_directory, target_is_directory=True)
    run = acceptance.DeviceFreeAcceptanceRun(output, {"fixture": "artifact-parent"})

    with pytest.raises(FileNotFoundError, match="must not contain a symbolic link"):
        run.add_artifacts(
            [linked_directory / artifact.name],
            kind="android-debug-apk",
            expected_root=tmp_path,
        )


def _sdk_config(
    tmp_path: Path,
    *,
    configured_sdk: Path,
    compile_sdk: int = 35,
    platform_name: str | None = None,
) -> object:
    android_repo = tmp_path / "android"
    android_repo.mkdir(exist_ok=True)
    (android_repo / "build.gradle.kts").write_text(
        f"android {{ compileSdk = {compile_sdk} }}\n", encoding="utf-8"
    )
    platform = configured_sdk / "platforms" / (
        platform_name or f"android-{compile_sdk}"
    )
    platform.mkdir(parents=True, exist_ok=True)
    (platform / "android.jar").write_bytes(b"attested platform")
    (platform / "source.properties").write_text(
        "Pkg.Revision = 1\n", encoding="utf-8"
    )
    return acceptance.AcceptanceConfig(
        repo=tmp_path,
        app_data=tmp_path,
        baseline=None,
        output=tmp_path / "output",
        android_repo=android_repo,
        soak_cycles=1,
        ios_destination="platform=iOS Simulator,name=Test",
        java_home=tmp_path,
        android_sdk=configured_sdk,
    )


def test_android_sdk_provenance_requires_local_properties_to_match_environment(
    tmp_path: Path,
) -> None:
    configured_sdk = tmp_path / "configured-sdk"
    config = _sdk_config(tmp_path, configured_sdk=configured_sdk)
    (config.android_repo / "local.properties").write_text(
        f"sdk.dir={tmp_path / 'different-sdk'}\n", encoding="utf-8"
    )

    with pytest.raises(ValueError, match="Android SDK selection conflict"):
        acceptance.android_sdk_provenance(config)


def test_android_sdk_provenance_hashes_the_exact_gradle_platform(
    tmp_path: Path,
) -> None:
    configured_sdk = tmp_path / "configured-sdk"
    config = _sdk_config(tmp_path, configured_sdk=configured_sdk)
    (config.android_repo / "local.properties").write_text(
        f"sdk.dir={configured_sdk}\n", encoding="utf-8"
    )

    provenance = acceptance.android_sdk_provenance(config)

    android_jar = configured_sdk / "platforms/android-35/android.jar"
    assert provenance["selection"] == "environment-and-local.properties-agree"
    assert provenance["compile_sdk"] == 35
    assert provenance["android_jar"] == {
        "path": str(android_jar),
        "bytes": android_jar.stat().st_size,
        "sha256": acceptance.sha256_file(android_jar),
    }


def test_android_sdk_provenance_selects_base_minor_not_newer_installed_minor(
    tmp_path: Path,
) -> None:
    configured_sdk = tmp_path / "configured-sdk"
    config = _sdk_config(
        tmp_path,
        configured_sdk=configured_sdk,
        compile_sdk=37,
        platform_name="android-37.0",
    )
    newer = configured_sdk / "platforms/android-37.1"
    newer.mkdir(parents=True)
    (newer / "android.jar").write_bytes(b"must not be selected")
    (config.android_repo / "local.properties").write_text(
        f"sdk.dir={configured_sdk}\n", encoding="utf-8"
    )

    provenance = acceptance.android_sdk_provenance(config)

    assert provenance["compile_sdk"] == 37
    assert provenance["compile_target"] == "android-37.0"
    assert provenance["android_jar"]["path"].endswith(
        "platforms/android-37.0/android.jar"
    )


def test_android_sdk_provenance_rejects_duplicate_sdk_dir_keys(
    tmp_path: Path,
) -> None:
    configured_sdk = tmp_path / "configured-sdk"
    config = _sdk_config(tmp_path, configured_sdk=configured_sdk)
    (config.android_repo / "local.properties").write_text(
        f"sdk.dir={configured_sdk}\nsdk.dir={tmp_path / 'other-sdk'}\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="at most one sdk.dir"):
        acceptance.android_sdk_provenance(config)


def test_android_sdk_provenance_rejects_symlinked_platform_directory(
    tmp_path: Path,
) -> None:
    configured_sdk = tmp_path / "configured-sdk"
    config = _sdk_config(tmp_path, configured_sdk=configured_sdk)
    platform = configured_sdk / "platforms/android-35"
    real_platform = tmp_path / "external-platform"
    platform.rename(real_platform)
    platform.symlink_to(real_platform, target_is_directory=True)

    with pytest.raises(FileNotFoundError, match="must not contain a symbolic link"):
        acceptance.android_sdk_provenance(config)


def test_production_plan_is_device_free_and_contains_every_required_gate(
    tmp_path: Path,
) -> None:
    repo = Path(__file__).resolve().parents[1]
    config = acceptance.AcceptanceConfig(
        repo=repo,
        app_data=tmp_path / "app-data",
        baseline=tmp_path / "baseline",
        output=tmp_path / "output",
        android_repo=tmp_path / "android",
        soak_cycles=37,
        ios_destination="platform=iOS Simulator,name=Acceptance Test Phone,OS=latest",
        java_home=tmp_path / "jdk17",
        android_sdk=tmp_path / "android-sdk",
    )

    gates = acceptance.build_gate_specs(config)

    assert [gate.name for gate in gates] == [
        "contracts",
        "python-tests",
        "field-return-analysis",
        "swift-core-tests",
        "ios-simulator-tests",
        "ios-simulator-build",
        "android-tests-lint-build",
    ]
    commands = "\n".join(shlex for gate in gates for shlex in gate.command).lower()
    assert "analyze-field-return" in commands
    assert "--soak-cycles" in commands
    assert "37" in commands
    assert "devicectl" not in commands
    assert "adb" not in commands
    assert "usbserial" not in commands
    assert "bluetooth" not in commands
    android = gates[-1]
    assert android.command == (
        "./gradlew",
        "test",
        "lint",
        "assembleDebug",
        "--rerun-tasks",
    )
    assert android.environment["JAVA_HOME"] == str(config.java_home)
    assert android.environment["ANDROID_SDK_ROOT"] == str(config.android_sdk)


def test_field_return_lineage_proves_one_11045_observation_corpus(
    tmp_path: Path,
) -> None:
    output = tmp_path / "output"
    evidence = output / "evidence/full"
    corpus_directory = evidence / "replay-corpus"
    corpus_directory.mkdir(parents=True)
    analysis = {
        "analysis_scopes": {
            "full": {
                "status": "PASS",
                "records": 11_045,
                "portable_recovered_records": 10_709,
                "supplemental_direct_records": 336,
                "corpus_id": "field-return-real-corpus",
                "corpus_path": "full/replay-corpus",
                "replay_path": "full/replay.json",
                "reliability_path": "full/link-reliability.json",
                "semantic_digest": "abc123",
            }
        }
    }
    corpus = {
        "corpus_id": "field-return-real-corpus",
        "semantic_digest": "abc123",
        "source_classification": "REAL_CAPTURE_REPLAY",
        "vehicle_claims_authorized": False,
        "statistics": {
            "records": 11_045,
            "listen_only_records": 11_045,
            "sessions": 15,
            "unique_identifiers": 17,
        },
    }
    replay_result = {
        "corpus_id": "field-return-real-corpus",
        "input_records": 11_045,
        "decoded_records": 11_045,
        "exact_record_order_and_payload_match": True,
    }
    reliability = {
        "corpus_id": "field-return-real-corpus",
        "acceptance_status": "PASS",
        "scenario_count": 15,
        "soak_cycles": 20,
        "scenarios": [{"unique_input_records": 11_045} for _ in range(15)],
    }
    (output / "evidence/manifest.json").write_text(json.dumps(analysis))
    (corpus_directory / "manifest.json").write_text(json.dumps(corpus))
    (evidence / "replay.json").write_text(
        json.dumps({"live": replay_result, "history": replay_result})
    )
    (evidence / "link-reliability.json").write_text(json.dumps(reliability))
    config = acceptance.AcceptanceConfig(
        repo=tmp_path,
        app_data=tmp_path,
        baseline=None,
        output=output,
        android_repo=tmp_path,
        soak_cycles=20,
        ios_destination="platform=iOS Simulator,name=Test",
        java_home=tmp_path,
        android_sdk=tmp_path,
    )

    proof = acceptance.prove_field_return_evidence_chain(config)

    assert proof["status"] == "PASS"
    assert proof["recovered_observations"] == 11_045
    assert proof["live_replay_input_observations"] == 11_045
    assert proof["history_replay_input_observations"] == 11_045
    assert proof["reliability_input_observations_per_scenario"] == [11_045]
    assert all(proof["checks"].values())

    reliability["scenarios"][4]["unique_input_records"] = 11_044
    (evidence / "link-reliability.json").write_text(json.dumps(reliability))
    with pytest.raises(
        acceptance.GateFailure, match="reliability_consumed_exact_corpus"
    ):
        acceptance.prove_field_return_evidence_chain(config)


def test_output_nested_in_app_data_is_rejected_before_any_write(tmp_path: Path) -> None:
    app_data = tmp_path / "copied-app-data"
    app_data.mkdir()
    output = app_data / "must-not-be-created"

    result = acceptance.main(
        [
            "--app-data",
            str(app_data),
            "--output",
            str(output),
            "--android-repo",
            str(tmp_path / "android"),
        ]
    )

    assert result == 2
    assert not output.exists()


def test_symbolic_link_app_data_is_rejected_before_resolution(tmp_path: Path) -> None:
    real_app_data = tmp_path / "real-app-data"
    real_app_data.mkdir()
    linked_app_data = tmp_path / "linked-app-data"
    linked_app_data.symlink_to(real_app_data, target_is_directory=True)
    output = tmp_path / "output"

    result = acceptance.main(
        [
            "--app-data",
            str(linked_app_data),
            "--output",
            str(output),
            "--android-repo",
            str(tmp_path / "android"),
        ]
    )

    assert result == 2
    assert not output.exists()


def test_physical_style_destination_cannot_spoof_simulator_guard(
    tmp_path: Path,
) -> None:
    config = acceptance.AcceptanceConfig(
        repo=tmp_path,
        app_data=tmp_path,
        baseline=None,
        output=tmp_path / "output",
        android_repo=tmp_path,
        soak_cycles=1,
        ios_destination="platform=iOS,name=Simulator",
        java_home=tmp_path,
        android_sdk=tmp_path,
    )

    with pytest.raises(ValueError, match="platform=iOS Simulator"):
        acceptance.validate_config(config)


def test_swift_testing_summary_wins_over_zero_test_xctest_compatibility_footer(
    tmp_path: Path,
) -> None:
    log = tmp_path / "swift.log"
    log.write_text(
        "Executed 0 tests, with 0 failures (0 unexpected)\n"
        "\u2714 Test run with 140 tests in 1 suite passed after 2.785 seconds.\n",
        encoding="utf-8",
    )

    assert acceptance._last_test_count(log) == {
        "tests_executed": 140,
        "test_failures": 0,
    }


def test_swift_testing_summary_reports_nonzero_test_count(tmp_path: Path) -> None:
    log = tmp_path / "swift.log"
    log.write_text("Test run with 140 tests in 1 suite passed after 0.123 seconds.\n")

    assert acceptance._last_test_count(log) == {
        "tests_executed": 140,
        "test_failures": 0,
    }
