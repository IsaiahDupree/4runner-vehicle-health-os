# Vehicle Health OS for iPhone

Native SwiftUI control surface for the VHOS gateway contract. Minimum deployment target is iOS 17.

## Implemented

- CoreBluetooth discovery, handshake-verified state restoration, encrypted-bond reuse, and
  app-managed reconnection.
- Read-only recognition of factory WiCAN BLE service `FEE0` / characteristic `FEE1`.
- Versioned VHOS BLE service and framed message transport with CRC32C.
- Gateway handshake, live health, bounded protocol-discovery results, and evidence export.
- Automatic resumable download of the ESP32 current/previous passive CAN flight-recorder
  segments, CRC validation, durable iPhone NDJSON storage, Recent Logs, and share-sheet export.
- Always-on, bounded CoreBluetooth connection flight recorder with structured NDJSON export for
  scan, GATT, subscription, handshake, disconnect, and automatic-recovery diagnosis.
- Live commissioning dashboard with distinct iPhone/BLE, ESP32 service/handshake, OBD-II,
  safety, capability, OTA, and evidence indicators.
- Per-candidate status for all four passive CAN candidates and five allowlisted legacy OBD
  candidates. Passive network detection is shown separately from a confirmed OBD response.
- Keychain-backed Ed25519 signing of semantic experiment approvals.
- Safety validation requiring a current `PARKED` report, idle capture, listen-only mode, and gateway capabilities.
- `.vhosota` parsing, Ed25519 signature/hash verification, compatibility/voltage/capability
  preflight, encrypted-BLE temporary-network activation, one-shot iOS hotspot join, authenticated
  local upload, cleanup, and rollback-status decoding.
- A signed public Release Hub that stages Android, OBD ESP32, and A/C recovery artifacts from one
  target-aware catalog; iOS shares Android builds but does not claim authority to install an APK.
- Provider-neutral JSON evidence handoff whose authority contract excludes vehicle activation and raw frame emission.

The app contains no arbitrary CAN/K-line/J1850 transmit console. Factory WiCAN compatibility mode is observation-only; experiments require the VHOS firmware fork and its capability handshake.

The passive flight recorder is independent from signed active experiments. It runs listen-only
on the gateway even when the phone is absent. After a handshake advertising
`evidence.persistent-log`, the app downloads previous before current, resumes from the local
record offset, and deduplicates by gateway/session/source sequence. See
[`docs/development/PASSIVE-CAN-LOGGING-AND-REPLAY.md`](../docs/development/PASSIVE-CAN-LOGGING-AND-REPLAY.md).

Bluetooth transport evidence is stored separately from vehicle observations. Open **Evidence →
Bluetooth connection flight recorder** to export it without Xcode; retention, event fields,
privacy boundaries, and deeper Apple/radio escalation paths are documented in the
[iPhone BLE flight-recorder specification](../docs/development/IPHONE-BLE-CONNECTION-FLIGHT-RECORDER.md).

## Status semantics

- `PASS` is supported by app, gateway, or experiment evidence.
- `ACTIVE` means a scan, signed experiment, command transfer, or update is in progress.
- `CHECK` is an observed condition that requires review but is not silently promoted to failure.
- `BLOCKED` means a required safety or trust gate is not satisfied.
- `WAIT` means the app has not received enough evidence; it never means healthy.

The OBD-II summary becomes `CONFIRMED` only after a `READ_CONFIRMED` experiment result. A
`PASSIVE_LOCK` result is labeled `NETWORK ONLY`, because observed vehicle-bus traffic does not by
itself prove that a standards-based diagnostic request succeeded.

Advertisement or connected-link RSSI at or below -80 dBm is shown as `CHECK`, not `PASS`; at or
below -90 dBm the app directs the operator to place the iPhone beside the gateway before pairing.
The app reads RSSI again from each exact physical-link epoch and exposes it as `LINK_RSSI` in the
commissioning trace, so automated acceptance cannot rely on an old scan value. A connection timeout
while the encrypted notification subscription is pending is reported as CoreBluetooth error 6
(`connectionTimeout`); error 15 is reported as `encryptionTimedOut`. Both retain their exact domain,
numeric code, symbolic name, message, wall-clock timestamp, and monotonic commissioning timestamp.

If CoreBluetooth reports `peerRemovedPairingInformation`, the app discards the restored central
session once and immediately scans again with a clean, non-restored central. This prevents an old
restoration object from repeatedly terminating an otherwise valid post-forget connection.

Connections reuse the iOS-managed encrypted bond plus one app-managed reconnect policy. The app
retries the saved peripheral at 1, 2, 4, 8, 15, and then 30-second intervals until the user
explicitly disconnects. The CoreBluetooth system auto-reconnect option is intentionally disabled:
physical testing showed that it could reconnect immediately while the app's bounded retry was
pending, creating overlapping connect attempts and a rapid timeout cycle. Ordinary radio loss,
app backgrounding, and gateway restarts still do not require removing the saved BLE bond.
An explicit reconnect intent survives a temporary Bluetooth powered-off/reset state: when the radio
returns, the app retrieves the handshake-verified UUID first and only then falls back to a VHOS
service scan. `Disconnect` is the only control that clears that intent.

CoreBluetooth state restoration remains enabled under a versioned restoration identifier, but a
service match alone is not enough to resume a restored object. The app promotes only the peripheral
identifier that delivered a decoded, CRC-valid VHOS handshake. On a later launch, a connected or
connecting object inherited from the previous app process is always cancelled before reuse. Its
disconnect callback is drained, while the verified identifier and iOS bond are retained; the app
then opens one fresh physical link with a current-process delegate, CCCD, and contract. Unverified,
older, or additional restored objects use the same bounded cleanup boundary. The first
`Connect` after a restoration-identifier epoch change starts from a fresh app selection while
retaining the iOS-managed bond. If CoreBluetooth supplies an incomplete object in the current
epoch, the app automatically retires it before scanning, without requiring Settings → Forget This
Device. During retirement the control reads `Finishing…` and cannot start a duplicate session. A
four-second cleanup watchdog either observes the exact object become disconnected or rebuilds the
central only after cancelling that stale object; the saved bond and verified identifier remain.

Before a normal scan, the app may also adopt one coherent system-connected peripheral exposing the
VHOS service. Every callback is accepted only from the exact selected `CBPeripheral` object, so an
older restored wrapper cannot overwrite the active connection. Each physical adoption also receives
a link-scoped delegate epoch; service, characteristic, notification, value, and write callbacks must
match both that epoch and the currently connected object. Central callbacks must come from the exact
current manager, and replacement managers rotate and persist a unique restoration identifier before
they become active. A GATT discovery watchdog retires an unresponsive link and starts a fresh
service-filtered scan only after disconnection is confirmed. Reconnect backoff resets only after the
versioned VHOS handshake succeeds, not after a transient radio link.

Each physical link issues one encrypted CCCD request for the framed evidence stream. Pairing-pending
state suppresses duplicate requests on that link; health and OTA status remain logical frame types
multiplexed over the same stream. A failed secure subscription closes the link before a later
physical connection may make its own single request. Cached `isNotifying` state never proves the
current link: a current-epoch CCCD callback is required, and a 15-second enable watchdog retires a
link whose callback never arrives. A later notification-disabled callback also closes that exact
session instead of leaving a physically connected but unusable transport.

After the encrypted stream is ready, the app allows three link-session-bound, idempotent handshake
requests. Each request first has a two-second write-progress/final-ACK deadline. Its separate
two-second response deadline begins only after the final `.withResponse` write callback succeeds,
so attempt N+1 can never queue behind unfinished chunks from attempt N. A missing write ACK closes
that exact stale link without queuing another request. A decoded handshake cancels both phases. If
all three acknowledged requests receive no response—even if health frames continue to arrive—the
app marks the contract `DEGRADED`, closes that physical link, and waits for an explicit `Reconnect`;
it does not create a second session beside the unresponsive one.

The connection controls reflect that lifecycle. `Connect` appears only when no handshake-verified
gateway has been saved. `Reconnect` first retrieves that known CoreBluetooth UUID and connects it,
then falls back to the VHOS service scan if retrieval returns nothing. `Cancel` stops scanning,
physical-link negotiation, contract validation, or automatic reconnect. `Connected` is disabled
until a CRC-valid handshake has made the application session healthy. A separate `Disconnect`
tears down that healthy link and disables automatic reconnect while preserving both the iOS bond
and the handshake-verified peripheral identifier. The commissioning trace records that user intent
before any connection state is cleared.

## Physical acceptance: iOS `0.3.2 (8)` with gateway `0.1.0-dev.26`

The August 18 attached-device run in `/tmp/vhos-dev24-acceptance.IbXL3W/` exercised the saved
identity and automatic-loss paths without a Pair sheet or **Forget This Device**:

| UTC time | Evidence | Product state |
| --- | --- | --- |
| `00:18:17.027` | `KNOWN_GATEWAY_RECONNECT` and direct `CONNECT_REQUEST` | The verified saved UUID was retrieved before service-scan fallback |
| `00:18:17.536` | `LINK_CONNECTED link_session=1` | Physical BLE became active; this alone was still not application verification |
| `00:18:17.822` | `SUBSCRIBE_READY ... link_session=1` | The current physical epoch confirmed its encrypted stream CCCD |
| `00:18:17.992` | `HANDSHAKE_VERIFIED firmware=0.1.0-dev.26` | The UI could truthfully converge from Verifying to Connected |
| `00:18:18.188` onward | recurring `HEALTH_DECODED` | Live framed application data remained continuous until the forced reset/loss |
| `00:20:34.188` | exact `CBError.connectionTimeout` | The lost gateway was recorded as transport loss, not app crash or OBD failure |
| `00:20:34.194` | `RECONNECT_SCHEDULED attempt=1` | Automatic reconnect intent remained active |
| `00:21:25.797` | `LINK_CONNECTED link_session=2` after the gateway returned | Recovery created a distinct physical-link epoch on the saved identity |
| `00:21:26.026` | `SUBSCRIBE_READY ... link_session=2` | The recovered link proved its own CCCD rather than trusting cached state |
| `00:21:26.215` | `HANDSHAKE_VERIFIED firmware=0.1.0-dev.26` | The recovered application contract verified on attempt 1 |
| `00:21:26.365` onward | recurring health and capture-index traffic | Live application data and evidence synchronization resumed |

This run physically accepts known-UUID direct connect and one forced-reset automatic recovery. It
does not convert every documented control into a new physical pass. In particular, explicit
`Disconnect` was not tapped again on the final `0.3.2 (8)` build. Source review confirms that it
disables reconnect while retaining the saved identifier and iOS-managed bond, and an earlier
`dev.23` physical run observed that behavior followed by a no-Pair saved-ID `Reconnect`. Repeating
that manual sequence on `0.3.2 (8)` remains a regression check.

## Fault-injection acceptance: iOS `0.3.3 (9)` with gateway `0.1.0-dev.29`

The real-device harness now alternates ESP32 hard resets and iPhone app process death, then requires
a new physical link, CRC-valid handshake, and a configurable number of live health frames inside
one recovery budget. It does not use simulator data as its oracle.

The strict six-cycle run completed three gateway resets and three connected app relaunches. All six
cycles verified firmware dev29 and produced five subsequent health frames inside 55 seconds. The
run also exercised an incidental -96 dBm scan, existing-bond encryption, CoreBluetooth inherited-
link retirement, controller reason 531 cleanup, and supervision-timeout recovery. It required no
Pair sheet, Settings removal, NVS erase, or manual Connect.

The subsequent one-command pre-car run exposed why an incidental weak-RF pass must not define a
release condition: one mixed cycle timed out, and a focused rerun measured the gateway at -90 dBm.
The app and harness now measure the exact connected-link epoch and require -80 dBm by default. With
the bench restored to -62 through -68 dBm, the RSSI-qualified quick profile passed its ten-frame
soak, ESP reset, and app-process-death recovery, with exact dev29 handshakes and all required health
frames. The test plan retains both the failed discovery and stopped passing evidence hashes.

See the [fault-injection test plan](../docs/development/BLE-FAULT-INJECTION-TEST-PLAN.md) for the
command, exact recovery latencies, stopped-log hashes, failure found by the first strict run, true
power-cut hardware boundary, and the remaining vehicle/OTA/soak matrix. The capture-export incident
and dev28/dev29 corrections are recorded in the
[capture-sync incident](../docs/development/BLE-CAPTURE-SYNC-DISCONNECT-INCIDENT-2026-08-18.md).

The original August 16 commissioning record is documented in
[`BLE-RESTORATION-INCIDENT-2026-08-16.md`](../docs/development/BLE-RESTORATION-INCIDENT-2026-08-16.md).
The exact `dev.20` security timeout, disconnect-reason decoding, `dev.22` pre-`CONNECT` restore
ordering, `dev.23` restored-state correction, and final `0.3.2 (8)` / `dev.26` recovery evidence are
documented in
[`BLE-PAIRING-RESET-INCIDENT-2026-08-17.md`](../docs/development/BLE-PAIRING-RESET-INCIDENT-2026-08-17.md).

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

The fault-injection harness is separate and exits nonzero unless every selected fault reaches a
fresh verified contract plus live health:

```bash
uv run --script ios/tools/vhos_ble_fault_injection.py \
  --iphone <CoreDevice-ID> \
  --serial /dev/cu.usbserial-0001 \
  --cycles 6 \
  --faults esp-reset,app-relaunch \
  --timeout 55 \
  --health-frames 5 \
  --minimum-rssi -80
```

The normal pre-car gate wraps contracts, corruption/replay tests, Swift tests, an ESP-IDF build,
a signed iPhone build/install, stream soak, reset storms, app-death storms, and mixed recovery into
one evidence summary:

```bash
python3 ios/tools/vhos_precar_acceptance.py \
  --profile standard \
  --iphone <CoreDevice-ID> \
  --serial /dev/cu.usbserial-0001 \
  --minimum-rssi -80
```

Use `quick` while iterating and `endurance` for release-candidate stress. Optional true USB rail
cuts require `--include-power --usb-hub <location> --usb-port <port>` and compatible per-port
switching hardware. The default RF floor fails a marginal bench before its timeouts can be mistaken
for firmware defects; lower it only for a separately labeled range/recovery experiment. See the
[fault-injection test plan](../docs/development/BLE-FAULT-INJECTION-TEST-PLAN.md)
for exact profile counts, failure oracles, evidence layout, and claims that remain car-only.

## Gateway contract UUIDs

| Role | UUID |
| --- | --- |
| VHOS service | `33613EB3-FFCA-42D1-83FA-A18F12B3F123` |
| Command write | `B3D3279B-0244-4D54-A2AB-A1AB47A5FC0A` |
| Evidence stream notify | `265B90C0-A600-4659-BBBD-5CDA411C49CC` |
| Health/control notify | `BCB5699A-A9B4-49B8-B69B-D2DFF19B41A9` |
| OTA status notify | `18D21F8E-D190-4DB3-923C-27BBFC355874` |

The firmware implementation must treat these UUIDs and the `VHOS` frame header as versioned public contracts.
