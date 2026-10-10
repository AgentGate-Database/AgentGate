add_executable(agentgate-api
  main.cpp
  routes.cpp
  filters.cpp)
target_link_libraries(agentgate-api PRIVATE agentgate_core Drogon::Drogon)
agentgate_set_warnings(agentgate-api)
