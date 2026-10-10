# Supabase example

This milestone does not include the tested Supabase walkthrough. AgentGate already runs on standard Postgres 15 and 17, including through a transaction-mode pooler.

When you point it at Supabase later:

- Apply `packages/db` with the project's `postgres` role. That role is not a full superuser; `0001_roles.sql` grants it membership in `agentgate_owner`.
- Keep the `agentgate` schema out of exposed Data API schemas. The migration revokes it from `anon`, `authenticated`, and `service_role` when those roles exist.
- Do not put a service-role key in an agent. A publishable key is not a reviewer credential.
- Use the pooler in transaction mode. The API sets timeouts with `SET LOCAL` and does not use named prepared statements.
- Expect `agentgate_revision` in PostgREST `SELECT *` responses after enrollment. See `docs/supported-schema.md`.

No Supabase partnership is required, and this repository does not claim one.
