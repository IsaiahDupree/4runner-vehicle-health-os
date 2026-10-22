# Whole-vehicle digital-twin foundation — 2026-08-18

## Governing product decision

VHOS is a whole-vehicle digital twin. OBD/CAN, added sensors, schedules, inspections, repair history,
receipts, photographs, parts, warranties, and owner measurements are evidence sources for the twin;
none is the product by itself.

A condition must retain one of six evidence bases:

1. directly measured;
2. calculated from versioned inputs and equations;
3. schedule-derived from a sourced vehicle pack;
4. inspection-derived;
5. inferred and explicitly confidence-bounded; or
6. unknown/unverified.

No trouble codes is not evidence that brakes, suspension, tires, belts, seals, rust, or any other
physical system is healthy.

## Contracts added

| Contract | Purpose |
| --- | --- |
| `platform.head-unit-inventory@1.0.0` | Exact Android hardware, OS, display, capacity, BLE, permission, install, and power facts |
| `vehicle.configuration-profile@1.0.0` | Append-only 2005 4Runner identity and applicability revision |
| `vehicle.health-assessment@1.0.0` | Evidence-qualified state for one physical system |
| `vehicle.digital-twin.snapshot@1.0.0` | Complete portable current view for owner export and future iOS merge |

The first pack is identified as `toyota.4runner.2005@0.1.0`. It deliberately refuses schedule
readiness while VIN, engine, drivetrain, suspension, trim, build date, tires, severe-use selection,
modification status, or mileage remain unknown. The engine field deterministically produces
`TIMING_CHAIN` for the 4.0L V6 and
`TIMING_BELT` for the 4.7L V8; inconsistent profiles fail validation.

## Android slice

The Android head unit now:

- inventories the real device instead of relying on photographs or assumptions;
- persists de-duplicated inventory revisions;
- collects the first vehicle-profile revision through an owner form;
- appends every later profile revision with an explicit predecessor;
- creates a complete 22-system unknown health baseline;
- requires evidence before accepting any non-unknown assessment;
- resets the current view conservatively to an unknown baseline after a configuration revision while
  preserving all earlier records; and
- exports a versioned JSON snapshot through the system document picker.

The existing validated BLE frames and CAN observations remain append-only evidence. They are not
automatically converted into health conclusions merely because they are present.

## Security boundary

Android backup is disabled and files remain inside the app sandbox by default. The SQLite database
is not yet page-encrypted. The head-unit UI now reports that limitation instead of marking storage
fully complete. A Keystore-wrapped encrypted database migration is the next required storage gate
before owner documents, VIN-linked service history, receipts, or photographs are persisted.

## Next implementation sequence

1. Keystore-wrapped encrypted local storage and a verified non-destructive migration.
2. Append-only service, inspection, part, receipt, photograph, warranty, and manual-measurement
   records.
3. Official-source/versioned Toyota maintenance rules selected by the configuration profile.
4. Calculation Run records connecting raw evidence to decoded signals, equations, findings, and
   recommendations.
5. iOS export/import conflict rules for the new digital-twin contracts.
6. Mechanic-ready report rendering with unknowns and evidence provenance retained.
