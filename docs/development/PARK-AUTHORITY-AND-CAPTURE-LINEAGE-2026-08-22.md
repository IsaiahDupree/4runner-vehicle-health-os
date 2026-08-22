# Park authority and capture-lineage incident

Date: 2026-08-22
Status: returned vehicle evidence preserved; root causes identified; iOS 0.3.21 (28) adds the
capture-lineage correction and a bounded, evidence-only selector bootstrap; deterministic Park
authority remains open until a target-vehicle signal is independently corroborated and promoted

## Outcome

The vehicle run did capture useful CAN evidence. The app did not know the 4Runner was in Park
because the current MrDIY gateway firmware reports `vehicle_motion: UNKNOWN` deliberately. No
validated gear-selector or independent Park signal is currently part of the active Vehicle Signal
Pack.

This is correct fail-closed behavior. Stationary traffic, zero speed, an accelerometer at rest, or a
user saying “the shifter is in Park” must not silently become deterministic Park authority. Park is
a safety gate for discovery mutations, diagnostic reads, and OTA. A false positive is more harmful
than an honest unknown.

The correction is therefore two-part:

1. preserve and accept the evidence that actually belongs to the active gateway capture session;
2. provide one narrowly scoped selector-bootstrap procedure that can collect P/R/N/D/P evidence
   while motion remains `UNKNOWN`.

The bootstrap cannot unlock OTA, active diagnostics, arbitrary experiments, or normal parked-only
controls.

## Preserved evidence

The device container from the returned run is retained locally at:

`build/device-data/2026-08-22-park-authority-incident`

That path is intentionally ignored by Git because it contains device-private field evidence. The
portable logical-frame stream contains 4,443 records:

| Logical message type | Meaning | Count |
| --- | --- | ---: |
| 1 | Gateway handshakes | 103 |
| 2 | Raw CAN observations | 1,650 |
| 4 | Gateway health | 2,201 |
| 12 | Capture indexes | 93 |
| 13 | Capture-history chunks | 396 |

The portable stream SHA-256 is
`70851c530ceed2ffbb5c348740e59017d1c812d833901729bb1993d928864984`.
The latest BLE connection trace SHA-256 is
`39248c1088f9a6b5599e588cdb66c70e44e9ed1876487e1c172d7a1d810e2987`.

The latest returned trace reported approximately 181,287 observed vehicle-bus frames, 12,474
retained sampled records, and 1,469 cumulative TWAI receive-missed/overrun events. It reported no
bus error or bus-off event. All 2,201 decoded health messages reported motion as `UNKNOWN`; the app
did not lose a valid `PARKED` assertion.

Those counters establish acquisition activity and quality. They do not establish the selector
position.

### Selector-shaped candidate in the returned capture

The newest raw-CAN session (`122561546`) contains 636 live observations across approximately
318.760 seconds. Within that session, the already researched cross-model selector candidate
`0x2D0 byte[2] & 0x7F` changed through this retained sequence:

| Elapsed time | Source sequence | Raw candidate code |
| ---: | ---: | ---: |
| 3.015 s | 10,083 | 8 |
| 201.841 s | 116,093 | 2 |
| 209.371 s | 120,118 | 0 |
| 209.878 s | 120,386 | 8 |
| 214.890 s | 123,058 | 2 |
| 246.486 s | 139,888 | 8 |
| 274.108 s | 154,601 | 16 |
| 276.115 s | 155,679 | 2 |
| 283.633 s | 159,672 | 8 |

This is useful selector-shaped activity, not a decoded gear position. The session contains no
synchronized P/R/N/D event markers, so none of codes `0`, `2`, `8`, or `16` may be named `PARK`,
`REVERSE`, `NEUTRAL`, or `DRIVE`. Sparse live observations may also omit intermediate transitions.
The ordered selector bootstrap below exists to bind those raw codes to owner-observed positions and
then test repeatability before any canonical signal is promoted.

## Root cause 1: no Park authority source

The current firmware target publishes a literal `UNKNOWN` vehicle-motion value. The previous IMU
stationarity helper is not compiled into this MrDIY CAN-shield target, and it would not be an
acceptable substitute anyway: stationary is not synonymous with transmission Park.

The required authority chain is:

`raw selector observation → candidate field → repeated controlled tests → independent reference → golden replay → promoted canonical signal → current Park assertion`

Until that chain exists, the correct production value is `UNKNOWN`.

## Root cause 2: capture session identity was discarded on iPhone

The deployed gateway health contract uses the JSON field `capture_session_id`. Swift's
`convertFromSnakeCase` strategy maps that spelling to `captureSessionId`, while the synthesized
property is named `captureSessionID`. Without an explicit coding key, the value decoded as `nil`.

That defect did not create the missing Park state, but it broke the evidence lineage used to admit
returned raw frames. Valid CAN observations could be rejected as stale or session-mismatched even
when their gateway and recorder session were correct.

iOS 0.3.21 (28) now defines explicit `GatewayHealth` coding keys and maps
`capture_session_id` to `captureSessionID`. A regression test decodes the deployed JSON spelling and
proves the expected session value is retained.

## Evidence-only selector bootstrap

The iPhone Discovery workspace now exposes exactly one exception while motion is unknown:

`discovery.transmission.selector-bootstrap`

It is allowed only when all of these facts are current and agree:

- the VHOS application contract is validated;
- the gateway identity is exact and stable;
- handshake, health, and raw observation all report listen-only operation;
- passive capture is advertised and active;
- gateway health and the latest raw observation are no older than five seconds;
- the health capture-session ID exactly matches the raw observation session;
- the canonical bootstrap template, revision, marker sequence, and capability list are unchanged;
- the gateway reports motion as `UNKNOWN`, never `MOVING`.

The procedure requires level ground, wheels chocked, parking brake applied, engine off, ignition on,
and foot brake held. It records these markers in exact order:

1. Safety setup confirmed
2. Park
3. Reverse
4. Neutral
5. Drive
6. Park (return)

The result is experimental evidence only. It does not mutate gateway motion, manufacture a Park
signal, satisfy the independent-corroboration gate, or authorize a second procedure.
Markers are accepted only one time in the exact canonical order above. The generic event button is
not available in this workflow, and the run cannot end until the complete sequence is retained.

## Freshness and OTA boundary

Connection state is not vehicle-state authority. iOS now distinguishes current health from stale
health in System Status. Listen-only and motion rows stop passing when health has expired.

OTA now requires a current deterministic Park assertion both before pausing capture and again
immediately before preflight/network activation. A cached `PARKED` value cannot authorize an update.
The gateway-side OTA handler still needs an independently current Park proof before production OTA
can be considered end-to-end safe.

Periodic health must also continue during capture-history transfer. Otherwise an otherwise valid
motion assertion expires while the phone is downloading evidence. The firmware follow-up keeps a
small in-memory health heartbeat independent from filesystem history work; history transfer must
never own the authority clock.

## Next vehicle procedure

1. Open **Discovery** on iPhone.
2. Select **Run a Test → Transmission → Park / Selector Bootstrap**.
3. Apply the displayed physical safety setup exactly.
4. Perform and mark P → R → N → D → P.
5. Repeat the full procedure at least twice in separate capture sessions.
6. Run the same sequence with Toyota Techstream or another accepted independent selector/shift
   reference recording simultaneously.
7. Analyze per-bit and per-field transitions against the synchronized markers.
8. Reject fields with false activation, session ambiguity, missing freshness, or inconsistent
   behavior.
9. Golden-replay the proposed decoder before promoting any canonical selector or Park signal.

Only after those gates pass may `transmission.selector_position` or an equivalent canonical signal
produce deterministic Park authority for the normal product.

## Acceptance gates

- Returned raw observations are admitted only when gateway and capture-session lineage match.
- A reboot or recorder-session change clears live projections and rejects late frames.
- Unknown motion cannot start arbitrary discovery tests.
- Moving motion cannot start the selector bootstrap.
- Stale health or stale raw evidence cannot start or finish the bootstrap.
- The selector bootstrap cannot authorize OTA or diagnostics.
- Health remains current during bounded history transfer.
- A promoted Park signal requires repeated target-vehicle evidence, independent corroboration, and
  golden replay.
