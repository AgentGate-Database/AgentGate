#include "http_client.hpp"
#include "server.hpp"

#include "agentgate/crypto.hpp"
#include "agentgate/schema.hpp"

#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>
#include <pqxx/pqxx>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/wait.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
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
  return "r" + agentgate::random_token_secret(12);
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
  cred.principal_id = row[1].as<std::string>();
  cred.token = "agk_" + row[0].as<std::string>() + "_" + secret;
  return cred;
}

struct Env {
  pqxx::connection admin;
  pqxx::connection worker;
  Cred proposer;
  Cred reviewer;
  Cred admin_user;

  Env()
      : admin(agentgate::test::admin_url()), worker(agentgate::test::worker_database_url()),
        proposer(issue(admin, "revert-proposer", "proposer", acme_scope())),
        reviewer(issue(admin, "revert-reviewer", "reviewer", nlohmann::json::object())),
        admin_user(issue(admin, "revert-admin", "admin", nlohmann::json::object())) {
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

long fresh_invoice() {
  for (int attempt = 0; attempt < 5; ++attempt) {
    const auto id =
        2000000L + static_cast<long>(std::hash<std::string>{}(agentgate::random_token_secret(8)) %
                                     1000000000L);
    pqxx::work work(env().admin);
    const auto inserted =
        work.exec("INSERT INTO public.invoices (id, tenant_id, payment_terms, notes) "
                  "VALUES ($1, 'acme', 'net_15', 'revert fixture') ON CONFLICT (id) DO NOTHING",
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

std::string notes_of(long id) {
  pqxx::work work(env().admin);
  const auto value = work.exec("SELECT notes FROM public.invoices WHERE id = $1", pqxx::params{id})
                         .one_field()
                         .as<std::string>();
  work.commit();
  return value;
}

int reverse_count(const std::string &pr_id) {
  pqxx::work work(env().admin);
  const auto count = work.exec("SELECT count(*) FROM agentgate.prs WHERE source_pr_id = $1::uuid",
                               pqxx::params{pr_id})
                         .one_field()
                         .as<int>();
  work.commit();
  return count;
}

struct Submitted {
  std::string pr_id;
  std::string content_hash;
  int revision{0};
  std::string job_id;
};

Submitted propose_update(long id, const nlohmann::json &set, const std::string &title) {
  const auto raw = nlohmann::json{
      {"title", title},
      {"reason", "revert the invoice"},
      {"expires_in_seconds", 3600},
      {"changes", nlohmann::json::array({nlohmann::json{{"operation", "update"},
                                                        {"schema", "public"},
                                                        {"table", "invoices"},
                                                        {"key", {{"id", std::to_string(id)}}},
                                                        {"expected_revision", revision_of(id)},
                                                        {"set", set}}})}};
  const auto created = call("POST", "/v1/prs", env().proposer.token, raw.dump(), next_key());
  INFO(created.body);
  REQUIRE(created.status == 201);
  const auto body = nlohmann::json::parse(created.body);
  expect_schema("pr_response.json", body);
  REQUIRE(body["source_pr_id"].is_null());
  Submitted submitted;
  submitted.pr_id = body["pr_id"].get<std::string>();
  submitted.content_hash = body["content_hash"].get<std::string>();
  submitted.revision = body["revision"].get<int>();
  return submitted;
}

void approve(const Submitted &submitted) {
  const auto raw =
      nlohmann::json{{"revision", submitted.revision}, {"content_hash", submitted.content_hash}}
          .dump();
  const auto response = call("POST", "/v1/prs/" + submitted.pr_id + "/approve",
                             env().reviewer.token, raw, next_key());
  INFO(response.body);
  REQUIRE(response.status == 200);
}

Submitted queue_update(long id, const nlohmann::json &set, const std::string &title) {
  auto submitted = propose_update(id, set, title);
  approve(submitted);
  const auto raw =
      nlohmann::json{{"revision", submitted.revision}, {"content_hash", submitted.content_hash}}
          .dump();
  const auto merged =
      call("POST", "/v1/prs/" + submitted.pr_id + "/merge", env().proposer.token, raw, next_key());
  INFO(merged.body);
  REQUIRE(merged.status == 202);
  submitted.job_id = nlohmann::json::parse(merged.body)["job_id"].get<std::string>();
  return submitted;
}

void clear_queued() {
  pqxx::work work(env().admin);
  work.exec("UPDATE agentgate.merge_jobs SET state = 'failed', lease_expires_at = NULL "
            "WHERE state = 'queued'");
  work.exec("UPDATE agentgate.prs SET state = 'failed' WHERE state = 'queued'");
  work.commit();
}

void commit_job(const std::string &job_id) {
  pqxx::work work(env().worker);
  const auto field =
      work.exec("SELECT agentgate.claim_merge_job($1::text, 30)", pqxx::params{"revert-worker"})
          .one_field();
  REQUIRE_FALSE(field.is_null());
  REQUIRE(nlohmann::json::parse(field.c_str()).at("job_id") == job_id);
  work.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{job_id});
  work.commit();
}

nlohmann::json revert_body() {
  return nlohmann::json{{"title", "Revert invoice payment terms"},
                        {"reason", "Restore the terms captured by the merge receipt."},
                        {"expires_in_seconds", 3600}};
}

struct Captured {
  std::string path;
  std::string body;
  std::string signature;
  std::string timestamp;
  std::string event_id;
};

std::string header_value(const std::string &headers, const std::string &name) {
  std::string lowered = headers;
  for (char &ch : lowered) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  std::string needle = name;
  for (char &ch : needle) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  needle += ":";
  const auto at = lowered.find(needle);
  if (at == std::string::npos) {
    return {};
  }
  auto start = at + needle.size();
  while (start < headers.size() && (headers[start] == ' ' || headers[start] == '\t')) {
    ++start;
  }
  const auto end = headers.find("\r\n", start);
  return headers.substr(start, end == std::string::npos ? std::string::npos : end - start);
}

class HookListener {
public:
  explicit HookListener(int status) : status_(status) {
    fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    REQUIRE(fd_ >= 0);
    int yes = 1;
    ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    REQUIRE(::bind(fd_, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    REQUIRE(::listen(fd_, 16) == 0);
    socklen_t length = sizeof(address);
    REQUIRE(::getsockname(fd_, reinterpret_cast<sockaddr *>(&address), &length) == 0);
    port_ = ntohs(address.sin_port);
    thread_ = std::thread([this] { loop(); });
  }

  ~HookListener() {
    stop_.store(true);
    if (fd_ >= 0) {
      ::shutdown(fd_, SHUT_RDWR);
      ::close(fd_);
      fd_ = -1;
    }
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  int port() const { return port_; }

  bool wait_for(std::size_t count, std::chrono::seconds timeout) {
    std::unique_lock lock(mu_);
    return cv_.wait_for(lock, timeout, [&] { return seen_.size() >= count; });
  }

  std::vector<Captured> requests() {
    std::lock_guard lock(mu_);
    return seen_;
  }

private:
  void loop() {
    const int listen_fd = fd_;
    while (!stop_.load()) {
      fd_set fds;
      FD_ZERO(&fds);
      FD_SET(listen_fd, &fds);
      timeval tv{0, 200000};
      if (::select(listen_fd + 1, &fds, nullptr, nullptr, &tv) <= 0) {
        continue;
      }
      const int client = ::accept(listen_fd, nullptr, nullptr);
      if (client < 0) {
        continue;
      }
      std::string data;
      char buffer[4096];
      while (data.find("\r\n\r\n") == std::string::npos) {
        const auto count = ::recv(client, buffer, sizeof(buffer), 0);
        if (count <= 0) {
          break;
        }
        data.append(buffer, static_cast<std::size_t>(count));
      }
      const auto split = data.find("\r\n\r\n");
      if (split != std::string::npos) {
        const auto headers = data.substr(0, split);
        auto body = data.substr(split + 4);
        const auto length_text = header_value(headers, "content-length");
        std::size_t length = 0;
        if (!length_text.empty()) {
          length = static_cast<std::size_t>(std::stoul(length_text));
        }
        while (body.size() < length) {
          const auto count = ::recv(client, buffer, sizeof(buffer), 0);
          if (count <= 0) {
            break;
          }
          body.append(buffer, static_cast<std::size_t>(count));
        }
        Captured captured;
        const auto line_end = headers.find("\r\n");
        const auto first = headers.substr(0, line_end);
        const auto path_start = first.find(' ');
        const auto path_end = first.find(' ', path_start == std::string::npos ? 0 : path_start + 1);
        if (path_start != std::string::npos && path_end != std::string::npos) {
          captured.path = first.substr(path_start + 1, path_end - path_start - 1);
        }
        captured.body = body.substr(0, length);
        captured.signature = header_value(headers, "agentgate-signature");
        captured.timestamp = header_value(headers, "agentgate-timestamp");
        captured.event_id = header_value(headers, "agentgate-event-id");
        {
          std::lock_guard lock(mu_);
          seen_.push_back(std::move(captured));
        }
        cv_.notify_all();
      }
      const auto location = "Location: http://127.0.0.1:" + std::to_string(port_) + "/followed\r\n";
      const auto response = status_ == 302 ? "HTTP/1.1 302 Found\r\n" + location +
                                                 "Content-Length: 0\r\nConnection: close\r\n\r\n"
                                           : "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                                             "Connection: close\r\n\r\n";
      ::send(client, response.data(), response.size(), 0);
      ::close(client);
    }
  }

  int fd_{-1};
  int port_{0};
  int status_{200};
  std::atomic<bool> stop_{false};
  std::thread thread_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::vector<Captured> seen_;
};

struct EndpointGuard {
  std::string id;

  ~EndpointGuard() {
    if (id.empty()) {
      return;
    }
    try {
      pqxx::work work(env().admin);
      work.exec("DELETE FROM agentgate.webhook_subscriptions WHERE endpoint_id = $1::uuid",
                pqxx::params{id});
      work.exec("UPDATE agentgate.webhook_deliveries SET state = 'failed', lease_expires_at = NULL "
                "WHERE endpoint_id = $1::uuid AND state = 'pending'",
                pqxx::params{id});
      work.commit();
    } catch (const std::exception &) {
    }
  }
};

std::string insert_endpoint(const std::string &url, const std::string &secret_hex) {
  pqxx::work work(env().admin);
  const auto id = work.exec("INSERT INTO agentgate.webhook_endpoints (url, secret, created_by) "
                            "VALUES ($1, decode($2, 'hex'), $3::uuid) RETURNING id::text",
                            pqxx::params{url, secret_hex, env().proposer.principal_id})
                      .one_field()
                      .as<std::string>();
  work.exec("INSERT INTO agentgate.webhook_subscriptions (endpoint_id, event_type) "
            "VALUES ($1::uuid, 'pr.merged')",
            pqxx::params{id});
  work.commit();
  return id;
}

struct DeliveryWorker {
  pid_t pid{-1};

  DeliveryWorker() {
    const auto url = agentgate::test::worker_database_url();
    pid = ::fork();
    REQUIRE(pid >= 0);
    if (pid == 0) {
      ::setenv("AGENTGATE_WORKER_DATABASE_URL", url.c_str(), 1);
      ::setenv("AGENTGATE_EXPIRE_INTERVAL_SECONDS", "1", 1);
      ::setenv("AGENTGATE_WEBHOOK_ALLOW_PRIVATE", "1", 1);
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

  ~DeliveryWorker() {
    if (pid > 0) {
      ::kill(pid, SIGTERM);
      ::waitpid(pid, nullptr, 0);
    }
  }
};

} // namespace

TEST_CASE("a merged invoice reverts to its receipt and a new revision", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto queued =
      queue_update(id, nlohmann::json{{"payment_terms", "net_45"}}, "before revert");
  commit_job(queued.job_id);
  REQUIRE(terms_of(id) == "net_45");
  const auto landed = revision_of(id);

  const auto response = call("POST", "/v1/prs/" + queued.pr_id + "/revert", env().proposer.token,
                             revert_body().dump(), next_key());
  INFO(response.body);
  REQUIRE(response.status == 201);
  const auto created = nlohmann::json::parse(response.body);
  expect_schema("pr_response.json", created);
  REQUIRE(created["source_pr_id"] == queued.pr_id);
  REQUIRE(created["state"] == "pending_review");
  REQUIRE(terms_of(id) == "net_45");

  const auto hidden = call("POST", "/v1/prs/" + queued.pr_id + "/revert", env().reviewer.token,
                           revert_body().dump(), next_key());
  expect_error(hidden, 404, "NOT_FOUND");

  Submitted reverse;
  reverse.pr_id = created["pr_id"].get<std::string>();
  reverse.revision = created["revision"].get<int>();
  reverse.content_hash = created["content_hash"].get<std::string>();
  approve(reverse);
  REQUIRE(terms_of(id) == "net_45");
  const auto review =
      nlohmann::json{{"revision", reverse.revision}, {"content_hash", reverse.content_hash}}.dump();
  const auto merged =
      call("POST", "/v1/prs/" + reverse.pr_id + "/merge", env().proposer.token, review, next_key());
  INFO(merged.body);
  REQUIRE(merged.status == 202);
  commit_job(nlohmann::json::parse(merged.body)["job_id"].get<std::string>());
  REQUIRE(terms_of(id) == "net_15");
  REQUIRE(revision_of(id) == std::to_string(std::stol(landed) + 1));
}

TEST_CASE("an edit after merge blocks revert and writes no reverse proposal", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto queued = queue_update(id, nlohmann::json{{"payment_terms", "net_45"}}, "drift revert");
  commit_job(queued.job_id);
  {
    pqxx::work drift(env().admin);
    drift.exec("UPDATE public.invoices SET notes = 'edited after merge' WHERE id = $1",
               pqxx::params{id});
    drift.commit();
  }
  const auto response = call("POST", "/v1/prs/" + queued.pr_id + "/revert", env().proposer.token,
                             revert_body().dump(), next_key());
  expect_error(response, 409, "DRIFT_CONFLICT");
  REQUIRE(terms_of(id) == "net_45");
  REQUIRE(notes_of(id) == "edited after merge");
  REQUIRE(reverse_count(queued.pr_id) == 0);
}

TEST_CASE("a drift failure writes pr.conflicted and no pr.merged outbox row", "[integration]") {
  require_api();
  clear_queued();
  const auto id = fresh_invoice();
  const auto queued = queue_update(id, nlohmann::json{{"payment_terms", "net_60"}}, "drift merge");
  {
    pqxx::work drift(env().admin);
    drift.exec("UPDATE public.invoices SET payment_terms = 'net_90' WHERE id = $1",
               pqxx::params{id});
    drift.commit();
  }
  std::string sqlstate;
  try {
    pqxx::work work(env().worker);
    const auto field =
        work.exec("SELECT agentgate.claim_merge_job($1::text, 30)", pqxx::params{"drift-revert"})
            .one_field();
    REQUIRE(nlohmann::json::parse(field.c_str()).at("job_id") == queued.job_id);
    work.exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{queued.job_id});
    work.commit();
    FAIL("drifted merge committed");
  } catch (const pqxx::sql_error &ex) {
    sqlstate = ex.sqlstate();
  }
  REQUIRE(sqlstate == "AG008");
  {
    pqxx::work failure(env().worker);
    failure.exec("SELECT agentgate.record_merge_failure($1::uuid, 'DRIFT_CONFLICT')",
                 pqxx::params{queued.job_id});
    failure.commit();
  }
  REQUIRE(terms_of(id) == "net_90");
  pqxx::work check(env().admin);
  const auto merged = check
                          .exec("SELECT count(*) FROM agentgate.outbox_events "
                                "WHERE pr_id = $1::uuid AND event_type = 'pr.merged'",
                                pqxx::params{queued.pr_id})
                          .one_field()
                          .as<int>();
  const auto conflicted = check
                              .exec("SELECT count(*) FROM agentgate.outbox_events "
                                    "WHERE pr_id = $1::uuid AND event_type = 'pr.conflicted'",
                                    pqxx::params{queued.pr_id})
                              .one_field()
                              .as<int>();
  check.commit();
  REQUIRE(merged == 0);
  REQUIRE(conflicted == 1);
}

TEST_CASE("a listener receives one signed body and a redirect is not followed", "[integration]") {
  require_api();
  clear_queued();
  {
    pqxx::work quiet(env().admin);
    quiet.exec("UPDATE agentgate.webhook_deliveries SET state = 'failed', lease_expires_at = NULL "
               "WHERE state = 'pending'");
    quiet.commit();
  }
  HookListener listener(200);
  EndpointGuard guard;
  const std::string secret_hex(64, 'a');
  guard.id =
      insert_endpoint("http://127.0.0.1:" + std::to_string(listener.port()) + "/hook", secret_hex);

  const auto id = fresh_invoice();
  const auto queued =
      queue_update(id, nlohmann::json{{"payment_terms", "net_45"}}, "webhook merge");
  commit_job(queued.job_id);

  DeliveryWorker worker;
  REQUIRE(listener.wait_for(1, std::chrono::seconds(15)));
  const auto delivered_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  std::string delivery_state;
  while (std::chrono::steady_clock::now() < delivered_deadline) {
    pqxx::work check(env().admin);
    delivery_state = check
                         .exec("SELECT state FROM agentgate.webhook_deliveries "
                               "WHERE endpoint_id = $1::uuid",
                               pqxx::params{guard.id})
                         .one_field()
                         .as<std::string>();
    check.commit();
    if (delivery_state == "delivered") {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  REQUIRE(delivery_state == "delivered");
  const auto first = listener.requests().at(0);
  REQUIRE(first.path == "/hook");
  const auto payload = nlohmann::json::parse(first.body);
  REQUIRE(payload["type"] == "pr.merged");
  REQUIRE(payload["id"] == first.event_id);
  REQUIRE_FALSE(payload.contains("before"));
  REQUIRE_FALSE(payload.contains("after"));
  REQUIRE(first.body.find("payment_terms") == std::string::npos);
  unsigned char secret[32];
  REQUIRE(agentgate::decode_hex(secret_hex, secret, sizeof(secret)));
  const auto expected = agentgate::hmac_sha256_hex(
      std::string_view(reinterpret_cast<const char *>(secret), sizeof(secret)),
      first.timestamp + "." + first.body);
  REQUIRE(first.signature == "v1=" + expected);

  {
    pqxx::work again(env().admin);
    again.exec("UPDATE agentgate.webhook_deliveries SET state = 'pending', attempt = 0, "
               "lease_expires_at = NULL, next_attempt_at = now() "
               "WHERE endpoint_id = $1::uuid",
               pqxx::params{guard.id});
    again.commit();
  }
  REQUIRE(listener.wait_for(2, std::chrono::seconds(15)));
  const auto second = listener.requests().at(1);
  REQUIRE(second.event_id == first.event_id);
  REQUIRE(second.body == first.body);

  HookListener redirect(302);
  EndpointGuard redirect_guard;
  redirect_guard.id =
      insert_endpoint("http://127.0.0.1:" + std::to_string(redirect.port()) + "/hook", secret_hex);
  const auto other = fresh_invoice();
  const auto other_queued =
      queue_update(other, nlohmann::json{{"payment_terms", "net_60"}}, "redirect merge");
  commit_job(other_queued.job_id);
  REQUIRE(redirect.wait_for(1, std::chrono::seconds(15)));
  REQUIRE(redirect.requests().at(0).path == "/hook");
  std::this_thread::sleep_for(std::chrono::seconds(1));
  for (const auto &item : redirect.requests()) {
    REQUIRE(item.path != "/followed");
  }
}

TEST_CASE("private webhook destinations are rejected and listed without the secret",
          "[integration]") {
  require_api();
  const auto loopback = call(
      "POST", "/v1/webhooks", env().admin_user.token,
      nlohmann::json{{"url", "http://127.0.0.1:9/hook"}, {"events", {"pr.merged"}}}.dump(), "");
  expect_error(loopback, 422, "VALIDATION_FAILED");
  const auto metadata = call(
      "POST", "/v1/webhooks", env().admin_user.token,
      nlohmann::json{{"url", "http://169.254.169.254/latest"}, {"events", {"pr.merged"}}}.dump(),
      "");
  expect_error(metadata, 422, "VALIDATION_FAILED");
  const auto userinfo =
      call("POST", "/v1/webhooks", env().admin_user.token,
           nlohmann::json{{"url", "https://user:pass@example.com/hook"}, {"events", {"pr.merged"}}}
               .dump(),
           "");
  expect_error(userinfo, 422, "VALIDATION_FAILED");
  const auto forbidden =
      call("POST", "/v1/webhooks", env().proposer.token,
           nlohmann::json{{"url", "https://example.com/hooks/agentgate"}, {"events", {"pr.merged"}}}
               .dump(),
           "");
  expect_error(forbidden, 403, "FORBIDDEN");

  const auto created =
      call("POST", "/v1/webhooks", env().admin_user.token,
           nlohmann::json{{"url", "https://example.com/hooks/agentgate"}, {"events", {"pr.merged"}}}
               .dump(),
           "");
  INFO(created.body);
  REQUIRE(created.status == 201);
  const auto created_json = nlohmann::json::parse(created.body);
  expect_schema("webhook_created.json", created_json);
  REQUIRE(created_json["secret"].get<std::string>().starts_with("whsec_"));

  const auto listed = call("GET", "/v1/webhooks", env().admin_user.token, "", "");
  INFO(listed.body);
  REQUIRE(listed.status == 200);
  const auto listed_json = nlohmann::json::parse(listed.body);
  expect_schema("webhook_list.json", listed_json);
  REQUIRE(listed.body.find("secret") == std::string::npos);
  REQUIRE(listed.body.find("whsec_") == std::string::npos);

  pqxx::work cleanup(env().admin);
  cleanup.exec("DELETE FROM agentgate.webhook_subscriptions WHERE endpoint_id = $1::uuid",
               pqxx::params{created_json["id"].get<std::string>()});
  cleanup.commit();
}
