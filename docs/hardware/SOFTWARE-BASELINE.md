# Software baseline

## Pinned versions

| Layer | Version / revision | Purpose |
| --- | --- | --- |
| Vehicle Health OS iOS | iOS 17 minimum; Xcode 26.0.1; Swift 6.2 | Native iPhone client |
| Project generation | XcodeGen 2.45.4 | Deterministic `.xcodeproj` generation from `ios/project.yml` |
| WiCAN Pro factory firmware | `v4.50p`, published 2026-06-03 | Known upstream recovery/baseline image |
| WiCAN upstream source | `meatpiHQ/wican-fw` main SHA `5e28f494232b3a4532aa666b0bd060e030fe5aee` observed 2026-08-16 | Research reference; do not silently float production builds |
| WiCAN schematic | `sch/wican_obd_pro_sch_v151.pdf` | Hardware-revision design reference |
| VHOS firmware fork toolchain | ESP-IDF `v5.5.5` | Maintained 5.x baseline close to WiCAN's documented ESP-IDF >=5.1 requirement |
| E0 tooling | Python 3.12+ | Contract checks, deterministic simulator, capture replay |

The upstream WiCAN firmware is GPL-3.0. A distributed derivative firmware must comply with that license. The VHOS iOS application and platform-neutral contracts can remain separately licensed because they communicate with the gateway over documented interfaces rather than incorporating GPL source.

## Upstream behavior we rely on

- WiCAN Pro advertises BLE service `FEE0` with data characteristic `FEE1` and encrypted MITM-protected access in the current source.
- Upstream supports silent CAN mode and configurable CAN rates.
- Upstream exposes Wi-Fi configuration/status APIs and a firmware upload endpoint at `POST /upload/ota.bin`.
- Its partition table has `ota_0`, `ota_1`, and `otadata` slots.
- Factory recovery uses OBD power plus USB-C data; USB-C alone does not power WiCAN Pro.

These are integration facts pinned to the upstream revision above, not permanent public API guarantees. The iOS app performs a capability handshake and blocks unsupported operations rather than assuming them.

## VHOS firmware fork requirements before vehicle deployment

1. Default to TWAI/listen-only or dedicated-interpreter passive monitoring.
2. Remove unrestricted transmit routes from the iOS-visible surface.
3. Accept only semantic allowlist IDs for diagnostic reads.
4. Add a signed experiment-plan contract and deterministic policy evaluation.
5. Emit gateway-health, drop, error, reset, storage, and voltage evidence.
6. Require signed application updates, A/B OTA, pending-verify boot, self-test, and rollback.
7. Expose protocol/capability versions in handshake and audit every activation.

## Primary references

- [WiCAN firmware and hardware sources](https://github.com/meatpiHQ/wican-fw)
- [WiCAN Pro v4.50p release](https://github.com/meatpiHQ/wican-fw/releases/tag/v4.50p)
- [ESP-IDF v5.5.5](https://github.com/espressif/esp-idf/releases/tag/v5.5.5)
- [ESP32-S3 TWAI listen-only mode](https://docs.espressif.com/projects/esp-idf/en/v5.3.5/esp32s3/api-reference/peripherals/twai.html)
- [ESP-IDF OTA and rollback](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/ota.html)
- [ESP32-S3 security overview](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/security/security.html)
