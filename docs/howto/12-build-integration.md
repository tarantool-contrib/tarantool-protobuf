# How-to: build integration

Driving `protoc-gen-tarantool` from build systems. The plugin is a
standard `protoc` plugin — anything that invokes `protoc` can invoke
it. This repo's canonical wrapper is the **Justfile**; recipes for
other build tools below.

For the canonical `protoc` flags, see
[reference/cli.md](../reference/cli.md).

## `tarantool-protobuf`'s own build (Justfile)

```bash
just build         # build the codegen plugin
just gen           # regenerate examples/expected/{full,runtime}/...
just gen-docs      # regenerate examples/docs/hello.md
just test          # luatest suite
just clean         # remove plugin + examples/expected/
```

See `just --list` for the full set.

## Plain `protoc`

The minimum:

```bash
protoc \
    -I. \
    -Ioptions \
    --tarantool_out=./gen \
    path/to/foo.proto path/to/bar.proto
```

Assumes `protoc-gen-tarantool` is on `PATH`. If not:

```bash
protoc \
    --plugin=protoc-gen-tarantool=./bin/protoc-gen-tarantool \
    --tarantool_out=./gen \
    ...
```

Pass options via `--tarantool_opt=key=value,key=value`:

```bash
protoc --tarantool_out=./gen --tarantool_opt=mode=runtime,prefix=vendor ...
```

## Makefile (legacy / external projects)

Example pattern for a downstream project that still uses Make:

```make
PROTOC      ?= protoc
GEN_DIR     := gen
PROTO_FILES := $(wildcard proto/**/*.proto)

.PHONY: gen
gen: protoc-gen-tarantool
	$(PROTOC) \
		-I. \
		-Ioptions \
		--tarantool_out=$(GEN_DIR) \
		--tarantool_opt=mode=full \
		$(PROTO_FILES)

protoc-gen-tarantool:
	go build -o $@ ./cmd/protoc-gen-tarantool

.PHONY: clean
clean:
	rm -rf $(GEN_DIR)
```

For incremental builds, gate per-file:

```make
$(GEN_DIR)/%/foo_pb.lua: proto/%/foo.proto protoc-gen-tarantool
	$(PROTOC) -I. -Ioptions --tarantool_out=$(GEN_DIR) $<
```

## Justfile

`tarantool-protobuf` itself ships a `Justfile` as the canonical entry
point (`just build`, `just gen`, `just test`, `just bench`,
`just conformance`, `just examples`, …). A downstream user-project
pattern:

```just
default:
    @just --list

build-plugin:
    go build -o ./bin/protoc-gen-tarantool ./vendor/tarantool-protobuf/cmd/protoc-gen-tarantool

gen: build-plugin
    PATH=./bin:$PATH protoc \
        -I. -Ivendor/tarantool-protobuf/options \
        --tarantool_out=./gen \
        proto/**/*.proto

clean:
    rm -rf gen
```

## `buf`

`buf generate` reads a `buf.gen.yaml`:

```yaml
version: v1
plugins:
  - plugin: tarantool
    out: gen
    opt:
      - mode=full
    path: ./bin/protoc-gen-tarantool
```

Then `buf generate`. `buf` discovers protos via `buf.yaml` (or
`buf.work.yaml` for monorepos) and runs the plugin for each.

The plugin doesn't depend on `buf` features beyond what every `protoc`
plugin sees, so `buf generate` is a drop-in for `protoc` if your team
prefers it.

## CMake

```cmake
find_package(Protobuf REQUIRED)
find_program(PROTOC_GEN_TARANTOOL protoc-gen-tarantool REQUIRED)

set(PROTO_FILES proto/foo.proto proto/bar.proto)
set(GEN_DIR ${CMAKE_BINARY_DIR}/gen)
file(MAKE_DIRECTORY ${GEN_DIR})

add_custom_command(
    OUTPUT ${GEN_DIR}/.stamp
    COMMAND ${Protobuf_PROTOC_EXECUTABLE}
            --plugin=protoc-gen-tarantool=${PROTOC_GEN_TARANTOOL}
            -I${CMAKE_SOURCE_DIR}
            -I${CMAKE_SOURCE_DIR}/vendor/tarantool-protobuf/options
            --tarantool_out=${GEN_DIR}
            ${PROTO_FILES}
    COMMAND ${CMAKE_COMMAND} -E touch ${GEN_DIR}/.stamp
    DEPENDS ${PROTO_FILES} ${PROTOC_GEN_TARANTOOL}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_custom_target(protos ALL DEPENDS ${GEN_DIR}/.stamp)
```

## Generating once, distributing as a binary blob

For deployments where `protoc` shouldn't run on every Tarantool host,
generate at build time and ship the `.lua` files (or a
`FileDescriptorSet` binary).

```bash
# At build time, ship pre-generated Lua:
protoc --tarantool_out=./dist/lua ...
tar czf myapp-protos.tar.gz dist/lua

# Or, ship a binary descriptor set for runtime ingestion:
protoc --descriptor_set_out=./dist/schemas.pb \
       --include_imports \
       proto/**/*.proto
# At Tarantool startup:
local pb = require('pb')
local set = pb.from_pb(io.open('dist/schemas.pb', 'rb'):read('*a'))
```

The descriptor-set approach is what makes
[dynamic schemas](08-dynamic-schemas.md) possible without running
`protoc` in production.

## Vendoring the plugin source

If you'd rather not depend on a published binary:

1. Vendor this repo (or just the `cmd/protoc-gen-tarantool` +
   `options/` + `runtime/pb/` directories) into your project.
2. Build the plugin as part of your top-level build (`go build` step).
3. Drop the resulting binary on `PATH` for `protoc` to find it.

The plugin's only runtime dependency is the `runtime/pb/` Lua module
set — that needs to land on `LUA_PATH` in production. See
[how-to: module layout → wiring LUA_PATH](02-module-layout.md#wiring-lua_path).

## CI: regenerate-and-diff

A cheap CI guard: regenerate Lua from `.proto` and fail the build if
the working tree changed.

```yaml
# .github/workflows
- run: just gen
- run: git diff --exit-code
```

This catches the "proto changed but generated Lua wasn't updated"
class of bug, which `protoc` itself won't notice.

## What's next

- [Reference: CLI](../reference/cli.md) — every flag, file option,
  path-resolution rule.
- [How-to: dynamic schemas](08-dynamic-schemas.md) — the
  no-codegen path.
- [How-to: module layout](02-module-layout.md) — what `prefix`,
  `lua_package`, and `LUA_PATH` do.
