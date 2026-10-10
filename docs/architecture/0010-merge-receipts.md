# ADR 0010 — Merge receipts

## Status

Accepted.

## Decision

A merge is queued by `enqueue_merge` and applied by a worker inside one transaction. The unique row in `merge_receipts` for `(pr_id, revision_id)` is the only proof that the business rows committed. A lease on `merge_jobs` is not evidence of a commit: if the worker crashes before commit, the lease expires and another worker may claim the same job.

`merge_pr` is idempotent. When a receipt already exists, a later call completes the job and returns that receipt without writing the business rows again. `record_merge_failure` does the same if a receipt appeared after a rollback, and it never writes `pr.merged`.

The successful transaction also inserts `pr.merged` into `audit_events` and `outbox_events`. The outbox payload names the proposal, revision, content hash, and receipt. It does not copy row values. Nothing in this milestone delivers the outbox.

## Consequences

Queue acceptance returns HTTP 202. Clients treat the proposal as merged only after a later read shows the receipt. A lost response after commit is recovered by calling merge again or by reading the proposal: both return the original receipt.
