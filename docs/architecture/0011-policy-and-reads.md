# ADR 0011 — Policy precedence and tracked reads

## Status

Accepted.

## Decision

The latest immutable policy document decides each proposal. `block` dominates `manual_review_required`, which dominates `auto_approved`. A rule applies only when its schema, table, operation, and column constraints match. When several rules match one change, the strictest effect wins. A proposal with no matching rule uses the document default. Mixed changes use the strictest effect in the proposal.

`auto_approved` stores the proposal as `approved` with no human approval. Merge re-evaluates that revision against the same document and skips the reviewer lookup only while the result is still `auto_approved`. Any newer policy version blocks merge.

`POST /v1/reads` returns an opaque `agr_<id>_<secret>` token. The database stores the SHA-256 digest of the secret, the principal, the expiry, and each row's revision and before-image. Proposal creation accepts only an unexpired token for the same principal and copies those rows into the revision. Merge locks dependency rows with the write targets, ordered by schema, table, and key text, and compares the frozen image before writing. A changed or missing dependency aborts the whole proposal.

Merge reserves a per-principal rolling row and request count on one locked counter row before it writes. The reservation commits only with the receipt. A limit failure returns the proposal to `approved` so the same revision can be queued again. Drift, schema, and policy failures stay terminal.

## Consequences

Invoice changes stay on the default manual review, so the demo still has a separate approval step. Profile updates that stay inside the published column and row limits can merge without a reviewer. The read token is a secret and is not returned again after the read response.
