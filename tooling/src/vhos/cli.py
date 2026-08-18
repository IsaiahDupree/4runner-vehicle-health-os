from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .ac_metrics import SIMULATOR_AC_SIGNALS, calculate_ac_metrics
from .bundles import BundleError, load_validated_bundle, write_simulator_bundle
from .can_discovery import CANDiscoveryError, analyze_passive_can, load_passive_can_ndjson
from .contracts import ContractCatalog, ContractError
from .evidence_inbox import EvidenceInboxError, EvidenceInboxStore, serve_evidence_inbox
from .firmware_package import build_firmware_package, verify_firmware_package
from .j1979 import (
    J1979Error,
    decode_standard_samples,
    enumerate_supported_pids,
    load_j1979_ndjson,
)
from .replay import replay_bundle
from .reference_correlation import ReferenceCorrelationError, correlate_can_with_reference
from .simulator import generate_ac_bench_sweep, generate_cold_start_idle


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vhos")
    subcommands = parser.add_subparsers(dest="command", required=True)

    contracts = subcommands.add_parser("contracts", help="Inspect contract schemas")
    contracts_subcommands = contracts.add_subparsers(dest="contracts_command", required=True)
    contracts_subcommands.add_parser("check", help="Validate every JSON Schema")

    simulate = subcommands.add_parser("simulate", help="Generate a deterministic capture bundle")
    simulate.add_argument(
        "--scenario", choices=["cold-start-idle", "ac-bench-sweep"], required=True
    )
    simulate.add_argument("--output", type=Path, required=True)
    simulate.add_argument("--replace", action="store_true")

    validate_bundle = subcommands.add_parser(
        "validate-bundle", help="Validate manifest, hashes, records, IDs, sequence, and timestamps"
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

    decode_j1979 = subcommands.add_parser(
        "decode-j1979",
        help="Enumerate supported Mode 01 PIDs per ECU and decode only pinned, supported values",
    )
    decode_j1979.add_argument(
        "input", type=Path, nargs="+", help="One or more obd.j1979-response NDJSON files"
    )
    decode_j1979.add_argument("--supported-output", type=Path, required=True)
    decode_j1979.add_argument("--samples-output", type=Path, required=True)

    correlate_reference = subcommands.add_parser(
        "correlate-can-reference",
        help="Rank raw fields from 0x2C4, 0x025, and 0x2C1 against synchronized reference samples",
    )
    correlate_reference.add_argument("--can", type=Path, action="append", required=True)
    correlate_reference.add_argument("--reference", type=Path, action="append", required=True)
    correlate_reference.add_argument(
        "--identifier",
        action="append",
        type=lambda value: int(value, 0),
        help="11-bit CAN identifier; defaults to 0x2C4, 0x025, and 0x2C1",
    )
    correlate_reference.add_argument("--maximum-pairing-delta-us", type=int, default=250_000)
    correlate_reference.add_argument("--output", type=Path, required=True)

    evidence_inbox = subcommands.add_parser(
        "evidence-inbox", help="Run or inspect the authenticated private evidence receiver"
    )
    inbox_commands = evidence_inbox.add_subparsers(dest="inbox_command", required=True)
    inbox_serve = inbox_commands.add_parser("serve", help="Serve the append-only evidence inbox")
    inbox_serve.add_argument("--root", type=Path, required=True)
    inbox_serve.add_argument("--bind", default="127.0.0.1")
    inbox_serve.add_argument("--port", type=int, default=8765)
    inbox_serve.add_argument("--token-env", default="VHOS_EVIDENCE_INBOX_TOKEN")
    inbox_serve.add_argument("--tls-certificate", type=Path)
    inbox_serve.add_argument("--tls-private-key", type=Path)
    inbox_list = inbox_commands.add_parser("list", help="List accepted evidence packages")
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
    package_firmware.add_argument("--minimum-supply-millivolts", type=int, required=True)
    package_firmware.add_argument("--minimum-bootloader-version")
    package_firmware.add_argument("--release-channel", default="development")

    verify_firmware = subcommands.add_parser(
        "verify-firmware-package", help="Verify a .vhosota package and print its manifest"
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
                    raise BundleError(f"A/C calculation output already exists: {args.output}")
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
                        item["enumeration_complete"] for item in supported["ecu_results"]
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
        if args.command == "evidence-inbox":
            store = EvidenceInboxStore(args.root)
            if args.inbox_command == "list":
                _print_json({"packages": store.list_packages(pending_only=args.pending_only)})
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
        ContractError,
        EvidenceInboxError,
        J1979Error,
        ReferenceCorrelationError,
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
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_new_ndjson(path: Path, documents: list[dict[str, object]]) -> None:
    if path.exists():
        raise ValueError(f"Output already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n" for item in documents),
        encoding="utf-8",
    )


if __name__ == "__main__":
    raise SystemExit(main())
