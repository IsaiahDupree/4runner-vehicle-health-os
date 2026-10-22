# Real CAN replay and offline load testing — 2026-08-18

- Status: implemented and exercised on Python, Swift, and Kotlin production decoders.
- Corpus contract: `can.replay.corpus@1.0.0`.
- Corpus ID: `2005-4runner-real-can-2026-08-18`.
- Source classification: `REAL_CAPTURE_REPLAY`.
- Required UI label: **HISTORICAL REPLAY • NOT LIVE**.
- Semantic digest: `94b5e7a86d062f81509c6a442aa9229800dc691860464abfb1dd22053b10aab5`.
- Vehicle claims authorized: **false**.

## Outcome

The vehicle is no longer required for most transport, storage, replay, analysis, and head-unit UI
development. Eight real listen-only sessions recovered from the iPhone are checked into
`test-replay/real-can-2026-08-18/` with their exact bytes, per-file SHA-256 values, session IDs,
source sequences, gateway monotonic timestamps, arbitration identifiers, DLCs, payloads, bitrate,
and listen-only proof.

The same observations now run through the actual VHOS envelope and stream decoders used by the
iPhone and Android app. Tests can fragment notifications, remove a fragment, corrupt a complete
payload, insert unrelated bytes, or reset the stream in the middle of a frame. A valid later frame
must recover without silently relabeling damaged transport as a vehicle fault.

This is a replay laboratory, not a live-vehicle simulator. It proves software behavior against
recorded bytes and makes their source visible. It never claims that the vehicle is currently in the
recorded state.

## Preserved evidence

| Metric | Preserved result |
| --- | ---: |
| Sessions | 8 |
| Retained observations | 5,176 |
| Source NDJSON bytes | 2,081,023 |
| Gateway identities | 1 |
| Identifier population | 17 |
| Bitrate | 500 kbit/s |
| Standard 11-bit records | 5,176/5,176 |
| Listen-only records | 5,176/5,176 |
| RTR records | 0 |
| Sampled source duration | 140.831 s |
| Sequence-estimated observed frames | 75,899 |
| Sequence-estimated bus rate | 538.880 frames/s |
| Retained record rate | 36.753 records/s |
| Retained sequence coverage | 6.8196% |

Coverage is the deliberate flight-recorder sampling density. It is not a dropped-frame counter.
Receive loss may be attributed only from the gateway's TWAI, queue, persistence, and bus-error
counters for the same session.

The corpus manifest validates the SHA-256 and record count of every source file and computes a
canonical semantic digest across every normalized record. Byte edits, record deletion, reordering,
or relabeling cause validation to fail.

## Replay architecture

```text
checked-in real NDJSON sessions
  -> manifest/hash/shape/listen-only validation
  -> original 36-byte CAN observation payload
  -> original CRC32C-protected VHOS logical envelope
  -> deterministic notification fragmentation/fault injection
  -> production self-resynchronizing stream decoder
  -> production CAN observation decoder
  -> exact identity/order/payload comparison
  -> replay diagnostics and Android historical-replay UI
```

Both deployed record paths are covered:

- `live` reconstructs message type 2, the sampled live-CAN observation;
- `history` reconstructs message type 13, the persistent capture-history chunk.

The decoder reports discarded bytes, rejected candidates, recovery events, and buffered bytes.
Those counters are transport-quality evidence and must never be merged into vehicle health.

## Fault and load matrix

| Test | Required result |
| --- | --- |
| Clean hostile fragmentation | Every record decodes exactly once and in source order |
| Notification fragment removed | The affected frame is reported missing; later valid frames recover |
| Payload corrupted after framing | CRC rejects the affected frame; later valid frames recover |
| Unframed noise inserted | Noise is counted as discarded; valid frames recover |
| Disconnect in the middle of a frame | Partial state is discarded; the new link starts cleanly |
| Sustained repeated corpus | No hang, trap, duplicate, reordering, or unexplained record loss |
| Replay cancellation | Work stops at a bounded record boundary without persisting false evidence |
| Historical replay UI | Always says `HISTORICAL REPLAY • NOT LIVE` and `REAL_CAPTURE_REPLAY` |

The automated Python suite replays the full 5,176-record corpus in both wire modes and all fault
profiles. Swift and Kotlin each pin an identical 256-record real fixture with SHA-256
`af2305021c2d48d89c55d1739da407d78ee28baa39cce63125d0656672f58aed`, replay it twenty
times under hostile fragmentation, and verify exact decoded identity and bytes. Android additionally
runs the persisted-observation replay twenty times, exercises all fault profiles, and proves
cancellation.

Performance numbers are written into replay reports for engineering comparison, but CI does not
hard-code a workstation throughput threshold. Correctness, liveness, bounded recovery, and exact
record accounting are the release gates; hardware-specific latency budgets belong in a separately
versioned target profile.

## Commands

Validate and replay the checked-in corpus:

```bash
.venv/bin/vhos validate-can-replay-corpus test-replay/real-can-2026-08-18
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode live --repeat 20 --fault clean --output build/replay-live.json
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode history --fault drop-fragment --fault-interval 257 \
  --output build/replay-drop-fragment.json
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode live --fault corrupt-payload --fault-interval 101 \
  --output build/replay-corrupt-payload.json
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode history --fault disconnect-mid-frame --fault-interval 113 \
  --output build/replay-disconnect.json
```

Run the platform suites:

```bash
.venv/bin/python -m pytest
swift test --package-path ios/Core

cd ../4runner-vhos-android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
./gradlew test lint assembleDebug
```

To add a future checked-in capture, export its durable NDJSON, keep the original file immutable,
then build a new corpus ID rather than changing this one:

```bash
.venv/bin/vhos build-can-replay-corpus path/to/new/session.ndjson \
  --output test-replay/real-can-YYYY-MM-DD \
  --corpus-id 2005-4runner-real-can-YYYY-MM-DD
.venv/bin/vhos validate-can-replay-corpus test-replay/real-can-YYYY-MM-DD
```

## What the current bytes support

The refreshed report is
[`can-discovery-2026-08-18-5176.report.json`](../evidence/can-discovery-2026-08-18-5176.report.json),
SHA-256 `520db9ba0c87c987e83f4019b6a4fe63d8f9ffaabfe2636a8aba049de3863e9d`.
It supports these acquisition and raw-statistical statements:

- all 5,176 observations are standard 11-bit, 500 kbit/s, listen-only records;
- 17 arbitration identifiers are present in the retained evidence;
- eight identifier families have a 100% match under the candidate Toyota additive-checksum rule:
  `0x022`, `0x023`, `0x025`, `0x223`, `0x2C1`, `0x2C4`, `0x2D0`, and `0x420`;
- `0x025` bytes 4, 5, and 6 are identical in 667/667 retained records, with raw values 115–255;
- nearest-time raw `BE16[0]` fields from `0x2C4` and `0x2D0` correlate at `0.992130` across
  625 pairs, with median right/left ratio `1.979058`; and
- raw `0x022[0:16]` and `0x223[0:16]` correlate at `-0.999643` across 142 pairs.

These are valuable discovery candidates. They do not establish RPM, steering, throttle, brake,
speed, temperature, gear, or any health condition. Those labels remain blocked until a synchronized
independent reference and a versioned Vehicle Signal Pack prove field shape, byte order, scale,
offset, unit, applicability, missing/stale behavior, and golden replays.

## Android owner experience

The Android head-unit app can replay any persisted CAN observations without connecting to either
ESP32. The owner can select normal source-time replay, full-speed stress replay repeated twenty
times, or stop an active replay. The card displays:

- the required historical/not-live label and real-capture classification;
- source record and repetition progress;
- source session, source sequence, arbitration ID, raw payload, and original source time;
- decoder recovery/discard counters; and
- an interpretation lock explaining why replay bytes are not live vehicle state or accepted
  signals.

Replay is read-only. It does not append duplicate evidence, promote a discovery candidate, update a
health score, or claim current vehicle state. It is a deterministic development and regression
surface built on the same decoders as live transport.

## Remaining physical gates

Offline replay cannot reproduce RF coexistence, ESP32 power integrity, antenna placement, actual
TWAI ISR pressure, flash-write latency, iOS/Android controller behavior, or vehicle-bus electrical
conditions. Physical acceptance still owns those gates. The practical development order is now:

1. fail fast on the full offline replay/load suite;
2. run desktop BLE fault injection when hardware is available;
3. take only release candidates that pass both to the vehicle; and
4. use the vehicle trip for synchronized reference labels and electrical/load validation, not basic
   parser debugging.
