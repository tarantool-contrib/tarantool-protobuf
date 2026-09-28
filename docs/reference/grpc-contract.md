# gRPC transport contract

The four-method interface every transport implements, and the
stream-object shapes that flow between transport and generated code.

This page is the **shipped, stable surface** of `runtime/pb/grpc.lua`.
Forward-looking spec work (which external transports to build,
status-code mapping, Connect vs HTTP/2 vs IProto trade-offs) lives in
[../specs/grpc_transports.md](../specs/grpc_transports.md).

For the *user-facing* shape of `M.<Service>_client` and
`M.<Service>_server` see
[generated-api.md → per-service symbols](generated-api.md#per-service-symbols).

## The transport interface

A transport is any Lua table implementing these four methods:

```lua
transport:unary(path, req_bytes, ctx)         -> resp_bytes
transport:server_stream(path, req_bytes, ctx) -> stream
transport:client_stream(path, ctx)            -> stream
transport:bidi(path, ctx)                     -> stream
```

- `path` is `/<pkg>.<Service>/<Method>`. Always slash-prefixed; same
  format as the gRPC wire-level `:path` pseudo-header.
- `req_bytes` is the encoded request message (already passed through
  `M.<Input>_encode`).
- `resp_bytes` is the encoded reply, returned to the generated client
  which decodes it via `M.<Output>_decode`.
- `ctx` is an opaque table — reserved keys below.

Errors raised by `error(...)` propagate to the caller verbatim. There
is no built-in retry, fallback, or status-code translation; transports
that need that wrap their core implementation.

### Why this shape

It's HTTP/2-shaped on purpose — path, byte-oriented messages,
streaming — but the contract makes **no commitment to a wire
protocol**. Loopback, multiplex, future HTTP/1.1 (Connect-JSON),
net.box-tunnel, and IProto transports all plug into the same four
methods.

## The stream object — client view

`server_stream`, `client_stream`, and `bidi` return a stream:

```lua
stream:send(bytes)              -- push a message (client_stream, bidi)
stream:close_send()             -- "no more outgoing messages"
stream:recv() -> bytes, err     -- pull next reply; (nil, err_or_nil) ends
stream:cancel()                 -- abort the call, drop pending messages
```

For `server_stream`, `:send` and `:close_send` are no-ops — the initial
request travels via the call's `req_bytes` argument.

Generated client code wraps the raw `bytes`-typed stream with a typed
facade via `pb.grpc.wrap_server_stream` / `pb.grpc.wrap_call`, so user
code sees decoded messages:

```lua
-- Inside a generated Greeter_client(transport):
StreamHellos = function(req, ctx)
    local raw = transport:server_stream("/hello.Greeter/StreamHellos", encode(req), ctx)
    return pb.grpc.wrap_server_stream(raw, M.HelloReply_decode)
end
```

## The stream object — server view

Generated server code hands the impl a view that speaks decoded
messages directly:

```lua
server_view:recv() -> message, err  -- pull next request (client_stream, bidi)
server_view:send(message)           -- push a reply (server_stream, bidi)
```

The handler signals end-of-stream by returning. Errors raised via
`error(...)` propagate to the client as the `err` return of
`stream:recv()`.

`pb.grpc.wrap_server_view(raw, input_decode, output_encode)` is what
generated server code uses to build the view — `input_decode = nil` for
server_stream (no incoming messages past the request) and
`output_encode = nil` for client_stream (no outgoing messages past
the final reply).

## Context (`ctx`)

`ctx` is an opaque table threaded from caller to transport. Standard
keys (none required):

| Key | Type | Meaning |
|---|---|---|
| `ctx.deadline` | number | fiber-clock timestamp (seconds, double). Transport enforces by canceling on overrun. |
| `ctx.headers` | `{string -> string}` | Flat metadata map. Wire-side translation is transport-specific (HTTP headers, IProto headers, …). |
| `ctx.trace_id`, `ctx.span_id` | string | Optional tracing hooks. Transports inject/extract per W3C `traceparent` for HTTP, custom IProto field for net.box. |
| `ctx.options` | table | Per-call overrides (retry policy, etc.). |

User code should not put other keys in `ctx` — more standard keys may
be added.

## Reference transports

### `pb.grpc.loopback(server)`

```lua
local server = M.Greeter_server(impl_table)
local transport = pb.grpc.loopback(server)
local client = M.Greeter_client(transport)

client.SayHello({name = 'Alice'})
```

In-process bridge using `fiber.channel`. Each streaming call spawns a
worker fiber for the handler and pipes messages through a paired
client/server stream view (`pb.grpc.new_stream_pair`). Channels
default to a 16-message buffer; senders block when full, receivers
block when empty.

Use cases: tests, same-process apps (a Tarantool instance that
implements a service and also calls it locally).

### `pb.grpc.multiplex({server1, server2, ...})`

Fans multiple `M.<Service>_server(impl)` results onto one transport.
Errors on duplicate paths. Useful when one Tarantool instance hosts
several services and you want a single shared transport.

```lua
local greeter = MService_server(greeter_impl)
local catalog = CatalogService_server(catalog_impl)
local transport = pb.grpc.multiplex({greeter, catalog})

local greeter_client = MService_client(transport)
local catalog_client = CatalogService_client(transport)
```

### `pb.grpc.new_stream_pair(buf_size)`

Lower-level: build a paired (client_stream, server_stream, state) over
two `fiber.channel`s. Used internally by `loopback`; exposed for
custom transports that want to reuse the framing without
re-implementing the cancel/close-send machinery.

```lua
local client, server, state = pb.grpc.new_stream_pair(buf_size_or_nil)
-- run server-side handler on a fiber that consumes `server`,
-- return `client` from your transport's :bidi(...) implementation.
```

## Writing a custom transport

A transport that talks to a real network endpoint implements the same
four methods. The minimal shape for a unary-only transport:

```lua
local function http_transport(base_url)
    local http = require('http.client').new()
    return {
        unary = function(_, path, req_bytes, ctx)
            local r = http:request('POST', base_url .. path, req_bytes, {
                headers = {['Content-Type'] = 'application/proto'},
                timeout = ctx and ctx.deadline,
            })
            if r.status ~= 200 then
                error(('grpc: HTTP ' .. r.status .. ': ' .. r.reason), 0)
            end
            return r.body
        end,
        -- Streaming methods: error or wrap as one-shot if not supported.
        server_stream = function() error('streaming not supported', 0) end,
        client_stream = function() error('streaming not supported', 0) end,
        bidi          = function() error('streaming not supported', 0) end,
    }
end
```

For full streaming support, return objects implementing the
client-view stream interface (`:send`, `:close_send`, `:recv`,
`:cancel`). A pair of `fiber.channel`s plus the
`pb.grpc.new_stream_pair` helper covers most in-process needs;
networked transports drive the channels from their I/O callback.

A worked example (a `net.box` tunnel stub) ships in
`examples/grpc/transport_netbox_stub.lua`; see also
[howto/13-custom-transport.md](../howto/13-custom-transport.md).

## Helpers used by generated code

These wrap a transport-level (bytes-typed) stream with a typed
(message-typed) facade. Application code rarely calls them directly;
they're documented here so custom-transport authors know what the
generated client/server code expects on either side.

| Helper | Used by | Wraps |
|---|---|---|
| `pb.grpc.wrap_server_stream(raw, output_decode)` | generated client (server-stream methods) | adds `:recv -> decoded` to a raw `:recv -> bytes` stream |
| `pb.grpc.wrap_call(raw, input_encode, output_decode)` | generated client (client-stream + bidi) | adds `:send(msg)` / `:recv -> decoded` |
| `pb.grpc.wrap_server_view(raw, input_decode, output_encode)` | generated server | conditionally adds `:send` and `:recv` based on streaming kind |
