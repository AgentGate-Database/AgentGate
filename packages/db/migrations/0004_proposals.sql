GRANT agentgate_owner TO CURRENT_USER;
SET ROLE agentgate_owner;

CREATE TABLE IF NOT EXISTS agentgate.policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version int NOT NULL UNIQUE,
  document jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS policies_immutable ON agentgate.policies;
CREATE TRIGGER policies_immutable
  BEFORE UPDATE OR DELETE ON agentgate.policies
  FOR EACH ROW EXECUTE FUNCTION agentgate.reject_mutation();

INSERT INTO agentgate.policies (version, document)
VALUES (1, '{"default":"manual_review_required"}'::jsonb)
ON CONFLICT (version) DO NOTHING;

CREATE TABLE IF NOT EXISTS agentgate.reviewer_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  principal_id uuid NOT NULL REFERENCES agentgate.principals (id),
  table_registry_id uuid NOT NULL REFERENCES agentgate.table_registry (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (principal_id, table_registry_id)
);

CREATE TABLE IF NOT EXISTS agentgate.prs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  reason text NOT NULL,
  task_id text,
  proposer_id uuid NOT NULL REFERENCES agentgate.principals (id),
  state text NOT NULL CHECK (state IN (
    'pending_review', 'approved', 'queued', 'merged', 'blocked',
    'rejected', 'expired', 'conflicted', 'failed'
  )),
  active_revision_id uuid,
  expires_at timestamptz NOT NULL,
  source_pr_id uuid REFERENCES agentgate.prs (id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS prs_list_idx ON agentgate.prs (created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS prs_state_idx ON agentgate.prs (state, expires_at);
CREATE INDEX IF NOT EXISTS prs_proposer_idx ON agentgate.prs (proposer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS agentgate.pr_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pr_id uuid NOT NULL REFERENCES agentgate.prs (id),
  revision_no int NOT NULL,
  canonical_content jsonb NOT NULL,
  content_hash text NOT NULL,
  policy_id uuid NOT NULL REFERENCES agentgate.policies (id),
  policy_decision text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pr_id, revision_no)
);

ALTER TABLE agentgate.prs
  DROP CONSTRAINT IF EXISTS prs_active_revision_fk;
ALTER TABLE agentgate.prs
  ADD CONSTRAINT prs_active_revision_fk
  FOREIGN KEY (active_revision_id) REFERENCES agentgate.pr_revisions (id);

CREATE TABLE IF NOT EXISTS agentgate.pr_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  revision_id uuid NOT NULL REFERENCES agentgate.pr_revisions (id),
  ordinal int NOT NULL,
  operation text NOT NULL,
  schema_name text NOT NULL,
  table_name text NOT NULL,
  row_key jsonb NOT NULL,
  expected_revision bigint NOT NULL,
  before_values jsonb NOT NULL,
  after_values jsonb NOT NULL,
  UNIQUE (revision_id, ordinal)
);

CREATE INDEX IF NOT EXISTS pr_changes_revision_idx ON agentgate.pr_changes (revision_id);

CREATE TABLE IF NOT EXISTS agentgate.approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pr_id uuid NOT NULL REFERENCES agentgate.prs (id),
  revision_id uuid NOT NULL REFERENCES agentgate.pr_revisions (id),
  principal_id uuid NOT NULL REFERENCES agentgate.principals (id),
  decision text NOT NULL CHECK (decision IN ('approved', 'rejected')),
  reason text,
  content_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS approvals_revision_idx ON agentgate.approvals (revision_id, created_at);

DROP TRIGGER IF EXISTS pr_revisions_immutable ON agentgate.pr_revisions;
CREATE TRIGGER pr_revisions_immutable
  BEFORE UPDATE OR DELETE ON agentgate.pr_revisions
  FOR EACH ROW EXECUTE FUNCTION agentgate.reject_mutation();

DROP TRIGGER IF EXISTS pr_changes_immutable ON agentgate.pr_changes;
CREATE TRIGGER pr_changes_immutable
  BEFORE UPDATE OR DELETE ON agentgate.pr_changes
  FOR EACH ROW EXECUTE FUNCTION agentgate.reject_mutation();

DROP TRIGGER IF EXISTS approvals_immutable ON agentgate.approvals;
CREATE TRIGGER approvals_immutable
  BEFORE UPDATE OR DELETE ON agentgate.approvals
  FOR EACH ROW EXECUTE FUNCTION agentgate.reject_mutation();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'audit_events_pr_fk' AND conrelid = 'agentgate.audit_events'::regclass
  ) THEN
    ALTER TABLE agentgate.audit_events
      ADD CONSTRAINT audit_events_pr_fk FOREIGN KEY (pr_id) REFERENCES agentgate.prs (id);
  END IF;
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA agentgate FROM PUBLIC, agentgate_api, agentgate_worker;

RESET ROLE;
