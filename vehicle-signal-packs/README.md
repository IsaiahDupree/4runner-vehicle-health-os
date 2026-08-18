# Vehicle Signal and Configuration Packs

This directory contains research hypotheses but no accepted target-vehicle constants. A 2005
4Runner signal is not accepted until engine/drivetrain/trim applicability and its source,
transform, unit, range, cadence, and provenance are verified.

Internet and reference research is tracked in
[`research-source-registry.v1.json`](research-source-registry.v1.json) and the accompanying
[`2005-4RUNNER-CAN-SOURCE-AUDIT-2026-08-18.md`](../docs/development/2005-4RUNNER-CAN-SOURCE-AUDIT-2026-08-18.md).
Those records are AI-readable discovery inputs, not accepted signal definitions.

The versioned discovery pack is
[`toyota-4runner-2005-passive-can-hypotheses.v1.json`](toyota-4runner-2005-passive-can-hypotheses.v1.json).
It records exact byte-field hypotheses, source revisions, competing transforms, limitations, and
the experiment required to accept or reject each candidate. Its contract forbids production
display and automatic promotion.

Evaluate every checked-in target capture without assigning a vehicle meaning:

```bash
.venv/bin/vhos evaluate-can-hypotheses \
  test-replay/real-can-2026-08-18/sessions \
  --output /tmp/can-signal-hypotheses.report.json
```

The pinned evaluation of all 5,176 retained records is
[`can-signal-hypotheses-2026-08-18-5176.report.json`](../docs/evidence/can-signal-hypotheses-2026-08-18-5176.report.json).
It remains `DISCOVERY_ONLY` with zero accepted signal definitions.

## Promotion path

1. Record a versioned capture on the target vehicle.
2. Identify a candidate source/byte layout without active probing where possible.
3. Corroborate it against an independent scan tool, instrument, physical measurement, or labeled behavior.
4. Add a `signal.definition@1.0.0` record with provenance and `EXPERIMENTAL` status.
5. Pin expected decoding in a golden replay test.
6. Test missing, malformed, stale, and out-of-range behavior.
7. Promote validation status only with recorded evidence.

Schedule intervals and applicability require verified Toyota owner/service information for the resolved vehicle profile. They must never be inferred from generic web guidance or encoded only in UI code.
