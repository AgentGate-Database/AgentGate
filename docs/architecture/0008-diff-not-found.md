# ADR 0008 — Unauthorized diffs are not found

## Status

Accepted.

## Decision

`GET /v1/prs/{id}` and `GET /v1/prs/{id}/diff` return `404 NOT_FOUND` with message `pr not found` when the caller cannot view the PR. The body contains no before or after values. The same response is used when the id does not exist.

Review actions are different. An authenticated reviewer who is not assigned receives `403`, because the product check is "this reviewer cannot decide," and the response still contains no row values.

## Consequences

Probing ids does not reveal diffs. It also does not tell a proposer whether another principal's id exists. Reviewers learn that an id exists only in the sense that a forbidden review is distinct from a missing id.
