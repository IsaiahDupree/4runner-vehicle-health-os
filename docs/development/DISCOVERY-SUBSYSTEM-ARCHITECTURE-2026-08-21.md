# Discovery Subsystem Architecture — 2026-08-21

## Outcome

Discovery is a first-class Vehicle Health OS subsystem. It is the controlled path by which an
unknown observation can become an accepted, reusable vehicle signal:

> Connect → Discover → Design Test → Capture → Mark Events → Analyze → Compare → Validate →
> Promote → Consume in Vehicle Health

Discovery does not weaken the system's evidence boundary. A plausible graph, a correlated byte, an
AI suggestion, or a matching signal from another Toyota is not vehicle truth. The production health
UI may consume only a versioned signal definition that passed the promotion checklist.

## Product modes

| Mode | Primary purpose | Android head unit | iPhone |
| --- | --- | --- | --- |
| Drive | Trusted, low-distraction vehicle information | Primary | Companion review |
| Garage | Maintenance, diagnostics, inspections, guided tests | Primary | Primary field remote |
| Engineering | Capture, raw signals, discovery, validation, and replay | Primary workspace | Mobile controller and review |

Engineering controls remain parked-only. The gateway remains passive/listen-only unless a narrowly
allowlisted, read-only diagnostic request is explicitly authorized. Discovery never introduces an
arbitrary CAN-transmit path.

## Platform roles

### Android head unit

- Maintains persistent gateway sessions with the OBD/CAN gateway and A/C sensor node.
- Persists raw observations before derived materializations.
- Owns long capture sessions, high-density plots, raw-bus exploration, candidate inspection, and
  the Replay Lab.
- Stores the local vehicle truth database and versioned Signal Registry.
- Exports checksummed evidence bundles and imports them append-only.

### iPhone

- Starts and stops guided tests while the user is elsewhere in or around the vehicle.
- Records large, one-tap event markers, independent measurements, notes, and photos.
- Shows connection/capture quality without treating transport state as vehicle health.
- Reviews candidates and validation evidence.
- Replays retained evidence, prepares evidence handoff, and syncs with Android through portable,
  versioned contracts.

The interfaces are intentionally different. Android is the dense, landscape engineering console;
iPhone is the hand-held test controller and evidence companion.

## Authority states

Every signal-like object has one explicit authority state:

1. **Observed** — raw evidence exists, with source and time lineage.
2. **Experimental candidate** — a decoder or meaning is proposed and measurable, but not accepted.
3. **Vehicle validated** — the proposal passed target-vehicle, repeatability, independent-reference,
   and replay gates.
4. **Promoted** — a versioned Signal Definition has been admitted to the active Vehicle Signal Pack.
5. **Rejected** — evidence contradicts the proposal or the field is not useful for the claimed meaning.

Unknown and unavailable are valid outcomes. A missing value is never replaced with zero. UI color,
labels, filters, and exports must retain these distinctions.

## Versioned records

The cross-platform Discovery records are serialized independently from either UI.

### Capture Session

A session binds immutable evidence and experimental context:

- typed session, vehicle, profile, and gateway identities;
- wall-clock and monotonic capture windows;
- firmware, protocol, configuration-pack, signal-pack, and decoder versions;
- raw capture segment hashes and record counts;
- OBD request/response evidence and allowlist identity;
- external-sensor observations;
- user event markers and physical measurements;
- test-template revision and completion state;
- acquisition counters, reconnects, queue drops, persistence failures, and bus errors;
- analysis results, candidates, validation evidence, and notes.

Raw observations are immutable. Re-analysis creates new versioned outputs; it does not rewrite the
capture.

Recorder monotonic clocks and source sequences are session-local. Multi-session captures retain an
explicit window for each gateway session; event correlation requires both the marker time and its
nearest sequence to resolve inside that exact session. A recorder-session change immediately clears
live CAN and J1979 projections, and late frames from the previous session are ignored rather than
shown as current vehicle state.

### Event Marker

An event marker records:

- a stable marker ID, canonical capture ID, and exact gateway recorder-session ID for new evidence;
- gateway-aligned monotonic time when available;
- wall time and phone ingestion time;
- event type, asserted state, observer, and optional note;
- nearest raw sequence and time-distance to that observation;
- optional independent measurement references.

Markers are append-only evidence. Editing a label creates a superseding record with lineage.
Legacy v1 markers that predate recorder-session binding remain decodable, but analysis excludes
them rather than guessing which rebooted monotonic clock they belong to.

### Physical Measurement

A manual or external reference measurement retains value, unit, instrument/source, calibration
information when known, capture time, uncertainty when known, and the person/device that observed it.
The app may display an entered value but cannot silently upgrade it to an OEM measurement.

### Vehicle Capability Snapshot

A capability scan is a dated fact set, not a live assumption. It records detected buses, responding
ECUs, supported J1979 PID ranges per ECU, gateway capabilities, known/unknown signal counts, and the
evidence hashes that produced the snapshot. A later scan creates another snapshot so changes can be
compared.

### Candidate Signal

A candidate contains the raw field definition, proposed semantic identity, transform hypothesis,
statistics, labeled-event correlations, independent-reference comparisons, tests observed, false
activations, conflicts, confidence components, supporting evidence, contradicting evidence, and the
recommended next experiment. Its confidence is an engineering prioritization aid, not authority.

## Promotion gate

Promotion fails closed until every required item passes:

- canonical signal identity is defined;
- raw source and layout are defined;
- transform, type, and canonical unit are defined;
- plausible range and freshness behavior are defined;
- target-vehicle capture exists;
- the behavior repeats in more than one controlled test;
- independent corroboration exists (J1979, Techstream, calibrated sensor, or accepted OEM source);
- failure, missing, stale, and out-of-range behavior is tested;
- golden replay passes with the proposed decoder;
- applicability to the resolved vehicle configuration is explicit;
- provenance and contradictions are preserved;
- reviewer/approval record is present.

AI may rank candidates, explain correlations, and recommend the next test. AI cannot satisfy an
independent corroboration gate or sign a promotion on the owner's behalf.

Discovery contract v1 is deliberately assessment-only. It records checklist assertions and
machine-readable blockers, but it cannot emit `VEHICLE_VALIDATED` or `PROMOTED`: the current
contract has no resolver that proves a reference names the exact expected evidence bytes and no
signed reviewer-identity envelope. Those authority states require a future contract version with
both mechanisms and migration/replay tests.

## Navigation

### Diagnostics

- Overview
- Live Signals
- Signal Discovery
- Tests
- Capture Sessions
- Candidate Signals
- Validated Signals
- DTCs
- Gateway
- Replay Lab

### Signals

- All
- Known
- Standard OBD
- Toyota Enhanced
- Raw CAN
- K-Line
- External Sensors
- Candidates
- Validated
- Unavailable

Normal owner views consume canonical signal IDs such as `engine.rpm` or
`brakes.pedal_pressed`. They never bind directly to a CAN ID, byte, or experimental decoder.

## Discovery screens

### Discovery Home

Shows only observed state: gateway and bus status, supported-PID scan status, frames/second, unique
IDs, capture state, storage state, counts by authority, and current evidence freshness. When a value
has not been measured, the UI says unavailable or not yet analyzed.

Primary actions are Start Discovery, Run Test, Continue Test, Explore Signals, Analyze Captures,
Review Candidates, and Replay Evidence.

### Test Library and runner

Versioned procedure templates cover ignition cycle, cold start, RPM sweep, accelerator sweep, brake
pulse, steering sweep, wheel rotation, A/C on/off, blower and temperature sweep, 4WD transition,
suspension settle, tire-pressure change, electrical load, and controlled road test. Templates are
procedures, not vehicle data.

The runner presents one safe step at a time, captures explicit owner approval where required, and
offers large marker controls. Unsafe or motion-dependent procedures remain blocked until the
required state is deterministically established.

### Signal Explorer and detail

Explorer joins canonical signals, standard OBD values, raw activity, and candidates without merging
their authority. Filters include recently changed, marker-correlated, unknown, Boolean-like,
temperature-shaped, source, freshness, and authority. Detail views show source, update rate,
freshness, quality, transform, evidence, contradictions, and exact validation status.

### Candidate Inbox

Candidates are grouped as very strong, likely, needs more data, conflicting, and rejected. A card
explains which tests support it, what failed, whether an independent reference exists, and the
highest-information next test. There is no one-tap path that bypasses the promotion gate.

### Replay Lab

Replay uses immutable capture time rather than ingestion time. It supports play, pause, scrub,
speed, looping, session boundaries, synchronized plots, event markers, normalized overlays, and
re-running a versioned decoder. Production calculation outputs are recomputed as new Calculation
Runs. Regression output identifies affected signals and dependent health calculations.

### Discovery Progress

Coverage is expressed by system and stage: physical signals expected, acquired, decoded,
vehicle-validated, promoted, and used by a health model. Percentages require an explicit denominator
from the active vehicle configuration pack. Without that denominator, counts are shown instead of a
made-up percentage.

## Analysis views

The engineering workspace may provide synchronized traces, normalized overlays, scatterplots,
correlation, bit-state timelines, byte heatmaps, transition counts, histograms, update-rate
distributions, and event-triggered averages. Every view links back to capture hashes and exact raw
field definitions.

## First production vertical slice

The first slice is intentionally evidence-driven:

- use the eight immutable retained-CAN sessions (5,176 real records) as the replay corpus;
- expose a Discovery home that derives status from actual gateway/evidence state;
- provide versioned test templates and append-only event markers/measurements;
- show a candidate inbox based on existing candidate-only research outputs;
- deep-link to real retained-CAN playback and comparison;
- enforce the complete promotion checklist with zero accepted target-vehicle signals by default;
- define portable Discovery schemas, persist canonical event markers on iPhone, and keep Android's
  operational drafts behind an explicit mapping boundary until archive and manifest hashes exist;
- verify empty, disconnected, stale, corrupted, reconnect, and high-load states.

This slice is useful before another vehicle trip: it exercises the complete product workflow while
truthfully showing where independent target-vehicle evidence is still missing.

## Acceptance criteria

- Neither platform fabricates a live value, coverage percentage, test result, or validated signal.
- A capture/session restart does not mix identities or overwrite prior evidence.
- Marker time can be related to gateway monotonic time or is explicitly marked unaligned.
- A candidate cannot be promoted by Discovery v1, including when every checklist item is marked
  satisfied; exact evidence resolution and authenticated reviewer approval remain mandatory.
- The same stored session can drive iPhone playback and Android replay deterministically.
- Corrupt, stale, missing, reordered, duplicated, and interrupted input is visible and bounded.
- Driver mode cannot invoke raw engineering controls.
- All accepted values retain raw observation → signal definition → calculation/evidence lineage.

## Next increments

1. Finish the Android finalized-archive adapter and exchange portable Discovery records through the
   signed evidence bundle.
2. Run supported-PID enumeration into dated Vehicle Capability Snapshots.
3. Complete a synchronized parked RPM/brake/steering/A/C test with J1979 or Techstream references.
4. Rank candidate fields against those labels and preserve contradicting evidence.
5. Repeat the highest-information tests under independent vehicle conditions.
6. Promote the first target-vehicle signal only after the full checklist and golden replay pass.
7. Bind the owner-facing health UI to the promoted canonical signal ID.
