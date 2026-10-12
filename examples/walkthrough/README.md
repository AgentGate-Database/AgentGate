# Walkthrough illustration

`index.html` plays a four-panel simulation by itself. Agents issue human requests, AgentGate and the company dashboard show those requests, and the customer table changes only after an approval. The page does not call the API, start MCP, or read Postgres. Open the file directly, or use [https://agentgate-database.github.io/AgentGate/](https://agentgate-database.github.io/AgentGate/).

The live path is the Docker demo:

```bash
docker compose -f compose.demo.yml --profile demo up --build
```

That dashboard is `http://127.0.0.1:8090`.
