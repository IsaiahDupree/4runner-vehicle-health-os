#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial>=3.5"]
# ///
"""Physical VHOS BLE fault-injection harness for a real iPhone and ESP32.

This tool never synthesizes vehicle observations. It perturbs only process,
radio-link, reset, and (when explicitly configured) USB-power boundaries, then
requires the real devices to re-establish the versioned VHOS contract.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

import serial


BUNDLE_ID = "com.isaiahdupree.VehicleHealthOS"

IPHONE_FATAL_SIGNATURES = (
    "FRAME_OR_CONTRACT_DECODE_FAILED",
    "FRAME_SEQUENCE_DISCONTINUITY",
    "HANDSHAKE_RESPONSE_EXHAUSTED",
    "HANDSHAKE_WRITE_ACK_TIMEOUT",
    "CAPTURE_TRANSFER_RECOVERY_FAILED",
    "CAPTURE_SYNC_PAUSED reason=write-error",
)

ESP_FATAL_SIGNATURES = (
    "Guru Meditation Error",
    "Stack overflow",
    "CORRUPT HEAP",
    "assert failed",
    "Task watchdog got triggered",
    "BLE_NOTIFY_BACKPRESSURE_EXHAUSTED",
)

ESP_UNEXPECTED_RESET_SIGNATURES = (
    "rst:0x",
)

CAPTURE_CHUNK_PATTERN = re.compile(
    r"CAPTURE_CHUNK session=(\d+) slot=(\d+) offset=(\d+) "
    r"received=(\d+) appended=(\d+) end=(true|false)"
)


def utc_stamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class EvidenceLog:
    def __init__(self, path: Path, label: str) -> None:
        self.path = path
        self.label = label
        self.lines: list[str] = []
        self.monotonic_times: list[float] = []
        self.condition = threading.Condition()
        self.handle = path.open("a", encoding="utf-8", buffering=1)

    def append(self, text: str) -> None:
        line = text.rstrip("\r\n")
        evidence = f"{utc_stamp()} {line}"
        observed_at = time.monotonic()
        with self.condition:
            self.lines.append(evidence)
            self.monotonic_times.append(observed_at)
            self.handle.write(evidence + "\n")
            self.condition.notify_all()
        print(f"[{self.label}] {line}", flush=True)

    def mark(self, text: str) -> int:
        self.append(f"HARNESS {text}")
        with self.condition:
            return len(self.lines)

    def position(self) -> int:
        with self.condition:
            return len(self.lines)

    def monotonic_at(self, index: int) -> float:
        with self.condition:
            return self.monotonic_times[index]

    def wait_for(
        self,
        fragment: str,
        start: int,
        timeout: float,
        abort_fragments: tuple[str, ...] = (),
    ) -> tuple[int, str]:
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for index in range(start, len(self.lines)):
                    for abort_fragment in abort_fragments:
                        if abort_fragment in self.lines[index]:
                            raise RuntimeError(
                                f"{self.label} emitted fatal signature "
                                f"{abort_fragment!r}: {self.lines[index]}"
                            )
                    if fragment in self.lines[index]:
                        return index, self.lines[index]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"{self.label} did not emit {fragment!r} within {timeout:.1f}s"
                    )
                self.condition.wait(remaining)

    def wait_for_any(
        self,
        fragments: tuple[str, ...],
        start: int,
        timeout: float,
        abort_fragments: tuple[str, ...] = (),
    ) -> tuple[int, str, str]:
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for index in range(start, len(self.lines)):
                    for abort_fragment in abort_fragments:
                        if abort_fragment in self.lines[index]:
                            raise RuntimeError(
                                f"{self.label} emitted fatal signature "
                                f"{abort_fragment!r}: {self.lines[index]}"
                            )
                    for fragment in fragments:
                        if fragment in self.lines[index]:
                            return index, self.lines[index], fragment
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    expected = " or ".join(repr(fragment) for fragment in fragments)
                    raise TimeoutError(
                        f"{self.label} did not emit {expected} within {timeout:.1f}s"
                    )
                self.condition.wait(remaining)

    def assert_absent(self, fragments: tuple[str, ...], start: int) -> None:
        with self.condition:
            for line in self.lines[start:]:
                for fragment in fragments:
                    if fragment in line:
                        raise RuntimeError(
                            f"{self.label} emitted fatal signature {fragment!r}: {line}"
                        )

    def close(self) -> None:
        self.handle.close()


class UARTMonitor:
    def __init__(self, device: str, log: EvidenceLog) -> None:
        self.device = device
        self.log = log
        self.stop_event = threading.Event()
        self.port: serial.Serial | None = None
        self.thread: threading.Thread | None = None

    def open(self) -> None:
        if not Path(self.device).exists():
            raise FileNotFoundError(f"UART device is not present: {self.device}")
        self.log.mark(
            f"UART_ATTACH_BEGIN device={self.device} note=CP2102-modem-line-transition-may-reset-target"
        )
        port = serial.Serial()
        port.port = self.device
        port.baudrate = 115200
        port.timeout = 0.2
        port.dtr = False
        port.rts = False
        port.open()
        self.port = port
        self.stop_event.clear()
        self.thread = threading.Thread(target=self._read, name="vhos-uart", daemon=True)
        self.thread.start()
        self.log.append(f"UART_OPEN device={self.device} baud=115200")

    def _read(self) -> None:
        pending = bytearray()
        while not self.stop_event.is_set():
            assert self.port is not None
            try:
                chunk = self.port.read(4096)
            except serial.SerialException as error:
                self.log.append(f"UART_READ_ERROR error={error}")
                return
            if not chunk:
                continue
            pending.extend(chunk)
            while b"\n" in pending:
                raw, _, remainder = pending.partition(b"\n")
                pending = bytearray(remainder)
                line = raw.decode("utf-8", errors="replace").replace("\x00", "")
                if line.strip():
                    self.log.append(line)
        if pending:
            line = pending.decode("utf-8", errors="replace").replace("\x00", "")
            if line.strip():
                self.log.append(line)

    def hard_reset(self) -> None:
        if self.port is None:
            raise RuntimeError("UART is not open")
        self.log.mark("FAULT_INJECT type=esp-hard-reset mechanism=CP2102-RTS")
        self.port.dtr = False
        self.port.rts = True
        time.sleep(0.12)
        self.port.rts = False

    def close(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=1)
        if self.port is not None:
            self.port.close()
        self.port = None


class IPhoneConsole:
    def __init__(self, device: str, log: EvidenceLog) -> None:
        self.device = device
        self.log = log
        self.process: subprocess.Popen[str] | None = None
        self.thread: threading.Thread | None = None

    def launch(self) -> int:
        self.stop_console()
        environment = os.environ.copy()
        environment["DEVICECTL_CHILD_VHOS_COMMISSIONING_TRACE"] = "1"
        command = [
            "xcrun",
            "devicectl",
            "device",
            "process",
            "launch",
            "--device",
            self.device,
            "--terminate-existing",
            "--console",
            BUNDLE_ID,
            "--vhos-auto-scan",
        ]
        start = self.log.mark(
            "FAULT_INJECT type=app-launch-or-relaunch mechanism=devicectl"
        )
        self.process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=environment,
        )
        self.thread = threading.Thread(target=self._read, name="vhos-iphone", daemon=True)
        self.thread.start()
        return start

    def _read(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for line in self.process.stdout:
            self.log.append(line)

    def stop_console(self) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        if self.thread is not None:
            self.thread.join(timeout=1)
        self.process = None
        self.thread = None


def remaining_seconds(deadline: float, context: str) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError(f"recovery budget expired while waiting for {context}")
    return remaining


def wait_for_contract(
    iphone: EvidenceLog,
    start: int,
    deadline: float,
    minimum_health_frames: int,
    expected_firmware: str | None,
    minimum_rssi: int,
    soak_seconds: float,
    minimum_activity_rate: float,
    maximum_activity_gap: float,
    minimum_capture_records: int,
    require_capture_eof: bool,
) -> dict[str, object]:
    began = time.monotonic()
    candidate_cursor = start
    rejected_link_candidates: list[dict[str, object]] = []
    while True:
        link_index, link = iphone.wait_for(
            "LINK_CONNECTED link_session=",
            candidate_cursor,
            remaining_seconds(deadline, "a qualified physical BLE link"),
            IPHONE_FATAL_SIGNATURES,
        )
        session_match = re.search(r"LINK_CONNECTED link_session=(\d+)", link)
        if session_match is None:
            raise RuntimeError(f"LINK_CONNECTED did not identify its link session: {link}")
        link_session = int(session_match.group(1))
        rssi_fragment = f"LINK_RSSI link_session={link_session} rssi="
        rssi_failed_fragment = f"LINK_RSSI_FAILED link_session={link_session}"
        disconnected_fragment = f"LINK_DISCONNECTED link_session={link_session}"
        result_index, rssi_line, result_kind = iphone.wait_for_any(
            (rssi_fragment, rssi_failed_fragment, disconnected_fragment),
            link_index + 1,
            remaining_seconds(deadline, "a connected-link RSSI qualification result"),
            IPHONE_FATAL_SIGNATURES,
        )
        candidate_cursor = result_index + 1
        if result_kind != rssi_fragment:
            rejected_link_candidates.append(
                {
                    "link_session": link_session,
                    "reason": "rssi-read-failed" if result_kind == rssi_failed_fragment else "disconnected-before-rssi",
                    "evidence": rssi_line,
                }
            )
            continue
        rssi_match = re.search(
            rf"LINK_RSSI link_session={link_session} rssi=(-?\d+)", rssi_line
        )
        if rssi_match is None:
            raise RuntimeError(f"LINK_RSSI did not contain a numeric measurement: {rssi_line}")
        observed_rssi = int(rssi_match.group(1))
        if observed_rssi < minimum_rssi:
            rejected_link_candidates.append(
                {
                    "link_session": link_session,
                    "reason": "below-rssi-floor",
                    "rssi_dbm": observed_rssi,
                    "required_rssi_dbm": minimum_rssi,
                }
            )
            continue
        break
    session_abort_signatures = IPHONE_FATAL_SIGNATURES + (
        f"LINK_DISCONNECTED link_session={link_session}",
        f"LINK_RSSI_FAILED link_session={link_session}",
    )
    handshake_index, handshake = iphone.wait_for(
        "HANDSHAKE_VERIFIED firmware=",
        link_index + 1,
        remaining_seconds(deadline, "a verified VHOS application contract"),
        session_abort_signatures,
    )
    observed_firmware = handshake.split("HANDSHAKE_VERIFIED firmware=", 1)[1].split()[0]
    if expected_firmware and observed_firmware != expected_firmware:
        raise RuntimeError(
            f"gateway reported firmware {observed_firmware}, expected {expected_firmware}"
        )
    activity_lines: list[str] = []
    health_lines: list[str] = []
    capture_chunks: list[dict[str, int | bool]] = []
    activity_times: list[float] = []
    expected_capture_offset: int | None = None
    capture_session: int | None = None
    capture_sessions: list[int] = []
    cursor = handshake_index + 1

    def record_activity(index: int, activity: str, activity_kind: str) -> None:
        nonlocal expected_capture_offset, capture_session
        activity_lines.append(activity)
        activity_times.append(iphone.monotonic_at(index))
        if activity_kind == "HEALTH_DECODED":
            health_lines.append(activity)
            return
        match = CAPTURE_CHUNK_PATTERN.search(activity)
        if match is None:
            raise RuntimeError(f"capture chunk trace was malformed: {activity}")
        session_id, slot, offset, received, appended = map(int, match.groups()[:5])
        end_of_file = match.group(6) == "true"
        if received <= 0 or appended < 0 or appended > received:
            raise RuntimeError(f"capture chunk counts were invalid: {activity}")
        if capture_session is None:
            capture_session = session_id
            capture_sessions.append(session_id)
        elif session_id != capture_session:
            if not capture_chunks or not bool(capture_chunks[-1]["end_of_file"]):
                raise RuntimeError(
                    f"capture session changed before the prior authenticated EOF: "
                    f"{capture_session} -> {session_id}"
                )
            capture_session = session_id
            capture_sessions.append(session_id)
            expected_capture_offset = None
        if expected_capture_offset is not None and offset != expected_capture_offset:
            raise RuntimeError(
                f"capture offsets were not contiguous: expected "
                f"{expected_capture_offset}, observed {offset}"
            )
        expected_capture_offset = offset + received
        capture_chunks.append(
            {
                "session_id": session_id,
                "slot": slot,
                "offset": offset,
                "received": received,
                "appended": appended,
                "end_of_file": end_of_file,
            }
        )

    while len(activity_lines) < minimum_health_frames:
        try:
            cursor, activity, activity_kind = iphone.wait_for_any(
                ("HEALTH_DECODED", "CAPTURE_CHUNK session="),
                cursor,
                remaining_seconds(deadline, "post-handshake health or capture activity"),
                session_abort_signatures,
            )
        except TimeoutError as error:
            raise TimeoutError(
                f"received {len(activity_lines)}/{minimum_health_frames} post-contract "
                f"activity frames ({len(health_lines)} health, "
                f"{len(capture_chunks)} capture chunks) "
                "inside the recovery budget"
            ) from error
        record_activity(cursor, activity, activity_kind)
        cursor += 1

    soak_started = time.monotonic()
    soak_activity_start = len(activity_lines)
    soak_capture_start = len(capture_chunks)
    soak_deadline = soak_started + soak_seconds
    while time.monotonic() < soak_deadline:
        remaining = soak_deadline - time.monotonic()
        wait_budget = remaining
        if maximum_activity_gap > 0:
            wait_budget = min(wait_budget, maximum_activity_gap)
        try:
            cursor, activity, activity_kind = iphone.wait_for_any(
                ("HEALTH_DECODED", "CAPTURE_CHUNK session="),
                cursor,
                wait_budget,
                session_abort_signatures,
            )
        except TimeoutError as error:
            if time.monotonic() >= soak_deadline and maximum_activity_gap <= 0:
                break
            if maximum_activity_gap > 0:
                raise TimeoutError(
                    f"no post-contract activity arrived within the allowed "
                    f"{maximum_activity_gap:.3f}s gap during the sustained-load window"
                ) from error
            raise
        record_activity(cursor, activity, activity_kind)
        cursor += 1

    soak_completed = time.monotonic()
    soak_duration = max(0.0, soak_completed - soak_started)
    soak_times = activity_times[soak_activity_start:]
    soak_activity_count = len(activity_lines) - soak_activity_start
    soak_activity_rate = (
        soak_activity_count / soak_duration if soak_duration > 0 else None
    )
    maximum_observed_gap: float | None = None
    if soak_seconds > 0:
        endpoints = [soak_started, *soak_times, soak_completed]
        maximum_observed_gap = max(
            later - earlier for earlier, later in zip(endpoints, endpoints[1:])
        )
        if maximum_activity_gap > 0 and maximum_observed_gap > maximum_activity_gap:
            raise RuntimeError(
                f"maximum activity gap {maximum_observed_gap:.3f}s exceeded "
                f"the allowed {maximum_activity_gap:.3f}s"
            )
        if minimum_activity_rate > 0 and (
            soak_activity_rate is None or soak_activity_rate < minimum_activity_rate
        ):
            raise RuntimeError(
                f"sustained activity rate {soak_activity_rate or 0:.3f} frames/s "
                f"was below the required {minimum_activity_rate:.3f} frames/s"
            )

    capture_records_received = sum(int(chunk["received"]) for chunk in capture_chunks)
    capture_records_appended = sum(int(chunk["appended"]) for chunk in capture_chunks)
    soak_capture_chunks = capture_chunks[soak_capture_start:]
    soak_capture_records = sum(int(chunk["received"]) for chunk in soak_capture_chunks)
    capture_eof_observed = any(bool(chunk["end_of_file"]) for chunk in capture_chunks)
    if capture_records_received < minimum_capture_records:
        raise RuntimeError(
            f"received {capture_records_received}/{minimum_capture_records} required "
            "capture records during the link epoch"
        )
    if require_capture_eof and not capture_eof_observed:
        raise RuntimeError("capture transfer did not reach an authenticated end-of-file chunk")
    iphone.assert_absent(session_abort_signatures, link_index)
    return {
        "link_session": link_session,
        "link": link,
        "handshake": handshake,
        "observed_firmware": observed_firmware,
        "link_rssi_dbm": observed_rssi,
        "minimum_rssi_dbm": minimum_rssi,
        "rejected_link_candidates": rejected_link_candidates,
        "activity_proof": "capture-transfer" if capture_chunks else "health-stream",
        "activity_frames": len(activity_lines),
        "health_frames": len(health_lines),
        "capture_chunks": len(capture_chunks),
        "capture_session": capture_session,
        "capture_sessions": capture_sessions,
        "capture_first_offset": capture_chunks[0]["offset"] if capture_chunks else None,
        "capture_next_offset": expected_capture_offset,
        "capture_records_received": capture_records_received,
        "capture_records_appended": capture_records_appended,
        "capture_record_bytes_received": capture_records_received * 36,
        "capture_eof_observed": capture_eof_observed,
        "soak_seconds_required": soak_seconds,
        "soak_seconds_observed": round(soak_duration, 3),
        "soak_activity_frames": soak_activity_count,
        "soak_activity_rate_frames_per_second": (
            round(soak_activity_rate, 3) if soak_activity_rate is not None else None
        ),
        "soak_maximum_activity_gap_seconds": (
            round(maximum_observed_gap, 3) if maximum_observed_gap is not None else None
        ),
        "soak_capture_chunks": len(soak_capture_chunks),
        "soak_capture_records_received": soak_capture_records,
        "minimum_activity_rate_frames_per_second": minimum_activity_rate,
        "maximum_activity_gap_seconds_allowed": maximum_activity_gap,
        "minimum_capture_records_required": minimum_capture_records,
        "recovery_seconds": round(time.monotonic() - began, 3),
    }


def power_cycle(args: argparse.Namespace, uart: UARTMonitor, uart_log: EvidenceLog) -> None:
    if not args.usb_hub or not args.usb_port:
        raise RuntimeError("power-cycle requires both --usb-hub and --usb-port")
    executable = shutil.which("uhubctl")
    if executable is None:
        raise RuntimeError(
            "uhubctl is not installed; use a compatible switchable USB hub/relay or omit power-cycle"
        )
    uart_log.mark(
        f"FAULT_INJECT type=true-usb-power-cut hub={args.usb_hub} port={args.usb_port}"
    )
    uart.close()
    subprocess.run(
        [executable, "-l", args.usb_hub, "-p", args.usb_port, "-a", "off"],
        check=True,
    )
    time.sleep(args.power_off_seconds)
    subprocess.run(
        [executable, "-l", args.usb_hub, "-p", args.usb_port, "-a", "on"],
        check=True,
    )
    deadline = time.monotonic() + args.timeout
    while not Path(args.serial).exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"UART did not return after power restore: {args.serial}")
        time.sleep(0.25)
    uart.open()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run real-device VHOS BLE reset/relaunch/power-loss recovery cycles."
    )
    parser.add_argument("--iphone", required=True, help="CoreDevice identifier or UDID")
    parser.add_argument("--serial", required=True, help="Exact ESP32 /dev/cu.* path")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--dwell", type=float, default=8.0)
    parser.add_argument("--health-frames", type=int, default=3)
    parser.add_argument(
        "--soak-seconds",
        type=float,
        default=0.0,
        help="Sustain real health/capture traffic for this many seconds after each contract",
    )
    parser.add_argument(
        "--minimum-activity-rate",
        type=float,
        default=0.0,
        help="Minimum health-or-capture events per second during the soak window",
    )
    parser.add_argument(
        "--maximum-activity-gap",
        type=float,
        default=0.0,
        help="Maximum permitted seconds without health/capture traffic during soak (0 disables)",
    )
    parser.add_argument(
        "--minimum-capture-records",
        type=int,
        default=0,
        help="Require at least this many real retained CAN records in each link epoch",
    )
    parser.add_argument(
        "--require-capture-eof",
        action="store_true",
        help="Require the retained-history transfer to reach its authenticated end marker",
    )
    parser.add_argument(
        "--minimum-rssi",
        type=int,
        default=-72,
        help="Fail a cycle whose connected-link RSSI is below this dBm floor (default: -72)",
    )
    parser.add_argument(
        "--expected-firmware",
        help="Require this exact firmware string in HANDSHAKE_VERIFIED",
    )
    parser.add_argument(
        "--faults",
        default="esp-reset,app-relaunch",
        help="Comma-separated sequence: esp-reset, app-relaunch, power-cycle",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--usb-hub", help="Explicit uhubctl hub location for true power cuts")
    parser.add_argument("--usb-port", help="Explicit uhubctl port for true power cuts")
    parser.add_argument("--power-off-seconds", type=float, default=3.0)
    args = parser.parse_args()
    if args.cycles < 0 or args.health_frames < 1:
        parser.error("--cycles must be nonnegative and --health-frames must be positive")
    if args.soak_seconds < 0:
        parser.error("--soak-seconds must be nonnegative")
    if args.minimum_activity_rate < 0 or args.maximum_activity_gap < 0:
        parser.error("activity-rate and activity-gap thresholds must be nonnegative")
    if args.minimum_capture_records < 0:
        parser.error("--minimum-capture-records must be nonnegative")
    if args.soak_seconds == 0 and (
        args.minimum_activity_rate > 0 or args.maximum_activity_gap > 0
    ):
        parser.error("activity-rate and activity-gap thresholds require --soak-seconds")
    if not -127 <= args.minimum_rssi <= 0:
        parser.error("--minimum-rssi must be between -127 and 0 dBm")
    allowed = {"esp-reset", "app-relaunch", "power-cycle"}
    args.faults = [item.strip() for item in args.faults.split(",") if item.strip()]
    unknown = set(args.faults) - allowed
    if unknown:
        parser.error(f"unsupported faults: {', '.join(sorted(unknown))}")
    if not args.faults:
        parser.error("at least one fault is required")
    return args


def main() -> int:
    args = parse_args()
    started_at = utc_stamp()
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    output = args.output or Path("build/fault-injection") / run_id
    output.mkdir(parents=True, exist_ok=False)
    iphone_log = EvidenceLog(output / "iphone.log", "iphone")
    uart_log = EvidenceLog(output / "esp32.log", "esp32")
    iphone = IPhoneConsole(args.iphone, iphone_log)
    uart = UARTMonitor(args.serial, uart_log)
    results: list[dict[str, object]] = []
    outcome = "PASS"
    failure: str | None = None
    try:
        uart.open()
        time.sleep(2.0)
        baseline_uart_stability_start = uart_log.position()
        iphone_start = iphone.launch()
        deadline = time.monotonic() + args.timeout
        baseline = wait_for_contract(
            iphone_log,
            iphone_start,
            deadline,
            args.health_frames,
            args.expected_firmware,
            args.minimum_rssi,
            args.soak_seconds,
            args.minimum_activity_rate,
            args.maximum_activity_gap,
            args.minimum_capture_records,
            args.require_capture_eof,
        )
        uart_log.assert_absent(
            ESP_FATAL_SIGNATURES + ESP_UNEXPECTED_RESET_SIGNATURES,
            baseline_uart_stability_start,
        )
        results.append({"cycle": 0, "fault": "baseline", "result": "PASS", **baseline})
        for cycle in range(1, args.cycles + 1):
            fault = args.faults[(cycle - 1) % len(args.faults)]
            time.sleep(args.dwell)
            pre_fault_cursor = iphone_log.position()
            _, pre_fault_activity, pre_fault_kind = iphone_log.wait_for_any(
                ("HEALTH_DECODED", "CAPTURE_CHUNK session="),
                pre_fault_cursor,
                max(5.0, args.maximum_activity_gap),
                IPHONE_FATAL_SIGNATURES,
            )
            iphone_log.mark(
                f"FAULT_TRIGGER_PROOF cycle={cycle} fault={fault} live_activity={pre_fault_kind} evidence={pre_fault_activity.split(' ', 1)[-1]}"
            )
            iphone_start = iphone_log.position()
            uart_start = uart_log.position()
            deadline = time.monotonic() + args.timeout
            if fault == "esp-reset":
                uart.hard_reset()
                uart_log.wait_for(
                    "VHOS_SELF_TEST_PASS",
                    uart_start,
                    remaining_seconds(deadline, "ESP32 reboot self-test"),
                    ESP_FATAL_SIGNATURES,
                )
                uart_stability_start = uart_log.position()
            elif fault == "app-relaunch":
                iphone_start = iphone.launch()
                uart_stability_start = uart_start
            else:
                power_cycle(args, uart, uart_log)
                uart_log.wait_for(
                    "VHOS_SELF_TEST_PASS",
                    uart_start,
                    remaining_seconds(deadline, "ESP32 power-cycle self-test"),
                    ESP_FATAL_SIGNATURES,
                )
                uart_stability_start = uart_log.position()
            recovery = wait_for_contract(
                iphone_log,
                iphone_start,
                deadline,
                args.health_frames,
                args.expected_firmware,
                args.minimum_rssi,
                args.soak_seconds,
                args.minimum_activity_rate,
                args.maximum_activity_gap,
                args.minimum_capture_records,
                args.require_capture_eof,
            )
            uart_log.assert_absent(
                ESP_FATAL_SIGNATURES + ESP_UNEXPECTED_RESET_SIGNATURES,
                uart_stability_start,
            )
            results.append(
                {
                    "cycle": cycle,
                    "fault": fault,
                    "result": "PASS",
                    "fault_trigger_proof": pre_fault_kind,
                    **recovery,
                }
            )
    except Exception as error:  # Evidence is preserved before returning failure.
        outcome = "FAIL"
        failure = str(error)
        print(f"FAULT-INJECTION FAILURE: {failure}", file=sys.stderr, flush=True)
    finally:
        iphone.stop_console()
        uart.close()
        summary = {
            "schema_version": 1,
            "run_id": run_id,
            "started_at": started_at,
            "completed_at": utc_stamp(),
            "outcome": outcome,
            "failure": failure,
            "iphone": args.iphone,
            "serial": args.serial,
            "faults": args.faults,
            "cycles_requested": args.cycles,
            "cycles_completed": len(results) - (1 if results else 0),
            "recovery_budget_seconds": args.timeout,
            "dwell_seconds": args.dwell,
            "required_post_contract_activity_frames": args.health_frames,
            "soak_seconds_per_epoch": args.soak_seconds,
            "minimum_activity_rate_frames_per_second": args.minimum_activity_rate,
            "maximum_activity_gap_seconds": args.maximum_activity_gap,
            "minimum_capture_records_per_epoch": args.minimum_capture_records,
            "require_capture_eof": args.require_capture_eof,
            "expected_firmware": args.expected_firmware,
            "minimum_link_rssi_dbm": args.minimum_rssi,
            "fatal_signature_oracles": {
                "iphone": IPHONE_FATAL_SIGNATURES,
                "esp32": ESP_FATAL_SIGNATURES,
                "unexpected_esp32_reset": ESP_UNEXPECTED_RESET_SIGNATURES,
            },
            "results": results,
            "limitations": [
                "Opening or closing some CP2102 UARTs can reset the target through modem-control lines; the attach marker makes that baseline perturbation explicit.",
                "RTS reset removes firmware execution but is not a true electrical power cut.",
                "True power cut requires an explicitly selected per-port switchable USB hub or relay.",
                "No vehicle signal is synthesized; CAN evidence requires a real connected vehicle bus.",
            ],
        }
        (output / "summary.json").write_text(
            json.dumps(summary, indent=2) + "\n", encoding="utf-8"
        )
        iphone_log.close()
        uart_log.close()
        print(f"Evidence: {output}", flush=True)
    return 0 if outcome == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
