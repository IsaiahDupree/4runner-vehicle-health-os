# iPhone-to-ESP32 BLE pairing and restored-session incident — 2026-08-17

Status: **mitigated and physically recovered with iPhone app `0.3.2 (8)` plus firmware `0.1.0-dev.26`; saved-identity direct connect and one forced-reset automatic recovery passed without a Pair sheet or manual Forget; full durability matrix remains open**

| Context | Value |
| --- | --- |
| Affected gateway | `VHOS-4R-OBD-B08D14` |
| Gateway ID | `esp32-9454c5b08d14` |
| ESP32 base MAC | `94:54:c5:b0:8d:14` |
| Firmware series diagnosed and accepted | `0.1.0-dev.20` through `0.1.0-dev.26` |
| Final physically exercised iPhone build | `0.3.2 (8)` |
| Firmware GATT/bond epoch | `6` |
| Recorded random-static BLE identity | `ec:01:f9:c3:78:ad` |
| iOS Core Bluetooth restoration generation | `v3` |
| ESP-IDF baseline | `v5.5.3` |
| ESP-NimBLE source revision | `039d2d62ed97fed632827fd51294f04068b2ca60` |

## Executive summary

The original screen cycle was real but combined several different layers:

```text
advertisement candidate
-> physical BLE link
-> GATT service and characteristics
-> pairing or encrypted-bond restore
-> notification subscription
-> VHOS application exchange
-> CRC-valid health data
```

The failing `dev.20` run reached GATT discovery but did not finish its Bluetooth Security Manager
procedure. The exact ESP-NimBLE result was `BLE_HS_ETIMEOUT` after the stack's 30-second security
timer. The controller later reported connection-supervision timeout. Those two events were not an
OBD-II failure, CAN failure, ESP32 reboot, or app crash.

The next physical iterations isolated two separate commissioning problems:

1. `dev.21` proactively initiated security after connection. A fresh iPhone pairing completed in
   approximately 4.8 seconds, proving that the selected security policy and both implementations
   are interoperable when the pairing exchange advances.
2. `dev.22` restored encryption and the saved stream subscription, but ESP-NimBLE delivered those
   restore events before its GAP `CONNECT` callback. The connection handler then cleared the valid
   pre-`CONNECT` state, so the application data path appeared to disappear even though the bond had
   restored correctly.
3. `dev.23` preserves the authoritative encrypted/subscribed state across that callback ordering.
   A physical cold app launch adopted the saved peripheral and began decoding health in about one
   second. Health continued for more than 92 seconds with no Pair sheet or disconnect, crossing the
   old 30-second failure boundary three times.
4. The state-aware iPhone build then bounded an unresponsive restored command path to three
   idempotent handshake requests, closed only that physical link, and exposed **Reconnect**. The
   operator's Reconnect action retrieved the previously verified Core Bluetooth UUID, reused the
   existing bond without a Pair sheet, connected in about 0.5 seconds, and directly logged
   `HANDSHAKE_VERIFIED firmware=0.1.0-dev.23` on its first request. A subsequent explicit
   Disconnect and Reconnect repeated the same saved-identity, no-Pair workflow.
5. The final `0.3.2 (8)` / `dev.26` run retrieved the handshake-verified Core Bluetooth UUID at
   `00:18:17.027Z`, connected at `00:18:17.536Z`, confirmed the one stream CCCD at
   `00:18:17.822Z`, and verified `0.1.0-dev.26` at `00:18:17.992Z`. Health then arrived
   continuously until a forced ESP32 reset/loss produced the exact Core Bluetooth timeout at
   `00:20:34.188Z`. The app scheduled automatic reconnect, retained the saved identity, and after
   the device returned established `link_session=2` at `00:21:25.797Z`; CCCD, handshake, and
   recurring health all resumed by `00:21:26.365Z` without a Pair sheet or Settings action.

This closes the immediate diagnosis and provides direct evidence for the corrected restored data
path plus one automatic firmware-reset recovery. It does not yet close the ten-minute,
background/foreground, repeated power-cycle/radio-loss, Cancel-during-negotiation, and endurance
acceptance gates.

## Evidence provenance and claim boundaries

| Evidence | Provenance | What it proves |
| --- | --- | --- |
| `dev.20` ESP32 serial trace | `/tmp/vhos-dev20-acceptance.FVImb1/esp32.log` | Exact connection, security-timeout, disconnect, and advertising chronology |
| `dev.19` control trace | `/tmp/vhos-dev19-acceptance.bKsj2V/esp32.log` | The same Just Works/Secure Connections policy and multiplexed stream can complete encryption and notify |
| Earlier reconnect traces | `/tmp/vhos-dev16-acceptance.OOlsPS/` and `/tmp/vhos-sequential-acceptance.T6oulD/` | Bond reuse can encrypt rapidly; reason `531` and stale-session races are distinct from reason `520` |
| `dev.21` fresh-pair run | synchronized attached iPhone and ESP32 consoles | Fresh pairing completed in approximately 4.8 seconds after proactive security initiation |
| `dev.22` bonded-reconnect run | synchronized attached iPhone and ESP32 consoles | Encryption and stream subscription restored before GAP `CONNECT`; later state clearing suppressed the data path |
| `dev.23` restored-session run | attached iPhone console beginning `2026-08-17T23:20:07.319Z` | Saved peripheral adopted; recurring decoded health from `23:20:08.425Z` through after `23:21:39Z`; no Pair sheet or disconnect observed |
| `dev.23` state-aware reconnect run | synchronized iPhone and ESP32 consoles beginning `2026-08-17T23:29:43.191Z` | Restored health arrived while the application command path was stale; bounded handshake timeout exposed Reconnect; the saved UUID reconnected and directly verified `0.1.0-dev.23` |
| `dev.23` manual-control run | attached iPhone console at `2026-08-17T23:31:18.424Z` | Explicit Disconnect disabled automatic reconnect; the following user Reconnect reused the saved UUID, verified the handshake on attempt 1, and resumed health |
| `dev.23` application image | local physical-flash artifact | SHA-256 `664c502a513ca50f0c2b9cc984756ebc0e8e8eb6795ed1b323cdb1660bcdb08b` |
| `0.3.2 (8)` / `dev.26` direct-connect and forced-reset run | `/tmp/vhos-dev24-acceptance.IbXL3W/iphone-dev26-reconnect.log` plus the `esp32-dev26*.log` files in the same directory | Verified saved-UUID retrieval, direct physical link, current-link CCCD, `HANDSHAKE_VERIFIED firmware=0.1.0-dev.26`, continuous health, exact timeout after forced reset/loss, and complete automatic recovery as `link_session=2` |
| Final iPhone trace digest | `/tmp/vhos-dev24-acceptance.IbXL3W/iphone-dev26-reconnect.log` | 45,998 bytes; SHA-256 `a77c3d01ce76728456806a3abac58b61b9106e1ea7a2fbf45938bd6a7a985f47` after capture stopped |

The first `dev.23` excerpt directly contains `HEALTH_DECODED`, not a handshake line, so this report
keeps that first launch's restored-data claim separate from application-contract verification. The
later saved-identity reconnects directly logged `HANDSHAKE_VERIFIED firmware=0.1.0-dev.23` at
`23:29:53.138Z` and `23:31:20.344Z`, followed by recurring health and capture-index frames. Those
later traces prove the complete application path without converting an inference into evidence.

Temporary trace paths are development evidence, not durable product storage. Before final release,
the same acceptance run must be archived with the firmware package hash, app build identity,
iPhone/iOS identity, monotonic timestamps, and operator actions.

## Final `0.3.2 (8)` / `dev.26` physical chronology

| UTC time on 2026-08-18 | Event | Direct interpretation |
| --- | --- | --- |
| `00:18:17.027` | `KNOWN_GATEWAY_RECONNECT` then `CONNECT_REQUEST` for UUID `39D7D381-0ADE-BF9B-B132-E555F100D036` | The app retrieved the handshake-verified saved UUID before scanning and initiated one direct connection |
| `00:18:17.536` | `LINK_CONNECTED link_session=1` | Physical BLE connected about 0.51 seconds after retrieval |
| `00:18:17.822` | `SUBSCRIBE_READY ... enabled=true link_session=1` | The current physical-link epoch confirmed the single encrypted stream CCCD |
| `00:18:17.992` | `HANDSHAKE_VERIFIED firmware=0.1.0-dev.26` | The application contract, not merely the radio link, became verified |
| `00:18:18.188` through `00:20:27.787` | recurring `HEALTH_DECODED` | CRC-decoded application health remained continuous for the observed pre-reset interval |
| `00:20:34.188` | `LINK_DISCONNECTED ... CBErrorDomain code=6 ... connectionTimeout` | The forced ESP32 reset/loss became an exact transport timeout, not an app crash or OBD-II conclusion |
| `00:20:34.194` | `RECONNECT_SCHEDULED attempt=1 delay=1` | The app preserved reconnect intent and scheduled its bounded policy |
| `00:21:25.797` | `LINK_CONNECTED link_session=2` after the device returned | A new physical epoch was established on the same saved Core Bluetooth identity |
| `00:21:26.026` | `SUBSCRIBE_READY ... link_session=2` | The new epoch independently confirmed its CCCD; cached readiness was not reused as proof |
| `00:21:26.215` | `HANDSHAKE_VERIFIED firmware=0.1.0-dev.26` | The recovered application session verified on handshake attempt 1 |
| `00:21:26.365` onward | recurring `HEALTH_DECODED` and capture-index traffic | Live health and evidence synchronization resumed |

No Pair sheet appeared and the operator did not use **Forget This Device** during this final run.
That observation, together with the direct UUID trace, proves bond reuse for the exercised path.

The final build's explicit **Disconnect** control was not tapped again in this exact `dev.26` run.
Its contract is therefore recorded with honest evidence boundaries: source review confirms that it
clears reconnect intent while retaining the handshake-verified UUID and iOS-managed bond, and the
earlier `dev.23` physical run directly observed the same offline-then-Reconnect behavior. A final
`0.3.2 (8)` explicit-Disconnect tap remains a separate regression check, not a newly claimed
physical pass.

### State-aware control contract

- **Connect** is offered only when no handshake-verified gateway identifier is saved.
- **Reconnect** is offered when that verified identifier exists but its application session is
  offline; it retrieves the known UUID first and uses a service scan only as fallback.
- **Cancel** is offered during scanning, physical connection, CCCD setup, or handshake validation.
- **Finishing…** is disabled while the prior physical object is being retired, preventing rapid
  taps from creating overlapping sessions.
- **Connected** is disabled and shown only after current-link CCCD proof, a CRC-valid versioned
  handshake, and application data make the session healthy; a physical link alone remains
  **Verifying** / `ACTIVE`.
- **Disconnect** is a deliberate owner intent: it ends the session and disables automatic
  reconnect while preserving the iOS-managed bond and handshake-verified UUID. The next explicit
  **Reconnect** can therefore reuse the known identity without asking the owner to forget/pair
  again.

## Exact `dev.20` chronology

The relevant ESP32 events were:

| ESP32 uptime | Event | Interpretation |
| ---: | --- | --- |
| `31.402 s` | `IPHONE_LINK_CONNECTED handle=0` | Physical LE link opened |
| `31.560 s` | `BLE_MTU value=247` | ATT negotiation worked |
| `31.708 s` | `BLE_CONN_UPDATE status=0` | Requested connection parameters were accepted |
| `32.118 s` | first post-connect subscription activity | Security-sensitive GATT activity was underway |
| `62.726 s` | `BLE_ENCRYPTION status=13` | Security procedure expired |
| `81.565 s` | `IPHONE_LINK_DISCONNECTED reason=520` | Controller later declared connection supervision timeout |
| `81.822 s` | advertising restarted | Firmware stayed alive and recovered to discoverable state |
| `89.333 s` | next `IPHONE_LINK_CONNECTED` | Automatic reconnect opened a new physical link |

The interval from the first security-sensitive activity to status `13` is approximately
30.608 seconds. That matches the exact ESP-NimBLE Security Manager timeout of 30,000 ms, allowing
for scheduling and logging latency.

The iPhone trace for the same incident reached:

```text
GATEWAY_MATCH
LINK_CONNECTED
SERVICES_DISCOVERED
CHARACTERISTICS_DISCOVERED count=4
SUBSCRIBE_REQUEST uuid=265B90C0-A600-4659-BBBD-5CDA411C49CC
LINK_DISCONNECTED domain=CBErrorDomain code=6
RECONNECT_SCHEDULED
```

Core Bluetooth error `6` is `CBError.connectionTimeout`. It is not Core Bluetooth error `15`,
which is `CBError.encryptionTimedOut`. The app now records the exact error domain, number, symbolic
name, message, wall clock, monotonic timestamp, selected peripheral object, and link session.

## Exact status and disconnect decoding

### Encryption status `13`

`BLE_GAP_EVENT_ENC_CHANGE.status` is documented as a BLE **host** error code. In the exact
ESP-NimBLE revision used by ESP-IDF `v5.5.3`:

```c
#define BLE_HS_ETIMEOUT 13  /* Operation timed out. */
#define BLE_SM_TIMEOUT_MS (30000)
```

When an SM procedure expires, ESP-NimBLE emits:

```c
ble_gap_enc_event(proc->conn_handle, BLE_HS_ETIMEOUT, 0, 0);
```

Therefore `BLE_ENCRYPTION status=13` in `dev.20` is conclusively a host security-procedure timeout.
It is not HCI error `0x0d`, “key missing,” an unknown Security Manager reason, or an unexplained
generic failure.

Primary source references:

- [host error definitions](https://github.com/espressif/esp-nimble/blob/039d2d62ed97fed632827fd51294f04068b2ca60/nimble/host/include/host/ble_hs.h#L107-L108)
- [`ENC_CHANGE.status` contract](https://github.com/espressif/esp-nimble/blob/039d2d62ed97fed632827fd51294f04068b2ca60/nimble/host/include/host/ble_gap.h#L850-L869)
- [30-second SM timer definition](https://github.com/espressif/esp-nimble/blob/039d2d62ed97fed632827fd51294f04068b2ca60/nimble/host/src/ble_sm.c#L63-L67)
- [expired-procedure event and tainted-link note](https://github.com/espressif/esp-nimble/blob/039d2d62ed97fed632827fd51294f04068b2ca60/nimble/host/src/ble_sm.c#L2838-L2860)

The same SM source warns that a timed-out connection is tainted and should not be reused for
another SMP procedure without reconnecting. Firmware now terminates that link immediately instead
of waiting for a later controller timeout, and iOS does not keep resubmitting the encrypted CCCD on
the same failed link.

### Disconnect reason `520`

NimBLE encodes controller/HCI errors by adding base `0x200`:

```text
520 decimal = 0x208
0x208 - 0x200 = HCI 0x08
HCI 0x08 = connection supervision timeout
```

In `dev.20`, reason `520` arrived 18.839 seconds after the 30-second SM timeout. It is the later
controller report that the radio link stopped exchanging packets, not the initiating security
failure. The number by itself also does not prove that the configured supervision window was too
short; range, peer state, scheduling, and an already-stalled security exchange can all culminate in
the same controller reason.

### Disconnect reason `531`

Reason `531` belongs to a different path:

```text
531 decimal = 0x213
0x213 - 0x200 = HCI 0x13
HCI 0x13 = remote user terminated connection
```

From the ESP32's perspective, the iPhone side intentionally ended that link. This can be expected
when iOS retires a stale restored object, the user selects Disconnect, or Core Bluetooth fulfills
an app cancellation. It is not a supervision timeout, ESP32 crash, or proof that pairing failed.
Earlier traces that contain reasons `520` and `531` must not combine them into one “random reset.”

Primary source references:

- [NimBLE host error namespaces](https://github.com/espressif/esp-nimble/blob/039d2d62ed97fed632827fd51294f04068b2ca60/nimble/host/include/host/ble_hs.h#L164-L174)
- [HCI error values](https://github.com/espressif/esp-nimble/blob/039d2d62ed97fed632827fd51294f04068b2ca60/nimble/include/nimble/ble.h#L193-L219)

## Version-by-version diagnosis

| Candidate | Implemented change | Direct physical observation | Result |
| --- | --- | --- | --- |
| `0.1.0-dev.20` | One physical encrypted stream CCCD; logical evidence, health, and OTA frame types multiplexed over it; connection-epoch and queue reset protections | GATT discovery and MTU succeeded; security expired after 30 seconds; reason `520` followed | Exact security timeout isolated |
| `0.1.0-dev.21` | Security initiated once shortly after a new peripheral connection; decoded SM/HCI logging; bond/security snapshots; timed-out SMP link terminated | Fresh Pair approval completed encryption and bond establishment in about 4.8 seconds | Security policy and fresh commissioning proven interoperable |
| `0.1.0-dev.22` | Bonded reconnection exercised with proactive security and detailed restore logging | `ENC_CHANGE status=0` and restored stream subscription occurred before GAP `CONNECT`; later no live stream because `CONNECT` cleared those flags | Callback-order state-loss bug isolated; bond itself was healthy |
| `0.1.0-dev.23` | `CONNECT` preserves pre-callback encryption/subscription events, confirms encryption from the connection descriptor, skips duplicate security initiation on an already encrypted link, and retains connection-epoch gating | Cold iPhone launch adopted the saved peripheral and streamed health; state-aware cleanup then reconnected the exact saved UUID twice, directly verified the handshake on attempt 1, and resumed health without a Pair sheet | Restored data plus explicit saved-identity reconnect passed |
| `0.1.0-dev.26` with iOS `0.3.2 (8)` | Final state-aware connection controls, current-link callback epochs, bounded CCCD/handshake phases, saved-UUID-first reconnect, and app-managed loss recovery | Direct known-UUID connect reached verified health in under one second; a forced reset/loss produced exact timeout evidence, then the returning gateway reconnected as `link_session=2`, independently confirmed CCCD and handshake, and resumed health without Pair or Forget | Saved-identity startup and one forced-reset automatic recovery passed |

Implementation and observation are deliberately separate in this table. A compiled feature is not
listed as physically accepted until the corresponding attached-device evidence exists.

## Modern connection-state interpretation

### Core Bluetooth state is transport evidence, not product verification

The app uses these layers independently:

1. An advertisement match creates a **candidate**.
2. `CBPeripheral.state == .connected` proves that iOS owns a physical/system BLE link.
3. discovery of the versioned VHOS service proves service identity for that session.
4. encrypted state plus the single stream subscription proves the protected transport is ready.
5. a decoded VHOS handshake proves the application contract and firmware identity.
6. recurring CRC-valid frames prove live application data.

A restored `.connected` peripheral can be useful, but it is not automatically `VHOS ONLINE`.
Conversely, a link that Core Bluetooth restored before the app launched is not “disconnected” just
because the app has not yet rediscovered services.

State restoration is accepted only for the exact selected peripheral object. Previously verified
identifiers help rank candidates, but delayed callbacks from an older `CBPeripheral` wrapper are
ignored. Extra or stale restored objects are cancelled and drained before a scan or verified-object
adoption proceeds.

### ESP-NimBLE restore events may precede GAP `CONNECT`

The central discovery from `dev.22` is event ordering, not a bond failure. On a bonded reconnect,
ESP-NimBLE may restore encryption and bonded CCCD state before delivering the application GAP
`CONNECT` event. Code must therefore treat these as valid:

```text
ENC_CHANGE status=0
SUBSCRIBE reason=bond-restore notify=1
CONNECT
```

The old handler initialized `link_encrypted` and every subscription flag to false inside
`CONNECT`, destroying the valid state that had just arrived. `dev.23` instead:

- clears link state at boot and definitive `DISCONNECT`;
- retains pre-`CONNECT` encryption/subscription events for the new connection epoch;
- reads the current connection security descriptor at `CONNECT`;
- starts security only when the descriptor is not already encrypted; and
- accepts outbound application traffic only for the active connection epoch.

This distinction explains why a screen could briefly show subscribed channels and then return to
waiting without either peer losing the bond.

### Pairing, bonding, subscription, and application readiness are separate

- **Pairing** is the security exchange that creates keys.
- **Bonding** persists those keys on both peers.
- **Encryption restore** reuses the saved keys on a later link.
- **CCCD restore** reestablishes the saved notification subscription.
- **VHOS readiness** still requires a current application exchange and valid frames.

No individual callback is allowed to make all five claims.

## Corrective behavior now implemented

### Gateway firmware

- Keep Secure Connections, bonding, `NoInputNoOutput` Just Works, and encrypted command/stream
  access; do not weaken security to hide a state-machine bug.
- Initiate the supported GAP security procedure once, 150 ms after a new unencrypted connection.
- Skip that initiation when the current connection descriptor is already encrypted.
- Decode host, SM, peer-SM, and HCI status namespaces in serial evidence.
- Log connection security state, peer identity, key size, subscription reason and transitions, and
  bond-store counts at each phase.
- Preserve pre-`CONNECT` encryption and restored CCCD state.
- Terminate an SM-timeout-tainted link and advertise again rather than attempting SMP repeatedly on
  the same link.
- Multiplex evidence, health, and OTA frames over one encrypted stream CCCD.
- Reset queued traffic and connection epochs at definitive link boundaries.
- Gate health output until encryption, stream subscription, and a current application command are
  all present.

The public NimBLE API explicitly supports `ble_gap_security_initiate()` for a peripheral. In the
peripheral role it sends a Security Request so the central can pair or restore encryption. The API
returns `BLE_HS_EALREADY` if another security procedure is active; it must not be called in a loop.

### iPhone app

- Maintain one process-wide radio owner and one selected `CBPeripheral` object per active session.
- Permit one encrypted stream subscription request per physical link.
- Do not issue another CCCD request while pairing is pending.
- Close a link after a terminal secure-subscription failure instead of retrying on the same SMP
  session.
- Retire stale restoration objects and wait for their disconnect callbacks before scanning.
- Distinguish `CANDIDATE`, `VALIDATING`, and application-verified state.
- Preserve exact Core Bluetooth error evidence and the operator's Connect, Cancel, or Disconnect
  intent.
- Use one bounded app-managed reconnect policy; a raw link event does not reset backoff.

## Why “Forget This Device” is not the product solution

Manual removal can be useful when deliberately testing a fresh pairing or diagnosing a confirmed
corrupted system bond. It is not part of ordinary commissioning, reconnection, firmware reboot, or
radio-loss recovery.

The supported owner experience is:

```text
first commissioning: Connect -> one Pair approval -> verified data
later use:           Connect or automatic restoration -> no Pair sheet -> verified data
```

A GATT schema change rotates the gateway BLE identity and clears only the incompatible gateway bond
epoch once. Ordinary reboots and application-only firmware updates with the same schema preserve
identity and bond state. The app handles stale Core Bluetooth objects automatically instead of
instructing the owner to visit Settings after every disconnect.

## What is proven now

- correct gateway advertisement selection;
- physical link, MTU 247, and stable connection-parameter negotiation;
- versioned service plus all four characteristics;
- exact decoding of the `dev.20` security timeout and later controller timeout;
- successful fresh security and bonding in `dev.21`;
- successful encrypted-bond and CCCD restoration in `dev.22`;
- corrected pre-`CONNECT` restore-state preservation in `dev.23`;
- saved-peripheral adoption and recurring decoded health for more than 92 seconds in `dev.23`;
- direct `HANDSHAKE_VERIFIED firmware=0.1.0-dev.23` evidence on two saved-identity reconnects;
- explicit Disconnect disabling automatic reconnect while preserving the saved gateway identity;
- explicit Reconnect targeting the saved Core Bluetooth UUID and reusing the existing bond without
  a Pair sheet;
- iOS `0.3.2 (8)` retrieving the saved UUID and verifying `0.1.0-dev.26` in under one second;
- one forced ESP32 reset/loss producing exact `CBError.connectionTimeout` evidence and then a full
  automatic `link_session=2` recovery with new CCCD proof, handshake, and recurring health;
- no Pair sheet or **Forget This Device** step during the final direct-connect/recovery run;
- no panic or Guru Meditation in the accepted gateway traces; and
- reason `531` is distinct intentional peer-side termination evidence, not reason `520`.

The final `0.3.2 (8)` run did not repeat a physical tap of explicit **Disconnect**. Its preserved-ID,
no-autoreconnect behavior is supported by source review and the earlier `dev.23` physical-control
run, and remains listed below as a final-build regression check rather than a fresh physical pass.

## What remains open

- ten uninterrupted foreground minutes;
- background/foreground while health continues or resumes deterministically;
- cold app termination/relaunch repeated across multiple trials;
- ESP32 power-cycle/bond restore repeated across multiple trials (one `dev.26` recovery passed);
- controlled out-of-range and return;
- explicit Cancel-during-negotiation validation;
- explicit Disconnect/offline/Reconnect repeated on the final `0.3.2 (8)` build;
- repeated runs at weak but supported signal levels;
- durable evidence archive rather than temporary/live console output; and
- downstream OBD-II/protocol evidence, which this BLE incident does not establish.

## Physical acceptance criteria

The incident can be marked closed only when the following matrix passes without ordinary use of
Settings -> Forget This Device.

### A. Fresh commissioning

1. Start from an intentionally fresh gateway identity and matching clean iPhone test state.
2. Keep VHOS foreground and the iPhone beside the gateway, with RSSI better than `-65 dBm`.
3. Select Connect once.
4. Observe one security initiation and at most one Pair sheet.
5. Approve Pair within five seconds.
6. Require `BLE_ENCRYPTION status=0`, bonded state, one stream subscription, a directly logged
   versioned handshake, and recurring CRC-valid health.
7. Reject duplicate CCCD requests, repeated Pair sheets, same-link SMP retries, and overlapping
   connect attempts.

### B. Bonded restoration

1. Preserve the gateway identity, NVS, and iPhone bond from A.
2. Cold-terminate and relaunch the app.
3. Require no Pair sheet.
4. Accept either coherent state restoration or a bounded reconnect to the same identity.
5. If ESP-NimBLE reports restore events before `CONNECT`, require the effective encrypted and
   subscribed state to remain true after `CONNECT`.
6. Require a directly logged handshake and first decoded health within five seconds after
   application adoption.
7. Require at least ten minutes of continuous or explicitly gap-accounted health frames.

### C. Recovery and controls

- background and foreground the app;
- power-cycle the ESP32 without erasing NVS;
- move the phone out of range until a real disconnect, then return;
- use Cancel during scan/validation and verify no reconnect occurs;
- repeat the passed Disconnect/Reconnect sequence with at least a ten-second intentional offline
  hold before Reconnect;
- repeat cold relaunch and radio-loss cycles at least five times; and
- verify every disconnect is decoded separately as supervision timeout, peer termination, local
  termination, or another exact host/controller reason.

### D. Security-timeout negative control

For a development-only fresh identity, deliberately leave the Pair sheet unanswered:

1. expect `BLE_HS_ETIMEOUT` at approximately 30 seconds;
2. require immediate clean termination of the tainted link;
3. require advertising and bounded reconnect to resume;
4. require no second SMP attempt on the same connection; and
5. confirm the UI reports pairing timeout rather than ESP32 crash, OBD failure, or “unknown.”

### E. Safety and truthfulness

- CAN remains listen-only during every test;
- SoftAP remains disabled unless explicitly and securely activated;
- no arbitrary CAN transmit or active-test surface is introduced;
- OBD-II remains `UNVERIFIED` until independent vehicle-bus/protocol evidence exists;
- unavailable supply, motion, and storage fields remain unavailable rather than becoming zero;
  and
- application exit, BLE disconnect, security timeout, controller timeout, and ESP32 reset remain
  separate facts in evidence and UI.

## Relationship to earlier incident records

This report supersedes the unresolved diagnosis at the end of the original `dev.20` incident while
preserving its evidence. It refines, but does not erase, the historical records:

- [BLE restoration incident — 2026-08-16](BLE-RESTORATION-INCIDENT-2026-08-16.md)
- [BLE gateway identity incident — 2026-08-16](BLE-GATEWAY-IDENTITY-INCIDENT-2026-08-16.md)
- [BLE GATT schema migration and automatic iPhone recovery](BLE-GATT-SCHEMA-MIGRATION.md)

The identity incident proved correct device selection. The schema incident proved automatic
recovery from incompatible cached GATT metadata. This incident proves the later failures were a
30-second incomplete security procedure followed by a separate restored-event ordering bug, then
records the first corrected `dev.23` restored data run and the final `0.3.2 (8)` / `dev.26`
direct-connect and reset-recovery run.

## Current conclusion

The original loop is no longer unexplained. `dev.20` timed out in the Bluetooth Security Manager;
reason `520` was the later connection-supervision consequence. Reason `531` is a different,
peer-initiated termination path. `dev.21` proved fresh pairing, `dev.22` exposed pre-`CONNECT`
restore ordering, and `dev.23` preserved that state and streamed decoded health for more than 92
seconds. The state-aware iPhone build then proved bounded stale-command recovery, explicit
Disconnect, and two saved-identity Reconnects with direct handshake verification and no Pair sheet.

The final iPhone `0.3.2 (8)` and gateway `0.1.0-dev.26` evidence advances that conclusion: startup
retrieved and directly connected the known UUID, verified the current CCCD and handshake, and
streamed health; a forced ESP32 reset/loss then produced an exact timeout and automatically
recovered through a new link epoch, new CCCD confirmation, verified handshake, and resumed health.
No Pair sheet or manual Forget was required. Explicit Disconnect remains physically supported by
the earlier run and implemented in the final build, but its tap was not repeated in this exact final
acceptance trace.

The next milestone is repeated endurance and recovery acceptance, not another speculative
security-policy change. The encrypted bond, one-CCCD transport, exact event evidence, and
no-manual-forget owner workflow remain the product contract.
