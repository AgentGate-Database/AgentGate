# ADR 0002 — Private schema in the business database

## Status

Accepted.

## Decision

AgentGate installs a private `agentgate` schema in the same database as the business tables. Proposals, decisions, audit rows, and later execution receipts commit in that database. There is no second database holding a copy of PR state.

If a legacy `data_pr` schema is present and `agentgate` is not, migration `0000` renames it. If both exist, installation fails. It does not merge them.

## Consequences

A backup of the business database includes PR history. The schema must stay out of customer-facing API catalogs, including Supabase exposed schemas. The migration revokes usage from `PUBLIC` and, when present, from `anon`, `authenticated`, and `service_role`.
