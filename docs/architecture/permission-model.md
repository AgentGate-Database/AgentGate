# Permission model

The HTTP API is the trust boundary for principals. Database roles are the trust boundary for process credentials. An agent that still has a direct Postgres password, a Supabase service-role key, or a permissive RPC can bypass AgentGate. Operators remove those credentials. AgentGate does not claim to stop a database administrator.

## Principals

| Kind | Can |
| --- | --- |
| `proposer` | Create tracked reads and propose updates on scoped tables and tenants. Read their own authorized PRs. Request merge of an approved PR. Propose a revert of their own merged receipt. Cannot approve. |
| `reviewer` | Approve or reject the active revision when assigned to every table in it. Cannot approve a PR they proposed. |
| `admin` | Propose on enrolled tables, view PRs, and register webhooks. Cannot approve unless the principal is a reviewer, which is a separate kind. |
| `worker` | No HTTP principal. The worker database role claims merge jobs, merges, expires proposals, and delivers webhooks. |

Scopes are server-side JSON on `agentgate.principals`:

```json
{"tables":[{"schema":"public","name":"invoices","tenants":["acme"]}]}
```

`reviewer_assignments` maps a reviewer principal to an enrolled table. Callers cannot send a reviewer id. `agentgate.assign_reviewer` is migration-role only.

`external_issuer` and `external_subject` are reserved for a later verified-identity adapter (for example Supabase Auth). They are unused by bearer authentication. No JWT is accepted.

The MCP adapter is a stdio client of the HTTP API. It sends the caller's bearer token and adds no database role. A proposer token presented to MCP still cannot approve, because the HTTP API rejects that call. The agent-facing tool list is `read_rows`, `propose_change`, `get_pr`, `get_pr_diff`, `list_prs`, and `get_pr_status`. Approve, reject, policy, webhook, and credential tools are not registered.

## Database roles

| Role | Login | Rights |
| --- | --- | --- |
| `agentgate_owner` | no | Owns functions and metadata. Not superuser. Not `BYPASSRLS`. |
| `agentgate_migrator` | yes | `enroll_table`, `issue_credential`, `assign_reviewer`. |
| `agentgate_api` | yes | Authenticate, propose, review, tracked reads, revert, webhook registration, and merge enqueue. No table DML. |
| `agentgate_worker` | yes | `expire_prs`, `claim_merge_job`, `merge_pr`, and webhook delivery. No approve. No direct business-table DML; merge runs as the owner of the security-definer function. |

Metadata tables have no privileges for the API or worker roles. Security-definer functions owned by `agentgate_owner` perform the writes. `enroll_table` is security invoker so the migration role's existing right to `ALTER` the business table is what adds the revision column. During enrollment the function grants `SELECT` and `UPDATE` on that table to `agentgate_owner` for the later merge function, and revokes the same table from `agentgate_api` and `agentgate_worker`.

The revision trigger function is executable by table writers. PostgreSQL requires `EXECUTE` on a trigger function for the updating role. It only assigns `OLD.revision + 1`.

## Authorization results

- Unknown, revoked, or mismatched credentials: `401 UNAUTHORIZED`. The response does not say which of those it was.
- Proposer calling approve, or a reviewer without an assignment: `403 FORBIDDEN`.
- Diff or PR fetch outside the caller's scope: `404 NOT_FOUND` with no row values.
- Worker role executing `approve`: permission denied at the database (`42501`), which the API maps to `403` if it is reached through SQL.

Approval stores the reviewer principal taken from the verified credential. A `reviewer_id` field in the body is ignored.
