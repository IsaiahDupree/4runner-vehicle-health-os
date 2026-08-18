# CAN discovery display baseline — 2026-08-18

- Status: implemented engineering analyzer; Android `0.1.0-dev.6` display implementation in the
  peer repository; vehicle-signal meanings remain unaccepted.
- Analysis contract: `can.discovery.report@1.0.0`.
- Machine-readable result:
  [`can-discovery-2026-08-18.report.json`](../evidence/can-discovery-2026-08-18.report.json),
  31,324 bytes, SHA-256
  `057876190c2162173dc97c826e399dc144e75c8c6fbab5766f62cead92a3ce17`.
- Authority: `DISCOVERY_CANDIDATE`. This record does not create a Vehicle Signal Pack.

## Outcome

The saved iPhone evidence can already support a useful CAN Discovery screen without inventing
Toyota meanings. The screen separates:

1. **proven acquisition facts** derived directly from every retained observation;
2. **raw statistical candidates** whose algorithm and evidence boundary are visible; and
3. **blocked semantic values** such as RPM, speed, gear, throttle, steering, and health ratings.

The Android head-unit implementation reads its append-only `can_observations` table. That table is
populated only after a complete VHOS frame, its CRCs, source identity, capture-record CRC, and
`listen_only=true` proof pass. Analysis never replaces or mutates the raw rows.

## Refreshed iPhone evidence

The installed iPhone app was copied read-only after the latest vehicle sessions. Five durable
gateway-flash NDJSON sessions contain 2,544 retained observations. The portable logical-frame
store contains 1,662 CRC-protected VHOS frames: 66 handshakes, 256 live CAN previews, 1,194 health
frames, 54 capture indexes, and 92 capture chunks.

| Session | Records | Duration (s) | Sequence span | Estimated observed rate (frames/s) | Retained rate (records/s) | Coverage |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 740,616,386 | 864 | 23.533 | 1–12,664 | 538.103 | 36.715 | 6.823% |
| 1,007,674,331 | 432 | 11.676 | 1–6,404 | 548.389 | 36.999 | 6.746% |
| 1,846,258,254 | 600 | 16.313 | 1–8,803 | 539.571 | 36.781 | 6.816% |
| 2,020,748,856 | 312 | 8.364 | 1–4,653 | 556.187 | 37.302 | 6.705% |
| 4,020,849,719 | 336 | 9.100 | 1–4,895 | 537.811 | 36.924 | 6.864% |

Aggregate acquisition result:

| Metric | Result | Display authority |
| --- | ---: | --- |
| Retained records | 2,544 | Proven raw evidence count |
| Sessions / gateways | 5 / 1 | Proven source identities |
| Identifier population | 17 | Proven within this retained set |
| Bitrate | 500 kbit/s | Proven on all records |
| Identifier format | 2,544/2,544 standard 11-bit | Proven |
| Remote-request frames | 0 | Proven within this retained set |
| Listen-only proof | 2,544/2,544 | Proven |
| Total sampled duration | 68.986 s | Proven from gateway monotonic time |
| Estimated observed traffic | 542.342 frames/s | Sequence/time estimate, explicitly labeled |
| Retained-record rate | 36.877 records/s | Proven sampled persistence rate |
| Sequence coverage | 6.799% | Proven sampling coverage, not a drop rate |

The expanded third session grew from 192 to 600 synchronized records. It is the reason this
baseline supersedes the 2,136-record snapshot in the earlier analysis record while preserving that
record's focal-session calculations.

## What the application may display now

### Acquisition facts

- gateway/source and capture-session identities;
- retained records and source-sequence span;
- source monotonic duration;
- standard versus extended identifier counts;
- bitrate, DLC, RTR, and listen-only flags;
- unique identifier population;
- raw payload bytes and per-byte minimum/maximum;
- unique-payload and payload-change counts;
- sequence-derived observed-rate estimate;
- retained-record rate and sequence coverage; and
- gateway-reported RX, queue, storage, bus-error, and bus-off counters when present.

These values describe the evidence system and observed bytes. They do not claim that a vehicle
component is healthy or faulty.

### Raw candidates

The screen may show each of the following only with `CANDIDATE`, the raw field identity, and the
analysis version:

- big-endian 16-bit word range, mean, and standard deviation;
- byte/bit transition activity;
- bounded nearest-time raw-field correlations and ratios;
- repeated-channel agreement;
- counter/checksum likelihood; and
- later, correlation with owner markers and independently accepted references.

The current aggregate report finds:

- eight identifier families with 2,048/2,048 matches under the candidate additive-checksum rule:
  `0x022`, `0x023`, `0x025`, `0x223`, `0x2C1`, `0x2C4`, `0x2D0`, and `0x420`;
- `0x025` bytes 4, 5, and 6 agree across all 327 retained records in the expanded set, while the
  shared raw value spans 115–255;
- generic nearest-time comparison of raw `BE16[0]` fields gives correlation `0.964242` between
  `0x2C4` and `0x2D0` across 323 pairs, with median right/left ratio `1.985061`; and
- `0x2C1`, `0x025`, `0x2C4`, `0x023`, `0x022`, and `0x2D0` remain the most change-rich retained
  families under the versioned ranking.

The expanded sessions include zero-valued and wider-range states not present in the original
settled-idle window. That correctly lowers the all-session `0x2C4`/`0x2D0` correlation from the
focal window's approximately 0.994–0.996. It is evidence that operating-state segmentation is
required, not permission to cherry-pick a stronger number.

### Values deliberately blocked

The production UI must not yet display any raw field as:

- engine RPM or idle quality;
- vehicle or wheel speed;
- transmission gear, input speed, output speed, or converter slip;
- throttle/pedal position;
- steering angle, yaw, lateral acceleration, or torque;
- brake pressure;
- coolant, transmission, differential, or ambient temperature; or
- a normal/abnormal score, diagnosis, recommendation, or component-health conclusion.

Those names require an accepted `signal.definition`, exact byte order/width, signedness,
scale/offset, unit, applicability, provenance, golden replay, missing/stale/range behavior, and an
independent reference capture.

## Analyzer command

The engineering CLI validates every NDJSON record before analysis and rejects an unsupported
contract, unsupported bitrate, invalid identifier/DLC/data shape, duplicate
`gateway_id + session_id + source_sequence`, bad timestamp, or absent listen-only proof.

```bash
.venv/bin/vhos discover-can path/to/passive-can-recent-logs.ndjson \
  --output build/can-discovery.report.json
```

Directories are accepted and scanned recursively for `.ndjson` files. The output records each
input's byte count, record count, and SHA-256 so an analysis can be tied back to the exact export.

## Android display behavior

The separate public Android repository implements the same `1.0.0` boundary:

- **Analyze saved CAN** reads a bounded snapshot of append-only observations off the UI thread;
- the card says **CANDIDATES ONLY**, not healthy/decoded;
- facts, raw activity, integrity candidates, relationships, and the interpretation lock are
  visually separated;
- analysis can run while BLE is offline because persisted evidence is the source;
- an empty database reports no evidence rather than zeros that look like vehicle values; and
- repeated analysis is idempotent because it writes no derived replacement rows.

If more than 100,000 observations exist, the screen states the analyzed count versus total rows.
A future durable calculation-run implementation must persist the exact analysis input identities,
algorithm version, and output hash before any discovery result can participate in lineage.

## Next validation captures

The highest-value next trip is not a longer unlabeled drive. It is one synchronized experiment
with explicit markers and an independent reference:

1. ignition off / accessory / start / settled warm idle;
2. three separated throttle blips while parked;
3. steering center / left / center / right / center;
4. brake rest / press / release repeated three times;
5. A/C off / request / compressor cycling where observable;
6. parked-to-drive transition, bounded acceleration, steady speed, coast, and stop; and
7. simultaneous reference-tool values with clock mapping and uncertainty.

The analyzer can then rank marker-linked fields. A reviewer—not the analyzer—promotes a candidate
through the Vehicle Signal Pack process.
