# AgentGate

**Postgres pull requests for AI agents.**

AgentGate is an open-source, self-hostable API for proposing, reviewing, approving, and merging changes to Postgres data. A data PR changes records. It does not open a GitHub pull request and it does not create a database branch. Merge means applying the approved changes atomically to the existing database.

Created and maintained by [Kirthi Narayanan](https://github.com/<kirthi-github-username>).
Vinya is the company behind the project. The project brand is AgentGate.

The canonical repository is planned as `https://github.com/<agentgate-org>/agentgate`. Those handles are placeholders until the owner confirms them. This tree does not create GitHub accounts or organizations.

AgentGate works with standard Postgres. It also works with Supabase as a Postgres host: install the private `agentgate` schema, use scoped database roles, and keep that schema out of exposed Data API schemas. No Supabase partnership is required to run it, and this project does not claim partner status.

## What this tree implements

Milestones 1 through 6 from `AgentGate_Build_Guide.md`:

- C++20 HTTP API and worker, with authoritative checks in SQL.
- Private `agentgate` schema, enrollment, and row revision tracking.
- Bearer credentials, immutable proposal revisions, manual review, idempotency, and audit events.
- Structured updates addressed by an explicit primary key, tracked reads, deterministic policy, and atomic merge with a receipt.
- Receipt revert and signed webhooks.
- A TypeScript SDK, a stdio MCP adapter with the six agent tools, and a local four-panel demo.

## License

Apache-2.0 is the recommended license candidate. This repository does not apply a license until the project owner chooses one. Do not treat the absence of a `LICENSE` file as a grant of rights.

## Local quickstart

Docker is enough to run the database, migrations, API, and worker. A local C++ toolchain is only needed to build natively.

```bash
docker compose up --build
```

The API listens on `http://127.0.0.1:8080`. Compose binds published ports to loopback and uses a disposable database with synthetic invoices when `AGENTGATE_SEED=true` (the default). This command uses the Compose project `agentgate`.

View the illustrated walkthrough at `examples/walkthrough/index.html`. It is a static page: the four panels step through a fixed invoice story and do not call the API. After the GitHub organization exists, GitHub Pages publishes that folder at `https://<agentgate-org>.github.io/agentgate/`. Enabling Pages in the repository settings is a separate owner step.

The live demo is a separate Compose project so its volumes can be removed without deleting the quickstart database:

```bash
docker compose -f compose.demo.yml --profile demo up --build
```

The dashboard is `http://127.0.0.1:8090`. Both projects publish the same host ports, so run one at a time. Reset deletes only the `agentgate-demo` project:

```bash
scripts/reset-demo.sh --yes
```

That script requires `--yes` and does not run on startup. It leaves the `agentgate` project and its database volume in place.

Check readiness:

```bash
curl -sS http://127.0.0.1:8080/healthz
curl -sS http://127.0.0.1:8080/readyz
```

Postgres 15 and 17 are both supported. Override the image with `POSTGRES_IMAGE=postgres:15`.

To exercise the pooler profile (PgBouncer in transaction mode):

```bash
docker compose --profile pooler up --build
```

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

Contracts live in `packages/contracts`. See `docs/supported-schema.md` and `docs/architecture/permission-model.md`.

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
- Enrollment adds `agentgate_revision` and a trigger. See `docs/supported-schema.md` before enrolling a table that clients read with `SELECT *`.
- `external_issuer` and `external_subject` are unused. Supabase Auth JWT review is out of scope.
