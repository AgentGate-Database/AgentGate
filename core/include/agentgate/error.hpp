#pragma once

#include <nlohmann/json.hpp>

#include <stdexcept>
#include <string>
#include <string_view>

namespace agentgate {

enum class ErrorCode {
  Unauthorized,
  Forbidden,
  UnsupportedTable,
  UnsupportedOperation,
  PolicyBlocked,
  RevisionMismatch,
  PrExpired,
  DriftConflict,
  SchemaChanged,
  IdempotencyConflict,
  LimitExceeded,
  ConstraintViolation,
  ValidationFailed,
  NotFound,
  Internal,
};

struct AgentGateError : std::runtime_error {
  ErrorCode code;
  int http_status;
  nlohmann::json details;

  AgentGateError(ErrorCode code, int http_status, std::string message,
                 nlohmann::json details = nlohmann::json::object());

  [[nodiscard]] nlohmann::json to_json() const;
};

[[nodiscard]] std::string_view to_string(ErrorCode code);
[[nodiscard]] int http_status_for(ErrorCode code);
[[nodiscard]] ErrorCode error_code_from_name(std::string_view name);

// Maps a Postgres SQLSTATE plus server message onto an AgentGateError.
// Unknown failures become INTERNAL and do not echo SQL text.
[[nodiscard]] AgentGateError error_from_database(std::string_view sqlstate,
                                                 std::string_view message);

[[nodiscard]] std::string redact_secrets(std::string_view text);

} // namespace agentgate
