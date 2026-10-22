# 2005 4Runner CAN and OBD source audit

> Follow-up: the source-pinned, executable hypothesis pack and its evaluation against all 5,176
> retained observations are documented in
> [`CAN-SIGNAL-INTERPRETATION-2026-08-18.md`](CAN-SIGNAL-INTERPRETATION-2026-08-18.md).
> The expanded 21-source, whole-line evidence graph is documented in
> [`TOYOTA-LEXUS-CAN-CROSS-PLATFORM-LINEAGE-2026-08-18.md`](TOYOTA-LEXUS-CAN-CROSS-PLATFORM-LINEAGE-2026-08-18.md).
> This earlier audit preserves the capture and research boundary as it existed at the time.

Date: 2026-08-18

Status: discovery research; no signal promotion

Machine-readable companion:
[`vehicle-signal-packs/research-source-registry.v1.json`](../../vehicle-signal-packs/research-source-registry.v1.json)

## Outcome

Internet research can eliminate a substantial amount of blind experimentation, but it cannot yet
replace exact-vehicle validation.

The highest-confidence no-experiment path is legislated OBD-II. SAE J1979 defines diagnostic
request/response services and points to its Digital Annex for PID definitions. The standard itself
requires applicability to be verified for the exact vehicle, engine, model year, and region. The
gateway should therefore enumerate supported PIDs using a narrowly allowlisted, read-only request
before displaying any standardized value.

Toyota-specific broadcast CAN is different. No authoritative public DBC for the exact 2005
4Runner configuration was found in this review. Published Toyota research and a third-party DBC
artifact contain several identifiers that also occur in our capture, which is valuable
corroboration, but neither source proves byte layout, scale, units, or applicability for this
vehicle.

## Source authority ladder

| Level | Source | What it can establish | Important limit |
|---|---|---|---|
| A | [SAE J1979](https://saemobilus.sae.org/standards/j1979_201009-e-e-diagnostic-test-modes) | Standard emissions-diagnostic request/response behavior and the existence of versioned PID definitions | Supported data remains vehicle/model-year/region dependent; the applicable historical revision and Digital Annex must be licensed and pinned |
| A | [Toyota Technical Information System](https://www.techinfo.toyota.com/techInfoPortal/appmanager/t3/ti?_nfpb=true&_pageLabel=ti_whats_tis) | VIN/model/year-specific repair information, wiring information, and Toyota diagnostic tooling | TIS/Techstream is subscription content and does not imply a publishable raw broadcast-CAN DBC |
| B | [Colorado State University Toyota CAN interpretation](https://www.engr.colostate.edu/~jdaily/tucrrc/ToyotaCAN.html) | Independent measurement and CAN correlation on a documented 2010 Toyota Camry, including exact identifiers and cadence | Different model, model year, ECUs, calibration, and options; discovery candidates only |
| C | [comma.ai opendbc](https://github.com/commaai/opendbc) | Version-pinned community DBC definitions plus parsing, replay, comparison, and reverse-engineering workflow | The reviewed repository does not provide an accepted exact 2005 4Runner definition for this project |
| C | [Toyota/Lexus DBC artifact](https://github.com/billyjack2/CAN-DBC-Collection/blob/6e2f88fd6cd9c1f47d0db7bd022711b106f27027/TOYOTA/LEXUS/can1v3.dbc) | Candidate field layouts for a named Toyota/Lexus AiM protocol | Community collection, no exact 4Runner applicability proof, and no license shown for copying it into this project |
| C | [AiM production-ECU documentation catalog](https://www.aim-sportline.com/it/documentazione-connessioni-ecu-serie.htm) | Vendor-published list of supported vehicle protocols and connection documents | No exact 2005 4Runner entry was established in this review |

Copyrighted standards and Toyota service content may be consulted and cited. They must not be
copied wholesale into this public repository. Only independently verified facts and project-owned
definitions should be committed.

## Cross-reference against retained 4Runner evidence

The following table preserves this audit's historical five-session, 2,544-record retained-capture
boundary; the later executable evaluation covers eight sessions and 5,176 records. This table
compares the historical subset with the CSU 2010 Camry research and the third-party DBC artifact. `CROSS_MODEL_CANDIDATE`
means "worth testing first," not "decoded."

| Identifier | Current 4Runner acquisition fact | Internet research | Status |
|---|---|---|---|
| `0x022` | Present; change-rich; candidate additive checksum matches all retained applicable frames | CSU calls it steering-like and reports changing fields | `CROSS_MODEL_CANDIDATE` |
| `0x023` | Present; DLC 7; change-rich; candidate checksum matches | CSU also records DLC 7 but leaves the meaning unknown | `CORROBORATED_ID_ONLY` |
| `0x025` | Present; bytes 4/5/6 agree in retained samples; candidate checksum matches | CSU identifies steering data; the DBC artifact labels a steering-angle field | `CROSS_MODEL_CANDIDATE` |
| `0x223` | Present; candidate checksum matches | CSU observed it and left it unknown | `CORROBORATED_ID_ONLY` |
| `0x2C1` | Present; change-rich; candidate checksum matches | Independent Camry and Lexus physical studies identify pedal behavior at byte 6; pinned mappings propose `0.5 percent/count` | `HIGH_PRIORITY_CROSS_MODEL_CANDIDATE` |
| `0x2C4` | Present; change-rich; correlated with `0x2D0`; candidate checksum matches | Independent Camry and Lexus physical studies identify RPM-related data; pinned mappings propose `0.78125 rpm/count` | `HIGH_PRIORITY_CROSS_MODEL_CANDIDATE` |
| `0x2D0` | Present; first-word relationship with `0x2C4`; candidate checksum matches | Lexus physical research finds RPM- and gear-related data; the FJ mapping proposes turbine speed, but the two sources conflict on gear-field placement | `CROSS_MODEL_CANDIDATE` |
| `0x420` | Present; candidate checksum matches | No mapping was found in the reviewed sources | `UNMAPPED` |

Additional cross-model identifiers worth watching, without asserting they must be present, include
`0x0B0`/`0x0B2` for wheel-speed candidates, `0x224` for a brake-pressure candidate, `0x380` for an
A/C-related candidate, `0x398` for a fuel-related candidate, and `0x610` for a vehicle-speed
candidate. Each remains blocked from a production label until exact-vehicle evidence satisfies the
Vehicle Signal Pack promotion path.

## What can be obtained without a bespoke CAN experiment

1. Resolve the exact VIN, engine, drivetrain, emissions region, and option set.
2. Use the applicable historical SAE J1979 revision and Digital Annex to implement only standard,
   read-only OBD services.
3. Query the supported-PID bitmaps first; unsupported PIDs remain absent rather than zero.
4. Record standard values, DTCs, freeze-frame availability, and identification data with the exact
   request/response evidence and contract version.
5. Use Toyota TIS repair/wiring information to establish topology and applicability.
6. Use Toyota Techstream Data List as an independent read-only reference for enhanced values when
   available.
7. Apply public Toyota mappings only as ranked hypotheses against captures already on the iPhone.

This path should yield useful engine and emissions telemetry before we decode most broadcast
frames. It does not authorize Active Tests, DTC clearing, ECU coding, or arbitrary diagnostic
requests.

## Minimal experiments that remain necessary

Internet sources cannot establish that a cross-model identifier has the same definition on this
specific 4Runner. Remaining experiments can be short and targeted:

- compare the `0x2C4` candidate with simultaneous standard-OBD or Techstream engine speed;
- correlate `0x025` with center/left/right steering markers;
- correlate `0x2C1` with rest and three separated pedal applications;
- compare `0x2D0` against engine speed, vehicle speed, and gear transitions; and
- look for the cross-model wheel-speed, brake, and A/C identifiers during labeled events.

One synchronized capture with independent reference values can answer these questions more safely
than many unlabeled drives.

## AI ingestion boundary

The research registry is committed at a stable path, so an AI working from the public repository
can ingest it automatically. New iPhone CAN and BLE evidence is not automatically uploaded: the
current app prepares an evidence package and exposes it through the share sheet.

The recommended next transport is a private, authenticated evidence outbox:

```text
iPhone immutable evidence package
  -> redact according to owner policy
  -> hash and encrypt
  -> authenticated private object store/inbox
  -> agent verifies manifest and claims package
  -> interpretation references immutable evidence IDs
```

Automatic ingestion must preserve the existing authority boundary: an AI may interpret evidence
and propose a signed experiment, but it may not transmit vehicle frames, activate an experiment,
or install firmware.

## Promotion decision

No identifier or scale is promoted by this research pass. The source registry is discovery input
only. The next practical implementation milestone is read-only supported-PID enumeration, followed
by a single synchronized standard-OBD/Techstream comparison capture.
