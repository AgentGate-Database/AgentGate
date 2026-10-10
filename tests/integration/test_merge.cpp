#include "http_client.hpp"
#include "server.hpp"

#include "agentgate/crypto.hpp"
#include "agentgate/schema.hpp"

#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>
#include <pqxx/pqxx>

#include <chrono>
#include <csignal>
#include <functional>
#include <thread>
#include <fcntl.h>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
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
  return "m" + agentgate::random_token_secret(12);
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

struct Env {
  pqxx::connection admin;
  pqxx::connection worker;
  Cred proposer;
  Cred reviewer;

  Env()
      : admin(agentgate::test::admin_url()), worker(agentgate::test::worker_database_url()),
        proposer(issue(admin, "merge-proposer", "proposer", acme_scope())),
        reviewer(issue(admin, "merge-reviewer", "reviewer", nlohmann::json::object())) {
    pqxx::work work(admin);
    work.exec("INSERT INTO public.invoices (id, tenant_id, payment_terms) VALUES "
              "(482, 'acme', 'net_15') ON CONFLICT (id) DO NOTHING");
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

void clear_queued() {
  pqxx::work work(env().admin);
  work.exec("UPDATE agentgate.merge_jobs SET state = 'failed', lease_expires_at = NULL "
            "WHERE state = 'queued'");
  work.exec("UPDATE agentgate.prs SET state = 'failed' WHERE state = 'queued'");
  work.commit();
}

long fresh_invoice() {
  for (int attempt = 0; attempt < 5; ++attempt) {
    const auto id =
        1000000L + static_cast<long>(std::hash<std::string>{}(agentgate::random_token_secret(8)) %
                                     1000000000L);
    pqxx::work work(env().admin);
    const auto inserted =
        work.exec("INSERT INTO public.invoices (id, tenant_id, payment_terms, notes) "
                  "VALUES ($1, 'acme', 'net_15', 'merge fixture') ON CONFLICT (id) DO NOTHING",
                  pqxx::params{id})
            .affected_rows();
    work.commit();
    if (inserted == 1) {
      return id;
    }
  }
  FAIL("could not insert a fresh invoice");
  return 0;
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

nlohmann::json one_change(long id, const std::string &revision, const nlohmann::json &set,
                          const std::string &title) {
  return nlohmann::json{
      {"title", title},
      {"reason", "merge the invoice"},
      {"expires_in_seconds", 3600},
      {"changes", nlohmann::json::array({nlohmann::json{{"operation", "update"},
                                                        {"schema", "public"},
                                                        {"table", "invoices"},
                                                        {"key", {{"id", std::to_string(id)}}},
                                                        {"expected_revision", revision},
                                                        {"set", set}}})}};
}

struct Queued {
  long invoice_id{0};
  std::string before_revision;
  std::string pr_id;
  std::string content_hash;
  std::string job_id;
  int revision{0};
};

Queued queue_update(long id, const nlohmann::json &set, const std::string &title) {
  const auto before = revision_of(id);
  const auto created = call("POST", "/v1/prs", env().proposer.token,
                            one_change(id, before, set, title).dump(), next_key());
  INFO(created.body);
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  const auto pr_id = created_json["pr_id"].get<std::string>();
  const auto hash = created_json["content_hash"].get<std::string>();
  nlohmann::json review{{"revision", created_json["revision"]}, {"content_hash", hash}};
  const auto approved = call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token,
                             review.dump(), next_key());
  INFO(approved.body);
  REQUIRE(approved.status == 200);
  const auto merged =
      call("POST", "/v1/prs/" + pr_id + "/merge", env().proposer.token, review.dump(), next_key());
  INFO(merged.body);
  REQUIRE(merged.status == 202);
  const auto body = nlohmann::json::parse(merged.body);
  expect_schema("merge_response.json", body);
  REQUIRE(body["state"] == "queued");
  REQUIRE(body["receipt"].is_null());
  REQUIRE(terms_of(id) == "net_15");
  Queued queued;
  queued.invoice_id = id;
  queued.before_revision = before;
  queued.pr_id = pr_id;
  queued.content_hash = hash;
  queued.job_id = body["job_id"].get<std::string>();
  queued.revision = body["revision"].get<int>();
  return queued;
}

std::string claim_job(pqxx::work &work, const std::string &worker_id) {
  const auto field =
      work.exec("SELECT agentgate.claim_merge_job($1::text, 30)", pqxx::params{worker_id})
          .one_field();
  if (field.is_null()) {
    return {};
  }
  return nlohmann::json::parse(field.c_str()).at("job_id").get<std::string>();
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

struct ScopedWorker {
  pid_t pid{-1};

  ScopedWorker() {
    const auto url = agentgate::test::worker_database_url();
    pid = ::fork();
    REQUIRE(pid >= 0);
    if (pid == 0) {
      ::setenv("AGENTGATE_WORKER_DATABASE_URL", url.c_str(), 1);
      ::setenv("AGENTGATE_EXPIRE_INTERVAL_SECONDS", "1", 1);
      const int log_fd =
          ::open("/tmp/agentgate-worker-test.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (log_fd >= 0) {
        ::dup2(log_fd, STDOUT_FILENO);
        ::dup2(log_fd, STDERR_FILENO);
        ::close(log_fd);
      }
      ::execl(AGENTGATE_WORKER_BIN, AGENTGATE_WORKER_BIN, static_cast<char *>(nullptr));
      _exit(127);
    }
  }

  ~ScopedWorker() {
    if (pid > 0) {
      ::kill(pid, SIGTERM);
      ::waitpid(pid, nullptr, 0);
    }
  }
};

} // namespace

TEST_CASE("the worker commits one receipt and the business row changes once", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto queued = queue_update(id, nlohmann::json{{"payment_terms", "net_45"}}, "happy merge");
  const auto shown = call("GET", "/v1/prs/" + queued.pr_id, env().proposer.token, "", "");
  INFO(shown.body);
  REQUIRE(shown.status == 200);
  const auto shown_json = nlohmann::json::parse(shown.body);
  expect_schema("pr_response.json", shown_json);
  REQUIRE(shown_json["state"] == "queued");
  REQUIRE(shown_json["execution_status"]["state"] == "queued");
  REQUIRE(shown_json["execution_status"]["receipt"].is_null());

  ScopedWorker worker;
  nlohmann::json done;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto fetched = call("GET", "/v1/prs/" + queued.pr_id, env().proposer.token, "", "");
    done = nlohmann::json::parse(fetched.body);
    if (done["state"] == "merged") {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
  INFO(done.dump());
  REQUIRE(done["state"] == "merged");
  expect_schema("pr_response.json", done);
  REQUIRE(done["execution_status"]["state"] == "completed");
  REQUIRE(done["execution_status"]["receipt"]["rows"].size() == 1);
  REQUIRE(terms_of(id) == "net_45");
  REQUIRE(revision_of(id) == std::to_string(std::stol(queued.before_revision) + 1));
  REQUIRE(merged_events(queued.pr_id) == 1);
  pqxx::work check(env().admin);
  const auto receipts =
      check
          .exec("SELECT count(*) FROM agentgate.merge_receipts WHERE pr_id = $1::uuid",
                pqxx::params{queued.pr_id})
          .one_field()
          .as<int>();
  const auto outbox = check
                          .exec("SELECT count(*) FROM agentgate.outbox_events "
                                "WHERE pr_id = $1::uuid AND event_type = 'pr.merged'",
                                pqxx::params{queued.pr_id})
                          .one_field()
                          .as<int>();
  check.commit();
  REQUIRE(receipts == 1);
  REQUIRE(outbox == 1);
}

TEST_CASE("two workers produce one receipt and a second merge returns it", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto queued =
      queue_update(id, nlohmann::json{{"payment_terms", "net_60"}}, "single receipt");
  pqxx::connection other(agentgate::test::worker_database_url());
  std::string first_receipt;
  {
    pqxx::work left(env().worker);
    pqxx::work right(other);
    const auto claimed = claim_job(left, "worker-left");
    const auto skipped = claim_job(right, "worker-right");
    REQUIRE(claimed == queued.job_id);
    REQUIRE(skipped.empty());
    const auto receipt = nlohmann::json::parse(
        left.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{queued.job_id})
            .one_field()
            .c_str());
    first_receipt = receipt["receipt_id"].get<std::string>();
    left.commit();
    right.commit();
  }
  REQUIRE(terms_of(id) == "net_60");
  const auto bumped = revision_of(id);
  {
    pqxx::work again(env().worker);
    const auto receipt = nlohmann::json::parse(
        again.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{queued.job_id})
            .one_field()
            .c_str());
    again.commit();
    REQUIRE(receipt["receipt_id"] == first_receipt);
  }
  REQUIRE(revision_of(id) == bumped);
  REQUIRE(merged_events(queued.pr_id) == 1);

  const auto replay_body =
      nlohmann::json{{"revision", queued.revision}, {"content_hash", queued.content_hash}}.dump();
  const auto again_http = call("POST", "/v1/prs/" + queued.pr_id + "/merge", env().proposer.token,
                               replay_body, next_key());
  INFO(again_http.body);
  REQUIRE(again_http.status == 200);
  const auto again_json = nlohmann::json::parse(again_http.body);
  expect_schema("merge_response.json", again_json);
  REQUIRE(again_json["state"] == "merged");
  REQUIRE(again_json["receipt"]["receipt_id"] == first_receipt);
}

TEST_CASE("one stale row rolls back every write in the proposal", "[integration]") {
  require_api();
  clear_queued();
  const auto first = fresh_invoice();
  const auto second = fresh_invoice();
  const auto before_second = revision_of(second);
  const auto raw = nlohmann::json{
      {"title", "two row merge"},
      {"reason", "update both invoices"},
      {"expires_in_seconds", 3600},
      {"changes", nlohmann::json::array({nlohmann::json{{"operation", "update"},
                                                        {"schema", "public"},
                                                        {"table", "invoices"},
                                                        {"key", {{"id", std::to_string(first)}}},
                                                        {"expected_revision", revision_of(first)},
                                                        {"set", {{"payment_terms", "net_45"}}}},
                                         nlohmann::json{{"operation", "update"},
                                                        {"schema", "public"},
                                                        {"table", "invoices"},
                                                        {"key", {{"id", std::to_string(second)}}},
                                                        {"expected_revision", before_second},
                                                        {"set", {{"notes", "second row"}}}}})}};
  const auto created = call("POST", "/v1/prs", env().proposer.token, raw.dump(), next_key());
  INFO(created.body);
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  const auto pr_id = created_json["pr_id"].get<std::string>();
  nlohmann::json review{{"revision", created_json["revision"]},
                        {"content_hash", created_json["content_hash"]}};
  REQUIRE(
      call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token, review.dump(), next_key())
          .status == 200);
  const auto queued =
      call("POST", "/v1/prs/" + pr_id + "/merge", env().proposer.token, review.dump(), next_key());
  REQUIRE(queued.status == 202);
  const auto job_id = nlohmann::json::parse(queued.body)["job_id"].get<std::string>();

  {
    pqxx::work drift(env().admin);
    drift.exec("UPDATE public.invoices SET payment_terms = 'net_90' WHERE id = $1",
               pqxx::params{first});
    drift.commit();
  }

  std::string sqlstate;
  try {
    pqxx::work work(env().worker);
    REQUIRE(claim_job(work, "drift-worker") == job_id);
    work.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{job_id});
    work.commit();
    FAIL("stale merge committed");
  } catch (const pqxx::sql_error &ex) {
    sqlstate = ex.sqlstate();
  }
  REQUIRE(sqlstate == "AG008");
  {
    pqxx::work failure(env().worker);
    failure.exec("SELECT agentgate.record_merge_failure($1::uuid, 'DRIFT_CONFLICT')",
                 pqxx::params{job_id});
    failure.commit();
  }
  REQUIRE(terms_of(first) == "net_90");
  REQUIRE(revision_of(second) == before_second);
  pqxx::work notes(env().admin);
  const auto note =
      notes.exec("SELECT notes FROM public.invoices WHERE id = $1", pqxx::params{second})
          .one_field()
          .as<std::string>();
  notes.commit();
  REQUIRE(note == "merge fixture");
  REQUIRE(merged_events(pr_id) == 0);
  const auto status = call("GET", "/v1/prs/" + pr_id, env().proposer.token, "", "");
  REQUIRE(nlohmann::json::parse(status.body)["state"] == "conflicted");
}

TEST_CASE("a schema change after approval writes nothing", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto before = revision_of(id);
  const auto queued = queue_update(id, nlohmann::json{{"payment_terms", "net_45"}}, "schema block");
  struct DropColumn {
    ~DropColumn() {
      try {
        pqxx::work work(env().admin);
        work.exec("ALTER TABLE public.invoices DROP COLUMN IF EXISTS extra_m3");
        work.commit();
      } catch (const std::exception &) {
      }
    }
  } guard;
  {
    pqxx::work alter(env().admin);
    alter.exec("ALTER TABLE public.invoices ADD COLUMN extra_m3 text");
    alter.commit();
  }
  std::string sqlstate;
  try {
    pqxx::work work(env().worker);
    REQUIRE(claim_job(work, "schema-worker") == queued.job_id);
    work.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{queued.job_id});
    work.commit();
    FAIL("schema change merged");
  } catch (const pqxx::sql_error &ex) {
    sqlstate = ex.sqlstate();
  }
  REQUIRE(sqlstate == "AG009");
  {
    pqxx::work failure(env().worker);
    failure.exec("SELECT agentgate.record_merge_failure($1::uuid, 'SCHEMA_CHANGED')",
                 pqxx::params{queued.job_id});
    failure.commit();
  }
  REQUIRE(terms_of(id) == "net_15");
  REQUIRE(revision_of(id) == before);
  REQUIRE(merged_events(queued.pr_id) == 0);
  (void)guard;
}

TEST_CASE("a proposer cannot approve and a revoked credential cannot merge", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto created = call(
      "POST", "/v1/prs", env().proposer.token,
      one_change(id, revision_of(id), nlohmann::json{{"payment_terms", "net_45"}}, "self approve")
          .dump(),
      next_key());
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  const auto pr_id = created_json["pr_id"].get<std::string>();
  nlohmann::json review{{"revision", created_json["revision"]},
                        {"content_hash", created_json["content_hash"]}};
  const auto denied = call("POST", "/v1/prs/" + pr_id + "/approve", env().proposer.token,
                           review.dump(), next_key());
  expect_error(denied, 403, "FORBIDDEN");

  REQUIRE(
      call("POST", "/v1/prs/" + pr_id + "/approve", env().reviewer.token, review.dump(), next_key())
          .status == 200);
  auto revoked = issue(env().admin, "revoked-merger", "proposer", acme_scope());
  {
    pqxx::work work(env().admin);
    work.exec("UPDATE agentgate.credentials SET revoked_at = now() WHERE id = $1::uuid",
              pqxx::params{revoked.credential_id});
    work.commit();
  }
  const auto blocked =
      call("POST", "/v1/prs/" + pr_id + "/merge", revoked.token, review.dump(), next_key());
  expect_error(blocked, 401, "UNAUTHORIZED");
  REQUIRE(terms_of(id) == "net_15");
}

TEST_CASE("revising a queued proposal cancels the job", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto queued = queue_update(id, nlohmann::json{{"payment_terms", "net_45"}}, "cancel queue");
  const auto revised =
      call("POST", "/v1/prs/" + queued.pr_id + "/revisions", env().proposer.token,
           one_change(id, revision_of(id), nlohmann::json{{"payment_terms", "net_60"}}, "revised")
               .dump(),
           next_key());
  INFO(revised.body);
  REQUIRE(revised.status == 201);
  REQUIRE(nlohmann::json::parse(revised.body)["state"] == "pending_review");
  pqxx::work work(env().admin);
  const auto job_state = work.exec("SELECT state FROM agentgate.merge_jobs WHERE id = $1::uuid",
                                   pqxx::params{queued.job_id})
                             .one_field()
                             .as<std::string>();
  work.commit();
  REQUIRE(job_state == "failed");
  REQUIRE(terms_of(id) == "net_15");
  pqxx::work claim(env().worker);
  REQUIRE(claim_job(claim, "cancel-worker").empty());
  claim.commit();
}
