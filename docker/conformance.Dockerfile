# Builds a single image carrying `conformance_test_runner` (built from
# upstream protobuf source) and Tarantool. The repo is mounted as a volume
# at /work at runtime; we never copy sources into the image, so generated
# Lua from `make gen` on the host stays the source of truth.
#
# Build:  docker build -t tarantool-protobuf-conformance:latest \
#             -f docker/conformance.Dockerfile docker/
# Run:    just conformance         (see Justfile)

FROM ubuntu:24.04 AS builder

# Pinned to match the host protoc shipped by Homebrew (v36.2). Keeps the
# conformance corpus and our generated _pb.lua aligned with the same
# protobuf release that runs `make gen` on the host.
ARG PROTOBUF_TAG=v36.2

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        ninja-build \
        build-essential \
        git \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Build protobuf via its own CMake project. -Dprotobuf_BUILD_CONFORMANCE
# adds the conformance/conformance_test_runner target. We rely on
# protobuf's vendored Abseil + utf8_range submodules to avoid mismatched
# system packages.
RUN git clone --depth 1 --branch ${PROTOBUF_TAG} --recurse-submodules \
        https://github.com/protocolbuffers/protobuf.git /src
WORKDIR /src
RUN cmake -GNinja -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -Dprotobuf_BUILD_CONFORMANCE=ON \
        -Dprotobuf_BUILD_TESTS=OFF \
        -Dprotobuf_BUILD_EXAMPLES=OFF \
    && cmake --build build --target conformance_test_runner

# -----------------------------------------------------------------------------

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Use Tarantool's official installer to set up the apt repo. The script
# detects the distro, writes /etc/apt/sources.list.d/tarantool_*.list, and
# installs `tarantool` so we don't have to track URL/path schema changes
# ourselves.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && curl -L https://tarantool.io/release/3/installer.sh | bash \
    && apt-get install -y --no-install-recommends \
        tarantool \
        tarantool-dev \
        build-essential \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/conformance_test_runner /usr/local/bin/conformance_test_runner
# protobuf's CMake build links conformance_test_runner against its
# vendored libjsoncpp as a shared library; the .so isn't installed and
# Ubuntu's libjsoncpp25 has a different soname. Ship the vendored copy.
# Since v34.1 jsoncpp is fetched via CMake FetchContent; the vendored .so
# lives under _deps/jsoncpp-build/ (still true in v36.2). Earlier protobuf
# releases placed it at /src/build/lib/.
COPY --from=builder /src/build/_deps/jsoncpp-build/src/lib_json/libjsoncpp.so* /usr/local/lib/
RUN ldconfig

# All scripts expect to find generated modules + the runtime under /work.
WORKDIR /work
ENV LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;./cmd/?.lua;./cmd/?/init.lua;;"
# Set PB_CONFORMANCE_SKIP_JSON=1 to short-circuit JSON output requests with
# `skipped` — useful when our JSON encoder hits a jsoncpp-crashing edge case
# and the suite would abort. Off by default now that the encoder no longer
# emits empty messages as `[]`.

# Default entrypoint exercises the Google suite against our runner.
# conformance_test_runner uses execv (not execvp), so the testee binary
# must be passed as an absolute path. Override via `docker run ... bash`
# for an interactive shell.
ENTRYPOINT ["/usr/local/bin/conformance_test_runner"]
CMD ["--enforce_recommended", \
     "--failure_list", "test/conformance/known_failures.txt", \
     "--text_format_failure_list", "test/conformance/known_failures_text.txt", \
     "/usr/bin/tarantool", "cmd/conformance-runner.lua"]
