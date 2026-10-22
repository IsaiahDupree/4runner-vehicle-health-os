# Shared contracts

`jsonschema/v1/` defines durable JSON/NDJSON objects used in capture bundles, exports, replay, and cross-layer tests. `proto/v1/` preserves the original compact-payload design, including added-sensor A/C messages. `wire/v1/` records the payload encodings actually deployed by the OBD/CAN firmware and mobile clients; deployed JSON/binary messages must not be decoded as protobuf merely because the older design file exists.

## Contract rules

- A released schema is immutable. Add a new version instead of changing historical meaning.
- Every serialized document names its contract and semantic version.
- Protobuf field numbers are never reused.
- Unknown additive protobuf fields are preserved/ignored according to generated runtime behavior.
- Raw observations retain exact payload bytes and hashes; decoding never replaces them.
- JSON is the durable/debug representation. A transport payload uses the encoding fixed by the deployed wire registry for its protocol version.
- No contract may introduce arbitrary CAN transmission or hidden actuation.
- A pressure engineering value is unavailable unless the telemetry names its configured calibration identity and revision; raw ADC/voltage evidence remains available independently.

## Discovery v1

The `vhos.discovery.*@1.0.0` contracts turn a retained capture into a reviewable,
cross-platform Discovery workflow without converting hypotheses into vehicle truth:

- `capture-session`, `event-marker`, `physical-measurement`, and
  `vehicle-capability-snapshot` are `OBSERVED` evidence records.
- `candidate-signal` and `recommended-test` are always
  `EXPERIMENTAL_CANDIDATE`.
- validation checklists and promotion decisions remain `EXPERIMENTAL_CANDIDATE`
  in v1. Caller-provided reference strings and an unsigned reviewer record cannot
  grant vehicle authority.
- v1 promotion is assessment-only and always blocked. A future contract version
  must resolve and hash-verify exact evidence bytes and authenticate the approving
  reviewer before `VEHICLE_VALIDATED` or `PROMOTED` can be emitted.
- capture wall time declares whether it came from synchronized capture epoch time
  or later evidence-ingestion time. Gateway monotonic time remains the physical
  correlation clock.
- every newly written marker and physical measurement binds to one exact gateway recorder
  session; repeated monotonic or sequence counters across restarts cannot be joined. Older v1
  records without that optional extension remain readable but are ineligible for correlation.
- JSON Schema provides structural validation; `ContractCatalog.validate` also enforces semantic
  capture invariants that JSON Schema cannot express, including unique marker/measurement IDs,
  matching capture/session lineage, and declared time/sequence envelopes. Importers must run both
  layers before accepting a capture.

Interop examples in `examples/v1/discovery-*.json` are bound to the retained
`real-can-2026-08-18-627753796-256.ndjson` fixture. They describe evidence and
cross-model candidates only; they are not a 2005 4Runner signal authority pack.

Run `vhos contracts check` after any schema change.

## Maintenance ledger v1

`vehicle.asset`, `vehicle.component-registry-entry`, `vehicle.maintenance-record`,
`vehicle.maintenance-audit-event`, `vehicle.maintenance-requirement`, and
`vehicle.maintenance-source-manifest` define the vehicle-agnostic lifecycle and
maintenance boundary shared by the Android truth store and future companion sync. The
existing `vehicle.configuration-profile@1.0.0` remains the immutable 2005
4Runner configuration contract; a generic asset does not inherit those
pack-specific constants.

Maintenance records are revision chains. A correction appends a revision with
`supersedes_revision_id` and `amendment_reason`; a user-facing delete appends a
`VOIDED` revision. Implementations must never physically update or delete a
record revision or audit event. Attachment bytes remain in private object
storage while the contract retains their hashes, type, size, availability, and
storage key.

All new lifecycle identities are typed ULIDs under ADR-0002. A maintenance occurrence states
whether the evidence is an exact instant or only a calendar date; a date-only receipt is never
assigned a fabricated time. Unknown system or component identity is represented explicitly rather
than guessed. A completion that claims to satisfy an OEM requirement binds the exact pack,
manifest hash, requirement version, task, rule hash, and due/baseline identity.

Source manifests are executable activation gates, not prose checklists. An active manifest must
have complete reviewed locators, applicability and independent review, legal approval for
normalized facts, regression evidence, and a signed promoted-pack digest. Draft manifests cannot
produce due state.
