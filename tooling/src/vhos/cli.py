from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .ac_metrics import SIMULATOR_AC_SIGNALS, calculate_ac_metrics
from .bundles import BundleError, load_validated_bundle, write_simulator_bundle
from .can_discovery import (
    CANDiscoveryError,
    analyze_passive_can,
    load_passive_can_ndjson,
)
from .can_replay import (
    CANReplayError,
    build_can_replay_corpus,
    load_validated_can_replay_corpus,
    replay_can_corpus,
    run_link_reliability_matrix,
    write_can_replay_fixture,
)
from .contracts import ContractCatalog, ContractError
from .evidence_inbox import EvidenceInboxError, EvidenceInboxStore, serve_evidence_inbox
from .field_return import FieldReturnAnalysisError, analyze_field_return
from .firmware_package import build_firmware_package, verify_firmware_package
from .j1979 import (
    J1979Error,
    decode_standard_samples,
    enumerate_supported_pids,
    load_j1979_ndjson,
)
from .marker_correlation import (
    DEFAULT_SETTLE_MICROSECONDS,
    DEFAULT_WINDOW_MICROSECONDS,
    MarkerCorrelationError,
    correlate_can_with_markers,
)
from .portable_can import (
    PortableCANError,
    extract_portable_can,
    load_recovered_can_extraction,
)
from .replay import replay_bundle
from .reference_correlation import (
    ReferenceCorrelationError,
    correlate_can_with_reference,
)
from .signal_hypotheses import SignalHypothesisError, evaluate_can_hypotheses
from .simulator import generate_ac_bench_sweep, generate_cold_start_idle


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vhos")
    subcommands = parser.add_subparsers(dest="command", required=True)

    contracts = subcommands.add_parser("contracts", help="Inspect contract schemas")
    contracts_subcommands = contracts.add_subparsers(
        dest="contracts_command", required=True
    )
    contracts_subcommands.add_parser("check", help="Validate every JSON Schema")

    simulate = subcommands.add_parser(
        "simulate", help="Generate a deterministic capture bundle"
    )
    simulate.add_argument(
        "--scenario", choices=["cold-start-idle", "ac-bench-sweep"], required=True
    )
    simulate.add_argument("--output", type=Path, required=True)
    simulate.add_argument("--replace", action="store_true")

    validate_bundle = subcommands.add_parser(
        "validate-bundle",
        help="Validate manifest, hashes, records, IDs, sequence, and timestamps",
    )
    validate_bundle.add_argument("bundle", type=Path)

    replay = subcommands.add_parser("replay", help="Replay a validated capture bundle")
    replay.add_argument("bundle", type=Path)
    replay.add_argument("--output", type=Path)

    calculate_ac = subcommands.add_parser(
        "calculate-ac",
        help="Calculate only evidence-complete A/C metrics; never infer charge or component faults",
    )
    calculate_ac.add_argument("bundle", type=Path)
    calculate_ac.add_argument("--output", type=Path)

    discover_can = subcommands.add_parser(
        "discover-can",
        help="Analyze passive CAN NDJSON without assigning unverified vehicle meanings",
    )
    discover_can.add_argument(
        "input",
        type=Path,
        nargs="+",
        help="One or more passive CAN NDJSON files or directories",
    )
    discover_can.add_argument("--output", type=Path)

    evaluate_hypotheses = subcommands.add_parser(
        "evaluate-can-hypotheses",
        help="Evaluate unverified cross-model signal hypotheses against passive target evidence",
    )
    evaluate_hypotheses.add_argument(
        "input",
        type=Path,
        nargs="+",
        help="One or more passive CAN NDJSON files or directories",
    )
    evaluate_hypotheses.add_argument(
        "--pack",
        type=Path,
        help="Versioned can.signal-hypothesis-pack; defaults to the checked-in 2005 4Runner pack",
    )
    evaluate_hypotheses.add_argument("--output", type=Path)

    extract_portable = subcommands.add_parser(
        "extract-portable-can",
        help="Recover validated passive CAN observations from iOS portable evidence",
    )
    extract_portable.add_argument(
        "input",
        type=Path,
        nargs="+",
        help="One or more .vhossync bundles, logical-frames.ndjson files, or containing directories",
    )
    extract_portable.add_argument("--output", type=Path, required=True)
    extract_portable.add_argument(
        "--session-id",
        type=int,
        action="append",
        help="Recover only this gateway recorder session; repeat for multiple sessions",
    )

    discover_recovered = subcommands.add_parser(
        "discover-recovered-can",
        help="Analyze a complete recovered-CAN extraction while retaining its non-authority label",
    )
    discover_recovered.add_argument(
        "extraction",
        type=Path,
        help="Root created by extract-portable-can; manifest.json is mandatory",
    )
    discover_recovered.add_argument("--output", type=Path)

    build_can_replay = subcommands.add_parser(
        "build-can-replay-corpus",
        help="Pin real passive-CAN evidence into a checksum-verified offline replay corpus",
    )
    build_can_replay.add_argument("input", type=Path, nargs="+")
    build_can_replay.add_argument("--output", type=Path, required=True)
    build_can_replay.add_argument("--corpus-id", required=True)

    validate_can_replay = subcommands.add_parser(
        "validate-can-replay-corpus",
        help="Verify every source hash, record identity, statistic, and semantic digest",
    )
    validate_can_replay.add_argument("corpus", type=Path)

    replay_can = subcommands.add_parser(
        "replay-can-corpus",
        help="Replay real observations through deployed VHOS framing with optional faults",
    )
    replay_can.add_argument("corpus", type=Path)
    replay_can.add_argument("--mode", choices=["live", "history"], default="live")
    replay_can.add_argument("--repeat", type=int, default=1)
    replay_can.add_argument(
        "--fault",
        choices=["clean", "drop-fragment", "corrupt-payload", "disconnect-mid-frame"],
        default="clean",
    )
    replay_can.add_argument("--fault-interval", type=int, default=257)
    replay_can.add_argument("--output", type=Path)

    reliability = subcommands.add_parser(
        "test-link-reliability",
        help="Run deterministic degraded-link and soak tests against pinned real CAN evidence",
    )
    reliability.add_argument("corpus", type=Path)
    reliability.add_argument("--soak-cycles", type=int, default=20)
    reliability.add_argument("--output", type=Path)

    replay_fixture = subcommands.add_parser(
        "export-can-replay-fixture",
        help="Export a deterministic real-capture excerpt for another platform's contract tests",
    )
    replay_fixture.add_argument("corpus", type=Path)
    replay_fixture.add_argument("--session-id", type=int, required=True)
    replay_fixture.add_argument("--records", type=int, required=True)
    replay_fixture.add_argument("--output", type=Path, required=True)

    decode_j1979 = subcommands.add_parser(
        "decode-j1979",
        help="Enumerate supported Mode 01 PIDs per ECU and decode only pinned, supported values",
    )
    decode_j1979.add_argument(
        "input",
        type=Path,
        nargs="+",
        help="One or more obd.j1979-response NDJSON files",
    )
    decode_j1979.add_argument("--supported-output", type=Path, required=True)
    decode_j1979.add_argument("--samples-output", type=Path, required=True)

    correlate_reference = subcommands.add_parser(
        "correlate-can-reference",
        help="Rank raw fields from 0x2C4, 0x025, and 0x2C1 against synchronized reference samples",
    )
    correlate_reference.add_argument("--can", type=Path, action="append", required=True)
    correlate_reference.add_argument(
        "--reference", type=Path, action="append", required=True
    )
    correlate_reference.add_argument(
        "--identifier",
        action="append",
        type=lambda value: int(value, 0),
        help="11-bit CAN identifier; defaults to 0x2C4, 0x025, and 0x2C1",
    )
    correlate_reference.add_argument(
        "--maximum-pairing-delta-us", type=int, default=250_000
    )
    correlate_reference.add_argument("--output", type=Path, required=True)

    correlate_markers = subcommands.add_parser(
        "correlate-can-markers",
        help="Rank raw CAN fields against synchronized append-only Discovery event markers",
    )
    correlate_markers.add_argument("--can", type=Path, action="append", required=True)
    correlate_markers.add_argument(
        "--markers", type=Path, action="append", required=True
    )
    correlate_markers.add_argument("--settle-us", type=int, default=0)
    correlate_markers.add_argument("--window-us", type=int, default=4_000_000)
    correlate_markers.add_argument("--output", type=Path, required=True)

    field_return = subcommands.add_parser(
        "analyze-field-return",
        help="Validate and analyze a copied iPhone field return in one atomic offline run",
    )
    field_return.add_argument(
        "app_data",
        type=Path,
        help="Copied iPhone application-data directory",
    )
    field_return.add_argument(
        "--baseline",
        type=Path,
        help="Optional earlier copied app-data directory; must be an exact ledger prefix",
    )
    field_return.add_argument("--output", type=Path, required=True)
    field_return.add_argument("--soak-cycles", type=int, default=20)
    field_return.add_argument(
        "--pack",
        type=Path,
        help="Optional versioned CAN hypothesis pack",
    )
    field_return.add_argument(
        "--marker-settle-us", type=int, default=DEFAULT_SETTLE_MICROSECONDS
    )
    field_return.add_argument(
        "--marker-window-us", type=int, default=DEFAULT_WINDOW_MICROSECONDS
    )

    evidence_inbox = subcommands.add_parser(
        "evidence-inbox",
        help="Run or inspect the authenticated private evidence receiver",
    )
    inbox_commands = evidence_inbox.add_subparsers(dest="inbox_command", required=True)
    inbox_serve = inbox_commands.add_parser(
        "serve", help="Serve the append-only evidence inbox"
    )
    inbox_serve.add_argument("--root", type=Path, required=True)
    inbox_serve.add_argument("--bind", default="127.0.0.1")
    inbox_serve.add_argument("--port", type=int, default=8765)
    inbox_serve.add_argument("--token-env", default="VHOS_EVIDENCE_INBOX_TOKEN")
    inbox_serve.add_argument("--tls-certificate", type=Path)
    inbox_serve.add_argument("--tls-private-key", type=Path)
    inbox_list = inbox_commands.add_parser(
        "list", help="List accepted evidence packages"
    )
    inbox_list.add_argument("--root", type=Path, required=True)
    inbox_list.add_argument("--pending-only", action="store_true")
    inbox_claim = inbox_commands.add_parser(
        "claim", help="Atomically claim one package for an evidence-analysis agent"
    )
    inbox_claim.add_argument("--root", type=Path, required=True)
    inbox_claim.add_argument("--package-id", required=True)
    inbox_claim.add_argument("--agent-id", required=True)

    package_firmware = subcommands.add_parser(
        "package-firmware", help="Create a signed .vhosota distribution package"
    )
    package_firmware.add_argument("--firmware", type=Path, required=True)
    package_firmware.add_argument("--output", type=Path, required=True)
    package_firmware.add_argument("--private-key", type=Path, required=True)
    package_firmware.add_argument("--firmware-version", required=True)
    package_firmware.add_argument("--firmware-build-id", required=True)
    package_firmware.add_argument("--hardware-revision", action="append", required=True)
    package_firmware.add_argument(
        "--minimum-supply-millivolts", type=int, required=True
    )
    package_firmware.add_argument("--minimum-bootloader-version")
    package_firmware.add_argument("--release-channel", default="development")

    verify_firmware = subcommands.add_parser(
        "verify-firmware-package",
        help="Verify a .vhosota package and print its manifest",
    )
    verify_firmware.add_argument("package", type=Path)
    verify_firmware.add_argument("--public-key", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "contracts":
            return _contracts(args)
        if args.command == "package-firmware":
            package = build_firmware_package(
                firmware_path=args.firmware,
                output_path=args.output,
                private_key_path=args.private_key,
                firmware_version=args.firmware_version,
                firmware_build_id=args.firmware_build_id,
                supported_hardware_revisions=args.hardware_revision,
                minimum_supply_millivolts=args.minimum_supply_millivolts,
                minimum_bootloader_version=args.minimum_bootloader_version,
                release_channel=args.release_channel,
            )
            _print_json(
                {
                    "output": str(args.output.resolve()),
                    "manifest": package.manifest,
                    "signature_bytes": len(package.signature),
                }
            )
            return 0
        if args.command == "verify-firmware-package":
            package = verify_firmware_package(args.package, args.public_key)
            _print_json({"valid": True, "manifest": package.manifest})
            return 0
        if args.command == "simulate":
            generators = {
                "cold-start-idle": generate_cold_start_idle,
                "ac-bench-sweep": generate_ac_bench_sweep,
            }
            capture = generators[args.scenario]()
            manifest = write_simulator_bundle(
                capture, args.output, replace=args.replace
            )
            _print_json(
                {
                    "bundle": str(args.output.resolve()),
                    "capture_id": manifest["capture_id"],
                    "records": manifest["statistics"]["received_records"],
                    "semantic_digest": manifest["semantic_digest"],
                }
            )
            return 0
        if args.command == "calculate-ac":
            replay = replay_bundle(args.bundle)
            result = calculate_ac_metrics(
                replay.samples,
                signals=SIMULATOR_AC_SIGNALS,
                confidence=0.0,
                confidence_factors={"source_quality": 0.0},
                quality_notes=[
                    "SIMULATOR source: integration evidence only; not vehicle evidence or diagnosis."
                ],
            )
            report = {
                "capture_id": replay.capture_id,
                "calculations": list(result.runs),
                "unavailable": result.unavailable,
            }
            if args.output:
                if args.output.exists():
                    raise BundleError(
                        f"A/C calculation output already exists: {args.output}"
                    )
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(
                    json.dumps(report, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            _print_json(report)
            return 0
        if args.command == "discover-can":
            records, sources = load_passive_can_ndjson(args.input)
            report = analyze_passive_can(records, sources=sources)
            ContractCatalog.load().validate(report)
            if args.output:
                if args.output.exists():
                    raise CANDiscoveryError(
                        f"CAN discovery output already exists: {args.output}"
                    )
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(
                    json.dumps(report, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            _print_json(report)
            return 0
        if args.command == "evaluate-can-hypotheses":
            report = evaluate_can_hypotheses(args.input, pack_path=args.pack)
            if args.output:
                _write_new_json(args.output, report)
            _print_json(report)
            return 0
        if args.command == "extract-portable-can":
            manifest = extract_portable_can(
                args.input,
                args.output,
                session_ids=args.session_id or (),
            )
            _print_json(
                {
                    "output": str(args.output.resolve()),
                    "records": manifest["statistics"]["recovered_unique_observations"],
                    "sessions": manifest["statistics"]["sessions"],
                    "duplicates_reconciled": manifest["statistics"][
                        "exact_duplicate_observations"
                    ],
                    "required_display_label": manifest["display_policy"][
                        "required_label"
                    ],
                }
            )
            return 0
        if args.command == "discover-recovered-can":
            records, recovery = load_recovered_can_extraction(args.extraction)
            report = analyze_passive_can(records, sources=recovery["source_files"])
            report["recovery_provenance"] = {
                "source_classification": recovery["source_classification"],
                "vehicle_claims_authorized": recovery["vehicle_claims_authorized"],
                "required_display_label": recovery["required_display_label"],
                "extraction_manifest": recovery["extraction_manifest"],
                "source_files": recovery["original_source_files"],
                "source_bundles": recovery["source_bundles"],
                "output_files": recovery["output_files"],
            }
            report["authority"] = (
                "RECOVERED_PORTABLE_EVIDENCE; vehicle_claims_authorized=false. "
                + report["authority"]
            )
            report["display_policy"]["proven_now"].insert(
                0,
                "recovery provenance and explicit non-authority verified from the complete extraction",
            )
            ContractCatalog.load().validate(report)
            if args.output:
                _write_new_json(args.output, report)
            _print_json(report)
            return 0
        if args.command == "build-can-replay-corpus":
            manifest = build_can_replay_corpus(
                args.input,
                args.output,
                corpus_id=args.corpus_id,
            )
            _print_json(
                {
                    "corpus": str(args.output.resolve()),
                    "corpus_id": manifest["corpus_id"],
                    "records": manifest["statistics"]["records"],
                    "sessions": manifest["statistics"]["sessions"],
                    "semantic_digest": manifest["semantic_digest"],
                    "required_display_label": manifest["display_policy"][
                        "required_label"
                    ],
                }
            )
            return 0
        if args.command == "validate-can-replay-corpus":
            corpus = load_validated_can_replay_corpus(args.corpus)
            _print_json(
                {
                    "valid": True,
                    "corpus_id": corpus.manifest["corpus_id"],
                    "records": len(corpus.records),
                    "semantic_digest": corpus.manifest["semantic_digest"],
                }
            )
            return 0
        if args.command == "replay-can-corpus":
            report = replay_can_corpus(
                args.corpus,
                mode=args.mode,
                repeat=args.repeat,
                fault=args.fault,
                fault_interval=args.fault_interval,
            )
            if args.output:
                _write_new_json(args.output, report)
            _print_json(report)
            return 0
        if args.command == "test-link-reliability":
            report = run_link_reliability_matrix(
                args.corpus,
                soak_cycles=args.soak_cycles,
            )
            if args.output:
                _write_new_json(args.output, report)
            _print_json(report)
            return 0
        if args.command == "export-can-replay-fixture":
            _print_json(
                write_can_replay_fixture(
                    args.corpus,
                    args.output,
                    session_id=args.session_id,
                    limit=args.records,
                )
            )
            return 0
        if args.command == "decode-j1979":
            responses, sources = load_j1979_ndjson(args.input)
            supported = enumerate_supported_pids(responses)
            samples = decode_standard_samples(responses, supported)
            _write_new_json(args.supported_output, supported)
            _write_new_ndjson(args.samples_output, samples)
            _print_json(
                {
                    "supported_output": str(args.supported_output.resolve()),
                    "samples_output": str(args.samples_output.resolve()),
                    "source_files": sources,
                    "ecu_count": len(supported["ecu_results"]),
                    "complete_ecu_count": sum(
                        item["enumeration_complete"]
                        for item in supported["ecu_results"]
                    ),
                    "decoded_samples": len(samples),
                }
            )
            return 0
        if args.command == "correlate-can-reference":
            keyword: dict[str, object] = {
                "maximum_pairing_delta_us": args.maximum_pairing_delta_us
            }
            if args.identifier:
                keyword["identifiers"] = args.identifier
            report = correlate_can_with_reference(
                args.can,
                args.reference,
                **keyword,
            )
            _write_new_json(args.output, report)
            _print_json(
                {
                    "output": str(args.output.resolve()),
                    "reference_signals": report["reference_signals"],
                    "ranked_candidates": len(report["ranked_candidates"]),
                    "promotion_allowed": report["promotion_allowed"],
                }
            )
            return 0
        if args.command == "correlate-can-markers":
            report = correlate_can_with_markers(
                args.can,
                args.markers,
                settle_microseconds=args.settle_us,
                window_microseconds=args.window_us,
            )
            _write_new_json(args.output, report)
            _print_json(
                {
                    "output": str(args.output.resolve()),
                    "test_runs": len(report["test_runs"]),
                    "ranked_candidates": len(report["ranked_candidates"]),
                    "promotion_allowed": report["promotion_allowed"],
                }
            )
            return 0
        if args.command == "analyze-field-return":
            manifest = analyze_field_return(
                args.app_data,
                args.output,
                baseline=args.baseline,
                soak_cycles=args.soak_cycles,
                hypothesis_pack=args.pack,
                marker_settle_microseconds=args.marker_settle_us,
                marker_window_microseconds=args.marker_window_us,
            )
            full = manifest["analysis_scopes"]["full"]
            appended = manifest["analysis_scopes"]["appended"]
            _print_json(
                {
                    "output": str(args.output.resolve()),
                    "analysis_id": manifest["analysis_id"],
                    "status": manifest["status"],
                    "full_records": full["records"],
                    "appended_records": (
                        appended.get("records", 0) if appended is not None else 0
                    ),
                    "marker_candidates": full["marker_correlation"].get(
                        "ranked_candidates", 0
                    ),
                    "reliability_status": full["reliability_status"],
                    "summary": str((args.output / "SUMMARY.md").resolve()),
                }
            )
            return 0
        if args.command == "evidence-inbox":
            store = EvidenceInboxStore(args.root)
            if args.inbox_command == "list":
                _print_json(
                    {"packages": store.list_packages(pending_only=args.pending_only)}
                )
                return 0
            if args.inbox_command == "claim":
                _print_json(store.claim(args.package_id, args.agent_id))
                return 0
            if args.inbox_command == "serve":
                token = os.environ.get(args.token_env, "")
                if not token:
                    raise EvidenceInboxError(
                        f"Evidence inbox token environment variable is not set: {args.token_env}"
                    )
                serve_evidence_inbox(
                    root=args.root,
                    bind=args.bind,
                    port=args.port,
                    bearer_token=token,
                    tls_certificate=args.tls_certificate,
                    tls_private_key=args.tls_private_key,
                )
                return 0
        if args.command == "validate-bundle":
            manifest, observations = load_validated_bundle(args.bundle)
            _print_json(
                {
                    "valid": True,
                    "capture_id": manifest["capture_id"],
                    "observations": len(observations),
                    "semantic_digest": manifest["semantic_digest"],
                }
            )
            return 0
        if args.command == "replay":
            result = replay_bundle(args.bundle)
            if args.output:
                if args.output.exists():
                    raise BundleError(f"Replay output already exists: {args.output}")
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(
                    "".join(
                        json.dumps(sample, sort_keys=True, separators=(",", ":")) + "\n"
                        for sample in result.samples
                    ),
                    encoding="utf-8",
                )
            _print_json(
                {
                    "capture_id": result.capture_id,
                    "observations": result.observation_count,
                    "signal_samples": result.signal_sample_count,
                    "signal_ids": result.signal_ids,
                    "semantic_digest": result.semantic_digest,
                }
            )
            return 0
    except (
        BundleError,
        CANDiscoveryError,
        CANReplayError,
        ContractError,
        EvidenceInboxError,
        FieldReturnAnalysisError,
        J1979Error,
        MarkerCorrelationError,
        PortableCANError,
        ReferenceCorrelationError,
        SignalHypothesisError,
        OSError,
        ValueError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    parser.error("Unhandled command")
    return 2


def _contracts(args: argparse.Namespace) -> int:
    if args.contracts_command == "check":
        checked = ContractCatalog.load().check_schemas()
        _print_json({"valid": True, "schema_count": len(checked), "schemas": checked})
        return 0
    raise ValueError(f"Unhandled contracts command: {args.contracts_command}")


def _print_json(document: dict[str, object]) -> None:
    print(json.dumps(document, indent=2, sort_keys=True))


def _write_new_json(path: Path, document: dict[str, object]) -> None:
    if path.exists():
        raise ValueError(f"Output already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _write_new_ndjson(path: Path, documents: list[dict[str, object]]) -> None:
    if path.exists():
        raise ValueError(f"Output already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(
            json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n"
            for item in documents
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    raise SystemExit(main())
