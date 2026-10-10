#include "http.hpp"

#include "agentgate/crypto.hpp"
#include "agentgate/error.hpp"
#include "agentgate/schema.hpp"
#include "agentgate/services/database.hpp"

#include <algorithm>
#include <iostream>
#include <utility>

namespace agentgate {
namespace {

drogon::HttpResponsePtr from_error(const AgentGateError &error) {
  return error_response(error.http_status, error.to_json());
}

std::string digest_hex(std::string_view body) {
  const auto bytes = sha256_bytes(body);
  return to_hex(bytes.data(), bytes.size());
}

template <typename Fn>
void on_worker(std::function<void(const drogon::HttpResponsePtr &)> callback, Fn fn) {
  try {
    app_context().work->submit([callback = std::move(callback), fn = std::move(fn)]() mutable {
      try {
        callback(fn());
      } catch (const AgentGateError &error) {
        callback(from_error(error));
      } catch (const std::exception &ex) {
        std::cerr << "agentgate-api: " << redact_secrets(ex.what()) << '\n';
        const AgentGateError error{ErrorCode::Internal, 500, "internal error"};
        callback(from_error(error));
      }
    });
  } catch (const AgentGateError &error) {
    callback(from_error(error));
  }
}

std::string authenticated_principal(const std::string &token) {
  const auto parsed = parse_credential(token);
  if (!parsed) {
    throw AgentGateError{ErrorCode::Unauthorized, 401, "unauthorized"};
  }
  return app_context().database->authenticate(parsed->credential_id, parsed->secret).id;
}

nlohmann::json parse_body(std::string_view raw, const nlohmann::json &schema) {
  const auto &config = app_context().config;
  if (raw.size() > static_cast<std::size_t>(std::max(config.max_payload_bytes, 0))) {
    throw AgentGateError{ErrorCode::LimitExceeded, 429, "payload is too large"};
  }
  nlohmann::json body;
  try {
    body = nlohmann::json::parse(raw);
  } catch (const nlohmann::json::exception &) {
    throw AgentGateError{ErrorCode::ValidationFailed, 422, "request body must be JSON"};
  }
  validate_json(schema, body);
  return body;
}

void health(const drogon::HttpRequestPtr &,
            std::function<void(const drogon::HttpResponsePtr &)> &&cb) {
  cb(json_response(200, nlohmann::json{{"status", "ok"}, {"service", "agentgate-api"}}));
}

void ready(const drogon::HttpRequestPtr &,
           std::function<void(const drogon::HttpResponsePtr &)> &&cb) {
  on_worker(std::move(cb), [] {
    app_context().database->ping();
    return json_response(200, nlohmann::json{{"status", "ready"}});
  });
}

void post_reads(const drogon::HttpRequestPtr &request,
                std::function<void(const drogon::HttpResponsePtr &)> &&callback) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  const auto raw = std::string(request->body());
  on_worker(std::move(callback), [token, raw] {
    const auto body = parse_body(raw, app_context().read_schema);
    const auto principal = authenticated_principal(token);
    return json_response(200, app_context().database->create_read(principal, body));
  });
}

void post_prs(const drogon::HttpRequestPtr &request,
              std::function<void(const drogon::HttpResponsePtr &)> &&callback) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  if (auto rejected = reject_missing_idempotency(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  const auto key = header_value(request, "idempotency-key");
  const auto raw = std::string(request->body());
  const auto digest = digest_hex(raw);
  on_worker(std::move(callback), [token, key, raw, digest] {
    const auto body = parse_body(raw, app_context().propose_schema);
    const auto principal = authenticated_principal(token);
    const auto result = app_context().database->propose(principal, body, key, digest);
    return json_response(result.http_status, result.body);
  });
}

void post_revision(const drogon::HttpRequestPtr &request,
                   std::function<void(const drogon::HttpResponsePtr &)> &&callback,
                   const std::string &pr_id) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  if (auto rejected = reject_missing_idempotency(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  const auto key = header_value(request, "idempotency-key");
  const auto raw = std::string(request->body());
  const auto digest = digest_hex(raw);
  on_worker(std::move(callback), [token, key, raw, digest, pr_id] {
    const auto body = parse_body(raw, app_context().propose_schema);
    const auto principal = authenticated_principal(token);
    const auto result =
        app_context().database->create_revision(principal, pr_id, body, key, digest);
    return json_response(result.http_status, result.body);
  });
}

void post_decision(const drogon::HttpRequestPtr &request,
                   std::function<void(const drogon::HttpResponsePtr &)> &&callback,
                   const std::string &pr_id, bool approve_decision) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  if (auto rejected = reject_missing_idempotency(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  const auto key = header_value(request, "idempotency-key");
  const auto raw = std::string(request->body());
  const auto digest = digest_hex(raw);
  on_worker(std::move(callback), [token, key, raw, digest, pr_id, approve_decision] {
    const auto &schema =
        approve_decision ? app_context().review_schema : app_context().reject_schema;
    const auto body = parse_body(raw, schema);
    const auto principal = authenticated_principal(token);
    const auto result = approve_decision
                            ? app_context().database->approve(principal, pr_id, body, key, digest)
                            : app_context().database->reject(principal, pr_id, body, key, digest);
    return json_response(result.http_status, result.body);
  });
}

void post_merge(const drogon::HttpRequestPtr &request,
                std::function<void(const drogon::HttpResponsePtr &)> &&callback,
                const std::string &pr_id) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  if (auto rejected = reject_missing_idempotency(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  const auto key = header_value(request, "idempotency-key");
  const auto raw = std::string(request->body());
  const auto digest = digest_hex(raw);
  on_worker(std::move(callback), [token, key, raw, digest, pr_id] {
    const auto body = parse_body(raw, app_context().merge_schema);
    const auto principal = authenticated_principal(token);
    const auto result = app_context().database->enqueue_merge(principal, pr_id, body, key, digest);
    return json_response(result.http_status, result.body);
  });
}

void get_one(const drogon::HttpRequestPtr &request,
             std::function<void(const drogon::HttpResponsePtr &)> &&callback,
             const std::string &pr_id, bool diff) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  on_worker(std::move(callback), [token, pr_id, diff] {
    const auto principal = authenticated_principal(token);
    const auto body = diff ? app_context().database->get_diff(principal, pr_id)
                           : app_context().database->get_pr(principal, pr_id);
    return json_response(200, body);
  });
}

void list_prs(const drogon::HttpRequestPtr &request,
              std::function<void(const drogon::HttpResponsePtr &)> &&callback) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  const auto status = request->getParameter("status");
  const auto schema = request->getParameter("schema");
  const auto table = request->getParameter("table");
  const auto proposer = request->getParameter("proposer");
  const auto after = request->getParameter("created_after");
  const auto before = request->getParameter("created_before");
  const auto cursor = request->getParameter("cursor");
  int limit = 50;
  const auto limit_text = request->getParameter("limit");
  if (!limit_text.empty()) {
    try {
      limit = std::stoi(limit_text);
    } catch (const std::exception &) {
      const AgentGateError error{ErrorCode::ValidationFailed, 422, "limit must be an integer"};
      callback(from_error(error));
      return;
    }
  }
  on_worker(std::move(callback), [=] {
    const auto principal = authenticated_principal(token);
    const auto body = app_context().database->list_prs(principal, status, schema, table, proposer,
                                                       after, before, cursor, limit);
    return json_response(200, body);
  });
}

void list_events(const drogon::HttpRequestPtr &request,
                 std::function<void(const drogon::HttpResponsePtr &)> &&callback,
                 const std::string &pr_id) {
  if (auto rejected = reject_missing_bearer(request)) {
    callback(*rejected);
    return;
  }
  const auto token = bearer_token(request);
  on_worker(std::move(callback), [token, pr_id] {
    const auto principal = authenticated_principal(token);
    return json_response(200, app_context().database->list_events(principal, pr_id));
  });
}

} // namespace

void register_routes() {
  using drogon::Get;
  using drogon::Post;
  drogon::app().registerHandler("/healthz", &health, {Get});
  drogon::app().registerHandler("/readyz", &ready, {Get});
  drogon::app().registerHandler("/v1/reads", &post_reads, {Post});
  drogon::app().registerHandler("/v1/prs", &post_prs, {Post});
  drogon::app().registerHandler("/v1/prs", &list_prs, {Get});
  drogon::app().registerHandler("/v1/prs/{1}/revisions", &post_revision, {Post});
  drogon::app().registerHandler(
      "/v1/prs/{1}/approve",
      [](const drogon::HttpRequestPtr &request,
         std::function<void(const drogon::HttpResponsePtr &)> &&callback,
         const std::string &pr_id) { post_decision(request, std::move(callback), pr_id, true); },
      {Post});
  drogon::app().registerHandler("/v1/prs/{1}/merge", &post_merge, {Post});
  drogon::app().registerHandler(
      "/v1/prs/{1}/reject",
      [](const drogon::HttpRequestPtr &request,
         std::function<void(const drogon::HttpResponsePtr &)> &&callback,
         const std::string &pr_id) { post_decision(request, std::move(callback), pr_id, false); },
      {Post});
  drogon::app().registerHandler(
      "/v1/prs/{1}/diff",
      [](const drogon::HttpRequestPtr &request,
         std::function<void(const drogon::HttpResponsePtr &)> &&callback,
         const std::string &pr_id) { get_one(request, std::move(callback), pr_id, true); },
      {Get});
  drogon::app().registerHandler("/v1/prs/{1}/events", &list_events, {Get});
  drogon::app().registerHandler(
      "/v1/prs/{1}",
      [](const drogon::HttpRequestPtr &request,
         std::function<void(const drogon::HttpResponsePtr &)> &&callback,
         const std::string &pr_id) { get_one(request, std::move(callback), pr_id, false); },
      {Get});
}

} // namespace agentgate
