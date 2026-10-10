#include "server.hpp"

#include <catch2/catch_test_macros.hpp>
#include <pqxx/pqxx>

#include <vector>

namespace {

void expect_unsupported(pqxx::connection &admin, const std::vector<std::string> &setup,
                        const std::string &enroll) {
  pqxx::work work(admin);
  for (const auto &sql : setup) {
    work.exec(sql);
  }
  try {
    work.exec(enroll);
    FAIL("enrollment should have been rejected");
  } catch (const pqxx::failure &error) {
    REQUIRE(std::string(error.what()).find("UNSUPPORTED_TABLE") != std::string::npos);
  }
}

} // namespace

TEST_CASE("enrollment rejects unsupported schemas and tracks revisions", "[integration]") {
  agentgate::test::require_database_env();
  pqxx::connection admin(agentgate::test::admin_url());

  expect_unsupported(
      admin,
      {"CREATE TABLE public.enroll_trigger (id bigint PRIMARY KEY, note text)",
       "CREATE OR REPLACE FUNCTION public.enroll_touch() RETURNS trigger LANGUAGE plpgsql "
       "AS $$ BEGIN RETURN NEW; END $$",
       "CREATE TRIGGER enroll_touch BEFORE UPDATE ON public.enroll_trigger "
       "FOR EACH ROW EXECUTE FUNCTION public.enroll_touch()"},
      "SELECT agentgate.enroll_table('public', 'enroll_trigger', ARRAY['note'], NULL)");

  expect_unsupported(
      admin, {"CREATE TABLE public.enroll_composite (a int, b int, note text, PRIMARY KEY (a, b))"},
      "SELECT agentgate.enroll_table('public', 'enroll_composite', ARRAY['note'], NULL)");

  expect_unsupported(admin,
                     {"CREATE TABLE public.enroll_base (id bigint PRIMARY KEY)",
                      "CREATE VIEW public.enroll_view AS SELECT id FROM public.enroll_base"},
                     "SELECT agentgate.enroll_table('public', 'enroll_view', ARRAY['id'], NULL)");

  expect_unsupported(
      admin,
      {"CREATE TABLE public.enroll_rule (id bigint PRIMARY KEY, note text)",
       "CREATE RULE enroll_rule_delete AS ON DELETE TO public.enroll_rule DO INSTEAD NOTHING"},
      "SELECT agentgate.enroll_table('public', 'enroll_rule', ARRAY['note'], NULL)");

  expect_unsupported(
      admin,
      {"CREATE TABLE public.enroll_generated (id bigint PRIMARY KEY, base_value int NOT NULL, "
       "double_value int GENERATED ALWAYS AS (base_value * 2) STORED)"},
      "SELECT agentgate.enroll_table('public', 'enroll_generated', ARRAY['base_value'], NULL)");

  expect_unsupported(
      admin, {"CREATE TABLE public.enroll_bytea (id bigint PRIMARY KEY, payload bytea)"},
      "SELECT agentgate.enroll_table('public', 'enroll_bytea', ARRAY['payload'], NULL)");

  expect_unsupported(
      admin,
      {"CREATE TABLE public.enroll_part (id bigint NOT NULL, created_on date NOT NULL, "
       "PRIMARY KEY (id, created_on)) PARTITION BY RANGE (created_on)"},
      "SELECT agentgate.enroll_table('public', 'enroll_part', ARRAY['created_on'], NULL)");

  expect_unsupported(
      admin,
      {"CREATE TABLE public.enroll_parent (id bigint PRIMARY KEY, note text)",
       "CREATE TABLE public.enroll_child (extra text) INHERITS (public.enroll_parent)"},
      "SELECT agentgate.enroll_table('public', 'enroll_child', ARRAY['note'], NULL)");

  {
    pqxx::work work(admin);
    work.exec("CREATE TABLE public.enroll_ok (id bigint PRIMARY KEY, note text)");
    work.exec("INSERT INTO public.enroll_ok (id, note) VALUES (1, 'before')");
    work.exec("SELECT agentgate.enroll_table('public', 'enroll_ok', ARRAY['note'], NULL)");
    const auto first = work.exec("SELECT agentgate_revision FROM public.enroll_ok WHERE id = 1")
                           .one_field()
                           .as<long>();
    REQUIRE(first == 1);
    work.exec("UPDATE public.enroll_ok SET note = 'after' WHERE id = 1");
    const auto second = work.exec("SELECT agentgate_revision FROM public.enroll_ok WHERE id = 1")
                            .one_field()
                            .as<long>();
    REQUIRE(second == 2);
    work.exec("UPDATE public.enroll_ok SET agentgate_revision = 1, note = 'again' WHERE id = 1");
    const auto third = work.exec("SELECT agentgate_revision FROM public.enroll_ok WHERE id = 1")
                           .one_field()
                           .as<long>();
    REQUIRE(third == 3);
    const auto before =
        work.exec("SELECT agentgate.schema_fingerprint('public.enroll_ok'::regclass)")
            .one_field()
            .as<std::string>();
    work.exec("ALTER TABLE public.enroll_ok ADD COLUMN extra_col text");
    const auto after =
        work.exec("SELECT agentgate.schema_fingerprint('public.enroll_ok'::regclass)")
            .one_field()
            .as<std::string>();
    REQUIRE(before != after);
    const auto stored = work.exec("SELECT schema_fingerprint FROM agentgate.table_registry "
                                  "WHERE schema_name = 'public' AND table_name = 'enroll_ok'")
                            .one_field()
                            .as<std::string>();
    REQUIRE(stored == before);
    work.exec("DROP TABLE public.enroll_ok");
    work.exec("DELETE FROM agentgate.table_registry WHERE schema_name = 'public' AND table_name = "
              "'enroll_ok'");
    work.commit();
  }

  {
    pqxx::work work(admin);
    work.exec("CREATE SCHEMA data_pr");
    try {
      work.exec("DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data_pr') "
                "AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'agentgate') THEN "
                "RAISE EXCEPTION 'both data_pr and agentgate schemas exist'; END IF; END $$");
      FAIL("both schemas should fail");
    } catch (const pqxx::failure &error) {
      REQUIRE(std::string(error.what()).find("both data_pr and agentgate") != std::string::npos);
    }
  }
}

TEST_CASE("migrator can enroll a table it owns", "[integration]") {
  agentgate::test::require_database_env();
  pqxx::connection admin(agentgate::test::admin_url());
  {
    pqxx::work work(admin);
    work.exec("CREATE TABLE public.migrator_ok (id bigint PRIMARY KEY, note text)");
    work.exec("ALTER TABLE public.migrator_ok OWNER TO agentgate_migrator");
    work.commit();
  }
  pqxx::connection migrator(agentgate::test::migrator_database_url());
  {
    pqxx::work work(migrator);
    REQUIRE_NOTHROW(
        work.exec("SELECT agentgate.enroll_table('public', 'migrator_ok', ARRAY['note'], NULL)"));
    work.commit();
  }
  {
    pqxx::work work(admin);
    work.exec("DROP TABLE public.migrator_ok");
    work.exec("DELETE FROM agentgate.table_registry WHERE schema_name = 'public' AND table_name = "
              "'migrator_ok'");
    work.commit();
  }
}
