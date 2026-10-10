# ADR 0004 — vcpkg manifest and Homebrew development

## Status

Accepted.

## Decision

`vcpkg.json` pins the dependency set and a builtin baseline. Docker and GitHub Actions build with that manifest so users do not need a local C++ toolchain.

The maintainer machine is an Apple Silicon Mac with Homebrew. The `brew-debug` CMake preset sets `CMAKE_PREFIX_PATH=/opt/homebrew` for Drogon, libpqxx, Catch2, nlohmann-json, and OpenSSL. The JSON Schema validator is found with `find_package` or fetched at tag `2.4.0` when the package is absent. Both paths link the same CMake targets: `Drogon::Drogon`, `libpqxx::pqxx`, `nlohmann_json::nlohmann_json`, `nlohmann_json_schema_validator::validator`, `OpenSSL::Crypto`, and `Catch2::Catch2WithMain`.

## Consequences

Native and container builds can drift if Homebrew bottles move ahead of the vcpkg baseline. CI uses the baseline, so that is the compatibility bar. Do not remove the manifest to make the Mac build the only path.
