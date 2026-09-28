# CLI reference

How to drive `protoc-gen-tarantool` and the sibling
`protoc-gen-tarantool-doc` from `protoc`.

## Building the plugins

```bash
just build           # builds ./protoc-gen-tarantool
just build-doc       # builds ./protoc-gen-tarantool-doc
```

Or directly:

```bash
go build -o protoc-gen-tarantool     ./cmd/protoc-gen-tarantool
go build -o protoc-gen-tarantool-doc ./cmd/protoc-gen-tarantool-doc
```

Place both binaries on `PATH` (or pass `--plugin=` to `protoc`) and
they become available as the `tarantool` and `tarantool-doc` outputs.

## `protoc-gen-tarantool` — the Lua codegen

### Invocation

```bash
protoc \
    -I. \
    -Ioptions \
    --tarantool_out=<output_dir> \
    --tarantool_opt=<key>=<value>,<key>=<value> \
    path/to/file.proto
```

`output_dir` is the root the plugin writes under. Per-file output path
follows the Lua require path (see [`prefix`](#prefix) and
[`(tarantool.lua_package)`](#tarantoollua_package) below).

`-Ioptions` is needed when any input proto uses the custom
`(tarantool.lua_package)` option — it imports
`tarantool/tarantool.proto` from `options/tarantool/`.

### `--tarantool_opt`

Comma-separated `key=value` pairs:

| Option | Values | Default | Meaning |
|---|---|---|---|
| `mode` | `full` / `runtime` | `full` | `full` inlines `_encode` / `_decode` bodies; `runtime` emits one-line delegations to `pb.encode` / `pb.decode`. See [api-modes.md](../api-modes.md). |
| `prefix` | any Lua require path | empty | Prepended to every generated module's require path and on-disk subpath. |
| `int64_as_number` | `true` / `false` | `false` | `mode=full` only. Decode 64-bit scalar fields as Lua numbers when the value fits `[-2^53, 2^53]`, cdata otherwise. Workload-dependent — see [`int64_as_number`](#int64_as_number) below. |

### `prefix`

`prefix=foo.bar` rewrites every generated module name from
`<orig_path>` to `foo.bar.<orig_path>`. Affects both the require path
and the on-disk location.

| Without prefix | With `prefix=apps.myapp` |
|---|---|
| `hello/hello_pb.lua` | `apps/myapp/hello/hello_pb.lua` |
| `require('hello.hello_pb')` | `require('apps.myapp.hello.hello_pb')` |

The Justfile uses this to emit `full/` and `runtime/` copies side by
side for the parametrized test suite:

```bash
protoc --tarantool_opt=mode=full,prefix=full         ...   # examples/expected/full/...
protoc --tarantool_opt=mode=runtime,prefix=runtime   ...   # examples/expected/runtime/...
```

### `int64_as_number`

Decode `int64` / `uint64` / `sint64` / `fixed64` / `sfixed64` fields as
a Lua `number` when the decoded value fits `[-2^53, 2^53]` (inclusive
on both endpoints — both are powers of two and exact as doubles), as
LuaJIT `int64_t` / `uint64_t` cdata otherwise. `mode=full` only;
`mode=runtime` errors at plugin startup. Default off.

```bash
protoc --tarantool_out=out \
       --tarantool_opt=mode=full,int64_as_number=true \
       schema.proto
```

The return type becomes value-dependent under this flag. Arithmetic
(`+`/`-`/`*`/`/`/`==`) works transparently across number and cdata,
but call sites that branch on `type(v) == 'cdata'` or rely on
cdata-only operators need updating.

Workload-dependent tradeoff measured on a 5-field 64-bit schema
(`c_int64.Wide`, `mode=full`, no `PB_ENABLE_C`):

| Field-value magnitude | Default (always cdata) | `int64_as_number` | Delta |
|---|---|---|---|
| 1-byte varints (`< 128`) | 2050 ns/op | 1700 ns/op | **−17 %** |
| 3-byte varints | 3220 ns/op | 3600 ns/op | +11 % |
| past 2^53 | 7575 ns/op | 7750 ns/op | +2 % (noise) |

Enable when the schema's 64-bit fields typically carry small values
(counter-derived IDs, small sequence numbers, byte counts < 16 KB,
integer enums, second-resolution timestamps in restricted ranges).
The win is from skipping the cdata header allocation entirely on the
fast path. For workloads dominated by full-range int64 / fixed64
(epoch-nanosecond timestamps, large hash IDs, file-size byte counts),
leave it off — both decoders allocate a cdata for the intermediate
varint, and the comparison + `tonumber()` adds net overhead.

Under `PB_ENABLE_C=1` the flag is a no-op: the C runtime makes its
own number-vs-cdata decision via `luaL_pushint64` (Tarantool's small-
fits-in-double convention) before the codegen-emitted decoder runs.
See [c-accel.md](../c-accel.md).

The `runtime/` shipped Lua module exposes the matching wire helpers
(`wire.decode_int64_n`, `decode_uint64_n`, `decode_sint64_n`,
`decode_fixed64_n`, `decode_sfixed64_n`) for hand-rolled callers that
want the same semantics without going through codegen.

### `(tarantool.lua_package)` — per-file override

Defined in `options/tarantool/tarantool.proto`. Overrides the require
path for a single `.proto`:

```proto
syntax = "proto3";
package my.app;

import "tarantool/tarantool.proto";
option (tarantool.lua_package) = "myapp.proto.foo";

message Foo { ... }
```

| Without `lua_package` | With `lua_package` |
|---|---|
| `my/app/foo_pb.lua` | `myapp/proto/foo_pb.lua` |
| `require('my.app.foo_pb')` | `require('myapp.proto.foo_pb')` |

`prefix=` and `(tarantool.lua_package)` compose: `prefix` is prepended
to the final per-file path regardless of which scheme produced it.

### Path-resolution rules

For each input `.proto`, the plugin picks a Lua require path in this
order:

1. **`option (tarantool.lua_package) = "pkg";`** — wins outright. The
   plugin writes `pkg` as a `/`-joined path with `_pb.lua` appended
   (or just `pkg` if `pkg` already ends in `_pb`).
2. **`package` declaration + filename** — `package my.app;` and a
   file `foo.proto` produce `my/app/foo_pb.lua`,
   `require('my.app.foo_pb')`.
3. **No package** — the filename alone: `foo.proto` → `foo_pb.lua`,
   `require('foo_pb')`.

WKT proto files (`google/protobuf/*.proto`) are **not** generated as
Lua modules. References to WKT types route to `pb.wkt.<Name>_descriptor`
at codegen time; the runtime side ships them in `runtime/pb/wkt.lua`.

### What gets emitted

See [generated-api.md](generated-api.md) for the per-message /
per-enum / per-service surface. Both modes always emit:

- `M.<Msg>_descriptor`, `M.<Msg>_fields`, `M.<Msg>_oneofs` (when applicable)
- `M.<Msg>_new`, `M.<Msg>_encode`, `M.<Msg>_decode`
- `M.<Msg>_decode_lazy`, `M.<Msg>_text` (mode-independent wrappers)
- `M.<Msg>_has_<field>` / `M.<Msg>_clear_<field>` (proto3 explicit-optional)
- `M.<Enum>_descriptor`, `M.<Enum>` (alias for `by_name`)
- `M.<Service>_service`, `M.<Service>_client`, `M.<Service>_server`
- EmmyLua / lua-language-server annotations
- Reserved-name table (`reserved_names`) for the text-format parser

### Stdin/stdout protocol

The plugin reads a `CodeGeneratorRequest` from stdin and writes a
`CodeGeneratorResponse` to stdout, per protoc's standard plugin
interface. It advertises `FEATURE_PROTO3_OPTIONAL` so protoc surfaces
explicit-optional fields; without this flag, protoc omits them.

**Both proto2 and proto3 input are accepted**; any other syntax is
rejected at the top of `GenerateFile`. See
[codegen.md → Proto2 support](../codegen.md#proto2-support).

## `protoc-gen-tarantool-doc` — the Markdown reference generator

Same input as the Lua codegen; emits one Markdown file per input
`.proto` summarizing messages, enums, services.

```bash
protoc \
    -I. \
    -Ioptions \
    --tarantool-doc_out=<output_dir> \
    path/to/file.proto
```

Example: `examples/docs/hello.md` is produced by `just gen-docs` from
`examples/proto/hello.proto`.

No options today. The output template is minimal:

- Per message: a table of fields (number, name, type, label,
  description from the leading comment).
- Per enum: a table of values.
- Per service: a table of methods with streaming kind.

Lua call signatures (`Foo_encode`, `Foo_decode_lazy`, etc.) are not
yet in the doc template — they're documented in
[generated-api.md](generated-api.md) for now.

## Driving from `make`

The Justfile is the canonical entry point for development:

```bash
just build         # build the codegen plugin
just build-doc     # build the doc plugin
just gen           # build + regen examples/expected/{full,runtime}/...
just gen-docs      # build-doc + regen examples/docs/hello.md
just test          # run the luatest suite (parametrized over both modes)
just goldens       # regenerate test/interop/fixtures/*.bin via protoc --encode
just bench         # alloc + throughput per op
just jit-trace     # assert hot paths stay on the JIT trace
```

For end-user projects not using this repo's Makefile, see the planned
[howto 12: Build integration](../howto/12-build-integration.md)
(`protoc`, Justfile, `buf`, CMake recipes).
