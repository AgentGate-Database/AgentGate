# ADR 0006 — Credential hashing

## Status

Accepted.

## Decision

Bearer tokens are `agk_<uuid>_<secret>`. The secret is at least 128 bits from a CSPRNG, encoded so it is header-safe. The database stores SHA-256 of the secret string. Comparison uses `CRYPTO_memcmp`. A missing credential compares against a zero digest so the branch does not skip the compare.

These are random tokens, not low-entropy passwords, so a password KDF is not used. Revocation is `credentials.revoked_at`. Authentication returns the same `401` for unknown, mismatched, and revoked tokens.

## Consequences

The cleartext token exists only at issuance (stdout of `scripts/issue-credential.sh`) and on the caller. Logs must not include it. `agentgate.authenticate` returns the digest to the API role, which is a server credential, not an agent credential.
