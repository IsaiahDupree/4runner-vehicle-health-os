# August 24 CAN mapping evidence audit

Date: 2026-08-24
Gateway: `esp32-9454c5b08d14` / `VHOS-4R-OBD-B08D14`
Decision: offline analysis may continue; no production mapping is promoted

## Bottom line

Nothing prevents us from copying, validating, replaying, graphing, stress-testing, or ranking
candidate fields from the evidence already returned on the iPhone. The current full portable
recovery contains 10,709 unique CAN observations across 14 sessions and 17 standard identifiers.
The exact August 24 suffix contributes 3,308 new observations across two sessions.

The returned evidence does **not** yet authorize a new physical signal definition. The missing
ingredient is synchronized target-vehicle ground truth and complete gateway-flash offload, not an
offline-analysis capability. The checked-in hypothesis evaluator correctly remains at zero
accepted signal definitions.

## Evidence independently rechecked

The August 24 portable ledger is an exact append-only extension of the August 22 ledger:

| Check | Result |
| --- | ---: |
| August 22 envelopes | 5,626 |
| August 24 envelopes | 9,922 |
| Exact appended suffix | 4,296 |
| Appended-suffix SHA-256 | `497695b5fa00ace03ef19013fd6db3c89641de782b988ce42c6ef5f80848b445` |
| Full recovered CAN observations | 10,709 |
| New-only recovered CAN observations | 3,308 |
| New-only sessions / identifiers | 2 / 16 |

All 1,567 applicable Toyota-additive-checksum candidates in the new suffix match:

| ID | Matches / checked |
| --- | ---: |
| `0x022` | 296 / 296 |
| `0x023` | 83 / 83 |
| `0x025` | 147 / 147 |
| `0x223` | 79 / 79 |
| `0x2C1` | 272 / 272 |
| `0x2C4` | 367 / 367 |
| `0x2D0` | 323 / 323 |

This establishes strong payload integrity. A checksum match does not identify a signal.

## Mapping evidence that is genuinely stronger

| Candidate | Strengthened target evidence | Defensible status |
| --- | --- | --- |
| `0x2C4[0:16]` engine-speed family | Across seven independently recovered dense sessions, one-to-one `0x2C4`/`0x2D0` pairs number 29 to 241 per session. Every session has positive raw-word correlation (`0.861383...0.996827`), and its median `2D0/2C4` raw ratio stays in the narrow `1.974855...1.996431` range. | High-priority engine-speed-shaped candidate. The repeated target relationship is real, but it cannot independently prove the `0.78125 rpm/count` scale because the paired `0x2D0` scale and semantic are also hypotheses. |
| `0x2D0[0:16]` rotational family | The same seven-session result supports a rotational relationship with `0x2C4`, using 584 pairs overall and at most about 110 ms pairing separation. | Rotational-state candidate is strengthened. Engine redundancy versus turbine/input speed remains unresolved. |
| `0x2D0 byte[2] & 0x7F` selector family | In the one labeled P/R/N/D/P run, the first post-marker samples were `8`, `2`, `8`, `16`, `8`, at delays of `0`, `0.500391`, `1.001345`, `0`, and `3.510800` seconds. Code `16` also dominates the unlabeled new tail: 230/232 samples in session `3025357416` and 79/91 in session `317333329`. | Target-session selector-shaped evidence. `2` is a Reverse candidate and `16` is a Drive candidate; code `8` still aliases labeled Park and Neutral, so no selector decoder and no Park authority exist. The unlabeled tail is state coverage, not independent confirmation. |
| `0x224 bytes[4:6] & 0x1FF` brake-pressure family | The field is no longer static. Its full recovered range is `0...321`; the new-only range is `0...286`. During the selector procedure, whose safety instructions required the foot brake to remain held, retained values were `284`, `295`, and `298`; two later retained values were `279`. | Contextual target support for a brake/pressure family. There is no released/light/medium/firm reference in the same timeline, so field placement, scale, units, and even the exact physical meaning remain unaccepted. |
| `0x2C1 byte[6]` accelerator family | The new suffix exercises raw `0...175`, versus the earlier maximum of `95`. It is dynamic in both returned sessions and the independent Camry/Lexus sources already point to the same byte position. | Stronger exercise of a high-priority pedal-related candidate. No synchronized pedal reference means the `0.5%/count` transform remains unverified. |
| `0x025` signed field and repeated bytes | The signed-12 candidate now spans `-170...248`. Bytes 4 and 5 agree in 147/147 new records. Byte 6 also agrees in 146/147, with one valid exception (`51, 51, 129`). | Steering-family candidate remains high priority, but width, direction, and scale still conflict across related vehicles. Only the byte-4/byte-5 repetition is invariant in this delta; a three-channel redundancy claim would be false. |

No other field gains enough independent evidence to justify a semantic label. In particular, the
very strong historical `0x022[0:16]` versus `0x223[0:16]` anticorrelation is a statistical
relationship only; it does not turn either field into steering or braking data.

## Why the selector run cannot finish the mapping

The marker interval lasts 12.548 seconds but contains only 26 retained CAN observations from eight
identifiers. It contains five `0x2D0` frames, three `0x224` frames, one `0x2C4` frame, and one
`0x2C1` frame. That is enough to rank `0x2D0 byte[2]` for another test, but not enough to search all
IDs and fields at every transition.

The safety-confirmation marker is also user-observed context, not an independent powertrain
measurement. The procedure called for engine OFF, yet the only retained `0x2C4` sample inside the
window is raw `723`, which the cross-model candidate transform would render as `564.84375 rpm`.
That discrepancy could mean the engine state differed from the procedure, the sample/state timing
was insufficient, or the transform is wrong. Without a simultaneous PID/Techstream reference it
cannot resolve any of those alternatives.

The August 24 suffix adds no new markers, J1979 responses, Techstream values, or physical
measurements. It also contains zero capture-history chunks even though capture indices advertised
gateway-flash history. The new live sample coverage is about 0.39% of source-sequence positions,
and gateway health reports increasing TWAI overruns, persistence-write failures, and nearly
exhausted storage. These conditions limit discovery fidelity but do not prevent deterministic
offline replay of what was retained.

## Highest-information next single field test

Run one **Synchronized Reference Matrix** as one vehicle visit and one immutable evidence bundle.
The head unit/gateway records continuously; the iPhone supplies markers; Techstream or accepted
J1979 values provide independent references on the same timeline.

1. Start a fresh recorder session only after confirming adequate storage, advancing health,
   listen-only mode, and no increasing persistence-write failures.
2. Record an ignition-on/engine-off baseline, then a stable idle and three separated pedal holds.
   Save engine speed, accelerator position, and intake-air temperature references.
3. Record center/left/center/right steering holds and released/light/medium/firm brake holds, each
   repeated. Save steering angle, brake pressure, and stop-light-switch references.
4. On level ground with wheels chocked, parking brake set, foot brake held, and the engine state
   explicitly recorded, perform two P/R/N/D/P cycles with at least ten seconds per state. Save the
   independent selector state.
5. If a qualified operator and passenger can conduct a safe bounded road phase, record launch,
   steady speed, a shift, coast, brake, stop, and return to Park while saving engine speed,
   NT/turbine speed, vehicle speed, selector, and lockup. Otherwise leave the `0x2D0` turbine
   semantic unresolved rather than improvising a driving test.
6. Before leaving the vehicle, pause capture, download every indexed gateway-flash chunk, reconcile
   record counts and source-sequence coverage, verify CRC/SHA-256, and confirm that the archive
   spans every marker/reference timestamp.

This one matrix targets every current high-value candidate: `0x2C4` engine speed and temperature,
`0x2C1` pedal, `0x025` steering, `0x224` pressure, `0x223` stop light, and `0x2D0` rotational and
selector fields. It should produce enough data to fit and reject scales, generate synchronized
graphs, create golden replays, and choose the next test offline. Production promotion would still
require the repository's repeatability and independent-corroboration gates.

## Verification method

The counts, hashes, checksum totals, marker joins, repeated-byte totals, and per-session
correlations above were recomputed directly from:

- `build/device-data/2026-08-24-field-return-1835/VHOSPortableFrames/v1/logical-frames.ndjson`
- `build/device-data/2026-08-24-field-return-1835/VHOSDiscoveryEvidence/v1/event-markers.ndjson`
- `build/can-portable-recovery-2026-08-24-field-return-1835/replay-input/*.ndjson`
- `build/can-portable-recovery-2026-08-24-new-only/replay-input/*.ndjson`

Pairing used the repository's monotonic, one-to-one, 250,000-microsecond maximum pairing algorithm;
no sparse record was reused. The August 24 delta contributes no pair inside that conservative
window, so it was not counted as new correlation proof.

This audit supplements
[the August 24 portable delta report](FIELD-RETURN-PORTABLE-CAN-DELTA-2026-08-24.md),
[the August 22 field-return report](FIELD-RETURN-CAN-AND-LINK-ANALYSIS-2026-08-22.md), and
[the cross-platform source lineage](TOYOTA-LEXUS-CAN-CROSS-PLATFORM-LINEAGE-2026-08-18.md).
