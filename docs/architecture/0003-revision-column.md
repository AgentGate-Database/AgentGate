# ADR 0003 — Revision column and trigger

## Status

Accepted.

## Decision

Enrollment adds `agentgate_revision bigint NOT NULL DEFAULT 1` and a `BEFORE UPDATE` trigger that sets the new value to the old value plus one. Timestamps are not the freshness check. Proposals store `expected_revision` and the server-read before-image.

The trigger ignores a writer that tries to set the column. Proposal `set` objects that name the column are rejected.

## Consequences

`SELECT *` and PostgREST responses gain a column. That is documented in `docs/supported-schema.md` and is an explicit enrollment side effect. Delete-and-reinsert of a primary key resets the counter; the before-image is the additional check, not a history proof.
