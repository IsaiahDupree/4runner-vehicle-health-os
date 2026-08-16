# Safe protocol discovery

## Goal

Determine which legislated OBD-II transport and safe read-only diagnostic path works on the VIN-resolved target 2005 4Runner, while producing replayable evidence and without exposing arbitrary vehicle-bus transmission.

This workflow discovers transport capability. It does not discover control commands, perform Active Tests, clear DTCs, reprogram ECUs, or brute-force Toyota services.

## Gateway experiment phases

### Phase 0 — bench verification

1. Run the iOS simulator/replay source and gateway frame vectors.
2. Power WiCAN Pro from the current-limited bench fixture.
3. Verify firmware/hardware IDs, BLE pairing, Wi-Fi status, capture storage, and recovery flashing.
4. Use CANable 2.0 to produce labeled 11-bit and 29-bit frames on isolated 500 kbit/s and 250 kbit/s bench networks.
5. Prove listen-only capture receives frames while contributing no ACK or data traffic.
6. Interrupt OTA and force self-test failure to prove rollback before vehicle connection.

### Phase 1 — vehicle passive observation

1. Resolve VIN/engine/drivetrain/trim applicability and save a profile snapshot.
2. Ignition off: connect only the WiCAN Pro. Confirm gateway power/health and transmission-disabled state.
3. Start a signed discovery experiment with candidates ordered `CAN_11_500`, `CAN_29_500`, `CAN_11_250`, `CAN_29_250`.
4. For each candidate, use listen-only mode, a bounded window, no diagnostic request, and record valid-frame rate, stable IDs, errors, overruns, and bus-off state.
5. Prefer the candidate with repeatable valid frames and zero/known-bounded errors. A graph that merely “looks active” is insufficient validation.

The target is expected to expose ISO 15765-4 CAN at DLC3 based on the existing repair-information evidence, but the app records this as a hypothesis until the target vehicle corroborates it.

### Phase 2 — dedicated-interpreter protocol identification

If passive CAN does not lock, invoke WiCAN Pro's dedicated OBD interpreter through a signed semantic plan. Candidate families are ISO 9141-2, ISO 14230-4 slow/fast, SAE J1850 PWM, and SAE J1850 VPW. The iPhone never supplies electrical timing or raw request bytes.

Each candidate may execute only the gateway-resident `obd.standard.supported-pids` read allowlist entry. Required gates:

- vehicle is parked;
- explicit user approval for the experiment;
- request and response rate limits;
- no concurrent scan tool;
- gateway voltage and health in policy;
- immediate abort on bus/interpreter errors;
- complete request/response audit record.

### Phase 3 — independent corroboration

1. Disconnect the experimental gateway or place it fully passive.
2. Use OBDLink MX+ to record the detected protocol and standard read-only values.
3. Compare common values and timestamps; never run both active requesters concurrently.
4. If available, use Toyota Techstream Data List as OEM corroboration for enhanced signals.
5. Promote a protocol/config only when the evidence bundle, reference observation, versions, and validation decision are persisted.

## Experiment result contract

Every result contains:

- experiment and immutable capture IDs;
- gateway hardware, firmware, config, protocol-contract, and allowlist versions;
- candidate protocol and phase;
- start/end monotonic and wall times;
- frame/response count, error count, dropped count, stable-ID count, and coverage;
- request allowlist IDs issued, if any;
- ground-truth/reference links;
- outcome: `NO_LOCK`, `PASSIVE_LOCK`, `READ_CONFIRMED`, `REJECTED_ERROR`, or `INCONCLUSIVE`;
- SHA-256 manifest/segment hashes and operator approval record.

## Authority boundary

The AI agent may rank candidates, explain evidence, and propose the next signed plan. It cannot activate a plan, add an allowlist entry, supply a raw CAN payload, clear a DTC, or override parked/health/rate gates.
