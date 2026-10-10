#include "agentgate/db/work_pool.hpp"

#include "agentgate/error.hpp"

namespace agentgate {

WorkPool::WorkPool(std::size_t threads, std::size_t max_queue) : max_queue_(max_queue) {
  if (threads == 0 || max_queue_ == 0) {
    throw AgentGateError{ErrorCode::Internal, 500, "work pool requires threads and a queue bound"};
  }
  threads_.reserve(threads);
  for (std::size_t i = 0; i < threads; ++i) {
    threads_.emplace_back([this](std::stop_token /*stop*/) { run(); });
  }
}

WorkPool::~WorkPool() {
  shutdown();
}

void WorkPool::enqueue(std::function<void()> job) {
  {
    std::lock_guard lock(mutex_);
    if (stopping_) {
      throw AgentGateError{ErrorCode::Internal, 503, "work pool is shutting down"};
    }
    if (queue_.size() >= max_queue_) {
      throw AgentGateError{ErrorCode::LimitExceeded, 429, "work queue is full"};
    }
    queue_.push(std::move(job));
  }
  cv_.notify_one();
}

void WorkPool::run() {
  for (;;) {
    std::function<void()> job;
    {
      std::unique_lock lock(mutex_);
      cv_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
      if (stopping_ && queue_.empty()) {
        return;
      }
      job = std::move(queue_.front());
      queue_.pop();
    }
    job();
  }
}

void WorkPool::shutdown() {
  {
    std::lock_guard lock(mutex_);
    if (stopping_) {
      return;
    }
    stopping_ = true;
  }
  cv_.notify_all();
  threads_.clear();
}

std::size_t WorkPool::queued() const {
  std::lock_guard lock(mutex_);
  return queue_.size();
}

} // namespace agentgate
