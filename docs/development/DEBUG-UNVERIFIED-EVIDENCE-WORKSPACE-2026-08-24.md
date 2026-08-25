# Debug Unverified Evidence Workspace — 2026-08-24

Status: Debug-only authority contract and retained-signal projection implemented; device acceptance remains separate.

## Purpose

Development must not require a fresh `PARKED` result, gateway contract, recorder status, or
completed retained-record import before engineers can inspect data already on the iPhone, graph
it, add labels, or rank candidates.

The Debug build exposes **Disable evidence entry gates** and issues:

```text
DEBUG_UNVERIFIED
```

This is not a global safety override and does not claim that the vehicle is parked. It is a
separate app-local evidence authority. Every artifact created under it permanently retains
`DEBUG_UNVERIFIED` provenance.

It supersedes the narrow Debug Evidence Lab for general import, offline examination, analysis,
labeling, and test entry. Historical `DEVELOPMENT_EVIDENCE_LAB` records retain their original
authority and stricter canonical-selector semantics.

## Meaning of “disable all gates”

The control disables app-entry preconditions for evidence work. It does not disable parsing,
append-only storage, source lineage, or vehicle-side safety boundaries.

It bypasses app-local entry gates for import, replay, analysis, labeling, and test entry only.

The Debug policy can issue its authority without manufacturing:

- a connected BLE peripheral or negotiated handshake;
- gateway health, capability, or recorder state;
- a fresh timestamp or matching recorder session;
- storage headroom or zero recorder errors;
- deterministic `PARKED` authority; or
- completed pre-import vehicle verification.

Failed status remains visible and is never rewritten as PASS. The active Debug UI remains red and
explicitly labeled `DEBUG_UNVERIFIED`.

## Permitted app-local actions

- Import passive evidence.
- Replay passive evidence.
- Append a label.
- Append an event marker.
- Analyze an experimental candidate.

## Vehicle-side boundary

- Gateway commands remain denied.
- Gateway capture control remains denied by this authority.
- OTA and rollback decisions keep their ordinary safety policy.
- ECU writes remain denied.
- ECU services cannot be mutated.
- CAN writes remain denied.
- Vehicle and actuator control remain denied.
- ECU interrogation remains denied by this Debug authority.
- `PARKED` authority cannot be asserted.
- Signal promotion remains permanently denied.

The normal constrained Evidence-transfer feature is separate. It receives no permission from
`DEBUG_UNVERIFIED` and never begins because a test was completed.

## Integrity that remains active

- Imported bytes must still satisfy a supported canonical contract or be rejected or quarantined.
- Existing raw observations remain immutable.
- Labels and markers append; they do not rewrite observations.
- Projections retain gateway, recorder session, source sequence, and gateway monotonic time.
- Projections also retain evidence kind, listen-only state, pack hash, sources, and transform ID.
- Historical playback is labeled **HISTORICAL REPLAY • NOT LIVE**.
- Unknown units remain `raw count`.
- Cross-model units remain **UNVERIFIED CROSS-MODEL TRANSFORM**.
- Conflicting definitions remain raw-only.
- Debug artifacts cannot supply owner health, recommendations, or a Vehicle Signal Pack.

## Build boundary

- Only Debug can issue or continue `DEBUG_UNVERIFIED`.
- The mode selection persists for development convenience.
- Release cannot enable, issue, or continue it.
- Release can decode, preserve, export, and display prior records.
- Continuation requires an exact authority match.
- Later healthy state cannot upgrade the sealed provenance.
- Gateway control, Park claims, and signal promotion remain false capabilities.

## Existing iPhone evidence

The latest copied return passed this one-shot pipeline:

```bash
.venv/bin/vhos analyze-field-return \
  'build/device-data/2026-08-24-field-return-2319/Application Support' \
  --baseline 'build/device-data/2026-08-24-field-return-185114' \
  --output 'build/field-return-analysis/2026-08-24-2319' \
  --soak-cycles 20
```

| Metric | Result |
| --- | ---: |
| Replay observations | 11,862 |
| Recorder sessions | 20 |
| CAN identifiers | 17 |
| New observations versus the prior baseline | 817 |
| Sessions in the delta | 6 |
| Reliability matrix | 15 scenarios times 20 cycles, PASS |
| Ranked marker candidates | 19 |
| Accepted signal definitions created automatically | 0 |

Zero automatic definitions is intentional. The evidence supports graphs, playback, candidate
comparison, robustness tests, and next-test design. It does not support automatic Toyota signal
promotion.

## Signal Explorer display

Each retained-candidate card shows:

- candidate label and semantic;
- latest retained numeric value;
- a unit only when a pinned cross-model transform exists;
- otherwise the exact numeric raw count;
- CAN identifier and retained record count;
- exact gateway, recorder session, and sequence.

The detail view also identifies report authority and the analyzed evidence digest.

## Current candidate display rules

| CAN field | Candidate meaning | Display now |
| --- | --- | --- |
| `0x2C4` bytes 0–1 | Engine speed | Candidate rpm using `raw × 0.78125` |
| `0x2C4` byte 3 | Intake-air temperature | Raw count only |
| `0x2D0` bytes 0–1 | Transmission turbine speed | Candidate rpm using `raw × 0.390625` |
| `0x2D0` byte 2, low 7 bits | Selector code | Raw count only |
| `0x2C1` byte 6 | Accelerator pedal | Candidate percent using `raw × 0.5` |
| `0x025` signed low 12 bits of bytes 0–1 | Steering angle | Raw signed count only |
| `0x224` low 9 bits of bytes 4–5 | Brake pressure | Raw count only |

These names and transforms come from pinned related-Toyota sources. They are not validated 2005
4Runner mappings. Units are exposed only where a source-backed transform exists; the UI states that
the scale remains cross-model and unverified.

Target-vehicle validation still requires:

- `0x2C4` against SAE J1979 PID `01 0C` or Techstream RPM;
- `0x2D0` against Techstream turbine speed plus labeled gear and speed states;
- `0x2C1` against SAE J1979 PID `01 49` or Techstream pedal position;
- `0x025` against center, left, and right steering references; and
- `0x224` against labeled brake force with an independent reference.

## Stored-data procedure

This procedure deliberately works without a live ESP32:

1. Use a Debug build.
2. In Discovery, enable **Disable evidence entry gates**.
3. Confirm the visible `DEBUG_UNVERIFIED` workspace label.
4. In Evidence, use **Import passive CAN NDJSON — Debug** for a canonical
   `PassiveCANObservation` archive, or select CAN records already stored on the iPhone.
5. Reject the archive without mutation if its exact bytes are not canonical VHOS NDJSON. This
   prevents unknown fields or whitespace normalization from being silently discarded.
6. Run historical playback in Replay Lab.
7. Signal Explorer presents synchronized graphs and candidate cards.
8. Append labels or event markers at known physical events. An offline Debug test run binds to
   one retained gateway/session lineage, so Begin, every marker, and End use the same immutable
   stored session without requiring a live observation. The exact start observation is pinned by
   gateway, session, and source sequence and is reacquired from the durable store after relaunch,
   even after the 512-record display cache has moved on.
9. Run candidate analysis and create a review bundle.
10. Restore ordinary gate enforcement when offline work ends.

## Session boundary

The test record remains local.
Test closure never pauses the recorder.
Test closure never begins history offload.
Test closure never sends a gateway command.

## Transfer and reconnect boundary

App launch clears persisted `downloading` intent and preserves at most a resume-only confirmation.
History incompleteness is persisted separately from recorder-resume state, so a completed download
cannot reappear as **Resume saved log transfer** after relaunch. Neither state initiates scanning,
connection, or history offload.

Link loss during manual offload clears active bulk tasks and the downloading phase. A completed
copy awaiting recorder resume retains only that resume-only state. The checkpoint remains inert
until a later owner action.
Normal BLE reconnection is independent of the saved checkpoint.
No automatic bulk-read retry loop survives launch or link loss.

## Offline capabilities

- Direct canonical passive-CAN NDJSON import and quarantine reporting without a signed bundle
  manifest, live handshake, or `PARKED` result.
- Historical playback and synchronized signal graphs.
- Candidate comparison across stored sessions.
- Append-only labels and event markers.
- Decoder regression and load testing against copied evidence.
- Evidence export for reproducible human or AI-assisted review.

Offline evidence cannot establish a current connection, current vehicle state, `PARKED`, or a
production-valid signal mapping.

## Acceptance checks

- Debug authority works with the ESP32 powered off.
- Stored canonical evidence imports and replays without a live handshake.
- Import → durable lookup → Debug label succeeds for any bounded canonical provenance string.
- Noncanonical bytes fail before any capture record is appended.
- Offline Debug test runs can Begin, append markers, and End against one retained session.
- An active run remains closable after cache eviction and app relaunch.
- UI and exported records retain `DEBUG_UNVERIFIED` provenance.
- Unknown or conflicting units remain raw counts.
