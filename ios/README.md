# Vehicle Health OS for iPhone

Native SwiftUI control surface for the VHOS gateway contract. Minimum deployment target is iOS 17.

## Implemented

- CoreBluetooth discovery and state restoration.
- Read-only recognition of factory WiCAN BLE service `FEE0` / characteristic `FEE1`.
- Versioned VHOS BLE service and framed message transport with CRC32C.
- Gateway handshake, live health, bounded protocol-discovery results, and evidence export.
- Automatic resumable download of the ESP32 current/previous passive CAN flight-recorder
  segments, CRC validation, durable iPhone NDJSON storage, Recent Logs, and share-sheet export.
- Live commissioning dashboard with distinct iPhone/BLE, ESP32 service/handshake, OBD-II,
  safety, capability, OTA, and evidence indicators.
- Per-candidate status for all four passive CAN candidates and five allowlisted legacy OBD
  candidates. Passive network detection is shown separately from a confirmed OBD response.
- Keychain-backed Ed25519 signing of semantic experiment approvals.
- Safety validation requiring a current `PARKED` report, idle capture, listen-only mode, and gateway capabilities.
- `.vhosota` parsing, Ed25519 signature/hash verification, compatibility/voltage/capability
  preflight, encrypted-BLE temporary-network activation, one-shot iOS hotspot join, authenticated
  local upload, cleanup, and rollback-status decoding.
- Provider-neutral JSON evidence handoff whose authority contract excludes vehicle activation and raw frame emission.

The app contains no arbitrary CAN/K-line/J1850 transmit console. Factory WiCAN compatibility mode is observation-only; experiments require the VHOS firmware fork and its capability handshake.

The passive flight recorder is independent from signed active experiments. It runs listen-only
on the gateway even when the phone is absent. After a handshake advertising
`evidence.persistent-log`, the app downloads previous before current, resumes from the local
record offset, and deduplicates by gateway/session/source sequence. See
[`docs/development/PASSIVE-CAN-LOGGING-AND-REPLAY.md`](../docs/development/PASSIVE-CAN-LOGGING-AND-REPLAY.md).

## Status semantics

- `PASS` is supported by app, gateway, or experiment evidence.
- `ACTIVE` means a scan, signed experiment, command transfer, or update is in progress.
- `CHECK` is an observed condition that requires review but is not silently promoted to failure.
- `BLOCKED` means a required safety or trust gate is not satisfied.
- `WAIT` means the app has not received enough evidence; it never means healthy.

The OBD-II summary becomes `CONFIRMED` only after a `READ_CONFIRMED` experiment result. A
`PASSIVE_LOCK` result is labeled `NETWORK ONLY`, because observed vehicle-bus traffic does not by
itself prove that a standards-based diagnostic request succeeded.

Discovery RSSI at or below -80 dBm is shown as `CHECK`, not `PASS`; at or below -90 dBm the app
directs the operator to place the iPhone beside the gateway before pairing. CoreBluetooth error 15
(`encryptionTimedOut`) is translated into a visible stale-bond recovery instruction instead of an
opaque transport failure.

If CoreBluetooth reports `peerRemovedPairingInformation`, the app discards the restored central
session once and immediately scans again with a clean, non-restored central. This prevents an old
restoration object from repeatedly terminating an otherwise valid post-forget connection.

Connections use CoreBluetooth state restoration plus one app-managed reconnect policy. The app
retries the saved peripheral at 1, 2, 4, 8, 15, and then 30-second intervals until the user
explicitly disconnects. The CoreBluetooth system auto-reconnect option is intentionally disabled:
physical testing showed that it could reconnect immediately while the app's bounded retry was
pending, creating overlapping connect attempts and a rapid timeout cycle. Ordinary radio loss,
app backgrounding, and gateway restarts still do not require removing the saved BLE bond.

State restoration treats `.connected` and `.connecting` peripherals as live transport state. The
app resumes service discovery directly instead of issuing a duplicate connect request or scanning
for a gateway that cannot advertise while connected. Before scanning, it also checks for a
system-connected peripheral exposing either supported service. A six-second GATT discovery
watchdog cancels an unresponsive restored link and reconnects with the existing bond. Reconnect
backoff resets only after the versioned VHOS handshake succeeds, not after a transient radio link.

The August 16, 2026 commissioning incident and physical validation record are documented in
[`docs/development/BLE-RESTORATION-INCIDENT-2026-08-16.md`](../docs/development/BLE-RESTORATION-INCIDENT-2026-08-16.md).

## Build

```bash
cd ios
xcodegen generate --spec project.yml
swift test --package-path Core
xcodebuild \
  -project VehicleHealthOS.xcodeproj \
  -scheme VehicleHealthOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Bluetooth and temporary-network joining require a physical iPhone. The Debug configuration uses
`VehicleHealthOSCommissioning.entitlements`, an empty entitlement set that permits BLE commissioning,
capture, export, and GATT recovery to be installed with the local wildcard development profile. It
does not authorize automatic temporary-network joining. Release builds use
`VehicleHealthOS.entitlements` and must be signed by a profile that includes Apple's Hotspot
Configuration entitlement before iPhone-managed Wi-Fi OTA can pass. Release private keys remain
external inputs. The complete workflow and remaining physical gates are in
[`docs/development/IPHONE-TO-ESP32-WIFI-OTA.md`](../docs/development/IPHONE-TO-ESP32-WIFI-OTA.md).

For an attached development iPhone, the commissioning harness can launch the app with
`--vhos-auto-scan` or `VHOS_AUTO_SCAN=1`. Either input starts the same CoreBluetooth scan exposed
by the on-screen control; neither bypasses Bluetooth permission, pairing approval, firmware trust,
or vehicle-safety gates.

## Gateway contract UUIDs

| Role | UUID |
| --- | --- |
| VHOS service | `33613EB3-FFCA-42D1-83FA-A18F12B3F123` |
| Command write | `B3D3279B-0244-4D54-A2AB-A1AB47A5FC0A` |
| Evidence stream notify | `265B90C0-A600-4659-BBBD-5CDA411C49CC` |
| Health/control notify | `BCB5699A-A9B4-49B8-B69B-D2DFF19B41A9` |
| OTA status notify | `18D21F8E-D190-4DB3-923C-27BBFC355874` |

The firmware implementation must treat these UUIDs and the `VHOS` frame header as versioned public contracts.
