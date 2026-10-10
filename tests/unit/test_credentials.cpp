#include "agentgate/crypto.hpp"

#include <catch2/catch_test_macros.hpp>

TEST_CASE("credential tokens parse and hash", "[unit]") {
  const auto secret = std::string(32, 'a');
  const std::string token = "agk_11111111-1111-4111-8111-111111111111_" + secret;
  const auto parsed = agentgate::parse_credential(token);
  REQUIRE(parsed.has_value());
  REQUIRE(parsed->credential_id == "11111111-1111-4111-8111-111111111111");
  REQUIRE(parsed->secret == secret);

  REQUIRE_FALSE(agentgate::parse_credential("bearer " + token).has_value());
  REQUIRE_FALSE(agentgate::parse_credential("agk_not-a-uuid_secret").has_value());

  const auto digest = agentgate::sha256_bytes(secret);
  REQUIRE(agentgate::constant_time_equal(digest.data(), digest.data(), digest.size()));
  auto other = digest;
  other[0] ^= 0x01;
  REQUIRE_FALSE(agentgate::constant_time_equal(digest.data(), other.data(), digest.size()));
  REQUIRE(agentgate::to_hex(digest.data(), digest.size()).size() == 64);
}
