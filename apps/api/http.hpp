#pragma once

#include <drogon/drogon.h>
#include <nlohmann/json.hpp>

#include <functional>
#include <optional>
#include <string>

namespace agentgate {

drogon::HttpResponsePtr error_response(int status, const nlohmann::json &body);
drogon::HttpResponsePtr json_response(int status, const nlohmann::json &body);
std::optional<drogon::HttpResponsePtr> reject_missing_bearer(const drogon::HttpRequestPtr &request);
std::optional<drogon::HttpResponsePtr>
reject_missing_idempotency(const drogon::HttpRequestPtr &request);
std::string bearer_token(const drogon::HttpRequestPtr &request);
std::string header_value(const drogon::HttpRequestPtr &request, const std::string &name);

void register_routes();

} // namespace agentgate
