GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE TABLE IF NOT EXISTS agentgate.idempotency_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  principal_id uuid NOT NULL REFERENCES agentgate.principals (id),
  route text NOT NULL,
  idempotency_key text NOT NULL,
  request_digest text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (principal_id, route, idempotency_key)
);

CREATE OR REPLACE FUNCTION agentgate.idempotency_begin(
  p_principal uuid,
  p_route text,
  p_key text,
  p_digest text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_response jsonb;
  v_digest text;
BEGIN
  IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9._:-]{1,255}$' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'Idempotency-Key is invalid');
  END IF;
  IF p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'request digest is invalid');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_principal::text || '|' || p_route || '|' || p_key, 0));
  SELECT response, request_digest INTO v_response, v_digest
  FROM agentgate.idempotency_keys
  WHERE principal_id = p_principal AND route = p_route AND idempotency_key = p_key;
  IF FOUND THEN
    IF v_digest IS DISTINCT FROM p_digest THEN
      PERFORM agentgate.raise_app('IDEMPOTENCY_CONFLICT', 'idempotency key reused with a different request');
    END IF;
    RETURN v_response;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.idempotency_finish(
  p_principal uuid,
  p_route text,
  p_key text,
  p_digest text,
  p_response jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_existing jsonb;
  v_digest text;
BEGIN
  INSERT INTO agentgate.idempotency_keys (principal_id, route, idempotency_key, request_digest, response)
  VALUES (p_principal, p_route, p_key, p_digest, p_response)
  ON CONFLICT (principal_id, route, idempotency_key) DO NOTHING;
  IF FOUND THEN
    RETURN p_response;
  END IF;
  SELECT response, request_digest INTO v_existing, v_digest
  FROM agentgate.idempotency_keys
  WHERE principal_id = p_principal AND route = p_route AND idempotency_key = p_key;
  IF v_digest IS DISTINCT FROM p_digest THEN
    PERFORM agentgate.raise_app('IDEMPOTENCY_CONFLICT', 'idempotency key reused with a different request');
  END IF;
  RETURN v_existing;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.canonical_expr(p_type text, p_column text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_column text;
BEGIN
  v_column := agentgate.assert_ident(p_column);
  IF p_type = 'numeric' THEN
    RETURN format('COALESCE(to_jsonb(trim_scale(%I)::text), ''null''::jsonb)', v_column);
  ELSIF p_type = 'uuid' THEN
    RETURN format('COALESCE(to_jsonb(lower(%I::text)), ''null''::jsonb)', v_column);
  ELSIF p_type IN ('int2', 'int4', 'int8') THEN
    RETURN format('COALESCE(to_jsonb(%I::text), ''null''::jsonb)', v_column);
  ELSIF p_type = 'bool' THEN
    RETURN format('COALESCE(to_jsonb(%I), ''null''::jsonb)', v_column);
  ELSIF p_type = 'jsonb' THEN
    RETURN format('COALESCE(%I, ''null''::jsonb)', v_column);
  ELSIF p_type = 'timestamptz' THEN
    RETURN format(
      'COALESCE(to_jsonb(to_char(%I AT TIME ZONE ''UTC'', ''YYYY-MM-DD"T"HH24:MI:SS.US"Z"'')), ''null''::jsonb)',
      v_column);
  ELSIF p_type = 'date' THEN
    RETURN format('COALESCE(to_jsonb(to_char(%I, ''YYYY-MM-DD'')), ''null''::jsonb)', v_column);
  ELSIF p_type IN ('text', 'varchar') THEN
    RETURN format('COALESCE(to_jsonb(%I), ''null''::jsonb)', v_column);
  END IF;
  PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'unsupported column type');
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.capture_update(
  p_kind text,
  p_scopes jsonb,
  p_change jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_schema text;
  v_table text;
  v_pk_name text;
  v_pk_type text;
  v_tenant_column text;
  v_allowed jsonb;
  v_fingerprint text;
  v_set jsonb;
  v_pairs text := '';
  v_types jsonb := '{}'::jsonb;
  v_col text;
  v_spec jsonb;
  v_sql text;
  v_cast text;
  v_tenant_sql text;
  v_revision_text text;
  v_tenant_text text;
  v_before jsonb;
  v_key_norm jsonb;
  v_key_text text;
  v_expected_norm jsonb;
  v_expected_text text;
  v_scope jsonb;
  v_norm jsonb;
  v_current jsonb;
  v_changed boolean := false;
  v_before_out jsonb := '{}'::jsonb;
  v_after_out jsonb := '{}'::jsonb;
  v_fields jsonb := '[]'::jsonb;
  v_type text;
BEGIN
  IF COALESCE(p_change->>'operation', '') <> 'update' THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_OPERATION', 'only update is supported');
  END IF;
  v_schema := agentgate.assert_ident(p_change->>'schema');
  v_table := agentgate.assert_ident(p_change->>'table');
  SELECT primary_key_column, primary_key_type, allowed_columns, tenant_column, schema_fingerprint
  INTO v_pk_name, v_pk_type, v_allowed, v_tenant_column, v_fingerprint
  FROM agentgate.table_registry
  WHERE schema_name = v_schema AND table_name = v_table;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'table is not enrolled');
  END IF;

  IF p_kind <> 'admin' THEN
    SELECT elem INTO v_scope
    FROM jsonb_array_elements(COALESCE(p_scopes->'tables', '[]'::jsonb)) elem
    WHERE elem->>'schema' = v_schema AND elem->>'name' = v_table
    LIMIT 1;
    IF v_scope IS NULL THEN
      PERFORM agentgate.raise_app('FORBIDDEN', 'principal is not scoped to this table');
    END IF;
  END IF;

  IF jsonb_typeof(p_change->'key') <> 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_change->'key')) <> 1
     OR NOT (p_change->'key' ? v_pk_name) THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'key must contain only the primary key');
  END IF;
  v_key_norm := agentgate.normalize_input(v_pk_type, p_change->'key'->v_pk_name);
  IF v_key_norm = 'null'::jsonb THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'key is required');
  END IF;
  v_key_text := v_key_norm #>> '{}';
  IF p_change->>'expected_revision' IS NULL THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'expected_revision is required');
  END IF;
  v_expected_norm := agentgate.normalize_input('int8', to_jsonb(p_change->>'expected_revision'));
  v_expected_text := v_expected_norm #>> '{}';

  v_set := p_change->'set';
  IF jsonb_typeof(v_set) <> 'object' OR v_set = '{}'::jsonb THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'set must be a non-empty object');
  END IF;

  FOR v_col IN SELECT key FROM jsonb_object_keys(v_set) AS key ORDER BY key
  LOOP
    PERFORM agentgate.assert_ident(v_col);
    IF v_col IN ('agentgate_revision', v_pk_name) THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'primary key and revision columns cannot be changed');
    END IF;
    SELECT spec INTO v_spec
    FROM jsonb_array_elements(v_allowed) spec
    WHERE spec->>'name' = v_col;
    IF v_spec IS NULL THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'column is not allowed');
    END IF;
    v_type := v_spec->>'type';
    v_types := v_types || jsonb_build_object(v_col, v_type);
    IF v_pairs <> '' THEN
      v_pairs := v_pairs || ', ';
    END IF;
    v_pairs := v_pairs || format('%L, %s', v_col, agentgate.canonical_expr(v_type, v_col));
  END LOOP;

  v_cast := CASE v_pk_type
    WHEN 'int2' THEN 'smallint'
    WHEN 'int4' THEN 'integer'
    WHEN 'int8' THEN 'bigint'
    WHEN 'uuid' THEN 'uuid'
    ELSE NULL
  END;
  IF v_tenant_column IS NULL THEN
    v_tenant_sql := 'NULL::text';
  ELSE
    v_tenant_sql := format('%I::text', agentgate.assert_ident(v_tenant_column));
  END IF;
  v_sql := format(
    'SELECT agentgate_revision::text, %s, jsonb_build_object(%s) FROM %I.%I WHERE %I = $1::%s',
    v_tenant_sql, v_pairs, v_schema, v_table, v_pk_name, v_cast
  );
  DECLARE
    v_row_count int := 0;
  BEGIN
    EXECUTE v_sql INTO v_revision_text, v_tenant_text, v_before USING v_key_text;
    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    -- EXECUTE can leave FOUND unchanged when it returns no row. ROW_COUNT does not.
    IF v_row_count = 0 THEN
      PERFORM agentgate.raise_app('NOT_FOUND', 'row not found');
    END IF;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'key does not match the primary key type');
  END;

  IF p_kind <> 'admin' AND v_tenant_column IS NOT NULL THEN
    IF v_tenant_text IS NULL
       OR NOT (COALESCE(v_scope->'tenants', '[]'::jsonb) @> to_jsonb(v_tenant_text)) THEN
      PERFORM agentgate.raise_app('FORBIDDEN', 'principal is not scoped to this tenant');
    END IF;
  END IF;
  IF v_revision_text IS DISTINCT FROM v_expected_text THEN
    PERFORM agentgate.raise_app('REVISION_MISMATCH', 'expected revision does not match the current row');
  END IF;

  FOR v_col IN SELECT key FROM jsonb_each(v_types) AS t(key, value) ORDER BY key
  LOOP
    v_type := v_types->>v_col;
    v_norm := agentgate.normalize_input(v_type, v_set->v_col);
    v_current := COALESCE(v_before->v_col, 'null'::jsonb);
    IF v_norm IS DISTINCT FROM v_current THEN
      v_changed := true;
    END IF;
    v_before_out := v_before_out || jsonb_build_object(v_col, v_current);
    v_after_out := v_after_out || jsonb_build_object(v_col, v_norm);
    v_fields := v_fields || jsonb_build_array(jsonb_build_object(
      'column', v_col, 'type', v_type, 'before', v_current, 'after', v_norm
    ));
  END LOOP;
  IF NOT v_changed THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'change is a no-op');
  END IF;

  RETURN jsonb_build_object(
    'schema_name', v_schema,
    'table_name', v_table,
    'row_key', jsonb_build_object(v_pk_name, to_jsonb(v_key_text)),
    'key_token', v_schema || '.' || v_table || ':' || v_key_text,
    'expected_revision', v_expected_text,
    'before_values', v_before_out,
    'after_values', v_after_out,
    'canonical', jsonb_build_object(
      'after', v_after_out,
      'before', v_before_out,
      'expected_revision', v_expected_text,
      'key', jsonb_build_object(v_pk_name, to_jsonb(v_key_text)),
      'operation', 'update',
      'schema', v_schema,
      'schema_fingerprint', v_fingerprint,
      'table', v_table,
      'types', v_types
    ),
    'diff', jsonb_build_object(
      'operation', 'update',
      'schema', v_schema,
      'table', v_table,
      'key', jsonb_build_object(v_pk_name, to_jsonb(v_key_text)),
      'expected_revision', v_expected_text,
      'fields', v_fields
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.plan_changes(
  p_kind text,
  p_scopes jsonb,
  p_body jsonb,
  p_expires_at timestamptz,
  p_max_rows int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_changes jsonb;
  v_change jsonb;
  v_captured jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_rows jsonb := '[]'::jsonb;
  v_canonical jsonb := '[]'::jsonb;
  v_diff jsonb := '[]'::jsonb;
  v_ordinal int := 0;
  v_content jsonb;
  v_task text;
BEGIN
  IF p_body ? 'read_tokens'
     AND jsonb_typeof(p_body->'read_tokens') = 'array'
     AND jsonb_array_length(p_body->'read_tokens') > 0 THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_OPERATION', 'tracked read tokens are not available yet');
  END IF;
  v_changes := p_body->'changes';
  IF jsonb_typeof(v_changes) <> 'array' OR jsonb_array_length(v_changes) < 1 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'changes must be a non-empty array');
  END IF;
  IF jsonb_array_length(v_changes) > p_max_rows THEN
    PERFORM agentgate.raise_app('LIMIT_EXCEEDED', 'too many changes in one proposal');
  END IF;
  FOR v_change IN SELECT value FROM jsonb_array_elements(v_changes)
  LOOP
    v_captured := agentgate.capture_update(p_kind, p_scopes, v_change);
    IF v_captured->>'key_token' = ANY (v_seen) THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'duplicate target in proposal');
    END IF;
    v_seen := array_append(v_seen, v_captured->>'key_token');
    v_ordinal := v_ordinal + 1;
    v_rows := v_rows || jsonb_build_array(v_captured || jsonb_build_object('ordinal', v_ordinal));
    v_canonical := v_canonical || jsonb_build_array(v_captured->'canonical');
    v_diff := v_diff || jsonb_build_array(v_captured->'diff');
  END LOOP;
  v_task := p_body->>'task_id';
  v_content := jsonb_build_object(
    'changes', v_canonical,
    'dependencies', '[]'::jsonb,
    'expires_at', agentgate.iso_timestamptz(p_expires_at),
    'scope', COALESCE(p_scopes, '{}'::jsonb),
    'task_id', COALESCE(to_jsonb(v_task), 'null'::jsonb)
  );
  RETURN jsonb_build_object(
    'content', v_content,
    'content_hash', agentgate.sha256_hex(convert_to(v_content::text, 'UTF8')),
    'diff', jsonb_build_object('changes', v_diff),
    'rows', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.require_text(p_body jsonb, p_field text, p_max int)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_value text := p_body->>p_field;
BEGIN
  IF v_value IS NULL OR length(btrim(v_value)) = 0 OR length(v_value) > p_max THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', p_field || ' is required');
  END IF;
  RETURN v_value;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.parse_expiry(p_body jsonb, p_min int, p_max int)
RETURNS int
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_expiry int;
BEGIN
  BEGIN
    v_expiry := (p_body->>'expires_in_seconds')::int;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'expires_in_seconds must be an integer');
  END;
  IF v_expiry IS NULL OR v_expiry < p_min OR v_expiry > p_max THEN
    PERFORM agentgate.raise_app('LIMIT_EXCEEDED', 'expires_in_seconds is outside the allowed range');
  END IF;
  RETURN v_expiry;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.insert_revision_rows(
  p_revision uuid,
  p_rows jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_row jsonb;
BEGIN
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO agentgate.pr_changes (
      revision_id, ordinal, operation, schema_name, table_name, row_key,
      expected_revision, before_values, after_values
    ) VALUES (
      p_revision,
      (v_row->>'ordinal')::int,
      'update',
      v_row->>'schema_name',
      v_row->>'table_name',
      v_row->'row_key',
      (v_row->>'expected_revision')::bigint,
      v_row->'before_values',
      v_row->'after_values'
    );
  END LOOP;
END;
$$;

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
    'diff', p_diff
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.propose(
  p_principal uuid,
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
  v_existing jsonb;
  v_kind text;
  v_scopes jsonb;
  v_title text;
  v_reason text;
  v_task text;
  v_expiry int;
  v_expires_at timestamptz;
  v_plan jsonb;
  v_pr agentgate.prs%ROWTYPE;
  v_policy_id uuid;
  v_policy_version int;
  v_revision_id uuid := gen_random_uuid();
  v_body jsonb;
  v_wrapper jsonb;
BEGIN
  v_existing := agentgate.idempotency_begin(p_principal, 'POST /v1/prs', p_idempotency_key, p_request_digest);
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  SELECT kind, scopes INTO v_kind, v_scopes FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  IF v_kind NOT IN ('proposer', 'admin') THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'principal cannot propose changes');
  END IF;
  v_title := agentgate.require_text(p_body, 'title', 200);
  v_reason := agentgate.require_text(p_body, 'reason', 4000);
  v_task := p_body->>'task_id';
  IF v_task IS NOT NULL AND length(v_task) > 200 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'task_id is too long');
  END IF;
  v_expiry := agentgate.parse_expiry(p_body, p_min_expiry, p_max_expiry);
  v_expires_at := now() + make_interval(secs => v_expiry::double precision);
  SELECT id, version INTO v_policy_id, v_policy_version
  FROM agentgate.policies ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('POLICY_BLOCKED', 'no policy is configured');
  END IF;
  v_plan := agentgate.plan_changes(v_kind, v_scopes, p_body, v_expires_at, p_max_rows);

  INSERT INTO agentgate.prs (id, title, reason, task_id, proposer_id, state, expires_at)
  VALUES (gen_random_uuid(), v_title, v_reason, v_task, p_principal, 'pending_review', v_expires_at)
  RETURNING * INTO v_pr;
  INSERT INTO agentgate.pr_revisions (
    id, pr_id, revision_no, canonical_content, content_hash, policy_id, policy_decision
  ) VALUES (
    v_revision_id, v_pr.id, 1, v_plan->'content', v_plan->>'content_hash',
    v_policy_id, 'manual_review_required'
  );
  UPDATE agentgate.prs SET active_revision_id = v_revision_id WHERE id = v_pr.id;
  v_pr.active_revision_id := v_revision_id;
  PERFORM agentgate.insert_revision_rows(v_revision_id, v_plan->'rows');
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (v_pr.id, p_principal, 'pr.created', jsonb_build_object(
    'revision', 1, 'content_hash', v_plan->>'content_hash'
  ));
  v_body := agentgate.proposal_body(
    v_pr, 1, v_plan->>'content_hash', 'manual_review_required', v_policy_version, v_plan->'diff'
  );
  v_wrapper := jsonb_build_object('http_status', 201, 'body', v_body);
  RETURN agentgate.idempotency_finish(p_principal, 'POST /v1/prs', p_idempotency_key, p_request_digest, v_wrapper);
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
BEGIN
  v_existing := agentgate.idempotency_begin(p_principal, v_route, p_idempotency_key, p_request_digest);
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  SELECT kind, scopes INTO v_kind, v_scopes FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND OR (v_pr.proposer_id <> p_principal AND v_kind <> 'admin') THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.state NOT IN ('pending_review', 'approved', 'rejected', 'expired') THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'pr cannot be revised from its current state');
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

CREATE OR REPLACE FUNCTION agentgate.decide_pr(
  p_principal uuid,
  p_pr uuid,
  p_body jsonb,
  p_idempotency_key text,
  p_request_digest text,
  p_decision text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_route text := 'POST /v1/prs/' || p_pr::text || '/' || CASE WHEN p_decision = 'approved' THEN 'approve' ELSE 'reject' END;
  v_existing jsonb;
  v_kind text;
  v_pr agentgate.prs%ROWTYPE;
  v_rev agentgate.pr_revisions%ROWTYPE;
  v_revision int;
  v_hash text;
  v_reason text;
  v_state text;
  v_body jsonb;
  v_wrapper jsonb;
BEGIN
  v_existing := agentgate.idempotency_begin(p_principal, v_route, p_idempotency_key, p_request_digest);
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  SELECT kind INTO v_kind FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.proposer_id = p_principal THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'an agent cannot approve its own PR');
  END IF;
  IF v_kind <> 'reviewer' THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'principal cannot review');
  END IF;
  IF v_pr.state IN ('pending_review', 'approved') AND v_pr.expires_at <= now() THEN
    UPDATE agentgate.prs SET state = 'expired' WHERE id = p_pr;
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
  IF NOT FOUND OR v_pr.active_revision_id IS DISTINCT FROM v_rev.id THEN
    PERFORM agentgate.raise_app('REVISION_MISMATCH', 'revision is not active');
  END IF;
  IF v_rev.content_hash IS DISTINCT FROM v_hash THEN
    PERFORM agentgate.raise_app('REVISION_MISMATCH', 'content hash does not match');
  END IF;
  IF v_pr.state <> 'pending_review' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'pr is not pending review');
  END IF;
  IF NOT agentgate.reviewer_covers(p_principal, v_rev.id) THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'reviewer is not assigned to every table in the proposal');
  END IF;
  v_reason := p_body->>'reason';
  IF p_decision = 'rejected' AND (v_reason IS NULL OR length(btrim(v_reason)) = 0) THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'reason is required');
  END IF;
  v_state := CASE WHEN p_decision = 'approved' THEN 'approved' ELSE 'rejected' END;
  INSERT INTO agentgate.approvals (pr_id, revision_id, principal_id, decision, reason, content_hash)
  VALUES (p_pr, v_rev.id, p_principal, p_decision, v_reason, v_hash);
  UPDATE agentgate.prs SET state = v_state WHERE id = p_pr;
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (
    p_pr,
    p_principal,
    CASE WHEN p_decision = 'approved' THEN 'pr.approved' ELSE 'pr.rejected' END,
    jsonb_build_object('revision', v_revision, 'content_hash', v_hash)
  );
  v_body := jsonb_build_object(
    'pr_id', p_pr,
    'revision', v_revision,
    'content_hash', v_hash,
    'state', v_state,
    'decision', p_decision
  );
  v_wrapper := jsonb_build_object('http_status', 200, 'body', v_body);
  RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.approve(
  p_principal uuid, p_pr uuid, p_body jsonb, p_idempotency_key text, p_request_digest text
) RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
  SELECT agentgate.decide_pr(p_principal, p_pr, p_body, p_idempotency_key, p_request_digest, 'approved');
$$;

CREATE OR REPLACE FUNCTION agentgate.reject(
  p_principal uuid, p_pr uuid, p_body jsonb, p_idempotency_key text, p_request_digest text
) RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
  SELECT agentgate.decide_pr(p_principal, p_pr, p_body, p_idempotency_key, p_request_digest, 'rejected');
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA agentgate FROM PUBLIC, agentgate_api, agentgate_worker;
GRANT SELECT, INSERT, UPDATE ON agentgate.table_registry TO agentgate_migrator;

REVOKE ALL ON FUNCTION agentgate.idempotency_begin(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.idempotency_finish(uuid, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.canonical_expr(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.capture_update(text, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.plan_changes(text, jsonb, jsonb, timestamptz, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.require_text(jsonb, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.parse_expiry(jsonb, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.insert_revision_rows(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.proposal_body(agentgate.prs, int, text, text, int, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.propose(uuid, jsonb, text, text, int, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.create_revision(uuid, uuid, jsonb, text, text, int, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.decide_pr(uuid, uuid, jsonb, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.approve(uuid, uuid, jsonb, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.reject(uuid, uuid, jsonb, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentgate.propose(uuid, jsonb, text, text, int, int, int) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.create_revision(uuid, uuid, jsonb, text, text, int, int, int) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.approve(uuid, uuid, jsonb, text, text) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.reject(uuid, uuid, jsonb, text, text) TO agentgate_api;

RESET ROLE;
