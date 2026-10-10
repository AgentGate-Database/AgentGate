#pragma once

#include <string>

namespace agentgate::test {

extern int server_port;
extern std::string server_log;
extern std::string server_error;

void require_database_env();
std::string admin_url();
std::string api_database_url();
std::string worker_database_url();
std::string migrator_database_url();

} // namespace agentgate::test
