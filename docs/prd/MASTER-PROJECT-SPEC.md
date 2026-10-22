# 4Runner Vehicle Health OS — master project specification

Status: integration baseline v0.1
Date: 2026-08-16

This specification joins two immutable subordinate baselines without rewriting either one:

1. [Vehicle Health OS PRD v0.1](2005_Toyota_4Runner_Vehicle_Health_OS_PRD_v0.1.docx) governs explainability, maintenance intelligence, vehicle records, signal/equation lineage, owner workflows, security, and product acceptance.
2. [Telemetry Build Master Spec v1](4Runner_Telemetry_Build_Master_Spec.docx) governs added-sensor hardware, A/C instrumentation, protected power, logging, self-test, PCB/manufacturing artifacts, and the hardware feedback loop.

The later focused [A/C Engine-Bay Telemetry Node Spec v1.0 source record](AC-TELEMETRY-SOURCE.md)
controls the A/C node when it is more specific, including the corrected Nano
ESP32 VIN, independent sensor 5 V rail, and deliberately unfrozen pressure-sensor
transfer functions and permanent refrigerant fitting geometry.

[ADR-0003](../architecture/decisions/0003-ios-primary-control-surface.md) changes the primary mobile implementation from Android to native iOS. Original requirements remain preserved; iOS must satisfy their behavioral intent unless an explicit ADR says otherwise.

## Complete system boundary

```text
2005 4Runner
  ├─ DLC3 / OBD-II networks ──> WiCAN Pro VHOS gateway ─┐
  └─ Added pressure/temp/etc. ─> ESP32-S3 sensor node ───┤
                                                        v
                                              native iPhone app
                                                        |
                  append-only observations + manifests + evidence references
                                                        v
                   signal/config packs -> features -> versioned equations
                                                        v
            calculation runs -> findings -> recommendations -> service history
                                                        v
                 lifecycle baselines / component twins / owner UI / AI handoff
```

The OBD gateway and added-sensor node are separate devices in V0/V1. This prevents an unproven custom PCB from becoming a prerequisite for passive vehicle-bus discovery. A later consolidated board is allowed only after both interfaces have independent bench and vehicle evidence.

## Non-negotiable invariant

Every conclusion resolves through:

> raw observation -> decoded signal -> feature -> versioned equation -> calculation run -> finding -> recommendation -> service/inspection -> new lifecycle baseline

Gateway health, calibration, firmware identity, board revision, configuration identity, drop/error counters, and source-manifest checksums are part of that evidence—not implementation metadata that may be discarded.

## Requirement identity policy

- Existing Vehicle Health OS functional requirements retain their original `FR-###` IDs.
- Telemetry requirements receive `TEL-<domain>-###` IDs below.
- Cross-subsystem integration requirements use `INT-###`.
- Safety constraints use `SAFE-###`; they cannot be waived by an AI output.
- A requirement changes only through a versioned document or ADR. Tickets reference IDs; tickets do not redefine them.

### Telemetry hardware and mechanical requirements

| ID | Requirement |
| --- | --- |
| TEL-HW-001 | The added-sensor node shall use an ESP32-S3 and expose its exact module, board revision, pin map, and firmware build identity. |
| TEL-HW-002 | Vehicle power shall be fused near the source and include reverse-polarity, load-dump/transient, overcurrent, and brownout protection sized from measured behavior. |
| TEL-HW-003 | V1 shall provide two protected pressure inputs, at least three temperature inputs, microSD, service button, status LED, test points, and USB/UART recovery. |
| TEL-HW-004 | Vehicle-installed electronics shall use an IP-rated enclosure, sealed connectors, automotive TXL/GXL wire, abrasion protection, strain relief, and supported body/chassis mounting away from heat, rotating parts, and spray. |
| TEL-HW-005 | A/C wetted parts, seals, adapters, and hoses shall have manufacturer-backed R-134a compatibility; lubricant compatibility and service-port geometry require engineering review before installation. |
| TEL-HW-006 | High- and low-side interfaces shall remain keyed/labeled, leak checked after assembly, and mechanically supported so sensor mass is not carried by aluminum refrigerant lines. |
| TEL-HW-007 | Optional coin-cell BLE pressure pucks remain a later phase and shall not proceed until pressure containment, refrigerant compatibility, power budget, enclosure, and mechanical validation pass. |

### Telemetry firmware and data requirements

| ID | Requirement |
| --- | --- |
| TEL-FW-001 | Firmware shall separate sensor acquisition, health/POST/BIT, logging, BLE, Wi-Fi, OTA, configuration, time, and constrained command responsibilities. |
| TEL-FW-002 | POST shall persist reset cause, board/firmware revision, rail measurements, sensor plausibility, SD write/read/checksum, BLE/Wi-Fi startup, and overall result. |
| TEL-FW-003 | Continuous BIT shall detect range/rate/stuck values, cross-channel plausibility, storage latency/errors/free space, rail excursions, resets, communication counters, and task watchdog failures. |
| TEL-FW-004 | Logs shall be append-only, timestamped, checksummed, recoverable after interruption, and include calibration/config/firmware identity. |
| TEL-FW-005 | BLE shall provide bounded live telemetry, health, configuration identity, and diagnostics through a versioned contract. |
| TEL-FW-006 | Wi-Fi SoftAP shall provide authenticated local bulk log transfer and OTA; it shall not expose the device to the public internet. |
| TEL-FW-007 | OTA shall require a signed/versioned manifest, compatible board revision, inactive-slot install, probationary boot, POST/timed health validation, explicit mark-valid, rollback on failure, and persisted outcome. |

### Manufacturing requirements

| ID | Requirement |
| --- | --- |
| TEL-MFG-001 | The version-controlled PCB source shall generate schematic, routed PCB, Gerbers, BOM, CPL, STEP, net list, and machine-readable pin map from a pinned board revision. |
| TEL-MFG-002 | ERC, DRC, power, antenna keep-out, connector, protection, thermal, creepage, testability, and manufacturability reviews shall pass before purchase approval. |
| TEL-MFG-003 | JLCPCB/LCSC substitutions shall be explicit and reviewed; an AI or supplier may not silently substitute a safety-relevant part. |
| TEL-MFG-004 | Factory firmware and fixture shall emit machine-readable PASS/FAIL JSON covering rails, inputs, storage, radios, recovery, and board identity. |
| TEL-MFG-005 | Human purchase approval is required after an independent manufacturing-package check. |
| TEL-MFG-006 | Production firmware provisioning, enclosure/harness assembly, and first vehicle baseline occur only after factory self-test passes. |

### Integration and authority requirements

| ID | Requirement |
| --- | --- |
| INT-001 | Both gateways shall use compatible versioned handshake, health, evidence, experiment-result, and firmware-identity contracts. |
| INT-002 | The iPhone shall persist raw evidence before publishing a decoded or derived conclusion. |
| INT-003 | Simulator, replay, OBD gateway, and sensor-node observations shall enter the same validation/lineage pipeline while retaining distinct source identities. |
| INT-004 | Firmware update and discovery activation require a current gateway health report and deterministically `PARKED` vehicle state; the user cannot manually override motion state. |
| INT-005 | The iPhone may send only signed semantic experiment plans and firmware artifacts; it shall not expose arbitrary CAN/K-line/J1850 payload transmission. |
| INT-006 | AI handoffs shall carry evidence references, source identities, versions, checksums, uncertainty, and authority boundaries. |
| INT-007 | AI may interpret evidence, rank hypotheses, and propose a signed plan; AI may not approve/activate a vehicle experiment, clear codes, control actuators, or emit raw vehicle frames. |
| INT-008 | An equation result that cannot resolve to source observations, exact equation version, and calculation-run identity shall be shown as unavailable rather than healthy. |

### Safety requirements

| ID | Requirement |
| --- | --- |
| SAFE-001 | Vehicle-bus discovery is passive-first and time bounded. |
| SAFE-002 | Legacy protocol probing uses the gateway's dedicated interpreter and only firmware-resident semantic allowlist entries. |
| SAFE-003 | No active test, ECU flash, code clear, configuration write, or actuator control is in MVP scope. |
| SAFE-004 | Vehicle pressure work requires appropriate training, PPE, recovery/service practices, leak testing, and compliance with applicable refrigerant rules. |
| SAFE-005 | Gateway/sensor/storage failure shall be labeled as evidence-system degradation, never inferred as vehicle health. |

## Delivery sequence

1. Contracts, schemas, simulator, replay, immutable source records.
2. Native iOS local truth/evidence store and gateway contract client.
3. WiCAN Pro VHOS fork: passive capture, health, framed BLE, constrained discovery, signed A/B OTA.
4. Safe bench protocol discovery, then target-vehicle signal/config pack validation.
5. Maintenance and versioned equation engines, owner UI, condition models, and AI evidence loop.
6. Added-sensor V0 bench node, exact sensor/mechanical verification, POST/BIT, SD, BLE/Wi-Fi.
7. Protected vehicle-installed V1, then custom PCB/manufacturing loop.

No vehicle installation milestone is complete solely because code compiles. It requires real hardware evidence, signed manifests, and the applicable acceptance records.
