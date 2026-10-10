# Security

AgentGate governs writes that go through its API. It does not protect a database whose owner, or an agent that still holds a separate write credential, bypasses it.

## Reporting

Report vulnerabilities privately to the maintainer, Kirthi Narayanan, at the contact published on the verified GitHub profile `<kirthi-github-username>`. Do not open a public issue for an unfixed vulnerability. There is no bug-bounty program.

## Credential handling

- Callers authenticate with high-entropy bearer tokens. The database stores only a SHA-256 digest.
- Revoked credentials fail authentication.
- Tokens, database passwords, and webhook secrets must not be logged, committed, or sent to a browser.
- Request bodies cannot choose the principal, the tenant scope, or the reviewer.

## Database roles

- `agentgate_migrator` installs and enrolls. It is not a runtime credential.
- `agentgate_api` executes approved functions only.
- `agentgate_worker` executes queue and expiry functions only. It cannot approve.
- `agentgate_owner` is `NOLOGIN`, is not a superuser, and does not have `BYPASSRLS`. It owns security-definer functions.

Security-definer functions set a fixed `search_path`, qualify names, and do not accept SQL text from callers. Identifiers are checked against an allowlist and quoted.

## Supabase

Keep the `agentgate` schema out of exposed API schemas. Do not put a service-role key in an agent. A publishable project key is not reviewer authentication. Reviewer identity mapping for Supabase Auth is a later milestone; `principals.external_issuer` and `principals.external_subject` are reserved for it.

## Scope of the current tree

Merge is not implemented yet, so approval does not write business rows. That is not a security boundary you should rely on as the product promise; the merge milestone must re-check policy, revision, and scope inside the database transaction.
