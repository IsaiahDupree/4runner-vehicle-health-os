# iPhone Discovery workspace

Status: first vertical slice
Date: 2026-08-22

## Outcome

The iPhone Discovery tab is now an evidence-first workspace rather than a single protocol-plan form. It provides a usable path through:

> Connect -> choose a test -> capture -> mark ground truth -> review retained sessions -> inspect candidates -> replay

The screen does not claim that a cross-model CAN hypothesis is a validated 2005 4Runner signal. It uses four explicit authority labels:

1. `OBSERVED` — directly reported by the gateway or decoded through a pinned SAE J1979 definition.
2. `EXPERIMENTAL CANDIDATE` — a retained field selected by the versioned research pack, still requiring target-vehicle evidence.
3. `VEHICLE VALIDATED` — reserved for independent target-vehicle corroboration. The first slice shows this as unavailable because no validation registry is installed.
4. `PROMOTED` — reserved for an immutable signal-registry release. The first slice shows this as unavailable.

Unknown state is displayed as `UNAVAILABLE`; zero is not substituted for missing evidence.

## Discovery Home

The home screen derives its status only from current application state:

- verified VHOS gateway connection;
- gateway CAN lock/bitrate and cumulative receive counter;
- current J1979 ECU enumeration state;
- unique identifiers present in the bounded recent in-memory CAN window;
- distinct standard OBD signals actually decoded in the current context;
- experimental series actually produced from retained evidence;
- recorder and history-transfer state;
- gateway-reported free storage.

Frames per second, total unknown-field count, validation totals, and coverage percentages are intentionally absent because the current contracts do not supply defensible values for them.

## Test Library and marker controls

The test library is built from versioned, validated `VHOSCore.TestTemplate` contracts, not UI-only strings or signal definitions. A test describes what the owner should label and the safety boundary for the procedure. It never asserts that a CAN identifier or bit has a particular meaning. The first catalog covers ignition cycle, cold start, RPM and accelerator sweeps, brake pulse, steering sweep, A/C ON/OFF, fan and HVAC temperature sweeps, 4WD transition, electrical load, wheel rotation, suspension settle, tire-pressure change, and controlled road testing. Controlled road testing is visibly unavailable in iPhone driver-interaction mode and requires a future passenger-supervised workflow.

The runner exposes large ground-truth controls appropriate for use while moving around a parked vehicle. A marker is enabled only when all of the following are current:

- VHOS gateway contract connected;
- fresh gateway health deterministically reports `PARKED`, while handshake and health retain
  listen-only authority;
- gateway reports passive recording active;
- a matching versioned test-run draft is active; and
- a real CAN observation received within five seconds supplies a gateway session, source sequence,
  and monotonic timestamp.

The lifecycle is explicit: `Begin Session` creates an append-only local **test run draft**, marker controls become active only for that matching run, and `End Session` or `Abort` appends the terminal state. The app does not mislabel the draft as a finalized `CaptureSession`; finalization waits for the retained archive and manifest hashes required by the canonical contract.

Each accepted marker is a canonical `VHOSCore.EventMarker` appended to the local Discovery evidence ledger and binds to that exact gateway timeline location. A durable capture ULID maps the gateway's numeric recorder session into the domain contract. The app-local index adds the template and test-run reference without replacing the canonical marker. Both marker and run ledgers reload on launch. A marker cannot be created from wall-clock time alone and the app never creates a simulated CAN observation to make a button appear usable.

The marker timeline must also be fresh: the observation has to come from the verified gateway, prove listen-only mode, and have arrived within five seconds. A stale observation retained across a disconnect cannot become new ground-truth evidence. Capture review can export the append-only test-run snapshots, capture bindings, and canonical markers as an explicitly draft evidence artifact. Ending or aborting a run also queues that checksummed draft artifact in the existing private evidence outbox; it remains local when no authenticated HTTPS inbox is configured. An abort retains its wall-clock transition even when no current gateway observation exists; it does not claim a finalized capture boundary.

## Signal Explorer

The first slice separates two sources:

- `Observed / Standard OBD` shows the latest real sample per canonical J1979 signal from the current gateway/capture context. It retains ECU, PID, source sequence, definition revision, value, and unit.
- `Experimental Candidates / Retained Evidence` shows actual series from `PassiveCANResearchAnalyzer`, including retained record count, raw range, source count, research-pack identity, and the remaining validation gate.

There is no generic "known" badge. A candidate remains experimental even when a cross-model source provides a plausible transform.

## Candidate Inbox and progress

The first inbox is deliberately fail-closed. It lists retained research hypotheses under `Needs More Evidence`, but does not manufacture correlation, repeatability, confidence, false-activation, or corroboration scores. Ranking remains unavailable until the marker/measurement analyzer has sufficient synchronized inputs.

Discovery Progress reports evidence counts whose numerator is known. It does not show subsystem percentages because no versioned target signal inventory for the exact VIN configuration has been installed; therefore the denominator is unknown.

## Capture review and Replay Lab

Capture review lists real `CaptureSessionSummary` records from the append-only iPhone CAN store and exposes the existing guarded pause/download/resume operation. When a retained research report exists, the same screen embeds `PassiveCANPlaybackLab`:

- exact retained points only;
- no interpolated vehicle trajectory;
- capture-session boundaries preserved;
- synthetic inter-session gaps disclosed;
- owner health remains blocked.

Stored session review, Signal Explorer, Candidate Inbox, and Replay Lab remain read-only and accessible when motion is unknown or moving. Mutating live capture controls, protocol plans, test-run lifecycle controls, and event-marker entry remain disabled unless live gateway health deterministically reports `PARKED`.

## Safety and authority

- Protocol probing still requires explicit owner approval, deterministic `PARKED`, current health, listen-only agreement, the required gateway capability, and a signed semantic plan.
- The UI exposes no arbitrary CAN transmit surface.
- Marker entry records human ground truth; it does not promote a signal.
- AI can consume the evidence package and recommend another test, but cannot activate an experiment or alter registry authority.
- Capture, gateway, storage, or analysis failure is evidence-system degradation, never vehicle health.

## Manual acceptance pass

1. With no gateway, open every Discovery destination. All source-dependent values must read unavailable or explain the missing evidence; no sample values may appear.
2. Connect a VHOS gateway without vehicle traffic. Gateway may read connected, while vehicle bus and markers remain unavailable.
3. Start passive recording, confirm live health reports `PARKED`, and wait for a real observation. `Begin Session` becomes enabled while marker buttons remain disabled.
4. Begin a test run draft. Tap two different markers, then end the run. Confirm each row retains the canonical kind, label, capture session, and source sequence after relaunch.
5. Synchronize retained history. Confirm stored capture sessions appear without changing authority status.
6. Open a research candidate. Confirm it reads `EXPERIMENTAL CANDIDATE`, includes its validation gate, and opens playback.
7. Verify no screen labels a cross-model candidate Vehicle Validated or Promoted.
8. Change live motion to `UNKNOWN` or `MOVING`. Confirm tests, scans, capture mutation, and markers fail closed while stored review and replay remain available.
