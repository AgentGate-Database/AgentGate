-- Atomic merge queue. The receipt is the only proof a change committed.
GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE TABLE IF NOT EXISTS agentgate.merge_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pr_id uuid NOT NULL REFERENCES agentgate.prs (id),
  revision_id uuid NOT NULL REFERENCES agentgate.pr_revisions (id),
  enqueued_at timestamptz NOT NULL DEFAULT now(),
  attempts int NOT NULL DEFAULT 0,
  lease_owner text,
  lease_expires_at timestamptz,
  state text NOT NULL CHECK (state IN ('queued', 'completed', 'failed')),
  UNIQUE (pr_id, revision_id)
);

CREATE INDEX IF NOT EXISTS merge_jobs_claim_idx
  ON agentgate.merge_jobs (enqueued_at, id)
  WHERE state = 'queued';

CREATE TABLE IF NOT EXISTS agentgate.merge_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pr_id uuid NOT NULL REFERENCES agentgate.prs (id),
  revision_id uuid NOT NULL REFERENCES agentgate.pr_revisions (id),
  execution_id uuid NOT NULL,
  committed_at timestamptz NOT NULL DEFAULT now(),
  rows jsonb NOT NULL,
  UNIQUE (pr_id, revision_id)
);

CREATE TABLE IF NOT EXISTS agentgate.outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pr_id uuid REFERENCES agentgate.prs (id),
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION agentgate.sql_cast_type(p_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT CASE p_type
    WHEN 'int2' THEN 'smallint'
    WHEN 'int4' THEN 'integer'
    WHEN 'int8' THEN 'bigint'
    WHEN 'numeric' THEN 'numeric'
    WHEN 'text' THEN 'text'
    WHEN 'varchar' THEN 'varchar'
    WHEN 'bool' THEN 'boolean'
    WHEN 'timestamptz' THEN 'timestamptz'
    WHEN 'date' THEN 'date'
    WHEN 'uuid' THEN 'uuid'
    WHEN 'jsonb' THEN 'jsonb'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION agentgate.assignment_sql(p_column text, p_type text, p_value jsonb)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_cast text;
BEGIN
  PERFORM agentgate.assert_ident(p_column);
  v_cast := agentgate.sql_cast_type(p_type);
  IF v_cast IS NULL THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'unsupported column type');
  END IF;
  IF p_value IS NULL OR p_value = 'null'::jsonb THEN
    RETURN format('%I = NULL', p_column);
  END IF;
  IF p_type = 'bool' THEN
    IF p_value = 'true'::jsonb THEN
      RETURN format('%I = true', p_column);
    END IF;
    IF p_value = 'false'::jsonb THEN
      RETURN format('%I = false', p_column);
    END IF;
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'boolean values must be JSON booleans');
  END IF;
  IF p_type = 'jsonb' THEN
    RETURN format('%I = %L::jsonb', p_column, p_value::text);
  END IF;
  RETURN format('%I = %L::%s', p_column, p_value #>> '{}', v_cast);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.read_change_row(
  p_schema text,
  p_table text,
  p_pk text,
  p_pk_type text,
  p_key text,
  p_values jsonb,
  p_lock boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_pairs text := '';
  v_col text;
  v_type text;
  v_sql text;
  v_revision text;
  v_current jsonb;
  v_count int := 0;
BEGIN
  FOR v_col IN SELECT key FROM jsonb_object_keys(p_values) AS key ORDER BY key
  LOOP
    SELECT spec->>'type' INTO v_type
    FROM agentgate.table_registry r
    CROSS JOIN LATERAL jsonb_array_elements(r.allowed_columns) spec
    WHERE r.schema_name = p_schema AND r.table_name = p_table AND spec->>'name' = v_col;
    IF v_type IS NULL THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'column is not allowed');
    END IF;
    IF v_pairs <> '' THEN
      v_pairs := v_pairs || ', ';
    END IF;
    v_pairs := v_pairs || format('%L, %s', v_col, agentgate.canonical_expr(v_type, v_col));
  END LOOP;
  v_sql := format(
    'SELECT agentgate_revision::text, jsonb_build_object(%s) FROM %I.%I WHERE %I = $1::%s%s',
    v_pairs, p_schema, p_table, p_pk, agentgate.sql_cast_type(p_pk_type),
    CASE WHEN p_lock THEN ' FOR UPDATE' ELSE '' END
  );
  EXECUTE v_sql INTO v_revision, v_current USING p_key;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('revision', v_revision, 'values', v_current);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.receipt_body(p_receipt_id uuid, p_revision_no int, p_hash text)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT jsonb_build_object(
    'receipt_id', r.id,
    'pr_id', r.pr_id,
    'revision', p_revision_no,
    'content_hash', p_hash,
    'committed_at', agentgate.iso_timestamptz(r.committed_at),
    'rows', r.rows
  )
  FROM agentgate.merge_receipts r
  WHERE r.id = p_receipt_id;
$$;

CREATE OR REPLACE FUNCTION agentgate.enqueue_merge(
  p_principal uuid,
  p_pr uuid,
  p_body jsonb,
  p_idempotency_key text,
  p_request_digest text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_route text := 'POST /v1/prs/' || p_pr::text || '/merge';
  v_existing jsonb;
  v_pr agentgate.prs%ROWTYPE;
  v_rev agentgate.pr_revisions%ROWTYPE;
  v_job agentgate.merge_jobs%ROWTYPE;
  v_receipt agentgate.merge_receipts%ROWTYPE;
  v_revision int;
  v_hash text;
  v_body jsonb;
  v_wrapper jsonb;
BEGIN
  v_existing := agentgate.idempotency_begin(p_principal, v_route, p_idempotency_key, p_request_digest);
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agentgate.principals WHERE id = p_principal) THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND OR NOT agentgate.principal_can_view(p_principal, p_pr) THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.state IN ('approved', 'queued') AND v_pr.expires_at <= now() THEN
    UPDATE agentgate.prs SET state = 'expired' WHERE id = p_pr;
    UPDATE agentgate.merge_jobs SET state = 'failed' WHERE pr_id = p_pr AND state = 'queued';
    INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
    VALUES (p_pr, p_principal, 'pr.expired', '{}'::jsonb);
    PERFORM agentgate.raise_app('PR_EXPIRED', 'pr has expired');
  END IF;
  BEGIN
    v_revision := (p_body->>'revision')::int;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'revision must be an integer');
  END;
  v_hash := p_body->>'content_hash';
  IF v_hash IS NULL OR v_hash !~ '^[0-9a-f]{64}$' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'content_hash is required');
  END IF;
  SELECT * INTO v_rev FROM agentgate.pr_revisions
  WHERE pr_id = p_pr AND revision_no = v_revision;
  IF NOT FOUND OR v_pr.active_revision_id IS DISTINCT FROM v_rev.id OR v_rev.content_hash IS DISTINCT FROM v_hash THEN
    PERFORM agentgate.raise_app('REVISION_MISMATCH', 'revision is not active');
  END IF;

  SELECT * INTO v_receipt FROM agentgate.merge_receipts WHERE revision_id = v_rev.id;
  IF FOUND THEN
    v_body := jsonb_build_object(
      'pr_id', p_pr,
      'revision', v_revision,
      'content_hash', v_hash,
      'state', 'merged',
      'job_id', (SELECT id FROM agentgate.merge_jobs WHERE revision_id = v_rev.id),
      'receipt', agentgate.receipt_body(v_receipt.id, v_revision, v_hash)
    );
    v_wrapper := jsonb_build_object('http_status', 200, 'body', v_body);
    RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
  END IF;

  SELECT * INTO v_job FROM agentgate.merge_jobs WHERE revision_id = v_rev.id AND state = 'queued';
  IF FOUND THEN
    v_body := jsonb_build_object(
      'pr_id', p_pr, 'revision', v_revision, 'content_hash', v_hash,
      'state', 'queued', 'job_id', v_job.id, 'receipt', 'null'::jsonb
    );
    v_wrapper := jsonb_build_object('http_status', 202, 'body', v_body);
    RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
  END IF;

  IF v_pr.state <> 'approved' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'pr is not approved');
  END IF;

  INSERT INTO agentgate.merge_jobs (pr_id, revision_id, state)
  VALUES (p_pr, v_rev.id, 'queued')
  RETURNING * INTO v_job;
  UPDATE agentgate.prs SET state = 'queued' WHERE id = p_pr;
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (p_pr, p_principal, 'pr.queued', jsonb_build_object('revision', v_revision, 'job_id', v_job.id));
  v_body := jsonb_build_object(
    'pr_id', p_pr, 'revision', v_revision, 'content_hash', v_hash,
    'state', 'queued', 'job_id', v_job.id, 'receipt', 'null'::jsonb
  );
  v_wrapper := jsonb_build_object('http_status', 202, 'body', v_body);
  RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.claim_merge_job(p_worker text, p_lease_seconds int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_job agentgate.merge_jobs%ROWTYPE;
BEGIN
  UPDATE agentgate.merge_jobs
  SET lease_owner = p_worker,
      lease_expires_at = now() + make_interval(secs => GREATEST(p_lease_seconds, 1)),
      attempts = attempts + 1
  WHERE id = (
    SELECT id FROM agentgate.merge_jobs
    WHERE state = 'queued'
      AND (lease_expires_at IS NULL OR lease_expires_at <= now())
    ORDER BY enqueued_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING * INTO v_job;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('job_id', v_job.id, 'pr_id', v_job.pr_id, 'revision_id', v_job.revision_id);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.merge_pr(p_job uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_job agentgate.merge_jobs%ROWTYPE;
  v_pr agentgate.prs%ROWTYPE;
  v_rev agentgate.pr_revisions%ROWTYPE;
  v_receipt agentgate.merge_receipts%ROWTYPE;
  v_approver uuid;
  v_proposer_kind text;
  v_scopes jsonb;
  v_policy_version int;
  v_latest int;
  v_change agentgate.pr_changes%ROWTYPE;
  v_schema text;
  v_table text;
  v_reg agentgate.table_registry%ROWTYPE;
  v_fingerprint text;
  v_key text;
  v_locked jsonb;
  v_scope jsonb;
  v_tenant text;
  v_sets text;
  v_col text;
  v_type text;
  v_sql text;
  v_count int;
  v_after jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_execution uuid := gen_random_uuid();
BEGIN
  SELECT * INTO v_job FROM agentgate.merge_jobs WHERE id = p_job FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'merge job not found');
  END IF;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = v_job.pr_id FOR UPDATE;
  SELECT * INTO v_rev FROM agentgate.pr_revisions WHERE id = v_job.revision_id;
  SELECT * INTO v_receipt FROM agentgate.merge_receipts WHERE revision_id = v_job.revision_id;
  IF FOUND THEN
    UPDATE agentgate.merge_jobs SET state = 'completed', lease_expires_at = NULL WHERE id = p_job;
    UPDATE agentgate.prs SET state = 'merged' WHERE id = v_pr.id AND state <> 'merged';
    RETURN agentgate.receipt_body(v_receipt.id, v_rev.revision_no, v_rev.content_hash);
  END IF;

  IF v_pr.active_revision_id IS DISTINCT FROM v_rev.id OR v_pr.state <> 'queued' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'pr is not queued for this revision');
  END IF;
  IF v_pr.expires_at <= now() THEN
    PERFORM agentgate.raise_app('PR_EXPIRED', 'pr has expired');
  END IF;

  SELECT version INTO v_policy_version FROM agentgate.policies WHERE id = v_rev.policy_id FOR SHARE;
  SELECT max(version) INTO v_latest FROM agentgate.policies;
  IF v_policy_version IS DISTINCT FROM v_latest THEN
    PERFORM agentgate.raise_app('POLICY_BLOCKED', 'policy changed and requires a new revision');
  END IF;

  SELECT principal_id INTO v_approver
  FROM agentgate.approvals
  WHERE revision_id = v_rev.id AND decision = 'approved' AND content_hash = v_rev.content_hash
  ORDER BY created_at DESC
  LIMIT 1;
  IF NOT FOUND OR NOT agentgate.reviewer_covers(v_approver, v_rev.id) THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'approval does not cover this revision');
  END IF;

  SELECT kind, scopes INTO v_proposer_kind, v_scopes
  FROM agentgate.principals WHERE id = v_pr.proposer_id;

  FOR v_schema, v_table IN
    SELECT DISTINCT schema_name, table_name
    FROM agentgate.pr_changes
    WHERE revision_id = v_rev.id
    ORDER BY schema_name, table_name
  LOOP
    EXECUTE format('LOCK TABLE %I.%I IN SHARE ROW EXCLUSIVE MODE', v_schema, v_table);
  END LOOP;

  FOR v_change IN
    SELECT * FROM agentgate.pr_changes
    WHERE revision_id = v_rev.id
    ORDER BY schema_name, table_name, row_key::text, ordinal
  LOOP
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_change.schema_name AND table_name = v_change.table_name;
    IF NOT FOUND THEN
      PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'table is not enrolled');
    END IF;
    v_fingerprint := agentgate.schema_fingerprint(format('%I.%I', v_reg.schema_name, v_reg.table_name)::regclass);
    IF v_fingerprint IS DISTINCT FROM v_reg.schema_fingerprint THEN
      PERFORM agentgate.raise_app('SCHEMA_CHANGED', 'enrolled schema changed');
    END IF;
    v_key := v_change.row_key ->> v_reg.primary_key_column;
    v_locked := agentgate.read_change_row(
      v_reg.schema_name, v_reg.table_name, v_reg.primary_key_column, v_reg.primary_key_type,
      v_key, v_change.before_values, true
    );
    IF v_locked IS NULL
       OR (v_locked->>'revision')::bigint IS DISTINCT FROM v_change.expected_revision
       OR v_locked->'values' IS DISTINCT FROM v_change.before_values THEN
      PERFORM agentgate.raise_app('DRIFT_CONFLICT', 'a target row changed after approval');
    END IF;

    IF v_proposer_kind <> 'admin' THEN
      SELECT elem INTO v_scope
      FROM jsonb_array_elements(COALESCE(v_scopes->'tables', '[]'::jsonb)) elem
      WHERE elem->>'schema' = v_reg.schema_name AND elem->>'name' = v_reg.table_name
      LIMIT 1;
      IF v_scope IS NULL THEN
        PERFORM agentgate.raise_app('FORBIDDEN', 'principal is not scoped to this table');
      END IF;
      IF v_reg.tenant_column IS NOT NULL THEN
        EXECUTE format('SELECT %I::text FROM %I.%I WHERE %I = $1::%s',
          v_reg.tenant_column, v_reg.schema_name, v_reg.table_name,
          v_reg.primary_key_column, agentgate.sql_cast_type(v_reg.primary_key_type))
        INTO v_tenant USING v_key;
        IF v_tenant IS NULL OR NOT (COALESCE(v_scope->'tenants', '[]'::jsonb) @> to_jsonb(v_tenant)) THEN
          PERFORM agentgate.raise_app('FORBIDDEN', 'principal is not scoped to this tenant');
        END IF;
      END IF;
    END IF;

    v_sets := '';
    IF v_change.after_values IS NULL OR v_change.after_values = '{}'::jsonb THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'a change has no columns to write');
    END IF;
    FOR v_col IN SELECT key FROM jsonb_object_keys(v_change.after_values) AS key ORDER BY key
    LOOP
      SELECT spec->>'type' INTO v_type
      FROM jsonb_array_elements(v_reg.allowed_columns) spec
      WHERE spec->>'name' = v_col;
      IF v_sets <> '' THEN
        v_sets := v_sets || ', ';
      END IF;
      v_sets := v_sets || agentgate.assignment_sql(v_col, v_type, v_change.after_values->v_col);
    END LOOP;
    v_sql := format(
      'UPDATE %I.%I SET %s WHERE %I = $1::%s AND agentgate_revision = $2::bigint',
      v_reg.schema_name, v_reg.table_name, v_sets,
      v_reg.primary_key_column, agentgate.sql_cast_type(v_reg.primary_key_type)
    );
    EXECUTE v_sql USING v_key, v_change.expected_revision;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count <> 1 THEN
      PERFORM agentgate.raise_app('DRIFT_CONFLICT', 'a target row changed after approval');
    END IF;
    v_after := agentgate.read_change_row(
      v_reg.schema_name, v_reg.table_name, v_reg.primary_key_column, v_reg.primary_key_type,
      v_key, v_change.after_values, false
    );
    IF v_after IS NULL
       OR (v_after->>'revision')::bigint IS DISTINCT FROM v_change.expected_revision + 1
       OR v_after->'values' IS DISTINCT FROM v_change.after_values THEN
      PERFORM agentgate.raise_app('CONSTRAINT_VIOLATION', 'merged row did not match the approved after-image');
    END IF;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'schema', v_reg.schema_name,
      'table', v_reg.table_name,
      'key', v_change.row_key,
      'before', v_change.before_values,
      'after', v_change.after_values,
      'revision', v_after->>'revision'
    ));
  END LOOP;

  INSERT INTO agentgate.merge_receipts (pr_id, revision_id, execution_id, rows)
  VALUES (v_pr.id, v_rev.id, v_execution, v_rows)
  RETURNING * INTO v_receipt;
  UPDATE agentgate.prs SET state = 'merged' WHERE id = v_pr.id;
  UPDATE agentgate.merge_jobs SET state = 'completed', lease_expires_at = NULL WHERE id = p_job;
  INSERT INTO agentgate.audit_events (pr_id, event_type, details)
  VALUES (v_pr.id, 'pr.merged', jsonb_build_object(
    'revision', v_rev.revision_no, 'content_hash', v_rev.content_hash, 'receipt_id', v_receipt.id
  ));
  INSERT INTO agentgate.outbox_events (pr_id, event_type, payload)
  VALUES (v_pr.id, 'pr.merged', jsonb_build_object(
    'pr_id', v_pr.id, 'revision', v_rev.revision_no,
    'content_hash', v_rev.content_hash, 'receipt_id', v_receipt.id
  ));
  RETURN agentgate.receipt_body(v_receipt.id, v_rev.revision_no, v_rev.content_hash);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.record_merge_failure(p_job uuid, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_job agentgate.merge_jobs%ROWTYPE;
  v_pr agentgate.prs%ROWTYPE;
  v_rev agentgate.pr_revisions%ROWTYPE;
  v_receipt agentgate.merge_receipts%ROWTYPE;
  v_state text;
  v_event text;
BEGIN
  SELECT * INTO v_job FROM agentgate.merge_jobs WHERE id = p_job FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'merge job not found');
  END IF;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = v_job.pr_id FOR UPDATE;
  SELECT * INTO v_rev FROM agentgate.pr_revisions WHERE id = v_job.revision_id;
  SELECT * INTO v_receipt FROM agentgate.merge_receipts WHERE revision_id = v_job.revision_id;
  IF FOUND THEN
    UPDATE agentgate.merge_jobs SET state = 'completed', lease_expires_at = NULL WHERE id = p_job;
    UPDATE agentgate.prs SET state = 'merged' WHERE id = v_pr.id;
    RETURN agentgate.receipt_body(v_receipt.id, v_rev.revision_no, v_rev.content_hash);
  END IF;
  v_state := CASE p_code
    WHEN 'DRIFT_CONFLICT' THEN 'conflicted'
    WHEN 'SCHEMA_CHANGED' THEN 'conflicted'
    WHEN 'PR_EXPIRED' THEN 'expired'
    WHEN 'POLICY_BLOCKED' THEN 'blocked'
    ELSE 'failed'
  END;
  v_event := CASE WHEN v_state = 'conflicted' THEN 'pr.conflicted'
                  WHEN v_state = 'expired' THEN 'pr.expired'
                  ELSE 'pr.failed' END;
  UPDATE agentgate.merge_jobs SET state = 'failed', lease_expires_at = NULL WHERE id = p_job;
  UPDATE agentgate.prs SET state = v_state WHERE id = v_pr.id AND state = 'queued';
  INSERT INTO agentgate.audit_events (pr_id, event_type, details)
  VALUES (v_pr.id, v_event, jsonb_build_object('code', p_code, 'revision', v_rev.revision_no));
  RETURN jsonb_build_object('pr_id', v_pr.id, 'state', v_state, 'code', p_code);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.expire_prs()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_count integer;
  v_job uuid;
BEGIN
  FOR v_job IN
    SELECT j.id
    FROM agentgate.merge_jobs j
    JOIN agentgate.prs p ON p.id = j.pr_id
    WHERE j.state = 'queued' AND p.expires_at <= now()
    ORDER BY j.id
    FOR UPDATE OF j
  LOOP
    NULL;
  END LOOP;
  WITH expired AS (
    UPDATE agentgate.prs
    SET state = 'expired'
    WHERE state IN ('pending_review', 'approved', 'queued') AND expires_at <= now()
    RETURNING id
  ),
  failed_jobs AS (
    UPDATE agentgate.merge_jobs
    SET state = 'failed', lease_expires_at = NULL
    WHERE state = 'queued' AND pr_id IN (SELECT id FROM expired)
    RETURNING pr_id
  )
  INSERT INTO agentgate.audit_events (pr_id, event_type, details)
  SELECT id, 'pr.expired', '{}'::jsonb FROM expired
  UNION ALL
  SELECT pr_id, 'pr.expired', '{}'::jsonb FROM failed_jobs WHERE false;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
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
    'execution_status', COALESCE(v_execution, 'null'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.create_revision(
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
  v_route text := 'POST /v1/prs/' || p_pr::text || '/revisions';
  v_existing jsonb;
  v_kind text;
  v_scopes jsonb;
  v_pr agentgate.prs%ROWTYPE;
  v_expiry int;
  v_expires_at timestamptz;
  v_plan jsonb;
  v_revision_no int;
  v_revision_id uuid := gen_random_uuid();
  v_policy_id uuid;
  v_policy_version int;
  v_body jsonb;
  v_wrapper jsonb;
  v_locked_job uuid;
BEGIN
  v_existing := agentgate.idempotency_begin(p_principal, v_route, p_idempotency_key, p_request_digest);
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  SELECT kind, scopes INTO v_kind, v_scopes FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  FOR v_locked_job IN
    SELECT id FROM agentgate.merge_jobs
    WHERE pr_id = p_pr AND state = 'queued'
    ORDER BY id
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND OR (v_pr.proposer_id <> p_principal AND v_kind <> 'admin') THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.state NOT IN ('pending_review', 'approved', 'rejected', 'expired', 'queued') THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'pr cannot be revised from its current state');
  END IF;
  IF v_pr.state = 'queued' THEN
    UPDATE agentgate.merge_jobs
    SET state = 'failed', lease_expires_at = NULL
    WHERE pr_id = p_pr AND state = 'queued';
  END IF;
  IF v_kind NOT IN ('proposer', 'admin') THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'principal cannot propose changes');
  END IF;
  v_pr.title := agentgate.require_text(p_body, 'title', 200);
  v_pr.reason := agentgate.require_text(p_body, 'reason', 4000);
  v_pr.task_id := p_body->>'task_id';
  IF v_pr.task_id IS NOT NULL AND length(v_pr.task_id) > 200 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'task_id is too long');
  END IF;
  v_expiry := agentgate.parse_expiry(p_body, p_min_expiry, p_max_expiry);
  v_expires_at := now() + make_interval(secs => v_expiry::double precision);
  v_pr.expires_at := v_expires_at;
  v_pr.state := 'pending_review';
  SELECT id, version INTO v_policy_id, v_policy_version FROM agentgate.policies ORDER BY version DESC LIMIT 1;
  v_plan := agentgate.plan_changes(v_kind, v_scopes, p_body, v_expires_at, p_max_rows);
  SELECT COALESCE(MAX(revision_no), 0) + 1 INTO v_revision_no
  FROM agentgate.pr_revisions WHERE pr_id = p_pr;
  INSERT INTO agentgate.pr_revisions (
    id, pr_id, revision_no, canonical_content, content_hash, policy_id, policy_decision
  ) VALUES (
    v_revision_id, p_pr, v_revision_no, v_plan->'content', v_plan->>'content_hash',
    v_policy_id, 'manual_review_required'
  );
  UPDATE agentgate.prs
  SET title = v_pr.title,
      reason = v_pr.reason,
      task_id = v_pr.task_id,
      state = 'pending_review',
      expires_at = v_expires_at,
      active_revision_id = v_revision_id
  WHERE id = p_pr;
  PERFORM agentgate.insert_revision_rows(v_revision_id, v_plan->'rows');
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (p_pr, p_principal, 'pr.revised', jsonb_build_object(
    'revision', v_revision_no, 'content_hash', v_plan->>'content_hash'
  ));
  v_body := agentgate.proposal_body(
    v_pr, v_revision_no, v_plan->>'content_hash', 'manual_review_required', v_policy_version, v_plan->'diff'
  );
  v_wrapper := jsonb_build_object('http_status', 201, 'body', v_body);
  RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA agentgate FROM PUBLIC, agentgate_api, agentgate_worker;
GRANT SELECT, INSERT, UPDATE ON agentgate.table_registry TO agentgate_migrator;

REVOKE ALL ON FUNCTION agentgate.sql_cast_type(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.assignment_sql(text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.read_change_row(text, text, text, text, text, jsonb, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.receipt_body(uuid, int, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.enqueue_merge(uuid, uuid, jsonb, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.claim_merge_job(text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.merge_pr(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.record_merge_failure(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentgate.enqueue_merge(uuid, uuid, jsonb, text, text) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.claim_merge_job(text, int) TO agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.merge_pr(uuid) TO agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.record_merge_failure(uuid, text) TO agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.expire_prs() TO agentgate_api, agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.get_pr(uuid, uuid) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.create_revision(uuid, uuid, jsonb, text, text, int, int, int) TO agentgate_api;

RESET ROLE;
