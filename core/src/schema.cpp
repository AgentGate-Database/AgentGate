#include "agentgate/schema.hpp"

#include "agentgate/error.hpp"

#include <nlohmann/json-schema.hpp>

#include <fstream>
#include <sstream>

namespace agentgate {

nlohmann::json load_json_file(const std::filesystem::path &path) {
  std::ifstream input(path);
  if (!input) {
    throw AgentGateError{ErrorCode::Internal, 500, "unable to read " + path.string()};
  }
  std::stringstream buffer;
  buffer << input.rdbuf();
  try {
    return nlohmann::json::parse(buffer.str());
  } catch (const nlohmann::json::exception &) {
    throw AgentGateError{ErrorCode::Internal, 500, "invalid JSON in " + path.string()};
  }
}

void validate_json(const nlohmann::json &schema, const nlohmann::json &instance) {
  try {
    nlohmann::json_schema::json_validator validator;
    validator.set_root_schema(schema);
    validator.validate(instance);
  } catch (const AgentGateError &) {
    throw;
  } catch (const std::exception &ex) {
    throw AgentGateError{ErrorCode::ValidationFailed, 422, ex.what()};
  }
}

nlohmann::json load_contract_schema(const std::filesystem::path &contracts_dir,
                                    const std::string &name) {
  return load_json_file(contracts_dir / "schemas" / name);
}

void self_test_schemas(const std::filesystem::path &contracts_dir) {
  const auto schema = load_contract_schema(contracts_dir, "propose_request.json");
  const nlohmann::json bad{{"title", 1}};
  bool rejected = false;
  try {
    validate_json(schema, bad);
  } catch (const AgentGateError &ex) {
    rejected = ex.code == ErrorCode::ValidationFailed;
  }
  if (!rejected) {
    throw AgentGateError{ErrorCode::Internal, 500,
                         "JSON schema self-test failed to reject an invalid proposal"};
  }
  const auto example = load_json_file(contracts_dir / "examples" / "propose_request.json");
  validate_json(schema, example);
}

} // namespace agentgate
