# `pb` runtime API reference

Everything `require('pb')` exposes, organized by what you call from
application code.

For *generated* per-message functions (`M.Foo_encode`, `M.Foo_text`,
etc.) see [generated-api.md](generated-api.md). For the descriptor
table shape see [../codegen.md](../codegen.md#the-descriptor-table--the-contract).

## At a glance

```lua
local pb = require('pb')

local bytes = pb.encode(desc, t)          -- table -> wire bytes
local t     = pb.decode(desc, bytes)      -- wire bytes -> table
local view  = pb.decode_lazy(desc, bytes) -- wire bytes -> MessageView

local mod   = pb.parse(proto_source)      -- .proto text -> module
local set   = pb.from_pb(descset_bytes)   -- FileDescriptorSet -> module set

pb.json.encode(desc, t)                   -- proto3 JSON encode
pb.json.decode(desc, s [, opts])          -- proto3 JSON decode
pb.text.encode(desc, t [, opts])          -- text format encode
pb.text.decode(desc, s [, opts])          -- text format decode

pb.NULL                                   -- canonical null sentinel
pb.to_uint64(v) / pb.to_int64(v)          -- coerce to 64-bit cdata

pb.any.pack(desc, t [, prefix])           -- build google.protobuf.Any
pb.any.unpack(any_t [, desc])             -- unpack to {desc, t}
pb.register(desc) / pb.lookup(name)       -- type registry for Any

pb.grpc.error(pb.grpc.code.NOT_FOUND, m)  -- fail a gRPC call with a status
pb.grpc.loopback(server)                  -- in-process gRPC transport
pb.grpc.multiplex({srv1, srv2, ...})      -- fan multiple servers

local conv  = pb.tuple.bind(desc, space [, opts]) -- message <-> space format
conv:encode(tuple)                        -- box.tuple -> wire bytes
conv:decode(bytes)                        -- wire bytes -> box.tuple

pb.field_names(t)                         -- strict field-name table (codegen)
pb.enum(name, {RED=0, ...})               -- enum descriptor (codegen)
pb.finalize_message(desc)                 -- finalize a hand-rolled descriptor
```

## Codec

### `pb.encode(desc, t) -> string`

Encode `t` against `desc` to protobuf wire bytes. Same input shape as
generated `M.Foo_encode(t)`; runs through descriptor dispatch instead of
inline code. ~5-15% slower than full-mode `Foo_encode` on the
microbenchmark; same allocation profile.

### `pb.decode(desc, bytes) -> table`

Decode wire bytes against `desc`. Returns a plain Lua table whose keys
match field names. Only fields present on the wire get a key: a field
that is not on the wire is `nil`, whatever its kind — scalar, enum,
string, bytes, repeated, map, message, oneof member or explicit
`optional` — and proto2 `[default = X]` values are not filled in
either. Defaults are not materialized, so read an absent implicit-
presence field as its default yourself (`t.count or 0`). A field that
is on the wire holding its default (an explicit `0`, say) comes back
with that value. Generated `M.Foo_decode` in both codegen modes and the
C codec behave the same way. Unknown fields are concatenated into
`t._unknown_fields` (raw bytes, re-emitted on encode).

A singular message field that occurs more than once on the wire is
merged, not replaced: scalars take the last value, repeated fields
concatenate, nested messages merge recursively, a oneof member clears
the siblings an earlier occurrence set, and the unknown fields and
proto2 extensions of every occurrence are kept. `pb.text.decode`
merges a repeated `field { ... }` block the same way.

Decoding refuses input nested more than `pb.wire.RECURSION_LIMIT`
(100) messages or groups below the top-level message, with the error
`message nesting exceeds the recursion limit (100)`. The bound is the
same as protobuf's C++ and upb parsers and covers every path that
recurses: nested messages, groups, map values, extensions,
`Struct` / `Value` / `ListValue`, and unknown groups being skipped.
Every decoder enforces it identically — both codegen modes and the C
codec — which keeps hostile input from exhausting the Lua stack or the
fiber's C stack. The C encoder refuses a table nested past the same
bound (which also catches a self-referencing table); the Lua encoders
have no bound and fail on such a table with Lua's own `stack overflow`.

### `pb.decode_lazy(desc, bytes) -> MessageView`

Build a zero-copy view over the bytes. Nothing past the field index is
decoded until you call `:get`, `:has`, `:iter`, etc. See
[api-modes.md → lazy](../api-modes.md#lazy-zero-copy-view) for the full
surface and when it wins.

### `pb.lazy`

The lazy module itself (`pb.lazy.build`, the `MessageView` /
`ArrayView` / `MapView` classes). Most callers use `pb.decode_lazy`;
this is for advanced consumers that need to construct views by hand.

## Dynamic descriptors

Two ways to produce a descriptor module at runtime, both yielding the
same shape generated code emits in `mode=runtime`.

### `pb.parse(source) -> module`

Parse a `.proto` source string and return a module-shaped table
`{<MessageName>_descriptor = ..., <MessageName>_encode = ..., ...}`. The
parser handles proto3 syntax including services, options, imports,
nested messages, oneofs, maps, explicit-optional. WKT imports
(`google/protobuf/*.proto`) resolve to the `pb.wkt` descriptors
automatically.

```lua
local hello = pb.parse(io.open('hello.proto'):read('*a'))
local bytes = hello.Person_encode({name = 'Alice'})
```

### `pb.from_pb(descset_bytes) -> {files, order, lookup}`

Parse a binary `FileDescriptorSet` (the output of
`protoc --descriptor_set_out=...`) and return:

- `files[name]` — per-file module, indexed by the original `.proto`
  filename.
- `order` — array of filenames in dependency order.
- `lookup(fqn) -> descriptor` — find any message or enum by its fully-
  qualified name (e.g. `'hello.Person'`).

```lua
local set = pb.from_pb(io.open('build/all.pb', 'rb'):read('*a'))
local desc = set.lookup('hello.Person')
local bytes = pb.encode(desc, {name = 'Alice'})
```

### `pb.parser`, `pb.dynamic`, `pb.fileset`

The submodules behind `pb.parse` / `pb.from_pb`. Exposed for callers
that want the AST step (`pb.parser.parse(text) -> ast`) or to build
descriptors by hand (`pb.dynamic.build(ast)`).

## Codec dialects

### `pb.json`

Strict proto3 JSON. See `runtime/pb/json.lua` for the canonical-mapping
details (camelCase field names, base64 for `bytes`, RFC 3339 for
`Timestamp`, etc.).

- `pb.json.encode(desc, t) -> string`
- `pb.json.decode(desc, s [, opts]) -> table` —
  `opts.ignore_unknown_fields = true` accepts JSON with extra keys
  (matches the conformance suite's `JSON_IGNORE_UNKNOWN_PARSING_TEST`
  category).

### `pb.text`

Mainline-protoc text format, both directions.

- `pb.text.encode(desc, t [, opts]) -> string` — `opts.single_line =
  true` collapses to one space-separated line; `opts.indent =
  '<string>'` overrides the default two-space indent.
- `pb.text.decode(desc, s [, opts]) -> table` — handles every grammar
  bucket the conformance text suite exercises (decimal/hex/octal int
  literals, float specials, C-style and `\u`/`\U` escapes, `{}` /
  `<>` aggregates, repeated short-form `[a, b, c]`, map entries, the
  inline Any form, enum-by-name-or-number, reserved-name drop, and
  numeric-field-ID tolerance).

Both directions support `_unknown_fields` passthrough.

## Well-known types — `pb.wkt`

Hand-rolled descriptors for `google.protobuf.*`. Generated code that
references a WKT field routes to these automatically — you only touch
`pb.wkt` directly when packing/unpacking by hand or registering a type
for `Any`.

| Symbol | Notes |
|---|---|
| `pb.wkt.Timestamp_descriptor` | Lua-side value: `datetime` cdata when in spec, or `{seconds, nanos}` table when out of spec. |
| `pb.wkt.Duration_descriptor` | Lua-side value: `{seconds, nanos}` table. |
| `pb.wkt.Empty_descriptor` | Lua-side value: `{}`. |
| `pb.wkt.<T>Value_descriptor` (Int32, Int64, UInt32, UInt64, Bool, String, Bytes, Float, Double) | Auto-wrap/unwrap: pass the scalar directly, decode returns the scalar. |
| `pb.wkt.Struct_descriptor` | Lua-side value: a table tagged via `pb.wkt.struct(t)` if disambiguation is needed (Struct vs Value vs ListValue). |
| `pb.wkt.Value_descriptor` | Lua-side value: native Lua of matching shape; use `pb.NULL` for null. |
| `pb.wkt.ListValue_descriptor` | Lua-side value: array; use `pb.wkt.list(t)` to disambiguate. |
| `pb.wkt.FieldMask_descriptor` | Lua-side value: `{'foo.bar', 'baz', ...}`. |
| `pb.wkt.Any_descriptor` | Opaque `{type_url, value}` table by default; see [`Any`](#any) below. |
| `pb.wkt.NullValue_descriptor` | Enum with single value `NULL_VALUE = 0`. |

### Tagging helpers

```lua
local s = pb.wkt.struct({a = 1, b = 'x'})  -- table tagged as Struct
local l = pb.wkt.list({1, 2, 3})           -- table tagged as ListValue
```

Use these when stashing a value into `google.protobuf.Value` (or a
`Struct` field) and the codec can't infer whether you mean a `Struct`,
a `ListValue`, or a primitive map/array.

### `Any`

`pb.any.pack(desc, t [, prefix]) -> any_table`

Encode `t` against `desc`, wrap as
`{type_url = '<prefix>/<full.name>', value = <bytes>}`. Default prefix
is `type.googleapis.com`.

`pb.any.unpack(any_t [, desc]) -> {desc, t}` or `(t, desc)`

Decode the `value` bytes against the supplied descriptor, or
auto-resolve via the registry if `desc` is nil.

`pb.register(desc)` / `pb.lookup(name_or_url) -> desc`

Type registry. Generated code does **not** auto-register messages —
call `pb.register(M.Foo_descriptor)` once per type you want to round-
trip through `Any` by `type_url` alone.

## gRPC — `pb.grpc`

| Symbol | Notes |
|---|---|
| `pb.grpc.code` / `pb.grpc.code_name` | The 17 canonical status codes by name (`NOT_FOUND = 5`), and the reverse lookup. |
| `pb.grpc.http_status[code]` | HTTP status for a code (Google API / grpc-gateway mapping). |
| `pb.grpc.error(code, message?, details?)` | Raise a status object; a handler uses it to fail a call. |
| `pb.grpc.status(code, message?, details?)` | Build a status object `{code, message, details}` without raising. `tostring` gives `NOT_FOUND: book 42`. |
| `pb.grpc.is_status(v)` | True for a status object. |
| `pb.grpc.encode_status(st)` / `pb.grpc.decode_status(bytes)` | Status object ↔ `google.rpc.Status` wire bytes. |
| `pb.grpc.loopback(server)` | In-process transport. `server` is the table returned by `M.<Service>_server(impl)`. Suitable for tests and same-process apps; uses `fiber.channel`. |
| `pb.grpc.multiplex({srv1, srv2, ...})` | Fan multiple `_server` results onto one transport. Errors on duplicate paths. |
| `pb.grpc.new_stream_pair(buf_size)` | Build a paired (client_stream, server_stream) over a `fiber.channel`. Used internally by `loopback`; exposed for custom transports. |
| `pb.grpc.wrap_*` | Helpers that wrap a raw stream/call with input/output codecs. Used by generated client/server code. |

`details` is an array of `google.protobuf.Any` tables (what
`pb.any.pack` returns). The in-process transports pass a raised status
object to the client unchanged; see
[grpc-contract.md → Status errors](grpc-contract.md#status-errors).

The transport *contract* (`:unary`, `:server_stream`, `:client_stream`,
`:bidi`) is documented in [grpc-contract.md](grpc-contract.md). Any
table implementing those four methods plugs into a generated client.

## Tuple bridge — `pb.tuple`

Converts between Tarantool tuples and wire bytes, one call per row.
With the C runtime (`PB_ENABLE_C=1`) neither direction builds a Lua
table per row. On the default Lua path both still allocate per row:
encode builds scratch tables and strings, and decode runs `pb.decode`
into a message table before laying it out as a row. See the how-to for
measured numbers. The walkthrough, with the binding rules, the type
compatibility list and a runnable example, is
[how-to: tuples to protobuf and back](../howto/14-tuples.md); the full
contract is the header comment of `runtime/pb/tuple.lua`.

### `pb.tuple.bind(desc, space [, opts]) -> conv`

Bind a message descriptor (from generated code, `pb.parse`,
`pb.from_pb` or a hand-rolled one) to the format of `space` (a space
object, e.g. `box.space.kv`). Top-level fields bind to columns by
name.

- `opts.columns = {[field name] = column name}` — renames.
- `opts.omit = {field name, ...}` — fields left out of the binding.

Any other option is an error. `bind` raises (`pb.tuple: ...`) on every
descriptor/format mismatch: a field with no column, two fields on one
column, an incompatible field and column type, a field with explicit
presence in a non-nullable column, and the rest listed in the how-to.
After a successful bind, conversions raise only per value.

### Converter methods

Every method first checks the box schema version. When it moved since
the plan was compiled, the converter rebinds against the space's
current format; it raises if the space was dropped or renamed, or if
the new format no longer binds.

| Method | Returns | Notes |
|---|---|---|
| `conv:encode(tuple)` | `string` | Wire bytes of the message the tuple holds. `tuple` is any `box.tuple` laid out per the format. |
| `conv:encode_repeated(field_no, tuples)` | `string` | For each tuple: the tag of `field_no` (length-delimited), the length, the encoded row. Splices rows into an enclosing message as a `repeated` field. `field_no` is an integer in `[1, 2^29 - 1]`; `tuples` is a Lua array of `box.tuple`; an empty array gives `''`. |
| `conv:decode(bytes)` | `box.tuple` | Laid out per the format but without it attached, so fields are read by number. Ends at the last bound column. |
| `conv:insert(bytes)` | `box.tuple` | `decode`, then `space:insert`; the stored tuple. |
| `conv:replace(bytes)` | `box.tuple` | `decode`, then `space:replace`; the stored tuple. |

Errors from the methods:

- an argument of the wrong type (`pb.tuple: expected a box.tuple, got
  table`);
- a value the field or column cannot take, naming the field, the
  message and the column (`pb.tuple: field 'lease' of kv.KeyValue
  (column 'lease_id'): value -1LL does not fit column type unsigned`);
- on decode, malformed wire bytes (the codec's error), and a
  non-nullable column that no field binds to;
- on `insert` / `replace`, box errors such as a duplicate key, as box
  raises them.

With `PB_ENABLE_C=1` and the C runtime loaded (Tarantool 3.5 or later),
all five methods run in C with the same results and the same error
messages. `bind` stays in Lua.

## Sentinels and coercions

### `pb.NULL`

Canonical null sentinel used by `google.protobuf.Value` and proto3
JSON. Equal to `box.NULL` — preferred form is `pb.NULL` so application
code doesn't have to depend on `box` being available.

### `pb.to_uint64(v) -> uint64_t cdata`
### `pb.to_int64(v) -> int64_t cdata`

Coerce a Lua number, cdata, or numeric string into the matching
LuaJIT cdata. Use at any boundary where the input type isn't already
cdata (JSON, text format, net.box arguments, user input). The codec
otherwise requires cdata for the five 64-bit-typed fields and will
error on bare Lua numbers past 2^53.

```lua
local id = pb.to_uint64('18446744073709551615')  -- max uint64
local t  = {user_id = id}
```

## Codegen helpers (used by generated `_pb.lua`)

Three helpers application code rarely calls directly — they're how
generated modules and hand-rolled descriptors get built:

### `pb.field_names(tbl) -> tbl`

Wrap a `{field_name = field_name, ...}` table with a strict
`__index` / `__newindex` so unknown keys error at the read site.
Generated code emits `M.<Type>_fields = pb.field_names({...})` for use
with the lazy view (`view:get(F.user_id)`).

### `pb.enum(name, {NAME = number, ...}) -> enum_descriptor`

Build an enum descriptor with reversible `by_name` / `by_value` maps:

```lua
local Color = pb.enum('app.Color', {RED = 0, GREEN = 1, BLUE = 2})
Color.by_name.RED   -- 0
Color.by_value[1]   -- 'GREEN'
```

### `pb.finalize_message(desc) -> desc`

Fill in `field_by_id` / `field_by_name` / `oneofs_list`, mark cdata-
keyed maps for pointer-vs-value dedup on decode, and attach
per-field `_writer` / `_reader` specializations for the hot path.
Call after constructing `desc.fields[]`. Idempotent.

## Wire-format primitives — `pb.wire`

Low-level encode/decode for individual wire types. Generated full-mode
code inlines calls to these; application code rarely needs them
directly. The full surface is in `runtime/pb/wire.lua`. Highlights:

- Wire-type constants: `pb.WIRE_VARINT`, `pb.WIRE_I64`, `pb.WIRE_LEN`,
  `pb.WIRE_I32` (also under `pb.wire.WIRE_*`).
- Per-type encode/decode: `pb.wire.encode_int32`, `decode_string`, etc.
  for all 15 scalar types.
- Tag handling: `pb.wire.encode_tag(id, wt)`, `decode_tag(buf, pos)`.
- Varint primitives: `encode_varint`, `decode_varint`, the four zigzag
  variants.
- UTF-8 validator: `pb.wire.is_valid_utf8(s)` — ICU-backed, matches
  every proto3 UTF-8 rejection rule.
- `pb.wire.RECURSION_LIMIT` — the decode nesting bound (100); see
  [`pb.decode`](#pbdecodedesc-bytes---table).

Adding a new scalar means touching `wire.lua` (primitives +
`TYPE_INFO`), `types.go` (Kind mapping), and `inline.go` (emission).
See [codegen.md → adding a new wire type](../codegen.md#plugin-source-layout).

## Codec internals — `pb.codec`

Exposed for generated inline code that wants to share helpers (e.g.
`pb.codec.merge_message` for sub-message merging on repeated decode).
Not intended as a stable application-facing surface; reach for the
high-level `pb.encode` / `pb.decode` instead.
