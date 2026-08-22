# AI evidence handoff

The iPhone exports a provider-neutral, read-only handoff before any direct AI-provider integration.

## Current delivery state

The package is generated on demand and exposed through the iOS share sheet. It is not currently
uploaded in the background, placed in a remote agent inbox, or claimed automatically by an AI
worker. The same boundary applies to the iPhone BLE flight-recorder export: the evidence is durable
and shareable, but owner action is still required to move it off the phone.

An AI process running from this repository can automatically read checked-in evidence, analysis
reports, and the machine-readable CAN research registry. It cannot directly read the iPhone app's
sandbox.

Automatic pickup requires a separately authorized evidence-outbox implementation with:

- an owner-selected private endpoint and explicit upload policy;
- authentication, encryption in transit, and server-side access control;
- immutable package identity, SHA-256 manifest verification, and idempotent retries;
- configurable VIN, location, timestamp, and raw-frame redaction;
- visible `QUEUED`, `UPLOADING`, `DELIVERED`, `CLAIMED`, and `FAILED` states;
- retention/deletion controls and an auditable agent claim record; and
- no path from an AI interpretation back to vehicle transmission or experiment activation.

The raw evidence outbox must not default to a public GitHub repository.

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
