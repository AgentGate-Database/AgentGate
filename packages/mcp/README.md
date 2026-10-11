# @agentgate/mcp

Stdio MCP adapter. It calls the C++ HTTP API through `@agentgate/sdk` with `AGENTGATE_API_URL` and `AGENTGATE_TOKEN`. It does not connect to Postgres and adds no database role.

Tools: `read_rows`, `propose_change`, `get_pr`, `get_pr_diff`, `list_prs`, `get_pr_status`. Approve, reject, policy, webhook, and credential tools are not registered.
