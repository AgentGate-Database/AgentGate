cmake_minimum_required(VERSION 3.25)

project(agentgate
  VERSION 0.1.0
  DESCRIPTION "Postgres pull requests for AI agents"
  LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(AGENTGATE_SANITIZERS "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

include(cmake/Dependencies.cmake)
include(cmake/Warnings.cmake)
include(CTest)

add_subdirectory(core)
add_subdirectory(apps/api)
add_subdirectory(apps/worker)
add_subdirectory(tests)
