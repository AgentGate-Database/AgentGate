#include "agentgate/db/transaction.hpp"

#include "agentgate/error.hpp"

namespace agentgate {
namespace {

void set_local(pqxx::work &work, const char *name, std::chrono::milliseconds value) {
  // Third argument true means transaction-local, which survives transaction-mode pooling.
  work.exec("SELECT set_config($1, $2, true)", pqxx::params{name, std::to_string(value.count())});
}

} // namespace

Transaction::Transaction(pqxx::connection &connection, Timeouts timeouts) : work_(connection) {
  try {
    set_local(work_, "statement_timeout", timeouts.statement);
    set_local(work_, "lock_timeout", timeouts.lock);
    set_local(work_, "idle_in_transaction_session_timeout", timeouts.idle_in_transaction);
  } catch (const pqxx::failure &ex) {
    throw error_from_database(ex.sqlstate(), ex.what());
  }
}

Transaction::~Transaction() {
  if (!committed_) {
    try {
      work_.abort();
    } catch (const std::exception &) {
    }
  }
}

void Transaction::commit() {
  work_.commit();
  committed_ = true;
}

} // namespace agentgate
