# Vehicle Signal and Configuration Packs

This directory is empty of target-vehicle constants by design. A 2005 4Runner pack is not accepted until engine/drivetrain/trim applicability and each signal's source, transform, unit, range, cadence, and provenance are verified.

## Promotion path

1. Record a versioned capture on the target vehicle.
2. Identify a candidate source/byte layout without active probing where possible.
3. Corroborate it against an independent scan tool, instrument, physical measurement, or labeled behavior.
4. Add a `signal.definition@1.0.0` record with provenance and `EXPERIMENTAL` status.
5. Pin expected decoding in a golden replay test.
6. Test missing, malformed, stale, and out-of-range behavior.
7. Promote validation status only with recorded evidence.

Schedule intervals and applicability require verified Toyota owner/service information for the resolved vehicle profile. They must never be inferred from generic web guidance or encoded only in UI code.
