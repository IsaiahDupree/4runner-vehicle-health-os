# Passive CAN capture analysis and acquisition roadmap — 2026-08-17

- Status: replay-verified against the immutable evidence copied from the installed iPhone app on
  2026-08-17/18.
- Source artifact: `iphone-vhos-evidence-20260817T2222-0400.zip`, 250,600 bytes, SHA-256
  `6654e436c4945bc9d712c8c761b7769a56e2c6046976002e5135c6ffebfcf0b1`. The archive remains a
  local evidence artifact rather than a public source file.
- Decoder authority: every CAN identifier, field meaning, byte order, and scale below is a
  `DISCOVERY_CANDIDATE`, not an accepted 4Runner Vehicle Signal Pack definition.

An expanded 2,544-record refresh and the implemented `can.discovery.report@1.0.0` display boundary
are recorded separately in the
[2026-08-18 CAN discovery display baseline](CAN-DISCOVERY-DISPLAY-BASELINE-2026-08-18.md). This
document retains the original 2,136-record snapshot and focal-session calculations rather than
silently rewriting their evidence boundary.

## Outcome

The capture reportedly contains strong, coherent 11-bit CAN traffic at 500 kbit/s and is already
useful for acquisition-health, timing, checksum, stability, correlation, and experiment design.
Its main limitation for reverse engineering is intentional retained-record sampling, not proven
TWAI loss. The immediate acquisition priority is therefore a lossless binary capture mode with
explicit drop/error accounting, followed by synchronized experiment markers and an automatic
signal-discovery analyzer.

This record preserves the analysis while enforcing the project rule that an interesting
correlation is not yet a decoded vehicle signal.

## Acquired iPhone evidence set

The iPhone container copy reproduced the original 336-record focal capture and added four more
sessions from the same gateway. All 2,136 retained records report 11-bit, non-RTR, 500 kbit/s,
listen-only CAN. Seventeen identifiers occur in every session.

| Session ID | Records | Duration (s) | Sequence span | Estimated observed rate (frames/s) | Retained rate (records/s) | Sequence coverage |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 740,616,386 | 864 | 23.532650 | 1–12,664 | 538.103 | 36.672 | 6.822% |
| 1,007,674,331 | 432 | 11.676020 | 1–6,404 | 548.389 | 36.913 | 6.746% |
| 1,846,258,254 | 192 | 5.130097 | 1–2,861 | 557.494 | 37.231 | 6.711% |
| 2,020,748,856 | 312 | 8.364094 | 1–4,653 | 556.187 | 37.183 | 6.705% |
| 4,020,849,719 | 336 | 9.099846 | 1–4,895 | 537.811 | 36.814 | 6.864% |

The portable evidence store contains 1,599 CRC-protected VHOS logical frames:

| Message type | Meaning | Frames |
| ---: | --- | ---: |
| 1 | Handshake | 65 |
| 2 | Live raw CAN sample | 221 |
| 4 | Gateway health | 1,185 |
| 12 | Persistent-capture index | 53 |
| 13 | Persistent-capture chunk | 75 |

The six strongest change-rich discovery candidates across the retained set are `0x022`, `0x023`,
`0x025`, `0x2C1`, `0x2C4`, and `0x2D0`. That ranking is based only on payload diversity; it grants
no semantic name, unit, scale, or health authority.

The focal session's Toyota-style checksum result was also reproduced. For the eight candidate
families listed below, the final data byte equals the low eight bits of the 11-bit identifier's two
bytes, actual DLC, and preceding payload bytes. The result is 271 valid of 271 applicable retained
frames. This remains a candidate family rule until controlled corruption vectors and exact model
applicability are versioned.

## Reproduced focal-capture metrics

| Metric | Reproduced result | Evidence meaning |
| --- | ---: | --- |
| Capture duration | 9.10 s | Short field snapshot |
| Exported records | 336 | Records present in the analyzed NDJSON |
| `source_sequence` span | 1–4,895 | Gateway observation sequence covers substantially more frames than the sampled export |
| Estimated observed bus rate | ~537.5 frames/s | Plausible active vehicle-network traffic |
| Exported-record rate | ~36.9 records/s | Retained/exported subset, not raw receive throughput |
| Sequence coverage in export | ~6.86% | Expected to be incomplete under the `dev.11` per-ID flash sampling policy |
| Unique exported CAN IDs | 17 | Visible population in this short sampled interval |
| Change-rich IDs | `022`, `023`, `025`, `2C1`, `2C4`, `2D0` | Candidates for controlled experiments |
| Toyota-style checksum results | 271/271 applicable frames valid | Strong candidate payload-integrity evidence; algorithm/applicability still requires versioned model validation |
| Frame configuration | 11-bit, 500 kbit/s | Strongly supported by the passive gateway lock and capture |

### Critical interpretation of sequence coverage

Firmware `v0.1.0-dev.11` does not attempt lossless flash persistence. It observes every frame
presented by the TWAI receive task, then retains changed payloads at no more than 5 Hz per ID and
unchanged payloads at no more than 1 Hz per ID. Consequently:

- a gap in exported `source_sequence` values is expected;
- it is not equivalent to a TWAI RX queue drop;
- it is not equivalent to a flash-writer queue drop;
- it must never be interpreted as a vehicle fault; and
- true loss must be measured through the gateway's RX missed/overrun, capture-queue drop, and
  storage-write failure counters.

The reported linear relationship between sequence and monotonic time can still estimate observed
bus rate because sequence is assigned before sampling.

## Candidate metrics available without accepting signal meanings

### Settled-window stability

Replay of the focal capture produces a rotational candidate at `0x2C4` with:

| Window | Mean | Minimum | Maximum | Standard deviation | CV |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whole 9.10 s capture | 1,389 candidate units | 1,314 | 1,549 | ~54 | not reported |
| `t >= 4 s` | 1,370.9 candidate units | 1,362 | 1,386 | 5.27 | 0.38% |

If a controlled reference later confirms that field as engine RPM, versioned calculations may
include:

- `idle_mean_rpm`
- `idle_stddev_rpm`
- `idle_peak_to_peak_rpm`
- `idle_cv`
- `idle_drift`
- `idle_dropouts`
- `idle_oscillation_frequency`

Until then, the same algorithms may run only against a candidate field identity and must not label
the result as engine idle or compare it with a health threshold. The capture does not establish
operating temperature, cold-start state, A/C state, engine variant, commanded idle, or acceptable
idle range.

### `0x2D0` relationship candidate

The first two bytes of `0x2D0` vary from approximately 2,599 to 3,099 while the compared `0x2C4`
candidate varies from approximately 1,314 to 1,549. Reproduced findings:

- correlation: approximately `0.994–0.996`, depending on the bounded nearest-time pairing rule;
- median ratio: approximately `1.981`; and
- provisional relation: `2D0_word ~= 2 * 2C4_candidate` in this capture.

This is a high-priority discovery candidate, not a semantic identification. It may represent a
redundant engine-speed field, transmission/turbine/input speed, calculated rotational state, or
another correlated quantity.

Required controlled sequence:

1. PARK: stable idle and separated throttle blips.
2. DRIVE: bounded acceleration, steady-speed hold, shifts, coast, and stop.
3. Compare `0x2C4`, `0x2D0`, independently verified vehicle speed, verified gear state, and wheel
   speeds.
4. Test whether the ratio remains constant across gear and road-speed changes.

A constant ratio supports a redundant representation hypothesis. Gear-dependent ratios support a
driveline-speed hypothesis. Neither result alone establishes a production decoder.

### `0x025` repeated-channel consistency

For all 43 focal-capture `0x025` records, bytes 4, 5, and 6 are equal, with values spanning 120–126.
A meaning-independent consistency feature can be defined as:

```text
candidate_channel_disagreement = max(byte4, byte5, byte6) - min(byte4, byte5, byte6)
```

Reproduced result: `0` throughout this capture.

This can be used immediately as discovery evidence for repeated fields. It cannot be called a
steering-sensor health metric until the field semantics, redundancy design, scaling, and
applicability are established for the exact 2005 4Runner configuration.

### `0x022` and `0x023` biased-channel hypothesis

Replayed 16-bit candidates cluster near decimal 512 (`0x0200`):

| ID | Candidate word 0 | Candidate word 1 |
| --- | ---: | ---: |
| `0x022` | ~508–510 | ~503–505 |
| `0x023` | ~506–511 | ~526–529 |

This suggests—but does not prove—a biased signed representation where approximately 512 denotes
zero. Stationary, steering, straight-drive, acceleration, braking, left-turn, and right-turn
markers are needed to separate steering, yaw, lateral acceleration, torque, and unrelated
hypotheses.

## Candidate Toyota additive-checksum evidence

The acquired focal capture reproduces 271 valid checks out of 271 applicable frames when the
calculation uses the identifier's two bytes, each frame's actual DLC, and preceding payload bytes,
including a DLC of 7 for `0x023`. Matching IDs:

- `0x022`
- `0x023`
- `0x025`
- `0x223`
- `0x2C1`
- `0x2C4`
- `0x2D0`
- `0x420`

Before this becomes gateway production telemetry, versioned test vectors and controlled captures
must lock down:

1. the exact checksum construction;
2. identifier inclusion/exclusion rules;
3. DLC handling;
4. checksum-byte location per ID/family;
5. behavior on extended/RTR frames; and
6. independent test vectors, including intentionally corrupted frames.

The eventual acquisition-health counters should distinguish:

- CAN frames received;
- frames for which a versioned checksum rule applies;
- checksum passes/failures and per-ID rates;
- TWAI RX queue missed/overrun counts;
- capture-ring and storage-writer drops;
- bus errors and bus-off events; and
- sequence gaps at each pipeline boundary.

## P0 — Lossless Capture V2

### Reason

Verbose NDJSON is an interchange/export format, not a real-time storage format. At the reported
traffic rate, approximately 402 bytes of JSON per frame would consume roughly 216 KB/s or 778
MB/hour. A compact 24-byte record would consume approximately 12.9 KB/s or 46 MB/hour. The current
36-byte CRC-protected flash record would consume approximately 19.4 KB/s or 69.7 MB/hour if every
frame were retained.

The present ESP32 target has only a roughly 960 KiB SPIFFS partition and no verified microSD
interface. Lossless multi-minute/hour capture therefore requires one of:

- physically verified microSD hardware;
- a high-throughput binary Wi-Fi stream to iPhone storage with a bounded RAM/flash fallback; or
- a future logger board with sufficient durable storage.

No microSD pinout or presence may be assumed for the current MrDIY CAN Shield target.

### Proposed binary record

```c
struct LosslessCANRecordV2 {
    uint64_t capture_monotonic_us;
    uint32_t source_sequence;
    uint16_t can_id;
    uint8_t  dlc;
    uint8_t  flags;
    uint8_t  data[8];
}; // 24 bytes
```

The real format must also define endianness, contract/version, capture/session identity, bitrate,
header CRC, record/block CRC, restart recovery, and exact wrap/rotation behavior. If source
sequence can exceed 32 bits over the maximum supported session, retain 64 bits and accept the
larger record.

### Required pipeline

```text
TWAI RX task
  -> bounded lock-free/SPSC RAM ring or equivalent measured queue
  -> block-oriented binary writer
  -> verified durable target or authenticated Wi-Fi bulk stream
  -> offline/background decoder
  -> NDJSON / database / replay bundle
```

The critical receive path must not decode semantic signals, stringify JSON, perform BLE framing,
or issue filesystem syncs per record.

### Required measurements

- `frames_received`
- `frames_enqueued`
- `frames_written`
- `rx_queue_high_water`
- `rx_queue_overflow`
- `capture_ring_high_water`
- `capture_ring_overflow`
- `sequence_gap_count`
- `bus_error_count`
- `bus_off_count`
- `checksum_checked_count`
- `checksum_fail_count`
- `storage_write_latency_p50/p95/max`
- `buffer_fill_percent`
- `bytes_written`
- exact loss reason and pipeline stage

### Acceptance boundary

A lossless claim requires replay of a controlled high-rate source with equality between accepted
RX frames and durable records, or an explicit bounded drop count that reconciles the difference.
Compilation, short sampled export, or a zero application-level counter alone is insufficient.

## P0.5 — Synchronized Experiment Mode

The iPhone should expose explicit owner-controlled experiment markers:

- Idle
- Throttle
- Brake
- Steering
- A/C
- Transmission
- Drive
- Custom event

Each tap creates an immutable marker containing at least:

```json
{
  "contract": "capture.experiment-marker",
  "contract_version": "1.0.0",
  "capture_id": "...",
  "event_id": "...",
  "event_kind": "brake_pressed",
  "capture_monotonic_us": 483920123,
  "phone_epoch_us": 0,
  "gateway_time_sync_id": "...",
  "owner_approved": true
}
```

The app must not pretend the phone and gateway clocks are identical. A time-sync exchange records
offset, round-trip uncertainty, and the mapping version used to place a phone event on the gateway
timeline.

Example controlled brake sequence:

```text
REST -> PRESS -> RELEASE -> PRESS -> RELEASE -> PRESS -> RELEASE
```

The analyzer then ranks fields whose variance, derivative, or transition probability changes in
the marker windows.

## P1 — Automatic signal discovery

For every capture, CAN ID, byte, and bounded bit-field candidate, compute:

- frequency and period/jitter;
- entropy and unique-value count;
- min/max/range;
- bit-transition counts;
- derivative and change-point statistics;
- counter likelihood;
- checksum likelihood;
- correlation with accepted reference signals;
- correlation/lag with experiment markers;
- byte-order, signedness, width, scale, and offset candidates; and
- confidence plus explicit supporting evidence references.

Illustrative output only:

```text
candidate: 0x2D0[0:16]
correlation_to_candidate_0x2C4: 0.994
candidate_scale: approximately 0.5
status: DISCOVERY_CANDIDATE
```

Promotion into a Vehicle Signal Pack requires controlled captures, independent reference values,
applicability metadata, exact decoder equations, version identity, and review. The analyzer may
rank hypotheses; it may not silently publish a decoder.

## P1 — Allowlisted read-only diagnostics

Future diagnostic acquisition should add:

- ISO-TP transport;
- a gateway-resident diagnostic addressing registry;
- bounded timeout/retry and response reassembly;
- supported-PID enumeration;
- ECU inventory and identification/calibration reads;
- read-only live data, DTC, and freeze-frame reads where explicitly allowlisted;
- rate limits; and
- complete request/response evidence.

Arbitrary frame transmission remains absent. Active tests, actuator control, code clearing, ECU
flashing, and configuration writes remain outside MVP authority.

## P1 — Independent reference acquisition

Run the ESP32 capture, an appropriate Toyota diagnostic reference tool, and synchronized iPhone
markers concurrently. Reference values such as engine speed, coolant temperature, throttle,
vehicle speed, A/C request, and compressor command can become supervised labels only when their
source/tool/session/time mapping is preserved.

Any external cross-model Toyota CAN research is discovery context, not proof that the 2005 4Runner
uses identical identifiers or scaling. Source citations and tool behavior described in the
user-provided analysis remain pending verification before they are used in an accepted signal
definition.

## Unified time model

Replace ambiguous ingestion-only timing with explicit fields:

- `capture_monotonic_us`: gateway time at physical acquisition;
- `capture_epoch_us`: epoch estimate plus synchronization identity/uncertainty, when available;
- `ingested_epoch_us`: phone/store arrival time; and
- `source_sequence`: source ordering independent of storage sampling.

CAN, diagnostic responses, pressure, line/ambient temperatures, supply/current, IMU, GPS, and
phone markers must resolve to the same versioned timeline without discarding their distinct source
identities or timing uncertainty.

## Derived telemetry unlocked after validation

Potential future calculations include:

- engine idle stability, warm-up, overshoot, response delay, and roughness proxies;
- wheel/vehicle speed, slip, gear inference, shift duration, and converter/input slip;
- steering angle/rate/center drift and redundant-channel disagreement;
- brake pressure/application rate;
- cranking voltage drop, charging response, and battery recovery; and
- A/C pressure ratio/differential, cycling, superheat, subcooling, cool-down rate, and performance.

Every production result must retain the full lineage:

```text
raw observation
  -> versioned signal definition
  -> feature
  -> versioned equation
  -> calculation run
  -> finding/recommendation
  -> service or inspection
  -> lifecycle baseline
```

## Agreed development order

1. Lossless Capture V2 and explicit drop/error instrumentation.
2. Synchronized Experiment Mode.
3. Automatic signal-discovery analyzer.
4. Allowlisted read-only OBD/ISO-TP query engine.
5. Independent diagnostic-tool comparison.
6. Versioned 4Runner Vehicle Signal Pack.
7. Synchronized A/C and added-sensor acquisition.

The authenticated iPhone Wi-Fi OTA bootstrap remains an enabling infrastructure task because it
reduces future vehicle-development trips. It does not supersede the acquisition order above; it
makes those firmware iterations deployable after the one-time USB bootstrap.
