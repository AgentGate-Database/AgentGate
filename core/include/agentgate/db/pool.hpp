#pragma once

#include "agentgate/config.hpp"

#include <pqxx/pqxx>

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace agentgate {

class ConnectionPool {
public:
  ConnectionPool(std::string conninfo, std::size_t max_size,
                 std::chrono::milliseconds acquire_timeout, Timeouts timeouts);
  ~ConnectionPool();

  ConnectionPool(const ConnectionPool &) = delete;
  ConnectionPool &operator=(const ConnectionPool &) = delete;

  class Lease {
  public:
    Lease(ConnectionPool *pool, std::unique_ptr<pqxx::connection> connection);
    ~Lease();
    Lease(Lease &&other) noexcept;
    Lease &operator=(Lease &&) = delete;
    Lease(const Lease &) = delete;
    Lease &operator=(const Lease &) = delete;

    [[nodiscard]] pqxx::connection &get() const;

  private:
    ConnectionPool *pool_;
    std::unique_ptr<pqxx::connection> connection_;
  };

  [[nodiscard]] Lease acquire();
  void shutdown();

  [[nodiscard]] const Timeouts &timeouts() const { return timeouts_; }
  [[nodiscard]] std::size_t idle_count() const;

private:
  friend class Lease;
  void release(std::unique_ptr<pqxx::connection> connection);

  std::string conninfo_;
  std::size_t max_size_;
  std::chrono::milliseconds acquire_timeout_;
  Timeouts timeouts_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::vector<std::unique_ptr<pqxx::connection>> idle_;
  std::size_t live_{0};
  bool stopping_{false};
};

} // namespace agentgate
