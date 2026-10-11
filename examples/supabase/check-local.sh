#!/usr/bin/env bash
# Check AgentGate's local Supabase-compatibility constraints through the
# Compose pooler profile. This does not call hosted Supabase.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

PORT="${POOLER_PORT:-6432}"
HOST="${POOLER_HOST:-127.0.0.1}"
if [[ "${HOST}" != "127.0.0.1" && "${HOST}" != "localhost" && "${HOST}" != "db" ]]; then
  echo "refusing a remote database host: ${HOST}" >&2
  exit 1
fi

if ! (echo >/dev/tcp/127.0.0.1/"${PORT}") >/dev/null 2>&1; then
  docker compose --profile pooler up -d db pooler
  ready=0
  for _ in $(seq 1 30); do
    if (echo >/dev/tcp/127.0.0.1/"${PORT}") >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "${ready}" != "1" ]]; then
    echo "pooler did not accept connections on 127.0.0.1:${PORT}" >&2
    exit 1
  fi
fi

run_psql() {
  local database="$1"
  shift
  if command -v psql >/dev/null 2>&1; then
    psql "postgresql://postgres:postgres@127.0.0.1:${PORT}/${database}" "$@"
  else
    docker compose exec -T db psql "postgresql://postgres:postgres@pooler:5432/${database}" "$@"
  fi
}

run_psql agentgate -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE
  role_name text;
  data_roles text[] := ARRAY['anon', 'authenticated', 'service_role'];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'agentgate') THEN
    RAISE EXCEPTION 'schema agentgate is missing';
  END IF;
  IF has_schema_privilege('public', 'agentgate', 'USAGE') THEN
    RAISE EXCEPTION 'PUBLIC can use schema agentgate';
  END IF;

  FOREACH role_name IN ARRAY data_roles LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name)
       AND has_schema_privilege(role_name, 'agentgate', 'USAGE') THEN
      RAISE EXCEPTION '% can use schema agentgate; exclude it from Data API schemas', role_name;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'agentgate_owner' AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcanlogin
  ) THEN
    RAISE EXCEPTION 'agentgate_owner must be NOLOGIN, NOSUPERUSER, and NOBYPASSRLS';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'agentgate_api' AND NOT rolsuper AND NOT rolbypassrls AND rolcanlogin
  ) THEN
    RAISE EXCEPTION 'agentgate_api must be a login role without superuser or BYPASSRLS';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'agentgate_worker' AND NOT rolsuper AND NOT rolbypassrls AND rolcanlogin
  ) THEN
    RAISE EXCEPTION 'agentgate_worker must be a login role without superuser or BYPASSRLS';
  END IF;

  IF has_table_privilege('agentgate_api', 'public.invoices', 'UPDATE')
     OR has_table_privilege('agentgate_worker', 'public.invoices', 'UPDATE') THEN
    RAISE EXCEPTION 'api or worker role can update public.invoices directly';
  END IF;
END
$$;
SQL

admin="$(run_psql pgbouncer -v ON_ERROR_STOP=1 -tA -c "SHOW CONFIG;" | awk -F '|' '$1=="pool_mode" { gsub(/ /,"",$2); print $2 }')"
if [[ "${admin}" != "transaction" ]]; then
  echo "pool_mode is '${admin}', expected transaction" >&2
  exit 1
fi

echo "local Supabase-compatibility checks passed through 127.0.0.1:${PORT}"
