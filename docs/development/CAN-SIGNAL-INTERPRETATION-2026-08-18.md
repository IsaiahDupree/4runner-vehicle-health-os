# 2005 4Runner CAN signal interpretation — 2026-08-18

## Outcome

We now have a versioned, executable interpretation layer for the captured passive CAN traffic,
but it is intentionally a **hypothesis pack**, not an accepted 2005 4Runner DBC.

- Corpus: 5,176 retained observations, eight sessions, one gateway, 17 standard identifiers.
- Physical bus evidence: 11-bit CAN at 500 kbit/s; every record reports listen-only operation.
- Accepted passive Toyota signal definitions: **zero**.
- Strongest candidates: engine speed (`0x2C4`), accelerator pedal (`0x2C1`), steering field
  placement (`0x025`), and transmission turbine speed (`0x2D0`).
- Safe product behavior: show raw evidence and capture health now; show candidate interpretations
  only in Engineering with `UNVERIFIED CROSS-MODEL HYPOTHESIS`.

The distinction is deliberate. A value that looks like RPM is not yet proof that the target ECU
uses that field, scale, or semantic. The app must never turn a plausible cross-model decode into a
maintenance finding or owner-facing health conclusion.

## Versioned artifacts

| Artifact | Purpose |
|---|---|
| [`toyota-4runner-2005-passive-can-hypotheses.v1.json`](../../vehicle-signal-packs/toyota-4runner-2005-passive-can-hypotheses.v1.json) | Source-pinned field hypotheses, candidate transforms, limitations, and promotion gates |
| [`can-signal-hypothesis-pack.schema.json`](../../contracts/jsonschema/v1/can-signal-hypothesis-pack.schema.json) | Strict contract that forbids production display and automatic promotion |
| [`can-signal-hypothesis-evaluation.schema.json`](../../contracts/jsonschema/v1/can-signal-hypothesis-evaluation.schema.json) | Reproducible evaluation report contract |
| [`can-signal-hypotheses-2026-08-18-5176.report.json`](../evidence/can-signal-hypotheses-2026-08-18-5176.report.json) | Evaluation of every retained target record |
| [`signal_hypotheses.py`](../../tooling/src/vhos/signal_hypotheses.py) | Generic extraction, transformation, and same-session relationship evaluator |
| [`test_signal_hypotheses.py`](../../tests/test_signal_hypotheses.py) | Real-corpus regression gates |

Reproduce the evaluation:

```bash
.venv/bin/vhos evaluate-can-hypotheses \
  test-replay/real-can-2026-08-18/sessions \
  --output /tmp/can-signal-hypotheses.report.json
```

## What the current CAN evidence most likely means

These are discovery interpretations, ordered by present usefulness. “Candidate output” is what a
published cross-model transform produces on our target bytes; it is not an accepted measurement.

| ID and field | Current interpretation | Target evidence | Confidence boundary |
|---|---|---|---|
| `0x2C4`, bytes `0..1`, big-endian | Engine speed candidate at `raw × 0.78125 rpm` | 659 records; candidate range `0–4421.875 rpm` | High-priority cross-model candidate. CSU identifies the field as engine speed and two pinned community mappings agree on the scale; exact target proof is still missing. |
| `0x2C4`, byte `3` | Intake-air-temperature candidate at `raw °C` | 659 records; `30–50 °C` | Plausible but only one reviewed related-platform mapping supplies this byte formula. Compare with J1979 PID `0x0F` or Techstream. |
| `0x2D0`, bytes `0..1`, big-endian | Transmission turbine/input speed candidate at `raw × 0.390625 rpm` | 626 records; candidate range `0–4429.297 rpm` | The semantic comes from the related FJ mapping. CSU left `0x2D0` unknown. A drive/shift capture is required. |
| `0x2D0`, byte `2 & 0x7F` | Transmission selector-code candidate | Values `0–8`, mostly `8` | Codes are unlabeled. Do not map them to P/R/N/D until a stationary marked experiment proves each state. |
| `0x2C1`, byte `6` | Accelerator-pedal candidate at `raw × 0.5%` | 631 records; candidate range `0–47.5%`, mostly zero | CSU independently reports pedal behavior at the same byte position; the scale remains cross-model. |
| `0x025`, signed 12-bit field in bytes `0..1` | Steering-wheel-angle candidate | 667 records; raw signed counts `-12..39`; bytes `4`, `5`, and `6` also agree in every retained frame | Field placement is strongly recurrent, but reviewed sources conflict on scale and direction (`×1.5`, `×1.0`, and `×-0.087890625` degrees). The repeated bytes are a consistency clue, not yet named channels. **No degree value is accepted.** |
| `0x224`, low nine bits of bytes `4..5` | Brake-pressure candidate | 143 records; candidate field is always zero | The current sessions did not exercise the candidate. A marked brake sequence is required. |
| `0x223` | Brake stop-light/switch candidate | 142 records; two payload states | ID-level clue only. The changing target bit is not yet aligned safely with the related-platform bit numbering. |
| `0x022` | Steering-related unknown | 640 records; words cluster near a biased center in much of the capture | CSU reports steering-like behavior, but exact physical quantity, field, sign, scale, and unit remain unknown. |
| `0x023` | Unknown | 682 records, DLC 7 | Cross-model recurrence only. Preserve DLC 7 for checksum and field analysis. |
| `0x420` | Unknown | 134 records; two payloads | No mapping was found in the reviewed sources. |

The other retained identifiers are static or nearly static in these sessions and have no defensible
semantic assignment yet. Their presence remains useful raw evidence, but arbitration-ID proximity
or payload appearance cannot identify a subsystem.

## The strongest new relationship

The first word of `0x2C4` and the first word of `0x2D0` already had a raw ratio near two. The
related-platform mappings use reciprocal-looking physical scalings:

```text
0x2C4 candidate engine RPM  = raw_2C4 × 0.78125
0x2D0 candidate turbine RPM = raw_2D0 × 0.390625
```

Applied to the target corpus, 625 same-session nearest-time pairs produce:

- Pearson correlation: `0.992130`
- median turbine/engine candidate ratio: `0.989529`
- mean absolute difference: `23.228750 rpm`
- root-mean-square difference: `65.899752 rpm`
- maximum pairing delta: `109,508 µs`

This strongly supports the byte boundaries and makes the FJ formulas worth testing. It does not
prove that `0x2D0` is turbine speed, because two rotational values can track closely at idle or
under converter lockup. A marked park/launch/shift/coast/stop capture is the discriminating test.

## Source assessment

No authoritative, redistributable exact-vehicle DBC for a 2005 Toyota 4Runner was found in this
review. We therefore use a source hierarchy rather than copying a community label into production:

1. **Toyota TIS/Techstream and exact-vehicle evidence** for authoritative applicability and an
   independent reference.
2. **SAE J1979 responses** for standardized emissions-related signals after the ECU's supported-PID
   bitmap proves availability.
3. **Independent university research** for cross-model causal clues.
4. **Version-pinned open/community mappings** for field and scaling hypotheses only.

Reviewed sources:

- [Colorado State University Toyota CAN research](https://www.engr.colostate.edu/~jdaily/tucrrc/ToyotaCAN.html): independently correlated signals on a 2010 Camry using physical reference instruments; it identifies the relevant ID families but is not the target vehicle.
- [Version-pinned 2012 FJ Cruiser RealDash mapping](https://github.com/janimm/RealDash-extras/blob/cedfdf491b53d331625930909f949b657441f4a3/RealDash-CAN/XML-files/toyota/toyota_fj_can.xml): supplies the related-platform `0x2C1`, `0x2C4`, and `0x2D0` formulas used as hypotheses.
- [Version-pinned comma.ai opendbc Toyota sources](https://github.com/commaai/opendbc/tree/b4ef5e1cf406ff143fa67bdbfb154739d43279c9/opendbc/dbc): demonstrates recurring signed 12-bit `0x025` field placement but also exposes cross-model steering-scale differences.
- [Version-pinned community Toyota/Lexus DBC](https://github.com/billyjack2/CAN-DBC-Collection/blob/6e2f88fd6cd9c1f47d0db7bd022711b106f27027/TOYOTA/LEXUS/can1v3.dbc): corroborates several IDs and the `0x2C4` scale but has no exact-target applicability proof.
- [SAE J1979 overview](https://saemobilus.sae.org/standards/j1979_201009-e-e-diagnostic-test-modes) and [Toyota Technical Information System](https://www.techinfo.toyota.com/techInfoPortal/appmanager/t3/ti?_nfpb=true&_pageLabel=ti_whats_tis): authority paths for the standardized read layer and exact Toyota validation.

## What can be displayed today

| Surface | Allowed now | Required wording |
|---|---|---|
| Status / Evidence | Raw identifier, DLC, bytes, 500 kbit/s, listen-only state, frame count, sampling coverage, sequence gaps, receive errors, checksum-candidate result | Direct/raw evidence |
| Engineering research | Candidate semantic, exact field, candidate transform, range, source links, correlation, limitations, required experiment | `UNVERIFIED CROSS-MODEL HYPOTHESIS` |
| Standard OBD | J1979 value only after a complete response and the same ECU/capture's supported-PID chain proves support | Standard measured value with ECU/source provenance |
| Owner health / maintenance / findings | No passive candidate values yet | Unknown/unverified until promoted |

Candidate values must never create a finding, recommendation, service baseline, digital-twin health
state, or AI claim. AI may rank experiments and explain evidence; it may not promote a decode.

## Minimum next vehicle session

One synchronized session can resolve most of the high-value uncertainty:

1. Resolve VIN, engine, drivetrain, and emissions configuration.
2. Keep passive capture running and record gateway monotonic timestamps.
3. Enumerate J1979 Mode 01 supported PIDs for every responding ECU.
4. Record J1979 `0x0C` engine speed and `0x0F` intake-air temperature if supported.
5. Record Techstream engine speed, turbine/input speed, steering angle, accelerator position,
   brake pressure, stop-light switch, vehicle speed, selected gear, and converter-lock state.
6. Insert explicit markers for engine off, stable idle, three pedal levels, steering
   left/center/right, brake released/light/medium/firm, P/R/N/D, launch, shifts, coast, and stop.
7. Run `vhos correlate-can-reference`; review scale, offset, RMSE, stale behavior, and repeatability.
8. Promote only reviewed candidates into separate `signal.definition@1.0.0` records and pin them in
   replay tests. Rejected hypotheses remain in the research pack with their rejection evidence.

This sequence gives the Android head unit useful raw/candidate visualization immediately while
preserving the product's central rule: every accepted number must resolve to raw evidence, a
versioned decoder, and a reproducible validation record.
