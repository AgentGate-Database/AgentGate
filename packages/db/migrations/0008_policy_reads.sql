-- Declarative policy, tracked reads, and rolling merge limits.
GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE TABLE IF NOT EXISTS agentgate.read_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  principal_id uuid NOT NULL REFERENCES agentgate.principals (id),
  secret_digest bytea NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agentgate.read_snapshot_rows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_id uuid NOT NULL REFERENCES agentgate.read_snapshots (id),
  ordinal int NOT NULL,
  schema_name text NOT NULL,
  table_name text NOT NULL,
  row_key jsonb NOT NULL,
  expected_revision bigint NOT NULL,
  before_values jsonb NOT NULL,
  UNIQUE (snapshot_id, ordinal)
);

CREATE TABLE IF NOT EXISTS agentgate.pr_dependencies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  revision_id uuid NOT NULL REFERENCES agentgate.pr_revisions (id),
  ordinal int NOT NULL,
  schema_name text NOT NULL,
  table_name text NOT NULL,
  row_key jsonb NOT NULL,
  expected_revision bigint NOT NULL,
  before_values jsonb NOT NULL,
  UNIQUE (revision_id, ordinal)
);

CREATE TABLE IF NOT EXISTS agentgate.rate_principals (
  principal_id uuid PRIMARY KEY REFERENCES agentgate.principals (id)
);

CREATE TABLE IF NOT EXISTS agentgate.rate_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  principal_id uuid NOT NULL REFERENCES agentgate.rate_principals (principal_id),
  reserved_at timestamptz NOT NULL DEFAULT now(),
  row_count int NOT NULL,
  request_count int NOT NULL
);

CREATE INDEX IF NOT EXISTS rate_reservations_window_idx
  ON agentgate.rate_reservations (principal_id, reserved_at);

CREATE OR REPLACE FUNCTION agentgate.effect_rank(p_effect text)
RETURNS int
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT CASE p_effect
    WHEN 'block' THEN 3
    WHEN 'manual_review_required' THEN 2
    WHEN 'auto_approved' THEN 1
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION agentgate.rule_matches(
  p_rule jsonb,
  p_schema text,
  p_table text,
  p_operation text,
  p_columns jsonb,
  p_row_count int
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_effect text := p_rule->>'effect';
  v_col text;
BEGIN
  IF agentgate.effect_rank(v_effect) IS NULL THEN
    RETURN false;
  END IF;
  IF p_rule ? 'schema' AND p_rule->>'schema' IS DISTINCT FROM p_schema THEN
    RETURN false;
  END IF;
  IF p_rule ? 'table' AND p_rule->>'table' IS DISTINCT FROM p_table THEN
    RETURN false;
  END IF;
  IF p_rule ? 'operations'
     AND NOT COALESCE(p_rule->'operations', '[]'::jsonb) @> to_jsonb(p_operation) THEN
    RETURN false;
  END IF;
  IF p_rule ? 'columns' THEN
    IF v_effect = 'auto_approved' THEN
      FOR v_col IN SELECT key FROM jsonb_object_keys(COALESCE(p_columns, '{}'::jsonb)) AS key
      LOOP
        IF NOT COALESCE(p_rule->'columns', '[]'::jsonb) @> to_jsonb(v_col) THEN
          RETURN false;
        END IF;
      END LOOP;
    ELSE
      FOR v_col IN SELECT key FROM jsonb_object_keys(COALESCE(p_columns, '{}'::jsonb)) AS key
      LOOP
        IF COALESCE(p_rule->'columns', '[]'::jsonb) @> to_jsonb(v_col) THEN
          RETURN true;
        END IF;
      END LOOP;
      RETURN false;
    END IF;
  END IF;
  IF v_effect = 'auto_approved' AND p_rule ? 'max_rows'
     AND p_row_count > (p_rule->>'max_rows')::int THEN
    RETURN false;
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.evaluate_policy(p_rows jsonb, p_document jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_default text := COALESCE(p_document->>'default', 'manual_review_required');
  v_count int := COALESCE(jsonb_array_length(p_rows), 0);
  v_row jsonb;
  v_rule jsonb;
  v_best int;
  v_rank int;
  v_overall int := 0;
BEGIN
  IF agentgate.effect_rank(v_default) IS NULL THEN
    PERFORM agentgate.raise_app('POLICY_BLOCKED', 'policy default is invalid');
  END IF;
  FOR v_row IN SELECT value FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb))
  LOOP
    v_best := NULL;
    FOR v_rule IN SELECT value FROM jsonb_array_elements(COALESCE(p_document->'rules', '[]'::jsonb))
    LOOP
      IF agentgate.rule_matches(
        v_rule,
        v_row->>'schema_name',
        v_row->>'table_name',
        COALESCE(v_row->>'operation', 'update'),
        v_row->'after_values',
        v_count
      ) THEN
        v_rank := agentgate.effect_rank(v_rule->>'effect');
        IF v_best IS NULL OR v_rank > v_best THEN
          v_best := v_rank;
        END IF;
      END IF;
    END LOOP;
    IF v_best IS NULL THEN
      v_best := agentgate.effect_rank(v_default);
    END IF;
    IF v_best > v_overall THEN
      v_overall := v_best;
    END IF;
  END LOOP;
  IF v_overall = 0 THEN
    v_overall := agentgate.effect_rank(v_default);
  END IF;
  RETURN CASE v_overall
    WHEN 3 THEN 'block'
    WHEN 1 THEN 'auto_approved'
    ELSE 'manual_review_required'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.publish_policy(p_document jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_version int;
  v_rule jsonb;
  v_limits jsonb;
BEGIN
  IF jsonb_typeof(p_document) <> 'object' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'policy document must be an object');
  END IF;
  IF agentgate.effect_rank(COALESCE(p_document->>'default', 'manual_review_required')) IS NULL THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'policy default is invalid');
  END IF;
  IF p_document ? 'rules' AND jsonb_typeof(p_document->'rules') <> 'array' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'policy rules must be an array');
  END IF;
  FOR v_rule IN SELECT value FROM jsonb_array_elements(COALESCE(p_document->'rules', '[]'::jsonb))
  LOOP
    IF agentgate.effect_rank(v_rule->>'effect') IS NULL THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'policy rule effect is invalid');
    END IF;
  END LOOP;
  IF p_document ? 'limits' THEN
    v_limits := p_document->'limits';
    IF jsonb_typeof(v_limits) <> 'object'
       OR COALESCE((v_limits->>'window_seconds')::int, 0) < 1
       OR COALESCE((v_limits->>'max_rows')::int, 0) < 1
       OR COALESCE((v_limits->>'max_requests')::int, 0) < 1 THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'policy limits are invalid');
    END IF;
  END IF;
  LOCK TABLE agentgate.policies IN SHARE ROW EXCLUSIVE MODE;
  INSERT INTO agentgate.policies (version, document)
  SELECT COALESCE(MAX(version), 0) + 1, p_document
  FROM agentgate.policies
  RETURNING version INTO v_version;
  RETURN v_version;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.random_hex(p_bytes int)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_schema text;
  v_out text;
BEGIN
  SELECT n.nspname INTO v_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pgcrypto';
  IF v_schema IS NULL THEN
    PERFORM agentgate.raise_app('INTERNAL', 'pgcrypto is not installed');
  END IF;
  EXECUTE format('SELECT encode(%I.gen_random_bytes($1), ''hex'')', v_schema)
  INTO v_out USING p_bytes;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.create_read(
  p_principal uuid,
  p_body jsonb,
  p_min_expiry int,
  p_max_expiry int,
  p_max_rows int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_kind text;
  v_scopes jsonb;
  v_reads jsonb;
  v_read jsonb;
  v_schema text;
  v_table text;
  v_pk_name text;
  v_pk_type text;
  v_tenant_column text;
  v_allowed jsonb;
  v_scope jsonb;
  v_col text;
  v_placeholder jsonb;
  v_key_norm jsonb;
  v_key_text text;
  v_seen text[] := ARRAY[]::text[];
  v_locked jsonb;
  v_tenant text;
  v_rows jsonb := '[]'::jsonb;
  v_ordinal int := 0;
  v_id uuid := gen_random_uuid();
  v_secret text;
  v_expires_at timestamptz;
  v_expiry int;
BEGIN
  SELECT kind, scopes INTO v_kind, v_scopes FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNAUTHORIZED', 'unknown principal');
  END IF;
  IF v_kind NOT IN ('proposer', 'admin') THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'principal cannot read rows');
  END IF;
  v_reads := p_body->'reads';
  IF jsonb_typeof(v_reads) <> 'array' OR jsonb_array_length(v_reads) < 1 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'reads must be a non-empty array');
  END IF;
  IF jsonb_array_length(v_reads) > p_max_rows THEN
    PERFORM agentgate.raise_app('LIMIT_EXCEEDED', 'too many reads in one request');
  END IF;
  v_expiry := agentgate.parse_expiry(p_body, p_min_expiry, p_max_expiry);
  v_expires_at := now() + make_interval(secs => v_expiry::double precision);
  v_secret := agentgate.random_hex(32);
  INSERT INTO agentgate.read_snapshots (id, principal_id, secret_digest, expires_at)
  VALUES (
    v_id, p_principal,
    decode(agentgate.sha256_hex(convert_to(v_secret, 'UTF8')), 'hex'),
    v_expires_at
  );
  FOR v_read IN SELECT value FROM jsonb_array_elements(v_reads)
  LOOP
    v_schema := agentgate.assert_ident(v_read->>'schema');
    v_table := agentgate.assert_ident(v_read->>'table');
    SELECT primary_key_column, primary_key_type, tenant_column, allowed_columns
    INTO v_pk_name, v_pk_type, v_tenant_column, v_allowed
    FROM agentgate.table_registry
    WHERE schema_name = v_schema AND table_name = v_table;
    IF NOT FOUND THEN
      PERFORM agentgate.raise_app('NOT_FOUND', 'row not found');
    END IF;
    v_scope := NULL;
    IF v_kind <> 'admin' THEN
      SELECT elem INTO v_scope
      FROM jsonb_array_elements(COALESCE(v_scopes->'tables', '[]'::jsonb)) elem
      WHERE elem->>'schema' = v_schema AND elem->>'name' = v_table
      LIMIT 1;
      IF v_scope IS NULL THEN
        PERFORM agentgate.raise_app('NOT_FOUND', 'row not found');
      END IF;
    END IF;
    IF jsonb_typeof(v_read->'key') <> 'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_read->'key')) <> 1
       OR NOT (v_read->'key' ? v_pk_name) THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'key must contain only the primary key');
    END IF;
    v_key_norm := agentgate.normalize_input(v_pk_type, v_read->'key'->v_pk_name);
    IF v_key_norm = 'null'::jsonb THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'key is required');
    END IF;
    v_key_text := v_key_norm #>> '{}';
    IF (v_schema || '.' || v_table || ':' || v_key_text) = ANY (v_seen) THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'duplicate read target');
    END IF;
    v_seen := array_append(v_seen, v_schema || '.' || v_table || ':' || v_key_text);
    IF jsonb_typeof(v_read->'columns') <> 'array' OR jsonb_array_length(v_read->'columns') < 1 THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'columns must be a non-empty array');
    END IF;
    v_placeholder := '{}'::jsonb;
    FOR v_col IN SELECT value FROM jsonb_array_elements_text(v_read->'columns') AS value ORDER BY value
    LOOP
      PERFORM agentgate.assert_ident(v_col);
      IF v_col IN ('agentgate_revision', v_pk_name) THEN
        PERFORM agentgate.raise_app('VALIDATION_FAILED', 'primary key and revision columns cannot be read here');
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_allowed) spec WHERE spec->>'name' = v_col
      ) THEN
        PERFORM agentgate.raise_app('VALIDATION_FAILED', 'column is not allowed');
      END IF;
      v_placeholder := v_placeholder || jsonb_build_object(v_col, 'null'::jsonb);
    END LOOP;
    v_locked := agentgate.read_change_row(
      v_schema, v_table, v_pk_name, v_pk_type, v_key_text, v_placeholder, false
    );
    IF v_locked IS NULL THEN
      PERFORM agentgate.raise_app('NOT_FOUND', 'row not found');
    END IF;
    IF v_kind <> 'admin' AND v_tenant_column IS NOT NULL THEN
      EXECUTE format(
        'SELECT %I::text FROM %I.%I WHERE %I = $1::%s',
        v_tenant_column, v_schema, v_table, v_pk_name, agentgate.sql_cast_type(v_pk_type)
      ) INTO v_tenant USING v_key_text;
      IF v_tenant IS NULL OR NOT (COALESCE(v_scope->'tenants', '[]'::jsonb) @> to_jsonb(v_tenant)) THEN
        PERFORM agentgate.raise_app('NOT_FOUND', 'row not found');
      END IF;
    END IF;
    v_ordinal := v_ordinal + 1;
    INSERT INTO agentgate.read_snapshot_rows (
      snapshot_id, ordinal, schema_name, table_name, row_key, expected_revision, before_values
    ) VALUES (
      v_id, v_ordinal, v_schema, v_table,
      jsonb_build_object(v_pk_name, to_jsonb(v_key_text)),
      (v_locked->>'revision')::bigint,
      v_locked->'values'
    );
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'schema', v_schema,
      'table', v_table,
      'key', jsonb_build_object(v_pk_name, to_jsonb(v_key_text)),
      'revision', v_locked->>'revision',
      'values', v_locked->'values'
    ));
  END LOOP;
  RETURN jsonb_build_object(
    'token', 'agr_' || v_id::text || '_' || v_secret,
    'expires_at', agentgate.iso_timestamptz(v_expires_at),
    'rows', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.freeze_dependencies(p_principal uuid, p_tokens jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_token text;
  v_id uuid;
  v_secret text;
  v_snap agentgate.read_snapshots%ROWTYPE;
  v_row agentgate.read_snapshot_rows%ROWTYPE;
  v_item jsonb;
  v_key text;
  v_seen jsonb := '{}'::jsonb;
  v_deps jsonb := '[]'::jsonb;
BEGIN
  IF p_tokens IS NULL OR jsonb_typeof(p_tokens) <> 'array' OR jsonb_array_length(p_tokens) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;
  FOR v_token IN SELECT value FROM jsonb_array_elements_text(p_tokens) AS value
  LOOP
    IF v_token !~ '^agr_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_[0-9a-f]{64}$' THEN
      PERFORM agentgate.raise_app('NOT_FOUND', 'read token not found');
    END IF;
    v_id := substring(v_token from 5 for 36)::uuid;
    v_secret := substring(v_token from 42);
    SELECT * INTO v_snap
    FROM agentgate.read_snapshots
    WHERE id = v_id
      AND principal_id = p_principal
      AND secret_digest = decode(agentgate.sha256_hex(convert_to(v_secret, 'UTF8')), 'hex');
    IF NOT FOUND THEN
      PERFORM agentgate.raise_app('NOT_FOUND', 'read token not found');
    END IF;
    IF v_snap.expires_at <= now() THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'read token expired');
    END IF;
    FOR v_row IN
      SELECT * FROM agentgate.read_snapshot_rows
      WHERE snapshot_id = v_snap.id
      ORDER BY ordinal
    LOOP
      v_key := v_row.schema_name || '.' || v_row.table_name || ':' || v_row.row_key::text;
      v_item := jsonb_build_object(
        'schema', v_row.schema_name,
        'table', v_row.table_name,
        'key', v_row.row_key,
        'revision', v_row.expected_revision::text,
        'values', v_row.before_values,
        'schema_name', v_row.schema_name,
        'table_name', v_row.table_name,
        'row_key', v_row.row_key,
        'expected_revision', v_row.expected_revision::text,
        'before_values', v_row.before_values
      );
      IF v_seen ? v_key AND v_seen->v_key IS DISTINCT FROM v_item THEN
        PERFORM agentgate.raise_app('VALIDATION_FAILED', 'read tokens disagree about a row');
      END IF;
      v_seen := v_seen || jsonb_build_object(v_key, v_item);
    END LOOP;
  END LOOP;
  SELECT COALESCE(jsonb_agg(value ORDER BY value->>'schema', value->>'table', (value->'key')::text), '[]'::jsonb)
  INTO v_deps
  FROM jsonb_each(v_seen);
  RETURN v_deps;
END;
$$;

DROP FUNCTION IF EXISTS agentgate.plan_changes(text, jsonb, jsonb, timestamptz, int);

CREATE OR REPLACE FUNCTION agentgate.plan_changes(
  p_principal uuid,
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
  v_deps jsonb;
  v_canonical_deps jsonb;
BEGIN
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
    v_rows := v_rows || jsonb_build_array(v_captured || jsonb_build_object(
      'ordinal', v_ordinal,
      'operation', 'update',
      'schema_name', v_captured->>'schema_name',
      'table_name', v_captured->>'table_name'
    ));
    v_canonical := v_canonical || jsonb_build_array(v_captured->'canonical');
    v_diff := v_diff || jsonb_build_array(v_captured->'diff');
  END LOOP;
  v_deps := agentgate.freeze_dependencies(p_principal, p_body->'read_tokens');
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'schema', item->>'schema',
    'table', item->>'table',
    'key', item->'key',
    'revision', item->>'revision',
    'values', item->'values'
  ) ORDER BY item->>'schema', item->>'table', (item->'key')::text), '[]'::jsonb)
  INTO v_canonical_deps
  FROM jsonb_array_elements(v_deps) item;
  v_task := p_body->>'task_id';
  v_content := jsonb_build_object(
    'changes', v_canonical,
    'dependencies', v_canonical_deps,
    'expires_at', agentgate.iso_timestamptz(p_expires_at),
    'scope', COALESCE(p_scopes, '{}'::jsonb),
    'task_id', COALESCE(to_jsonb(v_task), 'null'::jsonb)
  );
  RETURN jsonb_build_object(
    'content', v_content,
    'content_hash', agentgate.sha256_hex(convert_to(v_content::text, 'UTF8')),
    'diff', jsonb_build_object('changes', v_diff),
    'rows', v_rows,
    'dependencies', v_deps
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.insert_dependencies(p_revision uuid, p_deps jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_dep jsonb;
  v_ordinal int := 0;
BEGIN
  FOR v_dep IN
    SELECT value FROM jsonb_array_elements(COALESCE(p_deps, '[]'::jsonb))
    ORDER BY value->>'schema', value->>'table', (value->'key')::text
  LOOP
    v_ordinal := v_ordinal + 1;
    INSERT INTO agentgate.pr_dependencies (
      revision_id, ordinal, schema_name, table_name, row_key, expected_revision, before_values
    ) VALUES (
      p_revision, v_ordinal, v_dep->>'schema_name', v_dep->>'table_name',
      v_dep->'row_key', (v_dep->>'expected_revision')::bigint, v_dep->'before_values'
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.proposal_outcome(
  p_principal uuid,
  p_rows jsonb,
  p_document jsonb,
  p_policy_version int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_effect text;
BEGIN
  v_effect := agentgate.evaluate_policy(p_rows, p_document);
  IF v_effect = 'block' THEN
    PERFORM agentgate.raise_app(
      'POLICY_BLOCKED',
      'policy blocked this proposal',
      jsonb_build_object('policy_version', p_policy_version)
    );
  END IF;
  RETURN jsonb_build_object(
    'policy_decision', v_effect,
    'state', CASE WHEN v_effect = 'auto_approved' THEN 'approved' ELSE 'pending_review' END
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
  v_policy_doc jsonb;
  v_outcome jsonb;
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
  SELECT id, version, document INTO v_policy_id, v_policy_version, v_policy_doc
  FROM agentgate.policies ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('POLICY_BLOCKED', 'no policy is configured');
  END IF;
  v_plan := agentgate.plan_changes(p_principal, v_kind, v_scopes, p_body, v_expires_at, p_max_rows);
  v_outcome := agentgate.proposal_outcome(p_principal, v_plan->'rows', v_policy_doc, v_policy_version);

  INSERT INTO agentgate.prs (id, title, reason, task_id, proposer_id, state, expires_at)
  VALUES (
    gen_random_uuid(), v_title, v_reason, v_task, p_principal,
    v_outcome->>'state', v_expires_at
  )
  RETURNING * INTO v_pr;
  INSERT INTO agentgate.pr_revisions (
    id, pr_id, revision_no, canonical_content, content_hash, policy_id, policy_decision
  ) VALUES (
    v_revision_id, v_pr.id, 1, v_plan->'content', v_plan->>'content_hash',
    v_policy_id, v_outcome->>'policy_decision'
  );
  UPDATE agentgate.prs SET active_revision_id = v_revision_id WHERE id = v_pr.id;
  v_pr.active_revision_id := v_revision_id;
  PERFORM agentgate.insert_revision_rows(v_revision_id, v_plan->'rows');
  PERFORM agentgate.insert_dependencies(v_revision_id, v_plan->'dependencies');
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (v_pr.id, p_principal, 'pr.created', jsonb_build_object(
    'revision', 1,
    'content_hash', v_plan->>'content_hash',
    'policy_decision', v_outcome->>'policy_decision'
  ));
  v_body := agentgate.proposal_body(
    v_pr, 1, v_plan->>'content_hash', v_outcome->>'policy_decision', v_policy_version, v_plan->'diff'
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
  v_policy_doc jsonb;
  v_outcome jsonb;
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
  SELECT id, version, document INTO v_policy_id, v_policy_version, v_policy_doc
  FROM agentgate.policies ORDER BY version DESC LIMIT 1;
  v_plan := agentgate.plan_changes(p_principal, v_kind, v_scopes, p_body, v_expires_at, p_max_rows);
  v_outcome := agentgate.proposal_outcome(p_principal, v_plan->'rows', v_policy_doc, v_policy_version);
  IF v_pr.state = 'queued' THEN
    UPDATE agentgate.merge_jobs
    SET state = 'failed', lease_expires_at = NULL
    WHERE pr_id = p_pr AND state = 'queued';
  END IF;
  v_pr.expires_at := v_expires_at;
  v_pr.state := v_outcome->>'state';
  SELECT COALESCE(MAX(revision_no), 0) + 1 INTO v_revision_no
  FROM agentgate.pr_revisions WHERE pr_id = p_pr;
  INSERT INTO agentgate.pr_revisions (
    id, pr_id, revision_no, canonical_content, content_hash, policy_id, policy_decision
  ) VALUES (
    v_revision_id, p_pr, v_revision_no, v_plan->'content', v_plan->>'content_hash',
    v_policy_id, v_outcome->>'policy_decision'
  );
  UPDATE agentgate.prs
  SET title = v_pr.title,
      reason = v_pr.reason,
      task_id = v_pr.task_id,
      state = v_pr.state,
      expires_at = v_expires_at,
      active_revision_id = v_revision_id
  WHERE id = p_pr;
  PERFORM agentgate.insert_revision_rows(v_revision_id, v_plan->'rows');
  PERFORM agentgate.insert_dependencies(v_revision_id, v_plan->'dependencies');
  INSERT INTO agentgate.audit_events (pr_id, principal_id, event_type, details)
  VALUES (p_pr, p_principal, 'pr.revised', jsonb_build_object(
    'revision', v_revision_no,
    'content_hash', v_plan->>'content_hash',
    'policy_decision', v_outcome->>'policy_decision'
  ));
  v_body := agentgate.proposal_body(
    v_pr, v_revision_no, v_plan->>'content_hash', v_outcome->>'policy_decision',
    v_policy_version, v_plan->'diff'
  );
  v_wrapper := jsonb_build_object('http_status', 201, 'body', v_body);
  RETURN agentgate.idempotency_finish(p_principal, v_route, p_idempotency_key, p_request_digest, v_wrapper);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.lock_enrolled_row(
  p_schema text,
  p_table text,
  p_pk text,
  p_pk_type text,
  p_key text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  EXECUTE format(
    'SELECT 1 FROM %I.%I WHERE %I = $1::%s FOR UPDATE',
    p_schema, p_table, p_pk, agentgate.sql_cast_type(p_pk_type)
  ) USING p_key;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.reserve_merge_limit(
  p_principal uuid,
  p_document jsonb,
  p_row_count int
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_limits jsonb := p_document->'limits';
  v_window int;
  v_max_rows int;
  v_max_requests int;
  v_used_rows int;
  v_used_requests int;
BEGIN
  IF v_limits IS NULL OR jsonb_typeof(v_limits) <> 'object' THEN
    RETURN;
  END IF;
  v_window := (v_limits->>'window_seconds')::int;
  v_max_rows := (v_limits->>'max_rows')::int;
  v_max_requests := (v_limits->>'max_requests')::int;
  INSERT INTO agentgate.rate_principals (principal_id) VALUES (p_principal)
  ON CONFLICT (principal_id) DO NOTHING;
  PERFORM 1 FROM agentgate.rate_principals WHERE principal_id = p_principal FOR UPDATE;
  SELECT COALESCE(SUM(row_count), 0), COALESCE(SUM(request_count), 0)
  INTO v_used_rows, v_used_requests
  FROM agentgate.rate_reservations
  WHERE principal_id = p_principal
    AND reserved_at > now() - make_interval(secs => v_window);
  IF v_used_rows + p_row_count > v_max_rows OR v_used_requests + 1 > v_max_requests THEN
    PERFORM agentgate.raise_app('LIMIT_EXCEEDED', 'rolling merge limit exceeded');
  END IF;
  INSERT INTO agentgate.rate_reservations (principal_id, row_count, request_count)
  VALUES (p_principal, p_row_count, 1);
END;
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
      'pr_id', p_pr, 'revision', v_revision, 'content_hash', v_hash,
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

  SELECT * INTO v_job FROM agentgate.merge_jobs WHERE revision_id = v_rev.id AND state = 'failed';
  IF FOUND THEN
    UPDATE agentgate.merge_jobs
    SET state = 'queued', lease_owner = NULL, lease_expires_at = NULL, enqueued_at = now()
    WHERE id = v_job.id;
  ELSE
    INSERT INTO agentgate.merge_jobs (pr_id, revision_id, state)
    VALUES (p_pr, v_rev.id, 'queued')
    RETURNING * INTO v_job;
  END IF;
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

CREATE OR REPLACE FUNCTION agentgate.assert_proposer_scope(
  p_kind text,
  p_scopes jsonb,
  p_schema text,
  p_table text,
  p_tenant_column text,
  p_pk text,
  p_pk_type text,
  p_key text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_scope jsonb;
  v_tenant text;
BEGIN
  IF p_kind = 'admin' THEN
    RETURN;
  END IF;
  SELECT elem INTO v_scope
  FROM jsonb_array_elements(COALESCE(p_scopes->'tables', '[]'::jsonb)) elem
  WHERE elem->>'schema' = p_schema AND elem->>'name' = p_table
  LIMIT 1;
  IF v_scope IS NULL THEN
    PERFORM agentgate.raise_app('FORBIDDEN', 'principal is not scoped to this table');
  END IF;
  IF p_tenant_column IS NOT NULL THEN
    EXECUTE format(
      'SELECT %I::text FROM %I.%I WHERE %I = $1::%s',
      p_tenant_column, p_schema, p_table, p_pk, agentgate.sql_cast_type(p_pk_type)
    ) INTO v_tenant USING p_key;
    IF v_tenant IS NULL OR NOT (COALESCE(v_scope->'tenants', '[]'::jsonb) @> to_jsonb(v_tenant)) THEN
      PERFORM agentgate.raise_app('FORBIDDEN', 'principal is not scoped to this tenant');
    END IF;
  END IF;
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
  v_policy_doc jsonb;
  v_eval_rows jsonb;
  v_change agentgate.pr_changes%ROWTYPE;
  v_dep agentgate.pr_dependencies%ROWTYPE;
  v_schema text;
  v_table text;
  v_key_json jsonb;
  v_reg agentgate.table_registry%ROWTYPE;
  v_fingerprint text;
  v_key text;
  v_locked jsonb;
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

  SELECT version, document INTO v_policy_version, v_policy_doc
  FROM agentgate.policies WHERE id = v_rev.policy_id FOR SHARE;
  SELECT max(version) INTO v_latest FROM agentgate.policies;
  IF v_policy_version IS DISTINCT FROM v_latest THEN
    PERFORM agentgate.raise_app('POLICY_BLOCKED', 'policy changed and requires a new revision');
  END IF;

  IF v_rev.policy_decision = 'auto_approved' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema_name', schema_name,
      'table_name', table_name,
      'operation', operation,
      'after_values', after_values
    )), '[]'::jsonb)
    INTO v_eval_rows
    FROM agentgate.pr_changes
    WHERE revision_id = v_rev.id;
    IF agentgate.evaluate_policy(v_eval_rows, v_policy_doc) IS DISTINCT FROM 'auto_approved' THEN
      PERFORM agentgate.raise_app('POLICY_BLOCKED', 'policy no longer auto-approves this revision');
    END IF;
  ELSE
    SELECT principal_id INTO v_approver
    FROM agentgate.approvals
    WHERE revision_id = v_rev.id AND decision = 'approved' AND content_hash = v_rev.content_hash
    ORDER BY created_at DESC
    LIMIT 1;
    IF NOT FOUND OR NOT agentgate.reviewer_covers(v_approver, v_rev.id) THEN
      PERFORM agentgate.raise_app('FORBIDDEN', 'approval does not cover this revision');
    END IF;
  END IF;

  SELECT kind, scopes INTO v_proposer_kind, v_scopes
  FROM agentgate.principals WHERE id = v_pr.proposer_id;

  FOR v_schema, v_table IN
    SELECT schema_name, table_name FROM (
      SELECT schema_name, table_name FROM agentgate.pr_changes WHERE revision_id = v_rev.id
      UNION
      SELECT schema_name, table_name FROM agentgate.pr_dependencies WHERE revision_id = v_rev.id
    ) tables
    ORDER BY schema_name, table_name
  LOOP
    EXECUTE format('LOCK TABLE %I.%I IN SHARE ROW EXCLUSIVE MODE', v_schema, v_table);
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_schema AND table_name = v_table;
    IF NOT FOUND THEN
      PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'table is not enrolled');
    END IF;
    v_fingerprint := agentgate.schema_fingerprint(format('%I.%I', v_schema, v_table)::regclass);
    IF v_fingerprint IS DISTINCT FROM v_reg.schema_fingerprint THEN
      PERFORM agentgate.raise_app('SCHEMA_CHANGED', 'enrolled schema changed');
    END IF;
  END LOOP;

  FOR v_schema, v_table, v_key_json IN
    SELECT schema_name, table_name, row_key FROM (
      SELECT DISTINCT schema_name, table_name, row_key FROM (
        SELECT schema_name, table_name, row_key FROM agentgate.pr_changes WHERE revision_id = v_rev.id
        UNION
        SELECT schema_name, table_name, row_key FROM agentgate.pr_dependencies WHERE revision_id = v_rev.id
      ) unioned
    ) keys
    ORDER BY schema_name, table_name, row_key::text
  LOOP
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_schema AND table_name = v_table;
    PERFORM agentgate.lock_enrolled_row(
      v_schema, v_table, v_reg.primary_key_column, v_reg.primary_key_type,
      v_key_json ->> v_reg.primary_key_column
    );
  END LOOP;

  FOR v_dep IN
    SELECT * FROM agentgate.pr_dependencies
    WHERE revision_id = v_rev.id
    ORDER BY schema_name, table_name, row_key::text, ordinal
  LOOP
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_dep.schema_name AND table_name = v_dep.table_name;
    v_key := v_dep.row_key ->> v_reg.primary_key_column;
    v_locked := agentgate.read_change_row(
      v_reg.schema_name, v_reg.table_name, v_reg.primary_key_column, v_reg.primary_key_type,
      v_key, v_dep.before_values, false
    );
    IF v_locked IS NULL
       OR (v_locked->>'revision')::bigint IS DISTINCT FROM v_dep.expected_revision
       OR v_locked->'values' IS DISTINCT FROM v_dep.before_values THEN
      PERFORM agentgate.raise_app('DRIFT_CONFLICT', 'a dependency row changed after the tracked read');
    END IF;
    PERFORM agentgate.assert_proposer_scope(
      v_proposer_kind, v_scopes, v_reg.schema_name, v_reg.table_name, v_reg.tenant_column,
      v_reg.primary_key_column, v_reg.primary_key_type, v_key
    );
  END LOOP;

  FOR v_change IN
    SELECT * FROM agentgate.pr_changes
    WHERE revision_id = v_rev.id
    ORDER BY schema_name, table_name, row_key::text, ordinal
  LOOP
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_change.schema_name AND table_name = v_change.table_name;
    v_key := v_change.row_key ->> v_reg.primary_key_column;
    v_locked := agentgate.read_change_row(
      v_reg.schema_name, v_reg.table_name, v_reg.primary_key_column, v_reg.primary_key_type,
      v_key, v_change.before_values, false
    );
    IF v_locked IS NULL
       OR (v_locked->>'revision')::bigint IS DISTINCT FROM v_change.expected_revision
       OR v_locked->'values' IS DISTINCT FROM v_change.before_values THEN
      PERFORM agentgate.raise_app('DRIFT_CONFLICT', 'a target row changed after approval');
    END IF;
    PERFORM agentgate.assert_proposer_scope(
      v_proposer_kind, v_scopes, v_reg.schema_name, v_reg.table_name, v_reg.tenant_column,
      v_reg.primary_key_column, v_reg.primary_key_type, v_key
    );
  END LOOP;

  SELECT count(*) INTO v_count FROM agentgate.pr_changes WHERE revision_id = v_rev.id;
  PERFORM agentgate.reserve_merge_limit(v_pr.proposer_id, v_policy_doc, v_count);

  FOR v_change IN
    SELECT * FROM agentgate.pr_changes
    WHERE revision_id = v_rev.id
    ORDER BY schema_name, table_name, row_key::text, ordinal
  LOOP
    SELECT * INTO v_reg FROM agentgate.table_registry
    WHERE schema_name = v_change.schema_name AND table_name = v_change.table_name;
    v_key := v_change.row_key ->> v_reg.primary_key_column;
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
  IF p_code = 'LIMIT_EXCEEDED' THEN
    UPDATE agentgate.merge_jobs SET state = 'failed', lease_expires_at = NULL WHERE id = p_job;
    UPDATE agentgate.prs SET state = 'approved' WHERE id = v_pr.id AND state = 'queued';
    INSERT INTO agentgate.audit_events (pr_id, event_type, details)
    VALUES (v_pr.id, 'pr.limit_exceeded', jsonb_build_object(
      'code', p_code, 'revision', v_rev.revision_no
    ));
    RETURN jsonb_build_object('pr_id', v_pr.id, 'state', 'approved', 'code', p_code);
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

CREATE OR REPLACE FUNCTION agentgate.record_policy_block(p_principal uuid, p_policy_version int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  INSERT INTO agentgate.audit_events (principal_id, event_type, details)
  VALUES (p_principal, 'pr.blocked', jsonb_build_object('policy_version', p_policy_version));
END;
$$;

SELECT agentgate.publish_policy($policy${
  "default": "manual_review_required",
  "rules": [
    {
      "effect": "auto_approved",
      "schema": "public",
      "table": "customer_profiles",
      "operations": ["update"],
      "columns": ["display_name", "email"],
      "max_rows": 9
    },
    {
      "effect": "manual_review_required",
      "schema": "public",
      "table": "payments"
    }
  ],
  "limits": {"window_seconds": 3600, "max_rows": 1000, "max_requests": 1000}
}$policy$::jsonb);

REVOKE ALL ON ALL TABLES IN SCHEMA agentgate FROM PUBLIC, agentgate_api, agentgate_worker;
GRANT SELECT, INSERT, UPDATE ON agentgate.table_registry TO agentgate_migrator;

REVOKE ALL ON FUNCTION agentgate.effect_rank(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.rule_matches(jsonb, text, text, text, jsonb, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.evaluate_policy(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.publish_policy(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.random_hex(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.create_read(uuid, jsonb, int, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.freeze_dependencies(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.plan_changes(uuid, text, jsonb, jsonb, timestamptz, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.insert_dependencies(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.proposal_outcome(uuid, jsonb, jsonb, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.lock_enrolled_row(text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.reserve_merge_limit(uuid, jsonb, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.assert_proposer_scope(text, jsonb, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.record_policy_block(uuid, int) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentgate.publish_policy(jsonb) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.create_read(uuid, jsonb, int, int, int) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.propose(uuid, jsonb, text, text, int, int, int) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.create_revision(uuid, uuid, jsonb, text, text, int, int, int) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.enqueue_merge(uuid, uuid, jsonb, text, text) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.merge_pr(uuid) TO agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.record_merge_failure(uuid, text) TO agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.record_policy_block(uuid, int) TO agentgate_api;

RESET ROLE;
