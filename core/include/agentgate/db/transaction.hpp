#pragma once

#include "agentgate/config.hpp"

#include <pqxx/pqxx>

namespace agentgate {

// Owns one pqxx::work. Applies timeouts with set_config(..., is_local=true)
// so a transaction-mode pooler does not retain them on the server connection.
// Named prepared statements are intentionally unused.
class Transaction {
public:
  Transaction(pqxx::connection &connection, Timeouts timeouts);
  ~Transaction();

  Transaction(const Transaction &) = delete;
  Transaction &operator=(const Transaction &) = delete;

  [[nodiscard]] pqxx::work &work() { return work_; }
  void commit();

private:
  pqxx::work work_;
  bool committed_{false};
};

} // namespace agentgate
