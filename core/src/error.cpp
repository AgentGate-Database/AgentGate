#include "agentgate/error.hpp"

#include <cctype>

namespace agentgate {
namespace {

std::string_view trim_view(std::string_view text) {
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front())) != 0) {
    text.remove_prefix(1);
  }
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back())) != 0) {
    text.remove_suffix(1);
  }
  return text;
}

} // namespace

AgentGateError::AgentGateError(ErrorCode error_code, int status, std::string message,
                               nlohmann::json error_details)
    : std::runtime_error(std::move(message)), code(error_code), http_status(status),
      details(std::move(error_details)) {}

nlohmann::json AgentGateError::to_json() const {
  return nlohmann::json{{"error",
                         {{"code", std::string(to_string(code))},
                          {"message", what()},
                          {"details", details.is_null() ? nlohmann::json::object() : details}}}};
}

std::string_view to_string(ErrorCode code) {
  switch (code) {
  case ErrorCode::Unauthorized:
    return "UNAUTHORIZED";
  case ErrorCode::Forbidden:
    return "FORBIDDEN";
  case ErrorCode::UnsupportedTable:
    return "UNSUPPORTED_TABLE";
  case ErrorCode::UnsupportedOperation:
    return "UNSUPPORTED_OPERATION";
  case ErrorCode::PolicyBlocked:
    return "POLICY_BLOCKED";
  case ErrorCode::RevisionMismatch:
    return "REVISION_MISMATCH";
  case ErrorCode::PrExpired:
    return "PR_EXPIRED";
  case ErrorCode::DriftConflict:
    return "DRIFT_CONFLICT";
  case ErrorCode::SchemaChanged:
    return "SCHEMA_CHANGED";
  case ErrorCode::IdempotencyConflict:
    return "IDEMPOTENCY_CONFLICT";
  case ErrorCode::LimitExceeded:
    return "LIMIT_EXCEEDED";
  case ErrorCode::ConstraintViolation:
    return "CONSTRAINT_VIOLATION";
  case ErrorCode::ValidationFailed:
    return "VALIDATION_FAILED";
  case ErrorCode::NotFound:
    return "NOT_FOUND";
  case ErrorCode::Internal:
    return "INTERNAL";
  }
  return "INTERNAL";
}

int http_status_for(ErrorCode code) {
  switch (code) {
  case ErrorCode::Unauthorized:
    return 401;
  case ErrorCode::Forbidden:
    return 403;
  case ErrorCode::NotFound:
    return 404;
  case ErrorCode::RevisionMismatch:
  case ErrorCode::PrExpired:
  case ErrorCode::DriftConflict:
  case ErrorCode::SchemaChanged:
  case ErrorCode::IdempotencyConflict:
    return 409;
  case ErrorCode::LimitExceeded:
    return 429;
  case ErrorCode::UnsupportedTable:
  case ErrorCode::UnsupportedOperation:
  case ErrorCode::PolicyBlocked:
  case ErrorCode::ConstraintViolation:
  case ErrorCode::ValidationFailed:
    return 422;
  case ErrorCode::Internal:
    return 500;
  }
  return 500;
}

ErrorCode error_code_from_name(std::string_view name) {
  if (name == "UNAUTHORIZED")
    return ErrorCode::Unauthorized;
  if (name == "FORBIDDEN")
    return ErrorCode::Forbidden;
  if (name == "UNSUPPORTED_TABLE")
    return ErrorCode::UnsupportedTable;
  if (name == "UNSUPPORTED_OPERATION")
    return ErrorCode::UnsupportedOperation;
  if (name == "POLICY_BLOCKED")
    return ErrorCode::PolicyBlocked;
  if (name == "REVISION_MISMATCH")
    return ErrorCode::RevisionMismatch;
  if (name == "PR_EXPIRED")
    return ErrorCode::PrExpired;
  if (name == "DRIFT_CONFLICT")
    return ErrorCode::DriftConflict;
  if (name == "SCHEMA_CHANGED")
    return ErrorCode::SchemaChanged;
  if (name == "IDEMPOTENCY_CONFLICT")
    return ErrorCode::IdempotencyConflict;
  if (name == "LIMIT_EXCEEDED")
    return ErrorCode::LimitExceeded;
  if (name == "CONSTRAINT_VIOLATION")
    return ErrorCode::ConstraintViolation;
  if (name == "VALIDATION_FAILED")
    return ErrorCode::ValidationFailed;
  if (name == "NOT_FOUND")
    return ErrorCode::NotFound;
  return ErrorCode::Internal;
}

ErrorCode code_from_sqlstate(std::string_view sqlstate) {
  if (sqlstate == "AG001")
    return ErrorCode::Unauthorized;
  if (sqlstate == "AG002")
    return ErrorCode::Forbidden;
  if (sqlstate == "AG003")
    return ErrorCode::UnsupportedTable;
  if (sqlstate == "AG004")
    return ErrorCode::UnsupportedOperation;
  if (sqlstate == "AG005")
    return ErrorCode::PolicyBlocked;
  if (sqlstate == "AG006")
    return ErrorCode::RevisionMismatch;
  if (sqlstate == "AG007")
    return ErrorCode::PrExpired;
  if (sqlstate == "AG008")
    return ErrorCode::DriftConflict;
  if (sqlstate == "AG009")
    return ErrorCode::SchemaChanged;
  if (sqlstate == "AG010")
    return ErrorCode::IdempotencyConflict;
  if (sqlstate == "AG011")
    return ErrorCode::LimitExceeded;
  if (sqlstate == "AG012")
    return ErrorCode::ConstraintViolation;
  if (sqlstate == "AG013")
    return ErrorCode::ValidationFailed;
  if (sqlstate == "AG014")
    return ErrorCode::NotFound;
  if (sqlstate == "42501")
    return ErrorCode::Forbidden;
  if (sqlstate.size() >= 2 && sqlstate.substr(0, 2) == "22")
    return ErrorCode::ValidationFailed;
  if (sqlstate == "23505" || sqlstate == "23503" || sqlstate == "23514" || sqlstate == "23502") {
    return ErrorCode::ConstraintViolation;
  }
  return ErrorCode::Internal;
}

AgentGateError error_from_database(std::string_view sqlstate, std::string_view message) {
  const auto trimmed = trim_view(message);
  const auto start = trimmed.find('{');
  const auto end = trimmed.rfind('}');
  if (start != std::string_view::npos && end != std::string_view::npos && end > start) {
    try {
      const auto parsed = nlohmann::json::parse(trimmed.substr(start, end - start + 1));
      if (parsed.is_object() && parsed.contains("code") && parsed.contains("message")) {
        const auto code = error_code_from_name(parsed.at("code").get<std::string>());
        auto details = parsed.contains("details") ? parsed.at("details") : nlohmann::json::object();
        if (details.is_null()) {
          details = nlohmann::json::object();
        }
        return AgentGateError{code, http_status_for(code), parsed.at("message").get<std::string>(),
                              details};
      }
    } catch (const nlohmann::json::exception &) {
    }
  }

  const auto code = code_from_sqlstate(sqlstate);
  if (code == ErrorCode::Forbidden && sqlstate == "42501") {
    return AgentGateError{code, 403, "insufficient privilege"};
  }
  if (code == ErrorCode::ValidationFailed && sqlstate.size() >= 2 &&
      sqlstate.substr(0, 2) == "22") {
    return AgentGateError{code, 422, "invalid input"};
  }
  if (code == ErrorCode::ConstraintViolation) {
    return AgentGateError{code, 422, "constraint violation"};
  }
  if (code != ErrorCode::Internal) {
    return AgentGateError{code, http_status_for(code), "request failed"};
  }
  return AgentGateError{ErrorCode::Internal, 500, "internal error"};
}

std::string redact_secrets(std::string_view text) {
  std::string out(text);
  const std::string marker = "postgresql://";
  auto pos = out.find(marker);
  while (pos != std::string::npos) {
    const auto end = out.find_first_of(" \n\t'\"", pos);
    out.replace(pos, end == std::string::npos ? std::string::npos : end - pos,
                "postgresql://<redacted>");
    pos = out.find(marker, pos + 1);
  }
  const std::string bearer = "agk_";
  pos = out.find(bearer);
  while (pos != std::string::npos) {
    const auto end = out.find_first_of(" \n\t'\"", pos);
    out.replace(pos, end == std::string::npos ? std::string::npos : end - pos, "agk_<redacted>");
    pos = out.find(bearer, pos + 1);
  }
  return out;
}

} // namespace agentgate
