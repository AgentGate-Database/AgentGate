#include "agentgate/db/pool.hpp"

#include "agentgate/error.hpp"

namespace agentgate {

ConnectionPool::Lease::Lease(ConnectionPool *pool, std::unique_ptr<pqxx::connection> connection)
    : pool_(pool), connection_(std::move(connection)) {}

ConnectionPool::Lease::~Lease() {
  if (pool_ != nullptr && connection_ != nullptr) {
    pool_->release(std::move(connection_));
  }
}

ConnectionPool::Lease::Lease(Lease &&other) noexcept
    : pool_(other.pool_), connection_(std::move(other.connection_)) {
  other.pool_ = nullptr;
}

pqxx::connection &ConnectionPool::Lease::get() const {
  return *connection_;
}

ConnectionPool::ConnectionPool(std::string conninfo, std::size_t max_size,
                               std::chrono::milliseconds acquire_timeout, Timeouts timeouts)
    : conninfo_(std::move(conninfo)), max_size_(max_size), acquire_timeout_(acquire_timeout),
      timeouts_(timeouts) {
  if (max_size_ == 0) {
    throw AgentGateError{ErrorCode::Internal, 500, "connection pool size must be positive"};
  }
}

ConnectionPool::~ConnectionPool() {
  shutdown();
}

ConnectionPool::Lease ConnectionPool::acquire() {
  std::unique_lock lock(mutex_);
  const auto deadline = std::chrono::steady_clock::now() + acquire_timeout_;
  for (;;) {
    if (stopping_) {
      throw AgentGateError{ErrorCode::Internal, 503, "connection pool is shutting down"};
    }
    if (!idle_.empty()) {
      auto connection = std::move(idle_.back());
      idle_.pop_back();
      lock.unlock();
      if (connection && connection->is_open()) {
        return Lease{this, std::move(connection)};
      }
      {
        std::lock_guard guard(mutex_);
        if (live_ > 0) {
          --live_;
        }
      }
      lock.lock();
      continue;
    }
    if (live_ < max_size_) {
      ++live_;
      break;
    }
    if (cv_.wait_until(lock, deadline) == std::cv_status::timeout && idle_.empty() &&
        live_ >= max_size_) {
      throw AgentGateError{ErrorCode::LimitExceeded, 503,
                           "timed out waiting for a database connection"};
    }
  }
  lock.unlock();

  try {
    auto connection = std::make_unique<pqxx::connection>(conninfo_);
    return Lease{this, std::move(connection)};
  } catch (const std::exception &ex) {
    std::lock_guard guard(mutex_);
    if (live_ > 0) {
      --live_;
    }
    cv_.notify_one();
    throw AgentGateError{ErrorCode::Internal, 503, redact_secrets(ex.what())};
  }
}

void ConnectionPool::release(std::unique_ptr<pqxx::connection> connection) {
  std::lock_guard lock(mutex_);
  if (stopping_ || connection == nullptr || !connection->is_open()) {
    if (live_ > 0) {
      --live_;
    }
    cv_.notify_one();
    return;
  }
  idle_.push_back(std::move(connection));
  cv_.notify_one();
}

void ConnectionPool::shutdown() {
  std::lock_guard lock(mutex_);
  stopping_ = true;
  idle_.clear();
  live_ = 0;
  cv_.notify_all();
}

std::size_t ConnectionPool::idle_count() const {
  std::lock_guard lock(mutex_);
  return idle_.size();
}

} // namespace agentgate
