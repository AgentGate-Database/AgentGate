# Demo dashboard

Four panels on one page: agent intent, AgentGate status, company review, and the invoice row in Postgres. The browser talks only to this proxy. The proxy holds the local proposer and reviewer tokens and calls the AgentGate HTTP API. Prepare reads invoice 482 through a tenant-scoped query. Approval does not change `payment_terms`. The business panel updates only after the worker commits a merge receipt.

```bash
export AGENTGATE_API_URL=http://127.0.0.1:8080
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/agentgate
export DEMO_SECRETS=/path/to/demo.env
pnpm --filter @agentgate/demo-dashboard start
```

`scripts/demo-credentials.sh` writes that secrets file with the issue-credential script. Compose profile `demo` runs the API, worker, credential script, and this proxy on loopback.
