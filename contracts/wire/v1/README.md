# VHOS deployed wire registry v1

This registry records the interoperable payload encoding physically used by the OBD/CAN ESP32 and
the iPhone client. It supplements ADR-0001. The original protobuf file remains immutable historical
design input; it is not permission to decode deployed JSON or binary payloads as protobuf.

Every message is carried inside the 36-byte little-endian `VHOS` envelope defined by ADR-0001.
Header and payload CRC32C validation occurs before this registry is consulted.

| Code | Name | Deployed payload encoding | Current state |
| ---: | --- | --- | --- |
| 1 | handshake | UTF-8 JSON: `gateway.handshake` or `gateway.handshake.request` | deployed |
| 2 | raw CAN frame | 36-byte binary live-record v1 | deployed |
| 3 | diagnostic response | versioned payload reserved by client | not emitted by current firmware |
| 4 | gateway health | UTF-8 JSON: `gateway.health` | deployed |
| 5 | capture marker | versioned JSON | reserved |
| 6 | allowlisted diagnostic request | semantic/versioned payload only; never arbitrary bytes | reserved |
| 7 | experiment plan | signed versioned JSON | client support; not advertised by current firmware |
| 8 | OTA control/status | UTF-8 JSON | deployed |
| 9 | agent handoff acknowledgement | versioned JSON | reserved |
| 10 | experiment result | versioned JSON | client support; not advertised by current firmware |
| 11 | capture-log request | 8-byte binary request v1 | deployed |
| 12 | capture-log index | UTF-8 JSON: `gateway.capture-log-index` | deployed |
| 13 | capture-log chunk | 16-byte binary header plus zero or more CRC32C 36-byte records | deployed |

The A/C node does not yet have a deployed BLE payload registry. Its current `EMPTY_RECOVERY` image
does not advertise BLE. Sensor telemetry/health/POST message-code assignment must be accepted as a
new compatible registry revision or protocol major before firmware ships; it must not reuse codes
8 or 9 from the deployed mobile/gateway registry.

## Compatibility rule

Changing a message's encoding at the same protocol version is prohibited. A protobuf migration or
sensor-code allocation requires coordinated firmware, Android, and iOS golden vectors. Unknown
message codes are rejected; arbitrary CAN transmit payloads remain intentionally absent.

## Portable app handoff

Android and iOS exchange `.vhossync` ZIP archives with uncompressed entries. The archive contains
`manifest.json` conforming to `evidence-sync-bundle.schema.json` and the declared NDJSON segments.
Each segment and each embedded envelope is SHA-256 verified before an append-only import. ZIP entry
paths must be relative, unique, declared by the manifest, and free of `.`/`..` components.
