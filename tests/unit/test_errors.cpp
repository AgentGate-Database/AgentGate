#include "agentgate/error.hpp"

#include <catch2/catch_test_macros.hpp>

#include <string>

TEST_CASE("sqlstate maps to stable error codes", "[unit]") {
  const auto mismatch = agentgate::error_from_database(
      "AG006", R"({"code":"REVISION_MISMATCH","message":"stale","details":{}})");
  REQUIRE(mismatch.code == agentgate::ErrorCode::RevisionMismatch);
  REQUIRE(mismatch.http_status == 409);
  REQUIRE(mismatch.to_json()["error"]["code"] == "REVISION_MISMATCH");

  const auto privilege =
      agentgate::error_from_database("42501", "permission denied for function approve");
  REQUIRE(privilege.code == agentgate::ErrorCode::Forbidden);
  REQUIRE(privilege.http_status == 403);
  REQUIRE(std::string(privilege.what()).find("approve") == std::string::npos);

  const auto unknown =
      agentgate::error_from_database("XX000", "secret postgresql://user:pw@db/app");
  REQUIRE(unknown.code == agentgate::ErrorCode::Internal);
  REQUIRE(unknown.http_status == 500);
  REQUIRE(std::string(unknown.what()) == "internal error");
}

TEST_CASE("redaction strips tokens and urls", "[unit]") {
  const auto text =
      agentgate::redact_secrets("failed postgresql://agentgate_api:secret@db/agentgate token "
                                "agk_11111111-1111-4111-8111-111111111111_abcdef");
  REQUIRE(text.find("secret") == std::string::npos);
  REQUIRE(text.find("abcdef") == std::string::npos);
  REQUIRE(text.find("<redacted>") != std::string::npos);
}
