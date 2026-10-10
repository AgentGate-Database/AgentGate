# Supported schema

Enrollment is explicit. Proposing a PR does not alter a business table. `agentgate.enroll_table` is the installation step, and it is granted to the migration role only.

## Accepted tables

- Ordinary tables (`relkind = 'r'`) in Postgres 15 or newer.
- Exactly one primary-key column of type `uuid`, `smallint`, `integer`, or `bigint`.
- Allowed columns whose types are in the scalar set below.
- An optional enrolled tenant column, which must itself be an allowed scalar column.

Enrollment rejects views, materialized views, foreign tables, partitioned tables, partitions, inheritance parents and children, tables with user-defined rules, tables with user-defined triggers other than `agentgate_bump_revision`, generated columns, composite primary keys, and unsupported column types. Rejection fails the enrollment call. AgentGate does not guess a diff for those tables.

## Scalar types

| Postgres type | JSON representation |
| --- | --- |
| `uuid` | string, lowercase canonical text |
| `int2`, `int4`, `int8` | string, so values above `2^53-1` survive JavaScript |
| `numeric` | string, `trim_scale` text |
| `text`, `varchar` | string |
| `bool` | boolean |
| `date` | string `YYYY-MM-DD` |
| `timestamptz` | string, UTC `YYYY-MM-DDTHH:MM:SS.USZ` |
| `jsonb` | object or array |

JSON numbers are rejected for integer, numeric, and key fields. `null` is a JSON null. Missing fields are not updated.

## Revision column

Enrollment adds `agentgate_revision bigint NOT NULL DEFAULT 1` when it is not already there, and installs the `BEFORE UPDATE` trigger `agentgate_bump_revision`. Existing rows start at revision 1. Every update, including ordinary application writes, increments the revision. The trigger overwrites any client-supplied value, so an application cannot reset the counter by setting the column.

Proposals cannot include `agentgate_revision` in `set`.

This column appears in `SELECT *`. PostgREST and any Supabase Data API exposure of the business table will return `agentgate_revision` to clients that do not list columns. Generated clients and inserts that name columns explicitly are unaffected. Inserts that rely on column order, or `SELECT *` consumers that bind by position, must be updated as part of enrollment. Enrollment is an operator action; it is not a side effect of `POST /v1/prs`.

The revision is row-local. Deleting a row and inserting the same primary key again starts a new row at revision 1. AgentGate also stores the before-image on the proposal. Matching a before-image does not prove that the row was never deleted.

## Schema fingerprint

`agentgate.schema_fingerprint(regclass)` hashes column name, type, nullability, primary-key membership, and generated flag. The registry stores the fingerprint from enrollment. A later `ALTER TABLE` changes the fingerprint. Merge, when it exists, will fail closed on a mismatch. This milestone records the fingerprint and exposes it on the proposal content; it does not yet compare it at merge time.

## `SELECT *` and Supabase

If a project uses Supabase, the Data API uses PostgREST. After enrollment, `agentgate_revision` is part of the REST row unless the API is configured with an explicit column list or a view that omits it. Do not add the `agentgate` schema to exposed schemas. The migration revokes `agentgate` usage from `anon`, `authenticated`, and `service_role` when those roles exist.
