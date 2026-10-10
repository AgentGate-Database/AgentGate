# ADR 0001 — C++ backend

## Status

Accepted.

## Decision

The HTTP API, workers, and application services are C++20. Drogon serves HTTP. libpqxx talks to Postgres. JSON Schema is validated with pboettch/json-schema-validator on top of nlohmann/json. Catch2 runs tests.

PL/pgSQL functions in the `agentgate` schema are the authoritative path for proposals and review. The API authenticates the caller and passes the verified principal id into those functions.

## Consequences

Client contracts stay in OpenAPI and JSON Schema so the TypeScript SDK and MCP adapter do not depend on C++ types. The demo UI, when it exists, will call this API and will not reimplement approval or merge.
