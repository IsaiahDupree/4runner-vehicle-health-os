# iOS retained CAN research graphs and session-safe evidence reload

Status: implemented in iOS `0.3.18 (25)`

## Outcome

The iPhone can now close, relaunch, reload its retained passive-CAN NDJSON sessions, and rebuild the
same signal-research report without depending on in-memory BLE state. The Evidence screen plots
actual stored vehicle observations across capture sessions. It does not generate or substitute
sample values when evidence is missing.

Every chart carries this authority badge:

```text
VALID RAW EVIDENCE • UNVERIFIED CROSS-MODEL CANDIDATE
```

The feature is an engineering research surface. It cannot update owner health, findings,
maintenance, recommendations, component twins, or lifecycle baselines.

## Evidence archive boundary

`PassiveCANEvidenceArchive` is the shared load/offload contract for this surface. It:

- encodes deterministic, inspectable NDJSON;
- validates `gateway.passive-can-observation@1.0.0` on every read;
- requires the gateway's listen-only proof;
- rejects malformed identifiers, payload shape, data length, bitrate, duplicate identities, and
  conflicting bytes under one gateway/session/source-sequence identity;
- merges imports append-only and reports how many new records were admitted; and
- computes the SHA-256 over the exact canonical semantic archive used to produce the report.

The app reads every retained capture file through that validator. Files are merged oldest first,
deduplicated by stable observation identity, and bounded to the newest 50,000 records for the live
research surface. The underlying capture files remain the durable truth and are not rewritten by
analysis.

## Current research series

The analyzer is pinned to:

| Field | Value |
| --- | --- |
| Pack ID | `toyota.4runner.2005.passive-can-hypotheses` |
| Pack version | `0.4.0` |
| Pack SHA-256 | `6e2df8207e8977d613923a01f4bea7a16baba74a1869cce2ad0a83b56cf6ba32` |
| Authority | `ENGINEERING_RESEARCH_ONLY` |
| Owner health display | `false` |

The initial graph set is intentionally narrow:

| CAN field | Candidate meaning | Graph axis | Required validation |
| --- | --- | --- | --- |
| `0x2C4[0:16]` big-endian | engine speed | candidate RPM using the one pinned `×0.78125` transform | simultaneous J1979 PID `0x0C` or Techstream engine speed |
| `0x2C4 byte 3` | intake-air temperature | raw count | resolve conflicting cross-model formulas with PID `0x0F` or Techstream |
| `0x2D0[0:16]` big-endian | transmission turbine speed | candidate RPM using the one pinned `×0.390625` transform | Techstream input/turbine speed across a labeled drive |
| `0x2D0 byte 2 & 0x7F` | selector code | raw count | repeated P/R/N/D/manual markers |
| `0x2C1 byte 6` | accelerator-pedal position | candidate percent using the one pinned `×0.5` transform | PID `0x49` when supported or Techstream pedal position |
| `0x025[0:12]` signed | steering-wheel angle | raw signed count | Techstream center/left/right sweep and ignition-cycle repeat |
| `0x224 bytes 4–5 & 0x1FF` | brake pressure | raw count | released/light/medium/firm independent pressure reference |

Candidate engineering units are useful for planning an experiment, but the UI labels them
unverified. A plausible range is not proof. Conflicting definitions never receive a physical-unit
axis.

## Multi-session graph behavior

Each observation keeps gateway ID, capture session, source sequence, monotonic capture time, raw
field value, and candidate display value. Sessions are ordered by their retained ingestion time;
monotonic time is preserved within each session, and a visible one-second separator prevents one
session from being presented as continuous with the next. Chart downsampling retains each bucket's
minimum and maximum rather than taking an average that could hide a transient.

The Evidence screen shows:

- source archive SHA-256 and exact pack version;
- CAN identifier, candidate semantic, record/session/distinct-value counts;
- raw range regardless of whether a candidate transform exists;
- transformed range and transform ID only for a single non-conflicting pinned transform;
- number of pinned sources; and
- the exact independent validation gate.

## Automated acceptance

The Core test uses the checked-in 256-record slice from the real 2005 4Runner capture. It performs
this full application-session transition:

1. analyze the real retained observations;
2. offload all 256 records to canonical NDJSON;
3. discard the in-memory collection to represent a fresh app process;
4. decode and validate the archive;
5. import into an empty store and require 256 appended records;
6. import the same archive again and require zero appended records;
7. require the same semantic SHA-256; and
8. require the exact same research report before and after reload.

Additional tests require seven real-evidence series, verify the expected record counts and raw-only
boundaries, prove the embedded catalog hash matches the repository signal pack, and reject any
record without listen-only proof. No mocked or generated vehicle values are used.

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

## Next physical validation

The most valuable next vehicle session is one synchronized, labeled capture containing J1979 PID
`0x0C` or Techstream engine speed, stable pedal levels, a steering sweep, brake levels, and
P/R/N/D transitions on the same gateway-monotonic timeline. That evidence can validate or reject
candidate fields one at a time through a new versioned Vehicle Signal Pack; it must not silently
promote the current research catalog.
