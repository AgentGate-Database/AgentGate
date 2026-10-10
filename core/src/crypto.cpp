#include "agentgate/crypto.hpp"

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

#include <stdexcept>

namespace agentgate {
namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

} // namespace

std::optional<ParsedCredential> parse_credential(std::string_view token) {
  constexpr std::string_view prefix = "agk_";
  if (!token.starts_with(prefix) || token.size() < prefix.size() + 36 + 1 + 16) {
    return std::nullopt;
  }
  const auto rest = token.substr(prefix.size());
  if (rest[36] != '_') {
    return std::nullopt;
  }
  ParsedCredential parsed;
  parsed.credential_id = std::string(rest.substr(0, 36));
  parsed.secret = std::string(rest.substr(37));
  if (parsed.secret.empty()) {
    return std::nullopt;
  }
  const auto &id = parsed.credential_id;
  auto hex_or_dash = [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '-';
  };
  for (char c : id) {
    if (!hex_or_dash(c)) {
      return std::nullopt;
    }
  }
  if (id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-') {
    return std::nullopt;
  }
  return parsed;
}

std::array<unsigned char, 32> sha256_bytes(std::string_view data) {
  std::array<unsigned char, 32> out{};
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (ctx == nullptr) {
    throw std::runtime_error("EVP_MD_CTX_new failed");
  }
  const auto ok = EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr) == 1 &&
                  EVP_DigestUpdate(ctx, data.data(), data.size()) == 1 &&
                  EVP_DigestFinal_ex(ctx, out.data(), nullptr) == 1;
  EVP_MD_CTX_free(ctx);
  if (!ok) {
    throw std::runtime_error("SHA-256 failed");
  }
  return out;
}

std::string hmac_sha256_hex(std::string_view key, std::string_view message) {
  unsigned char raw[EVP_MAX_MD_SIZE];
  unsigned int length = 0;
  const auto *signed_bytes =
      HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()),
           reinterpret_cast<const unsigned char *>(message.data()), message.size(), raw, &length);
  if (signed_bytes == nullptr || length != 32) {
    throw std::runtime_error("HMAC-SHA256 failed");
  }
  return to_hex(raw, length);
}

bool constant_time_equal(const unsigned char *left, const unsigned char *right,
                         std::size_t length) {
  return CRYPTO_memcmp(left, right, length) == 0;
}

std::string random_bytes(std::size_t count) {
  std::string raw(count, '\0');
  if (count > 0 &&
      RAND_bytes(reinterpret_cast<unsigned char *>(raw.data()), static_cast<int>(count)) != 1) {
    throw std::runtime_error("RAND_bytes failed");
  }
  return raw;
}

std::string random_token_secret(std::size_t raw_bytes) {
  std::string raw(raw_bytes, '\0');
  if (RAND_bytes(reinterpret_cast<unsigned char *>(raw.data()), static_cast<int>(raw_bytes)) != 1) {
    throw std::runtime_error("RAND_bytes failed");
  }
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string out;
  out.resize(raw_bytes);
  for (std::size_t i = 0; i < raw_bytes; ++i) {
    out[i] = kAlphabet[static_cast<unsigned char>(raw[i]) % 64];
  }
  return out;
}

std::string to_hex(const unsigned char *data, std::size_t length) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out(length * 2, '\0');
  for (std::size_t i = 0; i < length; ++i) {
    out[i * 2] = kHex[data[i] >> 4];
    out[i * 2 + 1] = kHex[data[i] & 0x0f];
  }
  return out;
}

bool decode_hex(std::string_view hex, unsigned char *out, std::size_t out_len) {
  if (hex.size() != out_len * 2) {
    return false;
  }
  for (std::size_t i = 0; i < out_len; ++i) {
    const int hi = hex_value(hex[i * 2]);
    const int lo = hex_value(hex[i * 2 + 1]);
    if (hi < 0 || lo < 0) {
      return false;
    }
    out[i] = static_cast<unsigned char>((hi << 4) | lo);
  }
  return true;
}

} // namespace agentgate
