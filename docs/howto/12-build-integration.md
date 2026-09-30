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

[`buf`](https://buf.build/docs/) runs `protoc-gen-tarantool` as a
local plugin; nothing in the plugin is specific to `protoc`. The
snippets below use the v2 configuration (buf 1.32 and later) and a
project laid out like this:

```
buf.yaml
buf.gen.yaml
buf.lock                               # written by `buf dep update`
bin/protoc-gen-tarantool               # the plugin, built from this repo
proto/shop/v1/shop.proto               # your schema
third_party/tarantool/tarantool.proto  # copied from options/tarantool/
```

The schema uses both kinds of option this plugin reads,
`google.api.http` rules ([how-to 15](15-http-transcoding.md)) and
`(tarantool.lua_package)`:

```proto
syntax = "proto3";

package shop.v1;

import "google/api/annotations.proto";
import "tarantool/tarantool.proto";

option (tarantool.lua_package) = "shop.shop_pb";

message Item {
  string name = 1;
  int64 price = 2;
}

message GetItemRequest {
  string name = 1;
}

service Shop {
  rpc GetItem(GetItemRequest) returns (Item) {
    option (google.api.http) = {get: "/v1/{name=items/*}"};
  }
}
```

### `buf.yaml`: where imports come from

```yaml
version: v2
modules:
  - path: proto
  - path: third_party
deps:
  - buf.build/googleapis/googleapis
```

- **`google/api/annotations.proto`** comes from the
  [`buf.build/googleapis/googleapis`](https://buf.build/googleapis/googleapis)
  module on the Buf Schema Registry, the usual source under `buf`. Run
  `buf dep update` once to resolve it into `buf.lock` and commit both
  files; public modules need no login.
- **`tarantool/tarantool.proto`** (the `(tarantool.lua_package)`
  option) is not published as a registry module. Copy
  `options/tarantool/tarantool.proto` from this repository into a
  directory that is one of your modules, keeping the `tarantool/`
  directory so the import path stays `tarantool/tarantool.proto`. Skip
  it if you do not use `lua_package`.
- **Well-known types** (`google/protobuf/*.proto`) are built into
  `buf`; nothing to add.

Without the registry (offline builds, air-gapped CI), make this
repository's `options/` directory a module instead of the `deps`
entry. It carries `google/api/annotations.proto`, `google/api/http.proto`
and `tarantool/tarantool.proto`:

```yaml
version: v2
modules:
  - path: proto
  - path: vendor/tarantool-protobuf/options
```

Use one source or the other: with both, `buf` refuses to build
(`google/api/annotations.proto is contained in multiple modules`).

### `buf.gen.yaml`: running the plugin

```yaml
version: v2
plugins:
  - local: ./bin/protoc-gen-tarantool
    out: gen
    opt:
      - mode=full
    strategy: all
inputs:
  - directory: proto
```

- `local:` is a path to the plugin binary, or its name when it is on
  `PATH` (`local: protoc-gen-tarantool`).
- `opt:` takes the `--tarantool_opt` keys, one `key=value` per item:
  `mode` (`full` or `runtime`), `prefix`, `int64_as_number` — see
  [reference/cli.md](../reference/cli.md#--tarantool_opt). For
  example `[mode=runtime, prefix=app]` writes
  `gen/app/shop/shop_pb.lua`.
- `strategy: all` runs the plugin once for every file, like a single
  `protoc` call. The default (`directory`, one run per directory)
  produces the same modules.
- `inputs: - directory: proto` generates your module only; the
  `third_party` module and the `googleapis` dependency just resolve
  imports. Name a module directory as an input, not in `paths:` —
  `buf` rejects a module path there
  (`module "proto" was specified with --path`).

Then:

```bash
buf dep update     # once, and whenever deps change
buf generate       # writes gen/shop/shop_pb.lua
```

Put `gen/` on `LUA_PATH` next to the runtime and the module works as
with `protoc`:

```lua
local shop = require('shop.shop_pb')
local item = shop.Item_decode(shop.Item_encode({name = 'pen', price = 3}))
assert(item.name == 'pen' and item.price == 3LL)
print(shop.Shop_service.methods.GetItem.http[1].pattern)  -- /v1/{name=items/*}
```

### Differences from `protoc` output

Only one: each generated module embeds its `FileDescriptorProto`
exactly as the compiler serialized it (server reflection serves those
bytes), and `buf` writes the fields of option messages in a different
order than `protoc` does (a `google.api.http` rule's `body` before
`post`, for instance). The two descriptors decode to the same thing,
and the generated code is the same. `just test-buf` checks this for
the examples in this repository.

To call a running [`pb.server`](16-network-server.md) with
`buf curl`, see [how-to 16](16-network-server.md#3-talk-to-it).

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
