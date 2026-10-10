#!/usr/bin/env bash
# Print a new bearer token once on stdout. The database stores only its SHA-256 digest.
set -euo pipefail

name=""
kind=""
scopes='{"tables":[]}'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --kind) kind="$2"; shift 2 ;;
    --scopes) scopes="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${name}" || -z "${kind}" ]]; then
  echo "usage: issue-credential.sh --name NAME --kind proposer|reviewer|admin|worker [--scopes JSON]" >&2
  exit 2
fi

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=agentgate_migrator}"
: "${PGDATABASE:=agentgate}"
: "${PGPASSWORD:=${AGENTGATE_MIGRATOR_PASSWORD:-local-dev-migrator-password}}"
export PGPASSWORD

secret="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
digest="$(printf '%s' "${secret}" | openssl dgst -sha256 | awk '{print $NF}')"

read -r credential_id principal <<<"$(psql -v ON_ERROR_STOP=1 -X -q -tA -F ' ' \
  -v name="${name}" \
  -v kind="${kind}" \
  -v scopes="${scopes}" \
  -v digest="${digest}" <<'SQL'
SELECT s.credential_id::text, agentgate.issue_credential(
  :'name',
  :'kind',
  :'scopes'::jsonb,
  s.credential_id,
  decode(:'digest', 'hex')
)::text
FROM (SELECT gen_random_uuid() AS credential_id) AS s;
SQL
)"

echo "principal ${principal}" >&2
printf 'agk_%s_%s\n' "${credential_id}" "${secret}"
