#pragma once

#include <condition_variable>
#include <cstddef>
#include <functional>
#include <future>
#include <mutex>
#include <queue>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace agentgate {

class WorkPool {
public:
  WorkPool(std::size_t threads, std::size_t max_queue);
  ~WorkPool();

  WorkPool(const WorkPool &) = delete;
  WorkPool &operator=(const WorkPool &) = delete;

  template <typename Fn>
  auto submit(Fn &&fn) -> std::future<std::invoke_result_t<std::decay_t<Fn>>> {
    using Result = std::invoke_result_t<std::decay_t<Fn>>;
    auto task = std::make_shared<std::packaged_task<Result()>>(std::forward<Fn>(fn));
    std::future<Result> future = task->get_future();
    enqueue([task]() { (*task)(); });
    return future;
  }

  void shutdown();
  [[nodiscard]] std::size_t queued() const;

private:
  void enqueue(std::function<void()> job);
  void run();

  std::size_t max_queue_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::queue<std::function<void()>> queue_;
  std::vector<std::jthread> threads_;
  bool stopping_{false};
};

} // namespace agentgate
