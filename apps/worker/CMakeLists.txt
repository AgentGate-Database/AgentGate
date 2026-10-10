add_executable(agentgate-worker main.cpp)
target_link_libraries(agentgate-worker PRIVATE agentgate_core)
agentgate_set_warnings(agentgate-worker)
