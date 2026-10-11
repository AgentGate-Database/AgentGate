#!/usr/bin/env bash
# Delete the named agentgate-demo project and its volumes.
# This does not target the ordinary `agentgate` Compose project.
set -euo pipefail

if [[ "${1:-}" != "--yes" ]]; then
  echo "Refusing to reset. This deletes only the agentgate-demo containers and volumes." >&2
  echo "The ordinary quickstart started with 'docker compose up' is left in place." >&2
  echo "Run: scripts/reset-demo.sh --yes" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
docker compose -f compose.demo.yml --profile demo down -v
