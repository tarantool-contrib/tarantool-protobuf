# tarantool-protobuf

A `protoc` plugin and pure-Lua runtime for using Protocol Buffers (proto2 +
proto3) and gRPC service stubs from [Tarantool](https://www.tarantool.io/).

Tarantool ships an in-tree `require('protobuf')` module, but it is
**encode-only** and has no support for `map`, `oneof`, services, or any decode
path. This project fills those gaps with:

- **`protoc-gen-tarantool`** — a protoc plugin (Go) that turns `.proto` files
  into Lua modules.
- **`runtime/pb`** — a pure Lua + LuaJIT-FFI runtime the generated code uses
  for the wire format. Named `pb` rather than `protobuf` to avoid colliding
  with Tarantool's built-in module.

## Status

Proto2 + proto3 conformance is closed: every `Required.*` and `Recommended.*`
test in both the binary+JSON and text-format suites passes. The proto2
slice covers `required`/`optional`/`repeated` cardinalities, custom
defaults, closed enums, legacy `group` fields (SGROUP/EGROUP wire types),
and extensions (`extend`/`extensions`), including the legacy MessageSet
wire format. Only editions are out of scope for now.

| Feature                          | State        |
|----------------------------------|--------------|
| proto3 scalars (all 15 types)    | ✅           |
| Repeated, packed by default      | ✅           |
| Nested messages, self-reference  | ✅           |
| Cross-file imports               | ✅           |
| Enums (open semantics)           | ✅           |
| 64-bit integers as LuaJIT cdata  | ✅           |
| Opt-in 64-bit-as-Lua-number decode (`int64_as_number=true`) | ✅ |
| Two codegen modes (full + runtime) | ✅         |
| Zero-copy lazy decode views      | ✅           |
| `map<K,V>` (scalar/message values) | ✅         |
| `oneof`                          | ✅           |
| proto3 explicit `optional` + `has_*`/`clear_*` | ✅ |
| `-0.0` preserved for float/double | ✅          |
| gRPC service stubs (unary)       | ✅           |
| gRPC streaming (server / client / bidi) | ✅      |
| Loopback / multiplex transport   | ✅           |
| gRPC status codes + status errors (`pb.grpc.error`) | ✅ |
| `google.api.http` rules in service descriptors | ✅ |
| gRPC server reflection v1 / v1alpha (`pb.reflection`) | ✅ |
| gRPC health service (`pb.health`) | ✅ |
| HTTP/JSON transcoding by `google.api.http` rules (`pb.transcode`) | ✅ |
| gRPC over HTTP/2 (h2c) network server, all four call kinds (`pb.server`)¹ | ✅ |
| HTTP/JSON transcoding over HTTP/1.1 and HTTP/2 on the gRPC port (`pb.server`)¹ | ✅ |
| Reflection and health served over the network (`pb.server`)¹ | ✅ |
| Connect protocol on the same port: unary POST + GET, client / server / half-duplex bidi streams (`pb.connect`)¹ | ✅ |
| Connect full-duplex bidi and incremental server streams | ❌ needs a streaming HTTP handler in tarantool-http2 |
| **Connect conformance suite (server mode, Connect + gRPC)** | **516 ✓**, 72 known failures (Connect full-duplex, tarantool-http2) |
| WKT: Timestamp ↔ `datetime`      | ✅           |
| WKT: Duration, Empty, wrappers   | ✅           |
| WKT: Struct, Value, ListValue    | ✅           |
| WKT: Any (opaque + registry pack/unpack) | ✅   |
| WKT: FieldMask (strict round-trip) | ✅         |
| Byte-for-byte interop with `protoc` (10 fixtures) | ✅ |
| **Google conformance suite — binary + JSON**       | **2817 ✓ / 0 failures** |
| **Google conformance suite — text format**         | **445 ✓ / 0 failures** |
| **Google conformance suite — `--performance`**     | **55 ✓ / 0 failures** (1 editions test skipped) |
| Runtime `.proto` parsing (`pb.parse`) | ✅       |
| Runtime `FileDescriptorSet` ingest (`pb.from_pb`) | ✅ |
| Tuple ↔ wire in one call per row (`pb.tuple`; no Lua table per row with the C runtime) | ✅ |
| Markdown doc generator (`protoc-gen-tarantool-doc`) | ✅ |
| proto3 JSON (`pb.json.encode`/`.decode`) | ✅    |
| Text format (`pb.text.encode` / `pb.text.decode`) | ✅ |
| Unknown-field passthrough (`_unknown_fields`)    | ✅ |
| Microbenchmark + alloc regression gate (`just bench`) | ✅ |
| proto2 `required` / `optional` / custom `[default = X]` | ✅ |
| proto2 repeated unpacked-by-default + `[packed = true]` | ✅ |
| proto2 `group` (SGROUP/EGROUP wire types) | ✅   |
| proto2 extensions / `extend` blocks       | ✅   |
| proto2 closed enums                       | ✅   |
| `MessageSet` wire format (`message_set_wire_format`) | ✅ |
| Editions                                  | ❌ deferred |

¹ Requires the tarantool-http2 rock (HTTP/2 and HTTP/1.1 over the system
`libnghttp2`); see [Serving gRPC and HTTP/JSON](#serving-grpc-and-httpjson).

## Install

There is no published rock yet, so install from a local checkout:

```bash
git clone https://github.com/tarantool-contrib/tarantool-protobuf.git && cd tarantool-protobuf
tt rocks make tarantool-protobuf-scm-1.rockspec
```

That puts the `pb.*` runtime modules under `.rocks/share/tarantool/`.
The Go plugin still has to be built separately — see "Quick start"
below.

## Quick start

```bash
# 1. Build the plugin and generate the example.
just gen

# 2. Run the round-trip test in Tarantool.
just test
```

The plugin emits one `.lua` file per `.proto`. By default the output path
mirrors the proto package (`package foo.bar; baz.proto` → `foo/bar/baz_pb.lua`),
required as `foo.bar.baz_pb`. Two ways to override:

```proto
// 1. Per-file, via a proto option:
import "tarantool/tarantool.proto";
option (tarantool.lua_package) = "myapp.proto.foo";
```

```bash
# 2. Plugin-wide, via the `prefix=` plugin parameter. Every generated
#    module is prepended with this namespace and cross-file imports rewrite
#    to match. Equivalent to applying `option (tarantool.lua_package)` to
#    every input file, but without touching the .proto.
protoc --tarantool_out=out \
       --tarantool_opt=prefix=myapp.proto \
       file.proto
# -> out/myapp/proto/<pkg>/<file>_pb.lua, required as
#    "myapp.proto.<pkg>.<file>_pb"
```

`prefix=` and `(tarantool.lua_package)` compose: when both are set, the
prefix is prepended to the option's value. See
[docs/reference/cli.md](docs/reference/cli.md) for the full mapping.

For a full walk-through that takes a fresh `.proto` to a Tarantool process
encoding and decoding it, see **[docs/howto/01-first-message.md](docs/howto/01-first-message.md)**.

### Using buf

`buf generate` runs the plugin as a local plugin (`local:` in a v2
`buf.gen.yaml`, with `opt: [mode=full]` and so on); take
`google/api/annotations.proto` from the `buf.build/googleapis/googleapis`
dependency and copy `options/tarantool/tarantool.proto` into one of your
modules if you use `(tarantool.lua_package)`. The output matches
`protoc`'s (`just test-buf` checks it). A server built with `pb.server`
answers `buf curl` over its default Connect protocol given a local
`--schema`, and through server reflection with `--protocol grpc
--http2-prior-knowledge` (reflection over Connect is a full-duplex
stream, not served yet). See
[docs/howto/12-build-integration.md](docs/howto/12-build-integration.md#buf)
and [docs/howto/16-network-server.md](docs/howto/16-network-server.md#3-talk-to-it).

### Using EasyP

[EasyP](https://easyp.tech/) runs the plugin with `path:` in the
`generate.plugins` of its `easyp.yaml` and takes
`google/api/annotations.proto` from a git dependency on
`github.com/googleapis/googleapis`. Its output matches `protoc`'s too
(`just test-easyp`). See
[docs/howto/12-build-integration.md](docs/howto/12-build-integration.md#easyp).

## Serving gRPC and HTTP/JSON

`pb.server` serves the generated services over the network: gRPC over
HTTP/2 (h2c) that grpc-go, grpcurl and other stock clients talk to,
server reflection, health, HTTP/JSON transcoding of the
`google.api.http` rules and the
[Connect protocol](docs/howto/17-connect.md) over HTTP/1.1 and HTTP/2,
all on one port:

```lua
local server = require('pb').server.new({
    listen   = '0.0.0.0:8080',
    services = {greeter_pb.Greeter_server(impl)},
}):start()
```

It needs the **tarantool-http2** rock, which drives the system
`libnghttp2` (≥ 1.57) through FFI. The rock is not published yet:
install it from its source tree with `tt rocks make`; once published it
becomes a regular dependency of this rock. Nothing else in `pb` needs
it. See **[docs/howto/16-network-server.md](docs/howto/16-network-server.md)**.

## Development

The [Justfile](Justfile) is the entry point (`just --list`): `just gen`,
`just test`, `just test-c`, `just examples all`, the Go end-to-end
checks `just test-reflection-go` and `just test-server-go`, and the
Connect conformance suite `just connect-conformance`.

The recipes that start a server (`just test`, `just test-c`,
`just examples network-server`, `just test-server-go`,
`just connect-conformance`) find the
tarantool-http2 rock through `require('http2')`. To use a checkout of
the rock instead of an installed one, export its `runtime/` directory
(an absolute path); the Justfile appends it to `LUA_PATH`:

```bash
export TARANTOOL_HTTP2_RUNTIME=/path/to/tarantool-http2/runtime
just test-server-go
```

Without the rock, the luatest cases that need a live server skip,
`just examples all` skips `network-server` with a note, and
`just test-server-go` skips its tests. `just test-server-go` builds
grpcurl into a temporary directory (set `GRPCURL=<path>` to use an
installed one) and runs its `buf curl` cases when `buf` is on `PATH`.
`just test-toolchains` checks `buf generate` and `easyp generate`
output against `protoc`'s (`just test-buf` and `just test-easyp` run
one tool); a tool that is not installed is skipped, and EasyP is found
as `$EASYP` or `easyp` on `PATH`.

## Vendoring an upstream `.proto` schema

If you're vendoring someone else's `.proto` into your project (etcd,
prometheus, opentelemetry, pprof, …), `protoc-gen-tarantool` plus a
small preprocessor is the typical path.

**`google/api/annotations.proto` is supported.** The repository ships
`google/api/annotations.proto` and `google/api/http.proto` (vendored
from googleapis, Apache-2.0) under `third_party/googleapis/`, so with
`-I third_party/googleapis` an
`import "google/api/annotations.proto";` resolves, and every
`option (google.api.http) = {...}` is carried into the generated
service descriptor as a normalised `http` array on the method (see
[docs/reference/generated-api.md](docs/reference/generated-api.md#mservice_service)).
Keep these annotations: they are what HTTP/JSON transcoding
(`pb.transcode`, see
[docs/howto/15-http-transcoding.md](docs/howto/15-http-transcoding.md))
routes on.

> **Changed include path.** Earlier revisions kept these two files
> under `options/`, so `-I options` resolved `google/api` as well. It
> no longer does: `options/` holds only `tarantool/tarantool.proto`.
> Keep `-I options` for `(tarantool.lua_package)` and add
> `-I third_party/googleapis` (or the import root of your own
> googleapis copy or dependency) for `google/api`; with `-I options`
> alone, `protoc` stops at
> `google/api/annotations.proto: File not found.`

Upstream protos also import annotation extensions that only the
original generator consumes — `versionpb`, `gogoproto`,
`grpc.gateway.protoc_gen_openapiv2`. Mainline `protoc` won't parse a
file with an unresolved import, so the choice is between vendoring the
extension `.proto` files (lots of additional surface, no wire effect)
or stripping the imports and their attached options before generating.
Stripping is the lower-cost path — these annotations affect nothing on
the wire.

A drop-in preprocessor (one `python3` script, no dependencies, ~60
lines) should drop `import "versionpb/...";` /
`gogo.proto` / `protoc-gen-openapiv2/...` lines, drop single-line and
brace-balanced `option (foo.bar) = ...;` blocks at file/message/field
scope, and drop inline field options `[(foo.bar) = "..."]`.

The same preprocessor is also where you rewrite cross-package imports
to a flat layout: e.g. `import "etcd/api/mvccpb/kv.proto"` →
`import "mvccpb/kv.proto"`, so a single `protoc -I proto` resolves
every file without mirroring the upstream subdirectory tree.

Putting it together:

```bash
mkdir -p proto/<pkg>
for f in upstream/<path>/*.proto; do
    python3 strip_annotations.py < "$f" > proto/<pkg>/"$(basename "$f")"
done
protoc -I proto --tarantool_out=prefix=myapp.proto:out $(find proto -name '*.proto')
```

Proto2 sources work end to end — `required`, `optional`, custom
`[default = X]`, the proto2 unpacked-by-default rule for repeated
scalars, `extend` blocks, and legacy `group` fields all generate
correctly. See [docs/codegen.md](docs/codegen.md#proto2-support) for
the field-by-field mapping.

## Generated API

For each message `Foo` the plugin emits:

```lua
local M = require('myapp.proto.foo')

M.Foo_descriptor       -- the descriptor table consumed by the runtime
M.Foo_new(t)           -- returns t (or {}); placeholder for future validation
M.Foo_encode(t)        -- table -> wire bytes (string)
M.Foo_decode(b)        -- wire bytes (string) -> table
M.Foo_decode_lazy(b)   -- wire bytes -> MessageView (zero-copy view)
M.Foo_text(t, opts)    -- table -> protoc-style text format (debug printer)
M.Foo_has_<field>(t)   -- emitted for every presence-tracked field
M.Foo_clear_<field>(t) -- same
                       -- (proto3 explicit `optional`, proto2 `optional`,
                       --  oneof branches)
M.Foo_fields           -- strict {field = "field", ...} for lazy-view callers
M.Foo_oneofs           -- strict {oneof_group = "oneof_group", ...}, when any
```

Lazy-view field-name arguments should be routed through `M.Foo_fields`
/ `M.Foo_oneofs` rather than passed as string literals — typos error at
the read site instead of silently returning `nil`. See
[docs/api-modes.md](docs/api-modes.md#field-name-constants--required).

Text-format **decoding** is exposed on the runtime as `pb.text.decode(desc,
text, opts)` (no per-message wrapper — it's used from a few places, like
the conformance runner, and didn't warrant codegen surface).

For each enum `Color`:

```lua
M.Color_descriptor          -- { name, by_name, by_value }
M.Color                     -- alias for by_name: M.Color.RED -> 0
```

Repeated fields are Lua arrays (1-based, contiguous). 64-bit integers
(`int64`, `uint64`, `fixed64`, `sfixed64`, `sint64`) are LuaJIT `int64_t` /
`uint64_t` cdata — lossless and the same convention used by Tarantool's
`net.box`, `msgpack`, and built-in `protobuf` modules.

### Descriptor options

Every populated `*Options` message — `FileOptions`, `MessageOptions`,
`FieldOptions`, `OneofOptions`, `EnumOptions`, `EnumValueOptions`,
`ServiceOptions`, `MethodOptions` (see
[`google/protobuf/descriptor.proto`][descriptor]) — surfaces on the
generated descriptor as a plain Lua sub-table named `options`. Standard
fields use their proto name as a bare Lua key (`deprecated`, `packed`,
`json_name`, …); extensions use their fully-qualified name as a
bracket-quoted string key (`["google.api.http"]`,
`["versionpb.etcd_version_msg"]`, …). The walker is generic — pb has no
opinion about which extensions are interesting; consumers pull whichever
they care about for REST routing (`google.api.http`), version gates
(`versionpb.etcd_version_*`), in-house annotations, and so on.

The `options` key is **only emitted when at least one field is
populated**, so proto files without any options produce byte-identical
output to before. Message-valued extensions recurse into the same shape:

```lua
M.Annotated_method = M.Demo_service.methods.Annotated
M.Annotated_method.options                              -- {deprecated=true, ...}
M.Annotated_method.options["google.api.http"].post     -- "/v1/demo"
M.Annotated_method.options["google.api.http"].additional_bindings[1].post
```

For `google.api.http` specifically, the method also carries a
normalised `http` array (primary rule plus flattened
`additional_bindings`, `{method, pattern, body?, response_body?}` each)
— see [docs/reference/generated-api.md](docs/reference/generated-api.md#mservice_service).

Per-descriptor key:
- `M.<Type>_descriptor.options`         — `MessageOptions` (+ extensions)
- field's `options` (inline)            — `FieldOptions` (+ extensions)
- `M.<Type>_descriptor.oneof_options`   — `{oneof_name = OneofOptions}`
- `M.<Enum>_descriptor.options`         — `EnumOptions`
- `M.<Enum>_descriptor.value_options`   — `{VALUE_NAME = EnumValueOptions}`
- `M.<Svc>_service.options`             — `ServiceOptions`
- method's `options`                    — `MethodOptions`
- `M.options`                           — `FileOptions` (incl. `(tarantool.lua_package)`)

[descriptor]: https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/descriptor.proto

### Migrating from a Lua proto library that auto-down-casts int64

If you're moving from a library that hands back Lua numbers (silently
losing precision past 2^53), expect a sweep wherever a cdata value
crosses into a primitive that doesn't accept it. The four patterns
that catch out every migrator:

```lua
local id = msg.user_id  -- cdata: uint64_t

-- 1. log / printf format verbs: %d on cdata raises an error.
log.info('user %d signed in', tonumber(id))

-- 2. numeric for-loop bounds: `for i = 1, n` requires a Lua number.
for i = 1, tonumber(msg.row_count) do ... end

-- 3. string.format with %d / %x: same as log.
local hex = string.format('%016x', tonumber(id))

-- 4. table keys: cdata is hashed by identity, not value, so two
--    distinct cdata for the same number won't collide. Either convert
--    to number (if it fits) or use tostring(id) as the key.
cache[tonumber(id)] = row
```

`box.tuple` / `net.box` / `msgpack` / Tarantool's `protobuf` all accept
cdata int64 directly — those paths don't need a `tonumber()`. The
boundary is *Lua primitives that expect a number*. Past 2^53 (≈ 9e15),
`tonumber()` silently truncates; if your IDs can be that large, keep
them as cdata or stringify with `tostring(id):gsub('U?LL$', '')`.

If your schema's 64-bit values are dominated by the small-and-positive
case (counter-derived IDs, small sequence numbers, byte counts under
16 KB, integer enums, second-resolution timestamps in a restricted
range), the codegen can decode those as Lua numbers up front:

```bash
protoc --tarantool_opt=mode=full,int64_as_number=true ...
```

Decoded fields come back as Lua numbers when the value fits
`[-2^53, 2^53]` and cdata otherwise — same precision guarantee, none
of the `tonumber()` calls. The type at decode time becomes value-
dependent (arithmetic works transparently across both, but
`type(v) == 'cdata'` no longer holds for small values). Workload-
specific tradeoff: cdata-allocation saving on the 1-byte-varint fast
path measured at ~17 % on a 5-field 64-bit schema, but multi-byte
varints regress ~10 % because both paths still allocate the
intermediate cdata before the size check. Full table and the per-
size measurements live in [docs/reference/cli.md](docs/reference/cli.md#int64_as_number).

**Three API modes live side-by-side.** Same descriptor, three call shapes —
the inline (full) generated API is the default, the descriptor-driven runtime
API is for dynamic schemas, and the lazy API is a zero-copy view for sparse
reads and proxy / router workloads. See [docs/api-modes.md](docs/api-modes.md)
for when to pick which, with measured trade-offs.

## Layout

```
cmd/
  protoc-gen-tarantool/      Go plugin (the codegen)
    main.go                  reads CodeGeneratorRequest, hands off to gen
    internal/gen/            per-message emission for both modes
  protoc-gen-tarantool-doc/  separate Go plugin that emits Markdown docs
  conformance/               Lua conformance dispatch (loaded by the runner)
  conformance-runner.lua     stdin/stdout framing for `conformance_test_runner`

runtime/pb/                  pure-Lua runtime (`require('pb')`)
  init.lua                   public surface
  wire.lua                   varint / zigzag / fixed / float / LEN primitives
  codec.lua                  descriptor-driven encode/decode
  lazy.lua                   zero-copy MessageView / ArrayView / MapView
  text.lua                   text format encode + decode (proto3)
  json.lua                   proto3 JSON encode + decode (strict)
  wkt.lua                    Timestamp / Duration / Empty / Wrappers /
                             Struct / Value / ListValue / Any / FieldMask
  grpc.lua                   transport interface + loopback / multiplex
  reflection.lua             gRPC server reflection (v1, v1alpha)
  health.lua                 gRPC health service
  transcode.lua              google.api.http HTTP/JSON router
  connect.lua                the Connect protocol over buffered HTTP requests
  server.lua                 network server over the tarantool-http2 rock
  gen/                       reflection + health modules generated from
                             third_party/grpc-proto by this plugin
  parser.lua                 pure-Lua proto3 schema parser (.proto → AST)
  dynamic.lua                AST → descriptor module
  fileset.lua                FileDescriptorSet bytes → descriptor module
  descriptor_pb.lua          hand-built descriptors of descriptor.proto

options/tarantool/           custom proto file options
  tarantool.proto            (tarantool.lua_package) — Lua require path override

examples/proto/              demo .proto inputs
examples/expected/           generated output for full + runtime modes
                             (both committed for inspection + parametrized tests)
test/                        luatest groups, conformance regressions, fixtures
docs/                        codegen notes, API mode comparison, design briefs
bench/                       per-helper bench + JIT-trace gate + alloc baseline
```

## Documentation

Start at **[docs/index.md](docs/index.md)** — the documentation map,
grouped by what you're trying to do (getting started, reference, specs,
internals). The two reference pages worth knowing by name:

- **[docs/api-modes.md](docs/api-modes.md)** — when to use `Foo_encode`
  (full), `pb.encode(desc, t)` (runtime / reflect), or
  `pb.decode_lazy(desc, b)` (lazy view). Measured allocation + throughput
  trade-offs.
- **[docs/codegen.md](docs/codegen.md)** — plugin internals, descriptor
  shape contract, how to add a new wire type or scalar, the LuaJIT
  hot-path rules generated code observes.

Open roadmap work is tracked in GitHub issues.

## Conformance

`cmd/conformance-runner.lua` speaks the [Google protobuf conformance
protocol][gconf] on stdin/stdout. Drive it with the canonical
`conformance_test_runner` binary like so:

```bash
just gen
conformance_test_runner --enforce_recommended \
    tarantool cmd/conformance-runner.lua
```

Homebrew's `protobuf` package does not ship `conformance_test_runner`, so a
Dockerfile under `docker/conformance.Dockerfile` builds it from upstream
protobuf source and bundles Tarantool. Run the full suite locally with:

```bash
just conformance
```

(Mounts the repo into the container — generated Lua from `just gen` on the
host is what gets tested.) Keep the host `protoc` at the same release as
`PROTOBUF_TAG` in the Dockerfile: `just gen` runs it, and so does
`just gen-builtin-descriptors`, which writes the descriptors the runtime
ships for the well-known types and `google/api` into
`runtime/pb/descriptors_builtin.lua` (the protoc version is recorded in
its header). Nothing checks the alignment automatically. Known failures live in
`test/conformance/known_failures.txt` (binary + JSON suite) and
`test/conformance/known_failures_text.txt` (text-format suite); both are
empty.

`just conformance` runs the suite twice. The second pass adds
`--performance`, which is not a stricter setting but a separate set of
tests the default run never executes: merging 50000 occurrences of a
message field (binary and text format) and rejecting messages nested
20000 levels deep (`EnforceDepthLimit.*`).

Current baseline (2026-09-29, protobuf v36.2, `--enforce_recommended`,
identical with `just conformance-c`):

| Suite | Successes | Skipped | Expected failures | Unexpected |
|-------|-----------|---------|-------------------|------------|
| Binary + JSON | **2817** | 0 | 0 | 0 |
| Text-format   |  **445** | 0 | 0 | 0 |
| Binary, `--performance`      | **31** | 1 | 0 | 0 |
| Text-format, `--performance` | **24** | 0 | 0 | 0 |

The skipped test, `EnforceDepthLimit.Map`, is written against an editions
test message. Editions (`--maximum_edition 2023`, which adds another 3296
tests) are not supported yet.

Both proto2 and proto3 test messages run through the same dispatcher in
`cmd/conformance/core.lua`. The test protos in `test/conformance/proto/`
are vendored from upstream unchanged.

The runner supports `protobuf_test_messages.proto3.TestAllTypesProto3` in
binary, JSON, and text-format input/output, including the
`JSON_IGNORE_UNKNOWN_PARSING_TEST` category (forwarded as
`ignore_unknown_fields=true` to `pb.json.decode`). The self-test in
`test/conformance_test.lua` exercises the runner with crafted requests on
every `just test` run.

### C-runtime parity

The optional C acceleration runtime (`runtime/pb/c_runtime.{so,dylib}`,
built via `just build-c`, activated by `PB_ENABLE_C=1`) must produce
byte-identical output to the pure-Lua codec. It needs Tarantool 3.5 or
later; see [docs/c-accel.md](docs/c-accel.md#tarantool-version). The
parity gate reuses the existing test suites — no separate diff harness:

```bash
just test-all       # luatest under both codecs (752 + 1043 tests)
just conformance    # Google suite, Lua codecs
just conformance-c  # Google suite, PB_ENABLE_C=1
```

Every assertion checks against a reference (golden bytes, txtpb,
conformance result). If Lua passes and C passes, both equal the
reference, so Lua ≡ C by transitivity. The interop fixtures under
`test/interop/fixtures/` are parameterized over both codegen modes;
under `PB_ENABLE_C=1` the runtime-mode iteration transparently
exercises the C codec.

[gconf]: https://github.com/protocolbuffers/protobuf/tree/main/conformance

## Benchmarks

```bash
just bench           # print throughput + alloc per op (5 sizes × 2 modes)
just bench-c         # same with PB_ENABLE_C=1 — runtime column → `c-runtime`
just bench-baseline  # overwrite bench/baseline.json (run on a quiet machine)
just bench-compare   # exit 1 if any alloc-per-op regressed >5% vs baseline
```

The committed `bench/baseline.json` tracks only allocation per op — that's
reproducible across machines because it counts bytes, not time. Throughput
in stderr is informational; it swings 30%+ on a contended CPU.

Current baseline (LuaJIT 2.1, hello.Person):

| Payload | encode alloc (full / runtime) | decode alloc (full / runtime) |
|---------|-------------------------------|-------------------------------|
| 10 B    | 0.37 / 0.63 KB                | 0.51 / 0.51 KB                |
| 100 B   | 0.37 / 0.63 KB                | 0.51 / 0.51 KB                |
| 1 KB    | 5.98 / 7.04 KB                | 7.75 / 7.88 KB                |
| 10 KB   | 47.5 / 48.6 KB                | 59.5 / 59.6 KB                |
| 100 KB  | 444 / 445 KB                  | 568 / 568 KB                  |

Lazy decode trades a much higher *index-build* cost (one MessageView
table + four SoA arrays) for near-zero allocation on subsequent
field reads — best when you touch a small fraction of fields, or when
you re-encode mostly-unchanged messages (proxy / router workloads). See
[docs/api-modes.md](docs/api-modes.md) for the bench numbers and the
cross-over point.

## Why named `pb` instead of `protobuf`?

Tarantool's loader prefers the built-in `require('protobuf')` over any
filesystem module of the same name. Trying to override it would break code
that uses the built-in's encode API. `pb` is short, unambiguous, and lives
alongside the built-in.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
