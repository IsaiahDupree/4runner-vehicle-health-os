# OTA trust and recovery

## Transport

Routine streaming/control uses BLE. Firmware images use local Wi-Fi because iOS background BLE
throughput is bounded. The MrDIY VHOS target uses an explicitly activated, fixed
`/api/v1/ota/image` endpoint on a five-minute hidden SoftAP; compatible upstream WiCAN firmware may
advertise its own local endpoint. See
[the complete iPhone flow](IPHONE-TO-ESP32-WIFI-OTA.md).

## `.vhosota` package

The binary package format is:

| Field | Encoding |
| --- | --- |
| Magic | ASCII `VHUP` |
| Container version | UInt16 big-endian, currently `1` |
| Manifest length | UInt32 big-endian |
| Firmware length | UInt32 big-endian |
| Signature length | UInt16 big-endian |
| Manifest | Canonical sorted-key UTF-8 JSON |
| Firmware | Exact ESP-IDF application image |
| Signature | Ed25519 signature |

The v1 manifest contains package ID, release channel/timestamp, firmware version/build ID, target hardware revisions, minimum bootloader version, image byte count/SHA-256, minimum gateway supply requirement, and a sorted list of required capabilities. Build provenance such as Git SHA and ESP-IDF version belongs in the build ID and release record until a future container version adds dedicated fields.

The Ed25519 signature covers `SHA256(manifestBytes || firmwareBytes)`. The iOS app verifies it with a pinned release public key before upload. Production private keys never enter the repository or app.

## Two independent verification layers

1. **Distribution layer:** iOS verifies the `.vhosota` Ed25519 signature, image hash, hardware compatibility, versions, and preconditions.
2. **Device boot layer:** ESP-IDF verifies a signed application image using its target-specific
   signed-app policy before activation. The physically verified classic ESP32 development target
   uses ECDSA V1 signed-app verification without burning Secure Boot eFuses.

The iOS signature does not replace ESP-IDF signed-image verification.

## Required preconditions

- Vehicle motion is deterministically `PARKED`, not `UNKNOWN`.
- Capture/discovery is stopped and persisted.
- Gateway reports sufficient supply for the manifest requirement.
- Hardware revision and current firmware meet compatibility constraints.
- Gateway advertises `ota.ab`, `ota.signed-image`, and `ota.rollback-self-test` capabilities.
- Package signature/hash pass.
- User explicitly confirms installation.

## Activation and rollback

Write only the inactive OTA slot. Boot the new image into pending-verification state. Self-test
configuration parse, storage, BLE/Wi-Fi, watchdog, OBD interpreter, TWAI listen-only initialization,
and passive capture. Mark valid only after all required checks pass; otherwise mark invalid and roll
back. The temporary AP is default-off, encrypted-BLE activated, random-credentialed, one-client,
bearer-authenticated, and automatically removed after success, failure, cancel, or expiry.

Stock WiCAN recovery remains OBD power plus USB-C flashing. Do not enable irreversible production secure-boot eFuses until development recovery, key custody, signed builds, and rollback have been bench-tested on sacrificial/development hardware.

## References

- [ESP-IDF OTA and rollback](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/ota.html)
- [ESP32 signed app verification without hardware Secure Boot](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/security/secure-boot-v1.html)
- [Apple CryptoKit Ed25519 signing](https://developer.apple.com/documentation/cryptokit/curve25519/signing)
