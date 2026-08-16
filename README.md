# 4Runner Vehicle Health OS

Local-first, explainable vehicle-health and maintenance software for a 2005 Toyota 4Runner.

The signed-off product baseline is [PRD v0.1](docs/prd/2005_Toyota_4Runner_Vehicle_Health_OS_PRD_v0.1.docx). Its governing invariant is:

> raw observation -> decoded signal -> feature -> versioned equation -> calculation run -> finding -> recommendation -> service/inspection -> new lifecycle baseline

No derived value is authoritative unless that lineage can be reconstructed.

## Current baseline

E0 is implemented here as an executable contract and replay foundation:

- stable typed domain IDs;
- versioned JSON Schemas for evidence, signals, captures, equations, calculations, and AI claims;
- a protobuf source contract and fixed transport-frame decision for Android/ESP32 interoperability;
- deterministic simulator capture bundles with hashes and manifests;
- offline replay with integrity, sequence, timestamp, and schema validation;
- CI checks for schema validity and deterministic replay;
- explicit Android and ESP32 module boundaries with passive/read-only safety constraints.

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
| `contracts/proto/v1/` | Android/ESP32 payload source contract |
| `tooling/` | Contract validator, simulator, bundle writer, and replay engine |
| `tests/` | Contract, determinism, corruption, ordering, and replay tests |
| `android/` | Android module boundaries for E1/E3 onward |
| `firmware/` | ESP32 component boundaries and read-only safety policy for E2 onward |
| `vehicle-signal-packs/` | Validated vehicle-specific signal/configuration packs; no speculative constants |

## Development order

1. E1: Android append-only local truth store and lifecycle ledger.
2. E2: ESP32 passive TWAI capture, health counters, and BLE transport on a bench harness.
3. E3: Android ingest, reconnect/deduplication, raw persistence, and replay adapter.
4. E4: verified generic OBD baseline plus target-vehicle signal discovery and validation.
5. E5/E6: maintenance schedule and equation/lineage engines before owner-facing scoring.

See [E0 implementation record](docs/delivery/E0-IMPLEMENTATION.md) for the exact backlog and acceptance mapping.

## Safety boundary

- Production gateway startup is passive/listen-only.
- There is no arbitrary CAN-transmit command in the shared contract.
- Any diagnostic request references a firmware-resident allowlist entry; Android does not supply raw request bytes.
- Active Tests, vehicle control, ECU flashing, and code clearing are outside MVP scope.
- Gateway health/data loss is never presented as vehicle failure.
