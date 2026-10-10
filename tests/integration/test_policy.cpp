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
};

std::string next_key() {
  return "p" + agentgate::random_token_secret(12);
}

nlohmann::json scope_for(std::initializer_list<std::pair<const char *, bool>> tables) {
  nlohmann::json listed = nlohmann::json::array();
  for (const auto &table : tables) {
    nlohmann::json entry{{"schema", "public"}, {"name", table.first}};
    if (table.second) {
      entry["tenants"] = nlohmann::json::array({"acme"});
    }
    listed.push_back(entry);
  }
  return nlohmann::json{{"tables", listed}};
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
  cred.principal_id = row[1].as<std::string>();
  cred.token = "agk_" + row[0].as<std::string>() + "_" + secret;
  return cred;
}

struct Env {
  pqxx::connection admin;
  pqxx::connection worker;
  Cred proposer;
  Cred other;
  Cred invoice_reviewer;
  Cred payments_reviewer;

  Env()
      : admin(agentgate::test::admin_url()), worker(agentgate::test::worker_database_url()),
        proposer(issue(
            admin, "policy-proposer", "proposer",
            scope_for({{"invoices", true}, {"customer_profiles", false}, {"payments", false}}))),
        other(issue(admin, "policy-other", "proposer",
                    scope_for({{"invoices", true}, {"customer_profiles", false}}))),
        invoice_reviewer(
            issue(admin, "policy-invoice-reviewer", "reviewer", nlohmann::json::object())),
        payments_reviewer(
            issue(admin, "policy-payments-reviewer", "reviewer", nlohmann::json::object())) {
    pqxx::work work(admin);
    work.exec("SELECT agentgate.assign_reviewer($1::uuid, 'public', 'invoices')",
              pqxx::params{invoice_reviewer.principal_id});
    work.exec("SELECT agentgate.assign_reviewer($1::uuid, 'public', 'payments')",
              pqxx::params{payments_reviewer.principal_id});
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

struct PolicyGuard {
  int version{0};

  PolicyGuard() {
    pqxx::work work(env().admin);
    version = work.exec("SELECT max(version) FROM agentgate.policies").one_field().as<int>();
    work.commit();
  }

  ~PolicyGuard() {
    try {
      pqxx::connection db(agentgate::test::admin_url());
      pqxx::work work(db);
      work.exec("SELECT agentgate.publish_policy(document) FROM agentgate.policies "
                "WHERE version = $1",
                pqxx::params{version});
      work.commit();
    } catch (const std::exception &) {
    }
  }
};

void publish(const nlohmann::json &document) {
  pqxx::work work(env().admin);
  work.exec("SELECT agentgate.publish_policy($1::jsonb)", pqxx::params{document.dump()});
  work.commit();
}

nlohmann::json seeded_policy() {
  return nlohmann::json{
      {"default", "manual_review_required"},
      {"rules", nlohmann::json::array(
                    {nlohmann::json{{"effect", "auto_approved"},
                                    {"schema", "public"},
                                    {"table", "customer_profiles"},
                                    {"operations", nlohmann::json::array({"update"})},
                                    {"columns", nlohmann::json::array({"display_name", "email"})},
                                    {"max_rows", 9}},
                     nlohmann::json{{"effect", "manual_review_required"},
                                    {"schema", "public"},
                                    {"table", "payments"}}})},
      {"limits", {{"window_seconds", 3600}, {"max_rows", 1000}, {"max_requests", 1000}}}};
}

long fresh_invoice() {
  pqxx::work work(env().admin);
  const auto id = work.exec("INSERT INTO public.invoices (id, tenant_id, payment_terms, paid) "
                            "VALUES ((SELECT COALESCE(MAX(id), 1000000) + 1 FROM public.invoices), "
                            "'acme', 'net_15', false) RETURNING id")
                      .one_field()
                      .as<long>();
  work.commit();
  return id;
}

std::string fresh_profile() {
  pqxx::work work(env().admin);
  const auto id = work.exec("INSERT INTO public.customer_profiles (id, display_name, email) "
                            "VALUES (gen_random_uuid(), 'Policy Profile', 'policy@example.com') "
                            "RETURNING id::text")
                      .one_field()
                      .as<std::string>();
  work.commit();
  return id;
}

long fresh_payment() {
  pqxx::work work(env().admin);
  const auto id = work.exec("INSERT INTO public.payments (id, amount, status) "
                            "VALUES ((SELECT COALESCE(MAX(id), 100) + 1 FROM public.payments), "
                            "10.00, 'open') RETURNING id")
                      .one_field()
                      .as<long>();
  work.commit();
  return id;
}

std::string text_field(const std::string &sql, long id) {
  pqxx::work work(env().admin);
  const auto value = work.exec(sql, pqxx::params{id}).one_field().as<std::string>();
  work.commit();
  return value;
}

nlohmann::json change_of(const std::string &table, const std::string &key_name,
                         const std::string &key, const std::string &revision,
                         const nlohmann::json &set) {
  return nlohmann::json{{"operation", "update"},
                        {"schema", "public"},
                        {"table", table},
                        {"key", {{key_name, key}}},
                        {"expected_revision", revision},
                        {"set", set}};
}

nlohmann::json proposal(const std::string &title, const nlohmann::json &changes,
                        const nlohmann::json &tokens = nlohmann::json::array()) {
  nlohmann::json body{{"title", title},
                      {"reason", "policy fixture"},
                      {"expires_in_seconds", 3600},
                      {"changes", changes}};
  if (!tokens.empty()) {
    body["read_tokens"] = tokens;
  }
  return body;
}

nlohmann::json post_pr(const nlohmann::json &body) {
  const auto created = call("POST", "/v1/prs", env().proposer.token, body.dump(), next_key());
  INFO(created.body);
  REQUIRE(created.status == 201);
  const auto parsed = nlohmann::json::parse(created.body);
  expect_schema("pr_response.json", parsed);
  return parsed;
}

void approve(const nlohmann::json &created, const Cred &reviewer) {
  nlohmann::json review{{"revision", created["revision"]},
                        {"content_hash", created["content_hash"]}};
  const auto approved = call("POST", "/v1/prs/" + created["pr_id"].get<std::string>() + "/approve",
                             reviewer.token, review.dump(), next_key());
  INFO(approved.body);
  REQUIRE(approved.status == 200);
}

nlohmann::json enqueue(const nlohmann::json &created) {
  nlohmann::json review{{"revision", created["revision"]},
                        {"content_hash", created["content_hash"]}};
  const auto merged = call("POST", "/v1/prs/" + created["pr_id"].get<std::string>() + "/merge",
                           env().proposer.token, review.dump(), next_key());
  INFO(merged.body);
  REQUIRE(merged.status == 202);
  return nlohmann::json::parse(merged.body);
}

void merge_job(const std::string &job_id) {
  pqxx::work work(env().worker);
  work.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{job_id});
  work.commit();
}

int merged_events(const std::string &pr_id) {
  pqxx::work work(env().admin);
  const auto count = work.exec("SELECT count(*) FROM agentgate.audit_events "
                               "WHERE pr_id = $1::uuid AND event_type = 'pr.merged'",
                               pqxx::params{pr_id})
                         .one_field()
                         .as<int>();
  work.commit();
  return count;
}

} // namespace

TEST_CASE("a small profile update is auto-approved and merges once", "[integration]") {
  require_api();
  const auto id = fresh_profile();
  const auto created = post_pr(
      proposal("rename profile",
               nlohmann::json::array({change_of("customer_profiles", "id", id, "1",
                                                nlohmann::json{{"email", "ada@example.com"}})})));
  REQUIRE(created["policy_decision"] == "auto_approved");
  REQUIRE(created["state"] == "approved");
  REQUIRE(created["approvals"].empty());
  const auto queued = enqueue(created);
  merge_job(queued["job_id"].get<std::string>());
  pqxx::work check(env().admin);
  const auto email =
      check.exec("SELECT email FROM public.customer_profiles WHERE id = $1::uuid", pqxx::params{id})
          .one_field()
          .as<std::string>();
  const auto approvals =
      check
          .exec("SELECT count(*) FROM agentgate.approvals WHERE pr_id = $1::uuid",
                pqxx::params{created["pr_id"].get<std::string>()})
          .one_field()
          .as<int>();
  const auto receipts =
      check
          .exec("SELECT count(*) FROM agentgate.merge_receipts WHERE pr_id = $1::uuid",
                pqxx::params{created["pr_id"].get<std::string>()})
          .one_field()
          .as<int>();
  check.commit();
  REQUIRE(email == "ada@example.com");
  REQUIRE(approvals == 0);
  REQUIRE(receipts == 1);
  REQUIRE(merged_events(created["pr_id"].get<std::string>()) == 1);
}

TEST_CASE("payments stay in review and only a payments reviewer can approve", "[integration]") {
  require_api();
  const auto id = fresh_payment();
  const auto created = post_pr(proposal(
      "update payment", nlohmann::json::array({change_of("payments", "id", std::to_string(id), "1",
                                                         nlohmann::json{{"status", "paid"}})})));
  REQUIRE(created["policy_decision"] == "manual_review_required");
  REQUIRE(created["state"] == "pending_review");
  nlohmann::json review{{"revision", created["revision"]},
                        {"content_hash", created["content_hash"]}};
  const auto denied = call("POST", "/v1/prs/" + created["pr_id"].get<std::string>() + "/approve",
                           env().invoice_reviewer.token, review.dump(), next_key());
  expect_error(denied, 403, "FORBIDDEN");
  approve(created, env().payments_reviewer);
}

TEST_CASE("a mixed profile and payment change requires manual review", "[integration]") {
  require_api();
  const auto profile = fresh_profile();
  const auto payment = fresh_payment();
  const auto created = post_pr(
      proposal("mixed change",
               nlohmann::json::array({change_of("customer_profiles", "id", profile, "1",
                                                nlohmann::json{{"display_name", "Mixed"}}),
                                      change_of("payments", "id", std::to_string(payment), "1",
                                                nlohmann::json{{"status", "settled"}})})));
  REQUIRE(created["policy_decision"] == "manual_review_required");
  REQUIRE(created["state"] == "pending_review");
}

TEST_CASE("a block rule rejects the proposal and writes nothing", "[integration]") {
  require_api();
  PolicyGuard guard;
  auto document = seeded_policy();
  document["rules"].push_back(nlohmann::json{{"effect", "block"},
                                             {"schema", "public"},
                                             {"table", "invoices"},
                                             {"columns", nlohmann::json::array({"paid"})}});
  publish(document);
  const auto id = fresh_invoice();
  pqxx::work before(env().admin);
  const auto prior = before
                         .exec("SELECT count(*) FROM agentgate.audit_events "
                               "WHERE principal_id = $1::uuid AND event_type = 'pr.blocked' "
                               "AND pr_id IS NULL",
                               pqxx::params{env().proposer.principal_id})
                         .one_field()
                         .as<int>();
  before.commit();
  const auto created =
      call("POST", "/v1/prs", env().proposer.token,
           proposal("block paid",
                    nlohmann::json::array({change_of("invoices", "id", std::to_string(id), "1",
                                                     nlohmann::json{{"paid", true}})}))
               .dump(),
           next_key());
  expect_error(created, 422, "POLICY_BLOCKED");
  REQUIRE(text_field("SELECT paid::text FROM public.invoices WHERE id = $1", id) == "false");
  REQUIRE(text_field("SELECT agentgate_revision::text FROM public.invoices WHERE id = $1", id) ==
          "1");
  pqxx::work after(env().admin);
  const auto events = after
                          .exec("SELECT count(*) FROM agentgate.audit_events "
                                "WHERE principal_id = $1::uuid AND event_type = 'pr.blocked' "
                                "AND pr_id IS NULL",
                                pqxx::params{env().proposer.principal_id})
                          .one_field()
                          .as<int>();
  after.commit();
  REQUIRE(events == prior + 1);
  (void)guard;
}

TEST_CASE("a changed dependency rolls back the proposal", "[integration]") {
  require_api();
  const auto target = fresh_invoice();
  const auto dependency = fresh_invoice();
  const auto read =
      call("POST", "/v1/reads", env().proposer.token,
           nlohmann::json{{"expires_in_seconds", 3600},
                          {"reads", nlohmann::json::array({nlohmann::json{
                                        {"schema", "public"},
                                        {"table", "invoices"},
                                        {"key", {{"id", std::to_string(dependency)}}},
                                        {"columns", nlohmann::json::array({"payment_terms"})}}})}}
               .dump(),
           "");
  INFO(read.body);
  REQUIRE(read.status == 200);
  const auto read_json = nlohmann::json::parse(read.body);
  expect_schema("read_response.json", read_json);
  const auto created = post_pr(
      proposal("write target keep dependency",
               nlohmann::json::array({change_of("invoices", "id", std::to_string(target), "1",
                                                nlohmann::json{{"payment_terms", "net_45"}})}),
               nlohmann::json::array({read_json["token"]})));
  approve(created, env().invoice_reviewer);
  {
    pqxx::work work(env().admin);
    work.exec("UPDATE public.invoices SET payment_terms = 'net_60' WHERE id = $1",
              pqxx::params{dependency});
    work.commit();
  }
  const auto queued = enqueue(created);
  bool drifted = false;
  try {
    merge_job(queued["job_id"].get<std::string>());
  } catch (const pqxx::sql_error &error) {
    REQUIRE(std::string(error.sqlstate()) == "AG008");
    drifted = true;
  }
  REQUIRE(drifted);
  {
    pqxx::work work(env().worker);
    work.exec("SELECT agentgate.record_merge_failure($1::uuid, 'DRIFT_CONFLICT')",
              pqxx::params{queued["job_id"].get<std::string>()});
    work.commit();
  }
  REQUIRE(text_field("SELECT payment_terms FROM public.invoices WHERE id = $1", target) ==
          "net_15");
  REQUIRE(merged_events(created["pr_id"].get<std::string>()) == 0);
}

TEST_CASE("a newer policy version blocks merge", "[integration]") {
  require_api();
  PolicyGuard guard;
  const auto id = fresh_invoice();
  const auto created = post_pr(
      proposal("terms before policy change",
               nlohmann::json::array({change_of("invoices", "id", std::to_string(id), "1",
                                                nlohmann::json{{"payment_terms", "net_45"}})})));
  approve(created, env().invoice_reviewer);
  publish(seeded_policy());
  const auto queued = enqueue(created);
  bool blocked = false;
  try {
    merge_job(queued["job_id"].get<std::string>());
  } catch (const pqxx::sql_error &error) {
    REQUIRE(std::string(error.sqlstate()) == "AG005");
    blocked = true;
  }
  REQUIRE(blocked);
  {
    pqxx::work work(env().worker);
    work.exec("SELECT agentgate.record_merge_failure($1::uuid, 'POLICY_BLOCKED')",
              pqxx::params{queued["job_id"].get<std::string>()});
    work.commit();
  }
  REQUIRE(text_field("SELECT payment_terms FROM public.invoices WHERE id = $1", id) == "net_15");
  REQUIRE(merged_events(created["pr_id"].get<std::string>()) == 0);
  (void)guard;
}

TEST_CASE("concurrent merges cannot both pass a one-row budget", "[integration]") {
  require_api();
  PolicyGuard guard;
  auto document = seeded_policy();
  document["limits"]["max_rows"] = 1;
  publish(document);
  const auto limited =
      issue(env().admin, "policy-limited", "proposer", scope_for({{"invoices", true}}));
  const auto first = fresh_invoice();
  const auto second = fresh_invoice();
  auto make = [&](long id, const std::string &title) {
    const auto body =
        proposal(title, nlohmann::json::array({change_of("invoices", "id", std::to_string(id), "1",
                                                         nlohmann::json{{"notes", title}})}));
    const auto created = call("POST", "/v1/prs", limited.token, body.dump(), next_key());
    INFO(created.body);
    REQUIRE(created.status == 201);
    auto parsed = nlohmann::json::parse(created.body);
    approve(parsed, env().invoice_reviewer);
    nlohmann::json review{{"revision", parsed["revision"]},
                          {"content_hash", parsed["content_hash"]}};
    const auto merged = call("POST", "/v1/prs/" + parsed["pr_id"].get<std::string>() + "/merge",
                             limited.token, review.dump(), next_key());
    INFO(merged.body);
    REQUIRE(merged.status == 202);
    parsed["job_id"] = nlohmann::json::parse(merged.body)["job_id"];
    return parsed;
  };
  const auto left = make(first, "limit left");
  const auto right = make(second, "limit right");
  pqxx::connection other(agentgate::test::worker_database_url());
  std::string left_state;
  std::string right_state;
  std::exception_ptr left_error;
  std::exception_ptr right_error;
  std::thread left_thread([&] {
    try {
      pqxx::work work(env().worker);
      work.exec("SELECT agentgate.merge_pr($1::uuid)",
                pqxx::params{left["job_id"].get<std::string>()});
      work.commit();
      left_state = "merged";
    } catch (...) {
      left_error = std::current_exception();
    }
  });
  std::thread right_thread([&] {
    try {
      pqxx::work work(other);
      work.exec("SELECT agentgate.merge_pr($1::uuid)",
                pqxx::params{right["job_id"].get<std::string>()});
      work.commit();
      right_state = "merged";
    } catch (...) {
      right_error = std::current_exception();
    }
  });
  left_thread.join();
  right_thread.join();
  auto settle = [&](const std::exception_ptr &error, const nlohmann::json &created,
                    std::string &state) {
    if (!error) {
      return;
    }
    try {
      std::rethrow_exception(error);
    } catch (const pqxx::sql_error &ex) {
      REQUIRE(std::string(ex.sqlstate()) == "AG011");
      pqxx::work work(env().worker);
      work.exec("SELECT agentgate.record_merge_failure($1::uuid, 'LIMIT_EXCEEDED')",
                pqxx::params{created["job_id"].get<std::string>()});
      work.commit();
      state = "approved";
    }
  };
  settle(left_error, left, left_state);
  settle(right_error, right, right_state);
  REQUIRE((left_state == "merged") != (right_state == "merged"));
  REQUIRE((left_state == "approved") != (right_state == "approved"));
  pqxx::work check(env().admin);
  const auto receipts =
      check
          .exec("SELECT count(*) FROM agentgate.merge_receipts WHERE pr_id = $1::uuid "
                "OR pr_id = $2::uuid",
                pqxx::params{left["pr_id"].get<std::string>(), right["pr_id"].get<std::string>()})
          .one_field()
          .as<int>();
  const auto reserved = check
                            .exec("SELECT COALESCE(sum(row_count), 0)::int "
                                  "FROM agentgate.rate_reservations WHERE principal_id = $1::uuid",
                                  pqxx::params{limited.principal_id})
                            .one_field()
                            .as<int>();
  const auto left_notes = check
                              .exec("SELECT COALESCE(notes, '') FROM public.invoices WHERE id = $1",
                                    pqxx::params{first})
                              .one_field()
                              .as<std::string>();
  const auto right_notes =
      check
          .exec("SELECT COALESCE(notes, '') FROM public.invoices WHERE id = $1",
                pqxx::params{second})
          .one_field()
          .as<std::string>();
  const auto returned =
      check
          .exec("SELECT state FROM agentgate.prs WHERE id = $1::uuid",
                pqxx::params{(left_state == "approved" ? left : right)["pr_id"].get<std::string>()})
          .one_field()
          .as<std::string>();
  check.commit();
  REQUIRE(receipts == 1);
  REQUIRE(reserved == 1);
  REQUIRE(returned == "approved");
  REQUIRE((left_notes == "limit left") != (right_notes == "limit right"));
  (void)guard;
}

TEST_CASE("another principal or an expired token is rejected", "[integration]") {
  require_api();
  const auto id = fresh_invoice();
  const auto read =
      call("POST", "/v1/reads", env().proposer.token,
           nlohmann::json{{"expires_in_seconds", 3600},
                          {"reads", nlohmann::json::array({nlohmann::json{
                                        {"schema", "public"},
                                        {"table", "invoices"},
                                        {"key", {{"id", std::to_string(id)}}},
                                        {"columns", nlohmann::json::array({"notes"})}}})}}
               .dump(),
           "");
  INFO(read.body);
  REQUIRE(read.status == 200);
  const auto token = nlohmann::json::parse(read.body)["token"].get<std::string>();
  const auto foreign =
      call("POST", "/v1/prs", env().other.token,
           proposal("foreign token",
                    nlohmann::json::array({change_of("invoices", "id", std::to_string(id), "1",
                                                     nlohmann::json{{"notes", "foreign"}})}),
                    nlohmann::json::array({token}))
               .dump(),
           next_key());
  expect_error(foreign, 404, "NOT_FOUND");
  {
    pqxx::work work(env().admin);
    work.exec("UPDATE agentgate.read_snapshots SET expires_at = now() - interval '1 minute' "
              "WHERE principal_id = $1::uuid",
              pqxx::params{env().proposer.principal_id});
    work.commit();
  }
  const auto expired =
      call("POST", "/v1/prs", env().proposer.token,
           proposal("expired token",
                    nlohmann::json::array({change_of("invoices", "id", std::to_string(id), "1",
                                                     nlohmann::json{{"notes", "expired"}})}),
                    nlohmann::json::array({token}))
               .dump(),
           next_key());
  expect_error(expired, 422, "VALIDATION_FAILED");
  REQUIRE(text_field("SELECT COALESCE(notes, '') FROM public.invoices WHERE id = $1", id) == "");
}
