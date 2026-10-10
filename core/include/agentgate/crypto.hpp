#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace agentgate {

struct ParsedCredential {
  std::string credential_id;
  std::string secret;
};

// Tokens look like agk_<uuid>_<base64url-secret>.
[[nodiscard]] std::optional<ParsedCredential> parse_credential(std::string_view token);

[[nodiscard]] std::array<unsigned char, 32> sha256_bytes(std::string_view data);

[[nodiscard]] std::string hmac_sha256_hex(std::string_view key, std::string_view message);

[[nodiscard]] bool constant_time_equal(const unsigned char *left, const unsigned char *right,
                                       std::size_t length);

[[nodiscard]] std::string to_hex(const unsigned char *data, std::size_t length);
[[nodiscard]] bool decode_hex(std::string_view hex, unsigned char *out, std::size_t out_len);

[[nodiscard]] std::string random_token_secret(std::size_t raw_bytes = 32);
[[nodiscard]] std::string random_bytes(std::size_t count);

} // namespace agentgate
