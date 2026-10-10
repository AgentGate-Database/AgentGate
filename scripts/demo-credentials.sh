#!/usr/bin/env bash
# Write proposer and reviewer tokens for the demo proxy. Tokens stay in the output file.
set -euo pipefail

output="${1:-/secrets/demo.env}"
root="$(cd "$(dirname "$0")" && pwd)"
scope='{"tables":[{"schema":"public","name":"invoices","tenants":["acme"]}]}'

issue() {
  local name="$1"
  local kind="$2"
  local err
  err="$(mktemp)"
  local token
  token="$("${root}/issue-credential.sh" --name "${name}" --kind "${kind}" --scopes "${scope}" 2>"${err}")"
  local principal
  principal="$(awk '/^principal / { print $2 }' "${err}")"
  rm -f "${err}"
  if [[ -z "${token}" || -z "${principal}" ]]; then
    echo "credential issue failed for ${name}" >&2
    exit 1
  fi
  printf '%s %s\n' "${token}" "${principal}"
}

read -r proposer_token proposer_id <<<"$(issue demo-proposer proposer)"
read -r reviewer_token reviewer_id <<<"$(issue demo-reviewer reviewer)"
"${root}/assign-reviewer.sh" --principal "${reviewer_id}" --schema public --table invoices >/dev/null

mkdir -p "$(dirname "${output}")"
umask 077
cat >"${output}" <<EOF
AGENTGATE_PROPOSER_TOKEN=${proposer_token}
AGENTGATE_REVIEWER_TOKEN=${reviewer_token}
EOF
echo "wrote demo credentials for principals ${proposer_id} ${reviewer_id}" >&2
