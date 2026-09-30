# How-to: writing a custom transport

A "transport" is any Lua table implementing the four-method contract
documented in
[reference/grpc-contract.md](../reference/grpc-contract.md):
`:unary`, `:server_stream`, `:client_stream`, `:bidi`. Generated
`M.<Service>_client(transport)` accepts any object matching that
shape — wire protocol, framing, and connection management are
transport-private concerns.

The shipped reference transports (`pb.grpc.loopback`,
`pb.grpc.multiplex`) handle in-process routing. For anything across a
process boundary, you write a transport.

This how-to walks through three escalating cases.

## Case 1: unary-only HTTP/1.1 client

Outbound calls to a service that speaks Connect-JSON (or HTTP/1.1
gRPC-Gateway) over a single POST endpoint. Unary is enough for many
use cases.

```lua
local function http_unary_transport(base_url)
    local http = require('http.client').new()
    return {
        unary = function(_, path, req_bytes, ctx)
            local r = http:request('POST', base_url .. path, req_bytes, {
                headers = {['content-type'] = 'application/proto'},
                timeout = ctx and ctx.deadline,
            })
            if r.status ~= 200 then
                error('grpc: HTTP ' .. r.status, 0)
            end
            return r.body
        end,
        -- Streaming methods explicitly error rather than silently
        -- returning nil — caller learns at setup time, not on first
        -- failed message.
        server_stream = function() error('streaming not supported', 0) end,
        client_stream = function() error('streaming not supported', 0) end,
        bidi          = function() error('streaming not supported', 0) end,
    }
end

-- Plug into a generated client:
local client = hello.Greeter_client(http_unary_transport('http://api.example.com'))
client.SayHello({name = 'Alice'}, {})
```

The bytes the generated code passes you (`req_bytes`) are already
encoded; you put them on the wire as-is. Same on the way back —
`r.body` is the encoded reply that the generated client will decode.

## Case 2: net.box tunnel (in-cluster)

For Tarantool↔Tarantool calls, the simplest pattern is a stored
function that dispatches into a `M.<Service>_server` and a client
that calls it via `net.box`. The runnable stub:
`examples/grpc/transport_netbox_stub.lua`.

Server side (one stored function, all services):

```lua
local function register_server(server, func_name)
    func_name = func_name or 'grpc_dispatch'
    rawset(_G, func_name, function(path, req_bytes)
        local handler = server.methods[path]
        if handler == nil then
            return {false, 'unknown method: ' .. path}
        end
        local ok, resp = pcall(handler, req_bytes, {})
        if not ok then return {false, tostring(resp)} end
        return {true, resp}
    end)
end
```

Client side:

```lua
local function netbox_client(conn, func_name)
    func_name = func_name or 'grpc_dispatch'
    return {
        unary = function(_, path, req_bytes, _ctx)
            local r = conn:call(func_name, {path, req_bytes})
            if not r[1] then error('grpc: ' .. tostring(r[2]), 0) end
            return r[2]
        end,
        server_stream = function() error('streaming not supported in stub', 0) end,
        client_stream = function() error('streaming not supported in stub', 0) end,
        bidi          = function() error('streaming not supported in stub', 0) end,
    }
end

local conn = require('net.box').connect('user:pass@localhost:3301')
local client = hello.Greeter_client(netbox_client(conn))
```

This stub punts on streaming. A production net.box transport would
use `box.session.push` for server-stream messages and a stateful
session for client-stream / bidi.

## Case 3: full streaming over a paired channel

When you need all four streaming flavors, the pattern is:

1. Drive a paired client/server stream over your wire (channels,
   sockets, HTTP/2 streams — whatever you have).
2. Implement the client-view stream interface
   (`:send` / `:close_send` / `:recv` / `:cancel`).
3. Return that stream object from `:server_stream` / `:client_stream`
   / `:bidi`.

`pb.grpc.new_stream_pair(buf_size)` returns paired client/server
views over two `fiber.channel`s. Use it as the in-process half of a
network transport — the fiber that drives the channels writes/reads
from your actual wire.

Sketch of the I/O fiber pattern:

```lua
local fiber = require('fiber')

local function bidi_call(socket, path, ctx)
    local client_view, server_view, state = pb.grpc.new_stream_pair()

    -- Reader fiber: bytes from the wire -> server_view (which is the
    -- client_view's counterpart for inbound messages).
    fiber.create(function()
        while true do
            local frame, err = socket:read_frame()
            if frame == nil then
                if err then state.server_err = err end
                client_view:close_send()  -- closes the reader path
                return
            end
            server_view:send(frame.payload)  -- delivered to client_view:recv()
        end
    end)

    -- Writer fiber: outbound from client_view -> wire.
    fiber.create(function()
        while true do
            local bytes, err = server_view:recv()  -- pulls what client sent
            if bytes == nil then return end
            socket:write_frame({path = path, payload = bytes})
        end
    end)

    return client_view
end
```

The fiber.channel buffers decouple send/recv timing on each side.
Senders block when the buffer is full; receivers block when it's
empty. Default size is 16 messages — override per call via
`new_stream_pair(buf_size)`.

## Conventions every transport should honor

- **Path format.** `/<package>.<Service>/<Method>`. Don't strip the
  leading slash — generated code emits it.
- **Error propagation.** Errors flow as `error(...)` calls. Don't
  swallow them; transports may wrap with their own message prefix
  (`'grpc: ' .. err`) but the generated client expects to see the
  error. A status object (`pb.grpc.is_status(err)`) must reach the
  client as a status object with the same `code`, `message` and
  `details`: raise it again rather than wrapping it in a string.
- **`ctx` keys.** Honor `ctx.deadline` (cancel on overrun),
  `ctx.headers` (transport-specific encoding), `ctx.trace_id` /
  `ctx.span_id` (inject as the wire's tracing primitive). See
  [grpc-contract.md → context](../reference/grpc-contract.md#context-ctx).
- **Empty `ctx`.** Generated clients pass `ctx = {}` if the caller
  didn't supply one. Don't assume keys exist; use `ctx and ctx.foo`.
- **Cancel semantics.** `stream:cancel()` should release resources
  promptly. Tolerate it being called twice (e.g. after the stream
  already closed).

## Testing your transport against the loopback

A useful pattern for transport development is to run the same test
suite against both `pb.grpc.loopback` and your transport. Loopback
gives you the reference behavior; if a test passes against loopback
but fails against yours, the bug is in the transport.

```lua
local function test_against(transport_factory)
    return function()
        local server = hello.Greeter_server(impl)
        local transport = transport_factory(server)
        local client = hello.Greeter_client(transport)
        t.assert_equals(client.SayHello({name='X'}, {}).greeting, 'Hi X')
        -- ... full suite ...
    end
end

t.group('greeter.loopback').test = test_against(pb.grpc.loopback)
t.group('greeter.mytransport').test = test_against(make_my_transport)
```

## What's next

- [Reference: grpc-contract](../reference/grpc-contract.md) —
  contract, stream objects, helper wrappers.
- [Specs: gRPC transports](../specs/grpc_transports.md) — the
  protocol matrix and the recommended external transports
  (Connect-JSON server, net.box tunnel, HTTP/2 client) we haven't
  built yet.
