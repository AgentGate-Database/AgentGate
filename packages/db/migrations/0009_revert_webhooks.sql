-- Reverse proposals and webhook delivery. The outbox trigger is the only
-- writer of catalog events. A same-transaction guard drops the legacy
-- pr.merged insert inside merge_pr so that event is stored once.
GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE TABLE IF NOT EXISTS agentgate.webhook_endpoints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  url text NOT NULL,
  secret bytea NOT NULL,
  created_by uuid NOT NULL REFERENCES agentgate.principals (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (octet_length(secret) = 32),
  CHECK (char_length(url) BETWEEN 1 AND 2000)
);

CREATE TABLE IF NOT EXISTS agentgate.webhook_subscriptions (
  endpoint_id uuid NOT NULL REFERENCES agentgate.webhook_endpoints (id),
  event_type text NOT NULL,
  PRIMARY KEY (endpoint_id, event_type)
);

CREATE TABLE IF NOT EXISTS agentgate.webhook_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outbox_id uuid NOT NULL REFERENCES agentgate.outbox_events (id),
  endpoint_id uuid NOT NULL REFERENCES agentgate.webhook_endpoints (id),
  state text NOT NULL CHECK (state IN ('pending', 'delivered', 'failed')),
  attempt int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  lease_owner text,
  lease_expires_at timestamptz,
  body text,
  timestamp_text text,
  http_status int,
  error text,
  UNIQUE (outbox_id, endpoint_id)
);

CREATE INDEX IF NOT EXISTS webhook_deliveries_due_idx
  ON agentgate.webhook_deliveries (next_attempt_at, id)
  WHERE state = 'pending';

CREATE TABLE IF NOT EXISTS agentgate.webhook_delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL REFERENCES agentgate.webhook_deliveries (id),
  attempt int NOT NULL,
  http_status int,
  error text,
  attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION agentgate.proposal_body(
  p_pr agentgate.prs,
  p_revision_no int,
  p_hash text,
  p_decision text,
  p_policy_version int,
  p_diff jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  RETURN jsonb_build_object(
    'pr_id', p_pr.id,
    'title', p_pr.title,
    'reason', p_pr.reason,
    'task_id', COALESCE(to_jsonb(p_pr.task_id), 'null'::jsonb),
    'proposer_id', p_pr.proposer_id,
    'state', p_pr.state,
    'revision', p_revision_no,
    'content_hash', p_hash,
    'policy_decision', p_decision,
    'policy_version', p_policy_version,
    'expires_at', agentgate.iso_timestamptz(p_pr.expires_at),
    'created_at', agentgate.iso_timestamptz(p_pr.created_at),
    'approvals', '[]'::jsonb,
    'execution_status', 'null'::jsonb,
    'diff', p_diff,
    'source_pr_id', COALESCE(to_jsonb(p_pr.source_pr_id), 'null'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.get_pr(p_principal uuid, p_pr uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_pr agentgate.prs%ROWTYPE;
  v_rev agentgate.pr_revisions%ROWTYPE;
  v_policy_version int;
  v_approvals jsonb;
  v_execution jsonb;
  v_job uuid;
BEGIN
  FOR v_job IN
    SELECT id FROM agentgate.merge_jobs WHERE pr_id = p_pr ORDER BY id FOR UPDATE
  LOOP
    NULL;
  END LOOP;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND OR NOT agentgate.principal_can_view(p_principal, p_pr) THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.state IN ('pending_review', 'approved', 'queued') AND v_pr.expires_at <= now() THEN
    UPDATE agentgate.merge_jobs SET state = 'failed', lease_expires_at = NULL
    WHERE pr_id = p_pr AND state = 'queued';
    UPDATE agentgate.prs SET state = 'expired' WHERE id = p_pr;
    INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
    VALUES (p_pr, p_principal, 'pr.expired', '{}'::jsonb);
    v_pr.state := 'expired';
  END IF;
  SELECT * INTO v_rev FROM agentgate.pr_revisions WHERE id = v_pr.active_revision_id;
  SELECT version INTO v_policy_version FROM agentgate.policies WHERE id = v_rev.policy_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'principal_id', a.principal_id,
    'decision', a.decision,
    'revision', r.revision_no,
    'content_hash', a.content_hash,
    'reason', a.reason,
    'created_at', agentgate.iso_timestamptz(a.created_at)
  ) ORDER BY a.created_at), '[]'::jsonb)
  INTO v_approvals
  FROM agentgate.approvals a
  JOIN agentgate.pr_revisions r ON r.id = a.revision_id
  WHERE a.pr_id = p_pr;

  SELECT jsonb_build_object(
    'job_id', j.id,
    'state', j.state,
    'receipt', CASE WHEN rec.id IS NULL THEN 'null'::jsonb
      ELSE agentgate.receipt_body(rec.id, v_rev.revision_no, v_rev.content_hash) END
  )
  INTO v_execution
  FROM agentgate.merge_jobs j
  LEFT JOIN agentgate.merge_receipts rec ON rec.revision_id = j.revision_id
  WHERE j.pr_id = p_pr AND j.revision_id = v_pr.active_revision_id;

  RETURN jsonb_build_object(
    'pr_id', v_pr.id,
    'title', v_pr.title,
    'reason', v_pr.reason,
    'task_id', COALESCE(to_jsonb(v_pr.task_id), 'null'::jsonb),
    'proposer_id', v_pr.proposer_id,
    'state', v_pr.state,
    'revision', v_rev.revision_no,
    'content_hash', v_rev.content_hash,
    'policy_decision', v_rev.policy_decision,
    'policy_version', v_policy_version,
    'expires_at', agentgate.iso_timestamptz(v_pr.expires_at),
    'created_at', agentgate.iso_timestamptz(v_pr.created_at),
    'approvals', v_approvals,
    'execution_status', COALESCE(v_execution, 'null'::jsonb),
    'source_pr_id', COALESCE(to_jsonb(v_pr.source_pr_id), 'null'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.revert_pr(
  p_principal uuid,
  p_pr uuid,
  p_body jsonb,
  p_idempotency_key text,
  p_request_digest text,
  p_max_rows int,
  p_min_expiry int,
  p_max_expiry int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_route text := 'POST /v1/prs/' || p_pr::text || '/revert';
  v_existing jsonb;
  v_kind text;
  v_scopes jsonb;
  v_pr agentgate.prs%ROWTYPE;
  v_new agentgate.prs%ROWTYPE;
  v_receipt agentgate.merge_receipts%ROWTYPE;
  v_row jsonb;
  v_reg agentgate.table_registry%ROWTYPE;
  v_key text;
  v_locked jsonb;
  v_changes jsonb := '[]'::jsonb;
  v_request jsonb;
  v_title text;
  v_reason text;
  v_expiry int;
  v_expires_at timestamptz;
  v_plan jsonb;
  v_policy_id uuid;
  v_policy_version int;
  v_policy_doc jsonb;
  v_outcome jsonb;
  v_revision_id uuid := gen_random_uuid();
  v_body jsonb;
  v_wrapper jsonb;
BEGIN
  v_existing := agentgate.idempotency_begin(p_principal, v_route, p_idempotency_key, p_request_digest);
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  SELECT kind, scopes INTO v_kind, v_scopes FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND OR v_kind NOT IN ('proposer', 'admin') THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND OR (v_pr.proposer_id <> p_principal AND v_kind <> 'admin') THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.state <> 'merged' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'pr is not merged');
  END IF;
  SELECT * INTO v_receipt
  FROM agentgate.merge_receipts
  WHERE pr_id = p_pr AND revision_id = v_pr.active_revision_id;
  IF NOT FOUND OR jsonb_typeof(v_receipt.rows) <> 'array' OR jsonb_array_length(v_receipt.rows) < 1 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'merged pr has no receipt');
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(v_receipt.rows)
  LOOP
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_row->>'schema' AND table_name = v_row->>'table';
    IF NOT FOUND THEN
      PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'table is not enrolled');
    END IF;
    v_key := v_row->'key'->>v_reg.primary_key_column;
    v_locked := agentgate.read_change_row(
      v_reg.schema_name, v_reg.table_name, v_reg.primary_key_column, v_reg.primary_key_type,
      v_key, v_row->'after', false
    );
    IF v_locked IS NULL
       OR (v_locked->>'revision') IS DISTINCT FROM (v_row->>'revision')
       OR v_locked->'values' IS DISTINCT FROM v_row->'after' THEN
      PERFORM agentgate.raise_app('DRIFT_CONFLICT', 'a merged row changed before revert');
    END IF;
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'operation', 'update',
      'schema', v_row->>'schema',
      'table', v_row->>'table',
      'key', v_row->'key',
      'expected_revision', v_row->>'revision',
      'set', v_row->'before'
    ));
  END LOOP;

  v_title := agentgate.require_text(p_body, 'title', 200);
  v_reason := agentgate.require_text(p_body, 'reason', 4000);
  v_expiry := agentgate.parse_expiry(p_body, p_min_expiry, p_max_expiry);
  v_expires_at := now() + make_interval(secs => v_expiry::double precision);
  v_request := jsonb_build_object('changes', v_changes);
  SELECT id, version, document INTO v_policy_id, v_policy_version, v_policy_doc
  FROM agentgate.policies ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('POLICY_BLOCKED', 'no policy is configured');
  END IF;
  v_plan := agentgate.plan_changes(p_principal, v_kind, v_scopes, v_request, v_expires_at, p_max_rows);
  v_outcome := agentgate.proposal_outcome(p_principal, v_plan->'rows', v_policy_doc, v_policy_version);

  INSERT INTO agentgate.prs (
    id, title, reason, proposer_id, state, expires_at, source_pr_id
  ) VALUES (
    gen_random_uuid(), v_title, v_reason, p_principal, v_outcome->>'state', v_expires_at, p_pr
  )
  RETURNING * INTO v_new;
  INSERT INTO agentgate.pr_revisions (
    id, pr_id, revision_no, canonical_content, content_hash, policy_id, policy_decision
  ) VALUES (
    v_revision_id, v_new.id, 1, v_plan->'content', v_plan->>'content_hash',
    v_policy_id, v_outcome->>'policy_decision'
  );
  UPDATE agentgate.prs SET active_revision_id = v_revision_id WHERE id = v_new.id;
  v_new.active_revision_id := v_revision_id;
  PERFORM agentgate.insert_revision_rows(v_revision_id, v_plan->'rows');
  PERFORM agentgate.insert_dependencies(v_revision_id, v_plan->'dependencies');
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (v_new.id, p_principal, 'pr.created', jsonb_build_object(
    'revision', 1,
    'content_hash', v_plan->>'content_hash',
    'policy_decision', v_outcome->>'policy_decision',
    'source_pr_id', p_pr
  ));
  v_body := agentgate.proposal_body(
    v_new, 1, v_plan->>'content_hash', v_outcome->>'policy_decision', v_policy_version, v_plan->'diff'
  );
  v_wrapper := jsonb_build_object('http_status', 201, 'body', v_body);
  RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.webhook_event_allowed(p_event text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT p_event IN (
    'pr.created', 'pr.approved', 'pr.rejected', 'pr.conflicted',
    'pr.expired', 'pr.merged', 'pr.failed'
  );
$$;

CREATE OR REPLACE FUNCTION agentgate.skip_duplicate_outbox()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM agentgate.outbox_events
    WHERE event_type = NEW.event_type
      AND pr_id IS NOT DISTINCT FROM NEW.pr_id
      AND xmin = pg_current_xact_id()::xid
  ) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS outbox_events_skip_duplicate ON agentgate.outbox_events;
CREATE TRIGGER outbox_events_skip_duplicate
  BEFORE INSERT ON agentgate.outbox_events
  FOR EACH ROW
  EXECUTE FUNCTION agentgate.skip_duplicate_outbox();

CREATE OR REPLACE FUNCTION agentgate.enqueue_audit_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
  v_payload jsonb;
BEGIN
  IF NOT agentgate.webhook_event_allowed(NEW.event_type) THEN
    RETURN NEW;
  END IF;
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'id', v_id,
    'type', NEW.event_type,
    'created_at', agentgate.iso_timestamptz(NEW.created_at),
    'pr_id', NEW.pr_id,
    'revision', NEW.details->'revision',
    'content_hash', NEW.details->'content_hash',
    'receipt_id', NEW.details->'receipt_id'
  ));
  INSERT INTO agentgate.outbox_events (id, pr_id, event_type, payload)
  VALUES (v_id, NEW.pr_id, NEW.event_type, v_payload);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audit_events_outbox ON agentgate.audit_events;
CREATE TRIGGER audit_events_outbox
  AFTER INSERT ON agentgate.audit_events
  FOR EACH ROW
  EXECUTE FUNCTION agentgate.enqueue_audit_outbox();

CREATE OR REPLACE FUNCTION agentgate.fanout_webhook_delivery()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  INSERT INTO agentgate.webhook_deliveries (outbox_id, endpoint_id, state)
  SELECT NEW.id, subscription.endpoint_id, 'pending'
  FROM agentgate.webhook_subscriptions subscription
  WHERE subscription.event_type = NEW.event_type;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS outbox_events_fanout ON agentgate.outbox_events;
CREATE TRIGGER outbox_events_fanout
  AFTER INSERT ON agentgate.outbox_events
  FOR EACH ROW
  EXECUTE FUNCTION agentgate.fanout_webhook_delivery();

CREATE OR REPLACE FUNCTION agentgate.register_webhook(
  p_principal uuid,
  p_url text,
  p_events jsonb,
  p_secret bytea
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_kind text;
  v_id uuid := gen_random_uuid();
  v_event text;
  v_events jsonb := '[]'::jsonb;
BEGIN
  SELECT kind INTO v_kind FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  IF v_kind <> 'admin' THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'only an administrator can register a webhook');
  END IF;
  IF p_url IS NULL OR char_length(btrim(p_url)) = 0 OR char_length(p_url) > 2000 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'webhook url is invalid');
  END IF;
  IF octet_length(p_secret) <> 32 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'webhook secret must be 32 bytes');
  END IF;
  IF jsonb_typeof(p_events) <> 'array' OR jsonb_array_length(p_events) < 1 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'webhook events must be a non-empty array');
  END IF;
  INSERT INTO agentgate.webhook_endpoints (id, url, secret, created_by)
  VALUES (v_id, p_url, p_secret, p_principal);
  FOR v_event IN
    SELECT DISTINCT value FROM jsonb_array_elements_text(p_events) AS value ORDER BY value
  LOOP
    IF NOT agentgate.webhook_event_allowed(v_event) THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'webhook event is not supported');
    END IF;
    INSERT INTO agentgate.webhook_subscriptions (endpoint_id, event_type)
    VALUES (v_id, v_event);
    v_events := v_events || jsonb_build_array(v_event);
  END LOOP;
  RETURN jsonb_build_object('id', v_id, 'url', p_url, 'events', v_events);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.list_webhooks(p_principal uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_kind text;
  v_items jsonb;
BEGIN
  SELECT kind INTO v_kind FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  IF v_kind <> 'admin' THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'only an administrator can list webhooks');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', endpoint.id,
    'url', endpoint.url,
    'events', (
      SELECT COALESCE(jsonb_agg(subscription.event_type ORDER BY subscription.event_type), '[]'::jsonb)
      FROM agentgate.webhook_subscriptions subscription
      WHERE subscription.endpoint_id = endpoint.id
    ),
    'created_at', agentgate.iso_timestamptz(endpoint.created_at)
  ) ORDER BY endpoint.created_at, endpoint.id), '[]'::jsonb)
  INTO v_items
  FROM agentgate.webhook_endpoints endpoint;
  RETURN jsonb_build_object('webhooks', v_items);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.claim_webhook_delivery(p_worker text, p_lease_seconds int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_delivery agentgate.webhook_deliveries%ROWTYPE;
  v_endpoint agentgate.webhook_endpoints%ROWTYPE;
  v_event agentgate.outbox_events%ROWTYPE;
BEGIN
  UPDATE agentgate.webhook_deliveries
  SET lease_owner = p_worker,
      lease_expires_at = now() + make_interval(secs => GREATEST(p_lease_seconds, 1)),
      attempt = attempt + 1
  WHERE id = (
    SELECT id FROM agentgate.webhook_deliveries
    WHERE state = 'pending'
      AND next_attempt_at <= now()
      AND (lease_expires_at IS NULL OR lease_expires_at <= now())
    ORDER BY next_attempt_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING * INTO v_delivery;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_event FROM agentgate.outbox_events WHERE id = v_delivery.outbox_id;
  IF v_delivery.body IS NULL OR v_delivery.timestamp_text IS NULL THEN
    UPDATE agentgate.webhook_deliveries
    SET body = v_event.payload::text,
        timestamp_text = agentgate.iso_timestamptz(now())
    WHERE id = v_delivery.id
    RETURNING * INTO v_delivery;
  END IF;
  SELECT * INTO v_endpoint FROM agentgate.webhook_endpoints WHERE id = v_delivery.endpoint_id;
  RETURN jsonb_build_object(
    'delivery_id', v_delivery.id,
    'url', v_endpoint.url,
    'secret_hex', encode(v_endpoint.secret, 'hex'),
    'body', v_delivery.body,
    'timestamp', v_delivery.timestamp_text,
    'event_id', v_event.id,
    'attempt', v_delivery.attempt
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.record_webhook_result(
  p_delivery uuid,
  p_status int,
  p_error text,
  p_terminal boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_delivery agentgate.webhook_deliveries%ROWTYPE;
  v_state text;
  v_delay int;
BEGIN
  SELECT * INTO v_delivery FROM agentgate.webhook_deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'webhook delivery not found');
  END IF;
  IF v_delivery.state = 'delivered' THEN
    RETURN jsonb_build_object('delivery_id', p_delivery, 'state', 'delivered');
  END IF;
  INSERT INTO agentgate.webhook_delivery_attempts (delivery_id, attempt, http_status, error)
  VALUES (p_delivery, v_delivery.attempt, NULLIF(p_status, 0), NULLIF(p_error, ''));
  IF p_status >= 200 AND p_status < 300 AND NOT COALESCE(p_terminal, false) THEN
    v_state := 'delivered';
    v_delay := NULL;
  ELSIF COALESCE(p_terminal, false) OR v_delivery.attempt >= 5 THEN
    v_state := 'failed';
    v_delay := NULL;
  ELSE
    v_state := 'pending';
    v_delay := power(2, GREATEST(v_delivery.attempt - 1, 0))::int;
  END IF;
  UPDATE agentgate.webhook_deliveries
  SET state = v_state,
      http_status = NULLIF(p_status, 0),
      error = NULLIF(p_error, ''),
      lease_owner = NULL,
      lease_expires_at = NULL,
      next_attempt_at = CASE
        WHEN v_delay IS NULL THEN next_attempt_at
        ELSE now() + make_interval(secs => v_delay)
      END
  WHERE id = p_delivery;
  RETURN jsonb_build_object('delivery_id', p_delivery, 'state', v_state);
END;
$$;

REVOKE ALL ON FUNCTION agentgate.proposal_body(agentgate.prs, int, text, text, int, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.get_pr(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.revert_pr(uuid, uuid, jsonb, text, text, int, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.webhook_event_allowed(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.skip_duplicate_outbox() FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.enqueue_audit_outbox() FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.fanout_webhook_delivery() FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.register_webhook(uuid, text, jsonb, bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.list_webhooks(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.claim_webhook_delivery(text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.record_webhook_result(uuid, int, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentgate.get_pr(uuid, uuid) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.revert_pr(uuid, uuid, jsonb, text, text, int, int, int) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.register_webhook(uuid, text, jsonb, bytea) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.list_webhooks(uuid) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.claim_webhook_delivery(text, int) TO agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.record_webhook_result(uuid, int, text, boolean) TO agentgate_worker;

REVOKE ALL ON ALL TABLES IN SCHEMA agentgate FROM PUBLIC, agentgate_api, agentgate_worker;
GRANT SELECT, INSERT, UPDATE ON agentgate.table_registry TO agentgate_migrator;

RESET ROLE;
