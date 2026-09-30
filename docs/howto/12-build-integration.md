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
  option) is not published as a registry module yet (see
  [Using the options module](#using-the-options-module)). Copy
  `options/tarantool/tarantool.proto` from this repository into a
  directory that is one of your modules, keeping the `tarantool/`
  directory so the import path stays `tarantool/tarantool.proto`. Skip
  it if you do not use `lua_package`.
- **Well-known types** (`google/protobuf/*.proto`) are built into
  `buf`; nothing to add.

Without the registry (offline builds, air-gapped CI), make this
repository's `third_party/googleapis/` directory a module instead of
the `deps` entry. It carries `google/api/annotations.proto` and
`google/api/http.proto`; the repository's `options/` directory, which
carries only `tarantool/tarantool.proto`, can stand in for the copy:

```yaml
version: v2
modules:
  - path: proto
  - path: vendor/tarantool-protobuf/options
  - path: vendor/tarantool-protobuf/third_party/googleapis
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

## EasyP

[EasyP](https://easyp.tech/) is an alternative to `buf` with one
`easyp.yaml` for linting (buf-compatible rules), breaking-change
checks, dependencies and generation. Dependencies are git repositories
(`github.com/org/repo@<tag or commit>`), not registry modules. It has
no counterpart of `buf curl`; use grpcurl or `buf curl` against the
server.

The same schema as in the `buf` section, laid out for EasyP:

```
easyp.yaml
easyp.lock                        # written by `easyp mod download`
bin/protoc-gen-tarantool
proto/shop/v1/shop.proto          # the schema from the buf section
proto/tarantool/tarantool.proto   # copied from options/tarantool/
```

```yaml
lint:
  use:
    - MINIMAL
    - BASIC
  ignore:
    - tarantool

deps:
  - github.com/googleapis/googleapis@93d6085996d0b4ff7e7e86ca9945d5524bb380d1

generate:
  inputs:
    - directory:
        path: .
        root: proto
  plugins:
    - path: ./bin/protoc-gen-tarantool
      out: gen
      opts:
        mode: full
```

```bash
easyp validate-config
easyp mod download        # fetches googleapis, pins it in easyp.lock
easyp generate            # writes gen/shop/shop_pb.lua
easyp lint --root proto
```

- **`google/api/annotations.proto`** comes from the googleapis git
  repository, whose files sit at the import paths. Pin a commit: its
  only tag, `common-protos-1_3_1`, carries an `http.proto` without
  `response_body`. `easyp.lock` records what was fetched; commit it.
- **Inputs.** `path` is relative to `root`, and `root` is the import
  root, so `root: proto` names the file `shop/v1/shop.proto` as
  `protoc -I proto` does. The short form `- directory: proto` makes
  the project directory the import root instead: the file becomes
  `proto/shop/v1/shop.proto`, imports of local files need the
  `proto/` prefix (the `tarantool/tarantool.proto` import above no
  longer resolves), and server reflection shows those names.
- **`tarantool/tarantool.proto`** sits inside the input root: `easyp
  lint` resolves imports only from its `--root`, the dependencies and
  the well-known types, not from other inputs. EasyP generates every
  file under an input, so it also writes an unused
  `gen/tarantool/tarantool_pb.lua`; `ignore: [tarantool]` keeps the
  copy out of the lint (it fails `PACKAGE_VERSION_SUFFIX` under
  `DEFAULT`). A git dependency on this repository replaces the copy
  from the first release that ships the options module (see
  [Using the options module](#using-the-options-module)); at earlier
  revisions EasyP installs the file under its repository path,
  `options/tarantool/tarantool.proto`, so `import
  "tarantool/tarantool.proto"` does not resolve.
- `opts:` is a map of the `--tarantool_opt` keys (`mode`, `prefix`,
  `int64_as_number`).
- Well-known types are built in.

The generated modules load like the `buf` ones. As with `buf`, only
the embedded descriptors differ from `protoc` output, in the order of
option fields; `just test-easyp` checks the examples.

## Using the options module

The `options/` directory of this repository is a module of its own:
`tarantool/tarantool.proto`, which defines `(tarantool.lua_package)`,
and nothing else. The `buf.yaml` at the repository root names it
`buf.build/tarantool-contrib/tarantool-protobuf`. The copies of
`google/api/annotations.proto` and `google/api/http.proto` this
repository builds its examples with live in `third_party/googleapis/`,
outside the module, so they never compete with the googleapis module
or repository your project takes `google/api` from.

With the module as a dependency, the copy of `tarantool/tarantool.proto`
in the `buf` and EasyP layouts above goes away; the import stays
`import "tarantool/tarantool.proto";`.

### With `buf`

**The module is not published on the Buf Schema Registry yet.** Once it
is, list it next to googleapis in `buf.yaml` and run `buf dep update`:

```yaml
version: v2
modules:
  - path: proto
deps:
  - buf.build/googleapis/googleapis
  - buf.build/tarantool-contrib/tarantool-protobuf
```

Until then, make `options/` of a checkout of this repository (a git
submodule, for instance) one of your modules; it builds together with
googleapis from the registry:

```yaml
version: v2
modules:
  - path: proto
  - path: vendor/tarantool-protobuf/options
deps:
  - buf.build/googleapis/googleapis
```

When the registry module becomes available, replace the `modules`
entry with the `deps` entry rather than adding it: a file in a local
module and in a dependency at once fails the build
(`tarantool/tarantool.proto is contained in multiple modules`).

### With EasyP

Add a git dependency on this repository at a release tag (or a
commit) next to googleapis:

```yaml
deps:
  - github.com/googleapis/googleapis@93d6085996d0b4ff7e7e86ca9945d5524bb380d1
  - github.com/tarantool-contrib/tarantool-protobuf@<tag>

generate:
  inputs:
    - directory:
        path: .
        root: proto
  plugins:
    - path: ./bin/protoc-gen-tarantool
      out: gen
      opts:
        mode: full
```

EasyP reads the root `buf.yaml` of a dependency and strips the module
path from its files, so `options/tarantool/tarantool.proto` installs as
`tarantool/tarantool.proto`. The other `.proto` files of the repository
(examples, test fixtures, `third_party/`) install under their
repository paths, where they cannot shadow an import of yours;
`google/api` still comes from googleapis. A dependency is neither
generated nor linted, so there is no `gen/tarantool/tarantool_pb.lua`
and no `ignore: [tarantool]` to add.

**This works from the first release that carries the root `buf.yaml`;
no such release exists yet.** At an older tag the file installs as
`options/tarantool/tarantool.proto` and the import does not resolve:
keep the copy under `proto/` until then.

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
