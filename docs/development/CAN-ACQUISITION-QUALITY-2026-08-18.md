# CAN acquisition quality baseline — 2026-08-18

## Purpose

This record separates facts proven by the gateway from signal-discovery candidates and from
vehicle-health conclusions that are still blocked. A source-sequence gap in an exported sampled
log is not automatically a CAN receive failure.

## Current vehicle-run evidence

The final `0.1.0-dev.31` health report from the 2026-08-18 vehicle run reported:

| Field | Result | Authority |
| --- | ---: | --- |
| Passive network candidate | `CAN_11_500` | Multi-frame listen-only lock |
| Valid frames read by TWAI | 29,200 | Gateway counter |
| Standard / extended format | 29,200 / 0 | Gateway counters |
| TWAI missed + overrun aggregate | 230 | Gateway aggregate in dev.31 |
| Aggregate receive-loss ratio | approximately 0.78% | `230 / (29,200 + 230)` |
| Bus errors | 15 | Gateway counter; all appeared before the stable interval |
| Bus-off events | 0 | Gateway counter |
| Retained records in this capture session | 1,984 | Flushed capture index on the next boot |
| Capture queue drops | 0 | Capture-store counter |
| Capture storage write failures | 0 | Capture-store counter |

The frame count progressed at approximately 526 frames per second. The final count remained at
29,200 for about five seconds before the BLE connection timed out, so the evidence supports the
inference that vehicle-bus traffic or gateway power ended before the phone link disappeared. It
does not support an ESP32 crash claim.

The app deliberately did not download log history while the recorder was active. Every active-run
index response selected inventory-only mode, and the raw session remained on the gateway. This is
the intended protection against BLE/file transfer competing with the receive path.

## What the saved raw CAN evidence proves

Across all seven synchronized sessions currently stored on the iPhone, the regenerated
`docs/evidence/can-discovery-2026-08-18.report.json` records:

- 3,192 retained records across 86.441 seconds;
- a combined source-sequence span of approximately 46,722 observations, or 540.426 frames per
  second;
- a retained rate of 36.927 records per second and 6.8319% intentional sampling coverage;
- the same 17 standard 11-bit identifiers at 500 kbit/s in every session;
- 2,571 of 2,571 applicable retained frames matching the Toyota additive-checksum candidate;
- perfect agreement among `0x025` bytes 4, 5, and 6 in all 410 retained records;
- a `0x2C4[0:16]` to `0x2D0[0:16]` median ratio of 1.982738 and Pearson correlation of
  0.962991 across 384 monotonic, one-to-one nearest-time pairs.

Those repeated results make the raw relationships useful experiment targets, but do not promote
them to vehicle signals. The aggregate includes multiple operating states, including zero and
sentinel-like values, so it must not be used to infer units or normal ranges.

The latest synchronized raw session available before the 1,984-record run contains 408 retained
records over 10.99 seconds and a source-sequence span of 5,865:

- estimated observed traffic: 533.576 frames per second;
- retained record rate: 37.125 records per second;
- retained coverage: 6.9565%;
- 17 standard 11-bit identifiers at 500 kbit/s;
- no extended or remote-request frames in the retained sample;
- eight identifiers with a 100% Toyota additive-checksum candidate match across 330 applicable
  retained frames;
- `0x025` bytes 4, 5, and 6 agreed in all 52 retained records, with values from 120 through 127;
- `0x2C4[0:16]` ranged from 1,461 through 1,520 in that session;
- `0x2D0[0:16]` ranged from 2,882 through 3,023, with a median ratio of about 1.976 to
  `0x2C4[0:16]` and Pearson correlation about 0.851 across 50 monotonic, one-to-one nearest-time
  pairs (maximum timestamp separation 103,129 microseconds).

The checksum construction, repeated-channel relationship, ranges, and raw-word relationship are
discovery candidates. The identifiers are not accepted as RPM, throttle, steering, transmission,
or any other semantic vehicle signal until synchronized SAE J1979 or Toyota Techstream evidence
validates the meaning, byte order, scale, offset, and operating-state boundary.

The analyzer consumes each retained sample at most once when calculating cross-ID correlation.
This prevents one sparse sample from inflating a relationship by being paired to several denser
samples. The earlier reusable-nearest calculation was therefore superseded by the more
conservative value above.

## Why 6.96% retained coverage is not 93.04% loss

The gateway assigns a source sequence to every frame delivered to its observer pipeline, but the
flash recorder intentionally retains changed identifiers more frequently than unchanged ones.
Therefore:

- `retained_records / source_sequence_span` is the persistence sampling density;
- TWAI missed and overrun counters identify controller-side receive loss;
- observer-queue drops identify software fan-out loss;
- capture-queue drops identify sampled records that could not reach the writer;
- storage-write failures identify records rejected by durable storage.

Only those explicit counters may be used for loss attribution. Missing sampled sequence positions
must never be converted into a vehicle fault or a gateway drop claim.

## Development response

Firmware `0.1.0-dev.32` introduces a bounded two-stage receive pipeline:

1. a priority-12, core-1 TWAI task drains up to 64 frames per batch from a 512-entry driver queue;
2. a 256-entry observation queue transfers complete, timestamped records to a priority-9 dispatch
   task on the other core;
3. capture sampling, BLE live display, and passive J1979 parsing run from the dispatch task rather
   than the critical TWAI drain loop.

The health contract adds independent counters and pressure measurements for:

- TWAI missed frames;
- TWAI overrun frames;
- current TWAI queue depth and capacity;
- observer-queue drops;
- current observer depth, high-water mark, and capacity;
- capture-observed, sampled, policy-suppressed, retained, queue-dropped, and write-failure counts.

iOS `0.3.9 (15)` displays these layers separately. Its Evidence screen adds a single
**Pause, download, and resume** action. It flushes the recorder, transfers both retained segments,
then automatically resumes logging. The request carries a history-transfer reason so dev.32 also
resumes recording if that BLE session resets before the phone can finish.

## Next physical gates

1. Download the preserved 1,984-record dev.31 session before flashing new firmware.
2. Replay and analyze that exact NDJSON without assigning unvalidated signal names.
3. Flash dev.32 without erasing NVS or the storage partition.
4. Repeat the same parked vehicle capture for at least five minutes.
5. Accept acquisition quality only if observer drops, capture drops, write failures, and bus-off
   remain zero and the TWAI loss ratio materially improves from the dev.31 0.78% baseline.
6. Correlate `0x2C4`, `0x025`, and `0x2C1` with synchronized SAE J1979/Techstream values before
   promoting any signal definition into the 4Runner Vehicle Signal Pack.
