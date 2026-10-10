GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE OR REPLACE FUNCTION agentgate.assign_reviewer(
  p_principal uuid,
  p_schema text,
  p_table text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_kind text;
  v_table uuid;
  v_id uuid;
BEGIN
  SELECT kind INTO v_kind FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'principal not found');
  END IF;
  IF v_kind <> 'reviewer' THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'only reviewer principals can be assigned');
  END IF;
  SELECT id INTO v_table
  FROM agentgate.table_registry
  WHERE schema_name = agentgate.assert_ident(p_schema)
    AND table_name = agentgate.assert_ident(p_table);
  IF NOT FOUND THEN
    PERFORM agentgate.raise_app('UNSUPPORTED_TABLE', 'table is not enrolled');
  END IF;
  INSERT INTO agentgate.reviewer_assignments (principal_id, table_registry_id)
  VALUES (p_principal, v_table)
  ON CONFLICT (principal_id, table_registry_id) DO UPDATE
  SET created_at = agentgate.reviewer_assignments.created_at
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.reviewer_covers(p_principal uuid, p_revision uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
  SELECT COALESCE(bool_and(
    EXISTS (
      SELECT 1
      FROM agentgate.table_registry t
      JOIN agentgate.reviewer_assignments a ON a.table_registry_id = t.id
      WHERE t.schema_name = c.schema_name
        AND t.table_name = c.table_name
        AND a.principal_id = p_principal
    )
  ), false)
  FROM (
    SELECT DISTINCT schema_name, table_name
    FROM agentgate.pr_changes
    WHERE revision_id = p_revision
  ) c;
$$;

CREATE OR REPLACE FUNCTION agentgate.principal_can_view(p_principal uuid, p_pr uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_kind text;
  v_scopes jsonb;
  v_proposer uuid;
  v_revision uuid;
BEGIN
  SELECT kind, scopes INTO v_kind, v_scopes FROM agentgate.principals WHERE id = p_principal;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  SELECT proposer_id, active_revision_id INTO v_proposer, v_revision
  FROM agentgate.prs WHERE id = p_pr;
  IF NOT FOUND OR v_revision IS NULL THEN
    RETURN false;
  END IF;
  IF v_kind = 'admin' THEN
    RETURN true;
  END IF;
  IF v_proposer = p_principal THEN
    RETURN NOT EXISTS (
      SELECT 1
      FROM agentgate.pr_changes c
      WHERE c.revision_id = v_revision
        AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(v_scopes->'tables', '[]'::jsonb)) elem
          WHERE elem->>'schema' = c.schema_name AND elem->>'name' = c.table_name
        )
    );
  END IF;
  IF v_kind = 'reviewer' THEN
    RETURN agentgate.reviewer_covers(p_principal, v_revision);
  END IF;
  RETURN false;
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
BEGIN
  WITH expired AS (
    UPDATE agentgate.prs
    SET state = 'expired'
    WHERE state IN ('pending_review', 'approved') AND expires_at <= now()
    RETURNING id
  )
  INSERT INTO agentgate.audit_events (pr_id, event_type, details)
  SELECT id, 'pr.expired', '{}'::jsonb FROM expired;
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
BEGIN
  SELECT * INTO v_pr FROM agentgate.prs WHERE id = p_pr FOR UPDATE;
  IF NOT FOUND OR NOT agentgate.principal_can_view(p_principal, p_pr) THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  IF v_pr.state IN ('pending_review', 'approved') AND v_pr.expires_at <= now() THEN
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
    'execution_status', 'null'::jsonb
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.get_pr_diff(p_principal uuid, p_pr uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_rev agentgate.pr_revisions%ROWTYPE;
  v_pr_id uuid;
  v_changes jsonb;
BEGIN
  IF NOT agentgate.principal_can_view(p_principal, p_pr) THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  SELECT active_revision_id INTO v_pr_id FROM agentgate.prs WHERE id = p_pr;
  SELECT * INTO v_rev FROM agentgate.pr_revisions WHERE id = (
    SELECT active_revision_id FROM agentgate.prs WHERE id = p_pr
  );
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'operation', ch->>'operation',
    'schema', ch->>'schema',
    'table', ch->>'table',
    'key', ch->'key',
    'expected_revision', ch->>'expected_revision',
    'fields', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'column', key,
        'type', ch->'types'->>key,
        'before', ch->'before'->key,
        'after', ch->'after'->key
      ) ORDER BY key), '[]'::jsonb)
      FROM jsonb_object_keys(COALESCE(ch->'after', '{}'::jsonb)) AS key
    )
  )), '[]'::jsonb)
  INTO v_changes
  FROM jsonb_array_elements(v_rev.canonical_content->'changes') AS ch;

  RETURN jsonb_build_object(
    'pr_id', p_pr,
    'revision', v_rev.revision_no,
    'content_hash', v_rev.content_hash,
    'changes', COALESCE(v_changes, '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.list_events(p_principal uuid, p_pr uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_events jsonb;
BEGIN
  IF NOT agentgate.principal_can_view(p_principal, p_pr) THEN
    PERFORM agentgate.raise_app('NOT_FOUND', 'pr not found');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'type', e.event_type,
    'created_at', agentgate.iso_timestamptz(e.created_at),
    'details', e.details
  ) ORDER BY e.created_at, e.id), '[]'::jsonb)
  INTO v_events
  FROM agentgate.audit_events e
  WHERE e.pr_id = p_pr;
  RETURN jsonb_build_object('pr_id', p_pr, 'events', v_events);
END;
$$;

CREATE OR REPLACE FUNCTION agentgate.list_prs(
  p_principal uuid,
  p_status text,
  p_schema text,
  p_table text,
  p_proposer text,
  p_created_after timestamptz,
  p_created_before timestamptz,
  p_cursor text,
  p_limit int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agentgate
AS $$
DECLARE
  v_limit int;
  v_micros bigint;
  v_cursor_id uuid;
  v_proposer uuid;
  v_rows jsonb := '[]'::jsonb;
  v_next text;
  v_count int := 0;
  v_last_micros bigint;
  v_last_id uuid;
  v_rec record;
BEGIN
  PERFORM agentgate.expire_prs();
  IF p_limit IS NULL THEN
    v_limit := 50;
  ELSIF p_limit < 1 OR p_limit > 100 THEN
    PERFORM agentgate.raise_app('VALIDATION_FAILED', 'limit must be between 1 and 100');
  ELSE
    v_limit := p_limit;
  END IF;
  IF p_proposer IS NOT NULL THEN
    BEGIN
      v_proposer := p_proposer::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'proposer must be a uuid');
    END;
  END IF;
  IF p_cursor IS NOT NULL THEN
    BEGIN
      v_micros := split_part(convert_from(decode(p_cursor, 'base64'), 'UTF8'), '|', 1)::bigint;
      v_cursor_id := split_part(convert_from(decode(p_cursor, 'base64'), 'UTF8'), '|', 2)::uuid;
    EXCEPTION WHEN OTHERS THEN
      PERFORM agentgate.raise_app('VALIDATION_FAILED', 'cursor is invalid');
    END;
  END IF;

  FOR v_rec IN
    SELECT
      p.id,
      p.title,
      p.state,
      p.proposer_id,
      p.created_at,
      p.expires_at,
      r.revision_no,
      r.content_hash,
      r.policy_decision,
      floor(extract(epoch FROM p.created_at) * 1000000)::bigint AS micros
    FROM agentgate.prs p
    JOIN agentgate.pr_revisions r ON r.id = p.active_revision_id
    WHERE agentgate.principal_can_view(p_principal, p.id)
      AND (p_status IS NULL OR p.state = p_status)
      AND (v_proposer IS NULL OR p.proposer_id = v_proposer)
      AND (p_created_after IS NULL OR p.created_at >= p_created_after)
      AND (p_created_before IS NULL OR p.created_at < p_created_before)
      AND (
        v_micros IS NULL
        OR (floor(extract(epoch FROM p.created_at) * 1000000)::bigint, p.id) < (v_micros, v_cursor_id)
      )
      AND (
        p_schema IS NULL OR EXISTS (
          SELECT 1 FROM agentgate.pr_changes c
          WHERE c.revision_id = p.active_revision_id
            AND c.schema_name = p_schema
            AND (p_table IS NULL OR c.table_name = p_table)
        )
      )
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT v_limit + 1
  LOOP
    v_count := v_count + 1;
    IF v_count <= v_limit THEN
      v_last_micros := v_rec.micros;
      v_last_id := v_rec.id;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'pr_id', v_rec.id,
        'title', v_rec.title,
        'state', v_rec.state,
        'proposer_id', v_rec.proposer_id,
        'revision', v_rec.revision_no,
        'content_hash', v_rec.content_hash,
        'policy_decision', v_rec.policy_decision,
        'created_at', agentgate.iso_timestamptz(v_rec.created_at),
        'expires_at', agentgate.iso_timestamptz(v_rec.expires_at)
      ));
    END IF;
  END LOOP;

  IF v_count > v_limit THEN
    v_next := replace(encode(convert_to(v_last_micros::text || '|' || v_last_id::text, 'UTF8'), 'base64'), E'\n', '');
  END IF;

  RETURN jsonb_build_object('items', v_rows, 'next_cursor', COALESCE(to_jsonb(v_next), 'null'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION agentgate.assign_reviewer(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.reviewer_covers(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.principal_can_view(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.expire_prs() FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.get_pr(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.get_pr_diff(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.list_events(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agentgate.list_prs(uuid, text, text, text, text, timestamptz, timestamptz, text, int) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentgate.assign_reviewer(uuid, text, text) TO agentgate_migrator;
GRANT EXECUTE ON FUNCTION agentgate.expire_prs() TO agentgate_api, agentgate_worker;
GRANT EXECUTE ON FUNCTION agentgate.get_pr(uuid, uuid) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.get_pr_diff(uuid, uuid) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.list_events(uuid, uuid) TO agentgate_api;
GRANT EXECUTE ON FUNCTION agentgate.list_prs(uuid, text, text, text, text, timestamptz, timestamptz, text, int) TO agentgate_api;

RESET ROLE;
