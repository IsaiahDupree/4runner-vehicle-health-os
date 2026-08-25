# iOS Discovery ledger codec incident — 2026-08-22

Status: root cause confirmed; compatibility fix implemented for iOS 0.3.22 (29); existing evidence must be preserved and decoded in place.

## Field symptom

On **Run Test**, all live evidence-readiness checks passed, including the VHOS gateway contract,
passive recorder, honest `UNKNOWN` motion state, fresh listen-only CAN timeline, and required
gateway capabilities. The app then reported:

> The append-only Discovery ledger test-run-drafts.ndjson is invalid at line 1.

This failure is local to the iPhone's persisted Discovery ledger. It is not a BLE, ESP32, CAN,
Park-authority, or recorder-readiness failure.

Before installing the fix, both field ledgers were copied from the app data container. The captured
test-run ledger is one valid 439-byte line with SHA-256
`dcfd0dae4a29a7d96ab75eb30411a2d19dd180d7a82bf719c8854691d0ac801e`; its matching 221-byte
capture-binding ledger has SHA-256
`4c0d483d34abfe2fd153dfe506165e1be5e892561b78d8a871b9f13e1a1ffe35`. Both pass independent JSON
syntax validation. Their exact bytes are represented by a field-incident regression test.

## Root cause

The ledger records are encoded with `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase` and
decoded with `JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`. Swift's synthesized
`Codable` mapping does not round-trip acronym-bearing property names:

```text
Swift property templateID
    -> encoded key template_id
    -> decoded candidate templateId
    != synthesized property key templateID
```

The same defect affected `captureID`, `testRunID`, `gatewayID`, and `gatewaySessionID` across the
capture-binding, marker, and test-run-draft ledgers. The app therefore wrote a valid committed
NDJSON record and could fail to decode that same record on its next read or launch.

## Fix

Each persisted Discovery record now declares explicit `CodingKeys` whose raw acronym spelling is
lower camel case (`templateId`, `gatewaySessionId`, and so on). The global JSON strategies still
emit the unchanged snake-case wire format, while existing snake-case records decode correctly.

No migration, deletion, line skipping, or ledger rewrite is required. Successful reads leave the
source bytes untouched. Truly malformed committed lines continue to fail closed.

The app also tracks test-run and marker-ledger availability separately. A marker-ledger failure
must not hide a valid active run or prevent an evidence-preserving abort. Begin, marker, and end
actions remain disabled whenever the ledgers required for that mutation are unavailable. Retry and
raw recovery/export remain non-destructive.

## Regression requirements

- Pin exact pre-fix snake-case lines for all three ledgers.
- Decode and validate those lines with iOS 0.3.22.
- Assert encoder output retains the existing snake-case contract.
- Assert successful reads do not change any source byte.
- Replay active-to-ended and active-to-aborted append-only run histories.
- Keep malformed committed lines byte-identical and fail closed.
- Preserve a valid active run even if an independent marker ledger fails.
- Preserve and report any truncated, uncommitted tail using the existing quarantine mechanism.

## Operator guidance

Do **not** clear app data, delete the app, remove the BLE bond, or manually edit the NDJSON file to
resolve this incident. Install iOS 0.3.22 (29), reopen **Run Test**, and use **Retry ledger read** if
needed. If an earlier run is recovered as active, either continue the matching test or abort it in
the app; both paths retain the prior append-only evidence.
