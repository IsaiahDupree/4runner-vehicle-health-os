# iOS retained CAN playback lab

Status: implemented and build-verified in iOS `0.3.19 (26)`

## Outcome

The Evidence screen can now replay the signal-research charts built from passive CAN records that
are already retained on the iPhone. This is a historical evidence player, not a live vehicle
dashboard and not generated sample data.

The operator can:

- select any research field present in the retained evidence;
- play and pause on the retained monotonic timeline;
- scrub to an exact position;
- restart from the first capture-session boundary;
- select `0.25×`, `0.5×`, `1×`, `2×`, `5×`, `10×`, or `20×` speed;
- optionally loop at the end of the retained series;
- see a faint complete context trace and a bright progressive played trace using an exact-value
  step presentation;
- see an orange moving time cursor and the most recent exact retained-point marker;
- see dashed, labeled capture-session boundaries; and
- inspect the current raw field, candidate graph value, session, source sequence, retained point
  time, and time until the next plotted point.

The UI carries the explicit badge:

```text
HISTORICAL RETAINED EVIDENCE • NOT LIVE
```

The existing research authority badge remains visible:

```text
VALID RAW EVIDENCE • UNVERIFIED CROSS-MODEL CANDIDATE
```

## Authority and fidelity boundary

Playback consumes `PassiveCANResearchSeries.points`, which came from validated
`gateway.passive-can-observation@1.0.0` records carrying listen-only proof. It does not create a CAN
record, change a byte, interpolate a vehicle value, or write anything back to the evidence archive.

The cursor can move continuously between points, but the displayed raw and candidate values remain
the latest exact retained point at or before the cursor. The next exact point is exposed separately.
Both chart traces use a step presentation that holds the previous exact value; they do not draw a
linear trajectory between observations. That makes a sparse or sampled capture visibly sparse
instead of manufacturing a smooth physical measurement.

Candidate engineering units retain their orange cross-model warning. Playback cannot promote a
candidate to a validated Vehicle Signal Pack, owner health, finding, recommendation, service event,
component state, or lifecycle baseline.

## Timeline and session semantics

`PassiveCANPlaybackTimeline` validates and deterministically orders every plotted point by:

1. retained elapsed time;
2. capture-session ordinal;
3. gateway ID;
4. capture-session ID; and
5. source sequence.

Duplicate identities, non-finite values, non-finite cursors, invalid speed, invalid host time, and a
backward-moving host clock fail closed.

The transport accepts `ProcessInfo.processInfo.systemUptime` from the app, keeping playback speed
independent of wall-clock changes. Tests inject explicit monotonic timestamps so play, pause, scrub,
speed changes, loop counts, and end behavior are deterministic.

The research analyzer intentionally inserts a visible one-second separator between retained capture
sessions. Playback carries each session's exact all-observation capture start/end—not merely the
selected field's sampled endpoints—and reports when the cursor is inside that synthetic separator.
The chart uses a distinct line series for each session, so it never draws a vehicle-data line across
a session boundary.

The analyzer canonical-sorts equivalent evidence before sampling. Every selected-field session's
first and last exact points are mandatory plotted points. If the configured point budget cannot hold
those required endpoints, analysis fails closed instead of silently omitting a session boundary.
When the cursor enters a capture before the selected field's first retained sample, the UI explicitly
says it is awaiting that sample; any prior value remains labeled as the previous session's exact
retained point.

## Playback state machine

```text
                play
    PAUSED -----------------> PLAYING
       ^                         |
       | pause / begin scrub     | exact monotonic clock advance
       |                         v
       +--------------------- PLAYING
                                 |
                       end + stop-at-end
                                 v
                               ENDED
                                 |
                         replay / restart
                                 v
                               PLAYING

    end + loop -> start, increment completedLoops, remain PLAYING
```

Changing the selected field or source evidence SHA-256 constructs a new transport at the first exact
all-observation capture boundary represented by that series. Moving the app out of the active scene
pauses playback. Scrubbing pauses first and resumes only when playback was active before the gesture
and the cursor did not end at the final boundary.

## Rendering and performance boundary

The chart shows the exact transient-preserving point set produced by the research analyzer. Each
series is bounded to 480 plotted points; session endpoints and bucket minimum/maximum points are
retained rather than averaged. The chart's faint full trace supplies stable axes and context while
the bright prefix grows with playback. The canonical NDJSON archive remains complete and is not
rewritten or truncated by the player.

The app targets a 20 Hz transport refresh. This animates the time cursor while leaving vehicle values
stepwise at captured points. It is a visualization cadence, not a claim that the source CAN field was
sampled at 20 Hz.

## Accessibility

- Playback controls combine standard symbols with explicit VoiceOver labels.
- Play changes to Pause while active and to Replay at the end.
- The scrubber announces elapsed and total retained time.
- Loop announces on/off state.
- The chart is summarized as text with phase, session, source sequence, raw value, graph value, unit,
  and cursor time.
- Session state is conveyed with labels and dashed markers, not color alone.
- Playback does not depend on animation interpolation; the exact-point semantics remain usable with
  Reduce Motion.

## Automated acceptance

Eight playback tests use captured vehicle evidence rather than invented production values:

1. the played points are always an exact prefix of the retained research series;
2. speed, pause, and scrub calculations are deterministic;
3. stop-at-end exposes every real point and Replay restarts cleanly;
4. looping wraps at the exact duration without interpolating a value;
5. two tracked real sessions totaling 840 raw records expose ordered boundaries and the deliberate
   evidence gap;
6. all 5,176 tracked records across eight sessions preserve exact global capture bounds and every
   selected-field session endpoint even at a 16-point display budget;
7. shuffled and canonical orderings of the same over-cap evidence produce identical research series;
   and
8. invalid clock, speed, and overflow inputs fail closed.

The existing archive test also proves that a 256-record real capture can be offloaded, the in-memory
state discarded, the archive loaded in a fresh application session, deduplicated, reanalyzed, and
replayed from the same semantic evidence.

Run:

```bash
swift test --package-path ios/Core
xcodebuild \
  -project ios/VehicleHealthOS.xcodeproj \
  -scheme VehicleHealthOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Current verification result: 69 Swift tests pass, including the eight playback tests, and both the
complete iOS simulator build and signed iPhone-device build succeed.

## Remaining physical UX gate

The next iPhone field pass should replay the newest multi-session archive and verify touch targets,
scrubbing, 20× playback, looping, background pause, VoiceOver summaries, and chart readability in
portrait and landscape. That is a display acceptance step; it does not alter the evidence or signal
validation gates.
