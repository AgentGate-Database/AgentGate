#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>

namespace agentgate {

struct Timeouts {
  std::chrono::milliseconds statement{5000};
  std::chrono::milliseconds lock{2000};
  std::chrono::milliseconds idle_in_transaction{5000};
};

struct Config {
  std::string http_host{"127.0.0.1"};
  std::uint16_t http_port{8080};
  int http_threads{2};
  std::string database_url;
  std::size_t pool_size{8};
  std::size_t work_threads{4};
  std::size_t work_queue{64};
  std::chrono::milliseconds acquire_timeout{2000};
  Timeouts timeouts{};
  std::string contracts_dir{"packages/contracts"};
  int max_pr_rows{100};
  int max_payload_bytes{1048576};
  int max_expiry_seconds{604800};
  int min_expiry_seconds{1};
  std::chrono::seconds expire_interval{2};
  bool webhook_allow_private{false};
};

// Loads process configuration. database_url_variable selects which env var is
// required (API vs worker). Missing required values throw AgentGateError.
[[nodiscard]] Config load_config(const char *database_url_variable = "AGENTGATE_DATABASE_URL");

} // namespace agentgate
