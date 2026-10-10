#pragma once

#include "agentgate/config.hpp"
#include "agentgate/db/pool.hpp"
#include "agentgate/error.hpp"
#include "agentgate/db/work_pool.hpp"

#include <pqxx/pqxx>

#include <nlohmann/json.hpp>

#include <memory>
#include <string>

namespace agentgate {

struct DbResult {
  int http_status{200};
  nlohmann::json body{nlohmann::json::object()};
};

struct Principal {
  std::string id;
  std::string kind;
  std::string name;
  nlohmann::json scopes;
};

class Database {
public:
  Database(ConnectionPool &pool, Config config);

  void ping() const;
  [[nodiscard]] Principal authenticate(const std::string &credential_id,
                                       const std::string &secret) const;

  [[nodiscard]] nlohmann::json create_read(const std::string &principal_id,
                                           const nlohmann::json &body) const;
  [[nodiscard]] DbResult propose(const std::string &principal_id, const nlohmann::json &body,
                                 const std::string &idempotency_key,
                                 const std::string &request_digest) const;
  [[nodiscard]] DbResult create_revision(const std::string &principal_id, const std::string &pr_id,
                                         const nlohmann::json &body,
                                         const std::string &idempotency_key,
                                         const std::string &request_digest) const;
  [[nodiscard]] DbResult approve(const std::string &principal_id, const std::string &pr_id,
                                 const nlohmann::json &body, const std::string &idempotency_key,
                                 const std::string &request_digest) const;
  [[nodiscard]] DbResult reject(const std::string &principal_id, const std::string &pr_id,
                                const nlohmann::json &body, const std::string &idempotency_key,
                                const std::string &request_digest) const;
  [[nodiscard]] DbResult enqueue_merge(const std::string &principal_id, const std::string &pr_id,
                                       const nlohmann::json &body,
                                       const std::string &idempotency_key,
                                       const std::string &request_digest) const;
  [[nodiscard]] DbResult revert(const std::string &principal_id, const std::string &pr_id,
                                const nlohmann::json &body, const std::string &idempotency_key,
                                const std::string &request_digest) const;
  [[nodiscard]] nlohmann::json register_webhook(const std::string &principal_id,
                                                const nlohmann::json &body) const;
  [[nodiscard]] nlohmann::json list_webhooks(const std::string &principal_id) const;
  [[nodiscard]] nlohmann::json get_pr(const std::string &principal_id,
                                      const std::string &pr_id) const;
  [[nodiscard]] nlohmann::json get_diff(const std::string &principal_id,
                                        const std::string &pr_id) const;
  [[nodiscard]] nlohmann::json list_prs(const std::string &principal_id, const std::string &status,
                                        const std::string &schema, const std::string &table,
                                        const std::string &proposer, const std::string &after,
                                        const std::string &before, const std::string &cursor,
                                        int limit) const;
  [[nodiscard]] nlohmann::json list_events(const std::string &principal_id,
                                           const std::string &pr_id) const;

private:
  [[nodiscard]] nlohmann::json call_json(const std::string &sql, pqxx::params params) const;
  [[nodiscard]] DbResult unwrap_mutation(const nlohmann::json &wrapper) const;
  void note_policy_block(const std::string &principal_id, const AgentGateError &error) const;

  ConnectionPool &pool_;
  Config config_;
};

struct AppContext {
  Config config;
  std::unique_ptr<ConnectionPool> pool;
  std::unique_ptr<WorkPool> work;
  std::unique_ptr<Database> database;
  nlohmann::json propose_schema;
  nlohmann::json read_schema;
  nlohmann::json review_schema;
  nlohmann::json reject_schema;
  nlohmann::json merge_schema;
  nlohmann::json revert_schema;
  nlohmann::json webhook_schema;
};

[[nodiscard]] AppContext &app_context();

} // namespace agentgate
