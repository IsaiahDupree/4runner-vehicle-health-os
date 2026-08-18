# BLE and gateway fault-injection test plan

Date: 2026-08-18

## Purpose

VHOS must recover from ordinary vehicle use without asking the owner to remove an iOS bond,
erase the ESP32, or repeatedly press Connect. This plan turns process death, firmware loss, radio
loss, and true power loss into explicit tests with bounded recovery evidence.

The test oracle is the application contract, not the Bluetooth settings screen. A cycle passes
only after the iPhone observes, in order, a new physical `LINK_CONNECTED`, a current-link RSSI at
or above the configured floor, a CRC-valid `HANDSHAKE_VERIFIED`, and the configured number of real
post-contract activity frames. Ordinarily those are `HEALTH_DECODED` frames. While retained-history
transfer deliberately reserves the stream and suppresses periodic health, strictly contiguous
`CAPTURE_CHUNK` frames are the liveness and integrity oracle instead. Seeing the peripheral listed
as Connected in Settings is insufficient.

The harness never fabricates CAN frames or vehicle observations. A USB-bench run can prove BLE,
bond, boot, and application-session recovery while vehicle-network acceptance remains pending.

## Device-free transport and data-load gate

The first gate no longer needs an ESP32, iPhone, Android head unit, or vehicle. The checked-in
`can.replay.corpus@1.0.0` corpus preserves eight real listen-only sessions and 5,176 observations.
Python, Swift, and Kotlin rebuild the original VHOS frames and feed them through the production
stream and CAN decoders under sustained load.

```bash
.venv/bin/vhos validate-can-replay-corpus test-replay/real-can-2026-08-18
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode live --repeat 20 --fault clean
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode history --fault drop-fragment --fault-interval 257
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode live --fault corrupt-payload --fault-interval 101
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode history --fault disconnect-mid-frame --fault-interval 113
```

Clean replay requires exact record identity, order, count, and payload. A faulted replay must lose
only the deliberately damaged frame(s), count the recovery/discard evidence, and decode every
subsequent valid frame exactly once. A hang, crash, duplicate, reorder, unexplained loss, unbounded
buffer, or vehicle-health promotion is a release failure.

The Android app exposes the same production replay path as **HISTORICAL REPLAY • NOT LIVE**, with
source-time and full-speed ×20 modes plus explicit cancellation. The complete evidence boundary,
hashes, and cross-language matrix are in
[Real CAN replay and offline load testing](REAL-CAN-REPLAY-AND-LOAD-TESTING-2026-08-18.md).

## Harness

The executable harness is [`ios/tools/vhos_ble_fault_injection.py`](../../ios/tools/vhos_ble_fault_injection.py).
It uses the attached iPhone through `devicectl`, the ESP32 UART through `pyserial`, and preserves:

- timestamped iPhone commissioning output;
- timestamped ESP32 UART output;
- a machine-readable result for every cycle;
- the exact fault mechanism and recovery latency;
- a nonzero process exit when any recovery budget is exceeded.

Example endurance run:

```bash
uv run --script ios/tools/vhos_ble_fault_injection.py \
  --iphone <CoreDevice-ID> \
  --serial /dev/cu.usbserial-0001 \
  --cycles 20 \
  --faults esp-reset,app-relaunch \
  --timeout 55 \
  --dwell 3 \
  --health-frames 5 \
  --minimum-rssi -80
```

`--cycles` repeats the ordered fault list. The timeout is one total post-fault budget, including
ESP boot and self-test where applicable. An old handshake cannot satisfy a new cycle because the
harness starts after the fault marker and requires a new physical-link event first.

The harness also has negative oracles. A cycle fails immediately if the iPhone reports a frame
decode failure, exhausted handshake response, handshake-write timeout, or failed capture recovery,
or if UART reports a panic, stack overflow, heap corruption, assertion, task watchdog, or exhausted
BLE notification backpressure. Capture chunks must retain one session identity and exact contiguous
offsets; malformed counts or a gap fail the cycle. `--expected-firmware` requires
the exact version from the CRC-valid handshake; a physically connected device running the wrong
image cannot quietly pass. `--cycles 0` is a health-stream soak with no injected reset after the
baseline contract. `--minimum-rssi` requires a CoreBluetooth measurement from the exact current
link epoch. The default `-80 dBm` floor prevents marginal RF geometry from being misdiagnosed as a
GATT, encryption, firmware, or restoration defect. Deliberate range testing may lower that floor,
but its result must remain labeled as a weak-link experiment rather than release acceptance.

## One-command pre-car acceptance

[`ios/tools/vhos_precar_acceptance.py`](../../ios/tools/vhos_precar_acceptance.py) is the release
orchestrator. It combines the fast deterministic gates and the real-device harness in one command:

```bash
python3 ios/tools/vhos_precar_acceptance.py \
  --profile standard \
  --iphone <CoreDevice-ID> \
  --serial /dev/cu.usbserial-0001 \
  --minimum-rssi -80
```

Before physical fault injection, the default run verifies:

- every JSON/Protobuf domain contract;
- the complete Python suite, including evidence corruption and sequence-gap rejection;
- a fresh deterministic capture, bundle validation, and offline replay;
- the immutable real-CAN corpus manifest plus clean and faulted production-decoder replay;
- the Swift core suite, including fragmented VHOS frames, CRC corruption, capture chunks, signed
  releases, OTA preflight, and evidence bundles;
- syntax of both physical harnesses;
- a clean ESP-IDF 5.5.3 firmware build whose binary embeds the expected version;
- a signed physical-iPhone build, strict code-signature verification, and installation;
- exact-version physical health, reset, process-death, and mixed-recovery phases.
- a current-link RF precondition for every physical phase, recorded per cycle in `summary.json`.

All stdout, build output, physical logs, phase summaries, elapsed times, artifact hashes, and the
first failed gate are placed under `build/precar-acceptance/<timestamp>/`. The top-level
`summary.json` remains `RUNNING`, `PASS`, or `FAIL`; a nonzero process result is required for any
failed gate. `--skip-*` switches are intended for focused engineering reruns and are recorded in
that summary so a partial run cannot be mistaken for full acceptance.

| Profile | Stream gate | Reset gate | App-death gate | Mixed gate | Intended use |
| --- | ---: | ---: | ---: | ---: | --- |
| `quick` | 10 post-contract activity frames | included in 2 mixed cycles | included in 2 mixed cycles | 2 cycles | edit-time attached-device smoke |
| `standard` | 30 post-contract activity frames | 3 cycles | 3 cycles | 6 cycles | default before driving to the vehicle |
| `endurance` | 300 post-contract activity frames | 10 cycles | 10 cycles | 20 cycles | release candidate and overnight lab preparation |

All profiles run the deterministic software gates unless explicitly skipped. Signed app and
firmware builds also run unless `--skip-builds` is recorded. `--include-power` appends 1, 3, or 10
true rail-loss cycles respectively, but only when a concrete `uhubctl` hub and port are supplied.
The option fails closed on an ordinary CP2102 path.

## Fault mechanisms

| Fault | Current mechanism | What it proves | What it does not prove |
| --- | --- | --- | --- |
| ESP execution loss | CP2102 RTS hard reset | Boot, NVS/bond retention, advertising, iOS loss detection, automatic link and contract recovery | Electrical rail removal or brownout behavior |
| iPhone app death | `devicectl --terminate-existing` followed by a traced relaunch | CoreBluetooth restoration cleanup, saved-UUID reuse, bond reuse, fresh CCCD and handshake | iOS reboot or Bluetooth-controller reset |
| True ESP power cut | `uhubctl` with explicit `--usb-hub` and `--usb-port` | Actual rail removal, capacitor discharge, boot, persistent-state recovery | Vehicle voltage transients unless the production power path is used |

The true-power path is deliberately fail-closed. It refuses to run without a specifically selected,
per-port switchable USB hub or relay. The currently attached Mac/CP2102 path exposes reset control
but not software-controlled port power, and `uhubctl` is not installed. An RTS reset must never be
reported as a power cut.

Some CP2102 boards also reset when a host opens or closes the UART because the modem-control lines
feed the board's auto-reset circuit. The harness writes `UART_ATTACH_BEGIN` before opening the port
and treats any resulting boot as an explicit baseline perturbation. A phase called a soak therefore
means continuous health after that recorded attach/boot boundary; it does not claim the UART was
attached without affecting the target.

Example after connecting a compatible switchable hub or relay:

```bash
uv run --script ios/tools/vhos_ble_fault_injection.py \
  --iphone <CoreDevice-ID> \
  --serial /dev/cu.usbserial-0001 \
  --cycles 10 \
  --faults power-cycle \
  --usb-hub <uhubctl-location> \
  --usb-port <port> \
  --power-off-seconds 5
```

The explicit in-app `Disconnect` remains a separate owner-intent test. It must keep the saved
gateway identity and iOS bond, suppress automatic reconnect while offline, and allow a later
`Reconnect` without a Pair sheet. It is not interchangeable with an involuntary-loss test.

## Real-world matrix

| Scenario | Required injection | Required evidence | Status |
| --- | --- | --- | --- |
| Repeated firmware restart | 20+ alternating RTS resets | self-test, new link, handshake, health on every cycle | Harness available; 3-cycle physical subset passed |
| Repeated app process death | 20+ connected app kills | inherited link retired, bond retained, new link/CCCD/handshake/health | Harness available; 3-cycle physical subset passed |
| True electrical loss | 5 s and 60 s rail-off intervals | USB disappearance/return, cold boot, persisted identity/bond, contract recovery | Requires switchable hub/relay |
| Weak and intermittent RF | increase separation/shielding, then restore; lower `--minimum-rssi` only for this named experiment | bounded timeout, no stale-data promotion, eventual new contract | Incidental -96/-90 dBm failures observed; automated good-bench floor implemented; controlled restoration test pending |
| Bluetooth radio off/on | owner or automated device control | reconnect intent survives radio state reset, saved UUID tried first | Source implemented; physical matrix pending |
| iPhone reboot | reboot while gateway remains powered | no manual Forget/Pair, fresh process and physical link | Pending |
| Rapid ignition/power cycling | production OBD power path | no capture corruption, retained prior segment, automatic reconnect | Pending vehicle run |
| Capture download interruption | disconnect during a nonempty chunked export | live health remains connected or recovers; sync resumes exact offset | dev28/dev29 architecture implemented; nonempty physical run pending |
| OTA power loss | cut rail during inactive-slot upload and probationary boot | current image survives upload cut; rollback after failed probation | Pending signed-release gate |
| Extended soak | 8–24 hours connected plus scheduled faults | no reboot loop, memory/queue growth, sequence corruption, or manual action | Pending |

## Physical evidence: iOS 0.3.3 (9) and firmware 0.1.0-dev.29

The first strict six-cycle run intentionally found a defect: after an app-process kill, iOS
restored an already-connected `CBPeripheral` whose notification state belonged to the previous
process. Reconnect attempts then failed with `CBError.encryptionTimedOut` until the 55-second budget
expired. The failed record is retained locally at
`build/fault-injection/20260817-214417/`.

The correction treats every connected or connecting object inherited from a previous process as a
cleanup target. It cancels that physical link, preserves the handshake-verified UUID and iOS bond,
waits for disconnect or a four-second cleanup boundary, then opens one fresh physical link. This
produces one current-process delegate, one confirmed CCCD, and one new VHOS handshake.

The repeated run at `build/fault-injection/20260817-214822/` passed baseline plus six faults:

| Cycle | Fault | Recovery to five health frames |
| ---: | --- | ---: |
| 0 | baseline | 36.242 s; included stale connecting cleanup and an incidental -96 dBm scan |
| 1 | ESP reset | 15.642 s |
| 2 | app relaunch | 15.421 s |
| 3 | ESP reset | 23.528 s |
| 4 | app relaunch | 15.721 s |
| 5 | ESP reset | 15.674 s |
| 6 | app relaunch | 15.301 s |

Every cycle produced `HANDSHAKE_VERIFIED firmware=0.1.0-dev.29` and five subsequent health frames.
ESP boot evidence retained one local and one peer bond record. App-process recovery explicitly
terminated inherited links with controller reason 531 (`remote-user-terminated`) before opening a
fresh link. No Settings removal, NVS erase, manual Connect, or Pair approval was used.

Stopped-file evidence digests:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `iphone.log` | 52,830 | `8e69b27fee14ccfeabaf782358c37c08c841a93ec3651392836fdc87892e445a` |
| `esp32.log` | 112,808 | `53039c2dad6a0a34163fb8df14e3b9c34aa1b873cb6df748ac743e2b3e36b6f9` |
| `summary.json` | 5,001 | `02f66748be69083ff5de496da36e86f9a0fe5dbc9b699ea2e9178365fd4fe43e` |

These raw logs are local engineering evidence and are not represented as publicly retrievable
artifacts. The facts and hashes above are the versioned public record.

### Pre-car gate discovery: marginal RF was contaminating diagnosis

The first one-command `quick` run at `build/precar-acceptance/20260817-220304/` passed the clean
ESP-IDF build, signed iPhone build, strict code-signature check, install, and ten-frame health soak.
Its mixed recovery phase then failed honestly: one exact-dev29 session delivered only three of five
required health frames before `CBError.connectionTimeout`.

A focused reset rerun passed, including a new exact-dev29 handshake and five health frames, but
needed 49.270 seconds. The following app-relaunch baseline exposed the missing environmental
variable: the supported gateway advertisement was measured at `-90 dBm`, and the physical link
timed out about one second after connecting. That is weak enough to invalidate a protocol
commissioning conclusion. The aggregate pre-car result therefore remains `FAIL`; the isolated pass
does not overwrite it.

The app now emits `LINK_RSSI` from `CBPeripheral.readRSSI()` under the same link-scoped delegate
epoch used for GATT callbacks. The harness requires that exact-session measurement before accepting
the handshake and records both the observed value and required floor. A phone or gateway left too
far away now fails immediately with an actionable RF-precondition message, instead of spending the
recovery budget in encryption or supervision timeouts and encouraging an unrelated firmware change.

After installing that measurement build and restoring good bench geometry, the RSSI-qualified
`quick` profile at `build/precar-acceptance/20260817-2215-rssi-quick/` passed:

| Phase/cycle | Current-link RSSI | Required evidence | Result |
| --- | ---: | --- | --- |
| Ten-frame health soak | -62 dBm | exact dev29 handshake + 10 health frames | PASS in 25.644 s, including inherited-link cleanup |
| Mixed baseline | -64 dBm | exact dev29 handshake + 5 health frames | PASS in 15.074 s |
| ESP execution reset | -63 dBm | reboot/self-test + new link + exact dev29 handshake + 5 health frames | PASS in 14.967 s |
| iPhone app-process death | -68 dBm | inherited-link retirement + new link + exact dev29 handshake + 5 health frames | PASS in 15.355 s |

No Pair sheet, Settings removal, NVS erase, manual Connect, decode failure, exhausted handshake,
panic, stack/heap fault, assertion, or task watchdog occurred. The earlier weak-signal failure
remains part of the engineering record; the later pass proves recovery only for the declared RF
precondition.

Stopped-file evidence digests for the RSSI-qualified run:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| aggregate `summary.json` | 4,771 | `a2518673394d589c94957a1f3a8f9fd9138a924f812169297a164966f48af888` |
| health-smoke `iphone.log` | 10,052 | `e6c5fa1e85ebaa93fa4b79294fe67ff564afab17916d6c7239e2c970ce724ee8` |
| health-smoke `esp32.log` | 19,940 | `e4a3e0d5d312aec828d14b70d0069874f891dc7fe57187b634f5678474d32413` |
| mixed-recovery `iphone.log` | 23,102 | `bb74a208b811e61c6b249e1d4095995777fef2d2599305d3886681af071e2ad3` |
| mixed-recovery `esp32.log` | 42,872 | `afac06cf6c4f36ed961d1ec1421d1184b226fa40bff682233d748db9af53f18e` |

## Acceptance policy

A release candidate fails if any cycle:

- uses a handshake or health frame emitted before its fault marker;
- connects physically but does not verify the versioned application contract;
- lacks a current-link RSSI measurement or falls below the declared acceptance floor;
- exceeds the configured total recovery budget;
- asks the owner to forget or re-pair a still-compatible bonded device;
- mutates capture evidence, weakens listen-only CAN, or promotes unavailable vehicle data;
- calls a reset, process kill, or radio disconnect an electrical power test.

The current result closes the exercised reset and app-process-loss subset. True electrical loss,
vehicle-powered cycling, nonempty capture export interruption, iPhone reboot/radio reset, OTA
power loss, and long-duration soak remain explicit gates.
