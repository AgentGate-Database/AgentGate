-- Rename a legacy data_pr schema when it is the only AgentGate catalog present.
-- If both schemas exist, stop. Do not merge them and do not drop either one.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data_pr')
     AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'agentgate') THEN
    RAISE EXCEPTION 'both data_pr and agentgate schemas exist; refusing to merge them';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data_pr') THEN
    RAISE NOTICE 'renaming legacy schema data_pr to agentgate';
    ALTER SCHEMA data_pr RENAME TO agentgate;
  END IF;
END
$$;
