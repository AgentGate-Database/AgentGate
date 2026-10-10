find_package(nlohmann_json CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(libpqxx CONFIG REQUIRED)

find_package(nlohmann_json_schema_validator CONFIG QUIET)
if(NOT nlohmann_json_schema_validator_FOUND)
  include(FetchContent)
  set(JSON_VALIDATOR_INSTALL OFF CACHE BOOL "" FORCE)
  set(JSON_VALIDATOR_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(JSON_VALIDATOR_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(JSON_VALIDATOR_SHARED_LIBS OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(
    nlohmann_json_schema_validator
    GIT_REPOSITORY https://github.com/pboettch/json-schema-validator.git
    GIT_TAG 2.4.0
    GIT_SHALLOW TRUE)
  FetchContent_MakeAvailable(nlohmann_json_schema_validator)
endif()

find_package(Drogon CONFIG REQUIRED)
find_package(Catch2 3 CONFIG REQUIRED)
find_package(CURL REQUIRED)
