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

## Source records

- `vehicle-signal-packs/standards/j1979-mode01-obdb-d3259214.v1.json`
- `vehicle-signal-packs/toyota-4runner-2005-passive-can-hypotheses.v1.json`
- `docs/development/CAN-SIGNAL-INTERPRETATION-2026-08-18.md`
- `build/device-free-acceptance/2026-08-24-185114-final/evidence/full/hypotheses.json`
