# E0 implementation record

## Outcome

E0 establishes the repository and executable contract/replay foundation. It intentionally does not claim live-vehicle, Android UI, or ESP32 hardware functionality.

## PRD mapping

| PRD item | Implementation | Verification |
| --- | --- | --- |
| E0 repository/module skeleton | Top-level Android, firmware, signal-pack, contract, tooling, test, and documentation boundaries | Repository structure review |
| B-001 shared versioning conventions | ADR-0002 and semantic contract fields | Schema checks |
| B-002 gateway envelope and sequence/CRC semantics | ADR-0001 plus `gateway.proto` | Contract review and schema checks |
| B-003 simulator gateway source | Deterministic `cold-start-idle` scenario with hashed capture bundles | Simulator and replay tests |
| FR-004 timestamps/sequence/quality | Raw Observation and Signal Sample schemas | Schema and replay tests |
| FR-005 raw capture independent of decoding | Manifest plus hashed NDJSON raw segment | Corruption/replay tests |
| FR-008 signal quality | Enumerated quality contract and propagation | Replay tests |
| FR-051 replay isolation | Replay output remains in `sim.*` namespace and is not a live-alert source | Replay tests |
| FR-052 simulator source | Executable CLI works without a gateway | End-to-end CI command |
| NFR-005 monotonic time | Strict replay ordering validation | Timestamp disorder test |
| NFR-007 deterministic replay | Stable IDs, stable samples, stable digest | Repeat-run determinism test |

## Deliberate boundaries

- Vehicle-specific constants and enhanced Toyota signals remain absent until E4 validation.
- The simulator emits an explicit `SIMULATOR_STATE_V1` payload, not invented CAN frames.
- Protobuf code generation is deferred to the Android and ESP-IDF build environments; the `.proto` source is authoritative now.
- The gateway command surface contains an allowlist-reference request but no raw CAN-transmit primitive.
- Equation schemas define an immutable declarative AST contract; equation execution begins in E6.

## Exit criteria

E0 is complete when all schemas pass Draft 2020-12 validation, a generated bundle passes manifest/hash/sequence checks, replay creates contract-valid signal samples, a corrupted bundle is rejected, and two runs of the same scenario produce the same semantic digest.
