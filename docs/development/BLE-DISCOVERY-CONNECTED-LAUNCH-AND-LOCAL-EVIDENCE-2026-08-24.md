# BLE discovery, connected launch, and local evidence-only capture

Date: 2026-08-24

## Outcome

This change separates four independent concerns that were previously presented as one blocked
workflow:

1. Android must be able to discover a VHOS gateway on head-unit Bluetooth stacks that reject an
   Android service-UUID scan filter.
2. iOS must be able to open while CoreBluetooth already owns or restores a gateway connection
   without cancel/rebuild churn, UI starvation, or a crash.
3. A missing deterministic `PARKED` result must not prevent collection and analysis of passive
   selector evidence needed to discover that very result.
4. A Debug build must provide an explicitly labeled Evidence Lab path for collecting that same
   selector evidence when commissioning telemetry is incomplete, without weakening the Release
   policy or manufacturing vehicle authority.

The third item is implemented as **local evidence-only mode**, not a Park override. It never changes
`hasCurrentParkedAuthority` and cannot authorize a gateway or vehicle mutation.

The fourth item is implemented as **Debug Evidence Lab**, a separate, persisted acquisition scope.
It relaxes selected test-entry checks only for the canonical selector procedure. It does not relax
the live listen-only evidence requirement and is never equivalent to local evidence-only or Parked
authority.

## Android discovery recovery

Android still begins with the most specific path:

1. reconnect a previously validated gateway by stable Bluetooth address;
2. run a bounded scan using the exact VHOS service UUID;
3. if the vendor Bluetooth stack returns scan error 3, 4, or 5, or the filtered window is empty,
   retry with no platform UUID filter;
4. qualify every fallback result in the app and admit only an advertisement containing the exact
   VHOS service UUID or an approved VHOS OBD/A-C name;
5. require the normal encrypted GATT service, CRC, handshake identity, protocol, device role, and
   capability checks before a device becomes connected.

Removing the vendor OS scan filter does not make arbitrary Bluetooth devices acceptable.

The deployed gateway currently permits one BLE owner. If the iPhone owns it, the gateway may stop
advertising and Android cannot discover it. Use **Release for Android** on the iPhone System Status
screen, then **Start / Reacquire** on Android. Releasing cancels automatic iPhone reconnect until
the owner presses Connect again. This is transport ownership, not a permission failure, and neither
app silently steals the other app's link.

## iOS connected-launch recovery

A cold app launch can receive CoreBluetooth restoration callbacks before append-only evidence
persistence is ready. The previous lifecycle retired/cancelled that inherited link immediately,
then rebuilt the central manager while launch verification and UI rendering were in progress.
That created repeat connection negotiation, restoration cleanup watchdogs, and re-entrant state
changes that could look like a freeze or terminate the app.

The corrected lifecycle defers adoption until evidence persistence is ready without cancelling the
restored peripheral. It then adopts the connected/connecting peripheral once, under one fresh link
session and delegate. Evidence authority remains fail-closed during the defer interval.

## Local evidence-only selector workflow

Use this when the gateway is streaming passive CAN but strict Discovery readiness cannot be met
because motion is unknown, recorder telemetry is unavailable/stale, flash is low, the recorder
write path reports a fault, or the health capture session cannot be matched.

1. Open **Discovery**.
2. Open **Run a Test**.
3. Choose **Park / Selector Bootstrap**.
4. Tap **Use local evidence-only mode**.
5. Confirm level ground, wheels chocked, parking brake set, engine off, ignition on, and foot brake
   held.
6. Begin the session and record the required P/R/N/D markers in order, including each dwell.
7. End or abort the session. The app retains and queues the local append-only frames and markers
   but sends no capture pause/offload command, even if strict gateway health arrived after the run
   began.
8. Use **Evidence**, **Replay Lab**, and **Candidate Inbox** to analyze experimental mappings.
   Candidate registration remains visibly unavailable until the exact retained archive, manifest,
   vehicle profile, and gateway provenance have been finalized; recover the gateway archive later
   if ordinary recorder health becomes available.

The selected acquisition scope and the owner's safety acknowledgement are sealed into the
append-only test-run record. A local-only run therefore remains local-only across navigation,
reconnection, relaunch, or the later arrival of strict PARKED/recorder health; it can never be
silently upgraded into a gateway-commanding run.

The local scope is available only for the Core-owned canonical selector template and requires:

- an accepted `VHOS_CONNECTED` application contract;
- a fresh CAN observation no more than five seconds old;
- handshake and observation both reporting listen-only;
- exact handshake/observation gateway identity;
- the passive-capture capability;
- readable append-only test-run and marker ledgers;
- no available health report asserting `MOVING`.

It may bypass only:

- deterministic Park authority;
- gateway health freshness/availability;
- recorder-active status;
- recorder drop/write-failure status;
- recorder storage headroom;
- health-to-observation capture-session matching.

That distinction is preserved in the UI as `LOCAL ONLY`, never `PARKED`.

## Debug Evidence Lab

Debug Evidence Lab is intended for development sessions where the ESP32 is producing real passive
CAN observations but the rest of the commissioning contract is incomplete. It is not a simulator,
an unrestricted engineering console, a Park override, or an OTA override.

### Operator workflow

The control exists only in a Debug build:

1. Physically secure the vehicle on level ground: chock the wheels, set the parking brake, keep the
   engine off, turn the ignition on, and hold the foot brake while moving the selector.
2. Open **Discovery → Run a Test → Park / Selector Bootstrap**.
3. In the red **Development gate override** card, tap **Use Debug Evidence Lab**.
4. Read the destructive confirmation and tap **Arm Debug Evidence Lab**.
5. Begin within five minutes. The confirmation tap's actual timestamp arms exactly one run and is
   cleared when that immutable run starts; the app cannot synthesize acknowledgement at Begin.
6. Verify that **Fresh verified listen-only CAN timeline** passes. Failed relaxed-entry rows remain
   visible as diagnostics; the app does not relabel them as passing.
7. Tap **Begin Session**, then record the required safety, Park, Reverse, Neutral, Drive, and return-
   to-Park markers in order. Hold each selector position for the displayed eight-second gateway-
   monotonic dwell.
8. End the session only after the complete marker sequence and final dwell. Abort remains available
   and retains the append-only draft locally.

The active run is visibly labeled `DEBUG / UNVERIFIED`, `local only`, `no PARKED claim`, and
`no gateway command`.

### Entry gates deliberately relaxed

For this one exact canonical template, Debug Evidence Lab may begin without:

- the app connection state being `VHOS_CONNECTED`;
- a handshake being available;
- the passive-capture capability being advertised by an available handshake;
- a gateway health report or a fresh gateway health report;
- deterministic Park authority;
- `capture_active=true` recorder telemetry;
- zero recorder queue drops or storage-write failures;
- 128 KiB of reported recorder storage headroom; or
- a health-report capture-session ID matching the latest observation session.

These checks remain visible in Evidence readiness. The override changes whether the listed checks
block this app-local Debug run; it does not alter, suppress, or rewrite their reported state.

### Invariants never relaxed

Debug Evidence Lab still fails closed unless all of the following are true:

- the test is byte-for-byte the Core-owned canonical `Park / Selector Bootstrap` template
  `discovery.transmission.selector-bootstrap` version `1.1.0`;
- a real `PassiveCANObservation` is present, passes the canonical archive contract validator, and
  was accepted by the app no more than five seconds ago (an absent, stale, or future-aged
  observation is rejected);
- the observation reports listen-only mode;
- an available health report does not report non-listen-only mode or `MOVING`;
- an available handshake does not report non-listen-only mode and its gateway identity matches the
  observation gateway identity;
- both append-only Discovery ledgers are readable;
- the canonical test remains supported by the iPhone interactive runner;
- the user explicitly acknowledges the per-run physical safety setup, and that real confirmation
  timestamp precedes Begin by no more than five minutes;
- every marker remains bound to the exact gateway ID and recorder session sealed at Begin;
- the canonical markers are appended in order, with every physical selector dwell measured from
  the gateway monotonic clock; and
- End receives a new qualifying observation, the marker sequence is complete, and the final dwell
  is complete.

No simulated value, cached status tile, iPhone wall clock, or manually asserted Park value can
satisfy those conditions.

### Permanent provenance and continuation rules

Beginning the run seals `DEVELOPMENT_EVIDENCE_LAB` into the append-only test-run draft together
with the owner acknowledgement, gateway ID, gateway session ID, source sequence, and monotonic
time. Marker and End mutations require the policy to issue that exact scope again. A later healthy
handshake, recorder report, or deterministic `PARKED` result cannot upgrade the run to another
authority or give it gateway-command permission.

When an ended draft is finalized against an exact retained archive and manifest, the terminal run
and experimental candidate provenance retain the same acquisition authority. Candidate evidence
also carries the explicit reference
`capture-acquisition-authority:DEVELOPMENT_EVIDENCE_LAB`. It remains a Candidate with
`promotion_allowed=false`; the Debug label cannot disappear behind an archive hash.

### Release behavior

The button, confirmation, and policy issuance branch are compiled only into Debug builds. A Release
build cannot arm, begin, mark, continue, or end a `DEVELOPMENT_EVIDENCE_LAB` run and cannot silently
downgrade it to local evidence-only or upgrade it to Parked. The Codable authority value remains in
the shared contract so Release can decode, preserve, export, and validate already-ended evidence
and candidate provenance without losing its Debug/Unverified label. If Release encounters an
active Debug draft, it may only abort it locally; it cannot continue the experiment.

## Operations that remain impossible in app-local evidence modes

- signed or unsigned OTA installation;
- capture pause/resume/offload commands at session end or abort;
- J1979, ISO-TP, or Toyota-enhanced diagnostic requests;
- signed experiment-plan execution;
- arbitrary CAN transmission;
- Active Tests or actuator control;
- promotion of a candidate to Vehicle Validated or a production Vehicle Signal Pack;
- any claim that the vehicle is safe to service or physically parked.

This list applies to both `LOCAL_EVIDENCE_ONLY` and `DEVELOPMENT_EVIDENCE_LAB`. Command permission
uses a positive authority allowlist: only strict Parked and passive-selector-bootstrap authorities
can request gateway capture control. App-local scopes remain denied even if healthy gateway state
arrives before End or Abort.

The Firmware screen intentionally keeps its current Park, supply, compatibility, signature, A/B,
and rollback gates. It now directs selector-learning work to Discovery rather than implying that a
firmware install is the way to discover Park.

## Required regression coverage

- Local evidence requires an explicit per-run acknowledgement and the exact canonical template.
- Debug Evidence Lab is issued only in Debug, only for the exact canonical template, and is absent
  from Release UI and Release policy execution.
- Debug Evidence Lab may relax connection, handshake availability, capability advertisement,
  Park, recorder-health, storage, and session-match entry gates, while stale/missing/invalid or
  non-listen-only observations, explicit `MOVING`, conflicting available identities, and unreadable
  ledgers still deny it.
- Debug Evidence Lab markers remain bound to the exact begin-session lineage and require the real
  gateway-monotonic ordering and dwell rules.
- A persisted Debug run can continue only under the exact same Debug authority; it cannot become
  local evidence-only, passive bootstrap, or Parked.
- End and Abort of a Debug run never emit gateway capture commands, and Release can only locally
  abort an active Debug draft.
- Finalized manifests and experimental candidates preserve `DEVELOPMENT_EVIDENCE_LAB`; candidate
  registration does not grant validation or promotion authority.
- The acquisition scope survives navigation/relaunch and a local-only run never emits a gateway
  command even if strict authority becomes available later.
- Default strict authority remains unchanged.
- `MOVING`, stale/missing observation, wrong gateway, non-listen-only transport, missing passive
  capability, and disconnected state deny local evidence.
- Arbitrary Discovery templates cannot request the local scope.
- Ending or aborting local evidence appends and queues locally and performs no gateway command,
  even after a matching healthy recorder session reappears.
- Firmware preflight continues to reject unknown/non-Parked motion.
- Android compatibility fallback admits only VHOS advertisements and still requires the full
  handshake contract.
- iOS connected launch adopts one restored peripheral without cancellation/rebuild churn.

## Evidence semantics

App-local evidence can support an `EXPERIMENTAL_CANDIDATE`. It is useful for correlation, graphing,
replay, and proposing the next controlled test. It is not independent corroboration. Debug Evidence
Lab adds an explicit `DEVELOPMENT_EVIDENCE_LAB` provenance fact but no authority. Promotion still
requires target-vehicle evidence, a reviewed decoder, independent comparison such as standard OBD
or Techstream, golden replay, and signed review under the versioned signal policy.
