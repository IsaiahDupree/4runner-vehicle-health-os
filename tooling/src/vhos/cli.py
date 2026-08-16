from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .bundles import BundleError, load_validated_bundle, write_simulator_bundle
from .contracts import ContractCatalog, ContractError
from .replay import replay_bundle
from .simulator import generate_cold_start_idle


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vhos")
    subcommands = parser.add_subparsers(dest="command", required=True)

    contracts = subcommands.add_parser("contracts", help="Inspect contract schemas")
    contracts_subcommands = contracts.add_subparsers(dest="contracts_command", required=True)
    contracts_subcommands.add_parser("check", help="Validate every JSON Schema")

    simulate = subcommands.add_parser("simulate", help="Generate a deterministic capture bundle")
    simulate.add_argument("--scenario", choices=["cold-start-idle"], required=True)
    simulate.add_argument("--output", type=Path, required=True)
    simulate.add_argument("--replace", action="store_true")

    validate_bundle = subcommands.add_parser(
        "validate-bundle", help="Validate manifest, hashes, records, IDs, sequence, and timestamps"
    )
    validate_bundle.add_argument("bundle", type=Path)

    replay = subcommands.add_parser("replay", help="Replay a validated capture bundle")
    replay.add_argument("bundle", type=Path)
    replay.add_argument("--output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "contracts":
            return _contracts(args)
        if args.command == "simulate":
            capture = generate_cold_start_idle()
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
