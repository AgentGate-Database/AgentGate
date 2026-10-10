#!/usr/bin/env bash
# Apply packages/db migrations in order. Each file runs in one transaction.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${PGHOST:=localhost}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=agentgate}"
: "${AGENTGATE_API_PASSWORD:?set AGENTGATE_API_PASSWORD}"
: "${AGENTGATE_WORKER_PASSWORD:?set AGENTGATE_WORKER_PASSWORD}"
: "${AGENTGATE_MIGRATOR_PASSWORD:?set AGENTGATE_MIGRATOR_PASSWORD}"

export PGPASSWORD="${PGPASSWORD:-postgres}"

psql_cmd=(psql -v ON_ERROR_STOP=1 -X -q
  -v api_password="${AGENTGATE_API_PASSWORD}"
  -v worker_password="${AGENTGATE_WORKER_PASSWORD}"
  -v migrator_password="${AGENTGATE_MIGRATOR_PASSWORD}")

version_applied() {
  local version="$1"
  local exists
  exists="$("${psql_cmd[@]}" -tAc "SELECT to_regclass('agentgate.schema_migrations') IS NOT NULL" || true)"
  if [[ "${exists}" != "t" ]]; then
    return 1
  fi
  "${psql_cmd[@]}" -tAc "SELECT 1 FROM agentgate.schema_migrations WHERE version = '${version}'" | grep -q 1
}

shopt -s nullglob
files=("${ROOT}/migrations/"*.sql)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no migrations found" >&2
  exit 1
fi

for file in "${files[@]}"; do
  version="$(basename "${file}")"
  if version_applied "${version}"; then
    echo "skip ${version}"
    continue
  fi
  echo "apply ${version}"
  if grep -q 'agentgate:no-transaction' "${file}"; then
    "${psql_cmd[@]}" -f "${file}"
  else
    {
      echo "BEGIN;"
      cat "${file}"
      cat <<SQL
DO \$do\$
BEGIN
  IF to_regclass('agentgate.schema_migrations') IS NOT NULL THEN
    INSERT INTO agentgate.schema_migrations(version)
    VALUES ('${version}')
    ON CONFLICT DO NOTHING;
  END IF;
END
\$do\$;
COMMIT;
SQL
    } | "${psql_cmd[@]}"
  fi
done

if [[ "${AGENTGATE_SEED:-false}" == "true" ]]; then
  echo "seed"
  "${psql_cmd[@]}" -v ON_ERROR_STOP=1 -1 -f "${ROOT}/seed/demo_invoices.sql"
fi

echo "migrations complete"
