# Supabase compatibility example

AgentGate runs on standard Postgres. Supabase can host that Postgres. This directory checks the local constraints that make that install possible. It does not call hosted Supabase, and this project does not claim a Supabase partnership.

Supabase Auth JWT review is out of scope. `principals.external_issuer` and `principals.external_subject` stay unused. Bearer tokens remain the only login.

## Install

Apply `packages/db` with a role that can create roles. On Supabase that is the project `postgres` role, which is not a full superuser. `0001_roles.sql` grants that role membership in `agentgate_owner`, and later migrations create objects owned by `agentgate_owner`.

```bash
docker compose up -d db
docker compose run --rm migrate
```

Use the same migrator path against a Supabase database only from an operator machine. Do not put the migrator password, the `agentgate_api` password, or a service-role key in an agent.

## Scoped roles

| Role | Use |
| --- | --- |
| `agentgate_owner` | `NOLOGIN`. Owns the schema and security-definer functions. Not a superuser. Not `BYPASSRLS`. |
| `agentgate_migrator` | Installs migrations, enrolls tables, and issues credentials. Not a runtime credential. |
| `agentgate_api` | The API process. Executes proposal, review, read, revert, and webhook functions. No direct business-table DML. |
| `agentgate_worker` | The worker process. Expires proposals, merges, and delivers webhooks. Cannot approve. |

A publishable key is not a reviewer credential. Do not put a service-role key in an agent.

## Transaction-mode pooler

Point the API and worker at a transaction-mode pooler. The local profile is PgBouncer with `POOL_MODE=transaction`:

```bash
docker compose --profile pooler up -d pooler
```

The pooler listens on `127.0.0.1:6432`. The API sets timeouts with `set_config(..., true)` (`SET LOCAL`) and does not use named prepared statements. Session `SET` and named prepares are not compatible with transaction mode.

## Data API exclusion

Keep the private `agentgate` schema out of every exposed Data API schema list, including PostgREST `db-schemas` / `PGRST_DB_SCHEMAS` and the Supabase Data API exposed-schemas setting.

The migration already:

- revokes `USAGE` on schema `agentgate` from `PUBLIC`
- revokes the schema from `anon`, `authenticated`, and `service_role` when those roles exist
- comments the schema so an operator does not add it to an exposed schema list

After enrollment, `agentgate_revision` appears in `SELECT *` responses. See `docs/supported-schema.md`.

## Local check

`check-local.sh` connects through the Compose pooler profile and checks the constraints above. It refuses a remote database URL.

```bash
examples/supabase/check-local.sh
```
