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
