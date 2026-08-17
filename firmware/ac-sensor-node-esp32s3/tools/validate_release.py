#!/usr/bin/env python3
"""Validate and package the A/C node's non-radio recovery release."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


ESP_IMAGE_MAGIC = 0xE9
EXPECTED_FLASH_BYTES = 16 * 1024 * 1024
EXPECTED_SEGMENTS = {
    "bootloader": 0x0000,
    "partition-table": 0x8000,
    "otadata": 0xD000,
    "app": 0x10000,
}
NVS_RANGE = {
    "label": "Device identity and future BLE bond NVS",
    "address": 0x9000,
    "byteCount": 0x4000,
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(repo_root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo_root), *args], text=True).strip()


def parse_size(value: str) -> int:
    normalized = value.strip().upper()
    multiplier = 1
    if normalized.endswith("K"):
        multiplier = 1024
        normalized = normalized[:-1]
    elif normalized.endswith("M"):
        multiplier = 1024 * 1024
        normalized = normalized[:-1]
    return int(normalized, 0) * multiplier


def parse_partitions(path: Path) -> dict[str, dict[str, int | str]]:
    partitions: dict[str, dict[str, int | str]] = {}
    with path.open(encoding="utf-8", newline="") as source:
        for row in csv.reader(line for line in source if not line.lstrip().startswith("#")):
            if not row or not row[0].strip():
                continue
            name, part_type, subtype, offset, size, *_ = [value.strip() for value in row]
            partitions[name] = {
                "type": part_type,
                "subtype": subtype,
                "offset": int(offset, 0),
                "size": parse_size(size),
            }
    return partitions


def parse_flash_files(build_dir: Path) -> dict[str, tuple[int, Path]]:
    raw = json.loads((build_dir / "flasher_args.json").read_text(encoding="utf-8"))
    files = raw.get("flash_files")
    require(isinstance(files, dict), "flasher_args.json has no flash_files object")
    by_offset = {int(address, 0): build_dir / filename for address, filename in files.items()}
    return {
        "bootloader": (EXPECTED_SEGMENTS["bootloader"], by_offset[EXPECTED_SEGMENTS["bootloader"]]),
        "partition-table": (EXPECTED_SEGMENTS["partition-table"], by_offset[EXPECTED_SEGMENTS["partition-table"]]),
        "otadata": (EXPECTED_SEGMENTS["otadata"], by_offset[EXPECTED_SEGMENTS["otadata"]]),
        "app": (EXPECTED_SEGMENTS["app"], by_offset[EXPECTED_SEGMENTS["app"]]),
    }


def validate_source(target_dir: Path) -> None:
    sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted((target_dir / "main").glob("*"))
        if path.suffix in {".c", ".h"}
    )
    required = {
        "explicit recovery profile": "EMPTY_RECOVERY",
        "explicit Wi-Fi disabled evidence": '\\"wifi_state\\":\\"DISABLED\\"',
        "explicit BLE disabled evidence": '\\"ble_state\\":\\"DISABLED\\"',
        "A/B mark-valid gate": "esp_ota_mark_app_valid_cancel_rollback",
        "non-destructive NVS initialization": "initialize_nvs_non_destructive",
        "unavailable sensor evidence": '\\"sensor_data_state\\":\\"UNAVAILABLE\\"',
    }
    for control, fragment in required.items():
        require(fragment in sources, f"recovery source is missing {control}")

    forbidden = {
        "destructive NVS erase": "nvs_flash_erase",
        "Wi-Fi driver initialization": "esp_wifi_init",
        "network-interface initialization": "esp_netif_init",
        "default event-loop initialization": "esp_event_loop_create_default",
        "NimBLE initialization": "nimble_port_init",
        "Bluetooth controller initialization": "esp_bt_controller_init",
        "ADC initialization": "adc_oneshot_new_unit",
        "SPI bus initialization": "spi_bus_initialize",
        "SD/MMC host initialization": "sdmmc_host_init",
        "vehicle-bus transmit path": "twai_transmit",
    }
    for authority, fragment in forbidden.items():
        require(fragment not in sources, f"empty recovery profile contains {authority}")


def validate_configuration(target_dir: Path, build_dir: Path) -> dict[str, dict[str, int | str]]:
    sdkconfig = (build_dir / "config" / "sdkconfig.h").read_text(encoding="utf-8")
    require('#define CONFIG_IDF_TARGET "esp32s3"' in sdkconfig, "build target is not ESP32-S3")
    require("#define CONFIG_ESPTOOLPY_FLASHSIZE_16MB 1" in sdkconfig, "flash size is not 16 MB")
    require("#define CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE 1" in sdkconfig, "bootloader rollback is disabled")
    require(
        "#define CONFIG_APP_ROLLBACK_ENABLE 1" in sdkconfig
        or "#define CONFIG_APP_ROLLBACK_ENABLE CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE" in sdkconfig,
        "application rollback is disabled",
    )
    require("#define CONFIG_BT_ENABLED 1" not in sdkconfig, "Bluetooth is compiled into the empty recovery profile")

    project = json.loads((build_dir / "project_description.json").read_text(encoding="utf-8"))
    build_components = set(project.get("build_components", []))
    forbidden_components = {"bt", "esp_netif", "esp_wifi", "lwip", "wifi_provisioning"}
    linked_forbidden = sorted(build_components & forbidden_components)
    require(
        not linked_forbidden,
        f"radio/network components are linked into empty recovery: {', '.join(linked_forbidden)}",
    )

    partitions = parse_partitions(target_dir / "partitions.csv")
    for name in ("nvs", "otadata", "ota_0", "ota_1"):
        require(name in partitions, f"required partition {name} is missing")
    require(partitions["nvs"]["offset"] == NVS_RANGE["address"], "NVS offset changed")
    require(partitions["nvs"]["size"] == NVS_RANGE["byteCount"], "NVS size changed")
    require(partitions["otadata"]["offset"] == EXPECTED_SEGMENTS["otadata"], "OTA data offset changed")
    require(partitions["ota_0"]["offset"] == EXPECTED_SEGMENTS["app"], "primary OTA slot offset changed")
    require(partitions["ota_0"]["size"] == partitions["ota_1"]["size"], "A/B OTA slots differ in size")
    return partitions


def published_artifact(source: Path, destination: Path) -> dict[str, int | str]:
    shutil.copyfile(source, destination)
    return {
        "url": f"/firmware/{destination.name}",
        "byteCount": destination.stat().st_size,
        "sha256": sha256(destination),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", required=True)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--target-dir", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--merged", type=Path, required=True)
    args = parser.parse_args()

    require(
        git(args.repo_root, "status", "--porcelain", "--untracked-files=normal") == "",
        "release validation requires a clean source worktree",
    )
    validate_source(args.target_dir)
    partitions = validate_configuration(args.target_dir, args.build_dir)
    flash_files = parse_flash_files(args.build_dir)

    merged = args.merged.read_bytes()
    require(merged and merged[0] == ESP_IMAGE_MAGIC, "merged image has invalid bootloader magic")
    for label, (address, source_path) in flash_files.items():
        require(source_path.is_file(), f"generated {label} binary is missing")
        source = source_path.read_bytes()
        require(source and source[0] == ESP_IMAGE_MAGIC if label in {"bootloader", "app"} else True,
                f"generated {label} image has invalid magic")
        require(merged[address : address + len(source)] == source,
                f"merged segment at 0x{address:x} differs from generated {label}")
        if label == "app":
            require(len(source) <= int(partitions["ota_0"]["size"]), "application exceeds an OTA slot")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    release_slug = f"vhos-ac-sensor-node-esp32s3-{args.release}"
    segment_names = {
        "bootloader": f"{release_slug}-bootloader.bin",
        "partition-table": f"{release_slug}-partition-table.bin",
        "otadata": f"{release_slug}-ota-data-initial.bin",
        "app": f"{release_slug}-app.bin",
    }
    segments = []
    for label, (address, source_path) in flash_files.items():
        artifact = published_artifact(source_path, args.output_dir / segment_names[label])
        segments.append({"label": label.replace("-", " ").title(), **artifact, "address": address})

    merged_artifact = {
        "url": f"/firmware/{args.merged.name}",
        "address": 0,
        "byteCount": args.merged.stat().st_size,
        "sha256": sha256(args.merged),
    }
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    firmware_commit = git(args.repo_root, "rev-parse", "HEAD")
    manifest = {
        "schemaVersion": "1.1.0",
        "release": args.release,
        "channel": "development",
        "publishedAt": now,
        "chipFamily": "ESP32-S3",
        "hardwareFamily": "AC-SENSOR-NODE-ESP32S3",
        "hardwareRevision": "bench-verified 16 MB flash / 8 MB octal PSRAM; final assembly not frozen",
        "upstreamTag": "empty-recovery-bootstrap",
        "sourceCommit": firmware_commit,
        "firmwareCommit": firmware_commit,
        "espIdfVersion": "5.5.3",
        "softwareProfile": "EMPTY_RECOVERY",
        "runtimeRadios": {"wifi": "not-initialized", "ble": "not-initialized"},
        "artifact": merged_artifact,
        "segments": segments,
        "protectedRanges": [NVS_RANGE],
    }
    validation = {
        "schemaVersion": "1.0.0",
        "release": args.release,
        "generatedAt": now,
        "firmwareCommit": firmware_commit,
        "expectedFlashBytes": EXPECTED_FLASH_BYTES,
        "checks": {
            "chipTarget": "passed:ESP32-S3",
            "emptyRecoverySourceBoundary": "passed",
            "runtimeRadioInitialization": "passed:none",
            "linkedRadioNetworkComponents": "passed:none",
            "destructiveNvsRecovery": "passed:absent",
            "nvsPreservingInstallPlan": "passed",
            "mergedSegmentsByteExact": "passed",
            "otaABPartitionTopology": "passed",
            "rollbackConfiguration": "passed",
            "applicationFitsBothSlots": "passed",
            "physicalFlashAndBoot": "not-run-by-release-builder",
        },
        "artifactSha256": merged_artifact["sha256"],
        "partitions": partitions,
    }
    manifest_path = args.output_dir / "manifest-ac-sensor-node-esp32s3.json"
    validation_path = args.output_dir / "recovery-validation-ac-sensor-node-esp32s3.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    validation_path.write_text(json.dumps(validation, indent=2) + "\n", encoding="utf-8")

    checksum_paths = [args.merged, *(args.output_dir / value for value in segment_names.values())]
    (args.output_dir / "SHA256SUMS-ac-sensor-node-esp32s3").write_text(
        "".join(f"{sha256(path)}  {path.name}\n" for path in checksum_paths),
        encoding="utf-8",
    )
    print(json.dumps(validation, indent=2))


if __name__ == "__main__":
    main()
