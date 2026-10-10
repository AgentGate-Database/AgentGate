#!/usr/bin/env bash
# Assign a reviewer principal to an enrolled table. Request bodies cannot do this.
set -euo pipefail

principal=""
schema=""
table=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --principal) principal="$2"; shift 2 ;;
    --schema) schema="$2"; shift 2 ;;
    --table) table="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${principal}" || -z "${schema}" || -z "${table}" ]]; then
  echo "usage: assign-reviewer.sh --principal UUID --schema SCHEMA --table TABLE" >&2
  exit 2
fi

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=agentgate_migrator}"
: "${PGDATABASE:=agentgate}"
: "${PGPASSWORD:=${AGENTGATE_MIGRATOR_PASSWORD:-local-dev-migrator-password}}"
export PGPASSWORD

psql -v ON_ERROR_STOP=1 -X -q \
  -v principal="${principal}" \
  -v schema="${schema}" \
  -v table="${table}" <<'SQL'
SELECT agentgate.assign_reviewer(:'principal'::uuid, :'schema', :'table');
SQL
