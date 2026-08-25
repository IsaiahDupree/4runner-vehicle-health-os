# Offline iPhone field-return analysis — one command

Status: implemented and exercised on returned iPhone evidence
Date: 2026-08-24

## Outcome

One copied iPhone application-data directory is now enough to run the complete
offline acquisition-to-replay loop. The command validates the copy, verifies an
optional earlier copy as an exact append-only prefix, recovers both the complete
and appended portable CAN evidence, creates platform-neutral replay inputs,
runs discovery and checked-in hypotheses, correlates synchronized event markers,
and exercises clean plus degraded transport behavior.

The command is:

```bash
.venv/bin/vhos analyze-field-return \
  build/device-data/2026-08-24-field-return-185114 \
  --baseline build/device-data/2026-08-22-iphone-return-latest \
  --output build/field-return-analysis-2026-08-24-185114 \
  --soak-cycles 20
```

The output directory is published atomically only after every required gate
passes. Read the concise result first:

```text
build/field-return-analysis-2026-08-24-185114/SUMMARY.md
```

The corresponding machine-readable root is:

```text
build/field-return-analysis-2026-08-24-185114/manifest.json
```

## What the single command does

1. Finds the canonical `VHOSPortableFrames/v1/logical-frames.ndjson` ledger.
2. Rejects symbolic links, malformed NDJSON, duplicate JSON keys, unsafe source
   structure, size-limit violations, and missing canonical evidence.
3. Hashes every file in the copied app-data tree and verifies the inventory
   again before publishing results, detecting any source change during analysis.
4. Decodes and validates every portable VHOS envelope, CRC, source role,
   listen-only assertion, session identity, observation identity, and overlap.
5. If `--baseline` is supplied, requires every baseline record to be a
   byte-identical record prefix of the current ledger. A mismatch aborts the
   entire run; it is never treated as a delta.
6. Writes a derived appended ledger while leaving both source directories
   untouched.
7. Recovers complete and appended CAN into checksum-inventoried extraction
   directories.
8. Projects the recovered observations into ordinary
   `gateway.passive-can-observation` NDJSON grouped by gateway/session. These
   files are the reusable iOS/Android/UI playback inputs.
9. Produces discovery reports and evaluates the versioned 2005 4Runner
   cross-model hypothesis pack without promoting any mapping.
10. Validates the append-only event-marker ledger. When at least three markers
    bind to a recovered session, it ranks state-associated CAN fields and keeps
    evidence density, return-state behavior, and ambiguity visible.
11. Builds immutable real-capture replay corpora and verifies their source
    hashes, statistics, session identity, and semantic digest.
12. Replays both live and history wire encodings and requires exact surviving
    record order and payloads.
13. Runs the 15-scenario transport matrix, including MTU 23, MTU churn, bursts,
    jitter, duplicate frames/notifications, loss, corruption, reorder,
    reconnect, stale epochs, supervision timeout, bounded queue overrun, and
    mixed interference.
14. Inventories every generated artifact by relative path, byte count, and
    SHA-256, validates the root manifest contract, then atomically renames the
    completed staging directory into place.

## Output structure

```text
field-return-analysis-*/
├── manifest.json
├── SUMMARY.md
├── full/
│   ├── recovered/
│   ├── replay-input/
│   ├── replay-corpus/
│   ├── discovery.json
│   ├── hypotheses.json
│   ├── marker-correlation.json       # when applicable
│   ├── replay.json
│   └── link-reliability.json
└── appended/
    ├── portable/logical-frames.ndjson
    ├── recovered/
    ├── replay-input/
    ├── replay-corpus/
    ├── discovery.json
    ├── hypotheses.json
    ├── replay.json
    └── link-reliability.json
```

The appended scope is absent when no baseline was supplied or the current
ledger is byte-for-byte unchanged. If valid appended records contain no CAN
frames, they are preserved and explicitly labeled `NO_CAN_OBSERVATIONS`; replay
or mapping is not fabricated.

## Current field-return result

The August 24 copy is an exact 9,922-record continuation of the August 22
baseline. It adds 4,296 portable records and recovers 3,308 new CAN observations
from two sessions. The full copy recovers 10,709 observations across 14 sessions
and 17 identifiers from portable envelopes. The older direct `PassiveCAN`
archive has 5,176 valid records: 4,840 match the portable recovery and 336 are
additional identities. Those 336 are merged once into the full offline replay,
so the complete all-phone corpus contains 11,045 observations without double
counting overlap.

Both complete and appended corpora pass live replay, history replay, and all 15
reliability scenarios at 20 soak cycles. The synchronized selector run produces
11 discovery candidates. In particular, `0x2D0.byte2` repeats the observed
signature `P=8, R=2, N=8, D=16, P=8`. That makes it a useful selector-state
candidate while also proving that this field cannot distinguish Park from
Neutral in the present evidence. The result must not authorize parked state.

The highest raw association currently has sparse one-to-two-observation windows.
The correlation score is therefore multiplied by evidence density, and the
summary reports both values. A visually convincing signature cannot silently
become high-confidence evidence when capture retention is sparse.

No new identifier appears in the appended evidence. That is still useful: it
adds new values, state transitions, timing, and repeated observations for
existing identifiers. “No new identifier” does not mean “no new signal
evidence.”

## What no longer requires a vehicle trip

The replay inputs and immutable corpora can now be used repeatedly for:

- decoder changes and regression tests;
- iPhone and Android graph/playback development;
- duplicate, stale-session, reconnect, corruption, loss, and timeout handling;
- queue/backpressure and retained-history load tests;
- automatic candidate ranking and hypothesis comparison;
- UI state transitions from historical evidence;
- export/import compatibility and deterministic AI-analysis handoff.

The car and ESP32 are only needed to acquire facts that do not exist in the
current evidence: denser retained history, new physical states, repeated event
markers, and independent OBD/Techstream/manual reference measurements. That next
visit should be one guided capture/offload procedure, not an interactive coding
session.

## Authority boundary

Every output is labeled `OFFLINE FIELD EVIDENCE • NOT LIVE` and retains
`vehicle_claims_authorized=false`. Correlation and plausible transformed values
are discovery candidates. They are not accepted Toyota definitions, current
vehicle state, a health conclusion, deterministic Park/motion authority, or a
CAN-control permission.

This is intentional. The workflow removes the software round trips while
preserving the evidence and validation work required before a candidate can be
promoted into the versioned Vehicle Signal Pack.
