GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE OR REPLACE FUNCTION agentgate.bump_revision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, agentgate
AS $$
BEGIN
  NEW.agentgate_revision := OLD.agentgate_revision + 1;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.schema_fingerprint(p_rel regclass)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT agentgate.sha256_hex(convert_to(COALESCE(string_agg(
    a.attname || ':' || t.typname || ':' ||
    CASE WHEN a.attnotnull THEN '1' ELSE '0' END || ':' ||
    CASE WHEN EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)
    ) THEN '1' ELSE '0' END || ':' || COALESCE(a.attgenerated::text, ''),
    '|' ORDER BY a.attnum
  ), ''), 'UTF8'))
  FROM pg_attribute a
  JOIN pg_type t ON t.oid = a.atttypid
  WHERE a.attrelid = p_rel AND a.attnum > 0 AND NOT a.attisdropped;
$$;

CREATE OR REPLACE FUNCTION agentgate.column_type(p_rel regclass, p_column text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, agentgate
AS $$
  SELECT CASE t.typname
    WHEN 'int2' THEN 'int2'
    WHEN 'int4' THEN 'int4'
    WHEN 'int8' THEN 'int8'
    WHEN 'numeric' THEN 'numeric'
    WHEN 'text' THEN 'text'
    WHEN 'varchar' THEN 'varchar'
    WHEN 'bool' THEN 'bool'
    WHEN 'timestamptz' THEN 'timestamptz'
    WHEN 'date' THEN 'date'
    WHEN 'uuid' THEN 'uuid'
    WHEN 'jsonb' THEN 'jsonb'
    ELSE NULL
  END
  FROM pg_attribute a
  JOIN pg_type t ON t.oid = a.atttypid
  WHERE a.attrelid = p_rel AND a.attname = p_column AND a.attnum > 0 AND NOT a.attisdropped;
$$;

CREATE OR REPLACE FUNCTION agentgate.enroll_table(
  p_schema text,
  p_table text,
  p_allowed_columns text[],
  p_tenant_column text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_schema text;
  v_table text;
  v_rel regclass;
  v_relkind "char";
  v_partition boolean;
  v_pk_name text;
  v_pk_type text;
  v_pk_count int;
  v_allowed jsonb := '[]'::jsonb;
  v_column text;
  v_type text;
  v_nullable boolean;
  v_seen text[] := ARRAY[]::text[];
  v_id uuid;
  v_fingerprint text;
BEGIN
  v_schema := agentgate.assert_ident(p_schema);
  v_table := agentgate.assert_ident(p_table);
  IF p_tenant_column IS NOT NULL THEN
    PERFORM agentgate.assert_ident(p_tenant_column);
  END IF;

  SELECT c.oid, c.relkind, c.relispartition
  INTO v_rel, v_relkind, v_partition
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = v_schema AND c.relname = v_table;

  IF v_rel IS NULL OR v_relkind <> 'r' OR v_partition THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'only ordinary base tables can be enrolled');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_inherits WHERE inhrelid = v_rel OR inhparent = v_rel
  ) THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'partitioned and inherited tables cannot be enrolled');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_rewrite WHERE ev_class = v_rel AND rulename <> '_RETURN'
  ) THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'tables with rules cannot be enrolled');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = v_rel AND NOT tgisinternal AND tgname <> 'agentgate_bump_revision'
  ) THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'tables with user-defined triggers cannot be enrolled');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = v_rel AND attnum > 0 AND NOT attisdropped AND attgenerated <> ''
  ) THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'tables with generated columns cannot be enrolled');
  END IF;

  SELECT count(*), min(a.attname), min(CASE t.typname
    WHEN 'int2' THEN 'int2' WHEN 'int4' THEN 'int4' WHEN 'int8' THEN 'int8' WHEN 'uuid' THEN 'uuid'
    ELSE NULL END)
  INTO v_pk_count, v_pk_name, v_pk_type
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
  JOIN pg_type t ON t.oid = a.atttypid
  WHERE i.indrelid = v_rel AND i.indisprimary;

  IF v_pk_count <> 1 OR v_pk_type IS NULL THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'table must have one uuid or integer primary key');
  END IF;

  IF p_allowed_columns IS NULL OR cardinality(p_allowed_columns) < 1 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'at least one allowed column is required');
  END IF;

  FOREACH v_column IN ARRAY p_allowed_columns
  LOOP
    PERFORM agentgate.assert_ident(v_column);
    IF v_column = ANY (v_seen) THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'duplicate allowed column');
    END IF;
    v_seen := array_append(v_seen, v_column);
    IF v_column = 'agentgate_revision' OR v_column = v_pk_name THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'primary key and revision columns cannot be proposed');
    END IF;
    v_type := agentgate.column_type(v_rel, v_column);
    IF v_type IS NULL THEN
      PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'allowed column is missing or has an unsupported type');
    END IF;
    SELECT NOT a.attnotnull INTO v_nullable
    FROM pg_attribute a
    WHERE a.attrelid = v_rel AND a.attname = v_column;
    v_allowed := v_allowed || jsonb_build_array(jsonb_build_object(
      'name', v_column, 'type', v_type, 'nullable', COALESCE(v_nullable, true)
    ));
  END LOOP;

  IF p_tenant_column IS NOT NULL AND agentgate.column_type(v_rel, p_tenant_column) IS NULL THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'tenant column is missing or has an unsupported type');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = v_rel AND attname = 'agentgate_revision' AND NOT attisdropped
  ) THEN
    EXECUTE format(
      'ALTER TABLE %I.%I ADD COLUMN agentgate_revision bigint NOT NULL DEFAULT 1',
      v_schema, v_table
    );
  ELSE
    IF agentgate.column_type(v_rel, 'agentgate_revision') IS DISTINCT FROM 'int8' THEN
      PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'agentgate_revision must be bigint');
    END IF;
  END IF;

  EXECUTE format('DROP TRIGGER IF EXISTS agentgate_bump_revision ON %I.%I', v_schema, v_table);
  EXECUTE format(
    'CREATE TRIGGER agentgate_bump_revision BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION agentgate.bump_revision()',
    v_schema, v_table
  );

  EXECUTE format('GRANT SELECT, UPDATE ON TABLE %I.%I TO agentgate_owner', v_schema, v_table);
  EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM agentgate_api, agentgate_worker', v_schema, v_table);

  v_fingerprint := agentgate.schema_fingerprint(format('%I.%I', v_schema, v_table)::regclass);

  INSERT INTO agentgate.table_registry (
    schema_name, table_name, primary_key_column, primary_key_type,
    allowed_columns, tenant_column, schema_fingerprint
  ) VALUES (
    v_schema, v_table, v_pk_name, v_pk_type, v_allowed, p_tenant_column, v_fingerprint
  )
  ON CONFLICT (schema_name, table_name) DO UPDATE
  SET primary_key_column = EXCLUDED.primary_key_column,
      primary_key_type = EXCLUDED.primary_key_type,
      allowed_columns = EXCLUDED.allowed_columns,
      tenant_column = EXCLUDED.tenant_column,
      schema_fingerprint = EXCLUDED.schema_fingerprint,
      enrolled_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Writers must be able to fire the revision trigger. The function only increments the counter.
GRANT EXECUTE ON FUNCTION agentgate.bump_revision() TO PUBLIC;

REVOKE ALL ON FUNCTION agentgate.schema_fingerprint(regclass) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.column_type(regclass, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.enroll_table(text, text, text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION agentgate.enroll_table(text, text, text[], text) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.schema_fingerprint(regclass) TO agentgate_migrator;
-- enroll_table is SECURITY INVOKER, so the migrator executes these helpers directly.
GRANT EXECUTE ON FUNCTION agentgate.assert_ident(text) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.raise_app(text, text, jsonb) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.column_type(regclass, text) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.sha256_hex(bytea) TO agentgate_migrator;

RESET ROLE;
