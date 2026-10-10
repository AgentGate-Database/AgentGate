GRANT USAGE, CREATE ON SCHEMA agentgate TO agentgate_owner;
GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE TABLE IF NOT EXISTS agentgate.principals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('proposer', 'reviewer', 'admin', 'worker')),
  scopes jsonb NOT NULL DEFAULT '{"tables":[]}'::jsonb,
  external_issuer text,
  external_subject text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT principals_external_pair CHECK (
    (external_issuer IS NULL AND external_subject IS NULL)
    OR (external_issuer IS NOT NULL AND external_subject IS NOT NULL)
  ),
  CONSTRAINT principals_external_unique UNIQUE (external_issuer, external_subject)
);

CREATE TABLE IF NOT EXISTS agentgate.credentials (
  id uuid PRIMARY KEY,
  principal_id uuid NOT NULL REFERENCES agentgate.principals (id),
  secret_digest bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CONSTRAINT credentials_digest_len CHECK (octet_length(secret_digest) = 32)
);

CREATE INDEX IF NOT EXISTS credentials_principal_idx ON agentgate.credentials (principal_id);

CREATE TABLE IF NOT EXISTS agentgate.table_registry (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schema_name text NOT NULL,
  table_name text NOT NULL,
  primary_key_column text NOT NULL,
  primary_key_type text NOT NULL,
  allowed_columns jsonb NOT NULL,
  tenant_column text,
  schema_fingerprint text NOT NULL,
  enrolled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (schema_name, table_name)
);

CREATE TABLE IF NOT EXISTS agentgate.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pr_id uuid,
  principal_id uuid REFERENCES agentgate.principals (id),
  event_type text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_events_pr_idx ON agentgate.audit_events (pr_id, created_at);

CREATE OR REPLACE FUNCTION agentgate.reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  RAISE EXCEPTION 'append-only table' USING ERRCODE = 'AG012';
END;
$$;

DROP TRIGGER IF EXISTS audit_events_append_only ON agentgate.audit_events;
CREATE TRIGGER audit_events_append_only
  BEFORE UPDATE OR DELETE ON agentgate.audit_events
  FOR EACH ROW EXECUTE FUNCTION agentgate.reject_mutation();

CREATE OR REPLACE FUNCTION agentgate.raise_app(p_code text, p_message text, p_details jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_state text;
BEGIN
  v_state := CASE p_code
    WHEN 'UNAUTHORIZED' THEN 'AG001'
    WHEN 'FORBIDDEN' THEN 'AG002'
    WHEN 'UNSUPPORTED_TABLE' THEN 'AG003'
    WHEN 'UNSUPPORTED_OPERATION' THEN 'AG004'
    WHEN 'POLICY_BLOCKED' THEN 'AG005'
    WHEN 'REVISION_MISMATCH' THEN 'AG006'
    WHEN 'PR_EXPIRED' THEN 'AG007'
    WHEN 'DRIFT_CONFLICT' THEN 'AG008'
    WHEN 'SCHEMA_CHANGED' THEN 'AG009'
    WHEN 'IDEMPOTENCY_CONFLICT' THEN 'AG010'
    WHEN 'LIMIT_EXCEEDED' THEN 'AG011'
    WHEN 'CONSTRAINT_VIOLATION' THEN 'AG012'
    WHEN 'VALIDATION_FAILED' THEN 'AG013'
    WHEN 'NOT_FOUND' THEN 'AG014'
    ELSE 'AG013'
  END;
  RAISE EXCEPTION '%', jsonb_build_object(
    'code', p_code,
    'message', p_message,
    'details', COALESCE(p_details, '{}'::jsonb)
  )::text
  USING ERRCODE = v_state;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.assert_ident(p_value text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  IF p_value IS NULL OR p_value !~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'invalid identifier');
  END IF;
  RETURN p_value;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.sha256_hex(p_data bytea)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
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
  EXECUTE format('SELECT encode(%I.digest($1, ''sha256''), ''hex'')', v_schema) INTO v_out USING p_data;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.iso_timestamptz(p_value timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT to_char(p_value AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
$$;

CREATE OR REPLACE FUNCTION agentgate.normalize_input(p_type text, p_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_text text;
  v_out text;
BEGIN
  IF p_value IS NULL OR p_value = 'null'::jsonb THEN
    RETURN 'null'::jsonb;
  END IF;
  IF p_type = 'bool' THEN
    IF jsonb_typeof(p_value) <> 'boolean' THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'boolean values must be JSON booleans');
    END IF;
    RETURN p_value;
  END IF;
  IF p_type = 'jsonb' THEN
    IF jsonb_typeof(p_value) NOT IN ('object', 'array') THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'jsonb values must be objects or arrays');
    END IF;
    RETURN p_value;
  END IF;
  IF jsonb_typeof(p_value) <> 'string' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'numeric, key, and text values must be JSON strings');
  END IF;
  v_text := p_value #>> '{}';
  BEGIN
    IF p_type = 'int2' THEN
      v_out := v_text::smallint::text;
    ELSIF p_type = 'int4' THEN
      v_out := v_text::integer::text;
    ELSIF p_type = 'int8' THEN
      v_out := v_text::bigint::text;
    ELSIF p_type = 'numeric' THEN
      v_out := trim_scale(v_text::numeric)::text;
    ELSIF p_type = 'uuid' THEN
      v_out := lower(v_text::uuid::text);
    ELSIF p_type = 'date' THEN
      v_out := to_char(v_text::date, 'YYYY-MM-DD');
    ELSIF p_type = 'timestamptz' THEN
      v_out := agentgate.iso_timestamptz(v_text::timestamptz);
    ELSIF p_type IN ('text', 'varchar') THEN
      v_out := v_text;
    ELSE
      PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'unsupported column type');
    END IF;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'value does not match the column type');
  END;
  RETURN to_jsonb(v_out);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.issue_credential(
  p_name text,
  p_kind text,
  p_scopes jsonb,
  p_credential_id uuid,
  p_secret_digest bytea
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_principal uuid;
BEGIN
  IF p_kind NOT IN ('proposer', 'reviewer', 'admin', 'worker') THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'invalid principal kind');
  END IF;
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'principal name is required');
  END IF;
  IF octet_length(p_secret_digest) <> 32 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'secret digest must be 32 bytes');
  END IF;
  INSERT INTO agentgate.principals (name, kind, scopes)
  VALUES (p_name, p_kind, COALESCE(p_scopes, '{"tables":[]}'::jsonb))
  RETURNING id INTO v_principal;
  INSERT INTO agentgate.credentials (id, principal_id, secret_digest)
  VALUES (p_credential_id, v_principal, p_secret_digest);
  RETURN v_principal;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.authenticate(p_credential_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_row jsonb;
BEGIN
  SELECT jsonb_build_object(
    'credential_id', c.id,
    'principal_id', p.id,
    'kind', p.kind,
    'name', p.name,
    'scopes', p.scopes,
    'secret_digest_hex', encode(c.secret_digest, 'hex'),
    'revoked', c.revoked_at IS NOT NULL
  )
  INTO v_row
  FROM agentgate.credentials c
  JOIN agentgate.principals p ON p.id = c.principal_id
  WHERE c.id = p_credential_id;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION agentgate.raise_app(text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.assert_ident(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.sha256_hex(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.iso_timestamptz(timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.normalize_input(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.reject_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.issue_credential(text, text, jsonb, uuid, bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.authenticate(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentgate.issue_credential(text, text, jsonb, uuid, bytea) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.authenticate(uuid) TO agentgate_api;

REVOKE ALL ON ALL TABLES IN SCHEMA agentgate FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON agentgate.table_registry TO agentgate_migrator;

RESET ROLE;

GRANT USAGE ON SCHEMA agentgate TO agentgate_api, agentgate_worker, agentgate_migrator;
