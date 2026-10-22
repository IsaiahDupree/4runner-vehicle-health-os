# Toyota/Lexus CAN cross-platform signal lineage

Date: 2026-08-18

Status: source-recorded discovery research; zero accepted target signal definitions

Machine-readable companion:
[`toyota-can-cross-platform-lineage.v1.json`](../../vehicle-signal-packs/toyota-can-cross-platform-lineage.v1.json)

Target: 2005 Toyota 4Runner; VIN, engine, drivetrain, market, and option configuration unresolved

## Executive result

The public record is now strong enough to rank several target identifiers intelligently, but not
strong enough to publish any Toyota-specific decoded value as fact.

The best-supported lineages are:

1. `0x2C4` is an engine-speed message family across physical Camry and Lexus experiments, a
   related FJ Cruiser mapping, Toyota/Lexus/Auris/IS F community DBCs, and Yaris listen-only notes.
2. `0x2C1` is an accelerator-pedal message family. Independent Camry and Lexus experiments support
   pedal behavior at byte 6 (zero-indexed), while four pinned mappings converge on
   `0.5 percent/count` and another Toyota/Lexus artifact uses a different layout.
3. `0x025` is a steering-angle family, but the sources conflict on width, scale, and direction.
4. `0x224` is a braking family, but the sources conflict materially on field position and pressure
   scaling.
5. `0x223` shares a transmitter with `0x224` on the researched Camry and is brake-related in the
   FJ artifact, but the Camry semantic study itself left `0x223` unknown.
6. `0x2D0` is independently RPM- and gear-related in a physical Lexus study, but only the FJ
   mapping supplies the turbine scale, and the two sources conflict on gear/selector byte placement.

That is useful progress. The source disagreements are not a failure of research; they are direct
evidence that Toyota reused message families while changing implementations. The safe result is a
short, high-value validation sequence rather than a guessed dashboard.

## What “verified” means here

This audit separates four independent questions:

| Question | Required evidence |
|---|---|
| Does the target emit the identifier? | Raw target capture with identifier, DLC, bitrate, timestamps, and provenance |
| Has the identifier carried this semantic on another Toyota/Lexus vehicle? | Version-pinned DBC or primary physical-correlation research |
| Is the byte layout and scale valid on this target? | Simultaneous independent reference plus target CAN and labeled state transitions |
| May the app show the value as vehicle truth? | Versioned signal definition, exact applicability, golden replay, and missing/stale/range tests |

Only the first question has been answered directly by the current 4Runner captures. Cross-model
sources answer the second question. None may silently answer the third or fourth.

## Authority ladder

### A — Toyota/Lexus/SAE primary documentation

- Toyota's exact-model-year
  [2005 4Runner owner manual](https://assets.sia.toyota.com/publications/en/om-s/OM35860U/pdf/OM35860U.pdf)
  identifies both `1GR-FE` and `2UZ-FE` configurations. That makes VIN and configuration
  resolution a prerequisite, not optional metadata.
- Toyota's archived
  [General 2005 Features CAN section](https://www.scribd.com/document/391265361/51-Power-Steering)
  directly documents a 500 kbit/s 2005 4Runner/Tundra CAN joining the skid-control ECU, ECM,
  steering-angle sensor, yaw/deceleration sensor, and DLC3. It contrasts that topology with the
  2005 Sequoia's added suspension-control and translate ECUs. The pages identify Toyota copyright
  and repair-manual publication `1165U`, but the public host is an unversioned third-party mirror;
  the provenance limitation is retained in the machine-readable record.
- The adjacent-model-year Toyota GSIC 4Runner manual `RM00T1U`/`NM0010U`, preserved in a
  [version-pinned public archive](https://gitlab.com/ToyotaManuals/rm00t1u/-/tree/729e2480c90ffd3525595400ddd69024077f487b),
  covers `GRN210/GRN215` and `UZN210/UZN215`. Its CAN diagnostics expose the steering-angle
  sensor through the intelligent tester's CAN VIM and BUS CHECK, while its engine references
  distinguish `ACCEL POS` and `ACCEL POS#2` as separate measured channels.
- Toyota's related Land Cruiser/Prado
  [New Features CAN description](https://toyotamanuals.gitlab.io/PZ471-Z00W0-CA/htmlweb/ncf/ncf276e/m_05_0242.pdf)
  documents a 500 kbit/s VSC network connecting the skid-control ECU, engine ECU,
  steering-angle sensor, yaw/deceleration sensor, DLC3, and—in the stated 1KD configuration—ECT
  ECU.
- [Toyota Techstream Lite](https://www.techinfo.toyota.com/techInfoPortal/appmanager/t3/ti?_nfpb=true&_pageLabel=ti_ts_lite)
  documents factory-level DLC3/J1962 diagnostics for 1996-and-later North American Toyota,
  Lexus, and Scion vehicles.
- Toyota [Tech Tip T-TT-0615-20](https://static.nhtsa.gov/odi/tsbs/2020/MC-10177575-9999.pdf)
  defines a marked Techstream drivability snapshot containing engine speed, vehicle speed,
  accelerator position, intake-air temperature, output-axis speed, NT sensor speed, selector
  status, lockup, and related values.
- Toyota [T-SB-0086-13](https://static.nhtsa.gov/odi/tsbs/2013/MC-10132241-9999.pdf)
  uses the Techstream Steering Angle Sensor Data List value on 2009-2011 Camry vehicles.
- A Lexus [RX campaign procedure](https://static.nhtsa.gov/odi/rcl/2012/RCMN-12V305-6789.pdf)
  records redundant accelerator-sensor or accelerator-position Data List values at released and
  fully depressed states.
- Toyota [T-SB-0160-18](https://static.nhtsa.gov/odi/tsbs/2021/MC-10198131-9999.pdf)
  compares engine speed with transmission revolution sensor NT speed under controlled conditions.
- [SAE J1979](https://saemobilus.sae.org/standards/j1979_201009-e-e-diagnostic-test-modes)
  provides the standard, read-only OBD path; the exact applicable revision and Digital Annex must
  be licensed and pinned before formulas become project truth.

These establish exact or adjacent vehicle applicability, network topology, independent reference
values, and procedures. The GSIC and New Features files are Toyota-authored manual content on
third-party public archives, so the host and available revision are recorded explicitly. None of
these sources discloses the target's raw broadcast-CAN layouts.

### B — primary vehicle research

- [Colorado State University’s 2010 Camry research](https://www.engr.colostate.edu/~jdaily/tucrrc/ToyotaCAN.html)
  physically correlated actions with 11-bit, 500 kbit/s CAN messages.
- The peer-reviewed USENIX paper
  [Fingerprinting Electronic Control Units for Vehicle Intrusion Detection](https://rtcl.eecs.umich.edu/rtclweb/assets/publications/2016/sec16-final165_final.pdf)
  used separate ground truth to group transmitters on the same 2010 Camry data.
- The Netherlands Forensic Institute paper
  [Evaluation of a common practice – to calculate speed from EDR-reported RPM](https://www.researchgate.net/publication/355445796_Evaluation_of_a_common_practice_-_to_calculate_speed_from_EDR-reported_RPM)
  used a 2010 Lexus IS250, synchronized crank/cam and pedal/brake references, DLC CAN logging,
  controlled road tests, and EDR replay. It independently associates `0x2C4` with RPM, `0x2C1`
  byte 7 (one-indexed) with accelerator-pedal behavior, and `0x2D0` with RPM and current gear.
  The [EVU record](https://www.evu-online.org/bewertung-der-gaengigen-praxis-der-geschwindigkeitsberechnung-anhand-der-vom-edr-gemeldeten-motordrehzahl)
  identifies the authors, vehicle, publication venue, and year.
- The pinned [Prius CAN Translator](https://github.com/HbirdJ/CAN-Translator/tree/4674872629f7fddc4eb8b76a69004222ec471687)
  preserves raw logs and documents VSI-2534 acquisition plus VBox GPS validation. It supports the
  synchronized-reference method, not any target mapping by itself.

### C — version-pinned community definitions

- [2012 FJ Cruiser RealDash XML](https://github.com/janimm/RealDash-extras/blob/cedfdf491b53d331625930909f949b657441f4a3/RealDash-CAN/XML-files/toyota/toyota_fj_can.xml)
- [comma.ai opendbc at `b4ef5e1`](https://github.com/commaai/opendbc/tree/b4ef5e1cf406ff143fa67bdbfb154739d43279c9/opendbc/dbc)
- [generic Toyota/Lexus AiM-derived DBC](https://github.com/billyjack2/CAN-DBC-Collection/blob/6e2f88fd6cd9c1f47d0db7bd022711b106f27027/TOYOTA/LEXUS/can1v3.dbc)
- [Toyota Auris AiM-derived DBC](https://github.com/billyjack2/CAN-DBC-Collection/blob/6e2f88fd6cd9c1f47d0db7bd022711b106f27027/TOYOTA/AURIS/can1v3.dbc)
- [Lexus IS F AiM-derived DBC](https://github.com/billyjack2/CAN-DBC-Collection/blob/6e2f88fd6cd9c1f47d0db7bd022711b106f27027/LEXUS/IS_F/can1v3.dbc)
- [Toyota Yaris listen-only notes](https://github.com/P1kachu/talking-with-cars/blob/ddd7a2b7137a67aeac84a0eb858b57bc08aee38c/notes/toyota-yaris.md)

These are discovery inputs. Their labels do not become accepted target definitions because they
appear in multiple repositories; forks and transcriptions are not automatically independent
evidence.

## Why these are defensible related vehicles

Toyota’s own production records place 4Runner, Land Cruiser Prado, LC200, and Lexus GX on a
Tahara production line and Prado and FJ Cruiser on a Hamura line. Toyota separately documents the
FJ Cruiser with a 1GR-FE 4.0-liter engine and five-speed electronically controlled transmission:

- [Toyota production relationship](https://global.toyota/en/newsroom/corporate/32615825.html)
- [Toyota FJ Cruiser specification](https://global.toyota/en/detail/325290)

This makes FJ/Prado/GX rational research cohorts, especially if the target VIN resolves to the
1GR-FE configuration. It does not establish identical ECUs, calibration, network topology, or CAN
payloads. The same caution applies even more strongly to Camry, Prius, iQ, Yaris, Auris, and IS F.

## What the same-generation manuals add

The exact 2005 owner manual closes an important applicability gap: a generic “2005 4Runner” label
does not resolve the engine family. The adjacent 2006 service set then supplies target-family
diagnostic observables without pretending they are payload definitions:

| Manual evidence | What it contributes | What it cannot contribute |
|---|---|---|
| 2005 owner manual | Exact-model-year `1GR-FE`/`2UZ-FE` configuration boundary | CAN IDs, fields, scales, or PID support |
| 2005 General Features CAN section | Exact-model-year 500 kbit/s 4Runner/Tundra topology; contrasts Sequoia node population | Raw CAN identifiers, payload layouts, scales, or exact target option traffic |
| 2006 `RM00T1U` steering communication page | Same-generation steering sensor appears on tester `BUS CHECK` via `CAN VIM` | `0x025` identity, bit width, scale, or direction |
| 2006 `RM00T1U` accelerator reference | Two independent accelerator channels and released/depressed voltage ranges | `0x2C1` byte location or percent scaling |
| Land Cruiser/Prado New Features page | Related-SUV VSC CAN at 500 kbit/s and a named node topology | Exact 4Runner topology or any payload definition |

This is the appropriate use of manuals in reverse engineering: they tell us which physical and
diagnostic channels exist, which configurations differ, and what independent measurements to log.
They do not authorize a decoded dashboard value without target correlation.

## Signal-by-signal lineage

### `0x2C4` — strongest candidate: engine speed

| Source vehicle/corpus | Source claim | What agrees | What remains open |
|---|---|---|---|
| 2010 Camry physical research | First two payload bytes change with engine speed | Identifier and semantic family | Exact scale not established for target |
| 2010 Lexus IS250 physical/EDR research | `0x2C4` first-byte-position data is RPM-related | Independent identifier, field-position, and semantic corroboration | Exact target scale not established |
| 2012 FJ Cruiser XML | Engine RPM, raw divided by 1.28 | First word and `0.78125 rpm/count` | Community source; later vehicle |
| Generic Toyota/Lexus DBC | RPM at `0.78125 rpm/count` | Identifier and scale | Supported vehicle/year unspecified |
| Auris DBC | RPM at `0.78125 rpm/count` | Identifier and scale | Cross-model only |
| Lexus IS F DBC | RPM at `0.78125 rpm/count` | Identifier and scale | Cross-model only |
| Yaris listen-only notes | First 16 bits are high-rate engine revolutions | Identifier, field family | Explicitly guessed; no scale |
| Target capture | Present and dynamic; correlated with `0x2D0` | Target actually emits the ID | No simultaneous trusted RPM reference yet |

The first-word RPM hypothesis is the highest-priority candidate in the repository. It still remains
`DISCOVERY_ONLY`. A single synchronized standard-OBD PID `0x0C` or Techstream Engine Speed
comparison can confirm or reject the scale.

The same message illustrates why semantic recurrence is not enough. The FJ file labels a candidate
air-temperature byte with one transform, while the Lexus IS F file applies `2.5*raw-40` to its
temperature field. Until Techstream or J1979 intake-air temperature is synchronized, the app must
not show that byte in degrees.

### `0x2C1` — strong candidate: accelerator pedal

The CSU Camry experiment reports pedal-related behavior. The NFI Lexus experiment independently
reports accelerator-pedal-voltage behavior at byte 7 using one-indexed notation, which is byte 6 in
the repository's zero-indexed notation. The FJ, Auris, Lexus IS F, and generated Toyota opendbc
artifacts converge on that eight-bit field with `0.5 percent/count`.

The generic Toyota/Lexus DBC conflicts: it uses a seven-bit field elsewhere with
`1 percent/count`. Other Toyota generations also use different messages and normalized units.

Decision: prioritize byte 6, but validate it at released and at least three separated stable pedal
positions against Techstream or a supported standard accelerator PID. Do not label it throttle
plate angle; driver pedal, commanded throttle, and measured throttle are different quantities.

### `0x025` — strong semantic family, unresolved units

The Camry physical research, FJ artifact, Prius/iQ/later-Toyota opendbc definitions, and generic
Toyota/Lexus/IS F DBCs all make `0x025` a steering-angle family. They do not agree on the decode:

| Pinned definition | Width / representation | Scale / direction |
|---|---|---|
| 2009 Toyota iQ opendbc | signed 11-bit | `1 degree/count` |
| 2010 Prius and generated Toyota opendbc | signed 12-bit | `1.5 degrees/count` |
| Generic Toyota/Lexus and Lexus IS F DBCs | 12-bit field | `1.5 degrees/count` |
| 2012 FJ XML | circular signed 12-bit interpretation | approximately `-0.087890625 degree/count` |

This conflict is decisive. The target app may say “steering-angle candidate,” but no displayed
degree value is valid until a centered wheel plus marked left/right angles are correlated with
Techstream on the same monotonic timeline.

### `0x224` — brake family, unsafe to scale yet

CSU and the FJ artifact associate a pressure-like field with `0x224`; the generic Toyota/Lexus,
Auris, and IS F DBCs also assign braking or pressure fields to it; Yaris notes identify a brake bit.
Their byte positions and pressure scales disagree.

The current retained target evidence did not exercise the candidate field. Therefore:

- the identifier is a high-value brake experiment target;
- no bar, psi, or pedal-pressure value may be displayed;
- a press/release/press sequence must establish causality; and
- a Toyota Data List pressure or stop-light state must provide the independent reference.

### `0x223` — likely brake-neighborhood message, not decoded

The FJ XML proposes a brake-state bit. CSU recorded the message but left its meaning unknown.
University of Michigan’s peer-reviewed Camry analysis independently established that `0x223` and
`0x224` came from the same transmitter on that vehicle.

That transmitter relationship increases the value of a braking experiment, but it does not prove a
stop-light-switch semantic on the target.

### `0x2D0` — turbine/input-speed hypothesis

The FJ XML maps the first word to turbine speed at `0.390625 rpm/count` and its third byte to
selector state. CSU observed `0x2D0` on its Camry but left it unknown. The NFI Lexus experiment
independently found RPM-related data and current gear in `0x2D0`, but locates current gear in its
fifth byte. That field-placement disagreement is important evidence against blindly merging the
two mappings. Toyota’s official NT-sensor procedure provides the correct independent reference:
compare Engine Speed and NT Sensor Speed under a controlled state.

Decision: keep the FJ transform and both gear-field placements as competing candidates only.
Validate Park, launch, shifts, steady speed, coast, and stop against engine speed, NT/turbine speed,
vehicle speed, selector, and lockup.

### `0x022`, `0x023`, and `0x420`

- `0x022`: CSU calls it steering-like. There is no second exact field definition; keep ID-level.
- `0x023`: the target and Camry evidence both show a seven-byte message, but CSU left it unknown.
  opendbc also contains an address `0x023` for an aftermarket Zorro steering sensor; that is
  explicitly excluded as evidence for the OEM target frame.
- `0x420`: no relevant mapping was found; remain unmapped.

## Broader Toyota/Lexus corpus coverage

The pinned opendbc Toyota platform catalog uses a small set of generated DBC families across later
Alphard, Avalon, Camry, C-HR, Corolla, Highlander, Mirai, Prius/Prius v, RAV4, Sienna, and Yaris
platforms and Lexus CT, ES, GS F, IS, LC, LS, NX, RC, and RX platforms. This is meaningful evidence
of family reuse and model/generation variation. It is not a historical 2005 4Runner DBC.

The repository therefore records the whole reviewed line as a lineage matrix, not as one merged
Toyota decoder. Merging definitions would erase the very conflicts that protect us from displaying
plausible but wrong numbers.

## What the current 4Runner evidence can support now

The target corpus establishes acquisition facts only:

- 11-bit CAN at 500 kbit/s;
- eight retained sessions and 5,176 retained observations in the pinned analysis;
- 17 observed identifiers;
- target presence and payload behavior for the listed IDs; and
- candidate checksum and cross-signal statistical evidence already recorded in the hypothesis
  evaluation.

It cannot yet establish vehicle-health conclusions from these candidates. A dynamic byte is not a
sensor identity, a plausible range is not a unit, and cross-model agreement is not exact
applicability.

## Minimal validation run

One well-instrumented trip can settle most high-value questions:

1. Resolve VIN, engine, drivetrain, region, and options.
2. Enumerate standard supported PIDs with the read-only J1979 allowlist.
3. Start a target CAN capture and Techstream/scan-tool snapshot on the same monotonic timeline.
4. Record explicit markers for engine-off, idle, three pedal levels, wheel center/left/right,
   brake release/light/firm, P/R/N/D, launch, steady speed, shifts, coast, and stop.
5. Fit each competing transform and preserve rejection evidence.
6. Promote only exact definitions that pass replay plus missing, stale, malformed, and range tests.

Recommended reference pairs:

| CAN candidate | Independent reference |
|---|---|
| `0x2C4` word 0 | J1979 engine RPM or Techstream Engine Speed |
| `0x2C4` temperature byte | J1979 intake-air temperature or Techstream Intake Air Temperature |
| `0x2C1` byte 6 | Techstream accelerator position or supported legislated accelerator PID |
| `0x025` signed field | Techstream Steering Angle Sensor plus physical wheel markers |
| `0x224` / `0x223` | Techstream brake/pressure/stop-light state plus physical markers |
| `0x2D0` word 0 | Techstream NT/turbine speed, engine speed, selector, and lockup |

## Promotion boundary

This research changes hypothesis priority, not authority:

- accepted target signal definitions: **0**;
- production Toyota-specific value display: **blocked**;
- automatic AI promotion: **forbidden**;
- arbitrary CAN transmission: **forbidden**; and
- read-only diagnostic requests: only through the explicit allowlist and safety gates.

Every future value must retain the chain:

```text
raw target observation
  -> source-pinned candidate
  -> synchronized independent reference
  -> versioned signal definition
  -> golden replay and failure tests
  -> accepted sample with provenance
```

That chain lets the documentation tell the complete story—including what matched, what conflicted,
what was rejected, and why a number was or was not allowed onto the Android/iPhone UI.
