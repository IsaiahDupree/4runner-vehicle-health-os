# VHOS A/C sensor node firmware

This target is the safe ESP32-S3 foundation and empty recovery image for the
4Runner engine-bay A/C telemetry node.

It currently provides only capabilities that can be verified without the final sensor harness and calibration record:

- runtime chip, flash, PSRAM, reset, partition, and OTA-state inspection;
- A/B OTA partitions with bootloader rollback support;
- a monotonic five-second health heartbeat over USB serial;
- explicit `SAFE_MODE` and `UNAVAILABLE` states for every unconfigured sensor path; and
- Wi-Fi and Bluetooth disabled to prevent unintended radio interference during bench development.

The empty recovery profile is intentionally useful rather than a blank chip. A
blank ESP32-S3 cannot identify itself, report whether the board is healthy, or
participate in A/B rollback. This image retains only those recovery functions
and marks itself as `EMPTY_RECOVERY` in every bootstrap/health record.

It intentionally does **not** initialize ADC, RTD, pressure-sensor, storage,
Wi-Fi, or BLE paths. It also never erases NVS automatically. Sensor pins, part
identity, transfer functions, reference voltages, and calibration provenance
must be frozen before those drivers can produce evidence-grade observations.

The release installer writes bootloader, partition-table, OTA-selection, and
application segments while leaving the NVS range at `0x9000..0xCFFF`
untouched. This follows the proven backup-first, NVS-preserving, A/B rollback
pattern from the existing MrDIY ESP32 VHOS gateway. The later BLE phase should
reuse that gateway's persisted random-static identity, encrypted characteristic,
repeat-pairing recovery, and bounded-notification patterns; they are not
silently enabled in this empty profile.

## Build

From the repository root:

```bash
docker run --rm \
  -v "$PWD:/project" \
  -w /project/firmware/ac-sensor-node-esp32s3 \
  espressif/idf:v5.5.3 \
  bash -lc 'idf.py set-target esp32s3 && idf.py build'
```

Create the byte-verified web-flasher release bundle with the same pinned image:

```bash
docker run --rm \
  -v "$PWD:/project" \
  -w /project \
  espressif/idf:v5.5.3 \
  bash -lc 'firmware/ac-sensor-node-esp32s3/tools/build_release.sh v0.1.0-dev.1'
```

The builder rejects radio initialization, sensor-driver initialization,
destructive NVS recovery, missing rollback settings, incorrect partitions, and
any merged image whose embedded segments differ from the generated binaries.

The checked-in configuration targets the physically detected 16 MB flash / 8 MB octal-PSRAM ESP32-S3 board. Do not flash this image onto the classic ESP32 CAN gateway.

## Bench flashing

Resolve both serial devices immediately before writing. The validated A/C board identity is:

- USB serial port: `/dev/cu.usbserial-3110` at the 2026-08-16 bench session
- base MAC: `20:6e:f1:98:bd:20`
- chip: ESP32-S3 revision 0.2
- flash: 16 MB detected
- PSRAM: 8 MB embedded

Port names can change after reconnect. Re-run `esptool chip-id` and match the MAC; never select a port by name alone.

Use the generated flash arguments at a conservative baud:

```bash
uvx esptool --chip esp32s3 --port "$AC_NODE_PORT" --baud 115200 \
  --before default-reset --after hard-reset write-flash \
  @firmware/ac-sensor-node-esp32s3/build/flash_args
```

The first valid boot emits a single-line `sensor.node.bootstrap` POST and then health messages. This bootstrap contract is deliberately not the finalized `sensor.node.post/1.0.0` contract: the bare board has no trustworthy wall clock, vehicle assignment, or capture assignment yet.
