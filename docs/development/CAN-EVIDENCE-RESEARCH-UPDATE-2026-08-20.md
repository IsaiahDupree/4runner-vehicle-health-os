# CAN Evidence and Research Update — 2026-08-20

## Outcome

The latest iPhone export is intact, reproducible evidence, but it is not a new passive-CAN capture. All eight exported session files match the eight files already preserved in `test-replay/real-can-2026-08-18/sessions` byte for byte and by SHA-256. Re-running discovery and hypothesis evaluation against the phone copy produced the same semantic results as the checked-in corpus.

This is useful confirmation that iPhone retention, export, and replay preserve the evidence. It does not increase the number of vehicle conditions represented in the corpus.

## Export inventory

| Item | Result |
| --- | ---: |
| Passive-CAN sessions | 8 |
| Retained CAN records | 5,176 |
| Passive-CAN bytes | 2,081,023 |
| Portable VHOS logical frames | 3,584 |
| Unique CAN identifiers | 17 |
| Identifier format | standard 11-bit |
| Bitrate | 500 kbit/s |
| Gateway mode | listen only |
| Exact corpus matches | 8 of 8 |

The portable logical-frame stream includes connection and health evidence, but it does not contain an additional passive-CAN session beyond the eight-file corpus.

## Acquisition quality

The retained corpus spans 140.831 seconds. Source-sequence timing implies approximately 75,899 observed frames at 538.88 frames/second. The export contains 5,176 retained records at 36.753 records/second, or 6.8196% sequence coverage.

That percentage is the configured retained-evidence density. It is not proof that the TWAI receive path dropped 93% of vehicle traffic. Receive-loss attribution requires the gateway's TWAI, observer-queue, persistence, and storage counters on the same timeline.

The next recorder revision should preserve these separate counters:

- hardware frames received;
- RX queue full events;
- observer queue drops;
- records admitted to durable storage;
- records written successfully;
- storage latency and buffer high-water marks;
- export sampling policy and exported record count.

## What the current data proves

- One gateway captured 5,176 standard 11-bit, non-RTR frames at 500 kbit/s while reporting listen-only operation.
- Seventeen identifiers are present with reproducible payload ranges and activity statistics.
- The Toyota additive checksum candidate matches every applicable retained record for `0x022`, `0x023`, `0x025`, `0x223`, `0x2C1`, `0x2C4`, `0x2D0`, and `0x420`.
- `0x025` bytes 4, 5, and 6 agree in all 667 retained samples; maximum channel disagreement is zero.
- `0x2C4[0:16]` and `0x2D0[0:16]` have 625 time-aligned pairs and Pearson correlation 0.992130. Under the two cross-model candidate transforms, their median same-unit ratio is 0.989529.
- The iPhone export can be replayed without changing the raw evidence or the machine-readable findings.

These are acquisition and statistical conclusions. They do not establish vehicle-health meaning.

## What research adds

The new peer-reviewed SAE source, Ruth, Bartlett, and Daily, *Accuracy of Event Data in the 2010 and 2011 Toyota Camry During Steady State and Braking Conditions* (SAE 2012-01-0999), used synchronized independent reference acquisition and CAN logging. On its tested Camry family it identifies:

- `0x2C4` as engine-speed traffic, updated every 24 ms;
- `0x2C1` as accelerator-pedal-position traffic, updated every 512 ms;
- `0x610` as vehicle-speed traffic; and
- a standard 11-bit, 500 kbit/s Toyota CAN network.

This is strong primary, cross-model evidence and has been added to signal-hypothesis pack `0.4.0`. It independently raises the priority of `0x2C4` and `0x2C1`. It does not prove that the 2005 4Runner has the same field scale, offset, calibration, or ECU behavior.

Toyota service material also confirms that Techstream exposes engine speed, accelerator position, vehicle speed, temperatures, stop-light state, output-axis speed, NT/turbine speed, selector state, and related diagnostic values. Those values are the independent reference channels for target-vehicle validation; the service material does not publish the raw broadcast-CAN byte layout.

## Candidate interpretation, with boundaries

| Raw candidate | Current result | Allowed conclusion |
| --- | --- | --- |
| `0x2C4[0:16]` | 659 records; raw 0–5,660; cross-model transform 0–4,421.875 rpm | Highest-priority engine-speed candidate; engineering-only until synchronized PID `0x0C` or Techstream validation |
| `0x2D0[0:16]` | 626 records; raw 0–11,339; candidate 0–4,429.297 rpm; highly correlated with `0x2C4` | Related rotational-state candidate; engine/turbine/input identity remains unresolved |
| `0x2C1` byte 6 | 631 records; raw 0–95; candidate 0–47.5% | High-priority accelerator-pedal candidate; scale and cause remain unverified |
| `0x025` signed field | 667 records; raw -12–39 | Steering-family candidate; conflicting cross-model scales block degree display |
| `0x2C4` byte 3 | raw 30–50 | Temperature-family candidate; conflicting `raw` versus `2.5*raw-40` transforms block temperature display |
| `0x224` candidate field | 143 records, all zero | The current capture did not exercise the proposed brake-pressure field |
| `0x223` | two payload states | Brake-family/transmitter clue only; no accepted field mapping |
| `0x023`, `0x420` | present | Meaning unknown |

Accepted production signal definitions remain **zero**. The owner health map, maintenance engine, findings, recommendations, and lifecycle baselines must not consume these values yet. Android and iOS may show them only on an engineering research surface with an explicit **UNVERIFIED CROSS-MODEL HYPOTHESIS** badge and the raw evidence lineage.

## What Android can display now

The Android head unit can safely display:

- gateway identity and verified transport status;
- 11-bit / 500 kbit/s / listen-only acquisition state;
- frame, queue, persistence, and bus-error counters when reported;
- raw identifier population, per-ID cadence, raw bytes, and byte ranges;
- checksum candidate health and retained-evidence coverage;
- downloadable/replayable session identity and SHA-256 lineage; and
- the unverified candidate cards above on an engineering-only screen.

It must not label a candidate as actual RPM, pedal percentage, steering degrees, turbine RPM, brake pressure, or temperature on the owner-facing dashboard until the validation gates pass.

## Next capture when the device returns

Resolve the VIN, engine, drivetrain, market, and option configuration first. Then perform one labeled, synchronized, parked-first capture with the iPhone experiment marker, passive gateway, and Techstream or a trusted legislated-OBD reference on a shared timeline:

1. Ignition on, engine off: 15 seconds.
2. Start and stable idle: 60 seconds.
3. Three separated, safe parked throttle levels or brief blips, returning fully to idle between each.
4. Steering centered, approximately left/right 90 degrees, and left/right 180 degrees while stationary where mechanically safe.
5. Three complete brake press/hold/release cycles.
6. A/C off, request on, compressor engagement, and stabilized operation with explicit markers.
7. Only in a safe driving location: Park/Drive transition, steady low speed, coast, brake, stop, and return to Park.

The gateway remains passive and listen only. Standard diagnostic reads must be narrowly allowlisted, rate-limited, completely logged, and limited to supported-PID enumeration plus approved read-only values. No Active Tests, DTC clearing, coding, reprogramming, or arbitrary CAN transmission is authorized.

## Acceptance gates for the next dataset

- Independent reference values and experiment markers share the gateway monotonic timeline.
- Capture stages are separately labeled and repeatable.
- Hardware receive, queue, persistence, and export counters reconcile without silent gaps.
- `0x2C4` passes engine-off, idle, and multiple separated reference-RPM comparisons before any promotion.
- `0x2C1` passes rest plus at least three separated reference-pedal levels.
- `0x025` resolves field width, sign, direction, center, and scale against reference steering angle.
- `0x2D0` is tested across Park, Drive, shifts, steady speed, coast, and stop to distinguish engine-correlated from turbine/input behavior.
- Every proposed decoder has a versioned definition, golden replay, range checks, stale/missing behavior, and rejection evidence.

## Versioned artifacts

- Hypothesis pack: `vehicle-signal-packs/toyota-4runner-2005-passive-can-hypotheses.v1.json`, version `0.4.0`.
- Updated evaluation: `docs/evidence/can-signal-hypotheses-2026-08-20-5176.report.json`.
- Acquisition report: `docs/evidence/can-discovery-2026-08-18-5176.report.json`.
- Replay corpus: `test-replay/real-can-2026-08-18/`.
- Source registry: `vehicle-signal-packs/research-source-registry.v1.json`.
- Cross-platform lineage: `vehicle-signal-packs/toyota-can-cross-platform-lineage.v1.json`.

No number in these artifacts becomes vehicle truth merely because it is plausible. Promotion still requires raw observation → decoded signal → independent reference → versioned definition → replay evidence → accepted calculation lineage.
