# iPhone-to-ESP32 BLE pairing reset incident — 2026-08-17

Status: **open; failure isolated to BLE encryption/bond completion**

Affected gateway: `VHOS-4R-OBD-B08D14`  
Gateway ID: `esp32-9454c5b08d14`  
ESP32 base MAC: `94:54:c5:b0:8d:14`  
Current firmware candidate: `0.1.0-dev.20`  
Current firmware GATT/bond epoch: `6`  
Current BLE identity: `ec:01:f9:c3:78:ad`  
iOS Core Bluetooth restoration generation: `v3`

## Executive summary

The iPhone can find the correct VHOS gateway, open a BLE link, enumerate the versioned VHOS
service, and enumerate all four expected characteristics. Enabling the encrypted outbound stream
then triggers or resumes iOS pairing. The UI may temporarily show the service, command channel,
and notification channels as ready or enabling. The secure session does not remain established.

The latest two-sided trace shows the exact failure boundary:

1. iOS finds the current gateway identity.
2. Core Bluetooth connects.
3. The VHOS service is discovered.
4. All four characteristics are discovered.
5. iOS requests the one encrypted notification subscription.
6. The ESP32 does not report successful encryption.
7. The ESP32 reports encryption status `13`.
8. The controller ends the link with supervision-timeout reason `520`.
9. Both sides automatically reconnect, returning the UI to `CANDIDATE` / `VALIDATING`.

This is not currently an OBD-II failure, CAN decoder failure, ESP32 reboot, Wi-Fi/SoftAP problem,
or confirmed iOS application crash. The transport never reaches the versioned application
handshake in the failing run, so every downstream status must remain unverified or blocked.

## User-visible sequence

The observed cycle has appeared in several forms as the commissioning implementation evolved:

```text
Gateway scan: CANDIDATE
Gateway BLE link: VALIDATING
Discovery signal: PASS
VHOS BLE service: NOT FOUND / WAIT
```

followed in better runs by:

```text
VHOS BLE service: DISCOVERED
Reliable command channel: READY
Evidence stream notifications: ENABLING or SUBSCRIBED
Health stream notifications: ENABLING or SUBSCRIBED
OTA status notifications: ENABLING
Frame CRC and decode: 0 VALID / WAIT
Sequence continuity: NO DATA / WAIT
```

iOS can then display one system pairing prompt:

```text
“VHOS-4R-OBD-B08D14” would like to pair with your iPhone.
```

After Pair is selected, the UI can briefly advance, then the link closes and the automatic
reconnect path returns the screen to `CANDIDATE` / `VALIDATING`. The apparent reset is the app
truthfully reflecting a new BLE session; it is not evidence that OBD-II or the vehicle bus caused
the reset.

The most recent screenshot shows all three logical outbound channels at `ENABLING`. In dev20 they
are three logical frame types carried over one physical notification characteristic and one CCCD.
The UI labels remain separate because evidence, health, and OTA are different contracts even
though their encrypted transport is multiplexed.

## Latest verified evidence

### iPhone commissioning trace

The dev20 physical-device run produced:

```text
CENTRAL_STATE state=powered on scan_requested=true
RESTORED_CONNECT_TIMEOUT ... recovery=cancel-and-scan
SCAN_START mode=service-filter
GATEWAY_MATCH name=VHOS rssi=-70
LINK_CONNECTED ... source=did-connect state=2
SERVICES_DISCOVERED source=callback uuids=33613EB3-FFCA-42D1-83FA-A18F12B3F123
CHARACTERISTICS_DISCOVERED source=callback ... count=4
SUBSCRIBE_REQUEST uuid=265B90C0-A600-4659-BBBD-5CDA411C49CC
LINK_DISCONNECTED ... domain=CBErrorDomain code=6
message=The connection has timed out unexpectedly.
RECONNECT_SCHEDULED attempt=1 delay=1
LINK_CONNECTED ... source=did-connect state=2
```

The first restored peripheral in this trace belonged to the prior identity. The app timed it out,
closed it, performed a service-filtered scan, and selected the new dev20 identity. Stale restoration
therefore did not prevent discovery of the current gateway in this run.

### ESP32 serial trace for the same run

```text
BLE_CONN_PARAMS_INITIAL interval_units=24 latency=0 supervision_units=72
BLE_CONN_PARAMS_REQUEST interval_units=24-40 latency=0 supervision_units=600
IPHONE_LINK_CONNECTED handle=0
BLE_MTU value=247
BLE_CONN_UPDATE status=0
BLE_CONN_PARAMS_ACTIVE interval_units=40 latency=0 supervision_units=600
BLE_SUBSCRIBE handle=8 notify=0
BLE_ENCRYPTION status=13
BLE_SUBSCRIBE handle=8 notify=0
IPHONE_LINK_DISCONNECTED reason=520
VHOS_BLE_ADVERTISING name=VHOS-4R-OBD-B08D14 short_name=VHOS
IPHONE_LINK_CONNECTED handle=0
BLE_CONN_UPDATE status=0
BLE_CONN_PARAMS_ACTIVE interval_units=40 latency=0 supervision_units=600
```

Important interpretations:

- `BLE_MTU value=247` proves ATT negotiation worked before the failure.
- `BLE_CONN_UPDATE status=0` proves the requested stable connection parameters were accepted.
- `BLE_ENCRYPTION status=13` is a raw NimBLE security-manager failure result. Its more specific
  cause must be established with added security-manager event instrumentation; the report does not
  guess beyond the observed value.
- disconnect reason `520` is NimBLE's host-encoded controller reason for HCI connection
  supervision timeout `0x08`.
- advertising resumed, and a new BLE link opened. There is no panic, Guru Meditation, abort, or
  reboot in the trace.

### Application process evidence

After the attached console returned exit code `0`, the iPhone process list still contained:

```text
Vehicle Health OS
```

The console can detach when the app changes foreground state. That event must not be reported as a
crash without a nonzero termination, crash report, or missing process. The current incident is a
BLE session failure.

## What has been proven to work

The following layers have independent physical evidence:

- the correct classic ESP32 is attached and identifiable;
- the firmware boots and passes its self-test;
- CAN is initialized in listen-only mode;
- Wi-Fi and SoftAP remain disabled by default;
- the canonical device name is configured;
- the versioned VHOS service is advertised;
- iPhone service-filtered scanning finds the gateway;
- Core Bluetooth opens a physical link;
- ATT MTU negotiation completes;
- the requested connection interval and timeout are accepted;
- the expected service UUID is discoverable;
- all four expected characteristics are discoverable; and
- the app attempts only the single encrypted outbound-stream CCCD in dev20.

A dev19 fresh-pairing run also previously achieved:

```text
SUBSCRIBE_READY
HANDSHAKE_VERIFIED firmware=0.1.0-dev.19
HEALTH_DECODED
CAPTURE_INDEX
CAPTURE_SYNC_COMPLETE
```

That run proves the multiplexed frame path, command handshake, decoding, and capture sync can work.
It did not close the incident because a subsequent cold app launch restored an incomplete or stale
Core Bluetooth object and could not reproduce a durable secure session.

## What has not been proven in the current dev20 run

The current run has not yet produced:

- `BLE_ENCRYPTION status=0`;
- a notification callback with the stream enabled;
- `SUBSCRIBE_READY` for the current dev20 identity;
- a dev20 handshake response;
- a CRC-valid dev20 health frame;
- continuous dev20 sequence numbers;
- a successful cold app relaunch;
- a successful ESP32 reboot/reconnect with the saved bond; or
- radio-loss recovery without another pairing prompt.

No downstream OBD-II, protocol-test, experiment, evidence-export, or OTA state may be promoted
until those transport gates pass.

## Failure boundary and current root-cause assessment

### Confirmed failure boundary

The current failure occurs after GATT discovery and when the encrypted notification CCCD is being
enabled. The secure link does not reach a durable encrypted-and-subscribed state before the
supervision timeout.

### Leading unresolved causes

These are hypotheses to test, not conclusions:

1. iOS and NimBLE disagree about the current bond after repeated firmware identity/schema
   migrations, so the new security procedure does not finish.
2. the iOS pairing sheet is accepted too late, dismissed by an app/foreground transition, or its
   result is not reaching the active Core Bluetooth peripheral;
3. a restored old peripheral and the current new peripheral overlap long enough to interfere with
   commissioning state;
4. the notification retry path reissues an encrypted CCCD request while pairing is still pending;
5. NimBLE has a security-manager/key-distribution failure that is currently collapsed into raw
   encryption status `13`; or
6. the link remains connected but idle during pairing long enough to hit the six-second negotiated
   supervision timeout.

Only additional synchronized iOS and NimBLE security events can distinguish these cases.

## Changes already made

### Firmware

The current dev20 candidate includes:

- one canonical name: `VHOS-4R-OBD-B08D14`;
- a persisted random-static BLE identity;
- a versioned GATT/bond epoch;
- bond clearing plus one identity rotation when the firmware schema epoch changes;
- no identity rotation on ordinary reboots;
- Secure Connections with Just Works (`NoInputNoOutput`, bonding enabled, MITM disabled);
- encrypted command writes and encrypted notification access;
- a requested 30–50 ms connection interval, zero peripheral latency, and six-second supervision
  timeout;
- one encrypted notification characteristic for all framed evidence, health, and OTA output;
- health traffic gated until an encrypted application command is received;
- connection epochs that prevent queued chunks from a prior link being sent on a new link;
- TX queue and subscription reset on connect/disconnect; and
- SoftAP disabled and CAN transmit prevented by listen-only mode.

The GATT/bond epoch is currently `6`. The application-only flash preserved the normal NVS,
capture, OTA, and configuration partitions; the firmware intentionally migrated only its
namespaced BLE identity/bond compatibility state.

### iOS

The current iOS candidate includes:

- exactly one process-wide `CBCentralManager` owner;
- canonical gateway identity filtering;
- rejection of unrelated generic `FEE0` devices;
- stale callback rejection;
- explicit `CANDIDATE`, `VALIDATING`, and `VERIFIED` states;
- automatic stale-GATT disconnection and rescan without asking for Settings cleanup;
- connected-peripheral adoption only when Core Bluetooth reports `.connected`;
- cached service/characteristic adoption for coherent restored peripherals;
- Core Bluetooth restoration identifier generation `v3`;
- one physical stream notification request rather than three encrypted CCCD writes;
- logical evidence/health/OTA readiness derived from that stream subscription;
- bounded encryption/notification retry handling;
- handshake gating until the command channel and stream are ready; and
- the Disconnect control disabled during connection validation to avoid user/state-machine races.

## Why “Forget This Device” is not the product solution

Manual removal can clear an inconsistent bond during development, but requiring it after every
disconnect is not acceptable. Normal users must be able to:

- pair once;
- leave and return to the vehicle;
- relaunch the app;
- reboot or update the gateway; and
- recover after temporary radio loss

without opening iOS Settings.

The intended compatibility mechanism is firmware GATT/bond epoch migration plus iOS restoration
and stale-session recovery. `Forget This Device` remains a last-resort diagnostic action for a
confirmed corrupted system bond, not an ordinary workflow or acceptance step.

## Next diagnostic implementation

The next change should improve evidence before changing security policy again:

1. log every NimBLE passkey/security action, repeat-pairing event, encryption-change event,
   security level, peer identity, and bond-store count with a connection epoch;
2. log the exact iOS `didUpdateNotificationState` error domain/code and every retry against the
   active peripheral identifier;
3. ensure there is at most one encrypted CCCD request in flight and do not issue another while a
   pairing result is pending;
4. correlate iPhone monotonic timestamps, ESP32 uptime, Pair-button time, and disconnect time;
5. verify whether encryption status `13` occurs before or after the user accepts Pair;
6. if the bond is rejected, delete only the exact peer security record through the documented
   repeat-pairing recovery, then retry once;
7. do not rotate identity, erase all NVS, weaken encryption, or enable unencrypted production
   commands merely to make the indicator green; and
8. preserve the single-stream transport while the security issue is isolated.

## Acceptance criteria

The incident is closed only when one physical iPhone and this physical ESP32 complete all of the
following without Settings -> Forget This Device:

### Fresh commissioning

```text
correct canonical gateway selected
-> BLE link connected
-> VHOS service discovered
-> four characteristics discovered
-> exactly one stream subscription requested
-> one Pair approval at most
-> BLE_ENCRYPTION status=0
-> stream subscription enabled
-> HANDSHAKE_VERIFIED firmware=0.1.0-dev.20 or later
-> recurring CRC-valid health frames
-> continuous frame sequence
```

### Durability

- foreground connection remains verified for at least ten minutes;
- app background/foreground does not trigger a new pairing sheet;
- a cold app terminate/relaunch restores or reconnects and verifies automatically;
- an ESP32 power cycle reconnects and verifies automatically;
- a temporary out-of-range event reconnects with bounded backoff;
- only one local and one peer security record are retained for the active identity; and
- no panic, reset loop, notification storm, or overlapping connection loop occurs.

### Safety and truthfulness

- CAN remains listen-only throughout commissioning;
- SoftAP remains disabled unless explicitly and securely activated;
- no arbitrary CAN transmit surface is introduced;
- OBD-II remains `UNVERIFIED` until independent bus/protocol evidence exists;
- missing health fields remain unavailable rather than being replaced with zero; and
- application exit, BLE disconnect, and ESP32 reset are reported as separate facts.

## Relationship to earlier incidents

This report continues, but does not replace:

- [BLE restoration incident — 2026-08-16](BLE-RESTORATION-INCIDENT-2026-08-16.md)
- [BLE gateway identity incident — 2026-08-16](BLE-GATEWAY-IDENTITY-INCIDENT-2026-08-16.md)
- [BLE GATT schema migration and automatic iPhone recovery](BLE-GATT-SCHEMA-MIGRATION.md)

Those reports established identity selection, restoration, and schema migration behavior. This
incident narrows the remaining failure to secure pairing/encryption completion after valid GATT
discovery.

## Current conclusion

The system is no longer failing at gateway discovery or GATT enumeration. The immediate blocker is
durable BLE security establishment. The last verified failing event is ESP32 encryption status
`13`, followed by a supervision timeout and automatic reconnect. The correct next milestone is a
synchronized security-manager trace that ends in `BLE_ENCRYPTION status=0`, one active stream CCCD,
a verified dev20-or-later handshake, recurring health evidence, and successful cold reconnect.
