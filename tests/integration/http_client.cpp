#include "http_client.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <sstream>
#include <stdexcept>

namespace agentgate::test {
namespace {

void write_all(int fd, const std::string &data) {
  std::size_t sent = 0;
  while (sent < data.size()) {
    const auto n = ::send(fd, data.data() + sent, data.size() - sent, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      throw std::runtime_error("send failed");
    }
    sent += static_cast<std::size_t>(n);
  }
}

} // namespace

HttpResult http_request(int port, const std::string &method, const std::string &path,
                        const std::string &body,
                        const std::vector<std::pair<std::string, std::string>> &headers) {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    throw std::runtime_error("socket failed");
  }
  timeval timeout{};
  timeout.tv_sec = 10;
  ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
  ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (::inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) != 1) {
    ::close(fd);
    throw std::runtime_error("inet_pton failed");
  }
  if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0) {
    ::close(fd);
    throw std::runtime_error("connect failed");
  }

  std::ostringstream request;
  request << method << ' ' << path << " HTTP/1.1\r\n";
  request << "Host: 127.0.0.1\r\n";
  request << "Connection: close\r\n";
  request << "Content-Length: " << body.size() << "\r\n";
  bool has_type = false;
  for (const auto &header : headers) {
    request << header.first << ": " << header.second << "\r\n";
    if (header.first == "Content-Type" || header.first == "content-type") {
      has_type = true;
    }
  }
  if (!body.empty() && !has_type) {
    request << "Content-Type: application/json\r\n";
  }
  request << "\r\n" << body;
  write_all(fd, request.str());

  std::string raw;
  char buffer[4096];
  for (;;) {
    const auto n = ::recv(fd, buffer, sizeof buffer, 0);
    if (n == 0) {
      break;
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    raw.append(buffer, static_cast<std::size_t>(n));
  }
  ::close(fd);

  HttpResult result;
  const auto line_end = raw.find("\r\n");
  if (line_end == std::string::npos) {
    throw std::runtime_error("incomplete HTTP response");
  }
  const auto status_line = raw.substr(0, line_end);
  const auto first_space = status_line.find(' ');
  const auto second_space =
      status_line.find(' ', first_space == std::string::npos ? 0 : first_space + 1);
  if (first_space == std::string::npos) {
    throw std::runtime_error("bad status line");
  }
  const auto code = status_line.substr(
      first_space + 1,
      (second_space == std::string::npos ? status_line.size() : second_space) - first_space - 1);
  result.status = std::stoi(code);
  const auto header_end = raw.find("\r\n\r\n");
  if (header_end == std::string::npos) {
    throw std::runtime_error("missing HTTP header terminator");
  }
  result.body = raw.substr(header_end + 4);
  return result;
}

} // namespace agentgate::test
