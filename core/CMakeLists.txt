add_library(agentgate_core
  src/config.cpp
  src/error.cpp
  src/crypto.cpp
  src/webhook.cpp
  src/schema.cpp
  src/db/pool.cpp
  src/db/transaction.cpp
  src/db/work_pool.cpp
  src/services/database.cpp)
target_include_directories(agentgate_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(agentgate_core
  PUBLIC
    libpqxx::pqxx
    nlohmann_json::nlohmann_json
    nlohmann_json_schema_validator::validator
    OpenSSL::Crypto)
agentgate_set_warnings(agentgate_core)
target_compile_definitions(agentgate_core
  PUBLIC AGENTGATE_CONTRACTS_DIR="${CMAKE_SOURCE_DIR}/packages/contracts")
