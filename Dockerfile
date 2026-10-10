# Multi-stage build so a checkout can run without a local C++ toolchain.
# Dependencies come from the pinned vcpkg baseline in vcpkg.json.

FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    bison build-essential ca-certificates cmake curl flex git ninja-build pkg-config python3 tar unzip zip \
    && rm -rf /var/lib/apt/lists/*

ARG VCPKG_BASELINE=e456309491fd875487bf02b8a0dca76c1b1b00cc
RUN git clone https://github.com/microsoft/vcpkg.git /opt/vcpkg \
    && git -C /opt/vcpkg checkout ${VCPKG_BASELINE} \
    && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

WORKDIR /src
COPY . .
ENV VCPKG_ROOT=/opt/vcpkg
ENV VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg
RUN --mount=type=cache,target=/var/cache/vcpkg \
    set -eux; \
    ok=0; \
    for attempt in 1 2 3; do \
      if cmake --preset ci-linux && cmake --build --preset ci-linux; then \
        ok=1; \
        break; \
      fi; \
      echo "configure/build attempt ${attempt} failed" >&2; \
      sleep 20; \
    done; \
    test "${ok}" = 1

RUN mkdir -p /out/bin /out/lib \
    && cp /src/build/ci-linux/apps/api/agentgate-api /out/bin/ \
    && cp /src/build/ci-linux/apps/worker/agentgate-worker /out/bin/ \
    && ldd /out/bin/agentgate-api /out/bin/agentgate-worker \
      | awk '/=>/ { print $3 }' \
      | sort -u \
      | while read -r lib; do \
          case "${lib}" in \
            /lib/*|/usr/lib/*|"") ;; \
            *) cp -a "${lib}" /out/lib/ ;; \
          esac; \
        done

FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/ /usr/local/bin/
COPY --from=build /out/lib/ /usr/local/lib/
COPY packages/contracts /app/contracts
ENV LD_LIBRARY_PATH=/usr/local/lib
ENV AGENTGATE_CONTRACTS_DIR=/app/contracts
USER nobody
EXPOSE 8080
ENTRYPOINT ["agentgate-api"]
