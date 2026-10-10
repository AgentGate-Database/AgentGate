#include "agentgate/config.hpp"
#include "agentgate/crypto.hpp"
#include "agentgate/db/pool.hpp"
#include "agentgate/db/transaction.hpp"
#include "agentgate/error.hpp"

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

// Expire, then claim and merge one job on the same connection. A raised
// application error rolls the claim back; the failure is recorded afterwards.
bool process_once(agentgate::ConnectionPool &pool, const std::string &worker_id) {
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
    std::ofstream ready("/tmp/agentgate-worker-ready");
    ready << "ok\n";
    ready.close();
    std::cerr << "agentgate-worker connected\n";

    while (!g_stop.load()) {
      bool worked = false;
      try {
        worked = process_once(pool, worker_id);
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
    return 0;
  } catch (const std::exception &ex) {
    std::cerr << "agentgate-worker: " << agentgate::redact_secrets(ex.what()) << '\n';
    return 1;
  }
}
