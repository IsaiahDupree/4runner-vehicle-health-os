#!/usr/bin/env python3
"""One-command VHOS communication acceptance before a vehicle trip.

The suite combines deterministic contract/replay/build gates with physical
iPhone/ESP32 fault injection. It never synthesizes vehicle observations and
never reports USB-bench success as vehicle-CAN acceptance.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time


@dataclass(frozen=True)
class PhysicalPhase:
    name: str
    cycles: int
    faults: str
    health_frames: int
    timeout_seconds: int
    dwell_seconds: int


PROFILES: dict[str, tuple[PhysicalPhase, ...]] = {
    "quick": (
        PhysicalPhase("health-smoke", 0, "esp-reset", 10, 75, 0),
        PhysicalPhase("mixed-recovery", 2, "esp-reset,app-relaunch", 5, 55, 2),
    ),
    "standard": (
        PhysicalPhase("health-soak", 0, "esp-reset", 30, 120, 0),
        PhysicalPhase("reset-storm", 3, "esp-reset", 5, 55, 2),
        PhysicalPhase("app-death-storm", 3, "app-relaunch", 5, 55, 2),
        PhysicalPhase("mixed-recovery", 6, "esp-reset,app-relaunch", 5, 55, 2),
    ),
    "endurance": (
        PhysicalPhase("health-soak", 0, "esp-reset", 300, 900, 0),
        PhysicalPhase("reset-storm", 10, "esp-reset", 10, 75, 3),
        PhysicalPhase("app-death-storm", 10, "app-relaunch", 10, 75, 3),
        PhysicalPhase("mixed-recovery", 20, "esp-reset,app-relaunch", 10, 75, 3),
    ),
}


def utc_stamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def detect_firmware_version(firmware_repo: Path) -> str:
    cmake = firmware_repo / "targets/mrdiy-esp32-v13/CMakeLists.txt"
    if not cmake.is_file():
        raise FileNotFoundError(f"firmware version source not found: {cmake}")
    match = re.search(r'set\(PROJECT_VER\s+"([^"]+)"\)', cmake.read_text())
    if match is None:
        raise RuntimeError(f"PROJECT_VER was not found in {cmake}")
    return match.group(1)


class AcceptanceRun:
    def __init__(self, output: Path, profile: str, expected_firmware: str) -> None:
        self.output = output
        self.summary_path = output / "summary.json"
        self.summary: dict[str, object] = {
            "schema_version": 1,
            "run_id": output.name,
            "started_at": utc_stamp(),
            "completed_at": None,
            "profile": profile,
            "expected_firmware": expected_firmware,
            "outcome": "RUNNING",
            "failure": None,
            "gates": [],
            "limitations": [
                "USB-bench success does not establish vehicle CAN traffic or OBD compatibility.",
                "A CP2102 UART attach may reset the target; each physical phase records that boundary before evaluating post-boot recovery.",
                "RTS reset removes firmware execution but is not electrical rail removal.",
                "True power testing requires an explicitly selected switchable USB hub or relay.",
            ],
        }
        self.write_summary()

    def write_summary(self) -> None:
        self.summary_path.write_text(
            json.dumps(self.summary, indent=2) + "\n", encoding="utf-8"
        )

    def run_command(
        self,
        name: str,
        command: list[str],
        cwd: Path,
        *,
        timeout: float | None = None,
    ) -> None:
        log_path = self.output / f"{len(self.summary['gates']):02d}-{name}.log"
        started = time.monotonic()
        print(f"\n==> {name}\n    {shlex.join(command)}", flush=True)
        with log_path.open("w", encoding="utf-8", buffering=1) as log:
            log.write(f"started_at={utc_stamp()}\n")
            log.write(f"cwd={cwd}\n")
            log.write(f"command={shlex.join(command)}\n\n")
            try:
                process = subprocess.run(
                    command,
                    cwd=cwd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=timeout,
                )
                log.write(process.stdout)
                print(process.stdout, end="", flush=True)
                if process.returncode != 0:
                    raise RuntimeError(f"{name} exited {process.returncode}")
            except subprocess.TimeoutExpired as error:
                captured = error.stdout or ""
                if isinstance(captured, bytes):
                    captured = captured.decode(errors="replace")
                log.write(captured)
                print(captured, end="", flush=True)
                raise TimeoutError(f"{name} exceeded {timeout:.0f}s") from error
            except Exception:
                gate = {
                    "name": name,
                    "result": "FAIL",
                    "elapsed_seconds": round(time.monotonic() - started, 3),
                    "log": str(log_path.relative_to(self.output)),
                }
                self.summary["gates"].append(gate)
                self.write_summary()
                raise
        gate = {
            "name": name,
            "result": "PASS",
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "log": str(log_path.relative_to(self.output)),
        }
        self.summary["gates"].append(gate)
        self.write_summary()

    def add_physical_result(self, phase: PhysicalPhase, summary_path: Path) -> None:
        phase_summary = json.loads(summary_path.read_text(encoding="utf-8"))
        if phase_summary.get("outcome") != "PASS":
            raise RuntimeError(
                f"physical phase {phase.name} did not pass: "
                f"{phase_summary.get('failure')}"
            )
        if phase_summary.get("expected_firmware") != self.summary["expected_firmware"]:
            raise RuntimeError(f"physical phase {phase.name} used the wrong firmware oracle")
        self.summary["gates"].append(
            {
                "name": f"physical-{phase.name}",
                "result": "PASS",
                "phase": asdict(phase),
                "evidence": str(summary_path.parent.relative_to(self.output)),
                "results": phase_summary.get("results", []),
            }
        )
        self.write_summary()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run deterministic and real-device VHOS pre-car communication gates."
    )
    parser.add_argument("--profile", choices=PROFILES, default="standard")
    parser.add_argument("--iphone", help="CoreDevice identifier or iPhone UDID")
    parser.add_argument("--serial", default="/dev/cu.usbserial-0001")
    parser.add_argument("--expected-firmware")
    parser.add_argument(
        "--minimum-rssi",
        type=int,
        default=-80,
        help="Required connected-link RSSI floor for every physical cycle (default: -80 dBm)",
    )
    parser.add_argument("--firmware-repo", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--skip-software", action="store_true")
    parser.add_argument("--skip-builds", action="store_true")
    parser.add_argument("--skip-install", action="store_true")
    parser.add_argument("--skip-physical", action="store_true")
    parser.add_argument("--include-power", action="store_true")
    parser.add_argument("--usb-hub")
    parser.add_argument("--usb-port")
    parser.add_argument("--power-off-seconds", type=float, default=5.0)
    args = parser.parse_args()
    if not args.skip_physical and not args.iphone:
        parser.error("--iphone is required unless --skip-physical is used")
    if not args.skip_install and not args.skip_builds and not args.iphone:
        parser.error("--iphone is required for signed-build installation")
    if args.include_power and (not args.usb_hub or not args.usb_port):
        parser.error("--include-power requires --usb-hub and --usb-port")
    if not -127 <= args.minimum_rssi <= 0:
        parser.error("--minimum-rssi must be between -127 and 0 dBm")
    return args


def require_program(program: str) -> None:
    if shutil.which(program) is None:
        raise RuntimeError(f"required program is unavailable: {program}")


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parents[2]
    firmware_repo = (args.firmware_repo or repo.parent / "4runner-vhos-firmware").resolve()
    expected_firmware = args.expected_firmware or detect_firmware_version(firmware_repo)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    output = (args.output or repo / "build/precar-acceptance" / run_id).resolve()
    output.mkdir(parents=True, exist_ok=False)
    run = AcceptanceRun(output, args.profile, expected_firmware)
    run.summary.update(
        {
            "product_repo": str(repo),
            "firmware_repo": str(firmware_repo),
            "iphone": args.iphone,
            "serial": args.serial,
            "minimum_link_rssi_dbm": args.minimum_rssi,
            "software_gates_skipped": args.skip_software,
            "build_gates_skipped": args.skip_builds,
            "physical_gates_skipped": args.skip_physical,
        }
    )
    run.write_summary()

    try:
        for program in ("python3", "swift", "uv", "xcrun"):
            require_program(program)
        if not args.skip_builds:
            require_program("docker")
            require_program("xcodebuild")
            require_program("codesign")
        if not args.skip_physical and not Path(args.serial).exists():
            raise FileNotFoundError(f"ESP32 UART is not present: {args.serial}")

        venv_python = repo / ".venv/bin/python"
        vhos = repo / ".venv/bin/vhos"
        if not args.skip_software:
            if not venv_python.is_file() or not vhos.is_file():
                raise RuntimeError(
                    "repository .venv is missing; run: python3 -m venv .venv && "
                    ".venv/bin/python -m pip install -e './tooling[test]'"
                )
            capture = output / "software/cold-start-idle"
            run.run_command("contracts", [str(vhos), "contracts", "check"], repo)
            run.run_command("python-tests", [str(venv_python), "-m", "pytest"], repo)
            run.run_command(
                "capture-simulate",
                [str(vhos), "simulate", "--scenario", "cold-start-idle", "--output", str(capture)],
                repo,
            )
            run.run_command("capture-validate", [str(vhos), "validate-bundle", str(capture)], repo)
            run.run_command("capture-replay", [str(vhos), "replay", str(capture)], repo)
            run.run_command("swift-tests", ["swift", "test", "--package-path", "ios/Core"], repo)
            run.run_command(
                "harness-syntax",
                [
                    "python3",
                    "-m",
                    "py_compile",
                    "ios/tools/vhos_ble_fault_injection.py",
                    "ios/tools/vhos_precar_acceptance.py",
                ],
                repo,
            )

        app_path: Path | None = None
        if not args.skip_builds:
            firmware_target = firmware_repo / "targets/mrdiy-esp32-v13"
            run.run_command(
                "firmware-build",
                [
                    "docker",
                    "run",
                    "--rm",
                    "-v",
                    f"{firmware_repo}:/project",
                    "-w",
                    "/project/targets/mrdiy-esp32-v13",
                    "espressif/idf:v5.5.3",
                    "bash",
                    "-lc",
                    "idf.py build",
                ],
                firmware_target,
                timeout=900,
            )
            firmware_bin = firmware_target / "build/vhos_mrdiy_esp32_v13.bin"
            if not firmware_bin.is_file():
                raise FileNotFoundError(f"firmware build did not produce {firmware_bin}")
            binary = firmware_bin.read_bytes()
            if expected_firmware.encode() not in binary:
                raise RuntimeError(
                    f"firmware artifact does not embed expected version {expected_firmware}"
                )
            run.summary["firmware_artifact"] = {
                "path": str(firmware_bin),
                "bytes": firmware_bin.stat().st_size,
                "sha256": sha256(firmware_bin),
            }
            run.write_summary()

            derived = output / "xcode"
            run.run_command(
                "signed-ios-build",
                [
                    "xcodebuild",
                    "-project",
                    "ios/VehicleHealthOS.xcodeproj",
                    "-scheme",
                    "VehicleHealthOS",
                    "-configuration",
                    "Debug",
                    "-sdk",
                    "iphoneos",
                    "-destination",
                    "generic/platform=iOS",
                    "-derivedDataPath",
                    str(derived),
                    "build",
                ],
                repo,
                timeout=900,
            )
            app_path = derived / "Build/Products/Debug-iphoneos/Vehicle Health OS.app"
            run.run_command(
                "codesign-verify",
                ["codesign", "--verify", "--deep", "--strict", str(app_path)],
                repo,
            )
            if not args.skip_install:
                run.run_command(
                    "iphone-install",
                    [
                        "xcrun",
                        "devicectl",
                        "device",
                        "install",
                        "app",
                        "--device",
                        args.iphone,
                        str(app_path),
                    ],
                    repo,
                    timeout=180,
                )

        if not args.skip_physical:
            phases = list(PROFILES[args.profile])
            if args.include_power:
                power_cycles = {"quick": 1, "standard": 3, "endurance": 10}[args.profile]
                phases.append(
                    PhysicalPhase(
                        "true-power-loss",
                        power_cycles,
                        "power-cycle",
                        5 if args.profile != "endurance" else 10,
                        90,
                        3,
                    )
                )
            for phase in phases:
                phase_output = output / "physical" / phase.name
                command = [
                    "uv",
                    "run",
                    "--script",
                    "ios/tools/vhos_ble_fault_injection.py",
                    "--iphone",
                    args.iphone,
                    "--serial",
                    args.serial,
                    "--cycles",
                    str(phase.cycles),
                    "--faults",
                    phase.faults,
                    "--timeout",
                    str(phase.timeout_seconds),
                    "--dwell",
                    str(phase.dwell_seconds),
                    "--health-frames",
                    str(phase.health_frames),
                    "--expected-firmware",
                    expected_firmware,
                    "--minimum-rssi",
                    str(args.minimum_rssi),
                    "--output",
                    str(phase_output),
                ]
                if phase.name == "true-power-loss":
                    command.extend(
                        [
                            "--usb-hub",
                            args.usb_hub,
                            "--usb-port",
                            args.usb_port,
                            "--power-off-seconds",
                            str(args.power_off_seconds),
                        ]
                    )
                run.run_command(
                    f"physical-{phase.name}",
                    command,
                    repo,
                    timeout=(phase.cycles + 1) * (phase.timeout_seconds + phase.dwell_seconds + 10),
                )
                # Replace the generic command gate with the richer physical result.
                run.summary["gates"].pop()
                run.add_physical_result(phase, phase_output / "summary.json")

        run.summary["outcome"] = "PASS"
    except Exception as error:
        run.summary["outcome"] = "FAIL"
        run.summary["failure"] = str(error)
        print(f"\nPRE-CAR ACCEPTANCE FAILED: {error}", file=sys.stderr, flush=True)
    finally:
        run.summary["completed_at"] = utc_stamp()
        run.write_summary()
        print(f"\nEvidence summary: {run.summary_path}", flush=True)
    return 0 if run.summary["outcome"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
