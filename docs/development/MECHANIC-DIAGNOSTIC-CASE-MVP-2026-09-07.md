# Mechanic diagnostic case MVP — local iOS pilot slice

- Status: Implemented local slice; physical-device and commercial acceptance remain open
- Date: 2026-09-07
- Authority decision: ADR-0005
- Canonical maintenance authority: ADR-0004 Android ledger

## Delivery truth

This change delivers the first native iOS vertical slice: a versioned diagnostic-case JSON contract,
matching Swift Core model, append-only app-private ledger, the five-screen SwiftUI workflow, bounded
content-addressed attachments, and deterministic privacy-selected PDF/JSON/manifest report
artifacts. The workflow can be exercised without a gateway, account, cloud service, or internet
connection.

This is not a claim of complete product or commercial acceptance. Physical-device airplane-mode and
process-termination testing, export-package import/verification, selected attachment packaging,
cloud/team synchronization, durable customer consent/authorization receipts, payments, licensed
repair data, and a paid field pilot remain unimplemented or unrun as identified below. The
implementation remains a technician-authored local draft and never writes canonical maintenance
history.

## MVP objective

Let one diagnostic specialist complete a real, redacted vehicle case on an iPhone while offline:

1. record the customer's concern and vehicle intake facts;
2. record technician observations, measurements, DTC facts, attachments, and evidence gaps;
3. separate observed facts from diagnostic hypotheses and recommended next steps;
4. survive interruption without loss, duplication, or silent history rewrite; and
5. export a professional, privacy-reviewed report bound to the exact case revision.

Every case and report has `TECHNICIAN_LOCAL_DRAFT` authority. It is useful technician-authored
evidence, but it is neither canonical vehicle maintenance history nor an authorized VHOS vehicle
finding.

## Intended user and job

The initial user is an independent diagnostic specialist or small repair-shop technician who needs
to turn an intake, inspection, and diagnostic reasoning trail into a clear customer/referring-shop
handoff. The MVP tests whether durable offline case reporting saves enough time and creates enough
repeat value to support a paid product. It does not test autonomous diagnosis.

## Five-screen flow

### 1. Cases

The opening screen lists local cases by stable case identity, vehicle display label, concern,
workflow state, last committed revision time, and draft/report status. Search and filters operate
without network access. Empty state creates no sample customer or vehicle data.

Acceptance intent:

- reopening the app reconstructs the same current projections from append-only revisions;
- voided cases remain available in history and are not mixed into the active default list;
- an unreadable store displays a blocking integrity state, not an empty list; and
- the screen never labels a draft as synchronized, canonical, or vehicle-validated.

### 2. Intake

The technician starts a case and records the customer concern, intake source, vehicle display
identity, optional VIN/plate, odometer with unit and source, relevant systems, technician identity,
and free-form context. Unknown configuration remains unknown. Saving creates the first immutable
case revision.

Acceptance intent:

- minimum intake is usable without a gateway, account, or internet connection;
- required consent/privacy choices are explicit before sensitive fields are captured;
- a date-only occurrence is not assigned an invented instant; and
- a vehicle-specific schedule, PID, part, threshold, or trim fact is never inferred from sparse
  intake data.

### 3. Evidence

The technician adds typed observations, manual measurements with units/method, DTC facts with source
and observation time, photographs/documents, and optional referenced VHOS evidence. Each save appends
a case revision or a separately immutable evidence object linked by exact identity and hash.

Acceptance intent:

- observation, measurement, attachment, DTC fact, gateway evidence, simulator/replay material, and
  missing evidence remain visibly different;
- attachment bytes are durable and hash-verified before their reference is committed;
- gateway data is optional and cannot widen case or vehicle authority; and
- no result treats absent DTCs or missing data as proof of health.

### 4. Assessment

The technician reviews a structured evidence summary and records technician-authored hypotheses,
confidence/uncertainty, ruled-out or unresolved possibilities, safety notes, and recommended next
steps. Factual observations and hypotheses use separate presentation and serialized fields.

Acceptance intent:

- the technician can state `UNKNOWN` or insufficient evidence without inventing a score;
- a hypothesis cannot serialize or render as a validated vehicle finding;
- any AI suggestion is separately attributed, evidence-cited, and non-authoritative; and
- editing an assessment appends a successor revision and requires the expected current revision.

### 5. Report

The technician previews the exact committed revision, selects privacy and attachment inclusion,
generates the report/package, and invokes the system share surface. Preview shows the same draft
label, evidence distinctions, versions, and redactions present in exported bytes.

Acceptance intent:

- the human-readable report opens offline without an account;
- the package manifest verifies every included artifact and binds the report to one case revision;
- report generation does not mutate the case, Android ledger, findings, or lifecycle baselines; and
- cancelling or failing export publishes no partial package and loses no case data.

## Current slice boundaries

Included in the intended MVP:

- one technician using one iOS device;
- an app-private, durable append-only local case store;
- stable case and revision identity, optimistic revision checks, amendment reasons, and void history;
- manual intake, observations, measurements, DTC facts, notes, and bounded attachments;
- optional references to existing VHOS evidence without requiring a gateway;
- explicit fact, hypothesis, unknown, recommendation, and source/authority labels;
- deterministic report preview and checksum-verifiable offline export;
- explicit privacy/redaction controls; and
- local acceptance receipts sufficient to reproduce the tested case and report.

Excluded from the current slice:

- writes to or synchronization with the ADR-0004 Android maintenance ledger;
- cloud accounts, multi-tenant organizations, shared queues, remote backup, or remote analytics;
- canonical service-history import, requirement completion, or lifecycle baseline reset;
- autonomous diagnosis, authoritative AI findings, unsourced repair instructions, or parts/service
  interval lookup;
- arbitrary CAN transmission, new diagnostic allowlist entries, code clearing, active tests,
  actuation, ECU programming, or firmware/config activation;
- promotion of passive-CAN hypotheses or simulator/replay output into vehicle truth;
- customer payment processing, insurance adjudication, estimates/invoices, labor-time guides, parts
  ordering, shop-management-system integration, or regulatory certification; and
- a mechanic portal, Android technician UI, or generalized fleet synchronization.

## Technical acceptance matrix

`PASS` means the named behavior is covered by the checked-in automated suite. `PARTIAL` means a
useful subset is implemented and tested but the complete acceptance procedure has not passed.
`NOT RUN` and `NOT IMPLEMENTED` are explicit remaining gates.

| Area | Intended acceptance case | Pass evidence | Current status |
| --- | --- | --- | --- |
| Contract | Validate a complete case/revision, report receipt, and export manifest against new immutable versioned schemas. | Schema check plus positive interop example and semantic cross-reference test. | PARTIAL — the case schema/example and semantic checks pass; report artifacts use a versioned Swift manifest but do not yet have shared JSON Schemas. |
| Contract | Attempt to mark a technician draft as canonical maintenance history or an authorized vehicle finding. | Validation fails closed; no artifact or store mutation occurs. | PASS — schema constants and Swift semantic validation reject authority escalation. |
| Contract | Mix observation, hypothesis, recommendation, unknown, simulator/replay, and optional gateway evidence in one case. | Every item retains exact source, authority, quality, time, and evidence reference through render/export. | PARTIAL — typed technician/imported/gateway evidence and `SUPPORTS`/`CONTRADICTS`/`UNKNOWN` links exist; exact gateway bundle/version and simulator/replay provenance are not yet modeled. |
| Persistence | Create, amend, assess, report, and void a case across process restarts. | Current projection and complete revision/audit sequence reconstruct exactly with no in-place rewrite. | PARTIAL — complete close/reload and void/reload paths pass; one combined report-and-void restart fixture remains. |
| Persistence | Attach a photo/document, then revoke the transient provider URL. | App-private bytes still hash-match metadata and remain available or are explicitly marked missing. | PARTIAL — private copy, deduplication, and post-copy hash validation pass; provider-revocation UI testing is not run. |
| Offline/app-kill | In airplane mode, kill the app after each durable boundary in the five-screen flow and relaunch. | No committed data is lost or duplicated; no network dependency blocks intake, assessment, or report generation. | NOT RUN — the simulator exercises the network-independent workflow, but the physical airplane-mode/app-kill matrix remains. |
| Offline/app-kill | Kill during attachment copy, revision commit, report render, and final package publication. | Recovery is deterministic; incomplete work is not presented as committed or exported. | NOT RUN |
| Corrupt tail | Truncate each append-only ledger at every byte position in its final record. | Only a provably uncommitted tail is quarantined with exact bytes/receipt; committed prefix remains unchanged. | PARTIAL — a representative uncommitted tail is quarantined with a receipt; every-byte truncation coverage remains. |
| Corrupt tail | Corrupt an interior committed record or its index. | Store and report generation fail closed; UI does not present an empty/healthy case list. | PASS — committed-record corruption is terminal and the model exposes a blocking unavailable state. |
| Stale revision | Two editors open revision N; one commits N+1 and the other submits against N. | Second write receives a visible conflict and appends nothing until deliberately reconciled. | PASS |
| Export | Generate twice from the same fixed case revision and privacy selection. | Canonical case/report content and artifact hashes are reproducible; manifest covers every included file. | PASS — fixed revision, privacy selection, and generation time produce byte-identical report artifacts and manifest digests. |
| Export | Change, remove, add, rename, symlink, or path-traverse an exported artifact. | Verification rejects the package before display/import; no partial trust is granted. | NOT IMPLEMENTED — a package importer/verifier is outside this local generation slice. |
| Export | Exclude raw captures and attachments, then explicitly include selected items. | Manifest and report disclose the exact inclusion policy; excluded bytes are absent rather than hidden. | NOT IMPLEMENTED — reports inventory attachment references but do not package selected attachment bytes. |
| Privacy | Capture consent before storing optional customer contact, VIN, or plate data. | The case retains an explicit consent decision, scope, actor, and timestamp. | NOT IMPLEMENTED — the UI explains local handling and makes these fields optional, but no durable consent receipt exists. |
| Privacy | Exercise default, VIN/plate redaction, customer-detail redaction, location redaction, notes exclusion, and attachment inclusion. | Preview and exported bytes agree; a byte/content search finds no excluded sensitive value. | PARTIAL — customer contact, VIN, plate, and prior-work redaction defaults and explicit inclusion pass; location, per-note, and attachment-package controls remain. |
| Privacy | Share a package, then inspect the originating store. | Sharing creates a receipt but grants no recipient write authority and mutates no prior revision. | PARTIAL — generation is proven not to mutate the ledger and system sharing is available; a durable share-completion receipt remains. |

## Automated verification recorded for this slice

On 2026-09-07, the checked-in implementation passed:

- all 52 versioned JSON Schemas through `vhos contracts check`;
- all 217 Python tests, including the diagnostic-case example and semantic failure cases;
- all 227 `VHOSCore` Swift tests, including workflow, authority, stale-write, restart, corruption,
  tail-recovery, and no-resurrection coverage;
- a generic iOS Simulator build; and
- all 104 iOS application tests on an iPhone 17 Pro Max simulator, including the local five-screen
  model flow and report/attachment artifact tests.

These automated results are prerequisites, not substitutes for the unrun physical-device and paid
pilot gates.

## Required acceptance fixtures and receipts

Engineering schema examples must be explicitly labeled as examples and must never appear as real
vehicle observations. Technical acceptance should use an owner/technician-authorized, redacted real
case packet as soon as one is available. A passing receipt must record:

- source revision and Git commit;
- app, schema, renderer, and storage versions;
- device/simulator and operating-system version;
- test names, counts, outcome, and timestamp;
- airplane-mode and process-termination steps performed;
- case/revision IDs and canonical digests;
- report and manifest SHA-256 values;
- applied redaction profile;
- any quarantined-tail/conflict artifacts; and
- remaining physical, privacy, security, or commercial gates.

`vhos contracts check`, Python contract tests, Swift Core tests, and iOS Simulator app tests are
prerequisites for every change to this slice. The device-free field-return runner still does not
accept this feature until a technician-case/report gate is explicitly added to it.

## Paid-pilot research hypotheses

The following thresholds come from prior product research. They are hypotheses to test, not current
customers, usage, revenue, retention, performance, or acceptance claims.

| Hypothesis | Pilot test and threshold | Evidence required |
| --- | --- | --- |
| Recruitment access | Recruit 15 diagnostic specialists and 5 referring shops. | Dated outreach/recruitment ledger with consent status; duplicates excluded. |
| Real workflow coverage | Collect 10 owner/technician-authorized, redacted real case packets. | Ten distinct source receipts and privacy review; examples/simulator data do not count. |
| Willingness to pay and repeat use | At least 5 mechanics pay, and each records at least 3 distinct real cases. | Payment receipts plus case IDs; trials, team-member duplicates, and example cases do not count. |
| Handoff behavior | At least 50% of completed pilot cases generate a report that is actually shared. | Local generation and explicit share-completion receipts, collected with consent. |
| Retention | Week-4 active retention is at least 40% among activated paying mechanics. | Cohort definition fixed before measurement; active means at least one real case action in week 4. |
| Completion speed | Median intake-to-report time is no more than 10 minutes, with 8 minutes as the desired operating target. | Case-local start/report receipts; abandoned cases reported separately rather than removed. |
| Time savings | Median verified or participant-confirmed savings is at least 15 minutes per completed case against the technician's prior workflow. | Pre-pilot baseline method plus per-case comparison or same-week structured confirmation. |
| Technical reliability | Airplane-mode, app-kill, and restart testing produces no loss or duplication of committed case data. | Reproducible technical acceptance receipts from the matrix above and pilot incident log. |
| Unit economics | Contribution remains viable after binding data handling, privacy/compliance, support, payment, and insurance costs. | Cost model populated with actual pilot costs and a documented margin decision; excluded costs may not be treated as zero. |

Pilot measurement must not introduce silent telemetry or cloud synchronization that the MVP otherwise
excludes. Metrics may be collected through explicit, consented, redacted receipts and research
interviews until the separate tenant/security-reviewed cloud contract exists.

## Pivot and stop rules

- If technicians repeatedly use report generation and handoff but ignore structured hypothesis
  tracking, reposition the product around fast reporting/handoff instead of forcing an unused
  diagnostic-reasoning workflow.
- Stop the pilot or decline to expand the build if the team cannot obtain authorized real case data,
  paying repeat use, or credible time savings.
- Do not interpret recruitment interest, generated example reports, one-time trial use, or simulator
  runs as evidence of willingness to pay or repeat value.
- Do not widen authority, collect sensitive data silently, add cloud sync, or enable vehicle-control
  capabilities to rescue a failed commercial hypothesis.

## Exit gates for the slice

The local implementation slice is delivered, but the MVP is technically accepted for field use only
after every row in the technical acceptance matrix has a checked-in or otherwise durable passing
receipt and all regressions pass. It is commercially validated only after the paid-pilot hypotheses
meet their stated definitions and the unit-economics review includes binding compliance and
insurance costs.

A technical pass is not a commercial pass. A commercial signal is not permission to skip technical,
privacy, authority, or tenant-security gates.
