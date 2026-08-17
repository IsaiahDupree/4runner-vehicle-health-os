from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .ac_metrics import SIMULATOR_AC_SIGNALS, calculate_ac_metrics
from .bundles import BundleError, load_validated_bundle, write_simulator_bundle
from .contracts import ContractCatalog, ContractError
from .firmware_package import build_firmware_package, verify_firmware_package
from .replay import replay_bundle
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
    except (BundleError, ContractError, OSError, ValueError) as exc:
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


if __name__ == "__main__":
    raise SystemExit(main())
