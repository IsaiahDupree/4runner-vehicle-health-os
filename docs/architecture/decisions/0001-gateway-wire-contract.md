# ADR-0001: Gateway wire contract

- Status: Accepted
- Date: 2026-08-16
- Owners: Android ingest and gateway firmware

## Decision

Use a fixed little-endian binary frame header followed by a protobuf payload. BLE, Wi-Fi, and USB transports carry the same complete logical frames; transport-specific chunking is below this contract.

The 36-byte header is:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `VHOS` |
| 4 | 1 | protocol major |
| 5 | 1 | protocol minor |
| 6 | 1 | message type |
| 7 | 1 | flags |
| 8 | 4 | payload length in bytes |
| 12 | 8 | monotonically increasing sequence |
| 20 | 8 | gateway monotonic microseconds |
| 28 | 4 | CRC32C of the exact payload bytes |
| 32 | 4 | CRC32C of header bytes 0-31 |

Protocol major changes are incompatible. A receiver rejects an unknown major before parsing the payload. Minor changes are additive and negotiated in `Handshake`. Payload limits are transport/configuration policy, but a receiver must reject a frame larger than its advertised maximum before allocation.

The payload source contract is `contracts/proto/v1/gateway.proto`. Protobuf is selected because it supplies explicit field numbers, compact binary encoding, generated Kotlin/Javalite support, and nanopb-compatible embedded C generation.

## Safety properties

- There is no message that accepts arbitrary CAN identifier/data bytes for transmission.
- `AllowlistedDiagnosticRequest` names a firmware-resident allowlist entry; Android cannot smuggle raw request bytes through the contract.
- Firmware remains listen-only until its deterministic safety policy authorizes a known read request.
- Sequence gaps, CRC failures, reboots, and reconnects become gateway-health/data-quality evidence; they are not vehicle faults.

## Persistence boundary

Transport frames are not the durable truth format. Android validates a frame, then persists a `RawObservation` with gateway/config/protocol versions and content hash. Capture bundles use self-describing JSON/NDJSON plus SHA-256 so they remain inspectable and replayable without protobuf tooling.
