-- Synthetic business data and negative enrollment fixtures. Idempotent.
-- This is not production data.

CREATE TABLE IF NOT EXISTS public.invoices (
  id bigint PRIMARY KEY,
  tenant_id text NOT NULL,
  payment_terms text,
  amount numeric(20, 4),
  big_ref bigint,
  due_on date,
  paid boolean NOT NULL DEFAULT false,
  meta jsonb,
  updated_at timestamptz,
  notes text
);

CREATE TABLE IF NOT EXISTS public.customer_profiles (
  id uuid PRIMARY KEY,
  display_name text,
  email text
);

CREATE TABLE IF NOT EXISTS public.payments (
  id bigint PRIMARY KEY,
  amount numeric(12, 2),
  status text
);

INSERT INTO public.invoices (
  id, tenant_id, payment_terms, amount, big_ref, due_on, paid, meta, updated_at, notes
) VALUES
  (482, 'acme', 'net_15', 1999.5000, 9007199254740993, DATE '2026-11-01', false,
   '{"source":"seed"}'::jsonb, '2026-01-15T00:00:00Z', 'seed invoice'),
  (483, 'other', 'net_30', 50.0000, 1, DATE '2026-12-01', true,
   '{}'::jsonb, '2026-02-01T00:00:00Z', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.customer_profiles (id, display_name, email) VALUES
  ('11111111-1111-4111-8111-111111111111', 'Ada Invoice', 'ada@example.com')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.payments (id, amount, status) VALUES
  (7, 10.00, 'open')
ON CONFLICT (id) DO NOTHING;

SELECT agentgate.enroll_table(
  'public', 'invoices',
  ARRAY['tenant_id', 'payment_terms', 'amount', 'big_ref', 'due_on', 'paid', 'meta', 'updated_at', 'notes'],
  'tenant_id'
);
SELECT agentgate.enroll_table(
  'public', 'customer_profiles',
  ARRAY['display_name', 'email'],
  NULL
);
SELECT agentgate.enroll_table(
  'public', 'payments',
  ARRAY['amount', 'status'],
  NULL
);

CREATE TABLE IF NOT EXISTS public.bad_trigger (
  id bigint PRIMARY KEY,
  note text
);
CREATE OR REPLACE FUNCTION public.agentgate_bad_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS bad_touch ON public.bad_trigger;
CREATE TRIGGER bad_touch BEFORE UPDATE ON public.bad_trigger
  FOR EACH ROW EXECUTE FUNCTION public.agentgate_bad_touch();

CREATE TABLE IF NOT EXISTS public.bad_composite (
  a int NOT NULL,
  b int NOT NULL,
  note text,
  PRIMARY KEY (a, b)
);

CREATE OR REPLACE VIEW public.bad_view AS SELECT id FROM public.invoices;

CREATE TABLE IF NOT EXISTS public.bad_rule (
  id bigint PRIMARY KEY,
  note text
);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_rewrite r
    JOIN pg_class c ON c.oid = r.ev_class
    WHERE c.relname = 'bad_rule' AND r.rulename = 'bad_rule_delete'
  ) THEN
    CREATE RULE bad_rule_delete AS ON DELETE TO public.bad_rule DO INSTEAD NOTHING;
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.bad_generated (
  id bigint PRIMARY KEY,
  base_value int NOT NULL,
  double_value int GENERATED ALWAYS AS (base_value * 2) STORED
);

CREATE TABLE IF NOT EXISTS public.bad_type (
  id bigint PRIMARY KEY,
  payload bytea
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'bad_partition'
  ) THEN
    CREATE TABLE public.bad_partition (
      id bigint NOT NULL,
      created_on date NOT NULL,
      PRIMARY KEY (id, created_on)
    ) PARTITION BY RANGE (created_on);
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.bad_parent (
  id bigint PRIMARY KEY,
  note text
);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'bad_child'
  ) THEN
    CREATE TABLE public.bad_child (
      extra text
    ) INHERITS (public.bad_parent);
  END IF;
END
$$;
