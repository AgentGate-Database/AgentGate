# Development

Native build, tests, credentials, the HTTP API, the repository map, and current limitations. The product overview and the Docker quickstart are in the [README](../README.md).

## Native build

Homebrew path, used by the maintainer on macOS:

```bash
brew install ninja cmake libpq libpqxx drogon catch2 nlohmann-json openssl
cmake --preset brew-debug
cmake --build --preset brew-debug
```

The JSON Schema validator is fetched at configure time when it is not already installed. The vcpkg manifest (`vcpkg.json`, baseline in `vcpkg-configuration.json`) is the path Docker and CI use:

```bash
export VCPKG_ROOT=/path/to/vcpkg
cmake --preset ci-linux
cmake --build --preset ci-linux
```

Other presets: `dev-debug`, `dev-release`, `asan-ubsan`, `ci-asan`. `dev-*` and `ci-*` expect `VCPKG_ROOT`. `asan-ubsan` matches the Homebrew prefix. `ci-asan` is the Linux sanitizer build. Both sanitizer presets enable AddressSanitizer and UndefinedBehaviorSanitizer. The Homebrew preset also searches the keg-only `libpq` prefix.

## Tests

Start the disposable database and apply migrations first:

```bash
docker compose up -d db
docker compose run --rm migrate
cmake --build --preset brew-debug
ctest --preset brew-debug --output-on-failure
```

`ctest` expects the Compose database on `127.0.0.1:5432`. Integration tests are skipped when `AGENTGATE_TEST_DATABASE_URL` is unset. The `brew-debug` test preset sets the local URLs.

Node tests cover the SDK paths, the MCP tool list, and the demo guard. The HTTP and MCP equivalence test runs only when the API binary and both database URLs are set:

```bash
npm install
npm install --prefix packages/mcp
export AGENTGATE_API_BIN=build/brew-debug/apps/api/agentgate-api
export AGENTGATE_TEST_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/agentgate
export AGENTGATE_TEST_API_DATABASE_URL=postgresql://agentgate_api:local-dev-api-password@127.0.0.1:5432/agentgate
npm test
```

## Pooler

To exercise the pooler profile (PgBouncer in transaction mode):

```bash
docker compose --profile pooler up --build
```

Pooler check:

```bash
scripts/test-pooler.sh
```

## Issuing a credential

Credentials are high-entropy bearer tokens. Only the SHA-256 digest is stored. The script prints the token once on stdout and does not write it to a log file.

```bash
scripts/issue-credential.sh --name demo-proposer --kind proposer \
  --scopes '{"tables":[{"schema":"public","name":"invoices","tenants":["acme"]}]}'
```

Reviewer assignments are not taken from request bodies:

```bash
scripts/assign-reviewer.sh --principal <principal-uuid> --schema public --table invoices
```

## HTTP API

Routes are under `/v1`. Mutations require `Authorization: Bearer <token>` and `Idempotency-Key`.

| Method and route | Behavior |
| --- | --- |
| `POST /v1/reads` | Tracked read of explicit primary keys. Returns a read token. |
| `POST /v1/prs` | Create an immutable update proposal. Requires the tracked-read token for the demo flow. |
| `GET /v1/prs` | List PRs visible to the caller |
| `GET /v1/prs/{id}` | Metadata, revision, policy, approvals |
| `GET /v1/prs/{id}/diff` | Authorized before/after values |
| `POST /v1/prs/{id}/revisions` | New immutable revision; invalidates approvals |
| `POST /v1/prs/{id}/approve` | Approve the exact active revision and hash |
| `POST /v1/prs/{id}/reject` | Reject the exact active revision and hash |
| `POST /v1/prs/{id}/revert` | Propose the inverse of a merged receipt |
| `POST /v1/prs/{id}/merge` | Queue the approved revision. The worker commits it. |
| `GET /v1/prs/{id}/events` | Audit history |
| `POST /v1/webhooks` | Register a signed webhook. Administrator only. The secret is returned once. |
| `GET /v1/webhooks` | List destinations. The secret is omitted. |

Contracts live in `packages/contracts`. See [supported-schema.md](supported-schema.md) and [architecture/permission-model.md](architecture/permission-model.md).

## Repository map

| Path | Contents |
| --- | --- |
| `apps/api` | C++ HTTP API |
| `apps/worker` | C++ worker: expiry, merge, and webhook delivery |
| `core` | Shared services, pool, errors |
| `packages/db` | Migrations, grants, seed |
| `packages/contracts` | OpenAPI and JSON Schema |
| `packages/sdk` | TypeScript HTTP client |
| `packages/mcp` | Stdio MCP adapter over that client |
| `tests` | Catch2 unit and integration tests |
| `examples/supabase` | Local Supabase-compatibility checks |
| `examples/walkthrough` | Static four-panel illustration |
| `examples/demo-dashboard` | Live four-panel demo |
| `docs/architecture` | Decision records and the permission model |

## Limitations

- Only `update` of existing rows is accepted. `insert` and `delete` return `UNSUPPORTED_OPERATION`.
- Reads address explicit primary keys. Range queries, aggregates, absence checks, and unrestricted SQL are not supported.
- Approval does not write the business row. The worker writes it when a queued merge commits, and the receipt is the record of that write. A queued or conflicted proposal is not a committed write.
- The agent-facing MCP server exposes `read_rows`, `propose_change`, `get_pr`, `get_pr_diff`, `list_prs`, and `get_pr_status`. It does not expose approve, reject, merge, policy, or webhook tools, and it adds no database role.
- A proposer cannot approve their own PR. Approval requires a reviewer principal with an administrator-managed assignment.
- The demo proxy starts only when `AGENTGATE_DEMO=1` and `DATABASE_URL` points at `localhost`, `127.0.0.1`, or the Compose hostname `db`. The browser does not receive bearer tokens, the database password, or webhook secrets.
- The API process is the trust boundary. It passes the authenticated principal into SQL. Database role passwords must stay on the server.
- Enrollment adds `agentgate_revision` and a trigger. See [supported-schema.md](supported-schema.md) before enrolling a table that clients read with `SELECT *`.
- `external_issuer` and `external_subject` are unused. Supabase Auth JWT review is out of scope.
