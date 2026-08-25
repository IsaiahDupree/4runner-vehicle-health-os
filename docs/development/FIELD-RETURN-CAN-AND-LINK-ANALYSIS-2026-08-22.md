# Field-return CAN and sustained-link analysis

Date: 2026-08-22
Gateway: `esp32-9454c5b08d14` / `VHOS-4R-OBD-B08D14`
Status: returned evidence preserved and validated; one selector-bootstrap run recovered; no
selector signal is promoted; development safeguards are implemented but field validation,
recorder capacity, and sustained-link failure remain open

## Executive result

The returned iPhone contains useful new evidence, but the new vehicle session was not copied into
the normal `VHOS/PassiveCAN` store before the phone returned. It was recovered from the append-only
portable logical-frame ledger instead.

A second read-only device copy at `13:51` confirmed that all eight durable PassiveCAN sessions and
the portable-ledger SHA-256 remain byte-for-byte preserved. It also added one later BLE restoration
trace from app `0.3.22` build `29`; no app replacement occurred before either copy.

The recovered data proves all of the following:

- the gateway was receiving real standard 11-bit CAN at 500 kbit/s in listen-only mode;
- the iPhone completed the six required selector-bootstrap markers in the correct order;
- `0x2D0 byte[2] & 0x7F` repeated code `8` in both Park observations, code `2` near Reverse, and code
  `16` in Drive;
- the same code `8` also appeared near Neutral, so this field does **not** yet distinguish Park from
  Neutral and cannot supply deterministic Park authority;
- the recorder was already reporting persistence failures and low storage when the test began;
- the BLE application contract repeatedly completed quickly and correctly, then later stopped
  receiving health notifications before CoreBluetooth reported `connectionTimeout`;
- the two latest BLE timeouts did not coincide with a gateway reboot: the gateway capture-session
  identity and cumulative counters continued across the phone disconnects.

The present bottleneck is therefore evidence acquisition and retention quality, not a lack of CAN
traffic. The current development tree now refuses Discovery when the recorder reports queue drops,
write failures, or less than 128 KiB free; initiates a pause/download/resume transfer after an
immutable `ENDED` transition; and makes portable CAN recoverable in iOS research/export and desktop
tooling. The correct next sequence is to install and field-validate those safeguards on a fresh
recorder session, exercise the enforced eight-second selector dwell, bind the downloaded archive
manifest to the ended run, and collect an independent selector reference during repeated P/R/N/D/P
runs.

## Preserved source snapshot

The read-only device-container copy is retained at:

`build/device-data/2026-08-22-field-return-123951`

This path is intentionally ignored by Git because it contains device-private field evidence. The
snapshot contains 21 files and approximately 8.2 MB. Every one of its 20 NDJSON files parsed as
valid line-delimited JSON before analysis. The app was not relaunched or replaced before this copy
was taken.

The principal evidence hashes are:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `VHOSPortableFrames/v1/logical-frames.ndjson` | 5,826,995 | `cacf021b386de8c96fad8e09d9fafa3a50cfdf5f75d392e14719994fb75158ff` |
| `VHOSDiscoveryEvidence/v1/capture-bindings.ndjson` | 221 | `4c0d483d34abfe2fd153dfe506165e1be5e892561b78d8a871b9f13e1a1ffe35` |
| `VHOSDiscoveryEvidence/v1/test-run-drafts.ndjson` | 1,898 | `24ed02616cfc6c369a952df089c8f60398b7ee693b064c74bcfab057cdff0185` |
| `VHOSDiscoveryEvidence/v1/event-markers.ndjson` | 4,614 | `d360e4682ee4c2ead7dfdee261bb9e379c88990391de1aad3bdc5fa0dd14c802` |
| Latest BLE trace segment, `...1787416460598-00D78902-000.ndjson` | 32,728 | `4cd752748ef12a26e964d1dbe6222bc8dbcea214716eaaa95fb9aa86e30d083e` |

These hashes identify the local evidence used for this report. Derived reports must remain
reproducible from these files; they do not replace the source bytes.

The repeatable copy-before-install, recovery-analysis, install, and post-install verification
procedure is documented in
[iPhone field-return evidence runbook](IPHONE-FIELD-RETURN-EVIDENCE-RUNBOOK.md).

The later confirmation copy is retained at
`build/device-data/2026-08-22-iphone-return-latest`. It contains 20 files and approximately 8.1 MB.
The durable PassiveCAN files, Discovery ledgers, and portable ledger have the same hashes listed
above. The additional BLE trace is
`ble-connection-1787417960235-D91CBDB5-000.ndjson`, 11 records, SHA-256
`4483962fac7f76935c2102fea654cc8b6c36ea9f0b0af5039cb1c2d12701f224`.

After those read-only copies succeeded, iOS app `0.3.23` build `30` was installed over the existing
application and launched. A third read-only container copy is retained at
`build/device-data/2026-08-22-post-install-verification`. It contains the same 20 files. The
portable ledger, test-run ledger, and marker ledger still hash respectively to
`cacf021b386de8c96fad8e09d9fafa3a50cfdf5f75d392e14719994fb75158ff`,
`24ed02616cfc6c369a952df089c8f60398b7ee693b064c74bcfab057cdff0185`, and
`d360e4682ee4c2ead7dfdee261bb9e379c88990391de1aad3bdc5fa0dd14c802`. This proves that the
in-place application upgrade preserved the returned evidence bytes; it does not promote the old
selector run or repair its sparse recorder coverage.

A fourth read-only copy taken after the next iPhone return is retained at
`build/device-data/2026-08-22-iphone-return-142220`. It contains 20 files and 8,212 KiB. The
portable-frame ledger, three Discovery ledgers, and eight durable PassiveCAN sessions are still
byte-identical to the hashes above, so this return added no new durable or portable CAN evidence.
The copy did add BLE trace
`ble-connection-1787421403253-C0CF04F3-000.ndjson`, 193,158 bytes, SHA-256
`537a3b072d095d4c67a404368ab3e1a10bebc5f90fa6da66bd067f29f93fc694`.

That trace contains 453 records, including 432 `STALE_SCAN_DISCOVERY_IGNORED` callbacks in about
4.1 seconds while CoreBluetooth retired an inherited connection and rebuilt the central manager.
The cleanup then attempted the known gateway, reached the 12-second `CONNECT_TIMEOUT`, and fell
back to service-filtered scanning without observing another advertisement. This is a host callback
storm, not CAN evidence and not proof that the gateway rebooted. Build 31 coalesces these callbacks
to bounded first/checkpoint/final-summary evidence and explicitly stops scanning during restored
link cleanup so logging pressure cannot amplify reconnection work.

The recovery command was rerun directly against that fourth snapshot. It reproduced all 926
session-`3025357416` records with NDJSON SHA-256
`911a1d459575a6cf7a194a0264ddac08491b52d28032af16c400c76261c06101`. The exact extraction
manifest has SHA-256 `248e3ee1f3f74d58a450cb0db690bac89ec9e8671ecc064a8edf617d86431d3f`.
The provenance-bound discovery report has SHA-256
`a5a5a19f0f3b4b2331ea7e11495167d5acfa875cbc17db778d9f66fd6a4fe1ca`; it cross-binds the
original phone ledger, extraction manifest, and recovered output while retaining
`source_classification: RECOVERED_PORTABLE_EVIDENCE` and `vehicle_claims_authorized: false`.

The recovered session was also projected into the replay input contract without changing its
source bytes or authority and pinned as corpus `2005-4runner-selector-session-3025357416`. Corpus
validation accepted all 926 records with semantic digest
`38a87d6286d2c74119671f400c041a7c5b4587e70e66aec8ce3d67041d26197d`. A 100-cycle clean soak then
delivered 92,600 wire frames, recovered the exact 926-record survivor set, accepted no stale epoch,
reported no sequence gap, and rejected 91,674 expected cross-cycle duplicate identities. All 15
deterministic transport scenarios passed: five healthy paths and ten deliberately degraded paths
covering duplicate frames/notifications, notification loss/reordering, payload corruption,
mid-frame reconnect, stale prior epochs, supervision timeout, queue overrun, and mixed interference.
The matrix remains labeled `HISTORICAL REPLAY • NOT LIVE`; it verifies deterministic framing and
recovery behavior, not RF coexistence or hardware buffer capacity. Its report SHA-256 is
`d0d781ceabf2e8d4e85071b282f14a008e8eae139a6d2a4575091da3e266f97a`.

## Durable store versus portable recovery

### Normal PassiveCAN store

The snapshot's normal `Application Support/VHOS/PassiveCAN` directory contains eight sessions and
5,176 records. A physical-record comparison against the already retained
`test-replay/real-can-2026-08-18` corpus found:

| Comparison | Records |
| --- | ---: |
| Existing corpus | 5,176 |
| Returned iPhone normal store | 5,176 |
| Exact identities with identical bytes | 5,176 |
| Novel returned records | 0 |
| Missing existing records | 0 |
| Same-identity payload conflicts | 0 |

Therefore the normal PassiveCAN directory does **not** contain the new August 22 recorder session.
That absence must not be described as “no data was captured.”

### Append-only portable frame ledger

The portable ledger contains 5,626 complete VHOS logical frames:

| Message type | Frames |
| --- | ---: |
| Gateway handshake | 105 |
| Live raw CAN | 2,576 |
| Gateway health | 2,453 |
| Capture index | 96 |
| Capture-history chunk | 396 |

All envelope hashes, VHOS header and payload CRCs, metadata, gateway roles, and listen-only claims
passed validation. Decoding both live raw-CAN frames and downloaded history chunks yielded 7,416
CAN observations before session selection and physical-identity reconciliation.

Three August 22 sessions are recoverable from this portable source:

| Gateway capture session | Reconciled records |
| ---: | ---: |
| `122561546` | 636 |
| `1376339377` | 14 |
| `3025357416` | 926 |

For duplicate physical CAN identities, an identical gateway-flash history record is preferred over
its BLE-live copy. A same-identity payload conflict is a hard error rather than a last-writer-wins
merge. Recovered output must display the provenance label:

`RECOVERED EVIDENCE • NOT LIVE`

The recovered session used below is `3025357416`: 926 valid standard 11-bit, 500 kbit/s,
listen-only records across 17 identifiers. Its source-sequence span is `12,211...315,978`, its
gateway-monotonic span is `23,084,823...2,391,637,861 us`, and its elapsed span is approximately
39 minutes 28.553 seconds. This is sparse portable sampling, not a lossless copy of every observed
bus frame.

## Discovery-run lineage

The canonical capture binding is:

| Field | Value |
| --- | --- |
| Capture ID | `capture_01M0N365HHK80GS0MJW4F54R81` |
| Gateway ID | `esp32-9454c5b08d14` |
| Gateway session | `3025357416` |
| Created | `2026-08-22T15:59:46Z` |

An earlier draft run in that capture was eventually marked `ABORTED`. The completed field run is:

| Field | Value |
| --- | --- |
| Test-run ID | `run_01M0N58XSR4C24P6257SGZCCT1` |
| Template | `discovery.transmission.selector-bootstrap` `1.0.0` |
| State | `ENDED` |
| Wall-clock interval | `2026-08-22T16:36:13Z...16:36:34Z` |
| Gateway monotonic interval | `2,329,380,860...2,350,458,778 us` |
| Source-sequence interval | `283,250...294,333` |

All six append-only marker records have the expected gateway and capture lineage and appear in the
required order:

| Order | Marker | Gateway monotonic time (us) | Nearest CAN sequence | Recorded at |
| ---: | --- | ---: | ---: | --- |
| 1 | Safety setup confirmed | 2,332,391,529 | 284,835 | `16:36:16Z` |
| 2 | Selector: Park | 2,334,396,860 | 285,887 | `16:36:18Z` |
| 3 | Selector: Reverse | 2,336,910,102 | 287,217 | `16:36:20Z` |
| 4 | Selector: Neutral | 2,338,915,217 | 288,270 | `16:36:22Z` |
| 5 | Selector: Drive | 2,342,422,640 | 290,117 | `16:36:26Z` |
| 6 | Selector: Park (return) | 2,344,939,202 | 291,444 | `16:36:29Z` |

The markers prove what the owner reported doing and when. They do not themselves prove which raw
field represents selector position.

## Selector-candidate result and authority boundary

Only 31 portable live-CAN observations fall in the completed test window:

| CAN ID | Samples |
| --- | ---: |
| `0x020` | 14 |
| `0x022` | 3 |
| `0x025` | 3 |
| `0x224` | 3 |
| `0x2C1` | 1 |
| `0x2C4` | 1 |
| `0x2D0` | 5 |
| `0x2D2` | 1 |

The cross-model selector candidate is `0x2D0 byte[2] & 0x7F`. Joining the sparse observations to
the synchronized markers produces:

| Labeled state | Match position | Candidate code | Representative `0x2D0` payload prefix |
| --- | --- | ---: | --- |
| Pre-test | preceding sample | 8 | `07 18 08 ...` |
| Park | exact marker sample | 8 | `07 08 08 ...` |
| Reverse | nearest sample, about +0.500 s | 2 | `05 F3 02 ...` |
| Neutral | nearest sample, about +1.001 s | 8 | `06 9F 08 ...` |
| Drive | exact and about +0.508 s samples | 16 | `00 00 10 ...` |
| Park return | nearest sample, about +3.510 s | 8 | `07 0A 08 ...` |

### What may be said

- Code `8` repeated in both labeled Park observations.
- Code `2` appeared close to Reverse in this run.
- Code `16` appeared at Drive in this run.
- The field is selector-shaped and is a high-value target for another controlled experiment.

### What may not be said

- Code `8` is not established as Park because it also appeared near labeled Neutral.
- No code-to-gear enum is validated from one sparse session.
- Neither the marker nor this field may change gateway motion from `UNKNOWN` to `PARKED`.
- This result cannot authorize OTA, diagnostics, owner health conclusions, or a lifecycle baseline.

The correct authority state remains **experimental target evidence only**. Promotion still requires
repeatability in separate target-vehicle sessions, an independent accepted selector reference, a
defined decoder/range/freshness rule, and golden replay. See
[Park authority and capture lineage](PARK-AUTHORITY-AND-CAPTURE-LINEAGE-2026-08-22.md).

## Gateway acquisition and storage health

Every one of the 457 decoded August 22 health frames reported `vehicle_motion: UNKNOWN`. No valid
`PARKED` assertion was lost in iOS.

Across session `3025357416`, gateway health changed as follows:

| Observation | Received frames | TWAI missed/overrun | Bus errors | Bus-off | Retained | Suppressed | Write failures | Free storage |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| First, `15:57:47Z` | 12,214 | 90 | 0 | 0 | 839 | 11,362 | 0 | 411,305 B |
| Last, `16:37:31Z` | 315,982 | 7,316 | 30 | 0 | 22,119 | 293,494 | 369 | 3 B |

Observer-drop and bus-off counters remained zero. This does not make the capture lossless: TWAI
receive-missed/overrun events increased by 7,226 and persistent-write failures increased from zero
to 369 while storage fell to three bytes.

The capture-index progression shows when persistence degraded:

| Capture-index time | Current-session records | Free storage | Write failures |
| --- | ---: | ---: | ---: |
| `15:57:47Z` | 832 | 411,138 B | 0 |
| `15:59:27Z` | 4,512 | 277,606 B | 0 |
| `16:36:02Z` | 10,656 | 80,571 B | 286 |

The completed selector test therefore began after the recorder had already reported write
failures:

| Test point | Received | TWAI missed/overrun | Retained | Write failures | Free storage |
| --- | ---: | ---: | ---: | ---: | ---: |
| Run start | 283,054 | 6,611 | 19,878 | 297 | 67,791 B |
| Park | — | 6,680 | 20,102 | 304 | 59,727 B |
| Reverse | — | 6,693 | — | 306 | — |
| Neutral | — | 6,718 | — | 309 | — |
| Drive | — | 6,758 | — | 313 | — |
| Park return | — | 6,783 | — | 316 | 47,055 B |
| Run end | — | 6,857 | 20,673 | 323 | 39,171 B |

The app's previous readiness check accepted a fresh listen-only timeline but did not reject a
recorder already reporting storage-write failures. That is an evidence-quality defect. It does not
invalidate the six marker records; it limits the completeness and authority of the CAN evidence
joined to them.

“Retained coverage” and “dropped CAN frames” must also remain distinct:

- suppression is the deliberate flash-sampling policy;
- write failure is failure to persist a selected record;
- TWAI missed/overrun is loss at the CAN receive path;
- portable BLE sampling is neither the full recorder nor proof of CAN loss.

## BLE sustained-link evidence

The eight retained BLE trace files contain 1,498 valid events with trace sequence
`5,164...6,661` and no missing flight-recorder sequence. Four physical links progressed through
service discovery, characteristic discovery, notification subscription, and a CRC-valid VHOS
handshake.

Handshake completion times were approximately `1,162 ms`, `600 ms`, `486 ms`, and `462 ms`. No
retained link failed at GATT service discovery, characteristic discovery, encrypted subscription,
handshake, CRC, or initial frame decode.

All four established links ultimately ended with CoreBluetooth
`CBError.connectionTimeout` (`code 6`):

| Link start/window | Established-link lifetime | Last health before disconnect |
| --- | ---: | ---: |
| `14:42:23` | 345.182 s | 19.408 s |
| `14:49:11` | 275.694 s | 179.930 s |
| `15:57:46` | 442.428 s | 22.444 s |
| `16:36:02` | 107.173 s | 18.039 s |

The first latest field segment delivered 210 health notifications over 419.063 seconds with a
median interval of 2.002 seconds and a maximum interval of 3.047 seconds. The health frame counter
advanced from 12,214 to 216,613. Vehicle traffic stopped advancing at `16:04:41.850`; unchanged
health arrived at `16:04:43.967` and `16:04:46.346`; then health notifications ceased before the
timeout at `16:05:08.790`.

The final field segment advanced the health counter from 277,791 to 315,982. Traffic stopped
advancing at `16:37:17.217`, unchanged health continued through `16:37:31.454`, and the phone
reported timeout at `16:37:49.493`. One logical-frame sequence discontinuity was recorded
(`expected 1,279`, `observed 1,280`).

The gateway did not reboot at either of these two latest disconnects. Both sides of the drop retain
capture session `3025357416`, and the gateway cumulative counters continue increasing after phone
reconnection. Reconnect was requested approximately 1.644 seconds and 1.154 seconds after the two
timeouts. One restored peripheral remained stuck in the connecting state until the app relaunched;
the separate restored-peripheral cleanup corrects that iOS recovery condition.

This evidence localizes the repeated failure **after** a healthy application handshake and a period
of sustained traffic. It supports investigating gateway BLE-task starvation, radio/power
conditions, or a peer that stops responding. It does not prove which of those is responsible, and
it does not support calling this an iPhone application crash. A gateway UART trace over the same
wall-clock interval is required to distinguish the remaining causes.

The `15:57` handshake reported raw ESP reset reason `7`, which the current mapping treats as a
watchdog-class reset, while the preceding `14:49` handshake reported power-on reason `1`. The
watchdog event occurred before the `15:57` link; it did not occur at either latest BLE timeout.

The later `16:59:20Z` restoration trace identifies a distinct bonded-link recovery failure. iOS
retired a peripheral restored in CoreBluetooth's connecting state, and CoreBluetooth then reported
`CBError.encryptionTimedOut` (`code 15`): “Failed to encrypt the connection.” Cleanup completed, the
app immediately returned to a fresh service-filtered scan, and it observed the named gateway at
`-77 dBm`. Because the configured admission threshold was `-72 dBm`, the app correctly deferred
that weak candidate and continued scanning. This proves the restored-peripheral cleanup path works;
it does not implicate GATT discovery or VHOS decoding because encryption failed before the
application contract. It also demonstrates why field results must separate radio admission,
bond/encryption recovery, and post-handshake sustained transport.

## Current CAN interpretation

The strict analyzer re-ran across all eight durable sessions in the confirmation copy: 5,176
listen-only observations, 17 identifiers, approximately 140.831 aggregate seconds, an estimated
538.88 observed frames/s, 36.753 retained records/s, and 6.8196% retained sampling coverage. Eight
identifier families (`0x022`, `0x023`, `0x025`, `0x223`, `0x2C1`, `0x2C4`, `0x2D0`, and `0x420`)
matched the Toyota additive-checksum candidate on every applicable retained frame. Across 625
time-paired samples, raw word `0x2C4[0:16]` and `0x2D0[0:16]` retain Pearson correlation `0.99213`
and median right-to-left ratio `1.979058`. On all 667 durable `0x025` frames, bytes 4, 5, and 6
agree exactly, with their common raw value spanning `115...255`. A second cross-ID raw-word
candidate pairs `0x022[0:16]` with `0x223[0:16]` across 142 samples at Pearson correlation
`-0.999643`; that relationship may reflect a shared operating-state trajectory rather than a
physical signal relationship. These are strong repeatable raw relationships; none supplies
accepted vehicle units or semantics without target-vehicle reference correlation.

The recovered 926-record session contains 17 unique identifiers. Seven Toyota additive-checksum
candidates passed every applicable retained frame:

| Identifier | Valid / checked | Match rate |
| --- | ---: | ---: |
| `0x022` | 136 / 136 | 100% |
| `0x023` | 16 / 16 | 100% |
| `0x025` | 58 / 58 | 100% |
| `0x223` | 12 / 12 | 100% |
| `0x2C1` | 68 / 68 | 100% |
| `0x2C4` | 103 / 103 | 100% |
| `0x2D0` | 88 / 88 | 100% |

On all 58 retained `0x025` messages, bytes 4 and 5 agree exactly; the common value ranges from 47
to 197. This is a useful redundant-channel consistency observation, not proof of steering units or
semantic layout.

Cross-model research can prioritize experiments but cannot silently create a 2005 4Runner signal
definition. The current hypothesis report accepts zero production signal definitions, sets
`promotion_allowed: false`, limits display to `ENGINEERING_RESEARCH`, and requires the badge
`UNVERIFIED CROSS-MODEL HYPOTHESIS`.

| Candidate | Target evidence in this session | Current authority |
| --- | --- | --- |
| `0x2C4` word 0, engine-speed-shaped | raw 685...2,119; published candidate transform gives about 535.16...1,655.47 rpm | High-priority cross-model candidate only |
| `0x2C4` byte 3, intake-air-temperature-shaped | raw 33...38; published sources disagree between raw °C and `raw * 2.5 - 40` | Conflicting cross-model transforms |
| `0x2D0` word 0, turbine/RPM-shaped | raw 0...3,704; one published transform gives 0...1,446.875 rpm | Cross-model candidate only |
| `0x2D0` byte 2, selector-shaped | codes 0...16; synchronized run still aliases labeled Park and Neutral at code 8 | Experimental target evidence; not a selector decoder |
| `0x2C1` byte 6, accelerator-shaped | raw 0...47; one common transform gives 0...23.5% | High-priority cross-model candidate only |
| `0x025`, steering-shaped field | signed candidate -39...16; sources disagree materially on width, direction, and scale | High-priority cross-model candidate only |
| `0x224`, brake-pressure-shaped field | raw 0...321 | Cross-model candidate only |
| `0x223`, stop-light-shaped ID | identifier present with sparse states | ID-only candidate |
| `0x022`, `0x023` | related Toyota steering/stability-family references; target fields dynamic | Corroborated identifier family, semantics unverified |
| `0x420` | present, not mapped | Unknown |

The sparse portable sampling does not provide sufficiently close paired observations to reproduce
the earlier cross-ID RPM correlations in this session. No signal should be rejected or promoted
solely because a cross-ID pair fell outside the analyzer's 250 ms pairing window.

## Fix state

### Implemented in the current development tree

1. **Strict portable CAN recovery.** The Python `extract-portable-can` path validates SHA-256,
   VHOS CRCs, metadata, gateway role, listen-only state, and physical identity before writing a new,
   non-overwriting extraction directory. It supports a capture-session filter and fails closed on
   same-identity conflicts.
2. **Shared iOS projection logic.** `PortableCANEvidence` in VHOSCore projects live raw-CAN and
   capture-history chunks under the same strict provenance and conflict rules, preferring identical
   gateway-flash history over BLE-live sampling.
3. **Append-only Discovery lineage.** The capture binding, test-run transitions, and six markers
   survived the process lifecycle as independently valid ledger records.
4. **Restored-peripheral cleanup and BLE flight recording.** The app retains exact link-phase and
   reconnect evidence rather than treating the iOS Settings “Connected” label as a validated VHOS
   application contract.
5. **Fail-closed Discovery recorder gate.** `DiscoveryMutationPolicy` now denies authority when
   queue-drop or persistent-write counters are unavailable or nonzero, or when recorder free space
   is below 128 KiB. The Run Test view exposes the write-path and storage-headroom checks as separate
   readiness rows. This first implementation uses absolute cumulative counters; session-baseline
   and delta semantics remain a firmware/contract follow-up.
6. **Automatic retained-history offload after terminal transitions.** The app appends the immutable
   terminal test-run transition first and then requests the existing bounded
   pause/download-current-and-previous/resume workflow after `ENDED`. An `ABORTED` run requests the
   same recovery offload only when fresh health reports both the run's exact gateway and
   capture-session identity; otherwise the terminal ledger directs recovery after reconnect. Failure to start the
   transfer cannot roll back the terminal run and is surfaced to the user. Final immutable
   archive-manifest/hash binding to the test run is not yet implemented.
7. **Portable evidence in iOS research and recovery export.** iOS projects and reconciles
   checksummed portable CAN with the normal capture store under the same fail-closed
   identity-conflict policy for research. The Evidence view displays
   `RECOVERED EVIDENCE • NOT LIVE`; recovered export uses a backward-compatible v2 `.vhossync`
   recovery manifest that binds the classification, denies vehicle authority, and requires its
   source-ledger SHA-256 to equal the complete logical-frame segment. Desktop
   `extract-portable-can` consumes that shared bundle directly and creates a separately
   labeled recovery manifest plus per-record recovered wrappers. Every wrapper retains
   `RECOVERED_PORTABLE_EVIDENCE` and `vehicle_claims_authorized=false`, so a detached segment cannot
   masquerade as ordinary live evidence. The normal
   passive-CAN export is reserved for the complete durable capture archive so classification and
   source hashes cannot be silently discarded. CAN research consumes the reconciled observations
   even when no normal capture session was synchronized.
8. **Gateway-monotonic selector dwell.** Bootstrap template `1.1.0` requires eight-second selector
   holds. Both the AppModel mutation boundary and the Run Test controls calculate remaining dwell
   from the gateway monotonic timestamps, fail closed if that clock regresses or the prior timestamp
   is missing, disable the next selector marker or final test end, and display the remaining hold
   time. The initial safety-confirmation marker is the only intentional no-dwell transition.

Portable recovery is a safety net. It must not become an excuse to leave the recorder archive
undownloaded.

### Required follow-up before treating the next run as promotion evidence

1. **Field-validate the recorder gate and terminal offload.** Install matching iOS and gateway
   builds, begin from a fresh recorder session, prove that each degraded counter/storage case blocks
   a run, and prove that ending a valid run downloads the current and required preceding history
   before recording resumes. Define session-baseline/delta semantics so an old cumulative error does
   not remain ambiguous across a deliberate fresh-session boundary.
2. **Finalize archive lineage.** Verify the downloaded session manifest and hashes, bind them
   immutably to the ended `CaptureSession`/test run, and surface an explicit incomplete-export state
   if that finalization does not complete. Portable recovery remains a lower-fidelity safety net.
3. **Harden Android import conflicts.** `CONFLICT_IGNORE` is insufficient by itself; Android must
   compare bytes for an existing physical identity and fail closed if the payload differs.
4. **Instrument gateway BLE scheduling.** Persist BLE task/queue high-water, notification-send
   failures, connection event, heap, watchdog, and recorder-write latency alongside UART timestamps.
   Keep periodic health independent from history/filesystem work.
5. **Protect recorder capacity.** Use bounded lossless binary capture to microSD for full-fidelity
   work; use flash sampling only as a bounded fallback. Report receive loss, deliberate suppression,
   persistence failure, and export incompleteness as separate counters.

## Exact next field-run protocol

Do not begin another selector run merely because BLE says Connected.

### Before going to the vehicle

1. Preserve the current iPhone snapshot and portable-ledger hash listed above.
2. Build and run the portable recovery, CRC/conflict, replay-load, Discovery-ledger, and sustained
   BLE tests against session `3025357416`.
3. Install matching released iOS and gateway firmware builds and record both versions.
4. Prepare a synchronized gateway UART log. If available, prepare Toyota Techstream or another
   accepted independent selector-state source.

### At the vehicle, before the experiment

1. Offload and verify every existing gateway capture before any authorized storage rotation.
2. Start a fresh gateway capture session. Confirm that the capture-session ID is new and identical
   in handshake, health, live CAN, the iPhone binding, and the UART log.
3. Require all readiness rows to pass: current VHOS contract, passive recorder active, fresh
   listen-only health and raw timeline, matching lineage, zero new queue/write failures, no bus-off,
   and at least the configured storage headroom. Do not accept a cumulative counter without showing
   its session baseline and delta.
4. Observe health for at least 60 seconds before the test. Any notification gap, counter stall,
   recorder error, or reconnect restarts this preflight.

### Selector bootstrap

1. Use level ground, wheels chocked, parking brake applied, engine off, ignition on, and foot brake
   held, exactly as the template requires.
2. Tap **Safety setup confirmed** once.
3. For each position in `P → R → N → D → P`, move fully into the detent, tap the matching
   marker at the completed physical transition, and hold that position for at least eight seconds.
   The template's gateway-monotonic countdown keeps the next marker disabled until the hold is
   complete; do not advance while that countdown is active.
4. Keep the independent selector reference recording on the same time base. Record any mismatch or
   missed physical action; do not relabel it after the fact.
5. End the run only after the complete canonical marker sequence. Wait while the app pauses,
   flushes, downloads, verifies, and resumes the recorder.
6. Before leaving, verify that the iPhone contains the new gateway session in the normal PassiveCAN
   store, that its first/last source sequences cover the marker window, and that the portable copy
   agrees for every shared identity.

### Repetition and acceptance

1. Repeat the complete procedure in at least two additional, separate capture sessions.
2. Analyze raw bits/fields against all marker transitions and the independent reference. Specifically
   test whether any proposed Park field distinguishes Park from Neutral with no false activation.
3. Replay the proposed decoder over the complete sessions and earlier golden captures.
4. Keep the signal experimental if any session has ambiguous lineage, recorder degradation,
   conflicting bytes, missed dwell, disagreement with the reference, or stale evidence.
5. Promote `transmission.selector_position` or a Park assertion only after the repository's full
   target capture, independent-corroboration, freshness/range, and golden-replay gates pass.

### Sustained-link run in parallel

After the selector captures, keep the gateway connected for at least 15 minutes while the phone
receives health and sampled raw CAN and performs one bounded history transfer. Preserve iPhone BLE
flight recorder, gateway UART, capture index, reset reason, BLE notification queue depth, and power
state on the same wall-clock interval. Passing means the VHOS contract stays current, health cadence
remains within its bound, no reconnect occurs, and recorder/CAN counters remain explainable under
load. A failure should identify the last successful notification and the matching UART event rather
than be reported as a generic “Bluetooth dropped.”

## Decision

The August 22 return is a successful evidence-recovery event and a failed promotion-quality
capture. It gives us a concrete selector candidate and a precise transport/storage failure profile,
but it does not give the product a Park signal yet. The next development and field work must make
complete evidence retention and sustained transport explicit acceptance gates; only then should
signal interpretation advance from Engineering Research into the vehicle's versioned Signal Pack.
