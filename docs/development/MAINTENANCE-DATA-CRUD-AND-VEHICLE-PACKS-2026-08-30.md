# Maintenance data, CRUD, and vehicle packs — 2026-08-30

## Outcome and boundary

VHOS maintenance is a generic multi-vehicle ledger backed by the encrypted
Android truth store. It is not a set of mutable reminder rows and it is not a
hard-coded 2005 4Runner schedule.

Three kinds of information stay separate:

1. **Vehicle and owner truth** — identity, odometer, configuration, service,
   repair, inspection, measurements, installed parts/fluids, cost, warranty,
   receipts, photographs, and notes.
2. **OEM schedule rules** — immutable, source-qualified Vehicle Pack facts with
   exact applicability predicates.
3. **Calculated presentation** — due/overdue forecasts and system status,
   recomputed from a pack, vehicle configuration, odometer/time, and a verified
   service baseline.

No history is represented as **History unknown—verify last service**, never as
"never serviced," "complete," or "healthy."

## Where data is saved

| Data | Android location | Mutation rule |
| --- | --- | --- |
| Vehicle asset revisions | Keystore-wrapped SQLCipher `vhos-evidence.db` | Append revision |
| Maintenance record revisions | Same encrypted database | Append; never overwrite |
| Maintenance audit events | Same encrypted database | Append only |
| Attachment metadata and hashes | Same encrypted database | Revision-bound |
| Receipt/photo/PDF bytes | App-private content-addressed object directory | Immutable object; metadata can mark missing |
| OEM rule packs | Versioned read-only app asset or signed download | Replace only by new signed version |
| Companion drafts | Future encrypted iOS outbox | Promote through conflict-checked Android import |

Android backup remains disabled. The existing 4Runner digital-twin profile is
retained as a pack-specific configuration record; it is linked to, not used as
a substitute for, the generic `vehicle.asset`.

## CRUD semantics

The user experience says Create, View, Edit and Void. The data model says:

- **Create** appends revision 1 and a `CREATED` audit event.
- **Read** returns the current revision plus the complete immutable history.
- **Edit** appends a successor with an explicit amendment reason and an
  `AMENDED` audit event.
- **Delete** is called **Void record** and appends a reasoned `VOIDED` successor
  plus a `VOIDED` audit event.

There is no physical row deletion and no in-place update of permanent history.
All writes are transactions and reject stale expected revisions so two screens
or future devices cannot silently overwrite each other.

## Generic data coverage

Each vehicle can record:

- display identity, year/make/model/trim, VIN, plate, distance unit and odometer;
- service, repair, inspection, replacement, fluid service, installation,
  removal, adjustment, diagnostic, or other events;
- one or more systems and component instances, including parent relationships;
- performed time, recorded time, mileage, engine hours, actor and provider;
- part, fluid, supply, labor, and other line items with manufacturer, part
  number, specification, quantity, unit, and money;
- numeric/text/Boolean physical measurements with units, method, and grade;
- warranty provider, start/end, distance limit, terms, and linked documents;
- receipt/photo/PDF metadata with MIME type, byte length and SHA-256;
- free notes; and
- bounded typed custom fields: text, decimal, integer, Boolean, date, instant,
  and choice, with units allowed only for numeric values.

Typed extension data is intentionally bounded and validated. Arbitrary JSON is
not stored inside query-critical columns.

## Android UX

The Maintenance Garage is a parked, owner-facing workspace:

1. Vehicle selector with **Add vehicle** and **Edit vehicle**.
2. Summary counts for active and voided records.
3. Search plus event-type and state filters.
4. Chronological record list showing type, title, performed date and odometer.
5. Detail pane for systems/components, provider, costs, parts/fluids,
   measurements, warranty, notes, custom values, and attachments.
6. Immutable revision timeline.
7. **Add record**, **Amend record**, and **Void record** actions.

Dialogs capture common fields first and reveal detail sections progressively.
The normal Garage view does not require users to understand revision IDs. The
history view makes the audit trail visible when they need it.

## Vehicle-pack source strategy

There is no authoritative universal maintenance schedule. Vehicle identity can
be enriched with NHTSA vPIC, but schedule authority comes from a reviewed OEM
publication for the exact market/configuration.

The first source receipt is stored at
`maintenance-rule-packs/drafts/toyota.4runner.2005/source-manifest.json`. It
references Toyota publication `05ToyAllMS_MS0001` and deliberately remains
inactive. Required review covers cadence/special-condition instructions on printed page 3, the
complete SUV/truck schedule and footnotes on printed pages 20–35, and maintenance-item
explanations on printed pages 36–39 (PDF pages 5 and 22–41).

Initial applicability gates include engine family, 2WD/4WD, limited-slip and
other equipment, emissions jurisdiction, production date, cabin-filter
equipment, towing, dirt/desert operation, salted-road operation, and a trusted
service baseline. For example, a 2UZ-FE timing-belt rule must never be assigned
to a 1GR-FE vehicle.

Every promoted rule retains publisher, publication title/number, canonical
URL, market/language, document SHA-256, retrieval time, printed page/section,
pack version, applicability expression, reviewer, review state and legal/reuse
state.

## Public-distribution constraint

Do not redistribute OEM PDF bytes, copied prose, images, or branding. Store
normalized facts and provenance, link to the canonical owner page, and obtain
permission/legal review before shipping a public/commercial rule pack. The
source manifest is a development receipt, not a license and not an active
schedule.

## Contracts

The cross-platform v1 contracts are:

- `vehicle.asset@1.0.0`
- `vehicle.maintenance-record@1.0.0`
- `vehicle.maintenance-audit-event@1.0.0`
- `vehicle.component-registry-entry@1.0.0`
- `vehicle.maintenance-requirement@1.0.0`
- `vehicle.maintenance-source-manifest@1.0.0`

They are independent of the immutable, 4Runner-specific
`vehicle.configuration-profile@1.0.0` contract. A future sync bundle will carry
vehicle assets, record revisions, audit events, and attachment manifests
without changing their meaning.

## Acceptance checks

- Migration preserves all existing encrypted evidence.
- A user can add multiple makes/models without seeded or mock records.
- Create, amend and void survive process restart.
- Current-list queries return only the newest record revision.
- History returns every revision in order.
- Stale amendments fail atomically.
- Vehicle/record/audit contracts validate across platforms.
- Empty history remains unknown.
- Rule-pack drafts cannot generate a due state.
- No maintenance action changes CAN listen-only behavior or gateway authority.
