#include "agentgate/services/database.hpp"

#include "agentgate/crypto.hpp"
#include "agentgate/db/transaction.hpp"
#include "agentgate/error.hpp"

#include <optional>

namespace agentgate {
namespace {

void append_optional(pqxx::params &params, const std::string &value) {
  if (value.empty()) {
    params.append(std::optional<std::string>{});
  } else {
    params.append(value);
  }
}

} // namespace

Database::Database(ConnectionPool &pool, Config config) : pool_(pool), config_(std::move(config)) {}

void Database::ping() const {
  try {
    auto lease = pool_.acquire();
    Transaction tx(lease.get(), pool_.timeouts());
    tx.work().exec("SELECT 1");
    tx.commit();
  } catch (const AgentGateError &) {
    throw;
  } catch (const pqxx::failure &ex) {
    throw error_from_database(ex.sqlstate(), ex.what());
  }
}

nlohmann::json Database::call_json(const std::string &sql, pqxx::params params) const {
  try {
    auto lease = pool_.acquire();
    Transaction tx(lease.get(), pool_.timeouts());
    const auto field = tx.work().exec(sql, params).one_field();
    nlohmann::json parsed = nullptr;
    if (!field.is_null()) {
      parsed = nlohmann::json::parse(field.c_str());
    }
    tx.commit();
    return parsed;
  } catch (const AgentGateError &) {
    throw;
  } catch (const pqxx::failure &ex) {
    throw error_from_database(ex.sqlstate(), ex.what());
  } catch (const nlohmann::json::exception &) {
    throw AgentGateError{ErrorCode::Internal, 500, "invalid database JSON"};
  }
}

DbResult Database::unwrap_mutation(const nlohmann::json &wrapper) const {
  if (!wrapper.is_object() || !wrapper.contains("http_status") || !wrapper.contains("body")) {
    throw AgentGateError{ErrorCode::Internal, 500, "invalid mutation response"};
  }
  return DbResult{wrapper.at("http_status").get<int>(), wrapper.at("body")};
}

Principal Database::authenticate(const std::string &credential_id,
                                 const std::string &secret) const {
  const auto computed = sha256_bytes(secret);
  unsigned char stored[32] = {};
  const unsigned char *digest = stored;
  bool matches = false;
  nlohmann::json row;
  try {
    row = call_json("SELECT agentgate.authenticate($1::uuid)", pqxx::params{credential_id});
  } catch (const AgentGateError &ex) {
    if (ex.code != ErrorCode::NotFound) {
      throw;
    }
  }

  if (row.is_object() && row.contains("secret_digest_hex") &&
      decode_hex(row.at("secret_digest_hex").get<std::string>(), stored, sizeof stored)) {
    digest = stored;
    matches = true;
  }
  const bool equal = constant_time_equal(digest, computed.data(), sizeof stored);
  if (!matches || !equal || !row.is_object() || row.value("revoked", true)) {
    throw AgentGateError{ErrorCode::Unauthorized, 401, "unauthorized"};
  }

  Principal principal;
  principal.id = row.at("principal_id").get<std::string>();
  principal.kind = row.at("kind").get<std::string>();
  principal.name = row.at("name").get<std::string>();
  principal.scopes = row.at("scopes");
  return principal;
}

DbResult Database::propose(const std::string &principal_id, const nlohmann::json &body,
                           const std::string &idempotency_key,
                           const std::string &request_digest) const {
  const auto wrapper = call_json(
      "SELECT agentgate.propose($1::uuid, $2::jsonb, $3::text, $4::text, $5::int, $6::int, "
      "$7::int)",
      pqxx::params{principal_id, body.dump(), idempotency_key, request_digest, config_.max_pr_rows,
                   config_.min_expiry_seconds, config_.max_expiry_seconds});
  return unwrap_mutation(wrapper);
}

DbResult Database::create_revision(const std::string &principal_id, const std::string &pr_id,
                                   const nlohmann::json &body, const std::string &idempotency_key,
                                   const std::string &request_digest) const {
  const auto wrapper = call_json(
      "SELECT agentgate.create_revision($1::uuid, $2::uuid, $3::jsonb, $4::text, $5::text, "
      "$6::int, $7::int, $8::int)",
      pqxx::params{principal_id, pr_id, body.dump(), idempotency_key, request_digest,
                   config_.max_pr_rows, config_.min_expiry_seconds, config_.max_expiry_seconds});
  return unwrap_mutation(wrapper);
}

DbResult Database::approve(const std::string &principal_id, const std::string &pr_id,
                           const nlohmann::json &body, const std::string &idempotency_key,
                           const std::string &request_digest) const {
  const auto wrapper =
      call_json("SELECT agentgate.approve($1::uuid, $2::uuid, $3::jsonb, $4::text, $5::text)",
                pqxx::params{principal_id, pr_id, body.dump(), idempotency_key, request_digest});
  return unwrap_mutation(wrapper);
}

DbResult Database::enqueue_merge(const std::string &principal_id, const std::string &pr_id,
                                 const nlohmann::json &body, const std::string &idempotency_key,
                                 const std::string &request_digest) const {
  const auto wrapper =
      call_json("SELECT agentgate.enqueue_merge($1::uuid, $2::uuid, $3::jsonb, $4::text, $5::text)",
                pqxx::params{principal_id, pr_id, body.dump(), idempotency_key, request_digest});
  return unwrap_mutation(wrapper);
}

DbResult Database::reject(const std::string &principal_id, const std::string &pr_id,
                          const nlohmann::json &body, const std::string &idempotency_key,
                          const std::string &request_digest) const {
  const auto wrapper =
      call_json("SELECT agentgate.reject($1::uuid, $2::uuid, $3::jsonb, $4::text, $5::text)",
                pqxx::params{principal_id, pr_id, body.dump(), idempotency_key, request_digest});
  return unwrap_mutation(wrapper);
}

nlohmann::json Database::get_pr(const std::string &principal_id, const std::string &pr_id) const {
  return call_json("SELECT agentgate.get_pr($1::uuid, $2::uuid)",
                   pqxx::params{principal_id, pr_id});
}

nlohmann::json Database::get_diff(const std::string &principal_id, const std::string &pr_id) const {
  return call_json("SELECT agentgate.get_pr_diff($1::uuid, $2::uuid)",
                   pqxx::params{principal_id, pr_id});
}

nlohmann::json Database::list_prs(const std::string &principal_id, const std::string &status,
                                  const std::string &schema, const std::string &table,
                                  const std::string &proposer, const std::string &after,
                                  const std::string &before, const std::string &cursor,
                                  int limit) const {
  pqxx::params params;
  params.append(principal_id);
  append_optional(params, status);
  append_optional(params, schema);
  append_optional(params, table);
  append_optional(params, proposer);
  append_optional(params, after);
  append_optional(params, before);
  append_optional(params, cursor);
  params.append(limit);
  return call_json("SELECT agentgate.list_prs($1::uuid, $2::text, $3::text, $4::text, $5::text, "
                   "$6::timestamptz, $7::timestamptz, $8::text, $9::int)",
                   params);
}

nlohmann::json Database::list_events(const std::string &principal_id,
                                     const std::string &pr_id) const {
  return call_json("SELECT agentgate.list_events($1::uuid, $2::uuid)",
                   pqxx::params{principal_id, pr_id});
}

AppContext &app_context() {
  static AppContext context;
  return context;
}

} // namespace agentgate
