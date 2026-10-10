#!/usr/bin/env bash
# Re-run the test binaries through PgBouncer in transaction mode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

docker compose up -d db
docker compose run --rm migrate
docker compose --profile pooler up -d pooler

ready=0
for _ in $(seq 1 30); do
  if (echo >/dev/tcp/127.0.0.1/6432) >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" != "1" ]]; then
  echo "pgbouncer did not accept connections on 127.0.0.1:6432" >&2
  exit 1
fi

cmake --build --preset brew-debug

export AGENTGATE_TEST_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:6432/agentgate"
export AGENTGATE_TEST_API_DATABASE_URL="postgresql://agentgate_api:local-dev-api-password@127.0.0.1:6432/agentgate"
export AGENTGATE_TEST_WORKER_DATABASE_URL="postgresql://agentgate_worker:local-dev-worker-password@127.0.0.1:6432/agentgate"
export AGENTGATE_TEST_MIGRATOR_DATABASE_URL="postgresql://agentgate_migrator:local-dev-migrator-password@127.0.0.1:6432/agentgate"
export AGENTGATE_TEST_HTTP_PORT="${AGENTGATE_TEST_HTTP_PORT:-18081}"

./build/brew-debug/tests/agentgate_unit_tests
./build/brew-debug/tests/agentgate_integration_tests "[integration]"
