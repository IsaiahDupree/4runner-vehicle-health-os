# Offline experimental-candidate registration gap

Status: Core finalizer/store implemented and verified; UI registration intentionally not wired

Date: 2026-08-24

## Outcome

The new `ExperimentalCandidateStore` is a truthful offline persistence boundary once the app can
supply a canonical `CandidateSignal` and resolve every referenced capture through a
`FinalizedCaptureStore`. Candidate save re-reads the finalized ledger and verifies the
content-addressed archive, manifest, and vehicle-profile bytes before it accepts provenance; bare
in-memory `CaptureSession` values are not accepted. It does not need a live BLE connection, a
`PARKED` report, or an active gateway when it appends or reloads an experimental candidate. Each
entry remains
`EXPERIMENTAL_CANDIDATE`, encodes `promotionAllowed = false`, snapshots exact archive/manifest
hashes, and fails closed when candidate references do not match capture provenance.

The current iOS Discovery screens cannot yet call that store without inventing provenance. No
"Save candidate" button should be enabled from the current retained-research report.

`DiscoveryCaptureFinalizer` and `FinalizedCaptureStore` now provide the smallest truthful Core
boundary beneath that future UI. They accept one exact newline-committed canonical NDJSON archive
prefix, matching persisted vehicle-profile bytes and SHA-256, a complete gateway identity, the
exact canonical `ENDED` test-run snapshot plus its SHA-256, and session-bound
markers/measurements. The terminal snapshot must retain its immutable acquisition authority and
the owner acknowledgement required by local evidence-only mode. They derive record/range/bitrate
facts from the archive bytes, publish the archive/profile/manifest under content-addressed names,
and append the validated `CaptureSession` to a recoverable immutable ledger. Missing metadata,
mixed recorder sessions, sequence reversal, unbound evidence, terminal-scope/version mismatch,
digest conflicts, artifact loss, concurrent capture-identity reuse, and a commit timestamp earlier
than the archive end all fail closed.

## Evidence available today

The existing layers retain useful but incomplete pieces:

- `CaptureLogStore` retains canonical passive-CAN observations in per-gateway, per-recorder-session
  NDJSON ledgers. `CaptureSessionSummary` contains only gateway ID, numeric recorder-session ID,
  record count, byte count, modification date, and file URL.
- `DiscoveryEvidenceStore` retains a durable capture ULID binding, test-run drafts, and canonical
  event markers. A `DiscoveryTestRunDraft` explicitly is not a finalized `CaptureSession`.
- `PassiveCANResearchAnalyzer` retains an evidence semantic SHA-256, research-pack identity, and
  downsampled candidate series. A series retains gateway/session/sequence locations, but the report
  does not carry canonical capture IDs, archive hashes, manifest hashes, vehicle-profile identity,
  gateway firmware/configuration provenance, or the complete marker set.
- Portable `.vhossync` import receipts retain source archive and manifest hashes, but they describe
  a portable evidence bundle. They are not a canonical Discovery `CaptureSession`, and recovered
  portable evidence explicitly cannot assert vehicle authority.

There is no production call site that constructs a canonical `CaptureSession`. Every current
construction is in Core tests. Existing product documentation already identifies immutable archive
finalization as the next capture milestone.

## Why deriving a candidate directly from the current card would be false

Generating a placeholder capture ID or hashing the downsampled graph would break the evidence
lineage. In particular, the app cannot currently prove all of these `CaptureSession` requirements
from a candidate card:

1. the exact byte-complete retained archive and its SHA-256;
2. the canonical capture manifest and its SHA-256;
3. vehicle ID plus the exact vehicle-profile SHA-256;
4. start/end wall time and monotonic bounds;
5. exact gateway firmware, protocol, active configuration, and hardware provenance;
6. complete gateway-session, bitrate, record-count, and source-sequence bounds;
7. the complete set of retained markers and measurements that fall within those bounds; and
8. an immutable association between the ended test-run draft and that finalized archive.

The current research graph is also downsampled for display. It cannot be treated as the complete
analyzed observation set, and its semantic digest must not be relabeled as an archive or manifest
digest.

## Implemented finalization foundation

The Core `DiscoveryCaptureFinalizer` now performs the following before any
candidate-registration UI is added.

The finalizer should run after retained history has been synchronized and should:

1. Accept one exact committed NDJSON ledger prefix for the gateway recorder session. The app layer
   still must open an exact-length file descriptor and supply that sealed prefix; a mutable file
   URL is deliberately not accepted by Core.
2. Decode and validate every record in that prefix, reject identity/sequence conflicts, and derive
   the exact record count, monotonic range, source-sequence range, bitrate set, gateway ID, and
   listen-only state.
3. Resolve the existing `DiscoveryCaptureBinding`, exact canonical `ENDED` test-run draft bytes,
   and all canonical event markers/measurements for the same gateway and numeric recorder-session
   ID. Bind the draft SHA-256, acquisition authority, owner acknowledgement, state, canonical
   template ID, and canonical template version into the manifest. Reject a marker that is outside
   the sealed monotonic or sequence range.
4. Require persisted vehicle-profile bytes and their independently resolved SHA-256 plus
   handshake-captured gateway hardware,
   firmware, protocol, and configuration identity. Do not substitute an "unresolved" production
   value.
5. Create a canonical manifest from those exact inputs, hash the sealed archive and manifest, then
   construct and validate `CaptureSession`.
6. Publish content-addressed archive/profile/manifest artifacts and append that immutable session
   to a dedicated finalized-capture ledger. A corrected or expanded
   archive receives a new capture identity; it never overwrites the earlier session.
7. Throw an explicit, typed finalization error whenever any required input is unavailable or
   mismatched; no ledger line is appended.
8. Resolve candidate capture IDs back through that finalized store at save time so missing or
   tampered content-addressed evidence cannot enter the candidate ledger.

The remaining production blocker is an app-layer resolver that opens the exact committed prefix
from `CaptureLogStore`, resolves the corresponding binding and terminal run from
`DiscoveryEvidenceStore`, and supplies persisted vehicle-profile and handshake provenance. Those
facts do not all exist in the current app stores, so the UI remains disabled rather than filling
them with placeholders.

After finalization exists, extend passive research so its output retains the exact finalized
capture IDs it analyzed, in addition to `generatedFromSHA256`. Candidate construction must use the
complete observations from those captures, not the graph's downsampled points. It should resolve
the exact catalog field definition, declare the analysis algorithm/version, and avoid synthesizing
correlation or repeatability metrics that were not calculated.

Only then should `DiscoveryCandidateDetailView` expose:

- `Save experimental candidate` when every analyzed capture resolves to a finalized
  `CaptureSession` and the candidate/capture evidence sets match exactly;
- `Registration unavailable — finalize retained evidence` with the exact missing input otherwise;
- a persisted receipt showing `EXPERIMENTAL_CANDIDATE`, `promotionAllowed = false`, candidate hash,
  provenance hash, and archive/manifest evidence references after success.

Saving and reviewing this offline record must remain available without BLE and without a motion
report. It is evidence bookkeeping, not a vehicle mutation. OTA, protocol experiments, diagnostic
requests, arbitrary CAN transmission, vehicle control, and promotion to a validated signal remain
outside this path and keep their existing safety/authority checks.

## Recommended acceptance checks

- Finalize a real retained session, terminate the app, relaunch offline, and save a candidate whose
  capture IDs match the finalized ledger.
- Reject an ended test-run draft that has no sealed archive or manifest.
- Reject a research report whose capture set is only a subset of the candidate's claimed captures.
- Reject marker, gateway, recorder-session, sequence, vehicle-profile, archive, or manifest
  mismatches without mutating either ledger.
- Reject an ACTIVE/ABORTED terminal snapshot, missing or extra local safety acknowledgement,
  altered bootstrap template version, a finalization timestamp before archive end, or tampered
  finalized artifact without appending either ledger.
- Prove concurrent finalized-capture and candidate writers serialize by canonical ledger path.
- Prove a saved candidate reloads offline and remains unable to pass the signal-promotion gate.
- Prove candidate registration performs no BLE write and does not consult the live motion state.
- Prove an interrupted final ledger append is quarantined without rewriting committed evidence.
