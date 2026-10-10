#include "agentgate/db/work_pool.hpp"
#include "agentgate/error.hpp"

#include <catch2/catch_test_macros.hpp>

#include <atomic>

TEST_CASE("work pool runs jobs and rejects an overflowing queue", "[unit]") {
  agentgate::WorkPool pool(2, 2);
  std::atomic<int> ran{0};
  auto first = pool.submit([&ran] {
    ran.fetch_add(1);
    return 1;
  });
  REQUIRE(first.get() == 1);
  REQUIRE(ran.load() == 1);

  std::atomic<bool> release{false};
  auto blocker = pool.submit([&release] {
    while (!release.load()) {
    }
    return 0;
  });
  auto second = pool.submit([&release] {
    while (!release.load()) {
    }
    return 0;
  });
  bool overflowed = false;
  try {
    for (int i = 0; i < 8; ++i) {
      pool.submit([] { return 0; });
    }
  } catch (const agentgate::AgentGateError &error) {
    overflowed = error.code == agentgate::ErrorCode::LimitExceeded;
  }
  release.store(true);
  blocker.wait();
  second.wait();
  REQUIRE(overflowed);
}
