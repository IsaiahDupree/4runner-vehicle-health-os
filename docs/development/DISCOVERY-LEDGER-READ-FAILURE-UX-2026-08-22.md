# Discovery ledger read-failure UX

Date: 2026-08-22

## Incident

The Park/selector test runner displayed an actionable **Begin Session** button while the global
error banner reported that `test-run-drafts.ndjson` was invalid at line 1. The underlying evidence
store correctly failed closed, but the presentation layer represented an unreadable ledger as an
empty ledger. Repeated attempts could not succeed and the screen did not explain whether retained
bytes had been changed.

## Required behavior

The iPhone now tracks the test-run ledger and marker ledger independently:

- **AVAILABLE** means every committed record decoded and passed domain/lineage validation.
- **UNAVAILABLE** means the corresponding in-memory collection is not authoritative or empty; it
  is unknown because the ledger could not be read.
- Begin, marker append, and normal End operations require both ledgers to be available.
- Abort requires the test-run ledger and its capture binding, but does not require a readable marker
  ledger. This keeps a recoverable active draft from deadlocking when marker review fails.
- Retry performs another read only. It does not delete, skip, rewrite, migrate, or infer a committed
  record.
- A committed invalid record remains fail-closed. Automatic interrupted-tail recovery remains the
  only rewrite path and preserves the exact uncommitted tail in quarantine before retaining the
  exact committed prefix.

The test runner and Capture/Replay review show both ledger states and the concrete read errors.
They must never say “no retained drafts” or “no retained markers” when the corresponding ledger is
unavailable.

## Regression coverage

App-level codec and store tests should pin these cases:

1. Exact snake-case lines emitted by the pre-fix app decode without changing one byte.
2. Capture bindings, test-run drafts, and stored markers round-trip all acronym-bearing keys.
3. A marker-ledger failure still permits aborting a valid active run, and the abort appends a
   terminal snapshot without changing the original prefix.
4. Begin, marker append, and End remain disabled and rejected at the model boundary while either
   required ledger is unavailable.
5. Malformed or unsupported committed records remain byte-identical after a failed read.
6. Interrupted uncommitted tails remain byte-identical in quarantine while the source retains its
   exact committed prefix.

This recovery status carries no vehicle authority and cannot infer Park, unlock OTA, or authorize
diagnostic transmission.
