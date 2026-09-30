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
pb.descriptors.file('hello.proto')        -- registered FileDescriptorProto bytes

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
pb.reflection.new({services = {...}})     -- gRPC server reflection
pb.health.new()                           -- gRPC health service

local router = pb.transcode.new({srv1, ...} [, opts]) -- google.api.http router
router:handle(req [, ctx])                -- HTTP request table -> response | nil

local server = pb.server.new({listen = 'host:port', services = {srv1, ...}})
server:start()                            -- gRPC + reflection + health + HTTP/JSON
                                          -- on one port (needs the http2 rock)

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

Each module also carries `M.<Service>_service` for every service in the
file, in the generated shape (`name`, `full_name`, `methods[<Method>]`
with `input`, `output`, the streaming flags and, for methods annotated
with `google.api.http`, the same normalised `http` array codegen emits
— see [generated-api.md](generated-api.md#mservice_service)). `input` /
`output` resolve across the files of the set (pass `--include_imports`
to protoc so the types' files are in it); they are `nil` only when the
type's file is missing from the set. `pb.parse` builds the same service
tables for one file, without `http` (the text parser skips method
options).

```lua
local set = pb.from_pb(io.open('build/all.pb', 'rb'):read('*a'))
local desc = set.lookup('hello.Person')
local bytes = pb.encode(desc, {name = 'Alice'})
```

### `pb.parser`, `pb.dynamic`, `pb.fileset`

The submodules behind `pb.parse` / `pb.from_pb`. Exposed for callers
that want the AST step (`pb.parser.parse(text) -> ast`) or to build
descriptors by hand (`pb.dynamic.build(ast)`).

## Descriptor registry — `pb.descriptors`

Serialized `google.protobuf.FileDescriptorProto` bytes by `.proto` file
name: what gRPC server reflection hands to clients. Generated modules
register their file (and imports not generated alongside them) when
loaded — see [generated-api.md → File-level boilerplate](generated-api.md#file-level-boilerplate).
The descriptors of `google/protobuf/{descriptor,any,api,duration,empty,
field_mask,source_context,struct,timestamp,type,wrappers}.proto`,
`google/protobuf/compiler/plugin.proto` and
`google/api/{annotations,http}.proto` ship with the runtime
(`pb.descriptors_builtin`, loaded on first lookup).

The shipped built-ins are produced by the protoc release the runtime
was built with (its version is in the header of
`runtime/pb/descriptors_builtin.lua`). Generated modules do not embed
copies of these files, so a module compiled by a different protoc
release still resolves them to the shipped bytes. The well-known types
are stable across releases; what can differ is `descriptor.proto`
(new `FeatureSet` / edition fields), which reflection clients only
consult for custom options.

```lua
require('myapp.hello_pb')                  -- registers 'hello.proto'

pb.descriptors.file('hello.proto')         -- bytes, or nil if unknown
pb.descriptors.files()                     -- sorted names, built-ins included
pb.descriptors.dependencies('hello.proto') -- {'google/protobuf/timestamp.proto', ...}
pb.descriptors.package('hello.proto')      -- 'hello'
pb.descriptors.register(bytes)             -- -> 'hello.proto'
pb.descriptors.register(bytes, {snapshot = true}) -- a copy of an import
```

| Function | Semantics |
|---|---|
| `register(bytes [, opts]) -> name` | Add a serialized `FileDescriptorProto`; returns its `name`. Without opts the entry is *authoritative* (a module's own file) and replaces anything registered under that name — the latest loaded module wins, as a hot code reload needs. With `{snapshot = true}` it is a *snapshot* (a copy of an import embedded by another module): it fills a missing entry but never replaces an existing one; two different snapshots of one file keep the first and log a warning once. Identical bytes are a no-op. Errors on non-string input, undecodable bytes, or a missing `name`. |
| `file(name) -> bytes?` | The registered bytes for a file name as imported (`'google/api/http.proto'`). |
| `files() -> {name, ...}` | Every registered name, sorted. |
| `dependencies(name) -> {name, ...}?` | The file's direct imports, in declaration order. |
| `package(name) -> string?` | The file's proto package (`''` when none). |
| `registration_order() -> {name, ...}` | Every registered name in the order it was first registered; replacing a file keeps its place. |
| `generation() -> integer` | Changes whenever a file is added or replaced; anything derived from the registry (the reflection symbol index) caches against it. |

To decode an entry, feed it to `pb.from_pb` wrapped in a one-file
`FileDescriptorSet` (`'\x0a' .. pb.wire.encode_varint(#b) .. b`) or to
`pb.decode(require('pb.descriptor_pb').FileDescriptorProto, b)`.

## Codec dialects

### `pb.json`

Strict proto3 JSON. See `runtime/pb/json.lua` for the canonical-mapping
details (camelCase field names, base64 for `bytes`, RFC 3339 for
`Timestamp`, etc.).

- `pb.json.encode(desc, t [, opts]) -> string` — `opts.use_proto_names`,
  `opts.emit_defaults` (emit fields equal to their defaults, empty
  repeated and map fields), `opts.emit_null_messages` (emit an unset
  singular message field as `null`, as protojson's `EmitUnpopulated`
  does; oneof members and proto3 `optional` fields stay absent),
  `opts.indent`.
- `pb.json.decode(desc, s [, opts]) -> table` —
  `opts.ignore_unknown_fields = true` accepts JSON with extra keys
  (matches the conformance suite's `JSON_IGNORE_UNKNOWN_PARSING_TEST`
  category).
- `pb.json.encode_field(desc, t, field_name [, opts]) -> string` — the
  JSON of one top-level field of `t`, as it would appear under its key
  in `encode`'s output; an unset field renders as its default (`{}`,
  `[]`, or the zero value). Takes `encode`'s options.
- `pb.json.decode_field(desc, field_name, s [, opts]) -> value` — the
  inverse: parse `s` as the JSON of that one field (an object, array or
  scalar); `nil` for JSON `null`.
- `pb.json.json_name(name) -> string` — the lowerCamelCase JSON name of
  a proto field name.

The two field helpers exist for HTTP transcoding (`response_body` and
`body: "<field>"`, see [`pb.transcode`](#httpjson-transcoding--pbtranscode)).

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

## HTTP/JSON transcoding — `pb.transcode`

Maps plain HTTP requests onto the unary methods of generated servers by
their `google.api.http` rules, the scheme of
[`google/api/http.proto`](../../third_party/googleapis/google/api/http.proto) and
[AIP-127](https://google.aip.dev/127). Pure Lua over request/response
tables, no sockets: an HTTP server passes each request in and sends back
what comes out. A walkthrough is in
[howto/15-http-transcoding.md](../howto/15-http-transcoding.md).

```lua
local router = pb.transcode.new(servers [, opts])
local resp   = router:handle(req [, ctx])   -- nil when no route matches
router:routes()                              -- {{method, pattern, path, body?, response_body?}, ...}
router:status_response(st [, ctx])           -- a status object as the router renders errors
```

- `servers` — array of generated server tables (`M.<Svc>_server(impl)`
  results). Rules come from `service.methods.<M>.http`, which the plugin
  and `pb.from_pb` fill from the `google.api.http` option.
- `opts.unbound = true` — also route every unary method without rules as
  `POST /<package.Service>/<Method>` with the whole request as the JSON
  body. Off by default.
- `opts.json` — options for the response JSON (`pb.json.encode`'s),
  merged over the default `{emit_defaults = true, emit_null_messages =
  true}` with camelCase names: grpc-gateway's output, where every field
  is present and an unset singular message is `null` (protojson's
  `EmitUnpopulated`). `{emit_defaults = false, emit_null_messages =
  false}` gives proto3's elided form, `{use_proto_names = true}`
  snake_case names. `new()` rejects unknown keys and wrong value types.
  The body of a 500 does not depend on these options.
- `req = {method, path, headers, body, version, peer}` — `path` as
  received, query string included; header names lowercased.
- `resp = {status, headers, body}` — `content-type: application/json`
  plus whatever the handler put in `ctx.response_metadata`.
- `ctx` — passed to the handler as is. When omitted, the router builds
  `{method = '/pkg.Svc/M', metadata = <request headers minus hop-by-hop
  ones and content-length>, peer = req.peer, response_metadata = {},
  trailing_metadata = {}, is_cancelled = fn -> false}`.

`new()` parses every template and checks it against the request message:
a malformed template, a path variable naming a missing, repeated, map or
message field, or a `body` / `response_body` naming a missing field is
an error that names the method and the pattern. Rules on streaming
methods are skipped with a `log.warn` (streaming transcoding is not
supported).

**Templates.** `/` segments of literals, `*` (one segment), `**` (zero or
more, last only), `{field.path}` and `{field.path=segments}`, and an
optional `:verb`. A request path is split at `/` before any
percent-decoding. A single-segment variable is fully percent-decoded; a
multi-segment one (`{name=shelves/*}`, `{path=**}`) is decoded except
`%2F`/`%2f`, which stay encoded, as http.proto specifies. Literals match
the raw or the percent-decoded segment. When the template has no verb, a
`:suffix` in the request stays part of the last segment.

**Choosing a route.** Only routes of the request's HTTP method are
considered (`custom { kind: "*" }` accepts any). Among templates that
match, segments are compared from the left: a literal beats `*`, which
beats `**`, and a template that has ended beats one that continues with
`**` (`/v1/files` wins over `/v1/{name=files/**}` for `/v1/files`). Then
a template with a verb beats one without, then declaration order:
servers in the order given, methods in the service's `method_order`
(source order; a hand-built service without it falls back to name
order), rules in their `http` order.
A path that matches only under another HTTP method returns `nil`, like
an unknown path, so the caller decides between 404, 405 or a fallback.

**Binding.** The request message is built from:

1. the body, when the rule has one: `body: "*"` decodes the whole JSON
   body into the message, `body: "field"` decodes it into that field.
   An empty body leaves the message (or field) empty. A rule without
   `body` ignores the request body (http.proto: such a rule has none).
2. path variables, written after the body, so a field bound by the path
   wins over the same field in the body (with `body: "*"` the body maps
   only "every field not bound by the path template");
3. query parameters, unless the body is `*`: each key is a dotted field
   path (proto or JSON names per segment); repeated fields take repeated
   keys; enums take names or the numbers of defined values (unlike a
   JSON body, where proto3 enums stay open); signed integers take an
   optional leading `+` or `-`, unsigned ones no sign at all, and 64-bit
   ones become cdata; floats take an optional sign on finite literals,
   reject finite literals that overflow (`1e999`) and take `Infinity`,
   `-Infinity` and `NaN`; bools take `true/false/1/0/t/f` (and
   capitalised forms); bytes take standard or URL-safe base64, padding
   optional but exact; `Timestamp`, `Duration`, `FieldMask` and the
   wrapper types take their ProtoJSON string forms. Keys for fields
   bound by the path or under the body field are skipped; unknown keys
   are ignored (grpc-gateway's behaviour). A map field, a message field
   named directly, a repeated message on the way, a key that continues
   past a non-message field (`count.x`), a second value for a
   non-repeated field, or a second member of a oneof is a 400.

The same value rules apply to path variables. Path, query and body
together may set at most one member of each oneof (the same member
twice is fine: the path overrides the body).

**Calling.** The bound message is encoded, handed to
`server.methods[path](bytes, ctx)` and the result decoded — the same
wrapper a gRPC call goes through, at the cost of one extra encode and
decode per request. A hand-written `methods[path]` function may also
return `nil, code[, message]` instead of raising.

**Responses.** 200 with the response as proto3 JSON, or only its
`response_body` field. A `HEAD` request gets an empty body. Errors use
the `google.rpc.Status` JSON shape `{"code", "message", "details"}` with
`pb.grpc.http_status[code]`:

- a status raised by the handler (`pb.grpc.error`) keeps its code,
  message and details. Details whose type is registered with
  `pb.register` render as their JSON with `@type`; others as `{"@type",
  "value": <base64 of the payload>}`.
- malformed JSON, a value that does not fit its field in the path or
  query, or a malformed percent-escape: 400 `INVALID_ARGUMENT` naming
  the field.
- any other Lua error, and a status with code `OK` raised or returned
  by the handler (a success without a response): 500 `INTERNAL` with
  the message `internal error`, as `pb.server` answers it over gRPC;
  the real error goes to `log.error`.

`ctx.trailing_metadata` has no HTTP/1.1 counterpart and is not sent.

## gRPC server reflection — `pb.reflection`

`grpc.reflection.v1.ServerReflection` and its deprecated twin
`grpc.reflection.v1alpha.ServerReflection`, which `grpcurl`, Postman
and other reflection clients use to discover a server's services and
schemas without `.proto` files. Answers come from the descriptors in
[`pb.descriptors`](#descriptor-registry--pbdescriptors), so every
generated module the application has loaded is visible.

```lua
local greeter = hello_pb.Greeter_server(impl)
local health  = pb.health.new()

local refl = pb.reflection.new({services = {greeter, health:server()}})
local servers = {greeter, health:server()}
for _, s in ipairs(refl:servers()) do table.insert(servers, s) end
local transport = pb.grpc.multiplex(servers)
```

| Function | Semantics |
|---|---|
| `pb.reflection.new(opts?) -> refl` | `opts.services`: what `list_services` reports — an array of generated server tables, service descriptors (`M.<Svc>_service`) or full names, or a function returning such an array on every call. |
| `refl:server(version?) -> server` | Server table for `'v1'` (default) or `'v1alpha'`, the same shape `M.<Service>_server(impl)` returns. |
| `refl:servers() -> {v1, v1alpha}` | Both versions, as grpc-go's `reflection.Register` installs them; older clients speak only v1alpha. |
| `refl:services() -> {name, ...}` | Sorted, de-duplicated names `list_services` answers. The reflection services this instance handed out are always included. |
| `refl:add(service)` | Expose one more service (array form of `opts.services` only). |
| `pb.reflection.servers(opts?)` | `new(opts):servers()`. |
| `pb.reflection.file_containing_symbol(name) -> file?` | The symbol lookup the service uses; see below. |

Behaviour, following grpc-go's reflection service:

- `file_by_filename`, `file_containing_symbol`, `file_containing_extension`
  answer the file plus its transitive imports, breadth first. Files
  already sent on the same stream are skipped, except the requested
  file itself, which is always sent. Imports missing from the registry
  are skipped.
- Symbols resolve as protobuf-go's registry resolves them: messages
  (nested ones and map entries included), enums, enum values (in the
  scope around their enum: `hello.OK`, not `hello.Status.OK`), fields,
  oneofs, extensions, services and methods (`hello.Greeter.SayHello`).
  The index is built from the descriptor bytes on first use and rebuilt
  when `pb.descriptors` changes.
- Files are indexed in registration order. A file that declares a name
  an earlier file already declares is left out as a whole, and a warning
  is logged once, as protobuf-go's registry refuses it with "name
  conflict": serving both would hand a client two files defining one
  type, which do not link. A left-out file is served as if unregistered:
  asked for by name it is `NOT_FOUND`, as an import it is skipped like a
  missing one. `pb.descriptors` keeps it, so a reload that removes the
  conflict brings it back. Replacing a file under its own name is not a
  conflict.
- Extensions are indexed from the registered descriptors:
  `all_extension_numbers_of_type` answers the sorted numbers (an empty
  list for a known type without extensions).
- Anything not found is an `error_response` with `NOT_FOUND`; the stream
  goes on. A request with no field of `message_request` set fails the
  stream with `INVALID_ARGUMENT`.
- `valid_host` echoes the request's `host`; `original_request` echoes
  the request.

The service modules are generated by `protoc-gen-tarantool` from the
unmodified upstream `.proto` files (`third_party/grpc-proto`) into
`pb.gen.grpc.reflection.v1.reflection_pb` and
`pb.gen.grpc.reflection.v1alpha.reflection_pb`; their generated clients
talk to any reflection server over a transport.

## gRPC health — `pb.health`

`grpc.health.v1.Health`, the service load balancers, Kubernetes gRPC
probes and `grpc_health_probe` query.

```lua
local h = pb.health.new()
h:set('hello.Greeter', 'SERVING')
local transport = pb.grpc.multiplex({greeter, h:server()})
-- on the way down:
h:shutdown()
```

| Function | Semantics |
|---|---|
| `pb.health.new(opts?) -> h` | The whole server (`''`) starts `SERVING`. `opts.poll_interval` (seconds, default 1): how often a `Watch` with no status change checks its caller is still there. |
| `h:set(service, status) -> ok` | `status` is `'SERVING'`, `'NOT_SERVING'`, `'SERVICE_UNKNOWN'`, `'UNKNOWN'` or the number. Returns `false` (and changes nothing) after `shutdown()`. |
| `h:get(service) -> name?` | Current status name, `nil` for a service never set. |
| `h:shutdown()` / `h:resume()` | Every service `NOT_SERVING` and later `set()` ignored / every service `SERVING` and `set()` works again. |
| `h:server() -> server` | Server table for `grpc.health.v1.Health`. |
| `h:watchers(service) -> n` | Open `Watch` calls for a service. |
| `pb.health.status` | `{UNKNOWN = 0, SERVING = 1, NOT_SERVING = 2, SERVICE_UNKNOWN = 3}`. |

Methods, as grpc-go's health server answers them:

- `Check`: the stored status; `NOT_FOUND` for a service never set.
- `List`: every stored status; more than `pb.health.MAX_LIST` (100)
  services fail with `RESOURCE_EXHAUSTED`.
- `Watch`: the current status at once (`SERVICE_UNKNOWN` for a service
  never set, without ending the call), then each change; the same
  status twice in a row is sent once. The call runs until the client
  cancels. Each watch waits on its own `fiber.cond`; it ends when a
  `send` reports the caller gone or, with no change to send, within
  `poll_interval` of the cancel (via the stream's or `ctx`'s
  `is_cancelled`).

The module is generated from the upstream `grpc/health/v1/health.proto`
into `pb.gen.grpc.health.v1.health_pb`.

## The Connect protocol — `pb.connect`

The [Connect protocol](https://connectrpc.com/docs/protocol/) for
generated servers, as a function over buffered HTTP request/response
tables (the contract of tarantool-http2's HTTP handler, the same as
`pb.transcode`'s). `pb.server` builds one by default; the walkthrough,
with what the buffered transport cannot do, is
[howto/17-connect.md](../howto/17-connect.md).

```lua
local h    = pb.connect.new(servers [, opts])
local resp = h:handle(req)           -- nil when req is not a Connect call
local call = h:match(req)            -- {proc, mode, codec, query?, strong, reject?} | nil
local resp = h:serve(call, req)
h:reject(req)                        -- 415/405 for a procedure path, else nil
h:not_found(req)                     -- Connect-shaped 404 for a plainly Connect request, else nil
h:procedures()                       -- {{path, kind, get}, ...}
```

- `servers` — generated server tables; every `methods[path]` and
  `streams[path]` becomes a procedure at its path.
- `opts.json` — `pb.json.encode` options for JSON responses (default:
  `pb.json`'s, defaults omitted, camelCase names).
- `opts.max_recv_message_size` — largest request message in bytes
  (default 4 MiB); larger is `resource_exhausted`. `pb.server` passes
  `limits.max_recv_message_size`.

What `handle` serves:

| Request | Mode |
|---|---|
| `POST`, `content-type: application/proto` or `application/json` (parameters ignored), unary method | unary: bare message in, bare message or JSON error out |
| `GET ?encoding=json\|proto&message=...[&base64=1][&compression=identity][&connect=v1]`, method with `idempotency_level = NO_SIDE_EFFECTS` | unary, the message from the query |
| `POST`, `content-type: application/connect+proto` or `+json`, streaming method | enveloped messages in, enveloped messages and an EndStreamResponse out, HTTP 200 |

`match` returns `strong = true` when the request can only be Connect
(a Connect-Protocol-Version header of any value, a protobuf or
enveloped content-type, a `connect` parameter or `encoding=proto` in a
GET); `pb.server` lets its transcoding router try the others first. A
strong request to a procedure path that the handler cannot serve (an
unsupported codec, a streaming content-type on a unary method or the
reverse, a wrong method) is matched too, with `reject` set to the 415
or 405 that `serve` returns.

Handlers get the gRPC `ctx` shape (`method`, `metadata`, `deadline`,
`peer`, `response_metadata`, `trailing_metadata`, `is_cancelled`) plus
`protocol = 'connect'` and `connect = {get, codec, query}`. Request
headers are the metadata except `content-type`, `content-length`,
`content-encoding`, `accept-encoding`, `host`, hop-by-hop headers and
`connect-*`; `-bin` values are decoded from base64 (padded or not; bad
base64 is `invalid_argument`). Response metadata goes out as headers,
trailing metadata as `trailer-<key>` headers (unary) or the
EndStreamResponse `metadata` (streams); `-bin` values as unpadded
base64. `Connect-Timeout-Ms` (at most 10 digits, else
`invalid_argument`) is the deadline: when it passes the call answers
`deadline_exceeded` and the handler, still running in its own fiber,
sees `ctx:is_cancelled()`. `ctx.deadline` and every deadline decision
use `clock.monotonic()` (the origin of `fiber.clock()`, not cached per
event-loop iteration); a handler result that comes after the deadline,
or a unary response whose encoding runs past it, is dropped as well.

Errors: a raised status object keeps its code and message; its details
are sent as `{"type", "value"}` (unpadded base64); code `OK` and plain
errors are `internal` / `internal error` with the real error in the
log. The HTTP status of a unary error follows the protocol's table
(`pb.connect.http_status`, by gRPC code number; the names are in
`pb.connect.code_name`). Other answers: an unsupported
`Content-Encoding` / `Connect-Content-Encoding` / `compression` is
`unimplemented`; `Connect-Protocol-Version` other than `1` or
`connect` other than `v1` is `invalid_argument`; an unknown GET
`encoding` is `415`; in streams, an envelope with the compressed flag
is `internal`, a torn envelope or an end-stream flag in a request
`invalid_argument`, and a server stream with other than one request
message `unimplemented`.

Helpers, exported for tests and other transports:
`pb.connect.envelope(flags, payload)`, `pb.connect.error_json(st)`,
`pb.connect.end_stream_json(st, trailing_metadata)`,
`pb.connect.parse_timeout(v)`, `pb.connect.parse_query(q)`,
`pb.connect.request_metadata(headers)` and
`pb.connect.buffered_io(body)`, the envelope I/O of a streaming call
over an in-memory body (`read`, `write_headers`, `write`, `finish`).

## gRPC and HTTP/JSON server — `pb.server`

A network server built from generated server tables: gRPC over HTTP/2
(h2c, prior knowledge) with all four call kinds, server reflection,
health, `google.api.http` transcoding and the Connect protocol over
HTTP/1.1 and HTTP/2, on one listener. The walkthrough is
[howto/16-network-server.md](../howto/16-network-server.md).

Sockets and HTTP/2 come from the **tarantool-http2** rock
(`require('http2')`, over the system `libnghttp2`), which
`pb.server.new()` loads; without it `new()` raises an error naming the
rock and the library. Nothing else in `pb` needs it.

```lua
local server = pb.server.new({
    listen      = '127.0.0.1:0',   -- or host = ..., port = ...
    services    = {greeter_pb.Greeter_server(impl), ...},
    reflection  = true,
    health      = true,
    transcoding = true,
    connect     = true,
    http        = function(req) ... end,
    limits      = {max_recv_message_size = 4 * 1024 * 1024},
}):start()
server:address()                   -- {host = '127.0.0.1', port = 54321}
server:set_serving_status('hello.Greeter', 'NOT_SERVING')
server:stop(5)
```

| Option | Meaning |
|---|---|
| `listen` | `'host:port'` (`'[::1]:port'` for IPv6) or a port number; or `host` (default `'0.0.0.0'`) and `port` instead. Port `0` picks a free port. A port is required. |
| `services` | Array of generated server tables (`M.<Service>_server(impl)`). |
| `reflection` | Serve `grpc.reflection.v1` and `v1alpha` (default `true`). They list every service the server has: yours, health and reflection. |
| `health` | Serve `grpc.health.v1.Health` (default `true`); a table is passed to `pb.health.new`. `''` and every service in `services` start `SERVING`. |
| `transcoding` | Route HTTP requests by the services' `google.api.http` rules (default `true`); a table is passed to `pb.transcode.new` as its options (`{unbound = true, json = {...}}`). |
| `connect` | Serve the Connect protocol for every service (default `true`); a table is passed to `pb.connect.new` as its options (`{json = {...}}`). |
| `http` | `function(req)` returning a response table or `nil`, called for HTTP requests the router and Connect do not take. |
| `limits` | tarantool-http2 limits. The registry's keys (`max_recv_message_size`, `max_send_message_size`, `recv_buffer_size`, `max_recv_buffer_size`, `send_buffer_size`) go to `http2.grpc.new`, the rest (`max_body_size`, `max_concurrent_streams`, timeouts, ...) to `http2.server.new`. `max_recv_message_size` also bounds Connect request messages. |

An unknown option, a malformed `listen` or a method path served by two
server tables (including a user copy of health or reflection next to
the built-in one) is an error from `new()`.

| Method | Semantics |
|---|---|
| `server:start()` | Bind and serve; raises when the address cannot be bound. Returns the server. |
| `server:address()` | `{host, port}` of the listener, `nil` when not started. |
| `server:stop(timeout?)` | `health:shutdown()` (every service `NOT_SERVING`, so `Watch` callers hear it), then no new connections, `GOAWAY`, and up to `timeout` seconds (default 5) for calls in flight before the rest is closed. An open `Watch` holds the stop for the whole timeout. `start()` after `stop()` serves again with health resumed. |
| `server:set_serving_status(service, status)` | `health:set`; `false` while stopped. Raises when health is disabled. |
| `server:health()` / `server:reflection()` / `server:router()` / `server:connect()` | The `pb.health`, `pb.reflection`, `pb.transcode` and `pb.connect` objects behind the server, `nil` when disabled. |

**gRPC.** Each server table's `methods[path]` is a unary handler and
`streams[path]` a streaming one, registered with http2 under the
path's service name. Handlers receive http2's `ctx`: `method`,
`metadata` (lowercase keys, `-bin` values decoded), `deadline` (a
`fiber.clock()` value), `peer`, `response_metadata` and
`trailing_metadata` for the handler to fill, and `ctx:is_cancelled()`;
`pb.server` adds `protocol = 'grpc'` (`'connect'` over Connect,
`'http'` when transcoded).

- A raised `pb.grpc` status object ends the call with its code and
  message; its `details` are sent as `grpc-status-details-bin` (a
  `google.rpc.Status` with the same code and message). A status with
  code `OK` is treated as a plain error.
- Any other error is `INTERNAL` with the message `internal error`; the
  error and its traceback go to `log.error` (to `log.verbose` when the
  call already ended), never to the client.
- A unary handler may also return `nil, code[, message]`, as with
  `pb.transcode`.
- Streams: `recv()` gives the next message, `nil, nil` once the client
  half-closed, `nil, 'canceled'` after a client reset and `nil,
  <DEADLINE_EXCEEDED status>` after the deadline. `send()` returns
  `false` once the client is gone and raises `RESOURCE_EXHAUSTED` for a
  message over `max_send_message_size`. Returning from the handler ends
  the call with `OK`. A server-streaming handler gets the request
  message the client sent, once the client has half-closed; zero or
  several request messages are a cardinality violation answered
  `UNIMPLEMENTED` without running the handler.
- The server answers `UNIMPLEMENTED` for unknown methods and
  `DEADLINE_EXCEEDED` when a deadline passes; the handler fiber is not
  cancelled and should poll `ctx:is_cancelled()`.

**HTTP.** Every HTTP/1.1 request and every HTTP/2 request without a
gRPC content-type goes, in order, to: Connect when the request can
only be Connect (`pb.connect`'s `strong` match); the transcoding
router; Connect for a plain JSON call to a procedure path; the `http`
fallback; Connect's `415`/`405` for a procedure path with the wrong
content-type or method. What is left gets a 404: in the Connect error
shape for a plainly Connect request, otherwise with a
`google.rpc.Status` JSON body (`{"code": 5, "message": "no route for
GET /path", "details": []}`), rendered by the router with its JSON
options, so it matches the router's own errors (no `details` under
`emit_defaults = false`). Transcoded calls run with the `ctx`
`pb.transcode` builds from the request (metadata from its headers, its
peer, no deadline).

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
