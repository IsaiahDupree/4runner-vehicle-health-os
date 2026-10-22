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

### Portable-envelope recovery

Every checksummed VHOS logical frame received by iOS is also retained in the append-only portable
evidence ledger:

```text
VHOSPortableFrames/v1/logical-frames.ndjson
```

That filename is the active generation, not an indefinitely growing file. Before the active
generation reaches 16 MiB or 20,000 records, iOS atomically seals it as:

```text
logical-frames-generation-000000000001-<source-ledger-sha256>.ndjson
```

The next append creates a new active ledger. A sealed generation is never reopened for append and
its exact lowercase SHA-256 is rechecked against its filename every time records are read or
exported. Rollover moves bytes; it does not summarize, checkpoint away, or delete evidence. An
invalid complete NDJSON line, a malformed generation filename, a repeated ordinal, or a hash
mismatch fails closed without rewriting source bytes.

Generation ordinals start at `000000000001` and must remain exactly contiguous. The v2 durable
inventory anchor requires both a monotonic high-water receipt and
`generation-integrity-v1.manifest`. That canonical manifest permanently binds every sealed ordinal
to its first lowercase SHA-256. Consequently, deleting a generation, replacing it with different
valid NDJSON under the same ordinal, changing the content-derived filename, deleting the manifest,
or reusing an ordinal makes count, append, and export fail closed across process restarts. Rollover
publishes the content binding before advancing high-water; recovery may complete only the single
contiguous suffix that this ordering can leave during power loss. It never accepts or rebaselines
an arbitrary unreceipted suffix. The ordinal-only v1 receipt is migrated once after every existing
generation has been streamed and checked against its content-addressed filename. A v1 store with
an oversized active ledger uses a separate content-addressed, restartable migration receipt that
binds its already-sealed prefix, streams the active bytes into bounded suffix generations, and only
then publishes the v2 integrity manifest. Any v1 sealed generation already beyond the configured
byte or record ceiling cannot be safely renamed or resegmented without changing immutable ordinal
history, so v2 promotion stops fail-closed and preserves the source instead of blessing an
unbounded generation.

A lone active ledger remains the supported migration from the pre-generation release, but it is
not trusted as one unlimited generation. iOS validates it with 64 KiB reads and bounded line
buffers. If it exceeds 16 MiB or 20,000 records, a read-only content-addressed copy and migration
receipt are persisted, then the exact committed lines are streamed into normal bounded immutable
generations. The final bounded segment becomes active. The preserved source makes an interrupted
multi-file publication restartable without losing evidence. An incomplete final append first uses
the same exact-tail recovery described below; invalid newline-committed input remains unchanged and
is copied to `LegacyActiveLedgerQuarantine/` before migration fails closed. No migration path loads
the legacy ledger into one `Data`, record array, or identity set.

Every newline-committed ledger line must be exactly one canonical portable-record JSON encoding.
A blank committed line or a semantically valid but reformatted/reordered JSON line is corruption:
count, append, migration, and export stop fail-closed without rewriting those committed bytes.

An active ledger has one narrower power-loss recovery rule. A nonempty final byte suffix without
the NDJSON commit newline is an interrupted append, not a complete record. Before changing the
active file, iOS writes three read-only, content-addressed artifacts under
`InterruptedActiveLedger/`: the exact original ledger, the exact binary tail, and a JSON receipt
binding their SHA-256 values and byte counts. It then atomically restores only the already-validated
newline-delimited prefix and can continue appending. A newline-terminated but invalid final line is
complete evidence of corruption and is never repaired as a power-loss tail. Sealed generations are
immutable and never use tail recovery.

Exact record identity and count live in a derived SQLite index (`record-index.sqlite3`) rather than
an unbounded in-memory `Set`. The index uses a binary primary key, full synchronous transactions,
SQLite integrity checking, a content-bound generation/active-ledger fingerprint, and a declared
exact count. Index schema v2 also stores the canonical full-record SHA-256 and immutable source
role for each physical-envelope identity. Only a byte-for-byte canonical record match is
idempotent; reusing the same source/envelope identity with a different role, ingestion time, or
other provenance is an integrity collision and fails closed. When any check disagrees, iOS rebuilds
the index by streaming each verified ledger from disk in bounded chunks. Duplicate record identity
with conflicting provenance fails the rebuild. The app therefore does not
materialize all historical identities or records on startup, count, or each append, and an
integrity failure is surfaced in Evidence instead of becoming a misleading zero count.

The iOS materialized-import boundary is the same 16 MiB / 20,000-record ceiling used by each
generation. It rejects an oversized ZIP entry, declared segment, or archive before any portable
record is appended. Larger evidence collections must arrive as independently checksummed bundles,
not one allocation-heavy archive. The number of immutable generations is not silently capped;
available app storage remains the physical retention boundary and no generation is automatically
pruned. This removes the old eventual export dead end without allowing a selected bundle to force
hundreds of megabytes of simultaneous ZIP, NDJSON, record-array, and Base64 allocations.

Import is also preflighted as one semantic operation. The selected URL is size-checked before any
archive allocation and then read in bounded 64 KiB chunks. Every record is validated against the
disk-backed identity index and every other record in the selected bundle before the first new line
is appended, so a late source-role or provenance collision cannot leave a valid prefix imported.
Before appending, iOS durably preserves the original archive and a content-bound import intent.
After all records are durable, it writes one immutable completion receipt keyed by bundle UUID and
removes the intent. A restart with an intent revalidates and idempotently replays the preserved
archive before completing the receipt; power loss cannot leave imported frames without lineage.
The receipt binds the original archive and manifest SHA-256, creator platform/app/version/device,
recovery source-ledger metadata, record count, and a length-framed canonical record-ID/record-SHA
chain. Manual recovery export and the private AI outbox include both the original signed archive
and its completion receipt as separately checksummed lineage artifacts. Retrying the identical
bundle is idempotent; reusing its UUID with different provenance fails closed. A rejected preflight
writes neither frames, an intent, nor a receipt.

The import journal has an explicit persistence order, not only atomic renames: synchronize the
intent and its directory; synchronize the archive and ready marker; synchronize each ledger append
and generation receipt; synchronize the immutable v2 completion receipt; then delete the intent
before the ready marker and synchronize their directories. A crash after the archive but before the
ready marker is reconciled as an orphan journal, while a crash after the completion receipt but
before journal removal recognizes that exact receipt and completes cleanup without replaying or
quarantining valid evidence. Existing v1 receipts are upgraded from the preserved archive during
startup recovery, without requiring the owner to select the original file again. Missing inventory
anchors are checked before tail repair, orphan reconciliation, or legacy migration can mutate any
artifact; SQLite state, import journals, legacy migration receipts, and quarantine directories all
prove that the store was previously initialized and therefore prohibit an empty rebaseline.

Import receipts and their private-outbox reader share a 16 MiB ceiling. This is intentionally the
same byte bound as one portable evidence generation: a receipt may contain all 20,000 immutable
record links from a maximum-size bundle, so the provenance artifact must remain queueable even
when it is larger than 1 MiB. The original archive remains independently limited to the 18 MiB
wire-archive ceiling.

Export, ZIP construction, retained-CAN decoding, research analysis, and outbox payload verification
run on serial background actors rather than the CoreBluetooth/UI main actor. The main actor opens
only exact-length descriptors from the same live store instance; it never creates a second store
that could race ledger recovery or SQLite maintenance. Automatic AI handoff prepares at most two
missing immutable artifacts per cycle, manual preparation at most eight, and the next cycle resumes
by stable generation/lineage identity. Each selected descriptor is SHA-256 checked again by the
worker before publication. This bounds memory and work per cycle while leaving BLE callbacks and
connection watchdogs schedulable during a long-lived, multi-generation evidence history.

Portable-store failures are sticky authoritative-evidence failures. The app retires the active BLE
link, stops scanning and automatic reconnect, clears the last trusted portable count, and blocks
export/outbox controls until the same store instance passes integrity verification. It never keeps
accepting live frames after durable persistence has failed. Discovery bootstrap markers are also
serialized inside the evidence store: exactly one first marker may establish the baseline, and
subsequent markers must satisfy the store's monotonic dwell rule even when UI submissions race.

A CRC-valid logical frame captures its link epoch and source identity before entering the serialized
persistence tail. Disconnect, restoration cleanup, or a replacement connection invalidates only
that old frame's UI/state-machine application; it does not discard or rebind accepted bytes. The
old frame commits under its original source identity, then is ignored for the replacement session's
handshake, counters, and live values. If that commit fails, the sticky integrity path above retires
the authoritative link instead of translating storage loss into an ordinary decoder warning.

The retained passive-CAN session ledger uses the same newline-as-commit rule. A durable SQLite
index stores exact canonical record digests and offsets, so session counts do not require a
lifetime-sized in-memory sequence set. An interrupted final append is preserved as exact quarantine
evidence before the committed prefix is restored; a blank, malformed, noncanonical, or
same-sequence/different-content committed line fails closed. Therefore a capture-download resume
offset is derived only from validated committed bytes and cannot silently skip corruption.

This is a recovery source, not a replacement for the gateway flight recorder. It matters when a
field session was visible live but its capture index/chunks were not downloaded before the gateway
became unavailable. iOS and the desktop tooling now:

1. validate the portable contract, SHA-256, exact single VHOS envelope, outer CRC32C, and mirrored
   envelope metadata;
2. accept CAN only from the `OBD_CAN` role and require listen-only proof;
3. decode live CAN frames and CRC-protected capture chunks;
4. fail closed on a reused observation identity with different physical evidence;
5. deduplicate exact live/history overlap and prefer `gateway-flash` provenance;
6. expose recovered observations to iOS research, replay, and export with the mandatory label
   `RECOVERED EVIDENCE • NOT LIVE`.

The desktop recovery command never overwrites its input or an existing output directory:

```bash
.venv/bin/vhos extract-portable-can \
  path/to/vhos-recovered-evidence-not-live-ledger-<sha256>.vhossync \
  --session-id 3025357416 \
  --output build/recovered-session-3025357416
```

For forensic work against an unbundled device-data snapshot, the command also accepts the original
`VHOSPortableFrames/v1/logical-frames.ndjson`. A `.vhossync` input is ZIP-CRC checked, path-safe,
manifest-validated, segment-count/size/SHA-256 checked, and then envelope-validated before any CAN
projection is written.

The extraction emits a SHA-inventoried manifest plus recovered-observation NDJSON files grouped by
gateway and recorder session. Every individual line is an explicit
`can.recovered-passive-can-observation` wrapper carrying
`RECOVERED_PORTABLE_EVIDENCE` and `vehicle_claims_authorized=false`; copying a segment away from its
manifest therefore cannot make it look like an ordinary live observation. The ordinary
`discover-can` loader rejects these wrappers. Analyze only the complete extraction with:

Publication is transactional. The desktop tool writes into a private staging directory, reopens
the complete manifest and every declared output file, verifies actual byte counts, record counts,
lowercase SHA-256 values, unique physical identities, statistics, and exact decoded-record
equality, and only then atomically renames the staging directory to its final name. Any failed
read-back removes staging and leaves no final extraction directory.

The extraction manifest also cross-binds each bundled source ledger to the SHA-256 of its source
`.vhossync` archive and that archive's manifest. For recovery-v2, the bundle's
`source_ledger_sha256` must additionally equal the SHA-256 of its one matching
`segments/logical-frames.ndjson` source. Missing, ambiguous, uppercase, unknown, or internally
inconsistent source provenance fails closed; it is never treated as advisory metadata.

```bash
.venv/bin/vhos discover-recovered-can build/recovered-session-3025357416 \
  --output build/recovered-session-3025357416-discovery-report.json
```

That command rechecks the extraction manifest, exact file inventory, byte counts, SHA-256 values,
record counts, wrapper authority fields, passive-observation fields, listen-only proof, and unique
physical identities before analysis. Its report retains the explicit recovered/non-authoritative
label. Live portable sampling remains lower-fidelity than a complete flash offload and cannot, by
itself, authorize a decoded signal meaning or vehicle-health conclusion.

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
capability, recording state, at least 128 KiB free storage, zero queue drops, and zero storage
failures. Discovery test controls fail closed if any of those recorder conditions are unavailable
or degraded. At the vehicle, perform one controlled action at a time with spacing between actions. Active diagnostic
experiments remain unavailable until their separate signed-plan, allowlist, deterministic PARKED,
idle-capture, and explicit-approval gates pass.

Ending a Discovery test commits its append-only terminal record first, then automatically requests
the bounded pause -> current/previous history download -> resume sequence. Aborting a run performs
the same recovery offload only when fresh live health reports both the run's exact gateway and
capture-session identity; otherwise the app preserves the terminal ledger record and instructs the user to recover that
session from Evidence after reconnecting. A transfer failure cannot undo the terminal ledger
record, and the portable envelope ledger remains available as a lower-fidelity recovery path.

The normal passive-CAN NDJSON export contains the complete validated durable capture archive and
does not apply the 50,000-observation in-app research window. Recovered portable observations are
intentionally not blended into that file. Normal bidirectional app sync remains canonical
`.vhossync` manifest v1. Portable-ledger recovery exports manifest v2 with a required recovery
object that binds `RECOVERED_PORTABLE_EVIDENCE`, `vehicle_claims_authorized=false`, and the complete
source-ledger SHA-256 inside the checksummed bundle. The digest must equal the one complete
logical-frame segment, so renaming the artifact cannot erase or spoof its provenance.
`vhos extract-portable-can` consumes the shared `.vhossync` directly, validates the ZIP CRC,
manifest, segment, and logical-envelope layers, and produces separately labeled recovered wrappers
plus a recovery manifest on desktop. Readers reject duplicate/unknown JSON fields and enforce the
shared per-bundle floor before materialization: at most 20,000 records, 16 MiB per data segment, a
1 MiB manifest, 17 MiB aggregate uncompressed content, 18 MiB of archive bytes, and 33 ZIP entries.
Larger collections remain independently checksummed generation bundles and may be analyzed
together under the desktop tool's separately bounded multi-source analysis ceiling.

When more than one portable ledger generation exists, **Prepare checksummed `.vhossync` bundle**
returns one independent recovery-v2 file per generation. The Evidence screen shares those URLs as
one complete multi-file share set and explicitly states that every file must be transferred. The
private AI outbox similarly enqueues every generation and content-hash deduplicates generations it
already holds. Each artifact names its generation ordinal and source-ledger digest; each internal
manifest independently binds the same digest and `RECOVERED_PORTABLE_EVIDENCE`, with
`vehicle_claims_authorized=false`. A newer generation never replaces an older one.

Bundle identity is deterministically derived from the complete source-ledger SHA-256 and
`created_at` is the generation's final retained wall time. The ZIP writer is deterministic, so an
unchanged generation produces byte-identical `.vhossync` output on repeated automation cycles and
the bounded outbox stores it only once. A changed active generation is intentionally a different
content-addressed snapshot; sealed generations remain byte-stable forever.

Portable scalar validation is identical at the app-ledger and bundle boundaries: source sequence
and monotonic time are canonical unsigned decimal strings with no leading zeroes, source IDs and
creator strings honor their schema lengths, SHA-256 values are lowercase, timestamps are RFC 3339
wall times, message type zero is rejected, and the Base64 envelope honors its published size limit.
The app uses the strict record decoder for both loose NDJSON and ZIP-contained records, so moving a
line outside its bundle cannot weaken validation.

VHOS deliberately rejects RFC 3339 leap-second spellings (`:60`). The shared JSON Schema adds an
explicit `00`–`59` seconds constraint and every producer/consumer must apply the same fail-closed
policy. This avoids a contract-valid artifact on one platform becoming unrecoverable on another.

`discover-recovered-can` carries a `recovery_provenance` object in its discovery report. It retains
the validated extraction-manifest contract, exact byte count and SHA-256; the original portable
source-file inventory; every source-bundle and bundle-manifest digest; and the recovered output-file
inventory. Contract semantic validation cross-binds the analyzed `source_files` to those output
files, each bundled source file to its source bundle and manifest digest, and each recovery-v2
source ledger to the digest asserted by its bundle. The standalone report therefore preserves a
stable path back to the exact extraction manifest and original iPhone evidence instead of replacing
that lineage with only the derived session-wrapper hashes.

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

The iPhone now retains append-only owner-created test runs and markers with gateway monotonic time,
capture session, and source-sequence lineage. The next capture milestone is to finalize those
records against the automatically offloaded archive manifest and field-validate the new
eight-second gateway-monotonic dwell gate by running the same labeled sequence in at least two
independent sessions. Desktop replay can
then rank identifiers/bytes against the labels. Hypotheses must remain proposals until independently
corroborated and versioned into a Vehicle Signal Pack.

The first vehicle export has now been preserved as a separate evidence-bounded engineering record:
[Passive CAN capture analysis — 2026-08-17](PASSIVE-CAN-CAPTURE-ANALYSIS-2026-08-17.md). It records
the reported frame-rate/coverage/checksum metrics, signal candidates, why the sampled dev.11 export
is not lossless, and the agreed Lossless Capture V2 -> Experiment Mode -> automatic discovery ->
allowlisted diagnostics sequence. Candidate Toyota identifiers and scales in that note are not
production decoders.
