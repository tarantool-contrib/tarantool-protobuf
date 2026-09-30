# Justfile — canonical entry point for build / gen / test / bench / conformance.
#
# `just` is required (https://github.com/casey/just). On macOS:  brew install just
# On Linux:                                                       cargo install just
#
# Quick map of common targets:
#   just                          show available recipes
#   just build                    build both plugins
#   just gen                      regenerate examples/expected/{full,runtime}/*
#   just test                     run the luatest suite
#   just bench                    alloc + throughput per op
#   just conformance              run Google's conformance suite in Docker
#   just examples                 per-example runners (see examples/Justfile)
#
# Sub-recipes live in examples/Justfile (one target per runnable example).

set shell := ["bash", "-cu"]

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

plugin            := "protoc-gen-tarantool"
doc_plugin        := "protoc-gen-tarantool-doc"
gen_dir           := "examples/expected"
docs_dir          := "examples/docs"
proto_dir         := "examples/proto"
conformance_proto := "test/conformance/proto"
proto2_test_dir   := "test/proto"
luatest           := ".rocks/bin/luatest"
image             := "tarantool-protobuf-conformance:latest"

# pb.server serves over the tarantool-http2 rock (`require('http2')`). Until
# the rock is published, point TARANTOOL_HTTP2_RUNTIME at the `runtime/`
# directory of a tarantool-http2 checkout; it is appended to LUA_PATH for
# the test, example and Go end-to-end recipes. Unset, `http2` is looked up
# as usual (e.g. installed with `tt rocks make`), and the tests that need
# a server skip when it cannot be loaded.
http2_runtime := env_var_or_default("TARANTOOL_HTTP2_RUNTIME", "")
http2_lua_path := if http2_runtime == "" { "" } else { http2_runtime + "/?.lua;" + http2_runtime + "/?/init.lua;" }

# Semicolon-joined LUA_PATH for the luatest suite. Trailing `;;` defers to the
# standard package.path for everything not explicitly listed.
lua_path := "./runtime/?/init.lua;./runtime/?.lua;./" + gen_dir + "/?.lua;./" + gen_dir + "/?/init.lua;./?.lua;./?/init.lua;./test/?.lua;" + http2_lua_path + ";"

# LUA_CPATH for the optional C runtime (require('pb.c_runtime')). Trailing
# `;;` defers to the standard cpath. The C module is built into
# runtime/pb/c_runtime.{so,dylib} by `just build-c` when PB_ENABLE_C=1 is
# in play; absent without it. See docs/specs/c_accel_build_packaging.md.
#
# `.dylib` is searched before `.so` because `package.searchpath` returns
# the first existing file (not the first loadable one). If both exist
# (e.g., a Linux `.so` left in the working tree by `just conformance-c`,
# which builds inside the bind-mounted container), macOS dlopen would
# fail on the foreign ELF without ever trying the local `.dylib`. Linux
# never produces a `.dylib` so the order is harmless there.
lua_cpath := "./runtime/?.dylib;./runtime/?.so;./runtime/?/init.dylib;./runtime/?/init.so;;"

# ---------------------------------------------------------------------------
# Default
# ---------------------------------------------------------------------------

# Show available recipes.
default:
    @just --list

# Build everything from scratch and run the test suite.
all: build gen test

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Build the Lua codegen plugin (./protoc-gen-tarantool).
build:
    go build -o {{plugin}} ./cmd/protoc-gen-tarantool

# Build the Markdown doc plugin (./protoc-gen-tarantool-doc).
build-doc:
    go build -o {{doc_plugin}} ./cmd/protoc-gen-tarantool-doc

# Build the optional C-acceleration runtime into runtime/pb/c_runtime.{so,dylib}.
# The runtime is opt-in via PB_ENABLE_C=1 — see docs/specs/c_accel_build_packaging.md
# for the full contract.
build-c:
    make -C runtime/pb/c

# Remove built C-runtime artifacts.
clean-c:
    rm -f runtime/pb/c_runtime.so runtime/pb/c_runtime.dylib
    @if [ -d runtime/pb/c ]; then make -C runtime/pb/c clean; fi

# ---------------------------------------------------------------------------
# Codegen
# ---------------------------------------------------------------------------

# Regenerate examples/expected/{full,runtime}/* + conformance protos.
gen: gen-full gen-runtime gen-conformance gen-proto2-tests gen-int64-as-number gen-builtin-descriptors gen-grpc-services

# Regenerate runtime/pb/gen/: the gRPC reflection (v1, v1alpha) and health
# services from the vendored upstream protos (third_party/grpc-proto),
# compiled by this plugin. pb.reflection and pb.health build on them.
gen-grpc-services: build
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out=runtime \
        --tarantool_opt=mode=runtime,prefix=pb.gen \
        -I third_party/grpc-proto \
        third_party/grpc-proto/grpc/reflection/v1/reflection.proto \
        third_party/grpc-proto/grpc/reflection/v1alpha/reflection.proto \
        third_party/grpc-proto/grpc/health/v1/health.proto

# Regenerate runtime/pb/descriptors_builtin.lua: the FileDescriptorProto
# bytes of the well-known types and google/api/{annotations,http}.proto
# that pb.descriptors ships, as the host protoc serializes them (its
# version goes into the file header). Keep the host protoc at the same
# release as PROTOBUF_TAG in docker/conformance.Dockerfile — the same
# rule as for `just gen`; nothing checks it automatically.
gen-builtin-descriptors:
    go run ./cmd/gen-builtin-descriptors -I options > runtime/pb/descriptors_builtin.lua.tmp
    mv runtime/pb/descriptors_builtin.lua.tmp runtime/pb/descriptors_builtin.lua

# Generate full-mode Lua (inline encode/decode bodies).
gen-full: build
    mkdir -p {{gen_dir}}
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=full,prefix=full \
        -I {{proto_dir}} -I options \
        {{proto_dir}}/*.proto

# Generate runtime-mode Lua (delegates to pb.encode / pb.decode).
gen-runtime: build
    mkdir -p {{gen_dir}}
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=runtime,prefix=runtime \
        -I {{proto_dir}} -I options \
        {{proto_dir}}/*.proto

# Generate the Google conformance protos (TestAllTypesProto3) in both modes.
gen-conformance: build
    mkdir -p {{gen_dir}}
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=full,prefix=full \
        -I {{conformance_proto}} -I options \
        {{conformance_proto}}/*.proto
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=runtime,prefix=runtime \
        -I {{conformance_proto}} -I options \
        {{conformance_proto}}/*.proto

# Generate the proto2 test fixtures (test/proto/*.proto) in both modes.
# Lives outside examples/ because proto2 is exercised through the luatest
# suite, not the per-example runners.
gen-proto2-tests: build
    mkdir -p {{gen_dir}}
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=full,prefix=full \
        -I {{proto2_test_dir}} -I options \
        {{proto2_test_dir}}/*.proto
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=runtime,prefix=runtime \
        -I {{proto2_test_dir}} -I options \
        {{proto2_test_dir}}/*.proto

# Generate the c_int64 fixture into examples/expected/full_n/ with the
# `int64_as_number=true` codegen flag set, so the opt-in int64_as_number path has a
# parallel fixture for round-trip + type-stability tests next to the
# default full/ output. Single fixture is enough to cover the codegen
# surface; no need to double the entire examples/expected/full/ tree.
gen-int64-as-number: build
    mkdir -p {{gen_dir}}
    protoc \
        --plugin=./{{plugin}} \
        --tarantool_out={{gen_dir}} \
        --tarantool_opt=mode=full,prefix=full_n,int64_as_number=true \
        -I {{proto2_test_dir}} -I options \
        {{proto2_test_dir}}/c_int64.proto

# Regenerate Markdown reference docs (examples/docs/*.md) — committed output.
gen-docs: build-doc
    mkdir -p {{docs_dir}}
    protoc \
        --plugin=./{{doc_plugin}} \
        --tarantool-doc_out={{docs_dir}} \
        -I {{proto_dir}} -I options \
        {{proto_dir}}/*.proto

# Regenerate test/interop/fixtures/*.bin via mainline `protoc --encode`.
goldens:
    @for f in test/interop/fixtures/*.txtpb; do \
        type=$(awk '/^# type:/ {print $3; exit}' "$f"); \
        out="${f%.txtpb}.bin"; \
        echo "  protoc --encode=$type < $f > $out"; \
        protoc --encode="$type" -I {{proto_dir}} -I options {{proto_dir}}/hello.proto < "$f" > "$out" || exit $?; \
    done

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

# Run the luatest suite (639 tests, parametrized over both codegen modes).
test: gen
    LUA_PATH="{{lua_path}}" LUA_CPATH="{{lua_cpath}}" {{luatest}} -v test/

# Run a single luatest group or test. Example:
#   just test-one protobuf_test.lua::hello.full.test_packed_repeated_int32
test-one filter: gen
    LUA_PATH="{{lua_path}}" LUA_CPATH="{{lua_cpath}}" {{luatest}} -v test/{{filter}}

# Same as `test`, but with PB_ENABLE_C=1 so pb.encode / pb.decode dispatch
# through the C runtime (runtime/pb/c_runtime.{so,dylib}). Builds the C
# module first. Together with `test`, this is the parity gate — every
# luatest assertion is against a reference output (golden bytes, txtpb,
# conformance result), so if Lua passes and C passes, both equal the
# reference and Lua ≡ C by transitivity.
test-c: build-c gen
    PB_ENABLE_C=1 LUA_PATH="{{lua_path}}" LUA_CPATH="{{lua_cpath}}" {{luatest}} -v test/

# Parity gate: run the suite under both codecs. Use before pushing C-runtime
# or codec changes.
test-all: test test-c

# Check pb.reflection against an independent consumer: grpc-go's reflection
# types decode the responses and protodesc links every returned file
# (test/reflection-go). `protolegacy` lets protodesc accept the MessageSet
# in the conformance fixtures.
test-reflection-go: gen
    cd test/reflection-go && go test -tags protolegacy -v -count=1 ./...

# Check pb.server against independent clients (test/server-go): grpc-go
# with dynamicpb messages built from server reflection alone, grpc-go's
# health client, net/http over HTTP/1.1 and h2c, and grpcurl (built into a
# temporary GOBIN). Needs the http2 rock: see TARANTOOL_HTTP2_RUNTIME above.
test-server-go: gen
    cd test/server-go && TARANTOOL_HTTP2_RUNTIME="{{http2_runtime}}" go test -v -count=1 ./...

# ---------------------------------------------------------------------------
# Bench
# ---------------------------------------------------------------------------

# Microbench: alloc + throughput per op across 5 payload sizes, both modes.
bench: gen
    tarantool bench/bench.lua --print

# Same as `bench`, but with PB_ENABLE_C=1 so the runtime-mode results
# exercise the C codec. The runtime-mode column is relabelled to
# `c-runtime` in the output. Full-mode results are unchanged (full mode
# uses inline wire calls, not pb.encode). Allocation baselines (`bench-baseline`
# / `bench-compare`) remain Lua-only — C alloc shape differs by design
# and would noise the gate.
bench-c: build-c gen
    PB_ENABLE_C=1 tarantool bench/bench.lua --print

# Overwrite bench/baseline.json with current alloc-per-op numbers.
bench-baseline: gen
    tarantool bench/bench.lua --baseline

# Fail with exit 1 if any alloc-per-op regressed >5% vs the baseline.
bench-compare: gen
    tarantool bench/bench.lua --compare

# Per-helper microbench for runtime/pb/wire.lua (every primitive).
bench-wire: gen
    tarantool bench/wire_bench.lua

# Shape-variety microbench (scalar-heavy, packed, nested, maps, oneof, WKT).
bench-shapes: gen
    tarantool bench/shapes_bench.lua

# Range-shaped encode, Put-shaped decode/replace, nested-map name
# matching; each candidate is checked against its baseline before timing.
#
# Tuple bridge (pb.tuple) versus per-row Lua tables.
bench-tuple: gen
    tarantool bench/tuple_bench.lua

# The baselines' pb.encode / pb.decode go through the C codec as well.
#
# Same as `bench-tuple`, with PB_ENABLE_C=1.
bench-tuple-c: build-c gen
    PB_ENABLE_C=1 tarantool bench/tuple_bench.lua

# Trace-stability gate: assert hot paths JIT-compile without fatal aborts.
jit-trace: gen
    tarantool bench/jit_trace.lua

# Regenerate Go-side pb.go + vtproto pb.go in bench/go/pb/. Not committed
# (*.pb.go is gitignored repo-wide); run before `bench-go` on a fresh
# checkout. Requires `protoc-gen-go` and `protoc-gen-go-vtproto` on PATH:
#   go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#   go install github.com/planetscale/vtprotobuf/cmd/protoc-gen-go-vtproto@latest
gen-go:
    mkdir -p bench/go/pb/hellopb bench/go/pb/proto2pb
    cd bench/go && PATH="$(go env GOPATH)/bin:$PATH" protoc \
        --go_out=. --go_opt=module=github.com/tarantool-protobuf/bench/go \
        --go-vtproto_out=. --go-vtproto_opt=module=github.com/tarantool-protobuf/bench/go \
        --go-vtproto_opt=features=marshal+unmarshal+size \
        -I proto proto/hello.proto proto/proto2_basic.proto

# Go-side comparison bench: same fixtures + sizes as bench.lua, run against
# google.golang.org/protobuf (apiv2) and planetscale/vtprotobuf. Serial by
# default — Go's testing.B doesn't parallelize unless RunParallel is called.
bench-go: gen-go
    cd bench/go && go test -bench=. -benchmem -run=^$ -benchtime=1s ./...

# ---------------------------------------------------------------------------
# Conformance (Google's protobuf conformance suite, in Docker)
# ---------------------------------------------------------------------------

# Build the conformance Docker image (idempotent).
conformance-build:
    docker build -t {{image}} -f docker/conformance.Dockerfile docker/

# Runner flags shared by the strict conformance recipes.
conformance_flags := "--enforce_recommended --failure_list test/conformance/known_failures.txt --text_format_failure_list test/conformance/known_failures_text.txt"
conformance_testee := "/usr/bin/tarantool cmd/conformance-runner.lua"

# The --performance pass is not a stricter setting but a disjoint set of
# tests the default run never executes: merging 50000 occurrences of a
# message field in the binary and text formats, and messages nested
# 20000 levels deep against the recursion limit. The runner stops after
# the first failing suite, so a binary failure hides the text results of
# the same pass.
#
# Run the conformance suite with --enforce_recommended, default + --performance.
conformance: conformance-build gen
    docker run --rm -v "$(pwd):/work" -w /work {{image}}
    docker run --rm -v "$(pwd):/work" -w /work {{image}} {{conformance_flags}} --performance {{conformance_testee}}

# Only the --performance pass of `conformance`.
conformance-perf: conformance-build gen
    docker run --rm -v "$(pwd):/work" -w /work {{image}} {{conformance_flags}} --performance {{conformance_testee}}

# Builds runtime/pb/c_runtime.so inside the container (host .dylib won't
# load there), then runs both passes with PB_ENABLE_C=1 so pb/init.lua
# dispatches to the C codec.
#
# Same as `conformance`, but through the C-acceleration path.
conformance-c: conformance-build gen
    docker run --rm -v "$(pwd):/work" -w /work -e PB_ENABLE_C=1 \
        --entrypoint bash {{image}} -c '\
            set -e; \
            make -C runtime/pb/c clean >/dev/null; \
            make -C runtime/pb/c >/dev/null; \
            rc=0; \
            for pass in "" --performance; do \
                conformance_test_runner {{conformance_flags}} $pass \
                    {{conformance_testee}} || rc=$?; \
            done; \
            make -C runtime/pb/c clean >/dev/null; \
            exit $rc'

# Quick pass without --enforce_recommended.
conformance-quick: conformance-build gen
    docker run --rm -v "$(pwd):/work" -w /work --entrypoint conformance_test_runner {{image}} \
        --failure_list test/conformance/known_failures.txt \
        --text_format_failure_list test/conformance/known_failures_text.txt \
        /usr/bin/tarantool cmd/conformance-runner.lua

# Dump failing_tests.txt under test/conformance for triage.
conformance-refresh-failures: conformance-build gen
    docker run --rm -v "$(pwd):/work" -w /work --entrypoint conformance_test_runner {{image}} \
        --enforce_recommended \
        --output_dir /work/test/conformance \
        /usr/bin/tarantool cmd/conformance-runner.lua || true
    @echo "Inspect test/conformance/*failing_tests.txt and update known_failures.txt as needed."

# Open an interactive shell in the conformance image.
conformance-shell: conformance-build
    docker run --rm -it -v "$(pwd):/work" -w /work --entrypoint bash {{image}}

# ---------------------------------------------------------------------------
# Examples — see examples/Justfile for per-example runners
# ---------------------------------------------------------------------------

# Run an example. `just examples` lists per-example recipes.
examples *ARGS:
    just -f examples/Justfile {{ARGS}}

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

# Remove built plugin binaries and regenerated outputs.
clean: clean-c
    rm -f {{plugin}} {{doc_plugin}}
    rm -rf {{gen_dir}}

# Remove Tarantool instance state that leaked from running examples.
clean-state:
    rm -f *.snap *.xlog *.vylog *.run *.pid 512.lock
    rm -rf /tmp/tarantool-protobuf-*
