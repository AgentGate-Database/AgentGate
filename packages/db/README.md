# Database package

Migrations in `migrations/` are applied in filename order by `migrate.sh`, each in one transaction. `agentgate.schema_migrations` records applied versions. `0000` renames a legacy `data_pr` schema when `agentgate` is absent, and fails if both schemas exist.

## Roles

| Role | Purpose |
| --- | --- |
| `agentgate_owner` | `NOLOGIN` owner of functions and metadata. Not superuser. No `BYPASSRLS`. |
| `agentgate_migrator` | Install, enroll, issue credentials, assign reviewers. |
| `agentgate_api` | Execute proposal and review functions only. |
| `agentgate_worker` | Execute `expire_prs` only in this milestone. |

`0001_roles.sql` is safe to read on its own. A non-superuser migrator (the Supabase `postgres` role) needs `CREATEROLE` and membership in `agentgate_owner`, which the script grants to `CURRENT_USER`. Later files `SET ROLE agentgate_owner` before creating objects. The migrator must already be able to `ALTER` business tables it enrolls; `enroll_table` is security invoker for that DDL and security-definer functions do the metadata writes that the API is not allowed to do directly.

Passwords come from psql variables, not from SQL literals in the migration files:

```bash
AGENTGATE_API_PASSWORD=... \
AGENTGATE_WORKER_PASSWORD=... \
AGENTGATE_MIGRATOR_PASSWORD=... \
PGPASSWORD=postgres \
  packages/db/migrate.sh
```

Set `AGENTGATE_SEED=true` to load synthetic invoices and the negative enrollment fixtures.

The `agentgate` schema is revoked from `PUBLIC` and, when those roles exist, from `anon`, `authenticated`, and `service_role`. Do not add it to Supabase exposed schemas. `agentgate_revision` will show up in `SELECT *` and PostgREST responses for enrolled tables; see `docs/supported-schema.md`.
