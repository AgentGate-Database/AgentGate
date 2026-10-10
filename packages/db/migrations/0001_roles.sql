-- agentgate:no-transaction
-- Roles for a fresh database. Passwords are supplied with psql variables
-- (:'api_password', :'worker_password', :'migrator_password').
-- CREATE ROLE and ALTER ROLE cannot run inside a transaction block, so this
-- file is applied without an outer BEGIN. On Supabase, run it as a role with
-- CREATEROLE. The current user is granted membership in agentgate_owner so
-- later migrations can SET ROLE; objects are created as that role.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data_pr')
     AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'agentgate') THEN
    RAISE EXCEPTION 'both data_pr and agentgate schemas exist; refusing to merge them';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data_pr') THEN
    RAISE EXCEPTION 'legacy data_pr schema still exists after 0000; refusing to continue';
  END IF;
END
$$;

SELECT 'CREATE ROLE agentgate_owner NOLOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agentgate_owner')\gexec
SELECT 'CREATE ROLE agentgate_migrator LOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agentgate_migrator')\gexec
SELECT 'CREATE ROLE agentgate_api LOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agentgate_api')\gexec
SELECT 'CREATE ROLE agentgate_worker LOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agentgate_worker')\gexec

ALTER ROLE agentgate_owner NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
ALTER ROLE agentgate_migrator LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS PASSWORD :'migrator_password';
ALTER ROLE agentgate_api LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS PASSWORD :'api_password';
ALTER ROLE agentgate_worker LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS PASSWORD :'worker_password';

BEGIN;

GRANT agentgate_owner TO CURRENT_USER;
GRANT agentgate_owner TO agentgate_migrator;

CREATE SCHEMA IF NOT EXISTS agentgate;
ALTER SCHEMA agentgate OWNER TO agentgate_owner;
REVOKE ALL ON SCHEMA agentgate FROM PUBLIC;
COMMENT ON SCHEMA agentgate IS
  'Private AgentGate schema. Do not add it to exposed API schemas (including Supabase Data API schemas).';

DO $$
DECLARE
  role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role']
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA agentgate FROM %I', role_name);
    END IF;
  END LOOP;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
    CREATE EXTENSION pgcrypto SCHEMA agentgate;
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS agentgate.schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE agentgate.schema_migrations OWNER TO agentgate_owner;

INSERT INTO agentgate.schema_migrations(version)
VALUES ('0000_rename_data_pr.sql'), ('0001_roles.sql')
ON CONFLICT DO NOTHING;

COMMIT;
