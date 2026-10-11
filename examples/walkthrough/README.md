# Walkthrough illustration

`index.html` is a static four-panel story for a new viewer. The buttons advance a fixed invoice script. The page does not call the API, start MCP, or read Postgres. Open the file directly, or, after this repository is published and Pages is enabled, use `https://<agentgate-org>.github.io/agentgate/`.

The live path is the Docker demo:

```bash
docker compose -f compose.demo.yml --profile demo up --build
```

That dashboard is `http://127.0.0.1:8090`.
