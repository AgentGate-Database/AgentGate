#include "agentgate/config.hpp"
#include "agentgate/crypto.hpp"
#include "agentgate/db/pool.hpp"
#include "agentgate/db/transaction.hpp"
#include "agentgate/error.hpp"
#include "agentgate/webhook.hpp"

#include <curl/curl.h>
#include <nlohmann/json.hpp>
#include <pqxx/pqxx>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <thread>

namespace {
std::atomic<bool> g_stop{false};

void on_signal(int) {
  g_stop.store(true);
}

bool terminal_failure(agentgate::ErrorCode code) {
  switch (code) {
  case agentgate::ErrorCode::DriftConflict:
  case agentgate::ErrorCode::SchemaChanged:
  case agentgate::ErrorCode::PolicyBlocked:
  case agentgate::ErrorCode::PrExpired:
  case agentgate::ErrorCode::Forbidden:
  case agentgate::ErrorCode::ValidationFailed:
  case agentgate::ErrorCode::ConstraintViolation:
  case agentgate::ErrorCode::NotFound:
  case agentgate::ErrorCode::UnsupportedTable:
  case agentgate::ErrorCode::LimitExceeded:
    return true;
  default:
    return false;
  }
}

void record_failure(agentgate::ConnectionPool &pool, const std::string &job_id,
                    std::string_view code) {
  auto lease = pool.acquire();
  agentgate::Transaction tx(lease.get(), pool.timeouts());
  tx.work().exec("SELECT agentgate.record_merge_failure($1::uuid, $2::text)",
                 pqxx::params{job_id, std::string{code}});
  tx.commit();
}

std::size_t discard_body(char *, std::size_t size, std::size_t count, void *) {
  return size * count;
}

struct DeliveryResult {
  long status{0};
  std::string error;
  bool terminal{false};
};

DeliveryResult post_webhook(const nlohmann::json &claim, bool allow_private) {
  DeliveryResult result;
  const auto url = claim.at("url").get<std::string>();
  const auto body = claim.at("body").get<std::string>();
  const auto timestamp = claim.at("timestamp").get<std::string>();
  const auto event_id = claim.at("event_id").get<std::string>();
  const auto secret_hex = claim.at("secret_hex").get<std::string>();
  unsigned char secret[32];
  if (!agentgate::decode_hex(secret_hex, secret, sizeof(secret))) {
    result.terminal = true;
    result.error = "webhook secret is invalid";
    return result;
  }
  try {
    agentgate::validate_webhook_url(url, allow_private);
  } catch (const agentgate::AgentGateError &) {
    result.terminal = true;
    result.error = "destination is not allowed";
    return result;
  }
  const auto signature = agentgate::hmac_sha256_hex(
      std::string_view(reinterpret_cast<const char *>(secret), sizeof(secret)),
      timestamp + "." + body);
  CURL *curl = curl_easy_init();
  if (curl == nullptr) {
    result.error = "curl init failed";
    return result;
  }
  const auto event_header = "AgentGate-Event-Id: " + event_id;
  const auto time_header = "AgentGate-Timestamp: " + timestamp;
  const auto sig_header = "AgentGate-Signature: v1=" + signature;
  curl_slist *headers = nullptr;
  headers = curl_slist_append(headers, "Content-Type: application/json");
  headers = curl_slist_append(headers, event_header.c_str());
  headers = curl_slist_append(headers, time_header.c_str());
  headers = curl_slist_append(headers, sig_header.c_str());
  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_POST, 1L);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
  curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 0L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5L);
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "HTTP,HTTPS");
  curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "");
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, discard_body);
  const auto rc = curl_easy_perform(curl);
  if (rc != CURLE_OK) {
    result.error = curl_easy_strerror(rc);
  } else {
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &result.status);
  }
  curl_slist_free_all(headers);
  curl_easy_cleanup(curl);
  return result;
}

void record_delivery(agentgate::ConnectionPool &pool, const std::string &delivery_id,
                     const DeliveryResult &result) {
  auto lease = pool.acquire();
  agentgate::Transaction tx(lease.get(), pool.timeouts());
  tx.work().exec(
      "SELECT agentgate.record_webhook_result($1::uuid, $2::int, $3::text, $4::boolean)",
      pqxx::params{delivery_id, static_cast<int>(result.status), result.error, result.terminal});
  tx.commit();
}

bool deliver_once(agentgate::ConnectionPool &pool, const std::string &worker_id,
                  bool allow_private) {
  std::optional<nlohmann::json> claim;
  {
    auto lease = pool.acquire();
    agentgate::Transaction tx(lease.get(), pool.timeouts());
    const auto field =
        tx.work()
            .exec("SELECT agentgate.claim_webhook_delivery($1::text, 30)", pqxx::params{worker_id})
            .one_field();
    if (field.is_null()) {
      tx.commit();
      return false;
    }
    claim = nlohmann::json::parse(field.c_str());
    tx.commit();
  }
  const auto delivery_id = claim->at("delivery_id").get<std::string>();
  try {
    record_delivery(pool, delivery_id, post_webhook(*claim, allow_private));
  } catch (const std::exception &ex) {
    DeliveryResult failed;
    failed.error = "delivery failed";
    std::cerr << "agentgate-worker: webhook delivery failed: "
              << agentgate::redact_secrets(ex.what()) << '\n';
    record_delivery(pool, delivery_id, failed);
  }
  return true;
}

// Expire, then claim and merge one job on the same connection. A raised
// application error rolls the claim back; the failure is recorded afterwards.
bool merge_once(agentgate::ConnectionPool &pool, const std::string &worker_id) {
  std::optional<std::string> job_id;
  std::optional<agentgate::AgentGateError> failure;
  bool claimed = false;
  {
    auto lease = pool.acquire();
    agentgate::Transaction tx(lease.get(), pool.timeouts());
    tx.work().exec("SELECT agentgate.expire_prs()");
    const auto field = tx.work()
                           .exec("SELECT agentgate.claim_merge_job($1::text, $2::int)",
                                 pqxx::params{worker_id, 30})
                           .one_field();
    if (field.is_null()) {
      tx.commit();
      return false;
    }
    claimed = true;
    const auto claim = nlohmann::json::parse(field.c_str());
    job_id = claim.at("job_id").get<std::string>();
    try {
      tx.work().exec("SELECT agentgate.merge_pr($1::uuid)", pqxx::params{*job_id});
      tx.commit();
      return true;
    } catch (const pqxx::failure &ex) {
      failure = agentgate::error_from_database(ex.sqlstate(), ex.what());
    }
  }
  if (failure.has_value() && job_id.has_value() && terminal_failure(failure->code)) {
    record_failure(pool, *job_id, agentgate::to_string(failure->code));
  } else if (failure.has_value()) {
    std::cerr << "agentgate-worker: merge left queued after " << agentgate::to_string(failure->code)
              << '\n';
  }
  return claimed;
}

bool process_once(agentgate::ConnectionPool &pool, const std::string &worker_id,
                  bool allow_private) {
  const bool merged = merge_once(pool, worker_id);
  const bool delivered = deliver_once(pool, worker_id, allow_private);
  return merged || delivered;
}

} // namespace

int main() {
  try {
    const char *worker_url = std::getenv("AGENTGATE_WORKER_DATABASE_URL");
    auto config = agentgate::load_config(worker_url != nullptr && worker_url[0] != '\0'
                                             ? "AGENTGATE_WORKER_DATABASE_URL"
                                             : "AGENTGATE_DATABASE_URL");
    agentgate::ConnectionPool pool(config.database_url, config.pool_size, config.acquire_timeout,
                                   config.timeouts);
    const auto worker_id = agentgate::random_token_secret(16);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    {
      auto lease = pool.acquire();
      agentgate::Transaction tx(lease.get(), pool.timeouts());
      tx.work().exec("SELECT 1");
      tx.commit();
    }
    curl_global_init(CURL_GLOBAL_DEFAULT);
    std::ofstream ready("/tmp/agentgate-worker-ready");
    ready << "ok\n";
    ready.close();
    std::cerr << "agentgate-worker connected\n";

    while (!g_stop.load()) {
      bool worked = false;
      try {
        worked = process_once(pool, worker_id, config.webhook_allow_private);
      } catch (const std::exception &ex) {
        std::cerr << "agentgate-worker: " << agentgate::redact_secrets(ex.what()) << '\n';
      }
      if (worked) {
        continue;
      }
      const auto ticks = static_cast<int>(config.expire_interval.count()) * 5;
      for (int tick = 0; tick < ticks && !g_stop.load(); ++tick) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
      }
    }
    pool.shutdown();
    curl_global_cleanup();
    return 0;
  } catch (const std::exception &ex) {
    std::cerr << "agentgate-worker: " << agentgate::redact_secrets(ex.what()) << '\n';
    return 1;
  }
}
