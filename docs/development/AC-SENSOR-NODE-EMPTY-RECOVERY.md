# A/C sensor node empty recovery profile

Status: development, USB recovery only

The first ESP32-S3 image for the A/C node is deliberately an
`EMPTY_RECOVERY` profile. It exists to replace radio-disruptive experimental
software quickly without turning a blank chip into an unrecoverable device.

## Boot authority

The image may:

- inspect runtime chip, flash, PSRAM, reset, partition, and OTA state;
- initialize NVS non-destructively;
- confirm a pending A/B image only after the hardware self-test passes; and
- emit versioned bootstrap and five-second health evidence over USB serial.

The image may not initialize Wi-Fi, BLE, ADC, temperature, pressure, SD, SPI,
or any vehicle-bus interface. Unconfigured evidence is `UNAVAILABLE`, never a
synthetic nominal value. NVS initialization failure is reported and does not
authorize an automatic erase.

## Installer behavior

The hosted Web Serial provisioner is the recovery path. Its install plan
writes only the bootloader, partition table, initial OTA data, and application.
It protects the NVS range at `0x9000..0xCFFF`, requires a full-device backup,
checks the detected ESP32-S3 family and 16 MB flash capacity, verifies each
published segment by byte count and SHA-256, and requires explicit hardware
confirmation.

The generated merged image remains part of the release evidence, but the web
installer uses the NVS-preserving segment plan.

## Earlier ESP32 patterns retained

This profile takes the following proven patterns from the MrDIY ESP32 gateway:

- default-off radio/network activation after the SoftAP incident;
- backup-first USB installation with NVS preservation;
- A/B application slots, probationary boot, conditional mark-valid, and
  bootloader rollback; and
- machine-readable firmware/build identity and self-test evidence.

The full A/C firmware will later adapt the gateway's persisted random-static
BLE identity, encrypted GATT access, repeat-pair recovery, and bounded
notification queue. Those features are intentionally absent from the empty
recovery image and require their own contract and physical verification.

## Physical gate

A byte-verified build is not a physical pass. Before labeling the image
bench-validated, identify the board by base MAC, save its complete flash, write
the release at conservative baud, capture the first bootstrap/health records,
confirm no Wi-Fi network is created, and prove that restoring the saved image
returns the device to its prior state.
