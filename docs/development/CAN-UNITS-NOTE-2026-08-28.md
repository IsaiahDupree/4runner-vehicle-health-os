# CAN Units

Date: 2026-08-28

## Purpose

This branch turns retained CAN evidence into a physical-unit and derived-evidence engineering view. It keeps authority visible so a hypothesis cannot look like vehicle truth.

## Authority

- `OBSERVED_STANDARD`: SAE J1979 value after same-ECU supported-PID proof.
- `UNVERIFIED_CANDIDATE_UNIT`: cited cross-model transform, always badged.
- `RAW_ONLY_CANDIDATE`: exact raw value when scale or meaning is unresolved.
- `UNVERIFIED_DERIVED`: calculation that inherits its weakest input authority.

Unverified values cannot feed owner-health conclusions. Missing values stay `Unavailable`; they are never shown as zero.

## Current evidence

The checked-in corpus has 11,045 real listen-only observations across 15 sessions and 17 identifiers.

It has no target SAE J1979 response records or complete supported-PID proof, so saved-file analysis cannot claim standard OBD values.

## Candidate unit projections

- `0x2C4[0:16]`: engine-speed candidate, `BE16 × 0.78125 rpm`, 1,277 records.
- `0x2D0[0:16]`: rotational-speed candidate, `BE16 × 0.390625 rpm`, 1,184 records.
- `0x2C1 byte6`: accelerator candidate, `byte6 × 0.5 %`, 1,083 records.

Steering-shaped `0x025`, selector-shaped `0x2D0 byte2`, temperature-shaped `0x2C4 byte3`, and brake-family `0x224` remain raw-only because their scales or meanings are unresolved.

## Derived evidence

Statistics use complete projections before graph sampling: minimum, maximum, mean, population standard deviation, peak-to-peak, coefficient of variation, record count, and session count.

The `0x2C4` and `0x2D0` candidates pair one-to-one only inside the same gateway and session with bounded time skew.

The corpus has 625 pairs and Pearson correlation about `0.992298`. This is a candidate rotational relationship, not proof of gear, Park, converter slip, or driveline health.

## Product view

Discovery links to CAN Units & Derived Data: eligible J1979 values, candidate-unit cards with raw lineage, raw-only channels, full-evidence statistics, rotational analysis, and retained playback.

The iPhone and Android views preserve source hashes, sessions, raw values, transform IDs, and authority. Import never upgrades a candidate.

## Live identifier coverage

The live view is not restricted to the five identifiers that currently have pinned candidate fields.
Every current-session, persisted, listen-only `RAW_CAN_FRAME` identifier may appear in the raw bus
lane. The checked-in real corpus currently contains these 17 identifiers:

`0x020`, `0x022`, `0x023`, `0x025`, `0x223`, `0x224`, `0x2C1`, `0x2C4`, `0x2D0`, `0x2D2`,
`0x3D0`, `0x420`, `0x423`, `0x4C1`, `0x4C3`, `0x4C6`, and `0x4C7`.

Pinned fields may additionally show the explicitly recorded candidate transform and unit. All other
identifiers remain `RAW ONLY` and expose only evidence that arrived from the gateway: identifier,
DLC, payload bytes, source sequence, age/freshness, observation count/rate where defensibly
measured, and byte changes. An identifier name, physical unit, or vehicle meaning is never inferred
from presence or visual shape alone. Missing identifiers remain absent rather than appearing as zero.

## Source records

- `vehicle-signal-packs/standards/j1979-mode01-obdb-d3259214.v1.json`
- `vehicle-signal-packs/toyota-4runner-2005-passive-can-hypotheses.v1.json`
- `docs/development/CAN-SIGNAL-INTERPRETATION-2026-08-18.md`
- `build/device-free-acceptance/2026-08-24-185114-final/evidence/full/hypotheses.json`
