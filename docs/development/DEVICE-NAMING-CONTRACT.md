# VHOS device naming contract

Status: accepted and implemented for OBD/CAN; reserved for A/C and head-unit commissioning

## Canonical names

| Physical role | User-facing name | Current unit |
|---|---|---|
| 4Runner OBD/CAN gateway | `VHOS-4R-OBD-<MAC suffix>` | `VHOS-4R-OBD-B08D14` |
| 4Runner A/C sensor node | `VHOS-4R-AC-<MAC suffix>` | Assigned when its BLE firmware is commissioned |
| Android head unit | `VHOS-4R-HU-<model>` | `VHOS-4R-HU-Q91` |

The six-character hardware suffix is the final three bytes of the ESP32 station MAC, rendered as
uppercase hexadecimal. A board keeps this name across boots, bonds, phone reinstalls, firmware
updates, and transport changes.

## Identity layers

1. **Friendly name** is the stable label shown to an owner and advertised over BLE.
2. **Evidence source ID** remains the complete immutable `gateway_id` emitted by the signed
   handshake. Renaming must never rewrite stored evidence or create a new lifecycle identity.
3. **Transport identifier** is a CoreBluetooth UUID on iOS or BLE address on Android. It may change
   because of OS privacy, restoration, or pairing behavior. It is diagnostic metadata only and must
   not be displayed as the device name or used as evidence identity.

## Migration

Apps normalize the legacy `VHOS-MRDIY-B08D14` advertisement to `VHOS-4R-OBD-B08D14` immediately.
The next OBD firmware advertises the canonical value natively. This display migration does not
delete bonds, require Settings cleanup, or change the complete gateway ID used by stored captures.

Names remain discovery aids. A device becomes trusted only after the versioned VHOS service,
required characteristics, encrypted link, signed contract, hardware identity, and listen-only state
are validated.
