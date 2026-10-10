#include "http.hpp"

#include "agentgate/error.hpp"

#include <nlohmann/json.hpp>

namespace agentgate {
namespace {

drogon::HttpStatusCode to_status(int code) {
  switch (code) {
  case 200:
    return drogon::k200OK;
  case 201:
    return drogon::k201Created;
  case 401:
    return drogon::k401Unauthorized;
  case 403:
    return drogon::k403Forbidden;
  case 404:
    return drogon::k404NotFound;
  case 409:
    return drogon::k409Conflict;
  case 422:
    return drogon::k422UnprocessableEntity;
  case 429:
    return drogon::k429TooManyRequests;
  case 503:
    return drogon::k503ServiceUnavailable;
  default:
    return drogon::k500InternalServerError;
  }
}

} // namespace

drogon::HttpResponsePtr json_response(int status, const nlohmann::json &body) {
  auto response = drogon::HttpResponse::newHttpResponse();
  response->setStatusCode(to_status(status));
  response->setContentTypeCode(drogon::CT_APPLICATION_JSON);
  response->setBody(body.dump());
  return response;
}

drogon::HttpResponsePtr error_response(int status, const nlohmann::json &body) {
  return json_response(status, body);
}

std::string header_value(const drogon::HttpRequestPtr &request, const std::string &name) {
  auto value = request->getHeader(name);
  if (!value.empty()) {
    return value;
  }
  std::string lower = name;
  for (char &ch : lower) {
    if (ch >= 'A' && ch <= 'Z') {
      ch = static_cast<char>(ch - 'A' + 'a');
    }
  }
  return request->getHeader(lower);
}

std::string bearer_token(const drogon::HttpRequestPtr &request) {
  const auto header = header_value(request, "authorization");
  constexpr std::string_view prefix = "Bearer ";
  if (header.size() <= prefix.size() || header.compare(0, prefix.size(), prefix) != 0) {
    return {};
  }
  return header.substr(prefix.size());
}

std::optional<drogon::HttpResponsePtr>
reject_missing_bearer(const drogon::HttpRequestPtr &request) {
  if (bearer_token(request).empty()) {
    const AgentGateError error{ErrorCode::Unauthorized, 401, "unauthorized"};
    return error_response(error.http_status, error.to_json());
  }
  return std::nullopt;
}

std::optional<drogon::HttpResponsePtr>
reject_missing_idempotency(const drogon::HttpRequestPtr &request) {
  if (header_value(request, "idempotency-key").empty()) {
    const AgentGateError error{ErrorCode::ValidationFailed, 422, "Idempotency-Key is required"};
    return error_response(error.http_status, error.to_json());
  }
  return std::nullopt;
}

} // namespace agentgate
