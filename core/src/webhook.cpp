#include "agentgate/webhook.hpp"

#include "agentgate/error.hpp"

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>

#include <cctype>
#include <cstdint>
#include <cstring>
#include <string>

namespace agentgate {
namespace {

std::string lower_copy(std::string_view value) {
  std::string out(value);
  for (char &ch : out) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return out;
}

bool private_ipv4(std::uint32_t host_order) {
  const auto in = [host_order](std::uint32_t network, int bits) {
    const auto mask = bits == 0 ? 0u : 0xffffffffu << (32 - bits);
    return (host_order & mask) == (network & mask);
  };
  return in(0x00000000u, 8) || in(0x0a000000u, 8) || in(0x7f000000u, 8) || in(0xa9fe0000u, 16) ||
         in(0xac100000u, 12) || in(0xc0a80000u, 16);
}

bool private_address(const sockaddr *address) {
  if (address->sa_family == AF_INET) {
    const auto *v4 = reinterpret_cast<const sockaddr_in *>(address);
    return private_ipv4(ntohl(v4->sin_addr.s_addr));
  }
  if (address->sa_family == AF_INET6) {
    const auto *v6 = reinterpret_cast<const sockaddr_in6 *>(address);
    const unsigned char *bytes = v6->sin6_addr.s6_addr;
    if (bytes[0] == 0xff) {
      return true;
    }
    const bool loopback = std::memcmp(bytes, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1", 16) == 0;
    const bool link_local = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    const bool unique_local = (bytes[0] & 0xfe) == 0xfc;
    if (loopback || link_local || unique_local) {
      return true;
    }
    const bool mapped = std::memcmp(bytes, "\0\0\0\0\0\0\0\0\0\0\xff\xff", 12) == 0;
    if (mapped) {
      const auto host = (static_cast<std::uint32_t>(bytes[12]) << 24) |
                        (static_cast<std::uint32_t>(bytes[13]) << 16) |
                        (static_cast<std::uint32_t>(bytes[14]) << 8) |
                        static_cast<std::uint32_t>(bytes[15]);
      return private_ipv4(host);
    }
  }
  return false;
}

void reject(const char *message) {
  throw AgentGateError{ErrorCode::ValidationFailed, 422, message};
}

} // namespace

void validate_webhook_url(std::string_view url, bool allow_private) {
  const auto scheme_end = url.find("://");
  if (scheme_end == std::string_view::npos) {
    reject("webhook url is invalid");
  }
  const auto scheme = lower_copy(url.substr(0, scheme_end));
  if (scheme != "http" && scheme != "https") {
    reject("webhook url is invalid");
  }
  const auto rest = url.substr(scheme_end + 3);
  if (rest.empty()) {
    reject("webhook url is invalid");
  }
  const auto slash = rest.find('/');
  const auto at = rest.find('@');
  if (at != std::string_view::npos && (slash == std::string_view::npos || at < slash)) {
    reject("webhook url is invalid");
  }
  const auto hostport = slash == std::string_view::npos ? rest : rest.substr(0, slash);
  if (hostport.empty()) {
    reject("webhook url is invalid");
  }
  std::string host;
  std::string port = scheme == "https" ? "443" : "80";
  if (hostport.front() == '[') {
    const auto end = hostport.find(']');
    if (end == std::string::npos || end == 1) {
      reject("webhook url is invalid");
    }
    host = hostport.substr(1, end - 1);
    if (end + 1 < hostport.size()) {
      if (hostport[end + 1] != ':') {
        reject("webhook url is invalid");
      }
      port = hostport.substr(end + 2);
    }
  } else {
    const auto colon = hostport.rfind(':');
    if (colon != std::string::npos) {
      host = std::string(hostport.substr(0, colon));
      port = std::string(hostport.substr(colon + 1));
    } else {
      host = std::string(hostport);
    }
  }
  if (host.empty() || port.empty()) {
    reject("webhook url is invalid");
  }
  for (char ch : port) {
    if (ch < '0' || ch > '9') {
      reject("webhook url is invalid");
    }
  }
  try {
    const auto parsed = std::stoi(port);
    if (parsed < 1 || parsed > 65535) {
      reject("webhook url is invalid");
    }
  } catch (const std::exception &) {
    reject("webhook url is invalid");
  }
  const auto lowered = lower_copy(host);
  if (!allow_private && (lowered == "localhost" || lowered == "metadata.google.internal" ||
                         lowered.ends_with(".localhost") || lowered.ends_with(".internal"))) {
    reject("webhook destination is not allowed");
  }

  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  addrinfo *resolved = nullptr;
  const auto rc = ::getaddrinfo(host.c_str(), port.c_str(), &hints, &resolved);
  if (rc != 0 || resolved == nullptr) {
    if (resolved != nullptr) {
      ::freeaddrinfo(resolved);
    }
    reject("webhook host could not be resolved");
  }
  bool blocked = false;
  for (auto *item = resolved; item != nullptr; item = item->ai_next) {
    if (!allow_private && private_address(item->ai_addr)) {
      blocked = true;
      break;
    }
  }
  ::freeaddrinfo(resolved);
  if (blocked) {
    reject("webhook destination is not allowed");
  }
}

} // namespace agentgate
