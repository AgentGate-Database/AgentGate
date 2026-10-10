#pragma once

#include <string>
#include <utility>
#include <vector>

namespace agentgate::test {

struct HttpResult {
  int status{0};
  std::string body;
};

HttpResult http_request(int port, const std::string &method, const std::string &path,
                        const std::string &body,
                        const std::vector<std::pair<std::string, std::string>> &headers);

} // namespace agentgate::test
