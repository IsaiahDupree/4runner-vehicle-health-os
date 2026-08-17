# Shared contracts

`jsonschema/v1/` defines durable JSON/NDJSON objects used in capture bundles, exports, replay, and cross-layer tests. `proto/v1/` defines compact mobile/ESP32 payload contracts carried inside ADR-0001's binary frame, including the separate added-sensor A/C node.

## Contract rules

- A released schema is immutable. Add a new version instead of changing historical meaning.
- Every serialized document names its contract and semantic version.
- Protobuf field numbers are never reused.
- Unknown additive protobuf fields are preserved/ignored according to generated runtime behavior.
- Raw observations retain exact payload bytes and hashes; decoding never replaces them.
- JSON is the durable/debug representation. Protobuf is the transport representation.
- No contract may introduce arbitrary CAN transmission or hidden actuation.
- A pressure engineering value is unavailable unless the telemetry names its configured calibration identity and revision; raw ADC/voltage evidence remains available independently.

Run `vhos contracts check` after any schema change.
