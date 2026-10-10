add_executable(agentgate_unit_tests
  unit/test_errors.cpp
  unit/test_credentials.cpp
  unit/test_schema.cpp
  unit/test_work_pool.cpp
  unit/test_pool.cpp)
target_link_libraries(agentgate_unit_tests PRIVATE agentgate_core Catch2::Catch2WithMain)
agentgate_set_warnings(agentgate_unit_tests)

add_executable(agentgate_integration_tests
  integration/test_privileges.cpp
  integration/test_enrollment.cpp
  integration/test_api.cpp
  integration/http_client.cpp
  integration/server.cpp)
target_link_libraries(agentgate_integration_tests PRIVATE agentgate_core Catch2::Catch2WithMain)
target_compile_definitions(agentgate_integration_tests PRIVATE
  AGENTGATE_API_BIN="$<TARGET_FILE:agentgate-api>")
agentgate_set_warnings(agentgate_integration_tests)

include(CTest)
include(Catch)
catch_discover_tests(agentgate_unit_tests PROPERTIES LABELS "unit")
catch_discover_tests(agentgate_integration_tests
  PROPERTIES LABELS "integration" RUN_SERIAL TRUE)
add_dependencies(agentgate_integration_tests agentgate-api)
