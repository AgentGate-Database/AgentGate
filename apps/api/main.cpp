#include "http.hpp"

#include "agentgate/config.hpp"
#include "agentgate/db/pool.hpp"
#include "agentgate/db/work_pool.hpp"
#include "agentgate/error.hpp"
#include "agentgate/schema.hpp"
#include "agentgate/services/database.hpp"

#include <drogon/drogon.h>
#include <trantor/utils/Logger.h>

#include <algorithm>
#include <iostream>

int main() {
  try {
    auto config = agentgate::load_config();
    auto &ctx = agentgate::app_context();
    ctx.config = config;
    ctx.pool = std::make_unique<agentgate::ConnectionPool>(config.database_url, config.pool_size,
                                                           config.acquire_timeout, config.timeouts);
    ctx.work = std::make_unique<agentgate::WorkPool>(config.work_threads, config.work_queue);
    ctx.database = std::make_unique<agentgate::Database>(*ctx.pool, config);
    agentgate::self_test_schemas(config.contracts_dir);
    ctx.propose_schema =
        agentgate::load_contract_schema(config.contracts_dir, "propose_request.json");
    ctx.review_schema =
        agentgate::load_contract_schema(config.contracts_dir, "review_request.json");
    ctx.reject_schema =
        agentgate::load_contract_schema(config.contracts_dir, "reject_request.json");

    agentgate::register_routes();
    const auto body_limit = static_cast<std::size_t>(std::max(config.max_payload_bytes, 1)) + 4096;
    drogon::app().setClientMaxBodySize(body_limit);
    drogon::app().setLogLevel(trantor::Logger::kInfo);
    drogon::app().addListener(config.http_host, config.http_port);
    drogon::app().setThreadNum(static_cast<std::size_t>(std::max(config.http_threads, 1)));
    drogon::app().setIntSignalHandler([] { drogon::app().quit(); });
    drogon::app().setTermSignalHandler([] { drogon::app().quit(); });
    std::cerr << "agentgate-api listening on " << config.http_host << ":" << config.http_port
              << '\n';
    drogon::app().run();
    ctx.work->shutdown();
    ctx.pool->shutdown();
    return 0;
  } catch (const std::exception &ex) {
    std::cerr << "agentgate-api: " << agentgate::redact_secrets(ex.what()) << '\n';
    return 1;
  }
}
