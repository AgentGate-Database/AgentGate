# ADR 0009 — Supabase compatibility constraints

## Status

Accepted.

## Decision

Supabase is an integration target and a partnership is a possible later outcome. The core still runs on unmodified Postgres and must not imply partner status.

These constraints are part of the first milestone because they are expensive to retrofit:

1. Timeouts are applied with `set_config(name, value, true)` inside the transaction (`SET LOCAL` semantics). The C++ client does not issue session-level `SET` and does not call libpqxx named `prepare`. Parameters go through `exec` with `pqxx::params`, which uses an unnamed parameterized query.
2. SQL stays within Postgres 15. CI and Compose can run `postgres:15` and `postgres:17`.
3. Role creation is a separate migration. The migrator is granted membership in `agentgate_owner` before later files `SET ROLE` and create objects owned by that role. This is the shape a non-superuser Supabase `postgres` role needs, together with `CREATEROLE` and `ALTER` rights on tables it enrolls.
4. When `anon`, `authenticated`, or `service_role` exist, the `agentgate` schema is revoked from them.
5. `principals` stores nullable `external_issuer` and `external_subject` for a future JWT adapter. Bearer tokens are the only login in this milestone.

## Consequences

A transaction-mode pooler such as Supavisor can front the API connection. Session variables and named prepared statements will not be introduced casually. Partnership language stays out of the README until a partnership exists.
