# Passive CAN logging, Recent Logs, export, and replay

Status: implemented, physically exercised, and preserved as a reproducible offline corpus

## Outcome

The iPhone can recover passive CAN evidence captured while it was absent. A supported gateway
records bounded observations to its dedicated flash partition, advertises
`evidence.persistent-log`, and exposes a resumable encrypted-BLE index/chunk protocol. The app
automatically synchronizes those chunks into durable NDJSON files and makes them visible and
shareable from Evidence.

This design reduces the field loop from “stay at the car while every analysis runs” to “capture a
controlled action sequence once, then replay and analyze it repeatedly at the desk.”

The current immutable desk-development corpus contains eight real sessions and 5,176 retained
observations. See
[Real CAN replay and offline load testing](REAL-CAN-REPLAY-AND-LOAD-TESTING-2026-08-18.md) for
its hashes, load/fault matrix, exact CLI, and Android historical-replay UX.

The firmware-side record format, sampling policy, capacity, safety analysis, transfer messages,
and one-trip procedure are specified in the firmware repository's
`targets/mrdiy-esp32-v13/docs/PASSIVE-CAN-FLIGHT-RECORDER.md`.

## iOS state flow

1. A versioned gateway handshake is decoded and validated.
2. The app checks for `evidence.persistent-log`; older firmware remains compatible and receives no
   unknown capture request.
3. The app sends message type 11 operation `index` over the encrypted reliable command
   characteristic.
4. It decodes the type 12 index and compares each gateway segment with local session storage.
5. Previous is queued before current to reduce overwrite risk.
6. The app requests a maximum of one chunk at a time at its exact record offset.
7. The type 13 outer frame CRC and every 36-byte record CRC32C are validated.
8. Fresh records are appended atomically to a gateway/session NDJSON file.
9. The next offset is requested only after local persistence succeeds.
10. On reconnect or app relaunch, the local record count becomes the resume offset.

An unexpected slot, session, or offset is rejected. An empty chunk without an end marker is also
rejected so a malformed gateway cannot create an infinite sync loop.

## Local truth and deduplication

Files live under the app's Application Support directory, not Temporary, and therefore survive
normal app restarts and device reboots. The hierarchy is:

```text
VHOS/PassiveCAN/<gateway-id>/<session-id>.ndjson
```

The identity tuple is:

```text
gateway_id + session_id + source_sequence
```

The store reads existing lines when a session is first used, builds the sequence set, and never
appends a duplicate. A share operation creates a temporary combined
`passive-can-recent-logs.ndjson`; it does not move or delete the durable source files.

## Export contract

Every NDJSON line is a `gateway.passive-can-observation` version `1.0.0` object containing:

- gateway and capture-session identity;
- source receive sequence;
- gateway monotonic observation time;
- bitrate;
- arbitration identifier and standard/extended flag;
- remote-request and enforced-listen-only flags;
- DLC and eight bounded payload bytes;
- evidence source (`gateway-flash` for durable sync, `ble-live` for preview decoding);
- iPhone ingest time.

The export does not claim a vehicle ID, decoded signal, PID, diagnostic meaning, unit, equation,
or health conclusion. A later replay/analysis stage must retain the observation identity in every
proposal so a reviewer can resolve the claim back to exact bytes.

## Evidence UI

The Evidence tab shows:

- whether gateway recording is active;
- observed versus retained frame counts;
- total records in current and previous on-device segments;
- free capture storage;
- queue drops and storage write failures;
- synchronization progress;
- recent durable iPhone sessions and sizes;
- latest sampled live identifier, bytes, bitrate, and source sequence;
- refresh/sync and share actions.

Sampling and failures are never hidden. The latest live observation is explicitly labeled a
preview; it is not used as a substitute for the flash-backed session.

## Operational workflow

Before a car visit, install matching app/firmware builds and confirm the persistent-log
capability, recording state, free storage, zero queue drops, and zero storage failures. At the
vehicle, perform one controlled action at a time with spacing between actions. Active diagnostic
experiments remain unavailable until their separate signed-plan, allowlist, deterministic PARKED,
idle-capture, and explicit-approval gates pass.

After the visit, the gateway can be powered safely at the desk. Reconnect the app over BLE, wait
for “Recent gateway logs are synchronized on this iPhone,” then share the NDJSON. No SoftAP,
internet, or vehicle connection is required to retrieve already captured records.

## Verification

Automated checks cover:

- VHOS framing and stream chunking;
- outer CRC rejection;
- stored-record inner CRC rejection;
- capture chunk offsets, session identity, frame flags, identifiers, bytes, and lineage;
- backward-compatible decoding of health payloads that do not include capture fields.

They now also cover the full checked-in real corpus through both deployed wire paths, exact
cross-language fixtures in Python/Swift/Kotlin, repeated full-speed load, hostile notification
fragmentation, dropped fragments, CRC corruption, inserted noise, mid-frame disconnect, stream
resynchronization, and Android replay cancellation. Replay failures are reported as transport
quality; they cannot become vehicle-health findings.

```bash
.venv/bin/vhos validate-can-replay-corpus test-replay/real-can-2026-08-18
.venv/bin/vhos replay-can-corpus test-replay/real-can-2026-08-18 \
  --mode history --repeat 20 --fault clean
```

Release acceptance additionally requires a physical iPhone and gateway run that proves:

- automatic index request;
- nonzero current-record growth with real vehicle traffic;
- successful previous/current sync;
- resume after BLE interruption;
- no duplicate NDJSON records;
- recent sessions survive app termination/relaunch;
- exported lines parse independently;
- Wi-Fi remains disabled and no vehicle-bus transmit path exists.

## Next development step

Add owner-created capture markers to both gateway storage and the exported stream. A marker should
carry an owner label, iPhone wall time, gateway monotonic correlation, and exact surrounding
source-sequence range. A desktop replay tool can then rank identifiers/bytes against those actions
and emit evidence-linked signal hypotheses. Hypotheses must remain proposals until independently
validated and versioned into a Vehicle Signal Pack.

The first vehicle export has now been preserved as a separate evidence-bounded engineering record:
[Passive CAN capture analysis — 2026-08-17](PASSIVE-CAN-CAPTURE-ANALYSIS-2026-08-17.md). It records
the reported frame-rate/coverage/checksum metrics, signal candidates, why the sampled dev.11 export
is not lossless, and the agreed Lossless Capture V2 -> Experiment Mode -> automatic discovery ->
allowlisted diagnostics sequence. Candidate Toyota identifiers and scales in that note are not
production decoders.
