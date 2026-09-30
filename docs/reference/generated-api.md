# Generated module API

What `protoc-gen-tarantool` emits per `.proto` file. The plugin produces
one `<file>_pb.lua` module per input proto; this page is the surface
that module exposes.

For the *runtime* API (`require('pb')`) see
[runtime-api.md](runtime-api.md). For where each piece comes from see
[../codegen.md](../codegen.md).

## Module shape

A file `pkg/foo.proto` with `package pkg;` is generated as
`pkg/foo_pb.lua` and required as `pkg.foo_pb`. Prefix / module-path
overrides are documented in [cli.md](cli.md).

```lua
local M = require('pkg.foo_pb')
return M
```

Every symbol below lives under that returned table.

## Per-message symbols

For each message `Foo` in the proto file:

| Symbol | Type | Notes |
|---|---|---|
| `M.Foo_descriptor` | table | The descriptor consumed by `pb.encode` / `pb.decode` / `pb.decode_lazy`. Shape: [codegen.md → descriptor table](../codegen.md#the-descriptor-table--the-contract). |
| `M.Foo_new(t)` | `t or {}` | Placeholder constructor; currently just `t or {}`. Reserved for future validation/defaulting. |
| `M.Foo_encode(t)` | `(table) -> string` | Table → wire bytes. In full mode the body is inlined; in runtime mode it delegates to `pb.encode(M.Foo_descriptor, t)`. |
| `M.Foo_decode(b)` | `(string) -> table` | Wire bytes → table. Same inline/delegate split as encode. Unknown fields land under `t._unknown_fields`. |
| `M.Foo_decode_lazy(b)` | `(string) -> MessageView` | Zero-copy view. See [api-modes.md → lazy](../api-modes.md#lazy-zero-copy-view). |
| `M.Foo_text(t [, opts])` | `(table [, opts]) -> string` | mainline-protoc text format. `opts.single_line = true` for one-line output, `opts.indent = '<string>'` to override default `'  '`. |
| `M.Foo_fields` | strict table | `{field_name = "field_name", ...}` for typo-safe lazy-view access: `view:get(M.Foo_fields.user_id)`. Unknown keys error. |
| `M.Foo_oneofs` | strict table | `{group_name = "group_name", ...}`, only emitted when the message has any oneofs. Used with `view:which(M.Foo_oneofs.outcome)`. |
| `M.Foo_has_<field>(t)` | `(table) -> bool` | Only emitted for proto3 explicit-`optional` fields. Distinguishes "absent" from "set to default". |
| `M.Foo_clear_<field>(t)` | `(table) -> nil` | Same; unsets the field. |

**Text-format decode** has no per-message wrapper — call
`pb.text.decode(M.Foo_descriptor, text)` directly. It's used in a few
spots (conformance runner, debug tools) and didn't warrant codegen
surface.

**JSON encode/decode** likewise has no per-message wrapper — call
`pb.json.encode(M.Foo_descriptor, t)` and
`pb.json.decode(M.Foo_descriptor, s [, opts])`.

### Field types in the table

| Proto type | Lua type |
|---|---|
| `string` | `string` |
| `bytes` | `string` |
| `bool` | `boolean` |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32`, `enum` | Lua `number` (integer) |
| `int64`, `sint64`, `sfixed64` | `int64_t` cdata |
| `uint64`, `fixed64` | `uint64_t` cdata |
| `float`, `double` | Lua `number` (float) |
| `repeated T` | 1-based contiguous Lua array |
| `map<K, V>` | Lua table keyed by `K` (cdata keys are dedup'd via pointer-vs-value comparison on decode) |
| nested message | nested Lua table (recursive) |
| `oneof` member | only the active member is present in the table |

**Absence vs default:** a field that is not on the wire decodes to
`nil` whatever its kind — defaults are not materialized, so read an
absent implicit field as its default yourself (`t.count or 0`). A field
on the wire holding its default comes back with that value. For
explicit-`optional` fields the `_has_<field>` helper tells presence
apart from the default.

**`box.NULL`-equivalent:** `pb.NULL` is the canonical null sentinel
for `google.protobuf.Value` null and JSON null. Prefer it over
`box.NULL` so code doesn't depend on `box` being loaded.

### Unknown fields

Decoded messages with fields the schema doesn't recognize keep the
raw bytes in `t._unknown_fields` (a single string, in encounter
order). Re-encoding splices them back at the tail. WKT messages and
map entries skip this — they have custom `desc.encode/decode`.

## Per-enum symbols

For each enum `Color`:

| Symbol | Type | Notes |
|---|---|---|
| `M.Color_descriptor` | `{name, by_name, by_value}` | `by_name.RED = 0`, `by_value[0] = 'RED'`. |
| `M.Color` | alias | Shorthand for `M.Color_descriptor.by_name`. Use as `M.Color.RED`. |

Generated `_pb.lua` reserves only `Color_descriptor` and the alias.
There are no `Color_encode` / `Color_decode` wrappers — enums live
inside other messages, not on the wire by themselves.

Unknown enum values are passed through as their numeric form. Lua
table fields hold the integer; enum-aware printing/JSON converts back
to the name when the value is known.

## Per-service symbols

For each `service Greeter` in the proto file:

```lua
M.Greeter_service               -- descriptor (name, methods, paths)
M.Greeter_client(transport)     -- factory: returns {Method = fn(req, ctx)}
M.Greeter_server(impl)          -- factory: returns {service, methods}
```

### `M.<Service>_service`

```lua
{
    name       = "hello.Greeter",
    full_name  = "/hello.Greeter",
    methods    = {
        [<Method>] = {
            name              = "<Method>",
            full_name         = "/hello.Greeter/<Method>",
            input             = M.<Input>_descriptor,
            output            = M.<Output>_descriptor,
            client_streaming  = <bool, only if true>,
            server_streaming  = <bool, only if true>,
            http              = <google.api.http rules, only if annotated>,
            options           = <MethodOptions, only if any are set>,
        },
        ...
    },
}
```

`http` is present when the method carries a `google.api.http`
annotation (`import "google/api/annotations.proto";`). It is the rule
flattened into an array — the primary binding first, then each of its
`additional_bindings` in declaration order:

```lua
http = {
    {method = 'GET',  pattern = '/v1/{name=shelves/*/books/*}'},
    {method = 'POST', pattern = '/v1/books:lookup', body = '*', response_body = 'book'},
},
```

- `method` is `GET`, `PUT`, `POST`, `DELETE` or `PATCH`, or the `kind`
  of a `custom {kind, path}` pattern verbatim (e.g. `HEAD`);
- `pattern` is the path template as written (`{field}`,
  `{field=segments}`, `*`, `**`, nested `{a.b}`, a trailing `:verb`);
- `body` / `response_body` appear only when set in the rule.

The same annotation also stays in the method's `options` table under
`["google.api.http"]`, in raw `HttpRule` shape (see
[README → Descriptor options](../../README.md#descriptor-options)).
That is deliberate: `options` mirrors every extension of the
descriptor alike, `http` is the normalised form a transcoder routes on.
`pb.from_pb` produces the same `http` field from a `FileDescriptorSet`.

The four streaming flavors fall out of those two booleans:

| Streaming flavor | `client_streaming` | `server_streaming` |
|---|---|---|
| Unary | absent | absent |
| Server-stream | absent | `true` |
| Client-stream | `true` | absent |
| Bidi | `true` | `true` |

### `M.<Service>_client(transport) -> {Method = fn(...)}`

Pass any object implementing the four-method transport contract from
[grpc-contract.md](grpc-contract.md). The returned table has one
entry per RPC, shaped per its streaming flavor:

```lua
local client = M.Greeter_client(pb.grpc.loopback(server))

-- Unary: encode req, call transport:unary, decode resp.
local reply = client.SayHello({name = 'Alice'}, ctx)

-- Server-stream: returns a stream; iterate with :recv()/:close().
local stream = client.StreamHellos({name = 'Alice'}, ctx)
for msg in function() return stream:recv() end do ... end

-- Client-stream: returns a call; :send(req) / :close_send() / :recv() once.
local call = client.CollectHellos(ctx)
call:send({name = 'Alice'}); call:send({name = 'Bob'})
call:close_send()
local reply = call:recv()

-- Bidi: returns a call; :send and :recv interleave freely.
local call = client.Chat(ctx)
fiber.create(function() for msg in ... do call:send(msg) end; call:close_send() end)
for reply in function() return call:recv() end do ... end
```

`ctx` is whatever opaque table the transport understands (deadlines,
metadata, etc.). The contract reserves `ctx.deadline`, `ctx.headers`,
`ctx.trace_id`, `ctx.span_id`, `ctx.options`; see
[grpc-contract.md](grpc-contract.md).

### `M.<Service>_server(impl) -> {service, methods}`

`impl` is a table with one Lua function per RPC. Signatures depend on
the streaming flavor:

```lua
local server = M.Greeter_server({
    -- Unary
    SayHello = function(req, ctx) return {greeting = 'Hi ' .. req.name} end,

    -- Server-stream: receive req + a stream to push replies onto
    StreamHellos = function(req, stream, ctx)
        for i = 1, 3 do stream:send({greeting = 'Hi #' .. i}) end
        stream:close()
    end,

    -- Client-stream: receive a stream + ctx; collect requests, return one reply
    CollectHellos = function(stream, ctx)
        local names = {}
        for req in function() return stream:recv() end do
            names[#names + 1] = req.name
        end
        return {greeting = 'Hi ' .. table.concat(names, ', ')}
    end,

    -- Bidi: receive a stream; send/recv interleave
    Chat = function(stream, ctx)
        for req in function() return stream:recv() end do
            stream:send({greeting = 'Echo ' .. req.name})
        end
        stream:close()
    end,
})
```

The returned `{service, methods}` plugs into any transport:

```lua
local transport = pb.grpc.loopback(server)  -- in-process
local transport = pb.grpc.multiplex({server, other_server})
```

## File-level boilerplate

Every generated module starts with:

```lua
-- Code generated by protoc-gen-tarantool. DO NOT EDIT.
-- source: <file>.proto
-- syntax: proto3

local pb = require('pb')
local wire = pb.wire

local M = {}
-- ... enums, descriptors, fields tables, encoders/decoders ...
return M
```

Every generated module ends by embedding its file's descriptor:

```lua
M._file_descriptor = table.concat({ "\x0a\x0bhello.proto...", ... })
pb.descriptors.register(M._file_descriptor)
```

`M._file_descriptor` is the serialized `google.protobuf.FileDescriptorProto`
of the source file — exactly what protoc handed the plugin, with
`source_code_info` stripped (as protoc-gen-go does) and fields in
deterministic order. Loading the module registers it with
[`pb.descriptors`](runtime-api.md#descriptor-registry--pbdescriptors),
the input server reflection answers from. The import graph is covered
too:

- imports generated in the same protoc run are `require`d even when no
  field references them, so their modules register themselves;
- imports that are neither generated in the same run nor shipped with
  the runtime (the well-known types and `google/api/{annotations,http}.proto`
  are) — typically option files such as `tarantool/tarantool.proto` that
  are only on the `-I` path — have their descriptors embedded and
  registered by the importing module.

Registration runs once per module load and costs nothing on the
encode/decode paths.

EmmyLua / lua-language-server annotations are emitted alongside each
descriptor:

```lua
---@class hello.Person
---@field name string
---@field user_id integer
-- ...
```

Class identifiers use the full proto name (`hello.Person`,
`hello.Address`) so cross-file references resolve in editors. Lazy
view types (`pb.MessageView`, `pb.ArrayView`, `pb.MapView`) are
declared inline in `runtime/pb/lazy.lua` so the LSP sees them.

## Two emission modes

`mode=full` (default) inlines the encode/decode bodies; `mode=runtime`
emits one-line wrappers that delegate to `pb.encode` / `pb.decode`.
**Every other symbol on this page is mode-independent** — descriptor
tables, the lazy wrappers, text/JSON delegation, the
`_fields` / `_oneofs` strict tables, services, EmmyLua annotations
are identical across modes. See
[api-modes.md](../api-modes.md#full-inline-codegen) for the per-mode
trade-offs and how to pick.
