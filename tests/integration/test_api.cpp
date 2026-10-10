#include "http_client.hpp"
#include "server.hpp"

#include "agentgate/crypto.hpp"
#include "agentgate/schema.hpp"

#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>
#include <pqxx/pqxx>

#include <string>
#include <thread>
#include <vector>

namespace {

using agentgate::test::http_request;
using agentgate::test::HttpResult;
using agentgate::test::server_port;

struct Cred {
  std::string token;
  std::string principal_id;
  std::string credential_id;
};

std::string next_key() {
  return "k" + agentgate::random_token_secret(12);
}

nlohmann::json acme_scope() {
  return nlohmann::json{
      {"tables",
       nlohmann::json::array({nlohmann::json{{"schema", "public"},
                                             {"name", "invoices"},
                                             {"tenants", nlohmann::json::array({"acme"})}}})}};
}

Cred issue(pqxx::connection &db, const std::string &name, const std::string &kind,
           const nlohmann::json &scopes) {
  const auto secret = agentgate::random_token_secret();
  const auto digest = agentgate::sha256_bytes(secret);
  const auto hex = agentgate::to_hex(digest.data(), digest.size());
  pqxx::work work(db);
  const auto row =
      work.exec("SELECT id::text, agentgate.issue_credential($1, $2, $3::jsonb, id, "
                "decode($4, 'hex'))::text FROM (SELECT gen_random_uuid() AS id) generated",
                pqxx::params{name, kind, scopes.dump(), hex})
          .one_row();
  work.commit();
  Cred cred;
  cred.credential_id = row[0].as<std::string>();
  cred.principal_id = row[1].as<std::string>();
  cred.token = "agk_" + cred.credential_id + "_" + secret;
  return cred;
}

void ensure_invoices(pqxx::connection &admin) {
  pqxx::work work(admin);
  work.exec(
      "CREATE TABLE IF NOT EXISTS public.invoices ("
      "id bigint PRIMARY KEY, tenant_id text NOT NULL, payment_terms text, amount numeric(20, 4), "
      "big_ref bigint, due_on date, paid boolean NOT NULL DEFAULT false, meta jsonb, "
      "updated_at timestamptz, notes text)");
  work.exec("SELECT agentgate.enroll_table('public', 'invoices', "
            "ARRAY['tenant_id','payment_terms','amount','big_ref','due_on','paid','meta','updated_"
            "at','notes'], "
            "'tenant_id')");
  work.exec("INSERT INTO public.invoices (id, tenant_id, payment_terms, amount, big_ref, due_on, "
            "paid, meta, "
            "updated_at, notes) VALUES "
            "(482, 'acme', 'net_15', 1999.5000, 9007199254740993, DATE '2026-11-01', false, "
            "'{\"source\":\"seed\"}'::jsonb, '2026-01-15T00:00:00Z', 'seed invoice'), "
            "(483, 'other', 'net_30', 50, 1, DATE '2026-12-01', true, '{}'::jsonb, "
            "'2026-02-01T00:00:00Z', NULL) "
            "ON CONFLICT (id) DO NOTHING");
  for (int id = 9301; id <= 9306; ++id) {
    work.exec(
        "INSERT INTO public.invoices (id, tenant_id, payment_terms) VALUES ($1, 'acme', 'net_15') "
        "ON CONFLICT (id) DO NOTHING",
        pqxx::params{id});
  }
  work.commit();
}

struct Env {
  pqxx::connection admin;
  Cred proposer;
  Cred reviewer;
  Cred other;
  Cred unassigned;

  Env()
      : admin(agentgate::test::admin_url()),
        proposer(issue(admin, "proposer", "proposer", acme_scope())),
        reviewer(issue(admin, "reviewer", "reviewer", nlohmann::json::object())),
        other(issue(admin, "other", "proposer", acme_scope())),
        unassigned(issue(admin, "unassigned", "reviewer", nlohmann::json::object())) {
    ensure_invoices(admin);
    pqxx::work work(admin);
    work.exec("SELECT agentgate.assign_reviewer($1::uuid, 'public', 'invoices')",
              pqxx::params{reviewer.principal_id});
    work.commit();
  }
};

Env &env() {
  static Env instance;
  return instance;
}

void require_api() {
  agentgate::test::require_database_env();
  if (!agentgate::test::server_error.empty()) {
    FAIL(agentgate::test::server_error);
  }
}

HttpResult call(const std::string &method, const std::string &path, const std::string &token,
                const std::string &body, const std::string &key) {
  std::vector<std::pair<std::string, std::string>> headers;
  if (!token.empty()) {
    headers.emplace_back("Authorization", "Bearer " + token);
  }
  if (!key.empty()) {
    headers.emplace_back("Idempotency-Key", key);
  }
  return http_request(server_port, method, path, body, headers);
}

std::string revision_of(long id) {
  pqxx::work work(env().admin);
  const auto value = work.exec("SELECT agentgate_revision::text FROM public.invoices WHERE id = $1",
                               pqxx::params{id})
                         .one_field()
                         .as<std::string>();
  work.commit();
  return value;
}

std::string terms_of(long id) {
  pqxx::work work(env().admin);
  const auto value =
      work.exec("SELECT payment_terms FROM public.invoices WHERE id = $1", pqxx::params{id})
          .one_field()
          .as<std::string>();
  work.commit();
  return value;
}

nlohmann::json proposal(long id, const std::string &revision, nlohmann::json set,
                        const std::string &title, const std::string &operation = "update") {
  return nlohmann::json{
      {"title", title},
      {"reason", "update the invoice"},
      {"expires_in_seconds", 3600},
      {"changes", nlohmann::json::array({nlohmann::json{{"operation", operation},
                                                        {"schema", "public"},
                                                        {"table", "invoices"},
                                                        {"key", {{"id", std::to_string(id)}}},
                                                        {"expected_revision", revision},
                                                        {"set", std::move(set)}}})}};
}

void expect_schema(const char *name, const nlohmann::json &body) {
  const auto schema = agentgate::load_contract_schema(AGENTGATE_CONTRACTS_DIR, name);
  agentgate::validate_json(schema, body);
}

void expect_error(const HttpResult &response, int status, const std::string &code) {
  INFO(response.body);
  REQUIRE(response.status == status);
  const auto parsed = nlohmann::json::parse(response.body);
  expect_schema("error.json", parsed);
  REQUIRE(parsed["error"]["code"] == code);
}

} // namespace

TEST_CASE("health endpoints answer without a credential", "[integration]") {
  require_api();
  const auto health = call("GET", "/healthz", "", "", "");
  REQUIRE(health.status == 200);
  REQUIRE(nlohmann::json::parse(health.body)["status"] == "ok");
  const auto ready = call("GET", "/readyz", "", "", "");
  REQUIRE(ready.status == 200);
}

TEST_CASE("proposals move through review and keep the documented contract", "[integration]") {
  require_api();
  const auto rev = revision_of(482);
  const auto before = terms_of(482);
  const auto after = before == "net_45" ? "net_60" : "net_45";
  const auto body =
      proposal(482, rev, nlohmann::json{{"payment_terms", after}}, "Correct invoice payment terms");
  const auto raw = body.dump();
  const auto created = call("POST", "/v1/prs", env().proposer.token, raw, next_key());
  INFO(created.body);
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  expect_schema("pr_response.json", created_json);
  REQUIRE(created_json["state"] == "pending_review");
  REQUIRE(created_json["policy_decision"] == "manual_review_required");
  REQUIRE(created_json["diff"]["changes"][0]["fields"][0]["after"] == after);
  const auto pr_id = created_json["pr_id"].get<std::string>();
  const auto hash = created_json["content_hash"].get<std::string>();

  const auto fetched = call("GET", "/v1/prs/" + pr_id, env().proposer.token, "", "");
  REQUIRE(fetched.status == 200);
  expect_schema("pr_response.json", nlohmann::json::parse(fetched.body));

  const auto diff = call("GET", "/v1/prs/" + pr_id + "/diff", env().proposer.token, "", "");
  INFO(diff.body);
  REQUIRE(diff.status == 200);
  const auto diff_json = nlohmann::json::parse(diff.body);
  expect_schema("diff_response.json", diff_json);
  REQUIRE(diff_json["changes"][0]["fields"][0]["before"] == before);
  REQUIRE(diff_json["changes"][0]["fields"][0]["after"] == after);

  const auto events = call("GET", "/v1/prs/" + pr_id + "/events", env().proposer.token, "", "");
  REQUIRE(events.status == 200);
  const auto events_json = nlohmann::json::parse(events.body);
  expect_schema("events_response.json", events_json);
  REQUIRE(events_json["events"][0]["type"] == "pr.created");

  const auto listed =
      call("GET", "/v1/prs?status=pending_review&schema=public&table=invoices&limit=20",
           env().proposer.token, "", "");
  REQUIRE(listed.status == 200);
  const auto listed_json = nlohmann::json::parse(listed.body);
  expect_schema("list_response.json", listed_json);
  REQUIRE(listed.body.find(pr_id) != std::string::npos);

  const auto hidden = call("GET", "/v1/prs/" + pr_id + "/diff", env().other.token, "", "");
  expect_error(hidden, 404, "NOT_FOUND");
  REQUIRE(hidden.body.find(after) == std::string::npos);
  REQUIRE(hidden.body.find(before) == std::string::npos);

  nlohmann::json review{
      {"revision", 1}, {"content_hash", hash}, {"reviewer_id", env().proposer.principal_id}};
  const auto spoofed = call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token,
                            review.dump(), next_key());
  INFO(spoofed.body);
  REQUIRE(spoofed.status == 200);
  expect_schema("review_response.json", nlohmann::json::parse(spoofed.body));
  REQUIRE(nlohmann::json::parse(spoofed.body)["state"] == "approved");
  {
    pqxx::work work(env().admin);
    const auto approver =
        work.exec("SELECT principal_id::text FROM agentgate.approvals WHERE pr_id = $1::uuid",
                  pqxx::params{pr_id})
            .one_field()
            .as<std::string>();
    work.commit();
    REQUIRE(approver == env().reviewer.principal_id);
  }
  const auto again = call("GET", "/v1/prs/" + pr_id, env().proposer.token, "", "");
  REQUIRE(nlohmann::json::parse(again.body)["state"] == "approved");
}

TEST_CASE("idempotency replays the stored response and rejects a different body", "[integration]") {
  require_api();
  const auto current = terms_of(482);
  const auto body =
      proposal(482, revision_of(482),
               nlohmann::json{{"payment_terms", current == "net_60" ? "net_45" : "net_60"}},
               "idempotent terms");
  const auto raw = body.dump();
  const auto key = next_key();
  const auto first = call("POST", "/v1/prs", env().proposer.token, raw, key);
  const auto second = call("POST", "/v1/prs", env().proposer.token, raw, key);
  REQUIRE(first.status == 201);
  REQUIRE(second.status == 201);
  REQUIRE(nlohmann::json::parse(first.body)["pr_id"] ==
          nlohmann::json::parse(second.body)["pr_id"]);

  auto changed = body;
  changed["title"] = "different title";
  const auto conflict = call("POST", "/v1/prs", env().proposer.token, changed.dump(), key);
  expect_error(conflict, 409, "IDEMPOTENCY_CONFLICT");
}

TEST_CASE("parallel identical posts create one proposal", "[integration]") {
  require_api();
  const auto title = "concurrent-" + next_key();
  const auto raw =
      proposal(482, revision_of(482), nlohmann::json{{"payment_terms", "net_75"}}, title).dump();
  const auto key = next_key();
  HttpResult left;
  HttpResult right;
  std::thread a([&] { left = call("POST", "/v1/prs", env().proposer.token, raw, key); });
  std::thread b([&] { right = call("POST", "/v1/prs", env().proposer.token, raw, key); });
  a.join();
  b.join();
  INFO(left.body);
  INFO(right.body);
  REQUIRE(left.status == 201);
  REQUIRE(right.status == 201);
  REQUIRE(nlohmann::json::parse(left.body)["pr_id"] == nlohmann::json::parse(right.body)["pr_id"]);
  pqxx::work work(env().admin);
  const auto count =
      work.exec("SELECT count(*) FROM agentgate.prs WHERE title = $1", pqxx::params{title})
          .one_field()
          .as<int>();
  work.commit();
  REQUIRE(count == 1);
}

TEST_CASE("approval and revision serialize on the proposal lock", "[integration]") {
  require_api();
  const auto created = call(
      "POST", "/v1/prs", env().proposer.token,
      proposal(482, revision_of(482), nlohmann::json{{"notes", "lock-race"}}, "lock race").dump(),
      next_key());
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  const auto pr_id = created_json["pr_id"].get<std::string>();
  const auto hash = created_json["content_hash"].get<std::string>();
  const auto review = nlohmann::json{{"revision", 1}, {"content_hash", hash}}.dump();
  const auto revised =
      proposal(482, revision_of(482), nlohmann::json{{"notes", "lock-race-2"}}, "lock race revised")
          .dump();
  HttpResult approved;
  HttpResult revision;
  std::thread a([&] {
    approved =
        call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token, review, next_key());
  });
  std::thread b([&] {
    revision =
        call("POST", "/v1/prs/" + pr_id + "/revisions", env().proposer.token, revised, next_key());
  });
  a.join();
  b.join();
  INFO(approved.body);
  INFO(revision.body);
  REQUIRE(revision.status == 201);
  REQUIRE((approved.status == 200 || approved.status == 409));
  const auto fetched = call("GET", "/v1/prs/" + pr_id, env().proposer.token, "", "");
  const auto fetched_json = nlohmann::json::parse(fetched.body);
  REQUIRE(fetched_json["state"] == "pending_review");
  REQUIRE(fetched_json["revision"] == 2);
}

TEST_CASE("review rules reject self approval, missing assignment, stale revisions, and expiry",
          "[integration]") {
  require_api();
  const auto created = call(
      "POST", "/v1/prs", env().proposer.token,
      proposal(482, revision_of(482), nlohmann::json{{"payment_terms", "net_90"}}, "review rules")
          .dump(),
      next_key());
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  const auto pr_id = created_json["pr_id"].get<std::string>();
  const auto hash = created_json["content_hash"].get<std::string>();
  const auto review = nlohmann::json{{"revision", 1}, {"content_hash", hash}}.dump();

  const auto self =
      call("POST", "/v1/prs/" + pr_id + "/approve", env().proposer.token, review, next_key());
  expect_error(self, 403, "FORBIDDEN");
  REQUIRE(self.body.find("cannot approve its own PR") != std::string::npos);

  const auto stranger =
      call("POST", "/v1/prs/" + pr_id + "/approve", env().unassigned.token, review, next_key());
  expect_error(stranger, 403, "FORBIDDEN");

  const auto approved =
      call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token, review, next_key());
  REQUIRE(approved.status == 200);

  const auto revised_body = proposal(
      482, revision_of(482), nlohmann::json{{"payment_terms", "net_120"}}, "review rules revised");
  const auto revised = call("POST", "/v1/prs/" + pr_id + "/revisions", env().proposer.token,
                            revised_body.dump(), next_key());
  REQUIRE(revised.status == 201);
  REQUIRE(nlohmann::json::parse(revised.body)["state"] == "pending_review");

  const auto stale =
      call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token, review, next_key());
  expect_error(stale, 409, "REVISION_MISMATCH");
  const auto after =
      nlohmann::json::parse(call("GET", "/v1/prs/" + pr_id, env().proposer.token, "", "").body);
  REQUIRE(after["state"] == "pending_review");
  REQUIRE(after["revision"] == 2);

  {
    pqxx::work work(env().admin);
    work.exec(
        "UPDATE agentgate.prs SET expires_at = now() - interval '1 minute' WHERE id = $1::uuid",
        pqxx::params{pr_id});
    work.commit();
  }
  const auto new_hash = after["content_hash"].get<std::string>();
  const auto expired_review = nlohmann::json{{"revision", 2}, {"content_hash", new_hash}}.dump();
  const auto expired = call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token,
                            expired_review, next_key());
  expect_error(expired, 409, "PR_EXPIRED");
  const auto expired_get =
      nlohmann::json::parse(call("GET", "/v1/prs/" + pr_id, env().proposer.token, "", "").body);
  REQUIRE(expired_get["state"] == "expired");
}

TEST_CASE("revoked credentials and tenant scope are enforced", "[integration]") {
  require_api();
  auto doomed = issue(env().admin, "doomed", "proposer", acme_scope());
  {
    pqxx::work work(env().admin);
    work.exec("UPDATE agentgate.credentials SET revoked_at = now() WHERE id = $1::uuid",
              pqxx::params{doomed.credential_id});
    work.commit();
  }
  const auto denied = call("GET", "/v1/prs", doomed.token, "", "");
  expect_error(denied, 401, "UNAUTHORIZED");

  const auto tenant = call(
      "POST", "/v1/prs", env().proposer.token,
      proposal(483, revision_of(483), nlohmann::json{{"payment_terms", "net_10"}}, "wrong tenant")
          .dump(),
      next_key());
  expect_error(tenant, 403, "FORBIDDEN");
}

TEST_CASE("proposal validation rejects unsafe and empty changes", "[integration]") {
  require_api();
  const auto rev = revision_of(482);
  const auto token = env().proposer.token;

  const auto missing_key =
      call("POST", "/v1/prs", token, proposal(482, rev, {{"notes", "x"}}, "no key").dump(), "");
  expect_error(missing_key, 422, "VALIDATION_FAILED");

  const auto bad_json = call("POST", "/v1/prs", token, "{", next_key());
  expect_error(bad_json, 422, "VALIDATION_FAILED");

  const auto unauth = call("POST", "/v1/prs", "",
                           proposal(482, rev, {{"notes", "x"}}, "no auth").dump(), next_key());
  expect_error(unauth, 401, "UNAUTHORIZED");

  auto injected = proposal(482, rev, {{"notes", "x"}}, "inject");
  injected["changes"][0]["schema"] = "public; DROP TABLE public.invoices;--";
  const auto injection = call("POST", "/v1/prs", token, injected.dump(), next_key());
  expect_error(injection, 422, "VALIDATION_FAILED");
  {
    pqxx::work work(env().admin);
    REQUIRE(work.exec("SELECT to_regclass('public.invoices') IS NOT NULL").one_field().as<bool>());
    work.commit();
  }

  auto bad_column = proposal(482, rev, nlohmann::json::object(), "column");
  bad_column["changes"][0]["set"] = nlohmann::json{{"notes;drop", "x"}};
  expect_error(call("POST", "/v1/prs", token, bad_column.dump(), next_key()), 422,
               "VALIDATION_FAILED");

  auto duplicate = proposal(482, rev, {{"notes", "one"}}, "duplicate");
  duplicate["changes"].push_back(duplicate["changes"][0]);
  expect_error(call("POST", "/v1/prs", token, duplicate.dump(), next_key()), 422,
               "VALIDATION_FAILED");

  expect_error(call("POST", "/v1/prs", token,
                    proposal(482, rev, {{"payment_terms", terms_of(482)}}, "noop").dump(),
                    next_key()),
               422, "VALIDATION_FAILED");

  auto with_null = proposal(482, rev, nlohmann::json{{"notes", nullptr}}, "null note");
  const auto nulled = call("POST", "/v1/prs", token, with_null.dump(), next_key());
  INFO(nulled.body);
  REQUIRE(nulled.status == 201);
  REQUIRE(nlohmann::json::parse(nulled.body)["diff"]["changes"][0]["fields"][0]["after"].is_null());

  const auto precise = call(
      "POST", "/v1/prs", token,
      proposal(482, rev,
               nlohmann::json{{"big_ref", "9007199254740995"}, {"amount", "1234567890123456.1234"}},
               "precision")
          .dump(),
      next_key());
  INFO(precise.body);
  REQUIRE(precise.status == 201);
  REQUIRE(precise.body.find("9007199254740995") != std::string::npos);
  REQUIRE(precise.body.find("1234567890123456.1234") != std::string::npos);

  expect_error(call("POST", "/v1/prs", token,
                    proposal(482, rev, {{"notes", "z"}}, "insert", "insert").dump(), next_key()),
               422, "UNSUPPORTED_OPERATION");
  expect_error(call("POST", "/v1/prs", token,
                    proposal(482, rev, {{"notes", "z"}}, "delete", "delete").dump(), next_key()),
               422, "UNSUPPORTED_OPERATION");

  auto reads = proposal(482, rev, {{"notes", "tracked"}}, "reads");
  reads["read_tokens"] = nlohmann::json::array({"token-1"});
  expect_error(call("POST", "/v1/prs", token, reads.dump(), next_key()), 404, "NOT_FOUND");

  auto unknown = proposal(482, rev, {{"notes", "z"}}, "missing table");
  unknown["changes"][0]["table"] = "not_enrolled";
  expect_error(call("POST", "/v1/prs", token, unknown.dump(), next_key()), 422,
               "UNSUPPORTED_TABLE");

  expect_error(call("POST", "/v1/prs", token,
                    proposal(999999, "1", {{"notes", "z"}}, "missing row").dump(), next_key()),
               404, "NOT_FOUND");

  nlohmann::json too_many =
      proposal(9301, revision_of(9301), {{"payment_terms", "net_99"}}, "too many");
  for (int id = 9302; id <= 9306; ++id) {
    too_many["changes"].push_back(nlohmann::json{{"operation", "update"},
                                                 {"schema", "public"},
                                                 {"table", "invoices"},
                                                 {"key", {{"id", std::to_string(id)}}},
                                                 {"expected_revision", revision_of(id)},
                                                 {"set", {{"payment_terms", "net_99"}}}});
  }
  expect_error(call("POST", "/v1/prs", token, too_many.dump(), next_key()), 429, "LIMIT_EXCEEDED");

  auto huge = proposal(482, rev, nlohmann::json{{"notes", std::string(9000, 'n')}}, "huge");
  expect_error(call("POST", "/v1/prs", token, huge.dump(), next_key()), 429, "LIMIT_EXCEEDED");
}
