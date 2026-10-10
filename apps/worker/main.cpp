#include "agentgate/config.hpp"
#include "agentgate/db/pool.hpp"
#include "agentgate/db/transaction.hpp"
#include "agentgate/error.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <thread>

namespace {
std::atomic<bool> g_stop{false};

void on_signal(int) {
  g_stop.store(true);
}
} // namespace

int main() {
  try {
    const char *worker_url = std::getenv("AGENTGATE_WORKER_DATABASE_URL");
    auto config = agentgate::load_config(worker_url != nullptr && worker_url[0] != '\0'
                                             ? "AGENTGATE_WORKER_DATABASE_URL"
                                             : "AGENTGATE_DATABASE_URL");
    agentgate::ConnectionPool pool(config.database_url, config.pool_size, config.acquire_timeout,
                                   config.timeouts);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    {
      auto lease = pool.acquire();
      agentgate::Transaction tx(lease.get(), pool.timeouts());
      tx.work().exec("SELECT 1");
      tx.commit();
    }
    std::ofstream ready("/tmp/agentgate-worker-ready");
    ready << "ok\n";
    ready.close();
    std::cerr << "agentgate-worker connected\n";

    while (!g_stop.load()) {
      try {
        auto lease = pool.acquire();
        agentgate::Transaction tx(lease.get(), pool.timeouts());
        tx.work().exec("SELECT agentgate.expire_prs()");
        tx.commit();
      } catch (const std::exception &ex) {
        std::cerr << "agentgate-worker: " << agentgate::redact_secrets(ex.what()) << '\n';
      }
      const auto ticks = static_cast<int>(config.expire_interval.count()) * 5;
      for (int tick = 0; tick < ticks && !g_stop.load(); ++tick) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
      }
    }
    pool.shutdown();
    return 0;
  } catch (const std::exception &ex) {
    std::cerr << "agentgate-worker: " << agentgate::redact_secrets(ex.what()) << '\n';
    return 1;
  }
}
