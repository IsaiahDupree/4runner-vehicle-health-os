# Android head-unit dual-ESP32 architecture and connection requirements

Status: public Android `0.1.0-dev.15` prerelease, first OBD/CAN vertical slice, transactional
Android/iPhone evidence-bundle sync, and signed cross-target Release Hub implemented; physical
head-unit acceptance and A/C node BLE/OTA implementation pending

## Outcome

Vehicle Health OS will have a native Android application that runs directly on the installed head
unit and receives evidence from two independent ESP32 devices:

1. the OBD/CAN gateway, which passively observes the vehicle network; and
2. the A/C sensor node, which will acquire pressure, temperature, ADC, power, POST, and storage
   evidence.

The Android app is an always-available vehicle display and local evidence recorder. It complements
the native iPhone engineering application established by ADR-0003; it does not replace the iPhone
or change gateway safety authority. Android, iPhone, replay, and simulator data all enter the same
versioned validation and lineage pipeline.

The implementation invariant remains:

> raw observation -> decoded signal -> feature -> versioned equation -> calculation run -> finding
> -> recommendation -> service/inspection -> new lifecycle baseline

No Android screen may show an apparently authoritative number without retaining the source device,
raw observation, version, unit, quality, freshness, and derivation references required to explain
it.

## Current physical reality

| Device | Present role | Current connectivity | Android readiness |
| --- | --- | --- | --- |
| `VHOS-4R-OBD-B08D14` | Development OBD/CAN gateway; classic ESP32 with MrDIY CAN Shield v1.3+ | VHOS BLE service is implemented and physically enumerated; CAN is forced listen-only; normal Wi-Fi SoftAP is disabled | Android dev.15 client is build/release verified and includes bounded vendor BLE scanner recovery; sustained physical head-unit BLE acceptance remains open |
| A/C ESP32-S3, base MAC `20:6e:f1:98:bd:20` | Future ADC, pressure, temperature, power, POST/BIT, and storage node | Current `EMPTY_RECOVERY` image reports identity/health only over USB serial; BLE, Wi-Fi, ADC, and sensors are deliberately disabled | Not connectable from Android until the sensor-node BLE milestone is implemented |

This distinction must remain visible in tickets and UI. The Android app can be proven against the
CAN gateway first. It must show the A/C node as `FIRMWARE NOT READY` or `UNAVAILABLE`, not simulate a
connection or populate nominal sensor values.

The long-term OBD hardware selection may differ from the current MrDIY development gateway. Android
therefore trusts the versioned handshake, capabilities, and approved device association rather than
hard-coding a board name as the source of truth.

## Complete connection topology

```text
2005 Toyota 4Runner
  |
  |-- DLC3 / OBD-II networks
  |      |
  |      `--> OBD/CAN ESP32 gateway
  |              |-- encrypted BLE: routine control, health, live evidence, log sync
  |              |-- temporary authenticated Wi-Fi: approved bulk transfer / signed OTA
  |              `-- USB/UART: first flash, recovery, bench diagnostics
  |
  `-- added A/C sensors
         |
         `--> A/C ESP32-S3 sensor node
                 |-- encrypted BLE: routine telemetry, health, POST, bounded control
                 |-- temporary authenticated Wi-Fi: approved bulk transfer / signed OTA
                 `-- USB/UART: first flash, recovery, bench diagnostics

                         two independent BLE sessions
                                      |
                                      v
                       Android VHOS head-unit application
                         |-- transport validation
                         |-- append-only local truth store
                         |-- raw capture files + checksummed manifests
                         |-- source-specific status and freshness
                         |-- synchronized CAN + A/C experiment timeline
                         |-- Drive / Garage / Engineering surfaces
                         `-- evidence export for replay, iPhone, desktop, or AI
```

The head unit must never bridge arbitrary bytes between the two ESP32s. Fusion occurs only after
each source has independently passed frame validation and persistence.

## Device and transport contracts

### Shared VHOS wire frame

Both devices carry the ADR-0001 logical frame:

- 36-byte little-endian `VHOS` header;
- protocol major/minor;
- message type and flags;
- bounded payload length;
- source sequence;
- source monotonic microseconds;
- payload CRC32C; and
- header CRC32C.

The deployed payload encoding is fixed by `contracts/wire/v1/README.md`: handshake, health, capture
index, and OTA are versioned JSON; live CAN, capture request, and capture chunks use bounded binary
records. `contracts/proto/v1/gateway.proto` remains immutable historical design input and is not the
deployed OBD payload codec. BLE, Wi-Fi, USB, simulator, and replay must yield the same complete
logical frames after transport-specific chunk reassembly. Unknown protocol majors and oversized
frames are rejected before payload allocation.

### BLE GATT transport

The current OBD/CAN gateway uses this public contract:

| Role | UUID | Required behavior |
| --- | --- | --- |
| VHOS primary service | `33613EB3-FFCA-42D1-83FA-A18F12B3F123` | Advertised by a supported gateway |
| Reliable command write | `B3D3279B-0244-4D54-A2AB-A1AB47A5FC0A` | Encrypted write / write without response with application acknowledgements where required |
| Multiplexed stream | `265B90C0-A600-4659-BBBD-5CDA411C49CC` | The one encrypted CCCD enabled by current clients; carries independently typed evidence, health, capture, and OTA frames |
| Health compatibility characteristic | `BCB5699A-A9B4-49B8-B69B-D2DFF19B41A9` | Must remain registered for the current GATT schema; current clients do not enable its CCCD |
| OTA compatibility characteristic | `18D21F8E-D190-4DB3-923C-27BBFC355874` | Must remain registered for the current GATT schema; current clients do not enable its CCCD |

The A/C firmware should reuse this transport service and characteristic contract so the Android
transport implementation remains device-role neutral. The handshake's supported message types
then prove the role:

- an OBD/CAN source advertises `RAW_CAN_FRAME`, `GATEWAY_HEALTH`, and the applicable capture or
  diagnostic capabilities;
- an A/C source advertises `SENSOR_NODE_TELEMETRY`, `SENSOR_NODE_HEALTH`, and `SENSOR_NODE_POST`.

This reuse is an implementation target, not a claim that the current A/C recovery firmware already
advertises BLE. The A/C BLE milestone must implement and physically verify the service before the
Android app labels it compatible.

If future requirements make the shared service insufficient, a new UUID or incompatible protocol
major requires an accepted ADR and coordinated firmware/Android/iOS migration. It must not be
introduced only in one client.

### Handshake and source classification

Android accepts a device only after all of the following are true:

1. the user has approved or previously associated the physical device;
2. the advertised or discovered GATT service matches the VHOS contract;
3. the encrypted link and current-link multiplexed stream notification are active;
4. a complete handshake passes both CRC checks and deployed JSON contract decoding;
5. the protocol major is supported;
6. the declared maximum frame size is within the app's configured ceiling;
7. the hardware, firmware, configuration, and gateway/device identities are present; and
8. the supported message-type set proves exactly one expected device role.

Names such as legacy `VHOS-MRDIY-*` and canonical `VHOS-4R-OBD-*` are discovery aids, not identity proof. A generic device with a similar
name is rejected. A previously associated device whose current service or handshake no longer
matches is shown as a stale or incompatible association and is not silently trusted.

The app maintains separate source keys:

```text
OBD source: gateway_id + firmware_build_id + active_config_id + protocol_version
A/C source: device_id + firmware_build_id + device_config_revision + protocol_version
```

The two sequences and monotonic clocks are never merged into a single counter.

## Head-unit hardware and OS acceptance audit

Do not generate or freeze the Gradle application until the actual installed head unit has a saved
audit record containing:

| Area | Evidence required |
| --- | --- |
| Product identity | Manufacturer, exact model/SKU, board/build fingerprint, serial identity if exposed |
| Android platform | Android version, API level, security patch, ABI, whether it is Android Automotive OS, Google-certified Android, or an aftermarket AOSP tablet-style unit |
| Display/input | Resolution, density, physical size, fixed orientation, touch controls, day/night behavior, steering-wheel input exposure |
| Compute/storage | CPU ABI, RAM, free internal storage, filesystem behavior, removable storage availability |
| BLE | `android.hardware.bluetooth_le`, BLE central support, bonding behavior, MTU behavior, and a physical two-concurrent-GATT-session test |
| Wi-Fi | 2.4 GHz client support, local-only network request behavior, internet-network retention, and secondary STA concurrency result |
| USB | Host/device modes, accessible ports, permission behavior, and whether a serial adapter can be used without disassembling the dash |
| Vehicle power behavior | Cold boot, warm boot, ignition sleep, resume, brownout, retained accessory power, clock correctness, and app process survival |
| App lifecycle | Background limits, battery optimization, autostart policy, kiosk/device-owner privileges if any, and foreground-service behavior |
| Distribution | Play Store availability, managed deployment, approved sideload/update method, signing-key custody, rollback method |
| Security | Lock-screen posture, Android Keystore support, file-based encryption, ADB/debug policy, network exposure |

The minimum SDK, target SDK, application ID, signing posture, Room encryption choice, and supported
distribution method remain explicit decisions after this audit. The repository must not pretend
that an unknown head unit supports Android Automotive OS or Google Play Services.

## Android permissions and lifecycle requirements

The implementation uses platform APIs rather than hidden Bluetooth or Wi-Fi controls.

### Bluetooth

For an Android 12/API 31 or newer target, routine discovery and connection require the runtime
`BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` permissions. VHOS does not advertise from the head unit, so
`BLUETOOTH_ADVERTISE` is not required for the planned central-only design. Older supported Android
versions require their documented legacy Bluetooth/location permission path.

`CompanionDeviceManager` is the preferred initial-association path where the head-unit build
implements it correctly. Association does not itself create the BLE connection; the app still owns
GATT state, reconnection, validation, and data flow. A direct service-filtered scanner remains a
tested fallback for head units with incomplete companion-device UI.

Continuous visible capture uses a user-started connected-device foreground service and persistent
notification when required by the installed Android version. On API 34+ builds, the manifest and
runtime must satisfy the `connectedDevice` foreground-service requirements. Boot or background
reconnection is not assumed to be legal merely because the unit is installed in a vehicle; it must
be tested against the actual OS and current Android background-start rules.

### Wi-Fi

Wi-Fi remains off on both ESP32s during normal operation. The app may request one authenticated,
time-bounded local-only ESP32 network only after:

- the encrypted BLE session identifies the intended device;
- firmware advertises the exact OTA/bulk-transfer capability;
- vehicle motion is deterministically `PARKED` when required;
- the device health/preflight contract passes; and
- the owner explicitly approves the operation.

Android 10/API 29+ uses `WifiNetworkSpecifier` for a peer/local-only request. Android 13/API 33+
Wi-Fi management also requires the applicable `NEARBY_WIFI_DEVICES` permission. The app must check
whether the head unit supports a concurrent local-only connection before assuming it can retain its
normal internet network. Failure leaves OTA or bulk transfer unavailable; it must not change the
system's saved Wi-Fi configuration or repeatedly reconnect to a no-internet ESP32 access point.

## Two-session connection manager

The app owns one `DeviceSession` per expected role:

```text
DualGatewaySupervisor
  |-- ObdGatewaySession
  |     `-- scan -> associate -> connect -> discover -> secure -> subscribe -> handshake -> stream
  |
  `-- AcSensorSession
        `-- scan -> associate -> connect -> discover -> secure -> subscribe -> handshake -> stream
```

Every session has an independent state machine:

```text
UNAVAILABLE
RADIO_OFF
PERMISSION_REQUIRED
SCANNING
DISCOVERED
CONNECTING
GATT_VALIDATING
PAIRING
SUBSCRIBING
HANDSHAKING
STREAMING
DEGRADED
RECONNECTING
RELEASED_FOR_EXTERNAL_CLIENT
INCOMPATIBLE
```

A failure in one session cannot reset, relabel, or discard the other. Examples:

- CAN streaming + A/C unavailable is `CAN READY / A/C UNAVAILABLE`, not `SYSTEM HEALTHY`;
- A/C streaming + CAN disconnected permits physical A/C display but no CAN-command-state
  correlation;
- transport CRC failures degrade the relevant evidence source, not the vehicle component;
- stale A/C data cannot be replaced by a newer CAN timestamp or vice versa.

Each session implements bounded exponential reconnect with jitter, a circuit breaker after repeated
contract failures, and a visible manual retry. It does not continuously scan at full duty cycle
after both approved devices are streaming.

## Android and iPhone coexistence

The present OBD/CAN firmware tracks one active BLE connection. The A/C firmware should initially
make the same conservative assumption. Android must therefore not assume that an ESP32 can serve the
head unit and iPhone simultaneously.

The first coexistence policy is explicit ownership handoff:

1. the head unit normally owns the read-only live connection;
2. `Release gateways for iPhone` flushes Android persistence, disconnects both GATT sessions, and
   suppresses automatic reconnect for a visible time window;
3. the iPhone connects for engineering, export, experiment approval, or OTA;
4. after the iPhone disconnects or the owner ends the release window, Android resumes normal
   association and validation; and
5. neither client repeatedly steals the connection from the other.

A future controller-lease message may automate this handoff, but it requires a versioned shared
contract and firmware implementation. Multi-central BLE support is not an MVP assumption.

Historical transfer is already independent of BLE ownership. The iPhone can create a checksummed
`.vhossync` archive and Android dev.15 can import it append-only. Android verifies the ZIP/manifest,
segment and envelope hashes, outer VHOS CRC32C, persistent-record inner CRC32C, and listen-only proof
before materializing imported CAN observations in the same transaction. Direct background transfer
over the iPhone hotspot is not implemented yet; the present handoff uses an owner-selected file
provider or removable storage. Live telemetry should come directly from the ESP32 after the iPhone
releases its BLE connection.

## Ingest and durable evidence

### Validate before persistence

For every source, the ingest sequence is:

```text
BLE callback
  -> bounded chunk reassembly
  -> VHOS magic/version/length checks
  -> header CRC32C
  -> payload CRC32C
  -> sequence and reboot accounting
  -> registry-selected JSON or binary decode
  -> capability/identity validation
  -> append raw observation
  -> update rebuildable projections
```

Malformed data is quarantined with the source identity and failure reason. It is never decoded into
a vehicle value.

### Local storage

- Room/SQLite stores structured identities, sessions, raw-observation metadata, signal samples,
  quality/freshness, experiment markers, calculation runs, findings, service history, and audit
  events.
- Chunked files store high-rate binary captures and immutable exported payloads.
- Checksummed manifests bind every bundle to app, gateway, firmware, protocol, configuration,
  signal-pack, and equation versions.
- Database encryption and Android Keystore policy are frozen only after the head-unit security audit.
- “Latest state” tables are projections that can be deleted and rebuilt; they are not evidence.

Deduplication is scoped to the source:

```text
source_device_id + source_boot_or_capture_id + source_sequence
```

Identical byte payloads from different devices remain separate observations.

## Time synchronization and cross-source experiments

The head unit records three distinct times where available:

```text
capture_monotonic_us   source-device monotonic time
capture_epoch_us       mapped wall time with mapping identity and uncertainty
ingested_epoch_us      Android receipt/persistence time
```

Android maintains a separate monotonic-to-wall mapping for each ESP32 and records its uncertainty,
round-trip samples, resets, and drift. Arrival order is not a synchronization method.

A dual-source experiment creates one Android experiment identity and sends a semantic marker to each
capable source. The stored result preserves each source marker/sequence boundary and the Android
correlation record. This is how CAN state such as compressor command, engine speed, and vehicle
motion can later be compared with pressure and temperature behavior without pretending both ESP32
clocks are identical.

## Data expected from each ESP32

### OBD/CAN gateway

Android must be able to receive and store:

- handshake and firmware/configuration identity;
- current BLE and gateway health;
- enforced listen-only state;
- passive CAN bitrate/probe state;
- raw CAN observations and source sequences;
- received, retained, suppressed, dropped, bus-error, and bus-off counters;
- persistent capture index/chunks and storage health;
- signed experiment results when those capabilities exist;
- narrowly allowlisted diagnostic responses when separately authorized; and
- signed OTA/preflight/probation/rollback status.

Vehicle-network traffic is not proof of an OBD diagnostic response. The UI maintains those states
separately.

### A/C sensor node

After the radio and sensor firmware milestone, Android must be able to receive and store:

- device, hardware, firmware, configuration, and vehicle-profile identity;
- complete POST/BIT results;
- raw pressure ADC counts and measured signal voltage;
- calibrated absolute pressure only when calibration identity/revision/status are present;
- high/low line, ambient, cabin-return, center-vent, and board temperature with per-channel quality;
- atmospheric pressure value/source/quality when available;
- vehicle input, VIN rail, sensor 5 V, and logic 3.3 V evidence;
- sample counters, storage/drop/reconnect counters, queue depth, fault mask, and client counts;
- local persistent log indexes/chunks; and
- signed OTA/preflight/probation/rollback status.

The app must not implement a generic ADC-to-pressure transfer function. Unconfigured calibration
means absolute pressure is unavailable even when raw ADC evidence is present.

## User experience

### Persistent connection header

Every screen can resolve to two compact source indicators:

| Indicator | Example valid states |
| --- | --- |
| CAN gateway | `STREAMING`, `RECONNECTING`, `LISTEN-ONLY`, `LOG SYNC`, `INCOMPATIBLE` |
| A/C sensor node | `STREAMING`, `SAFE MODE`, `CALIBRATION REQUIRED`, `FIRMWARE NOT READY`, `UNAVAILABLE` |

The overall banner may say `ALL SOURCES READY` only when every source required by the current view
is fresh and valid. A CAN-only screen does not require the A/C node; an A/C performance calculation
does.

### Drive mode

Drive mode is glanceable and read-only:

- large status/metric tiles with unit, freshness, and quality;
- no firmware, raw-frame, configuration, export, or experiment controls;
- no keyboard-heavy workflows;
- concise data-system degradation alert distinct from a vehicle finding; and
- automatic suppression of unavailable derived values rather than substituting stale data.

### Garage mode

Garage mode exposes maintenance, history, component state, capture sessions, evidence completeness,
and owner-safe exports. Actions requiring `PARKED` remain disabled until deterministic motion
evidence proves that state.

### Engineering mode

Engineering mode exposes per-source connection state, firmware/configuration identity, GATT and
wire-protocol health, CRC/sequence/drop counters, raw evidence preview, log synchronization,
experiment markers, and signed OTA status. It still does not expose arbitrary CAN/K-line/J1850
transmission.

If the head unit is Android Automotive OS, driving-state restrictions and applicable car-app
quality rules are enforced by the platform integration. If it is an aftermarket AOSP head unit,
VHOS still enforces its own Drive/Garage/Engineering separation and does not claim privileged
vehicle-motion APIs that the unit does not provide.

## Module plan

The existing `android/modules.toml` dependency direction remains valid. Implementation should add
or refine the following internal boundaries when the hardware audit is complete:

| Module | Responsibility |
| --- | --- |
| `transport-ble` | Android BLE permissions, association, scan, GATT, bonding, MTU, subscription, chunk transport |
| `gateway-session` | Two role-specific state machines over one transport-neutral protocol client |
| `core:protocol` | ADR-0001 frames, CRC32C, deployed JSON/binary registry, capability negotiation, version rejection |
| `capture` | Source-scoped raw persistence, manifests, resumable gateway log sync, replay |
| `sensor-node` | A/C telemetry/health/POST validation without diagnostic interpretation |
| `timeseries` | Source time mappings, freshness, downsampling, gaps, synchronized queries |
| `signal-registry` | Versioned CAN and sensor definitions, units, applicability, validation status |
| `ui-drive` | Low-distraction, read-only fresh values and alerts |
| `ui-garage` | Maintenance, history, evidence, controlled export and updates |
| `export` | Checksummed bundles for desktop, iPhone, mechanic, or evidence-bound AI handoff |

UI modules depend on repositories/use cases, not `BluetoothGatt`, wire-payload types, or SQL
entities directly.

## Safety, security, and authority boundaries

- CAN remains passive-first and firmware-enforced listen-only.
- Android exposes no method accepting arbitrary arbitration IDs or raw vehicle request bytes.
- Diagnostic requests name a firmware-resident allowlist entry and remain rate/motion/approval
  constrained.
- No active test, ECU flash, code clear, configuration write, or actuator control is in MVP scope.
- BLE commands and notifications requiring authority use an encrypted, associated link.
- Release trust keys are pinned; private signing keys do not ship in the app.
- Firmware packages are signed, target-specific, versioned, and checked before transfer.
- OTA requires deterministic `PARKED`, current device health, explicit approval, A/B installation,
  probationary boot, POST, mark-valid, and rollback evidence.
- Wi-Fi is temporary, authenticated, device-specific, and disabled by default.
- An AI may analyze exported evidence and propose hypotheses or semantic experiments; it cannot
  connect to the ESP32, approve a run, transmit vehicle bytes, or install firmware.
- Gateway or sensor failure is evidence-system degradation, never proof of vehicle failure.

## Delivery sequence

### AH0 — Head-unit audit

- Record the exact hardware/OS acceptance table.
- Prove two simultaneous BLE GATT connections with test peripherals.
- Record ignition sleep/resume and app lifecycle behavior.
- Decide SDK, application ID, signing, distribution, and database encryption.

### AH1 — Android foundation

- Maintain the Gradle/Kotlin workspace in the public `4runner-vhos-android` repository.
- Generate golden vectors from the deployed JSON/binary registry shared by firmware and iOS.
- Implement CRC32C and golden frame vectors shared with firmware/iOS.
- Implement Room identities, raw observations, audit events, and file manifests.

### AH2 — Dual-source simulator and replay

- Run CAN and sensor-node replay sources concurrently.
- Prove source isolation, clock mappings, gaps, deduplication, and process restart.
- Build the two-source status UI without claiming live hardware.

### AH3 — Physical CAN gateway

- Associate the current MrDIY gateway.
- Complete secure discovery, the single encrypted multiplexed stream subscription, handshake,
  health, live CAN, and persistent log sync.
- Run foreground/background, sleep/resume, and head-unit reboot tests.

### AH4 — A/C node transport firmware

- Replace `EMPTY_RECOVERY` only after exact ADC/sensor/pin/calibration decisions pass.
- Implement the compatible VHOS BLE service, encrypted notifications, identity persistence, GATT
  schema migration, sensor telemetry/health/POST frames, and bounded queues.
- Preserve default-off Wi-Fi and USB recovery.

### AH5 — Physical dual-gateway acceptance

- Stream both ESP32s simultaneously for a minimum 30-minute bench run.
- Power-cycle and independently reconnect each source.
- Prove that disconnecting or corrupting one source leaves the other intact.
- Prove synchronized markers and exported evidence resolve to both raw sources.

### AH6 — Head-unit owner UX

- Ship Drive/Garage/Engineering separation.
- Add durable recent logs and share/export.
- Add explicit release/reacquire workflow for iPhone coexistence.

### AH7 — Controlled Wi-Fi and OTA

- Verify target-specific signed packages, network request behavior, internet retention, timeout,
  power interruption, probation, rollback, and recovery on the actual head unit.
- Keep iPhone OTA as a supported control path.

### AH8 — Signal packs, calculations, and AI handoff

- Promote independently validated CAN and A/C signals into versioned packs.
- Add equation-driven metrics only when every required input is available.
- Export evidence-bound AI packages; keep AI non-authoritative.

## MVP acceptance gates

The Android head-unit client is not complete until physical evidence proves:

1. exact head-unit identity and supported Android behavior are recorded;
2. the app associates with the correct two devices without name-only trust;
3. two encrypted GATT sessions stream concurrently for at least 30 minutes;
4. the service, command, and three registered stream/compatibility characteristics are validated;
   only the current multiplexed stream CCCD is enabled, and both role-specific handshakes pass;
5. source CRC failures, sequence gaps, resets, drops, and stale data are visible and isolated;
6. raw observations survive app termination, head-unit reboot, and ignition sleep/resume;
7. CAN and A/C records retain distinct identity and time mappings in a combined export;
8. one gateway can disconnect/reconnect without resetting the other;
9. Android can release both gateways for iPhone use and reacquire them without a connection war;
10. normal boot and capture create no ESP32 Wi-Fi access point;
11. no arbitrary vehicle-bus transmit surface exists in UI, Kotlin API, protobuf, or firmware;
12. missing A/C calibration yields unavailable engineering pressure, not a fabricated number;
13. moving-vehicle UI cannot open Engineering, experiment, or OTA controls; and
14. every displayed derived conclusion resolves to immutable raw evidence and exact versions.

## Blocking decisions and next action

The available Settings evidence identifies the head unit as model `Q91-A4-CPL`, reporting Android
13.0, security patch level 2020-02-01, kernel 4.14.116, and build/custom build
`android-trunk-p0`. Those labels are not sufficient acceptance proof. The next action is to install
the public dev.15 APK through the iPhone-hotspot release portal and record package-install behavior,
actual BLE-central operation, ABI/RAM/storage, ignition sleep/resume, and USB-debugging posture on
that physical unit.

Development can continue with platform-neutral protocol/replay tests and physical OBD/CAN
commissioning on the head unit. Physical A/C integration remains blocked by design until the
ESP32-S3 moves beyond `EMPTY_RECOVERY` and exposes real, versioned BLE telemetry.

## References

- [ADR-0001: Gateway wire contract](../architecture/decisions/0001-gateway-wire-contract.md)
- [ADR-0002: Versioning, identities, and lineage](../architecture/decisions/0002-versioning-identities-and-lineage.md)
- [ADR-0003: iOS is the primary mobile control surface](../architecture/decisions/0003-ios-primary-control-surface.md)
- [Master project specification](../prd/MASTER-PROJECT-SPEC.md)
- [A/C telemetry focused source record](../prd/AC-TELEMETRY-SOURCE.md)
- [A/C sensor-node recovery profile](AC-SENSOR-NODE-EMPTY-RECOVERY.md)
- [Passive CAN logging and replay](PASSIVE-CAN-LOGGING-AND-REPLAY.md)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Android companion-device pairing](https://developer.android.com/develop/connectivity/bluetooth/companion-device-pairing)
- [Android connected-device foreground service](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Android Wi-Fi network requests](https://developer.android.com/develop/connectivity/wifi/wifi-infrastructure)
- [Android nearby Wi-Fi permissions](https://developer.android.com/develop/connectivity/wifi/wifi-permissions)
- [Android Automotive parked-app and distraction guidance](https://developer.android.com/training/cars/parked/automotive-os)
