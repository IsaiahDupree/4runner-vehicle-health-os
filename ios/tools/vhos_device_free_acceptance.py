#!/usr/bin/env python3
"""Run the complete VHOS field-return acceptance suite without real devices.

This runner deliberately stops at the desktop boundary.  It analyzes a copied
iPhone app-data tree, runs the shared and platform build/test gates, and leaves
every physical acceptance requirement explicit in its durable summary.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from typing import Iterable


DEFAULT_JAVA_HOME = Path(
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
)
DEFAULT_ANDROID_SDK = Path.home() / "Library/Android/sdk"
DEFAULT_IOS_DESTINATION = "platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest"

REMAINING_PHYSICAL_GATES: tuple[dict[str, str], ...] = (
    {
        "id": "PHYSICAL-IOS-BLE-SOAK",
        "status": "NOT_RUN",
        "requirement": (
            "Sustain and recover the iPhone-to-ESP32 BLE application contract "
            "under real radio interference and retained-history transfer load."
        ),
    },
    {
        "id": "PHYSICAL-ANDROID-DUAL-GATT",
        "status": "NOT_RUN",
        "requirement": (
            "Verify the installed Android head unit can maintain the OBD/CAN and "
            "A/C GATT links concurrently on its vendor Bluetooth stack."
        ),
    },
    {
        "id": "PHYSICAL-ANDROID-SQLCIPHER-INSTRUMENTATION",
        "status": "NOT_RUN",
        "requirement": (
            "Run installed-head-unit instrumentation against the real SQLCipher "
            "database, keystore, restart, export, and append-only recovery path."
        ),
    },
    {
        "id": "PHYSICAL-VEHICLE-BUS",
        "status": "NOT_RUN",
        "requirement": (
            "Verify DLC power, listen-only CAN traffic, OBD protocol/ECU response, "
            "and gateway counters on the target vehicle."
        ),
    },
    {
        "id": "PHYSICAL-POWER-RECOVERY",
        "status": "NOT_RUN",
        "requirement": (
            "Exercise ignition loss, true ESP32 rail loss, brownout, reboot, and "
            "probationary OTA/rollback recovery."
        ),
    },
    {
        "id": "PHYSICAL-SIGNAL-GROUND-TRUTH",
        "status": "NOT_RUN",
        "requirement": (
            "Corroborate candidate mappings with repeated labeled captures and an "
            "independent OBD, Techstream, or manual measurement source before promotion."
        ),
    },
    {
        "id": "PHYSICAL-J1979-TECHSTREAM-REFERENCE",
        "status": "NOT_RUN",
        "requirement": (
            "Acquire supported J1979 PID enumeration and synchronized Techstream or "
            "equivalent reference values on the target vehicle timeline."
        ),
    },
    {
        "id": "PHYSICAL-IN-VEHICLE-UX",
        "status": "NOT_RUN",
        "requirement": (
            "Validate parked-only controls, readability, touch targets, playback, "
            "and recovery behavior on the installed phone/head-unit displays."
        ),
    },
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_regular_file_under_root(
    candidate: Path,
    *,
    expected_root: Path,
    label: str,
) -> tuple[Path, Path]:
    """Resolve one regular file without permitting a symlink or root escape."""

    root_absolute = Path(os.path.abspath(expected_root))
    if root_absolute.is_symlink():
        raise FileNotFoundError(f"{label} root must not be a symbolic link: {root_absolute}")
    root = root_absolute.resolve(strict=True)
    if not root.is_dir():
        raise FileNotFoundError(f"{label} root is unavailable: {root}")
    candidate_absolute = Path(os.path.abspath(candidate))
    try:
        relative = candidate_absolute.relative_to(root_absolute)
    except ValueError as error:
        raise FileNotFoundError(
            f"{label} escapes expected root {root}: {candidate_absolute}"
        ) from error
    component = root_absolute
    for part in relative.parts:
        component /= part
        if component.is_symlink():
            raise FileNotFoundError(
                f"{label} path must not contain a symbolic link: {component}"
            )
    path = candidate_absolute.resolve(strict=True)
    if not path.is_relative_to(root):
        raise FileNotFoundError(
            f"{label} resolves outside expected root {root}: {path}"
        )
    if not path.is_file():
        raise FileNotFoundError(f"{label} is unavailable: {path}")
    return path, root


def atomic_write_json(path: Path, value: object) -> None:
    """Replace one JSON file atomically; an interrupted write cannot look passed."""

    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


@dataclass(frozen=True)
class GateSpec:
    name: str
    command: tuple[str, ...]
    cwd: Path
    timeout_seconds: int
    environment: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class AcceptanceConfig:
    repo: Path
    app_data: Path
    baseline: Path | None
    output: Path
    android_repo: Path
    soak_cycles: int
    ios_destination: str
    java_home: Path
    android_sdk: Path


class GateFailure(RuntimeError):
    """A required acceptance command failed or exceeded its time budget."""


class DeviceFreeAcceptanceRun:
    """Fail-closed command orchestrator with atomic incremental evidence."""

    def __init__(self, output: Path, inputs: dict[str, object]) -> None:
        output.mkdir(parents=True, exist_ok=False)
        self.output = output
        self.summary_path = output / "summary.json"
        self._terminal = False
        self.summary: dict[str, object] = {
            "schema_version": 1,
            "kind": "vhos.device-free-field-return-acceptance",
            "run_id": output.name,
            "started_at": utc_now(),
            "completed_at": None,
            "outcome": "RUNNING",
            "device_free": True,
            "physical_or_vehicle_calls_permitted": False,
            "device_free_gates_passed": False,
            "offline_passed_gates": [],
            "release_ready": False,
            "inputs": inputs,
            "gates": [],
            "artifacts": [],
            "remaining_physical_gates": [
                dict(item) for item in REMAINING_PHYSICAL_GATES
            ],
            "failure": None,
        }
        self._write()

    def _write(self) -> None:
        atomic_write_json(self.summary_path, self.summary)

    def run_gate(self, gate: GateSpec) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")

        gates = self.summary["gates"]
        assert isinstance(gates, list)
        log_path = self.output / f"{len(gates):02d}-{gate.name}.log"
        started_at = utc_now()
        started_epoch_seconds = time.time()
        started = time.monotonic()
        record: dict[str, object] = {
            "index": len(gates),
            "name": gate.name,
            "result": "RUNNING",
            "started_at": started_at,
            "started_epoch_seconds": started_epoch_seconds,
            "completed_at": None,
            "duration_seconds": None,
            "command": list(gate.command),
            "command_display": shlex.join(gate.command),
            "cwd": str(gate.cwd),
            "timeout_seconds": gate.timeout_seconds,
            "environment": dict(sorted(gate.environment.items())),
            "returncode": None,
            "log": {"path": log_path.name, "bytes": 0, "sha256": None},
        }
        gates.append(record)
        self._write()

        environment = os.environ.copy()
        environment.update(gate.environment)
        process: subprocess.Popen[str] | None = None
        failure: str | None = None
        returncode: int | None = None
        with log_path.open("x", encoding="utf-8", buffering=1) as log:
            log.write(f"started_at={started_at}\n")
            log.write(f"cwd={gate.cwd}\n")
            log.write(f"command={shlex.join(gate.command)}\n")
            for key, value in sorted(gate.environment.items()):
                log.write(f"environment.{key}={value}\n")
            log.write("\n")
            try:
                process = subprocess.Popen(
                    gate.command,
                    cwd=gate.cwd,
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    text=True,
                    start_new_session=True,
                )
                returncode = process.wait(timeout=gate.timeout_seconds)
                if returncode != 0:
                    failure = f"{gate.name} exited {returncode}"
            except subprocess.TimeoutExpired:
                failure = f"{gate.name} exceeded {gate.timeout_seconds}s"
                if process is not None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                    returncode = process.returncode
            except Exception as error:  # command-not-found and OS failures
                failure = f"{gate.name} could not run: {error}"

        completed_at = utc_now()
        record.update(
            {
                "result": "FAIL" if failure else "PASS",
                "completed_at": completed_at,
                "duration_seconds": round(time.monotonic() - started, 3),
                "returncode": returncode,
                "log": {
                    "path": log_path.name,
                    "bytes": log_path.stat().st_size,
                    "sha256": sha256_file(log_path),
                },
            }
        )
        if failure:
            self.summary["outcome"] = "FAIL"
            self.summary["failure"] = {
                "gate": gate.name,
                "message": failure,
            }
            self.summary["completed_at"] = completed_at
            self._terminal = True
        self._write()
        if failure:
            raise GateFailure(failure)

    def add_artifacts(
        self,
        paths: Iterable[Path],
        *,
        kind: str,
        expected_root: Path,
    ) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")
        artifacts = self.summary["artifacts"]
        assert isinstance(artifacts, list)
        candidates = sorted(
            {Path(os.path.abspath(candidate)) for candidate in paths}
        )
        for candidate in candidates:
            path, root = resolve_regular_file_under_root(
                candidate,
                expected_root=expected_root,
                label=f"required {kind} artifact",
            )
            artifacts.append(
                {
                    "kind": kind,
                    "path": str(path),
                    "expected_root": str(root),
                    "bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
        self._write()

    def annotate_gate(self, name: str, **metrics: object) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")
        gates = self.summary["gates"]
        assert isinstance(gates, list)
        matches = [gate for gate in gates if gate.get("name") == name]
        if len(matches) != 1 or matches[0].get("result") != "PASS":
            raise GateFailure(f"cannot annotate unavailable passing gate: {name}")
        matches[0]["metrics"] = metrics
        self._write()

    def add_evidence_chain(self, proof: dict[str, object]) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")
        self.summary["field_return_evidence_chain"] = proof
        self._write()

    def set_source_snapshots(
        self,
        before: dict[str, object],
        *,
        after: dict[str, object] | None = None,
    ) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")
        self.summary["source_snapshots"] = {
            "before": before,
            "after": after,
            "unchanged": after == before if after is not None else None,
        }
        self._write()

    def set_environment_provenance(self, provenance: dict[str, object]) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")
        self.summary["environment_provenance"] = provenance
        self._write()

    def succeed(self, required_gate_names: Iterable[str]) -> None:
        if self._terminal:
            raise RuntimeError("acceptance run is already terminal")
        required = tuple(required_gate_names)
        gates = self.summary["gates"]
        assert isinstance(gates, list)
        by_name = {str(gate["name"]): gate for gate in gates}
        missing = [name for name in required if name not in by_name]
        failed = [
            name
            for name in required
            if name in by_name and by_name[name].get("result") != "PASS"
        ]
        if missing or failed:
            self.fail(
                "required desktop gates are incomplete",
                details={"missing": missing, "not_passed": failed},
            )
            raise GateFailure("required desktop gates are incomplete")
        self.summary.update(
            {
                "outcome": "PASS_DEVICE_FREE",
                "device_free_gates_passed": True,
                "offline_passed_gates": list(required),
                "release_ready": False,
                "completed_at": utc_now(),
            }
        )
        self._terminal = True
        self._write()

    def fail(self, message: str, *, details: object | None = None) -> None:
        if self._terminal and self.summary["outcome"] == "FAIL":
            return
        self.summary.update(
            {
                "outcome": "FAIL",
                "device_free_gates_passed": False,
                "release_ready": False,
                "completed_at": utc_now(),
                "failure": {"message": message, "details": details},
            }
        )
        self._terminal = True
        self._write()


def build_gate_specs(config: AcceptanceConfig) -> tuple[GateSpec, ...]:
    vhos = config.repo / ".venv/bin/vhos"
    python = config.repo / ".venv/bin/python"
    analysis = config.output / "evidence"
    derived_data = config.output / "ios-derived"
    field_return_command = [
        str(vhos),
        "analyze-field-return",
        str(config.app_data),
    ]
    if config.baseline is not None:
        field_return_command.extend(["--baseline", str(config.baseline)])
    field_return_command.extend(
        [
            "--output",
            str(analysis),
            "--soak-cycles",
            str(config.soak_cycles),
        ]
    )
    android_environment = {
        "JAVA_HOME": str(config.java_home),
        "ANDROID_SDK_ROOT": str(config.android_sdk),
        "ANDROID_HOME": str(config.android_sdk),
    }
    return (
        GateSpec("contracts", (str(vhos), "contracts", "check"), config.repo, 180),
        GateSpec("python-tests", (str(python), "-m", "pytest"), config.repo, 900),
        GateSpec(
            "field-return-analysis",
            tuple(field_return_command),
            config.repo,
            1800,
        ),
        GateSpec(
            "swift-core-tests",
            ("swift", "test", "--package-path", "ios/Core"),
            config.repo,
            900,
        ),
        GateSpec(
            "ios-simulator-tests",
            (
                "xcodebuild",
                "-project",
                "ios/VehicleHealthOS.xcodeproj",
                "-scheme",
                "VehicleHealthOS",
                "-configuration",
                "Debug",
                "-sdk",
                "iphonesimulator",
                "-destination",
                config.ios_destination,
                "-derivedDataPath",
                str(derived_data),
                "CODE_SIGNING_ALLOWED=NO",
                "test",
            ),
            config.repo,
            1200,
        ),
        GateSpec(
            "ios-simulator-build",
            (
                "xcodebuild",
                "-project",
                "ios/VehicleHealthOS.xcodeproj",
                "-scheme",
                "VehicleHealthOS",
                "-configuration",
                "Debug",
                "-sdk",
                "iphonesimulator",
                "-destination",
                "generic/platform=iOS Simulator",
                "-derivedDataPath",
                str(derived_data),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ),
            config.repo,
            1200,
        ),
        GateSpec(
            "android-tests-lint-build",
            ("./gradlew", "test", "lint", "assembleDebug", "--rerun-tasks"),
            config.android_repo,
            1800,
            android_environment,
        ),
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run copied-iPhone analysis plus iOS/Android desktop acceptance without "
            "contacting a phone, ESP32, head unit, or vehicle."
        )
    )
    parser.add_argument("--app-data", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--android-repo", type=Path)
    parser.add_argument("--soak-cycles", type=int, default=20)
    parser.add_argument(
        "--ios-destination",
        default=os.environ.get(
            "VHOS_IOS_SIMULATOR_DESTINATION", DEFAULT_IOS_DESTINATION
        ),
        help="Concrete iOS Simulator xcodebuild destination (never a physical device)",
    )
    return parser.parse_args(argv)


def resolve_config(args: argparse.Namespace) -> AcceptanceConfig:
    repo = Path(__file__).resolve().parents[2]
    return AcceptanceConfig(
        repo=repo,
        app_data=args.app_data.expanduser().resolve(),
        baseline=args.baseline.expanduser().resolve() if args.baseline else None,
        output=args.output.expanduser().resolve(),
        android_repo=(args.android_repo or repo.parent / "4runner-vhos-android")
        .expanduser()
        .resolve(),
        soak_cycles=args.soak_cycles,
        ios_destination=args.ios_destination,
        java_home=Path(os.environ.get("JAVA_HOME", DEFAULT_JAVA_HOME)).resolve(),
        android_sdk=Path(
            os.environ.get(
                "ANDROID_SDK_ROOT",
                os.environ.get("ANDROID_HOME", DEFAULT_ANDROID_SDK),
            )
        ).resolve(),
    )


def validate_source_arguments(args: argparse.Namespace) -> None:
    """Preserve field-return's top-level no-symlink source boundary."""

    for label, value in (("app-data", args.app_data), ("baseline", args.baseline)):
        if value is not None and value.expanduser().is_symlink():
            raise ValueError(f"--{label} must not be a symbolic link: {value}")


def _android_compile_target(android_repo: Path, android_sdk: Path) -> str:
    compile_sdks: set[int] = set()
    compile_sdk_minors: set[int] = set()
    for gradle_file in android_repo.glob("**/build.gradle.kts"):
        text = gradle_file.read_text()
        compile_sdks.update(
            int(match)
            for match in re.findall(
                r"\bcompileSdk\s*=\s*(\d+)", text
            )
        )
        compile_sdk_minors.update(
            int(match)
            for match in re.findall(r"\bcompileSdkMinor\s*=\s*(\d+)", text)
        )
    if len(compile_sdks) != 1:
        raise ValueError(
            "Android repository must declare exactly one numeric compileSdk; "
            f"found {sorted(compile_sdks)}"
        )
    if len(compile_sdk_minors) > 1:
        raise ValueError(
            "Android repository must declare at most one numeric compileSdkMinor; "
            f"found {sorted(compile_sdk_minors)}"
        )
    compile_sdk = next(iter(compile_sdks))
    if compile_sdk_minors:
        return f"android-{compile_sdk}.{next(iter(compile_sdk_minors))}"
    dotted_base = android_sdk / "platforms" / f"android-{compile_sdk}.0"
    if dotted_base.is_dir():
        return dotted_base.name
    return f"android-{compile_sdk}"


def _android_local_properties_sdk(android_repo: Path) -> Path | None:
    """Read Gradle's higher-priority sdk.dir without trusting an ignored file."""

    properties = android_repo / "local.properties"
    if not properties.exists():
        return None
    if properties.is_symlink() or not properties.is_file():
        raise ValueError(
            f"Android local.properties must be a regular non-symlink file: {properties}"
        )
    values: list[str] = []
    for raw_line in properties.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", "!")):
            continue
        match = re.match(r"sdk\.dir\s*[:=]\s*(.*)$", line)
        if match is None:
            continue
        value = re.sub(r"\\([\\ :=#!])", r"\1", match.group(1).strip())
        if not value:
            raise ValueError(f"Android local.properties has an empty sdk.dir: {properties}")
        values.append(value)
    if len(values) > 1:
        raise ValueError(
            "Android local.properties must contain at most one sdk.dir; "
            f"found {len(values)} in {properties}"
        )
    if not values:
        return None
    path = Path(values[0]).expanduser()
    if not path.is_absolute():
        path = android_repo / path
    return path.resolve()


def android_sdk_provenance(config: AcceptanceConfig) -> dict[str, object]:
    """Prove the SDK Gradle can select is the SDK the runner attests."""

    configured_sdk = config.android_sdk.resolve()
    local_properties = config.android_repo / "local.properties"
    local_sdk = _android_local_properties_sdk(config.android_repo)
    if local_sdk is not None and local_sdk != configured_sdk:
        raise ValueError(
            "Android SDK selection conflict: local.properties sdk.dir resolves to "
            f"{local_sdk}, but ANDROID_SDK_ROOT resolves to {configured_sdk}"
        )
    compile_target = _android_compile_target(config.android_repo, configured_sdk)
    platform = configured_sdk / "platforms" / compile_target
    platform_jar, _ = resolve_regular_file_under_root(
        platform / "android.jar",
        expected_root=configured_sdk,
        label=f"Android SDK {compile_target} android.jar",
    )
    source_properties = platform / "source.properties"
    package_revision = None
    if source_properties.is_file() and not source_properties.is_symlink():
        revision = re.search(
            r"^Pkg\.Revision\s*=\s*(.+)$",
            source_properties.read_text(encoding="utf-8"),
            flags=re.MULTILINE,
        )
        package_revision = revision.group(1).strip() if revision else None
    return {
        "selection": (
            "environment-and-local.properties-agree"
            if local_sdk is not None
            else "environment"
        ),
        "configured_sdk": str(configured_sdk),
        "local_properties": str(local_properties) if local_properties.exists() else None,
        "local_properties_sdk": str(local_sdk) if local_sdk is not None else None,
        "compile_sdk": int(compile_target.removeprefix("android-").split(".")[0]),
        "compile_target": compile_target,
        "platform": str(platform),
        "platform_package_revision": package_revision,
        "android_jar": {
            "path": str(platform_jar),
            "bytes": platform_jar.stat().st_size,
            "sha256": sha256_file(platform_jar),
        },
    }


def validate_config(config: AcceptanceConfig) -> dict[str, object]:
    if config.soak_cycles < 1:
        raise ValueError("--soak-cycles must be at least 1")
    for label, directory in (
        ("app-data", config.app_data),
        ("Android repository", config.android_repo),
    ):
        if not directory.is_dir():
            raise FileNotFoundError(f"{label} directory is unavailable: {directory}")
    if config.baseline is not None and not config.baseline.is_dir():
        raise FileNotFoundError(f"baseline directory is unavailable: {config.baseline}")
    destination_fields = {}
    for component in config.ios_destination.split(","):
        key, separator, value = component.partition("=")
        if separator:
            destination_fields[key.strip().casefold()] = value.strip().casefold()
    if destination_fields.get("platform") != "ios simulator":
        raise ValueError("--ios-destination must explicitly use platform=iOS Simulator")
    required_files = (
        config.repo / ".venv/bin/vhos",
        config.repo / ".venv/bin/python",
        config.android_repo / "gradlew",
        config.java_home / "bin/java",
    )
    for path in required_files:
        if not path.is_file():
            raise FileNotFoundError(
                f"required acceptance dependency is unavailable: {path}"
            )
    java_release = config.java_home / "release"
    if not java_release.is_file():
        raise FileNotFoundError(f"JDK release metadata is unavailable: {java_release}")
    java_version = re.search(
        r'^JAVA_VERSION="([^"]+)"',
        java_release.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    if java_version is None or java_version.group(1).split(".", 1)[0] != "17":
        raise ValueError(f"JAVA_HOME must select JDK 17: {config.java_home}")
    for program in ("swift", "xcodebuild"):
        if shutil.which(program) is None:
            raise FileNotFoundError(
                f"required acceptance program is unavailable: {program}"
            )
    return android_sdk_provenance(config)


def validate_output_location(config: AcceptanceConfig) -> None:
    """Reject an output that could mutate either copied evidence source."""

    for label, source in (
        ("app-data", config.app_data),
        ("baseline", config.baseline),
    ):
        if source is not None and config.output.is_relative_to(source):
            raise ValueError(
                f"--output must not equal or be nested inside {label}: {source}"
            )


def git_source_snapshot(
    repo: Path, *, exclude: Iterable[Path] = ()
) -> dict[str, object]:
    """Hash every tracked/untracked, non-ignored source path and Git state."""

    exclusions = tuple(path.resolve() for path in exclude)

    def git(*arguments: str) -> bytes:
        result = subprocess.run(
            ("git", *arguments),
            cwd=repo,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result.stdout

    head = git("rev-parse", "HEAD").decode("ascii").strip()
    listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    relative_paths = sorted(
        {Path(raw.decode("utf-8")) for raw in listed.split(b"\0") if raw}
    )
    digest = hashlib.sha256()
    included = 0
    for relative_path in relative_paths:
        path = (repo / relative_path).absolute()
        resolved = path.resolve(strict=False)
        if any(
            resolved == root or resolved.is_relative_to(root) for root in exclusions
        ):
            continue
        included += 1
        digest.update(relative_path.as_posix().encode("utf-8"))
        digest.update(b"\0")
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            digest.update(b"MISSING\0")
            continue
        digest.update(f"{stat.S_IMODE(metadata.st_mode):o}".encode("ascii"))
        digest.update(b"\0")
        if stat.S_ISLNK(metadata.st_mode):
            digest.update(b"SYMLINK\0")
            digest.update(os.readlink(path).encode("utf-8"))
        elif stat.S_ISREG(metadata.st_mode):
            digest.update(b"FILE\0")
            digest.update(str(metadata.st_size).encode("ascii"))
            digest.update(b"\0")
            digest.update(sha256_file(path).encode("ascii"))
        elif stat.S_ISDIR(metadata.st_mode):
            digest.update(b"GITLINK\0")
        else:
            digest.update(b"OTHER\0")
        digest.update(b"\0")
    return {
        "repo": str(repo),
        "git_commit": head,
        "tracked_and_untracked_source_files": included,
        "source_tree_sha256": digest.hexdigest(),
    }


def capture_source_snapshots(config: AcceptanceConfig) -> dict[str, object]:
    return {
        "product": git_source_snapshot(config.repo, exclude=(config.output,)),
        "android": git_source_snapshot(config.android_repo),
        "android_sdk": android_sdk_provenance(config),
    }


def collect_required_artifacts(
    config: AcceptanceConfig,
) -> tuple[tuple[str, Path, tuple[Path, ...]], ...]:
    evidence = config.output / "evidence"
    evidence_manifest = evidence / "manifest.json"
    evidence_summary = evidence / "SUMMARY.md"
    manifest = json.loads(evidence_manifest.read_text(encoding="utf-8"))
    if manifest.get("status") != "PASS":
        raise GateFailure("field-return manifest is not PASS")
    if manifest.get("vehicle_claims_authorized") is not False:
        raise GateFailure("field-return manifest widened vehicle authority")

    ios_products = tuple(
        sorted(
            (config.output / "ios-derived/Build/Products").glob(
                "Debug-iphonesimulator/*.app/Vehicle Health OS"
            )
        )
    )
    android_apks = tuple(
        sorted(config.android_repo.glob("app/build/outputs/apk/debug/*.apk"))
    )
    if not ios_products:
        raise FileNotFoundError("iOS Simulator build product was not produced")
    if not android_apks:
        raise FileNotFoundError("Android debug APK was not produced")
    return (
        (
            "field-return-evidence",
            evidence,
            (
                evidence_manifest,
                evidence_summary,
                evidence / "full/replay-corpus/manifest.json",
                evidence / "full/replay.json",
                evidence / "full/link-reliability.json",
            ),
        ),
        ("ios-simulator-app", config.output, ios_products),
        ("android-debug-apk", config.android_repo, android_apks),
    )


def prove_field_return_evidence_chain(config: AcceptanceConfig) -> dict[str, object]:
    """Prove replay and impairment tests consumed one exact recovered corpus."""

    evidence = config.output / "evidence"
    analysis = json.loads((evidence / "manifest.json").read_text(encoding="utf-8"))
    scope = analysis["analysis_scopes"]["full"]
    corpus_path = evidence / scope["corpus_path"] / "manifest.json"
    replay_path = evidence / scope["replay_path"]
    reliability_path = evidence / scope["reliability_path"]
    corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
    replay = json.loads(replay_path.read_text(encoding="utf-8"))
    reliability = json.loads(reliability_path.read_text(encoding="utf-8"))

    records = int(scope["records"])
    corpus_id = str(scope["corpus_id"])
    checks = {
        "analysis_scope_passed": scope.get("status") == "PASS",
        "analysis_and_corpus_id_match": corpus.get("corpus_id") == corpus_id,
        "analysis_and_corpus_records_match": corpus.get("statistics", {}).get("records")
        == records,
        "corpus_is_entirely_listen_only": corpus.get("statistics", {}).get(
            "listen_only_records"
        )
        == records,
        "corpus_authority_remains_disabled": corpus.get("vehicle_claims_authorized")
        is False,
        "semantic_digest_matches": corpus.get("semantic_digest")
        == scope.get("semantic_digest"),
        "live_replay_consumed_exact_corpus": replay.get("live", {}).get("corpus_id")
        == corpus_id
        and replay.get("live", {}).get("input_records") == records
        and replay.get("live", {}).get("decoded_records") == records
        and replay.get("live", {}).get("exact_record_order_and_payload_match") is True,
        "history_replay_consumed_exact_corpus": replay.get("history", {}).get(
            "corpus_id"
        )
        == corpus_id
        and replay.get("history", {}).get("input_records") == records
        and replay.get("history", {}).get("decoded_records") == records
        and replay.get("history", {}).get("exact_record_order_and_payload_match")
        is True,
        "reliability_consumed_exact_corpus": reliability.get("corpus_id") == corpus_id
        and reliability.get("acceptance_status") == "PASS"
        and all(
            scenario.get("unique_input_records") == records
            for scenario in reliability.get("scenarios", [])
        ),
        "requested_soak_cycles_applied": reliability.get("soak_cycles")
        == config.soak_cycles,
    }
    if not reliability.get("scenarios"):
        checks["reliability_consumed_exact_corpus"] = False
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise GateFailure(
            "field-return corpus lineage proof failed: " + ", ".join(failed)
        )
    return {
        "status": "PASS",
        "source_classification": corpus.get("source_classification"),
        "vehicle_claims_authorized": corpus.get("vehicle_claims_authorized"),
        "corpus_id": corpus_id,
        "semantic_digest": corpus.get("semantic_digest"),
        "recovered_observations": records,
        "portable_recovered_observations": scope.get("portable_recovered_records"),
        "supplemental_direct_observations": scope.get("supplemental_direct_records"),
        "sessions": corpus.get("statistics", {}).get("sessions"),
        "unique_identifiers": corpus.get("statistics", {}).get("unique_identifiers"),
        "live_replay_input_observations": replay["live"]["input_records"],
        "history_replay_input_observations": replay["history"]["input_records"],
        "reliability_scenarios": reliability["scenario_count"],
        "reliability_soak_cycles": reliability["soak_cycles"],
        "reliability_input_observations_per_scenario": sorted(
            {scenario["unique_input_records"] for scenario in reliability["scenarios"]}
        ),
        "checks": checks,
        "proof_artifacts": {
            "corpus_manifest": str(corpus_path),
            "replay_report": str(replay_path),
            "reliability_report": str(reliability_path),
        },
    }


def _last_test_count(log: Path) -> dict[str, int] | None:
    text = log.read_text(encoding="utf-8", errors="replace")
    pytest = list(re.finditer(r"(\d+) passed(?:, (\d+) skipped)?", text))
    if pytest:
        match = pytest[-1]
        return {
            "tests_passed": int(match.group(1)),
            "tests_skipped": int(match.group(2) or 0),
            "test_failures": 0,
        }
    # Swift Testing emits a compatibility XCTest footer with "Executed 0 tests"
    # before its authoritative nonzero summary. Prefer the Swift Testing result
    # whenever it is present so that a healthy package run cannot be mistaken for
    # an empty test run.
    swift_testing = list(
        re.finditer(
            r"Test run with (\d+) tests?(?: in \d+ suites?)? passed",
            text,
        )
    )
    if swift_testing:
        match = swift_testing[-1]
        return {
            "tests_executed": int(match.group(1)),
            "test_failures": 0,
        }
    executed = list(
        re.finditer(
            r"Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?",
            text,
        )
    )
    if executed:
        match = executed[-1]
        return {
            "tests_executed": int(match.group(1)),
            "test_failures": int(match.group(2)),
            "unexpected_failures": int(match.group(3) or 0),
        }
    return None


def prove_gradle_sdk_selection(
    config: AcceptanceConfig,
    *,
    freshness_floor: float,
) -> dict[str, object]:
    """Read fresh AGP lint models to prove Gradle's effective compile platform."""

    import xml.etree.ElementTree as ET

    expected = android_sdk_provenance(config)
    expected_target = str(expected["compile_target"])
    expected_jar = Path(str(expected["android_jar"]["path"]))
    models = sorted(
        model
        for model in config.android_repo.glob(
            "**/build/intermediates/lint_report_lint_model/**/module.xml"
        )
        if model.stat().st_mtime >= freshness_floor
    )
    if not models:
        raise GateFailure("Android gate produced no fresh AGP lint model")
    targets: set[str] = set()
    boot_jars: set[Path] = set()
    for model in models:
        root = ET.parse(model).getroot()
        target = root.attrib.get("compileTarget")
        if target:
            targets.add(target)
        for entry in root.attrib.get("bootClassPath", "").split(os.pathsep):
            path = Path(entry)
            if path.name == "android.jar":
                boot_jars.add(path.resolve())
    if targets != {expected_target}:
        raise GateFailure(
            "Gradle compileTarget differs from the attested Android SDK: "
            f"expected {expected_target}, observed {sorted(targets)}"
        )
    if boot_jars != {expected_jar}:
        raise GateFailure(
            "Gradle bootClassPath differs from the attested Android platform JAR: "
            f"expected {expected_jar}, observed {sorted(map(str, boot_jars))}"
        )
    return {
        "status": "PASS",
        "fresh_lint_models": len(models),
        "compile_target": expected_target,
        "android_jar": expected["android_jar"],
    }


def annotate_available_gate_counts(
    run: DeviceFreeAcceptanceRun, config: AcceptanceConfig
) -> None:
    gates = run.summary["gates"]
    assert isinstance(gates, list)
    for name in ("python-tests", "swift-core-tests", "ios-simulator-tests"):
        gate = next(item for item in gates if item["name"] == name)
        metrics = _last_test_count(config.output / gate["log"]["path"])
        if metrics is None:
            raise GateFailure(f"{name} did not report a test count")
        executed = int(metrics.get("tests_executed", metrics.get("tests_passed", 0)))
        if executed < 1 or int(metrics.get("test_failures", 0)) != 0:
            raise GateFailure(f"{name} did not prove a nonzero passing test run")
        run.annotate_gate(name, **metrics)

    android_gate = next(
        item for item in gates if item["name"] == "android-tests-lint-build"
    )
    freshness_floor = float(android_gate["started_epoch_seconds"]) - 1.0
    android_results = list(
        result
        for result in config.android_repo.glob("**/build/test-results/*/TEST-*.xml")
        if result.stat().st_mtime >= freshness_floor
    )
    android_counts = {
        "test_suites": 0,
        "tests_executed": 0,
        "test_failures": 0,
        "tests_skipped": 0,
    }
    if android_results:
        import xml.etree.ElementTree as ET

        for result in android_results:
            root = ET.parse(result).getroot()
            android_counts["test_suites"] += 1
            android_counts["tests_executed"] += int(root.attrib.get("tests", 0))
            android_counts["test_failures"] += int(root.attrib.get("failures", 0))
            android_counts["test_failures"] += int(root.attrib.get("errors", 0))
            android_counts["tests_skipped"] += int(root.attrib.get("skipped", 0))
    android_counts["debug_apks"] = len(
        [
            apk
            for apk in config.android_repo.glob("app/build/outputs/apk/debug/*.apk")
            if apk.stat().st_mtime >= freshness_floor
        ]
    )
    lint_reports = [
        report
        for report in config.android_repo.glob("**/build/reports/lint-results*.xml")
        if report.stat().st_mtime >= freshness_floor
    ]
    android_counts["lint_reports"] = len(lint_reports)
    android_counts["lint_issues"] = 0
    android_counts["lint_errors"] = 0
    if lint_reports:
        import xml.etree.ElementTree as ET

        for report in lint_reports:
            issues = ET.parse(report).getroot().findall("issue")
            android_counts["lint_issues"] += len(issues)
            android_counts["lint_errors"] += sum(
                issue.attrib.get("severity") in {"Error", "Fatal"} for issue in issues
            )
    if (
        android_counts["tests_executed"] < 1
        or android_counts["test_failures"] != 0
        or android_counts["debug_apks"] < 1
        or android_counts["lint_reports"] < 1
        or android_counts["lint_errors"] != 0
    ):
        raise GateFailure(
            "Android gate did not produce fresh, nonzero passing tests, lint, and APK evidence"
        )
    android_counts["sdk_selection"] = prove_gradle_sdk_selection(
        config,
        freshness_floor=freshness_floor,
    )
    run.annotate_gate("android-tests-lint-build", **android_counts)
    ios_products = list(
        (config.output / "ios-derived/Build/Products").glob(
            "Debug-iphonesimulator/*.app/Vehicle Health OS"
        )
    )
    if not ios_products:
        raise GateFailure(
            "iOS Simulator build did not produce an application executable"
        )
    run.annotate_gate("ios-simulator-build", app_products=len(ios_products))


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        validate_source_arguments(args)
        config = resolve_config(args)
        validate_output_location(config)
    except Exception as error:
        print(f"DEVICE-FREE ACCEPTANCE COULD NOT START: {error}", file=sys.stderr)
        return 2
    inputs = {
        "product_repo": str(config.repo),
        "app_data": str(config.app_data),
        "baseline": str(config.baseline) if config.baseline else None,
        "android_repo": str(config.android_repo),
        "soak_cycles": config.soak_cycles,
        "ios_destination": config.ios_destination,
        "java_home": str(config.java_home),
        "android_sdk": str(config.android_sdk),
    }
    try:
        run = DeviceFreeAcceptanceRun(config.output, inputs)
    except Exception as error:
        print(f"DEVICE-FREE ACCEPTANCE COULD NOT START: {error}", file=sys.stderr)
        return 2

    try:
        sdk_provenance = validate_config(config)
        run.set_environment_provenance({"android_sdk": sdk_provenance})
        before_sources = capture_source_snapshots(config)
        run.set_source_snapshots(before_sources)
        gates = build_gate_specs(config)
        for gate in gates:
            run.run_gate(gate)
        evidence_proof = prove_field_return_evidence_chain(config)
        run.add_evidence_chain(evidence_proof)
        run.annotate_gate(
            "field-return-analysis",
            recovered_observations=evidence_proof["recovered_observations"],
            sessions=evidence_proof["sessions"],
            unique_identifiers=evidence_proof["unique_identifiers"],
            reliability_scenarios=evidence_proof["reliability_scenarios"],
            reliability_soak_cycles=evidence_proof["reliability_soak_cycles"],
        )
        annotate_available_gate_counts(run, config)
        for kind, expected_root, paths in collect_required_artifacts(config):
            run.add_artifacts(paths, kind=kind, expected_root=expected_root)
        after_sources = capture_source_snapshots(config)
        run.set_source_snapshots(before_sources, after=after_sources)
        if after_sources != before_sources:
            raise GateFailure(
                "product or Android source tree changed during acceptance"
            )
        run.succeed(gate.name for gate in gates)
    except Exception as error:
        run.fail(str(error))
        print(f"DEVICE-FREE ACCEPTANCE FAILED: {error}", file=sys.stderr)
        print(f"Fail-closed summary: {run.summary_path}", file=sys.stderr)
        return 1

    print("DEVICE-FREE ACCEPTANCE PASSED")
    print(f"Evidence summary: {run.summary_path}")
    print("Physical acceptance remains required; see remaining_physical_gates.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
