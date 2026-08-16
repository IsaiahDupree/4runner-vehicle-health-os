# ADR-0002: Versioning, identities, and lineage

- Status: Accepted
- Date: 2026-08-16

## Stable identities

Persisted domain objects use typed ULID-shaped identifiers: `<type>_<26 Crockford Base32 characters>`. Prefixes make accidental cross-entity references visible while the 128-bit body remains time-sortable. Deterministic simulator IDs use the same shape but derive entropy from the scenario seed.

An identity is never reused for a corrected record. Corrections and recalculations receive new IDs and link to the superseded/original object.

## Contract versions

Serialized contracts carry both a semantic contract name and semantic version. Version rules are:

- major: incompatible field meaning/removal or wire break;
- minor: backward-compatible additive fields or enum values under tolerant readers;
- patch: clarification or stricter validation that does not change valid serialized meaning.

Schemas are immutable once released. A changed schema is stored beside its predecessor. Capture manifests record every relevant contract, app, gateway, configuration, signal-pack, and equation version.

## Evidence lineage

Every derived object stores exact references rather than querying “latest” data during explanation:

`RawObservation -> SignalSample -> FeatureValue -> CalculationRun -> DerivedMetric/Finding -> Recommendation -> MaintenanceEvent -> BaselineReset`

The E0 contracts establish raw observations, samples, equation definitions, and calculation runs. Later layers may materialize latest-state projections, but projections never replace source history.

## Equation representation

Equations use `vhos-expression-1`, a declarative JSON AST rather than embedded arbitrary code or unversioned UI logic. Inputs are typed and unit-constrained; constants include provenance and applicability; outputs state their truth boundary. A changed AST creates a new immutable equation version.
