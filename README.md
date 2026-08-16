# 4Runner Vehicle Health OS

Local-first, explainable vehicle-health and maintenance software for a 2005 Toyota 4Runner.

The project has two immutable source baselines: [Vehicle Health OS PRD v0.1](docs/prd/2005_Toyota_4Runner_Vehicle_Health_OS_PRD_v0.1.docx) and [Telemetry Build Master Spec v1](docs/prd/4Runner_Telemetry_Build_Master_Spec.docx). Their joined authority and unique requirement namespaces are defined in the [master project specification](docs/prd/MASTER-PROJECT-SPEC.md). The governing invariant is:

> raw observation -> decoded signal -> feature -> versioned equation -> calculation run -> finding -> recommendation -> service/inspection -> new lifecycle baseline

No derived value is authoritative unless that lineage can be reconstructed.

## Current baseline

E0 plus the first native iOS control slice are implemented here:

- stable typed domain IDs;
- versioned JSON Schemas for evidence, signals, captures, equations, calculations, and AI claims;
- a protobuf source contract and fixed transport-frame decision for mobile/ESP32 interoperability;
- deterministic simulator capture bundles with hashes and manifests;
- offline replay with integrity, sequence, timestamp, and schema validation;
- CI checks for schema validity and deterministic replay;
- a Swift 6 core with CRC32C framing, guarded discovery plans, signed firmware verification, OTA preflight, and AI evidence handoff;
- a buildable native SwiftUI app with BLE state restoration, WiCAN factory detection, gateway health, signed semantic experiments, private-network OTA, and evidence export;
- explicit iOS, legacy Android, gateway firmware, and added-sensor hardware boundaries.

No target-vehicle PID, threshold, service interval, or trim-specific constant is invented in this baseline. Those enter only through independently validated, versioned Vehicle Signal and Configuration Packs.

## Quick start

Requires Python 3.12 or newer.

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e './tooling[test]'
.venv/bin/vhos contracts check
.venv/bin/vhos simulate --scenario cold-start-idle --output build/captures/cold-start-idle
.venv/bin/vhos validate-bundle build/captures/cold-start-idle
.venv/bin/vhos replay build/captures/cold-start-idle
.venv/bin/python -m pytest
```

The simulator namespace is deliberately separate from live vehicle data. It creates deterministic engineering evidence for automated tests; it never represents itself as a Toyota measurement.

## Repository map

| Path | Responsibility |
| --- | --- |
| `docs/prd/` | Immutable product baseline and source integrity record |
| `docs/architecture/decisions/` | Accepted technical decisions and invariants |
| `contracts/jsonschema/v1/` | Authoritative serialized domain contracts |
| `contracts/proto/v1/` | Mobile/ESP32 payload source contract |
| `tooling/` | Contract validator, simulator, bundle writer, and replay engine |
| `tests/` | Contract, determinism, corruption, ordering, and replay tests |
| `ios/` | Native iOS app, portable Swift core, and deterministic XcodeGen project |
| `android/` | Preserved original Android module boundary; not the primary client after ADR-0003 |
| `firmware/` | ESP32 component boundaries and read-only safety policy for E2 onward |
| `vehicle-signal-packs/` | Validated vehicle-specific signal/configuration packs; no speculative constants |

## Development order

1. E1: iOS append-only local truth store and lifecycle ledger; the gateway contract client is now scaffolded.
2. E2: WiCAN Pro VHOS fork with passive capture, health counters, framed BLE, constrained discovery, and signed rollback-capable OTA on a bench harness.
3. E3: iOS ingest, reconnect/deduplication, raw persistence, and replay adapter.
4. E4: verified generic OBD baseline plus target-vehicle signal discovery and validation.
5. E5/E6: maintenance schedule and equation/lineage engines before owner-facing scoring.

See [E0 implementation record](docs/delivery/E0-IMPLEMENTATION.md) for the exact backlog and acceptance mapping.

## Safety boundary

- Production gateway startup is passive/listen-only.
- There is no arbitrary CAN-transmit command in the shared contract.
- Any diagnostic request references a firmware-resident allowlist entry; iOS does not supply raw request bytes.
- Active Tests, vehicle control, ECU flashing, and code clearing are outside MVP scope.
- Gateway health/data loss is never presented as vehicle failure.
