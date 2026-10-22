# CAN discovery display baseline — 2026-08-18

- Status: implemented engineering analyzer and Android display; vehicle-signal meanings remain
  unaccepted.
- Analysis contract: `can.discovery.report@1.0.0`.
- Authority: `DISCOVERY_CANDIDATE`. This record does not create a Vehicle Signal Pack.
- Current machine-readable result:
  [`can-discovery-2026-08-18-5176.report.json`](../evidence/can-discovery-2026-08-18-5176.report.json),
  33,210 bytes, SHA-256
  `520db9ba0c87c987e83f4019b6a4fe63d8f9ffaabfe2636a8aba049de3863e9d`.
- Reproducible corpus:
  [`test-replay/real-can-2026-08-18`](../../test-replay/real-can-2026-08-18/manifest.json).

## Outcome

Saved iPhone evidence supports a useful CAN Discovery screen without inventing Toyota meanings.
The screen separates:

1. **proven acquisition facts** derived directly from retained observations;
2. **raw statistical candidates** whose algorithm and evidence boundary are visible; and
3. **blocked semantic values** such as RPM, speed, gear, throttle, steering, and health ratings.

The Android head-unit implementation reads append-only `can_observations` rows only after their
VHOS envelope, CRCs, source identity, capture-record CRC, and `listen_only=true` proof pass.
Analysis never replaces or mutates raw rows. The same real observations are also available through
the explicitly historical replay described in
[the offline replay record](REAL-CAN-REPLAY-AND-LOAD-TESTING-2026-08-18.md).

## Current iPhone evidence

Eight durable gateway-flash sessions contain 5,176 retained observations and 2,081,023 source
NDJSON bytes.

| Session | Records | Duration (s) | Sequence span | Estimated observed rate (frames/s) | Retained rate (records/s) | Coverage |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 627,753,796 | 1,984 | 54.390 | 1–29,177 | 536.418 | 36.477 | 6.800% |
| 628,897,492 | 408 | 10.990 | 1–5,865 | 533.559 | 37.123 | 6.957% |
| 740,616,386 | 864 | 23.533 | 1–12,664 | 538.103 | 36.715 | 6.823% |
| 1,007,674,331 | 432 | 11.676 | 1–6,404 | 548.389 | 36.999 | 6.746% |
| 1,846,258,254 | 600 | 16.313 | 1–8,803 | 539.571 | 36.781 | 6.816% |
| 2,020,748,856 | 312 | 8.364 | 1–4,653 | 556.187 | 37.302 | 6.705% |
| 2,175,731,012 | 240 | 6.465 | 179,384–182,821 | 531.672 | 37.126 | 6.981% |
| 4,020,849,719 | 336 | 9.100 | 1–4,895 | 537.811 | 36.924 | 6.864% |

Aggregate acquisition result:

| Metric | Result | Display authority |
| --- | ---: | --- |
| Retained records | 5,176 | Proven raw evidence count |
| Sessions / gateways | 8 / 1 | Proven source identities |
| Identifier population | 17 | Proven within this retained set |
| Bitrate | 500 kbit/s | Proven on all records |
| Identifier format | 5,176/5,176 standard 11-bit | Proven |
| Remote-request frames | 0 | Proven within this retained set |
| Listen-only proof | 5,176/5,176 | Proven |
| Total sampled duration | 140.831 s | Proven from source monotonic time |
| Estimated observed traffic | 538.880 frames/s | Sequence/time estimate, explicitly labeled |
| Estimated observed frames | 75,899 | Sequence-derived estimate |
| Retained-record rate | 36.753 records/s | Proven sampled persistence rate |
| Sequence coverage | 6.8196% | Sampling coverage, not a drop rate |

## What the application may display now

### Acquisition facts

- gateway/source and capture-session identities;
- retained records and source-sequence span;
- source monotonic duration;
- standard/extended identifier counts, bitrate, DLC, RTR, and listen-only flags;
- unique identifier population, raw payload bytes, and raw byte ranges;
- sequence-derived observed-rate estimate, retained-record rate, and sampled coverage; and
- gateway-reported RX, queue, storage, bus-error, and bus-off counters when present.

These values describe evidence acquisition and observed bytes. They do not claim that a vehicle
component is healthy or faulty.

### Raw candidates

The UI may show only with `DISCOVERY_CANDIDATE`, the raw field identity, and the analysis version:

- big-endian 16-bit word range, mean, and standard deviation;
- byte/bit transition activity;
- bounded nearest-time raw-field correlations and ratios;
- repeated-channel agreement;
- counter/checksum likelihood; and
- later, correlation with owner markers and independently accepted references.

The current aggregate report finds:

- eight families with 4,181/4,181 matches under `toyota-additive-id-dlc-payload-v0`:
  `0x022`, `0x023`, `0x025`, `0x223`, `0x2C1`, `0x2C4`, `0x2D0`, and `0x420`;
- `0x025` bytes 4, 5, and 6 agree across all 667 retained records, with raw values 115–255;
- raw `0x2C4 BE16[0]` and `0x2D0 BE16[0]` correlate at `0.992130` across 625 bounded
  nearest-time pairs, with median right/left ratio `1.979058`; and
- raw `0x022 BE16[0]` and `0x223 BE16[0]` correlate at `-0.999643` across 142 pairs.

Correlation strength changes as captures include different operating states. Segmentation is
required; selecting only the strongest window would not establish a meaning.

### Values deliberately blocked

The production UI must not yet label a raw field as:

- engine RPM or idle quality;
- vehicle or wheel speed;
- transmission gear, input/output speed, or converter slip;
- throttle/pedal position;
- steering angle, yaw, acceleration, or torque;
- brake pressure;
- coolant, transmission, differential, ambient, or A/C temperature/pressure; or
- a normal/abnormal score, diagnosis, recommendation, or component-health conclusion.

Those names require an accepted `signal.definition`, exact field shape, signedness, scale/offset,
unit, applicability, provenance, golden replay, missing/stale/range behavior, and an independent
reference capture.

## Analyzer and replay commands

```bash
.venv/bin/vhos discover-can test-replay/real-can-2026-08-18/sessions \
  --output build/can-discovery.report.json
.venv/bin/vhos validate-can-replay-corpus test-replay/real-can-2026-08-18
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode live --repeat 20 --fault clean
```

The analyzer rejects unsupported contracts/bitrates, invalid identifier/DLC/data shape, duplicate
`gateway_id + session_id + source_sequence`, bad timestamps, or absent listen-only proof. The
replay layer additionally verifies manifest hashes, exact decode order, and full record identity.

## Android display behavior

The separate public Android repository implements the same truth boundary:

- **Analyze saved CAN** reads a bounded append-only snapshot off the UI thread;
- facts, raw activity, integrity candidates, relationships, and the interpretation lock are
  visually separated;
- **Replay saved CAN** preserves source timing while **Stress replay ×20** runs full speed;
- replay says **HISTORICAL REPLAY • NOT LIVE**, shows exact raw IDs/bytes/source sequences and
  decoder recovery counters, and cannot update vehicle health;
- an empty database reports no evidence rather than zeros that look like vehicle values; and
- analysis/replay are idempotent because they write no derived replacement rows.

## Next validation capture

The highest-value next trip is one synchronized experiment with explicit markers and an
independent Techstream/SAE J1979 reference: ignition states, settled idle, separated throttle
blips, steering left/center/right, repeated brake actions, A/C request transitions, and a bounded
park/drive/steady/coast/stop sequence. A reviewer—not the analyzer—promotes a candidate through the
Vehicle Signal Pack process.
