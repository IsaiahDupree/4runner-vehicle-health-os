# BLE test-close transfer disconnect — 2026-08-24

Status: field failure sequence confirmed; iOS containment implemented; exact ESP32 failure site still requires synchronized UART/reset evidence.

Affected field baseline:

- iOS `0.3.25` (`32`);
- gateway firmware `0.1.0-dev.34`;
- gateway `esp32-9454c5b08d14` / advertised name `VHOS-4R-OBD-B08D14`.
- CoreBluetooth peripheral identifier `52B37B97-0F8D-D862-9303-57202776396C` for this iPhone.

This incident extends the earlier BLE capture-sync disconnect incident dated 2026-08-18.

## Executive finding

The BLE application contract remained healthy for the complete 58-second selector test.
At `00:50:06Z`, the test ended and retained-log transfer began.
After 105 retained records arrived, CoreBluetooth reported `CBError.unknown` 5.8 seconds later.
The persisted transfer phase then re-entered the same bulk path after later relaunches and
reconnections.

This sequence explains the two field symptoms.
One is needing to power-cycle the gateway for recovery.
The other is a failure triggered by closing the test.

Afterward, advertisements and physical links still appeared at usable RSSI. VHOS service
enumeration timed out. Replacing the iOS central manager did not repair the peripheral state.

## Source evidence

The copied field return is under:

```text
build/device-data/2026-08-24-field-return-2319/Application Support
```

Decisive records:

```text
VHOSDiscoveryEvidence/v1/test-run-drafts.ndjson
VehicleHealthOS-Evidence/BLEConnectionTrace/ble-connection-1787618888740-DED38F9F-000.ndjson
```

Direct UTC chronology:

- `00:48:36.355`: dev34 handshake verified.
- `00:49:08`: selector run became `ACTIVE`, session `4182083257`, sequence `17936`.
- `00:49:08.713` through `00:50:04.829`: fresh health frames continued.
- Observed frames advanced from 18,003 to 46,924 during that interval.
- `00:50:06`: the run became `ENDED`, last sequence `47720`.
- `00:50:06.862`: `CAPTURE_TRANSFER_REQUESTED` recorded pause, transfer, and auto-resume mode.
- `00:50:07.155`: the index reported 3,320 current and 128 previous records.
- `00:50:10.326` through `00:50:12.257`: chunks advanced through offset 100.
- `00:50:12.690`: the physical link ended with `CBError.unknown`.
- `00:50:12.692`: the client recorded 105 records and automatic recovery.
- `00:50:44.014`: another physical link formed at `-67 dBm`.
- `00:51:06.235`: VHOS service enumeration timed out.
- `00:51:16.160`: another physical link formed at `-64 dBm`.
- `00:51:28.235`: a second timeout triggered central-manager replacement.

Later cycles failed near offsets 90, 105, and 125. Another app start recorded the durable phase as
`downloading`, proving the same bulk path was re-entered after process restoration.

The gateway `dropped` counter is the firmware sum of TWAI missed and overrun counts.
It is acquisition-quality evidence, not an iOS sequence-gap count.

## Confirmed facts

- Health frames continued through the test.
- The terminal transition began a nonempty retained-record transfer.
- The old client preserved the bulk phase across later app sessions.
- Advertising and physical BLE links remained possible after failure.
- VHOS GATT enumeration then timed out despite usable signal strength.
- Replacing the iOS central manager did not clear the peripheral condition.
- Power-cycling the ESP32 restored the observed workflow.

## Inference still awaiting UART proof

The retained-record path is placing the dev34 GATT server in a state that cannot complete a new
service-enumeration epoch. Notification backpressure, task starvation, buffer ownership, or a host
reset are plausible boundaries. The iPhone record cannot identify the failing firmware call.

The next firmware run must retain synchronized UART evidence for:

- ESP-IDF reset reason and boot identity;
- NimBLE disconnect reason and connection epoch;
- worker queue depth and notification return codes;
- notification credits and backpressure;
- heap and stack high-water marks; and
- recorder state transitions.

Until then, the supported conclusion is that bulk transfer precipitates the failure. A particular
NimBLE or filesystem instruction is not yet proven defective.

## Corrected product behavior

Test lifecycle and evidence transfer are now independent.

- Begin creates an app-local append-only run.
- Markers append with exact source lineage.
- End or Abort changes only the app-local run state.
- End or Abort never starts retained-record transfer or recorder control.
- Passive recording remains active after the terminal transition.
- Automatic index refresh reports inventory only.
- Bulk transfer begins only from the explicit Evidence or Capture Review action.
- A partial checkpoint changes the action label to **Resume saved log transfer**.

A saved `downloading` intent is cleared at app launch. A saved `resuming` intent is reduced to one
resume-only confirmation. History incompleteness is persisted independently, so a completed
download awaiting only recorder confirmation does not advertise a redundant full-history retry.
Neither state initiates scanning, connection, or bulk transfer. An actually incomplete durable
record offset remains available for a later explicit owner action, while the resume-only state can
send only the small recorder-resume command after the owner starts a normal connection.

If the physical link ends during manual history offload, the active bulk task and downloading
phase are cleared. The checkpoint remains inert and owner-triggered. If every record was already
copied and only recorder resume remains, that exact resume-only state is preserved. Ordinary BLE
reconnection is independent of history transfer; no bulk-read retry loop survives the loss.

`CaptureSyncPolicy.permitsAutomaticHistoryRecovery` is deliberately `false`. This is a product
contract, not merely a pacing constant.

## Field procedure

1. Verify the VHOS application contract.
2. Record test markers while the gateway recorder remains active.
3. Test completion remains app-local.
4. Additional tests may use the same healthy link.
5. After collection, use the explicit saved-log action in Evidence once.

If an explicit copy is interrupted, automatic work ends. A later connection and a later saved-copy
continuation are independent owner actions. Preserve the phone trace if service enumeration
repeatedly times out. Power cycling is a recovery action for the reproduced gateway state, not an
acceptable normal connection procedure.

## Closure acceptance

- Twenty Begin, marker, End, and Abort cycles emit zero capture-control commands.
- App launch clears saved `downloading` intent and preserves at most a resume-only confirmation,
  without scanning or connecting.
- Forced loss at offsets 0, 90, 105, 125, and end-of-file never rearms bulk work.
- Forced loss clears bulk tasks while retaining the inert checkpoint and, only when applicable,
  the resume-only confirmation.
- Normal BLE reconnection has no dependency on history-transfer state.
- No automatic bulk-read loop survives launch or link loss; resume-only work cannot read history.
- The saved offset survives app termination and is used only after owner action.
- A completed download followed by relaunch never exposes **Resume saved log transfer**.
- An interrupted download retains the explicit incomplete-checkpoint action without auto-starting.
- Twenty nonempty transfers on the next firmware retain UART evidence and never strand GATT.
- Electrical loss recovers without deleting the iOS bond.
- BLE trace and gateway boot identity enter the private evidence outbox.

The iOS change contains the automatic loop. It does not replace the firmware stress and soak
evidence needed to close the peripheral-side defect.
