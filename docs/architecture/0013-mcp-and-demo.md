# ADR 0013 — MCP adapter and local demo

## Status

Accepted.

## Decision

The TypeScript SDK is a client of the existing HTTP API. It sends `Authorization` and, on mutations, `Idempotency-Key`. It parses the API error body. It does not open a database connection and does not reimplement policy or merge.

The MCP adapter speaks stdio through the official MCP TypeScript SDK. It reads `AGENTGATE_API_URL` and one bearer token from the environment and calls the SDK. It does not connect to Postgres. The registered tools are `read_rows`, `propose_change`, `get_pr`, `get_pr_diff`, `list_prs`, and `get_pr_status`. `read_rows` calls `POST /v1/reads`. `propose_change` calls `POST /v1/prs` and requires the tracked-read token from `read_rows`. `get_pr_status` returns the stored state and says when a pending, queued, or conflicted proposal has not committed a write. Approve, reject, policy, webhook, and credential tools are not registered. MCP adds no database role.

The demo proxy starts only when `AGENTGATE_DEMO=1` and the `DATABASE_URL` host is `localhost`, `127.0.0.1`, or the Compose hostname `db`. Sample-agent and drift routes are absent otherwise. Prepare, send, and **Run sample agent** use a real MCP client. Show, approve, merge, and propose revert use the SDK over HTTP. The reviewer token is used only for approve. The browser receives neither bearer token, database password, nor webhook secret.

**Simulate another application changing this record** is a demo-only update of invoice 482 through the demo's ordinary Postgres connection. It is allowed only after approval and before merge. That update bumps `agentgate_revision`. The following merge returns the real `conflicted` state, and the other application's value remains.

`compose.demo.yml` names the project `agentgate-demo` and includes the existing services. `scripts/reset-demo.sh --yes` runs `docker compose -f compose.demo.yml --profile demo down -v`. It does not target the `agentgate` project and does not run on startup.

Two proposals of the same change share the canonical change image, dependency image, and `policy_decision`. `content_hash` also covers `expires_at`, which is the wall-clock expiry, so two proposals created at different times do not share a hash.

## Consequences

The invoice walkthrough can approve without changing the business row, merge through a receipt, revert through a second receipt, and then show a real drift conflict. A proposer token sent to the HTTP API still receives `403` on approve.
