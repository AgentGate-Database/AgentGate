# Contributing

AgentGate is maintained by Kirthi Narayanan. There is not a separate review team yet. Open a change against the project repository once it is published under the AgentGate organization (`<agentgate-org>/agentgate`). Until those handles are confirmed, coordinate with the maintainer directly.

## Expectations

- Keep the core in C++20. SQL and PL/pgSQL own transactional enforcement. TypeScript is for the client SDK, the demo UI, and the thin MCP adapter.
- Do not weaken an authorization, revision, or idempotency check to make a route pass.
- Use a disposable local Postgres database and synthetic data. Never point development settings at a production or remote database.
- Record material design choices as a short ADR in `docs/architecture`.
- Match `.clang-format`. The CI format job runs `clang-format --dry-run --Werror`.

## Build and test

```bash
cmake --preset brew-debug
cmake --build --preset brew-debug
docker compose up -d db
docker compose run --rm migrate
ctest --preset brew-debug --output-on-failure
```

On Linux CI the `ci-linux` preset uses the pinned vcpkg baseline. Sanitizer builds use the `asan-ubsan` preset or `-DAGENTGATE_SANITIZERS=ON`.

Migrations live in `packages/db/migrations` and must stay valid on Postgres 15 and 17. Prefer `SET LOCAL` and parameterized statements so transaction-mode poolers keep working.

## Review

The maintainer reviews functional changes, schema changes, and anything that touches grants or security-definer functions. Do not grant the API or worker roles direct table writes.
