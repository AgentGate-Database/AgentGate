#pragma once

#include <nlohmann/json.hpp>

#include <filesystem>
#include <string>

namespace agentgate {

[[nodiscard]] nlohmann::json load_json_file(const std::filesystem::path &path);

void validate_json(const nlohmann::json &schema, const nlohmann::json &instance);

// Loads the proposal schema, rejects a known-bad document, and accepts the
// checked-in example. Fails the process if the validator is a no-op.
void self_test_schemas(const std::filesystem::path &contracts_dir);

[[nodiscard]] nlohmann::json load_contract_schema(const std::filesystem::path &contracts_dir,
                                                  const std::string &name);

} // namespace agentgate
