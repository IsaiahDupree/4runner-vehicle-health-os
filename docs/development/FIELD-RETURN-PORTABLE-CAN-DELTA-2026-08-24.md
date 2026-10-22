# August 24 iPhone portable-CAN delta analysis

Date: 2026-08-24
Gateway: `esp32-9454c5b08d14` / `VHOS-4R-OBD-B08D14`
Status: new portable evidence recovered and reproducibly analyzed; no new signal is promoted

## Executive result

The returned iPhone does contain new analyzable vehicle evidence. The August 24 copy adds 4,296
append-only portable logical frames to the exact August 22 ledger prefix. Those new envelopes
recover 3,308 unique, CRC-valid, standard 11-bit, 500 kbit/s, listen-only CAN observations from two
gateway recorder sessions.

This delta is already suitable for deterministic offline replay, UI playback, regression testing,
raw-field range analysis, checksum verification, and cross-model hypothesis ranking. It is **not**
sufficient to accept a new physical signal mapping because:

- the phone received sparse BLE-live samples, not the corresponding gateway-flash history;
- no new synchronized event markers, physical measurements, J1979 responses, or Techstream
  references were saved;
- the retained cross-ID samples are phased at least about 500 ms apart, outside the
  conservative 250 ms correlation window; and
- gateway health proves material TWAI receive overruns, storage-write failures, and storage
  exhaustion during both returned intervals.

The blocker is therefore not access to the phone data or an inability to run analysis away from
the vehicle. The blockers are incomplete automatic offload and missing synchronized ground truth.
The current bytes tell us exactly what the next one-trip workflow must guarantee.

## Preserved sources and reproducibility

The read-only app-container copy is preserved at:

`build/device-data/2026-08-24-field-return-1835`

It contains 20 files, 12,245,879 file bytes (12,000 KiB on disk). All NDJSON parsed successfully.
No source evidence was rewritten during this analysis.

| Artifact | Records | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| August 22 portable ledger | 5,626 | 5,826,995 | `cacf021b386de8c96fad8e09d9fafa3a50cfdf5f75d392e14719994fb75158ff` |
| August 24 portable ledger | 9,922 | 9,368,169 | `230ce5e29a52236b3e4efbaa5ac89c6811c15b917be52c00bf951b516c3d9523` |
| Exact appended ledger suffix | 4,296 | 3,541,174 | `497695b5fa00ace03ef19013fd6db3c89641de782b988ce42c6ef5f80848b445` |
| Recovery manifest | - | 5,359 | `18c2839ce4d14c2dbf19071c0790386ba73e615d8c7365a72c5a603d694f868a` |
| Provenance-bound full discovery report | - | 42,248 | `669543158add68552857f443ef9e582fc4c5e9f14d13abc41a5d778065a59c87` |
| New-only discovery report | - | 27,531 | `a0592d7ea6751e5a5d86bfb90a887e8e5f7f517d641cc4c88aa1434e472e4f64` |
| New-only hypothesis evaluation | - | 14,565 | `1b965d20b8e570f289cfbc3c3354c3451fcae5f57672027e0816ae9ccedc2003` |

The first 5,626 lines of the August 24 ledger hash exactly to the complete August 22 ledger. There
are 4,296 added lines and zero removed or modified prefix lines.

The reproducible derived outputs are:

- `build/can-portable-recovery-2026-08-24-field-return-1835`
- `build/can-portable-recovery-2026-08-24-field-return-1835-discovery.json`
- `build/can-portable-delta-2026-08-24/discovery.json`
- `build/can-portable-delta-2026-08-24/hypothesis-evaluation.json`

All reports remain labeled discovery/recovered evidence. They authorize no vehicle-health claim.

## What is genuinely new

The 4,296 appended logical frames contain:

| VHOS message | Appended frames |
| --- | ---: |
| Live raw CAN | 3,308 |
| Gateway health | 980 |
| Gateway handshake | 4 |
| Capture-log index | 4 |
| Capture-history chunk | **0** |

Physical-identity recovery found no duplicate among the 3,308 appended CAN observations. The
new-only projected observation files are:

| Session evidence | Records | SHA-256 |
| --- | ---: | --- |
| Session `317333329` | 914 | `c9db42f931a89254f3cf11d63fd08566d77383721fed963613e9dc4e26089f46` |
| New tail of session `3025357416` | 2,394 | `e4f570c6dc6effa6d3144644da0616f168ef55d39d11d7fafc2b4aa7ac3d5646` |

The old 926-record session-`3025357416` recovered file is an exact prefix of the new 3,320-record
file. The new copy also adds the previously unseen recorder session `317333329`.

| Session | Ingested UTC interval | Records | Sequence span | Duration | Estimated observed rate | Retained coverage | IDs |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `3025357416` new tail | 2026-08-22 `18:27:43...18:47:46Z` | 2,394 | `423,953...1,040,902` | 1,202.703 s | 512.969 frames/s | 0.3880% | 16 |
| `317333329` | 2026-08-23 `19:29:03...19:50:44Z` | 914 | `1,257,519...1,493,953` | 1,301.039 s | 181.727 frames/s | 0.3866% | 16 |

Across the delta there are 3,308 records, 16 standard identifiers, no extended frames, no RTR
frames, one gateway, two sessions, and listen-only proof on every record. `0x420` is the only member
of the previously observed 17-ID population absent from the new delta; there is no newly observed
identifier.

The normal `VHOS/PassiveCAN` directory is still byte-for-byte the same eight-session, 5,176-record
store analyzed on August 22. The capture-binding, marker, and test-run ledgers are also unchanged:

| Ledger | Records | SHA-256 |
| --- | ---: | --- |
| Capture bindings | 1 | `4c0d483d34abfe2fd153dfe506165e1be5e892561b78d8a871b9f13e1a1ffe35` |
| Event markers | 6 | `d360e4682ee4c2ead7dfdee261bb9e379c88990391de1aad3bdc5fa0dd14c802` |
| Test-run drafts/transitions | 4 | `24ed02616cfc6c369a952df089c8f60398b7ee693b064c74bcfab057cdff0185` |

Consequently, the appended sessions have no newly returned ground-truth labels.

## Evidence-quality result

The 980 new health frames all report `vehicle_motion: UNKNOWN`. They do not establish Park.

| Health interval | First received / overrun / write failure / free | Last received / overrun / write failure / free |
| --- | --- | --- |
| Session `3025357416` | 423,765 / 9,709 / 615 / 3 B | 1,041,075 / 24,205 / 2,018 / 3 B |
| Session `317333329` | 1,257,298 / 29,435 / 2,763 / 85,089 B | 1,494,030 / 35,512 / 3,319 / 21 B |

In both intervals the observer-queue dropped-frame count remained zero and bus-off remained zero.
The loss is nevertheless material: the TWAI overrun counter increased, while persistent-write
failures increased and storage fell to near zero. Bus-error count was 45 throughout the new
session-`3025357416` tail and increased from 226 to 256 during session `317333329`.

The capture indices prove that gateway-flash history existed but was not offloaded. At the start of
session `317333329`, the gateway advertised a 10,656-record previous session (`3025357416`) and a
128-record current session. Four capture indices were saved, but zero type-13 capture-history
chunks followed. This is the concrete automatic-offload gap.

## Raw discovery findings

### Payload integrity

Seven additive-checksum families have 1,567/1,567 matches in the new delta:

| ID | Valid / checked |
| --- | ---: |
| `0x022` | 296 / 296 |
| `0x023` | 83 / 83 |
| `0x025` | 147 / 147 |
| `0x223` | 79 / 79 |
| `0x2C1` | 272 / 272 |
| `0x2C4` | 367 / 367 |
| `0x2D0` | 323 / 323 |

This is strong raw-payload-integrity evidence. It does not establish the meaning of any byte.

### Repeated-channel structure

`0x025` provides the strongest new structural result:

- session `3025357416`: bytes 4, 5, and 6 agree exactly in all 107 retained frames, range
  `120...132`;
- session `317333329`: bytes 4 and 5 agree exactly in all 40 retained frames, range `51...132`;
- across both sessions: bytes 4 and 5 agree in all 147 frames with maximum disagreement zero.

This strengthens a redundant/repeated-channel candidate. It does not identify steering, units, or
scale.

### Newly exercised raw ranges

No ID is new, but the delta adds meaningful state coverage:

| ID | Added records | Newly expanded retained ranges |
| --- | ---: | --- |
| `0x022` | 296 | byte 1 minimum `3 -> 0`; byte 3 minimum `2 -> 1`; byte 7 minimum `24 -> 10` |
| `0x023` | 83 | byte 3 minimum `8 -> 0`; byte 6 minimum `51 -> 5` |
| `0x025` | 147 | byte 1 minimum `9 -> 5`; byte 7 maximum `224 -> 237` |
| `0x223` | 79 | byte 0 maximum `7 -> 69`; byte 7 maximum `85 -> 146` |
| `0x224` | 399 | unique payloads `49 -> 125`; existing bounds unchanged |
| `0x2C1` | 272 | byte 1 maximum `254 -> 255`; byte 6 maximum `95 -> 175` |
| `0x2C4` | 367 | unique payloads `703 -> 1,048`; existing byte bounds unchanged |
| `0x2D0` | 323 | byte 0 maximum `44 -> 45`; byte 4 maximum `34 -> 35`; byte 6 maximum `2 -> 3` |
| `0x3D0` | 23 | byte 0 maximum `29 -> 81`; unique payloads `4 -> 17` |

These expanded ranges are valuable for future labeled experiments and replay boundary tests.

## Candidate mappings: what changed and what did not

The versioned hypothesis evaluator still returns:

`accepted_signal_definitions: 0`

All candidate values below are engineering-only cross-model hypotheses, not accepted 2005
4Runner signals:

| Raw candidate | New-only evidence | Defensible change |
| --- | --- | --- |
| `0x2C4[0:16]` | 367 records, raw `776...5790` | Still a high-priority engine-speed-shaped candidate; broader target range, no accepted scale |
| `0x2D0[0:16]` | 323 records, raw `0...11647` | Still a rotational-state candidate; turbine/input-speed meaning remains unverified |
| `0x2D0 byte[2] & 0x7F` | codes `2...16`; `2`, `8`, and `16` occur in session `317333329` | Selector-shaped candidate persists, but there are no new labels and Park/Neutral ambiguity remains |
| `0x2C1 byte[6]` | 272 records, raw `0...175` | Pedal-related candidate is exercised over a much broader range; causation and scale remain unverified |
| `0x025` signed-field hypothesis | 147 records, candidate raw `-170...248` | Steering-family candidate is more strongly exercised; conflicting published layouts/scales still block degrees |
| `0x224 bytes[4:6] & 0x1FF` | dynamic in both sessions, raw `0...286` | Independent dynamic evidence strengthens the brake-pressure-shaped test target; no brake marker/reference means no mapping |

The checked-in hypothesis pack's static sentence saying the `0x224` candidate field is always zero
is now stale relative to returned target evidence. The evaluator correctly reports
`FIELD_PRESENT_DYNAMIC`, but the narrative limitation must be revised before this report becomes a
checked-in golden evaluation. The dynamic field is still not a pressure signal until a labeled
brake sweep and independent reference corroborate it.

The earlier full-evidence raw-word relationships remain unchanged:

- `0x2C4[0:16]` versus `0x2D0[0:16]`: 584 historical pairs, correlation `0.992298`, median raw
  ratio `1.978989`;
- `0x022[0:16]` versus `0x223[0:16]`: 135 historical pairs, correlation `-0.999651`.

The new delta adds **zero** conservative pairs to either relationship. The smallest new retained
time separation between `0x2C4` and `0x2D0` is about 500,286 us, beyond the 250,000 us pairing
window. Therefore these correlations do not gain independent support from the August 24 delta.
Relaxing the pairing window merely to manufacture a result would overstate sparse evidence.

No `0x7E8...0x7EF` diagnostic responses or synchronized standard J1979 samples are present in the
new delta. Standard OBD values cannot be populated from these bytes alone.

## What must become automatic before the next vehicle trip

A single field run can support all later coding, replay, graphing, candidate ranking, and UI work if
the phone enforces this closeout sequence before it declares the run complete:

1. **Preflight:** require a fresh recorder session, adequate storage, zero new write failures,
   bounded TWAI overrun delta, listen-only proof, and an advancing health stream.
2. **Bind:** create the capture/test-run identity before the first physical action.
3. **Label:** save synchronized event markers and any independent OBD/Techstream/manual reference.
4. **Close:** end the run immutably, then pause the recorder for bulk transfer.
5. **Offload:** require a capture index followed by all expected type-13 history chunks; reconcile
   the expected record count, source identities, CRCs, and archive SHA-256.
6. **Package:** create one evidence bundle containing raw history, portable frames, gateway health,
   markers, references, firmware identity, and manifest hashes.
7. **Analyze offline:** replay the bundle through iOS and Android, render graphs, rank candidates,
   run link/load faults, and produce the next-test recommendation without returning to the car.

Until step 5 is mandatory, the app can say that it observed live traffic but cannot promise that it
brought home the data needed for high-fidelity mapping.

## Verification performed

- full August 24 portable extraction: 9,922/9,922 validated envelopes;
- full recovery: 10,709 unique observations, 14 sessions, 17 identifiers;
- new-only discovery: 3,308 records, two sessions, 16 identifiers;
- all five generated discovery/hypothesis reports validated against the contract catalog;
- `vhos contracts check`: 41 schemas valid;
- focused tooling suite: 48/48 tests passed (`test_can_discovery.py`, `test_portable_can.py`, and
  `test_signal_hypotheses.py`).

This report extends, but does not replace,
[Field-return CAN and sustained-link analysis](FIELD-RETURN-CAN-AND-LINK-ANALYSIS-2026-08-22.md).
