# AI evidence handoff

The iPhone exports a provider-neutral, read-only handoff before any direct AI-provider integration.

## Package contents

- vehicle-profile snapshot with optional VIN/location redaction;
- discovery experiment definition and user approval;
- gateway hardware/firmware/config/capability versions;
- capture manifest and integrity hashes;
- gateway-health and protocol-scoring summaries;
- decoded samples/features only when their registry/version/provenance are included;
- explicit evidence gaps and validation status;
- optional raw capture segments selected by the user.

## Agent response contract

The agent returns claims with claim type, confidence, hypothesis flag, and internal evidence references. A proposed next experiment is a reviewable semantic diff over candidate protocol, bounded window, labels, and existing allowlist entry IDs.

The agent cannot return or activate arbitrary frame bytes, add an allowlist entry, change an equation/configuration silently, install firmware, or amend permanent history. Unsupported statements remain general guidance or a visible hypothesis.
