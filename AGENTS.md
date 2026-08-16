# Repository agent rules

Read the PRD in `docs/prd/` and the accepted ADRs before changing domain contracts.

## Non-negotiable invariants

- Do not invent Toyota PIDs, service intervals, thresholds, part numbers, trim applicability, or signal scaling.
- Do not add arbitrary CAN transmit APIs. Diagnostic requests must reference a gateway-resident allowlist entry.
- Do not silently mutate service, inspection, lifecycle, calculation, equation, configuration, or audit history.
- Do not present simulator values as vehicle observations. Simulator sources use the `SIMULATOR` source kind and `sim.*` signal namespace.
- Do not ship mock providers, fake production returns, TODO stubs, or hardcoded production data.
- Keep raw evidence and exact version references sufficient for deterministic replay.
- Preserve unit, quality, freshness, applicability, and validation status at every derivation boundary.

## Verification

Run before committing:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e './tooling[test]'
.venv/bin/vhos contracts check
.venv/bin/python -m pytest
```

For changes to capture or replay behavior, also generate and validate a fresh bundle:

```bash
.venv/bin/vhos simulate --scenario cold-start-idle --output build/captures/cold-start-idle
.venv/bin/vhos validate-bundle build/captures/cold-start-idle
.venv/bin/vhos replay build/captures/cold-start-idle
```
