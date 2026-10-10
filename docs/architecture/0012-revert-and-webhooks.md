# ADR 0012 — Receipt revert and signed webhooks

## Status

Accepted.

## Decision

A reverse proposal is created only from a merged receipt. `POST /v1/prs/{id}/revert` requires an idempotency key. The caller must be the original proposer or an administrator. The server builds one update per receipt row: `set` is the committed before-image and `expected_revision` is the revision the receipt recorded after the merge. Before any proposal row is inserted, those business rows are read again. A missing row, a different `agentgate_revision`, or a different after-image raises `DRIFT_CONFLICT` and leaves no reverse proposal. The new proposal uses the normal policy and merge path, stores `source_pr_id`, and lands on a new revision. The previous revision counter is not restored.

Catalog events are `pr.created`, `pr.approved`, `pr.rejected`, `pr.conflicted`, `pr.expired`, `pr.merged`, and `pr.failed`. An insert trigger on `audit_events` is the only writer of those outbox rows. The payload is the event id, type, time, proposal id, revision, content hash, and receipt id when one exists. It does not include before or after values. A same-transaction guard drops the legacy `pr.merged` insert inside `merge_pr`, so that event is stored once. A failed merge records `pr.conflicted` or `pr.failed` and does not record `pr.merged`.

`POST /v1/webhooks` is limited to administrators. The signing secret is 32 random bytes, returned once as `whsec_` plus hex, and stored so the worker can sign. `GET /v1/webhooks` never returns it. A trigger on the outbox inserts one pending delivery per destination subscribed to that event. Destinations registered later do not receive earlier events.

The worker claims one due delivery with `FOR UPDATE SKIP LOCKED`, freezes the body and timestamp on the first claim, and POSTs that exact body with libcurl. Redirects are disabled. The signature is HMAC-SHA256 over `timestamp + "." + body`, sent as `AgentGate-Signature: v1=<hex>` with `AgentGate-Timestamp` and `AgentGate-Event-Id`. A 2xx marks the delivery delivered. Anything else uses delays of 1, 2, 4, 8, and 16 seconds and stops after five attempts. A crash after a successful POST and before the result commits is claimed again and sends the same event id and body.

Destination checks run at registration and again at delivery, after DNS resolution. Non-HTTP(S) URLs, userinfo, loopback, private, link-local, and metadata addresses are rejected. `AGENTGATE_WEBHOOK_ALLOW_PRIVATE=1` permits those addresses for a local test listener and is off by default.

## Consequences

The invoice demo proposes a revert over HTTP. Approval of that proposal does not change the business row. The row returns to the receipt's before-image only after the reverse merge commits, and its revision increases. The MCP adapter, drift simulator, and demo reset stay later work.
