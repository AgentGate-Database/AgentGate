# ADR 0007 — Canonical content and hash

## Status

Accepted.

## Decision

Each revision stores one jsonb document and `content_hash = sha256` of that document's text. Postgres jsonb emits object keys in a stable order, so the hash does not depend on client key order. Change arrays keep request order. Integers, numerics, timestamps, and keys are canonical strings. Approval and rejection must present the active revision number and that hash.

A new revision is a new row. Older approvals remain as history and no longer match `active_revision_id`, which is what invalidates them. The PR row is locked `FOR UPDATE` for revision and review changes.

## Consequences

Clients display the hash the server returns. They do not hash a local copy unless they reproduce this canonical form. A proposal with no read tokens stores an empty `dependencies` array. A proposal with tokens stores those frozen rows, sorted by schema, table, and key text, in that array.
