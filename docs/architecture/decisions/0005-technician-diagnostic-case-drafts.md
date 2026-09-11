# ADR-0005: iOS technician diagnostic cases are local commercial drafts

- Status: Accepted
- Date: 2026-09-07
- Owners: Technician workflow, iOS client, vehicle lifecycle, and export
- Relates to: ADR-0002, ADR-0003, and ADR-0004

## Context

ADR-0003 makes the iPhone the primary gateway commissioning, capture, OTA, and evidence-handoff
surface. ADR-0004 separately makes the installed Android head unit the only canonical writer for
long-lived vehicle maintenance and lifecycle history until a versioned cross-device synchronization
contract exists.

A commercial technician workflow needs to work before that synchronization layer and before every
vehicle has a VHOS gateway. A technician must be able to open a case, record the customer's concern,
add observations and measurements, preserve revisions, and produce a readable handoff report while
offline. Treating those records as canonical vehicle history would violate ADR-0004. Treating a
technician's draft diagnosis as a validated VHOS finding would also bypass the evidence, equation,
applicability, and confidence boundaries in the product requirements.

## Decision

An iOS technician device may create and retain durable, append-only diagnostic case revisions and
reports with authority classification `TECHNICIAN_LOCAL_DRAFT`.

That classification has a narrow positive meaning: it is authoritative evidence that the identified
technician recorded the represented statement, measurement, attachment, or hypothesis in the named
case revision. It does not by itself establish that the statement is a canonical fact about the
vehicle.

A `TECHNICIAN_LOCAL_DRAFT` case:

- is not canonical vehicle maintenance or lifecycle history;
- is not an authorized VHOS vehicle finding or health assessment;
- cannot satisfy an OEM maintenance requirement, close a due item, resolve a finding, or reset a
  lifecycle baseline;
- cannot create, amend, void, or otherwise mutate the ADR-0004 Android maintenance ledger;
- cannot promote a discovery candidate, signal definition, equation, threshold, service interval,
  part number, or configuration fact;
- cannot authorize a diagnostic request, firmware operation, code clear, active test, or vehicle
  control; and
- remains a draft after report generation, export, or acknowledgement by the customer.

The UI and every exported representation must preserve that authority boundary. A report title,
cover page, and machine-readable manifest must identify the material as a technician-authored local
draft. An observation, measurement, DTC fact, hypothesis, recommendation, and unavailable/unknown
state must remain distinguishable in both the case model and rendered report.

## Revision and persistence rules

Case content is revisioned, not updated in place. Each committed revision has a stable case identity,
its own revision identity, the exact predecessor identity or `null`, author identity, recorded time,
and a digest of its canonical representation. A correction appends a successor and records the
reason. A user-facing delete is a reasoned void/tombstone revision; normal product controls do not
physically erase acknowledged case history.

All attachments are copied into app-private content-addressed storage before a committed revision
may reference them. The revision retains media type, byte count, SHA-256, original display name,
availability, and case-local relationship. A transient photo-picker or document-provider URL is not
a durable source.

The store must reject stale expected revisions instead of silently overwriting a newer revision.
Committed-prefix corruption is terminal and fail-closed. Recovery may quarantine only a provably
uncommitted trailing write and must retain its exact bytes and recovery receipt.

The first concrete serialized contract, typed identity prefixes, and local append-only storage are
implemented by the 2026-09-07 iOS pilot slice. A 2026-09-10 integrity follow-up wraps every private
ledger row in a versioned envelope containing the exact canonical revision SHA-256 and the prior
revision digest for that case. Any schema evolution and migration sequence remain governed by
ADR-0002.

## Report and export boundary

A case report is a privacy-selected projection of one exact committed case revision. Report
generation does not change the case's authority. The export must include:

- a human-readable report that requires no VHOS account to open;
- a machine-readable report snapshot whose recorded source-revision digest binds it to the exact
  committed revision used to render it;
- referenced attachment and evidence inventory, with packaged attachment bytes permitted only by
  an explicit future inclusion control;
- app, case-contract, renderer, and relevant evidence-version identifiers;
- a manifest containing the path, media type, byte count, and SHA-256 of every included artifact;
- the applied privacy/redaction choices; and
- generation metadata in the manifest that binds the report bytes to the source-revision digest.

Raw high-volume captures, VIN, registration, customer contact details, precise location, and free-form
notes are excluded unless the technician deliberately includes the applicable class. Export does not
grant the recipient write authority over the originating store. Import, acknowledgement, countersign,
or promotion into canonical maintenance history requires a future contract and is outside this
decision. The current local slice does not export the unredacted raw revision or package referenced
attachment bytes. A shared report/manifest JSON Schema, package importer/verifier, explicit
raw-revision option, and attachment-selection control remain future work.

## Gateway and AI evidence

The existing VHOS gateway is an optional evidence source, not a prerequisite for case intake, case
persistence, or report generation. A case can consist entirely of technician-authored concern,
inspection, measurement, attachment, and hypothesis evidence.

Before gateway material can be treated as fully reproducible case evidence, a future provenance
contract must record the exact bundle/observation identity, hash, source kind,
firmware/configuration versions, quality, freshness, and authority. Simulator and replay sources must
retain their source labels. The current slice supports bounded gateway-reference fields but does not
yet model the complete bundle/version provenance set. Discovery candidates and recovered portable CAN
evidence remain non-authoritative. Gateway or transport degradation is not a vehicle fault.

AI is optional. AI-authored text remains an evidence-bound, non-authoritative claim and is visually
distinct from technician-authored material. AI cannot silently edit a case revision, approve a
diagnosis, mutate the Android ledger, or widen gateway authority.

## Future organization and cloud synchronization

Organization accounts, shared case queues, remote backup, countersignatures, and cloud synchronization
require a separate versioned synchronization contract and durable receipt. That work must receive a
tenant-isolation, authentication, authorization, key-management, retention/deletion, audit, incident
response, data-residency, and applicable security/privacy review before activation.

A cloud acknowledgement must never be inferred from an HTTP success alone, and a remote revision
must never overwrite a local or Android revision by last-write-wins. This ADR grants no current cloud
write authority and selects no cloud vendor.

## Consequences

- The technician workflow can be useful in airplane mode and without installed VHOS hardware.
- Commercial drafts and canonical owner history remain explicitly separate.
- A later Android import may validate and commit selected draft material, but must return new
  canonical revision and audit identities; it may not reuse the technician draft's authority.
- Existing evidence/export primitives may be reused only where their source and authority semantics
  remain intact.
- The immutable `vehicle.digital-twin.snapshot@1.0.0` contract is not extended for this feature. A
  case package uses a new contract/version.

## Delivery status

The 2026-09-07 implementation delivers the diagnostic-case schema/example, matching Swift Core
model, append-only local ledger, five-screen iOS workflow, bounded content-addressed attachment
store, and deterministic privacy-selected PDF/JSON plus versioned Swift manifest generation. The
JSON report snapshot records the exact source-revision digest; it is not an unredacted copy of the
stored revision. Automated contract, Core, app-model, persistence, corruption, and artifact tests
are recorded in `docs/development/MECHANIC-DIAGNOSTIC-CASE-MVP-2026-09-07.md`.

This ADR does not claim delivery of cloud/team synchronization, an export-package importer,
selected attachment packaging, Android maintenance import, customer authorization/payment flows,
licensed repair data, physical-device acceptance, or commercial validation.
