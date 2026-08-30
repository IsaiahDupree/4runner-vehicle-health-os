# ADR-0004: Android owns the canonical in-vehicle maintenance ledger

- Status: Accepted
- Date: 2026-08-30
- Owners: Vehicle lifecycle, Android head unit, iOS companion
- Clarifies: ADR-0003 for maintenance and lifecycle records

## Context

ADR-0003 keeps the iPhone as the first mobile control surface for gateway commissioning, capture,
OTA, and evidence handoff. The Android head unit is the persistent computer installed in the
vehicle. It already owns a Keystore-protected SQLCipher database containing raw evidence, vehicle
profile revisions, and health projections.

Maintenance history has a different durability requirement from a transient mobile control
session: service, inspection, repair, replacement, parts, fluids, measurements, receipts,
warranties, and lifecycle baselines must remain available in the vehicle for years and must not be
silently rewritten by whichever client connected most recently.

## Decision

The Android head unit owns the canonical local maintenance ledger for the vehicle. It stores the
ledger in the existing encrypted VHOS database and exposes ordinary create, read, update, and delete
controls through Garage mode with these history-preserving meanings:

- **Create** appends the first immutable revision of a vehicle, component, or maintenance record.
- **Read** uses rebuildable current-state projections and can always open the complete revision and
  audit history.
- **Update** appends a revision that names the exact revision it supersedes.
- **Delete** appends a void/tombstone revision with an actor, time, and reason. Acknowledged history
  is not physically deleted by normal product UI.

The base model is vehicle-agnostic and supports more than one vehicle. Make/model/year-specific
vehicle packs add sourced applicability, terminology, parts, capacities, and maintenance rules;
they do not change the generic ledger or hard-code schedule rules into UI code.

Persisted lifecycle identities follow ADR-0002 typed ULIDs. Generic vehicle configuration is
versioned with the asset revision; severe-use predicates remain separate tri-state facts; and an
active vehicle-pack link names the exact matched vehicle revision and reviewed source-manifest
digest. Component installation and retirement use a separate append-only lifecycle contract.

The existing 2005 4Runner profile and raw-evidence scope remain immutable. A generic vehicle asset
may link to that profile but may not replace or rewrite its identity.

## iOS companion authority

The iPhone may display an encrypted replicated read model and create pending maintenance mutations.
Until a versioned cross-device maintenance-sync contract is implemented, those mutations are
drafts. Android validates and commits a mutation, then returns the canonical revision and audit
receipt. The iPhone does not independently overwrite Android history.

This division does not reduce the iPhone's gateway-control authority from ADR-0003. It establishes
one writer for long-lived owner lifecycle truth while the portable sync contract is incomplete.

## Storage and attachments

- Queryable record metadata and canonical JSON revisions live in the existing SQLCipher database.
- Receipts, photographs, and documents use content-addressed app-private objects; the database
  stores their digest, media type, byte count, original name, and entity links.
- A transient external content URI is never the sole durable copy of an attachment.
- Raw CAN/capture evidence remains in its existing evidence stores and is referenced by stable IDs;
  it is not embedded into a maintenance row.
- Owner-controlled export/import is required before the ledger can claim off-device recoverability.

## Data authority

An official schedule or part/capacity value is activated only from a source-versioned vehicle pack
whose applicability matches the resolved vehicle configuration. User-entered custom records remain
valid owner history without being promoted to official schedule truth. Custom fields are typed and
versioned so they remain searchable, unit-aware, and deterministically exportable.

Occurrence precision is explicit: calendar-date evidence is not assigned an invented instant.
Unknown system/component references are represented as `UNKNOWN`, not guessed. A record may clear
an OEM due item only when it binds the exact versioned requirement, task, rule digest, source
manifest, and due and/or baseline identity.

## Consequences

- Android database migrations must remain additive and preserve all prior evidence.
- UI edits require optimistic revision checks; stale clients create a visible conflict instead of
  silently overwriting a newer record.
- Current maintenance status is a projection, never the historical source of truth.
- The digital-twin export requires a new version or separate maintenance bundle; the existing
  `vehicle.digital-twin.snapshot@1.0.0` schema remains immutable.
- Cross-device maintenance sync, encrypted attachment export, and iOS Garage UI are subsequent
  milestones built on the shared ledger contracts.
