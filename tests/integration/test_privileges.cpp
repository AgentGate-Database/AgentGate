#include "server.hpp"

#include <catch2/catch_test_macros.hpp>
#include <pqxx/pqxx>

namespace {

void expect_denied(pqxx::connection &connection, const std::string &sql) {
  pqxx::work work(connection);
  try {
    work.exec(sql);
    FAIL("expected permission denied");
  } catch (const pqxx::failure &error) {
    REQUIRE(std::string(error.sqlstate()) == "42501");
  }
}

} // namespace

TEST_CASE("runtime roles cannot write enrolled rows or call privileged functions",
          "[integration]") {
  agentgate::test::require_database_env();
  pqxx::connection admin(agentgate::test::admin_url());
  {
    pqxx::work work(admin);
    work.exec("CREATE TABLE IF NOT EXISTS public.priv_demo (id bigint PRIMARY KEY, note text)");
    work.exec("SELECT agentgate.enroll_table('public', 'priv_demo', ARRAY['note'], NULL)");
    work.exec(
        "INSERT INTO public.priv_demo (id, note) VALUES (1, 'a') ON CONFLICT (id) DO NOTHING");
    work.commit();
  }

  pqxx::connection api(agentgate::test::api_database_url());
  expect_denied(api, "UPDATE public.priv_demo SET note = 'hacked' WHERE id = 1");
  expect_denied(api, "INSERT INTO public.priv_demo (id, note) VALUES (2, 'x')");
  expect_denied(api, "DELETE FROM public.priv_demo WHERE id = 1");
  expect_denied(api, "INSERT INTO agentgate.principals (name, kind) VALUES ('x', 'proposer')");
  expect_denied(api, "UPDATE agentgate.table_registry SET schema_name = 'other'");
  expect_denied(api, "SELECT agentgate.enroll_table('public', 'priv_demo', ARRAY['note'], NULL)");
  expect_denied(api, "SELECT agentgate.issue_credential('x', 'proposer', '{}'::jsonb, "
                     "gen_random_uuid(), decode(repeat('ab', 32), 'hex'))");

  pqxx::connection worker(agentgate::test::worker_database_url());
  expect_denied(worker, "UPDATE public.priv_demo SET note = 'hacked' WHERE id = 1");
  expect_denied(worker,
                "SELECT agentgate.approve(gen_random_uuid(), gen_random_uuid(), '{}'::jsonb, "
                "'worker-key', repeat('a', 64))");
  {
    pqxx::work work(worker);
    REQUIRE_NOTHROW(work.exec("SELECT agentgate.expire_prs()"));
    work.commit();
  }
}
