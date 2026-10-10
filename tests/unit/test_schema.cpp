#include "agentgate/schema.hpp"

#include <catch2/catch_test_macros.hpp>

#include <filesystem>
#include <fstream>
#include <iterator>

TEST_CASE("contract examples validate and the validator rejects bad input", "[unit]") {
  const std::filesystem::path root{AGENTGATE_CONTRACTS_DIR};
  agentgate::self_test_schemas(root);

  const std::pair<const char *, const char *> pairs[] = {
      {"propose_request.json", "propose_request.json"},
      {"read_request.json", "read_request.json"},
      {"read_response.json", "read_response.json"},
      {"review_request.json", "review_request.json"},
      {"reject_request.json", "reject_request.json"},
      {"error.json", "error.json"},
      {"pr_response.json", "pr_response.json"},
      {"diff_response.json", "diff_response.json"},
      {"list_response.json", "list_response.json"},
      {"review_response.json", "review_response.json"},
      {"merge_request.json", "merge_request.json"},
      {"merge_response.json", "merge_response.json"},
  };
  for (const auto &[schema_name, example_name] : pairs) {
    INFO(example_name);
    const auto schema = agentgate::load_contract_schema(root, schema_name);
    const auto example = agentgate::load_json_file(root / "examples" / example_name);
    REQUIRE_NOTHROW(agentgate::validate_json(schema, example));
  }

  std::ifstream openapi(root / "openapi.yaml");
  REQUIRE(openapi);
  std::string spec((std::istreambuf_iterator<char>(openapi)), std::istreambuf_iterator<char>());
  REQUIRE(spec.find("Correct invoice payment terms") != std::string::npos);
  REQUIRE(spec.find("Postgres pull requests for AI agents") != std::string::npos);
}
