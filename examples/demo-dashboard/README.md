# Demo dashboard

This is the live local demo. The static illustration, which does not call the API, is `examples/walkthrough/index.html`.

Four panels on one page: agent intent, AgentGate status, company review, and the invoice row in Postgres. The browser talks only to this proxy.

Prepare, send, and **Run sample agent** use a real MCP client. Show, approve, merge, and propose revert use the TypeScript SDK over HTTP. The reviewer token is used only for approve. Actors are the fixed demo proposer and demo reviewer.

The server starts only when `AGENTGATE_DEMO=1` and `DATABASE_URL` points at `localhost`, `127.0.0.1`, or the Compose hostname `db`. **Simulate another application changing this record** updates invoice 482 through that database connection, and only after approval and before merge.

```bash
docker compose -f compose.demo.yml --profile demo up --build
```

The dashboard is `http://127.0.0.1:8090`. `scripts/reset-demo.sh --yes` removes the `agentgate-demo` project and leaves the ordinary `agentgate` project in place.
