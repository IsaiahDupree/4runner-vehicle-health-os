# Maintenance rule packs

Maintenance rule packs are immutable, source-qualified schedule facts. They
are not owner history and they are not stored in the mutable maintenance
ledger.

The runtime boundary is:

- `vehicle.asset` and `vehicle.maintenance-record` live in the encrypted local
  truth store;
- pack manifests and normalized rules ship as versioned, read-only assets or
  signed downloads;
- the active pack is selected only after its applicability predicates match a
  confirmed vehicle configuration; and
- pack-derived due state stays distinct from owner-entered completion history,
  inspection results, measurements, and inferred health.

`drafts/` contains source receipts and unactivated extraction work. A draft
must not generate a due date. The source-manifest contract makes promotion gates executable:
source/hash verification, complete locator and applicability review, legal/reuse approval for
normalized facts, independent review, regression tests, a signed pack digest, and reviewers.

Do not commit OEM PDF bytes, copied prose, images, logos, or undocumented bulk
downloads. Retain canonical links, document identity and hash, page/section
locators, and normalized facts.
