# Shared contracts

`jsonschema/v1/` defines durable JSON/NDJSON objects used in capture bundles, exports, replay, and cross-layer tests. `proto/v1/` defines the compact Android/ESP32 payload contract carried inside ADR-0001's binary frame.

## Contract rules

- A released schema is immutable. Add a new version instead of changing historical meaning.
- Every serialized document names its contract and semantic version.
- Protobuf field numbers are never reused.
- Unknown additive protobuf fields are preserved/ignored according to generated runtime behavior.
- Raw observations retain exact payload bytes and hashes; decoding never replaces them.
- JSON is the durable/debug representation. Protobuf is the transport representation.
- No contract may introduce arbitrary CAN transmission or hidden actuation.

Run `vhos contracts check` after any schema change.
