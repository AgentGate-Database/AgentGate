#include "agentgate/db/pool.hpp"
#include "agentgate/db/transaction.hpp"
#include "agentgate/error.hpp"

#include <catch2/catch_test_macros.hpp>

#include <cstdlib>

TEST_CASE("pooled connections apply local timeouts only inside the transaction", "[unit]") {
  const char *url = std::getenv("AGENTGATE_TEST_DATABASE_URL");
  if (url == nullptr) {
    SKIP("AGENTGATE_TEST_DATABASE_URL is not set");
  }
  agentgate::Timeouts timeouts;
  timeouts.statement = std::chrono::milliseconds(5000);
  timeouts.lock = std::chrono::milliseconds(2000);
  timeouts.idle_in_transaction = std::chrono::milliseconds(5000);
  agentgate::ConnectionPool pool(url, 2, std::chrono::milliseconds(1000), timeouts);

  {
    auto lease = pool.acquire();
    agentgate::Transaction tx(lease.get(), pool.timeouts());
    const auto value =
        tx.work().exec("SELECT current_setting('statement_timeout')").one_field().as<std::string>();
    REQUIRE(value != "0");
    REQUIRE(value != "0ms");
    tx.commit();
  }
  {
    auto lease = pool.acquire();
    pqxx::work work(lease.get());
    const auto value =
        work.exec("SELECT current_setting('statement_timeout')").one_field().as<std::string>();
    REQUIRE((value == "0" || value == "0ms"));
    work.commit();
  }

  auto first = pool.acquire();
  auto second = pool.acquire();
  REQUIRE_THROWS_AS(pool.acquire(), agentgate::AgentGateError);
}
