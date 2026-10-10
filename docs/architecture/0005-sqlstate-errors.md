# ADR 0005 — SQLSTATE error mapping

## Status

Accepted.

## Decision

PL/pgSQL raises application errors with `agentgate.raise_app`. The message is a JSON object `{"code","message","details"}` and the SQLSTATE is a stable five-character code:

| SQLSTATE | Code | HTTP |
| --- | --- | --- |
| `AG001` | `UNAUTHORIZED` | 401 |
| `AG002` | `FORBIDDEN` | 403 |
| `AG003` | `UNSUPPORTED_TABLE` | 422 |
| `AG004` | `UNSUPPORTED_OPERATION` | 422 |
| `AG005` | `POLICY_BLOCKED` | 422 |
| `AG006` | `REVISION_MISMATCH` | 409 |
| `AG007` | `PR_EXPIRED` | 409 |
| `AG008` | `DRIFT_CONFLICT` | 409 |
| `AG009` | `SCHEMA_CHANGED` | 409 |
| `AG010` | `IDEMPOTENCY_CONFLICT` | 409 |
| `AG011` | `LIMIT_EXCEEDED` | 429 |
| `AG012` | `CONSTRAINT_VIOLATION` | 422 |
| `AG013` | `VALIDATION_FAILED` | 422 |
| `AG014` | `NOT_FOUND` | 404 |

The C++ edge parses that JSON and returns the documented envelope. Unexpected database failures become `500` with code `INTERNAL` and no SQL text. Privilege failures (`42501`) become `403 FORBIDDEN`.

`AG008` and `AG009` are reserved for merge. They are not raised yet.

## Consequences

Clients branch on `error.code`, not on message text. New codes need a schema and ADR update rather than a free-form string.
