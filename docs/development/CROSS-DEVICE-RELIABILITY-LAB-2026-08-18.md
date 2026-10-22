# Cross-device reliability lab — 2026-08-18

Status: device-free deterministic matrix implemented and passing  
Contract: `transport.link-reliability-matrix@1.0.0`  
Evidence source: `REAL_CAPTURE_REPLAY`  
Required UI label: `HISTORICAL REPLAY • NOT LIVE`

## Outcome

The captured 4Runner CAN corpus can now exercise the ESP32-to-iPhone-to-Android data contract
without returning to the vehicle. The current host run passes all 15 expected outcomes across
175,984 reconstructed VHOS wire deliveries. The clean soak alone carries 103,520 deliveries
(5,176 immutable real records repeated 20 times) through the deployed header, CRC32C, payload,
fragmentation, decoder, epoch, ordering, and evidence-identity boundaries.

This closes a device-free testing gap. It does **not** replace hardware-in-loop validation of RF
coexistence, ESP32/NimBLE buffers, iOS Core Bluetooth scheduling, the head unit's vendor Bluetooth
stack, power interruptions, or live vehicle-bus load.

## Evidence under test

The immutable corpus at `test-replay/real-can-2026-08-18/` contains:

- 5,176 retained listen-only records;
- 8 capture sessions;
- 17 standard 11-bit identifiers;
- 500 kbit/s CAN evidence;
- 140.831 seconds of source capture time;
- an estimated 75,899 observed frames at 538.88 frames/s;
- 36.753 retained records/s and 6.8196% sampling coverage;
- a corpus semantic digest of
  `94b5e7a86d062f81509c6a442aa9229800dc691860464abfb1dd22053b10aab5`.

Retained sampling coverage is not CAN loss. Transport loss, decoder corruption, queue overflow,
and source sampling remain separate counters.

## Boundary exercised

```text
immutable real CAN records
        |
        v
deployed 36-byte VHOS frame + CRC32C
        |
        v
deterministic ATT-like fragmentation / impairment
        |
        v
incremental stream decoder + bounded resynchronization
        |
        v
physical-link epoch gate
        |
        v
outer-sequence ordering gate
        |
        v
(gateway, capture session, source sequence) identity deduplication
        |
        v
exact surviving raw observations
```

No replay output is published as live vehicle state. No raw identifier receives a vehicle meaning
because it survives this matrix.

## Scenario matrix

| Scenario | Injected condition | Required outcome | Current result |
| --- | --- | --- | --- |
| Clean soak | 20 complete corpus cycles, hostile chunk sizes | exact first-copy evidence; repeated identities rejected; no decoder recovery | PASS / HEALTHY |
| ATT MTU 23 | 20-byte notification payloads | exact order and payload | PASS / HEALTHY |
| MTU churn | 20/61/97/185/244-byte cycle | chunk boundaries remain irrelevant | PASS / HEALTHY |
| Burst delivery | 64 complete wire frames per callback | exact order; bounded decoder buffer | PASS / HEALTHY, 4,608-byte maximum |
| Jitter/short stall | deterministic 2.5-second stalls | remain below the 18-second supervision budget | PASS / HEALTHY |
| Duplicate frame | repeat every 37th complete frame | accept the evidence identity once | PASS / DEGRADED |
| Duplicate notification | repeat one fragment every 43rd frame | reject damaged frame; recover later exact records | PASS / DEGRADED |
| Notification loss | remove one fragment every 41st frame | loss is explicit; next CRC-valid frame recovers | PASS / DEGRADED |
| Payload corruption | flip one payload bit every 43rd frame | CRC rejects it; later records remain exact | PASS / DEGRADED |
| Notification reorder | swap two fragments every 47th frame | affected frame rejected; later records remain exact | PASS / DEGRADED |
| Mid-frame reconnect | split every 53rd frame across epochs | dead bytes cleared; old tail rejected; next epoch recovers | PASS / DEGRADED |
| Stale prior epoch | deliver an old complete callback after reconnect | reject before decode/persistence | PASS / DEGRADED |
| Supervision timeout | deterministic 20-second outage every 211th frame | clean reconnect; no stale acceptance | PASS / DEGRADED |
| Bounded queue overrun | omit every 97th complete delivery | outer-sequence gap exposes loss even without CRC damage | PASS / DEGRADED |
| Mixed interference | loss, corruption, reorder, duplicates, reconnects | only expected casualties; exact later recovery | PASS / DEGRADED |

`DEGRADED` is the correct observation for an intentionally damaged scenario. A degraded scenario
passes only when degradation is detected, no unexpected record is accepted, the exact expected
survivors remain ordered and byte-identical, and the decoder returns to an empty bounded buffer.

## Acceptance budgets

1. Clean paths accept zero unexplained loss, mutation, reordering, stale epochs, or duplicate
   evidence identities.
2. A corrupt/incomplete logical frame may be lost; the next CRC-valid frame must recover without
   silently changing later observations.
3. A physical reconnect clears partial bytes but preserves quality counters and durable evidence
   identities.
4. A callback from a prior link epoch is rejected before it reaches the decoder or evidence store.
5. Outer sequence regression is rejected. Forward gaps become communication-quality evidence.
6. Incremental decoder memory must remain at or below 262,144 bytes in this lab. The current
   maximum is 4,608 bytes.
7. A 2.5-second application stall remains below the modeled 18-second supervision budget. A
   20-second stall must produce a degraded reconnect path.
8. Communication degradation is never converted into a vehicle-health finding.

## Platform implementation

### Python / CI oracle

`vhos test-link-reliability` runs the full matrix over the checksum-pinned corpus. GitHub Actions
runs a 20-cycle soak on every product branch push and pull request.

```bash
.venv/bin/vhos test-link-reliability \
  test-replay/real-can-2026-08-18 \
  --soak-cycles 20 \
  --output build/link-reliability-matrix.json
```

### iPhone core

`TransportReliabilityLedger` provides the same durable evidence identity, current physical-link
epoch, duplicate rejection, outer-sequence regression/gap, and reconnect counters. Swift tests use
the pinned real-capture fixture for a 40-cycle soak, burst delivery, notification loss, payload
corruption, reordering, reconnect buffer reset, and stale-epoch rejection.

### Android head unit

`LinkReliabilityLab` runs the same 15 conditions against observations already in the encrypted
append-only store. The app exposes **Run reliability matrix** and renders every scenario's expected
quality, acceptance, exact record counts, induced loss, duplicate rejection, stale rejection, and
reconnect count. This operation is offline and does not take ownership of either ESP32.

Android's recovery counter now resets only after a CRC-valid VHOS handshake. Merely rediscovering
an advertisement does not erase prior GATT/scan failures, so repeated platform-code-3 or validation
failures reach the intended exponential cooldown instead of looping forever at attempt 1.

## What the Android display may safely show now

The full corpus supports these raw, versioned discovery candidates:

- additive-checksum candidate at 100% within the retained evidence for `0x022`, `0x023`, `0x025`,
  `0x223`, `0x2C1`, `0x2C4`, `0x2D0`, and `0x420`;
- `0x025` bytes 4, 5, and 6 agree with maximum disagreement 0 across 667 retained records, raw
  range 115–255;
- raw big-endian word correlation `0x022[0:16]` ↔ `0x223[0:16]` = -0.999643 across 142 paired
  samples, median raw ratio 0.062868;
- raw big-endian word correlation `0x2C4[0:16]` ↔ `0x2D0[0:16]` = 0.992130 across 625 paired
  samples, median raw ratio 1.979058.

The head unit now displays those identifiers, sample counts, checksum match rates, raw ranges,
correlations, and ratios with `MEANING UNVERIFIED`. It must not label them RPM, throttle, steering,
brake, gear, speed, or health until synchronized Techstream/SAE J1979 evidence creates a versioned
accepted Signal Pack.

## Hardware-in-loop gate for the next device session

The next visit should be shorter because the software-only failure classes are already covered.
Run the remaining physical matrix with synchronized ESP32 UART, iPhone trace, and Android trace:

1. 30-minute sustained live stream at observed vehicle traffic with zero unexplained queue drops;
2. Bluetooth/Wi-Fi coexistence with the head unit, CarBT, and hotspot active;
3. controlled RSSI walk from strong through fringe range and back;
4. ESP32 hard power loss during idle, live stream, and capture-history transfer;
5. iPhone app foreground/background/termination and Android service restart;
6. explicit iPhone ↔ Android gateway ownership handoff;
7. forced capture-history congestion while live recording remains protected;
8. 20 reconnect cycles with the saved bond and no Settings → Forget step;
9. real OTA/status flow only while parked and under the existing signed-image gates.

Each physical failure must retain exact timestamps, link epoch, platform status/error, firmware
identity, queue/drop counters, decoder counters, and the last CRC-valid evidence identity.
