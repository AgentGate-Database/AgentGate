#include "server.hpp"

#include "http_client.hpp"

#include <catch2/catch_test_macros.hpp>
#include <catch2/reporters/catch_reporter_event_listener.hpp>
#include <catch2/reporters/catch_reporter_registrars.hpp>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <csignal>

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <thread>

namespace agentgate::test {
namespace {

pid_t g_pid = -1;

std::string env_required_or_empty(const char *name) {
  const char *value = std::getenv(name);
  return value == nullptr ? std::string{} : std::string{value};
}

void start_server() {
  const auto api_url = env_required_or_empty("AGENTGATE_TEST_API_DATABASE_URL");
  const auto port_text = env_required_or_empty("AGENTGATE_TEST_HTTP_PORT");
  if (!port_text.empty()) {
    server_port = std::stoi(port_text);
  }
  server_log = "/tmp/agentgate-api-test.log";
  g_pid = ::fork();
  if (g_pid < 0) {
    server_error = "fork failed";
    return;
  }
  if (g_pid == 0) {
    ::setenv("AGENTGATE_DATABASE_URL", api_url.c_str(), 1);
    ::setenv("AGENTGATE_HTTP_HOST", "127.0.0.1", 1);
    ::setenv("AGENTGATE_HTTP_PORT", std::to_string(server_port).c_str(), 1);
    ::setenv("AGENTGATE_CONTRACTS_DIR", AGENTGATE_CONTRACTS_DIR, 1);
    ::setenv("AGENTGATE_MAX_PAYLOAD_BYTES", "8192", 1);
    ::setenv("AGENTGATE_MAX_PR_ROWS", "5", 1);
    const int log_fd = ::open(server_log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log_fd >= 0) {
      ::dup2(log_fd, STDOUT_FILENO);
      ::dup2(log_fd, STDERR_FILENO);
      ::close(log_fd);
    }
    ::execl(AGENTGATE_API_BIN, AGENTGATE_API_BIN, static_cast<char *>(nullptr));
    _exit(127);
  }

  for (int attempt = 0; attempt < 50; ++attempt) {
    try {
      const auto response = http_request(server_port, "GET", "/healthz", "", {});
      if (response.status == 200) {
        return;
      }
    } catch (const std::exception &) {
    }
    int status = 0;
    const auto waited = ::waitpid(g_pid, &status, WNOHANG);
    if (waited == g_pid) {
      g_pid = -1;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  std::ifstream input(server_log);
  std::string contents((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
  server_error = contents.empty() ? "API process did not become healthy" : contents;
}

void stop_server() {
  if (g_pid > 0) {
    ::kill(g_pid, SIGTERM);
    ::waitpid(g_pid, nullptr, 0);
    g_pid = -1;
  }
}

} // namespace

int server_port = 18080;
std::string server_log;
std::string server_error;

void require_database_env() {
  if (std::getenv("AGENTGATE_TEST_DATABASE_URL") == nullptr) {
    SKIP("AGENTGATE_TEST_DATABASE_URL is not set");
  }
}

std::string admin_url() {
  require_database_env();
  return std::getenv("AGENTGATE_TEST_DATABASE_URL");
}

std::string api_database_url() {
  const char *value = std::getenv("AGENTGATE_TEST_API_DATABASE_URL");
  if (value == nullptr) {
    SKIP("AGENTGATE_TEST_API_DATABASE_URL is not set");
  }
  return value;
}

std::string worker_database_url() {
  const char *value = std::getenv("AGENTGATE_TEST_WORKER_DATABASE_URL");
  if (value == nullptr) {
    SKIP("AGENTGATE_TEST_WORKER_DATABASE_URL is not set");
  }
  return value;
}

std::string migrator_database_url() {
  const char *value = std::getenv("AGENTGATE_TEST_MIGRATOR_DATABASE_URL");
  if (value == nullptr) {
    SKIP("AGENTGATE_TEST_MIGRATOR_DATABASE_URL is not set");
  }
  return value;
}

struct ServerListener : Catch::EventListenerBase {
  using EventListenerBase::EventListenerBase;

  void testRunStarting(Catch::TestRunInfo const &) override {
    if (std::getenv("AGENTGATE_TEST_DATABASE_URL") == nullptr ||
        std::getenv("AGENTGATE_TEST_API_DATABASE_URL") == nullptr) {
      return;
    }
    start_server();
  }

  void testRunEnded(Catch::TestRunStats const &) override { stop_server(); }
};

CATCH_REGISTER_LISTENER(ServerListener)

} // namespace agentgate::test
