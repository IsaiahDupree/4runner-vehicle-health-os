# Next implementation slice: E1-E4

These tickets are ordered to preserve the PRD's truth and safety boundaries.

## E1 — iOS local truth store

1. Record the iOS bundle ID, minimum iOS version, supported iPhone hardware, encryption posture, release keys, and signing environments in an ADR.
2. Extend `ios/Core` domain types to cover the E0 identifiers and lifecycle contracts without coupling them to SwiftUI or CoreBluetooth.
3. Implement SwiftData/Core Data entities and migrations for Vehicle, Component, InstalledPart lifecycle, MaintenanceEvent, Inspection, Attachment metadata, and AuditEvent.
4. Enforce append-only correction by amendment links; add transaction and migration tests.
5. Implement profile applicability state so engine/drivetrain-specific rules remain inactive while unresolved.
6. Add repository interfaces shared by live, replay, and simulator sources; do not couple UI to BLE.

## E2 — Passive ESP32 capture

1. Select and document board, transceiver/protection, DLC3 harness, protected power input, storage, and bench simulator.
2. Create ESP-IDF project only after the hardware ADR is accepted.
3. Implement listen-only TWAI receive, timestamp/sequence, health counters, bus-off reporting, and bounded buffering.
4. Implement ADR-0001 framing and protobuf/nanopb generation with CRC32C tests shared against Android vectors.
5. Prove there is no transmit path in passive firmware configuration.
6. Capture bench traffic and validate drop/error accounting before touching the vehicle.

## E3 — iOS ingest and replay

1. Implement transport-neutral gateway connection state and version handshake.
2. Validate frame header/length/CRC before protobuf allocation/parse.
3. Persist raw evidence before publishing decoded/materialized state.
4. Implement sequence deduplication, gap events, clock alignment, reconnect/reboot boundaries, and backpressure.
5. Port the E0 bundle validator/replay contract to Kotlin and prove cross-language digest vectors.
6. Feed simulator, replay, and real gateway through the same ingest interface.

## E4 — Vehicle Signal Pack

1. Define the first configuration-pack manifest and compatibility contract.
2. Add only standards-backed generic OBD signals with primary-source provenance.
3. Validate the target DLC3 passive configuration and preserve the first signed manifest.
4. Enumerate target ECUs and candidate Toyota Data List items under the passive-first/allowlisted policy.
5. Build ground-truth comparison tooling and promote individual signals independently.
6. Keep unavailable and uncertain signals explicit; never convert missing evidence into a healthy state.
