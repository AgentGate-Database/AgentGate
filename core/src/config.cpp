#include "agentgate/config.hpp"

#include "agentgate/error.hpp"

#include <cstdlib>
#include <string>

namespace agentgate {
namespace {

std::string env_or_empty(const char *name) {
  const char *value = std::getenv(name);
  if (value == nullptr) {
    return {};
  }
  return value;
}

int env_int(const char *name, int fallback) {
  const auto raw = env_or_empty(name);
  if (raw.empty()) {
    return fallback;
  }
  try {
    return std::stoi(raw);
  } catch (const std::exception &) {
    throw AgentGateError{ErrorCode::ValidationFailed, 500,
                         std::string(name) + " must be an integer"};
  }
}

} // namespace

Config load_config(const char *database_url_variable) {
  Config config;
  config.database_url = env_or_empty(database_url_variable);
  if (config.database_url.empty()) {
    throw AgentGateError{ErrorCode::Internal, 500,
                         std::string(database_url_variable) + " is required"};
  }

  const auto host = env_or_empty("AGENTGATE_HTTP_HOST");
  if (!host.empty()) {
    config.http_host = host;
  }
  const int port = env_int("AGENTGATE_HTTP_PORT", static_cast<int>(config.http_port));
  if (port < 1 || port > 65535) {
    throw AgentGateError{ErrorCode::ValidationFailed, 500, "AGENTGATE_HTTP_PORT is out of range"};
  }
  config.http_port = static_cast<std::uint16_t>(port);
  config.http_threads = env_int("AGENTGATE_HTTP_THREADS", config.http_threads);
  config.pool_size =
      static_cast<std::size_t>(env_int("AGENTGATE_POOL_SIZE", static_cast<int>(config.pool_size)));
  config.work_threads = static_cast<std::size_t>(
      env_int("AGENTGATE_WORK_THREADS", static_cast<int>(config.work_threads)));
  config.work_queue = static_cast<std::size_t>(
      env_int("AGENTGATE_WORK_QUEUE", static_cast<int>(config.work_queue)));
  config.acquire_timeout = std::chrono::milliseconds{
      env_int("AGENTGATE_ACQUIRE_TIMEOUT_MS", static_cast<int>(config.acquire_timeout.count()))};
  config.timeouts.statement = std::chrono::milliseconds{env_int(
      "AGENTGATE_STATEMENT_TIMEOUT_MS", static_cast<int>(config.timeouts.statement.count()))};
  config.timeouts.lock = std::chrono::milliseconds{
      env_int("AGENTGATE_LOCK_TIMEOUT_MS", static_cast<int>(config.timeouts.lock.count()))};
  config.timeouts.idle_in_transaction = std::chrono::milliseconds{
      env_int("AGENTGATE_IDLE_IN_TX_TIMEOUT_MS",
              static_cast<int>(config.timeouts.idle_in_transaction.count()))};

  const auto contracts = env_or_empty("AGENTGATE_CONTRACTS_DIR");
  if (!contracts.empty()) {
    config.contracts_dir = contracts;
  }
  config.max_pr_rows = env_int("AGENTGATE_MAX_PR_ROWS", config.max_pr_rows);
  config.max_payload_bytes = env_int("AGENTGATE_MAX_PAYLOAD_BYTES", config.max_payload_bytes);
  config.max_expiry_seconds = env_int("AGENTGATE_MAX_EXPIRY_SECONDS", config.max_expiry_seconds);
  config.min_expiry_seconds = env_int("AGENTGATE_MIN_EXPIRY_SECONDS", config.min_expiry_seconds);
  config.expire_interval = std::chrono::seconds{env_int(
      "AGENTGATE_EXPIRE_INTERVAL_SECONDS", static_cast<int>(config.expire_interval.count()))};
  config.webhook_allow_private = env_or_empty("AGENTGATE_WEBHOOK_ALLOW_PRIVATE") == "1";
  if (config.pool_size == 0 || config.work_threads == 0) {
    throw AgentGateError{ErrorCode::ValidationFailed, 500,
                         "pool and work thread counts must be positive"};
  }
  return config;
}

} // namespace agentgate
