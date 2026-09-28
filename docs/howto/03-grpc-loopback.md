# How-to: gRPC with the loopback transport

End-to-end Greeter service running entirely in-process: same Tarantool
instance hosts the server, calls it through a generated client. The
loopback transport (`pb.grpc.loopback`) bridges the two via
`fiber.channel` — no network, no HTTP/2 library, no external
dependencies.

This is the path for tests, same-process apps, and any scenario where
you want gRPC's ergonomics without leaving the process.

For real (external) transports the contract is documented in
[reference/grpc-contract.md](../reference/grpc-contract.md); a
worked example of writing your own lives in
[how-to: custom transport](13-custom-transport.md).

## The proto

We use the `Greeter` service from `examples/proto/hello.proto`. All
four streaming flavors:

```proto
service Greeter {
  rpc SayHello(HelloRequest) returns (HelloReply);
  rpc Echo(HelloRequest) returns (HelloRequest);
  rpc StreamHellos(HelloRequest) returns (stream HelloReply);
  rpc CollectHellos(stream HelloRequest) returns (HelloReply);
  rpc Chat(stream HelloRequest) returns (stream HelloReply);
}

message HelloRequest { string name = 1; }
message HelloReply   { string greeting = 1; }
```

The repo regenerates this on `just gen`. For a project of your own:
`protoc --tarantool_out=./gen hello.proto`.

## The server

Plain Lua table with one function per RPC. Streaming functions
receive a `stream` parameter that exposes `:send`, `:recv`, etc. (see
[grpc-contract.md → stream object — server view](../reference/grpc-contract.md#the-stream-object--server-view)).

`examples/grpc/server.lua`:

```lua
local pb = require('pb')
local hello = require('full.hello.hello_pb')

local impl = {
    -- Unary: req in, reply out.
    SayHello = function(req, _ctx)
        return {greeting = 'Hi ' .. req.name}
    end,

    -- Server-stream: push N replies then return.
    StreamHellos = function(req, stream, _ctx)
        for i = 1, 3 do
            stream:send({greeting = ('Hi #%d %s'):format(i, req.name)})
        end
    end,

    -- Client-stream: pull until peer closes, return one reply.
    CollectHellos = function(stream, _ctx)
        local names = {}
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                break
            end
            names[#names + 1] = req.name
        end
        return {greeting = 'Hi ' .. table.concat(names, ', ')}
    end,

    -- Bidi: pull a request, push a reply, repeat until peer closes.
    Chat = function(stream, _ctx)
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                return
            end
            stream:send({greeting = 'Echo ' .. req.name})
        end
    end,
}

local server = hello.Greeter_server(impl)
return pb.grpc.loopback(server)
```

## The client

`examples/grpc/client.lua`:

```lua
local fiber = require('fiber')
local hello = require('full.hello.hello_pb')

local transport = dofile('examples/grpc/server.lua')  -- builds loopback
local client = hello.Greeter_client(transport)

-- Unary
print(client.SayHello({name = 'Alice'}, {}).greeting)

-- Server-stream
local s = client.StreamHellos({name = 'Bob'}, {})
while true do
    local msg, err = s:recv()
    if msg == nil then break end
    print(msg.greeting)
end

-- Client-stream: send N, close, recv one
local c = client.CollectHellos({})
c:send({name = 'Alice'}); c:send({name = 'Bob'}); c:send({name = 'Carol'})
c:close_send()
print(c:recv().greeting)

-- Bidi: send on one fiber, recv on another
local b = client.Chat({})
fiber.create(function()
    for _, name in ipairs({'X', 'Y', 'Z'}) do b:send({name = name}) end
    b:close_send()
end)
while true do
    local msg, err = b:recv()
    if msg == nil then break end
    print(msg.greeting)
end
```

Run it:

```bash
LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;" \
    tarantool examples/grpc/client.lua
```

Expected output:

```
--- unary ---
Hi Alice
--- server-stream ---
Hi #1 Bob
Hi #2 Bob
Hi #3 Bob
--- client-stream ---
Hi Alice, Bob, Carol
--- bidi ---
Echo X
Echo Y
Echo Z
```

## Streaming patterns

### Bidi from a single fiber

The example above splits the bidi call across two fibers (one
sends, the main fiber receives). That's the safest pattern — `:send`
blocks when the channel buffer fills, so doing both from one fiber
risks self-deadlock if you're not careful.

Single-fiber bidi works when send/recv naturally interleave: send,
recv, send, recv, …

```lua
local b = client.Chat({})
for _, name in ipairs({'X', 'Y', 'Z'}) do
    b:send({name = name})
    print(b:recv().greeting)
end
b:close_send()
```

### Cancellation

Either side can cancel mid-stream:

```lua
local s = client.StreamHellos({name = 'Bob'}, {})
local first = s:recv()
s:cancel()  -- drop the rest
```

Cancellation closes the channel; the server-side `:send` raises
`pb.grpc: stream canceled` on the next attempt. Handlers that don't
need to react gracefully can ignore the raise — the fiber unwinds and
the call ends.

### Handler errors propagate

Errors raised in the server's handler surface as the `err` return on
the client's next `:recv()`:

```lua
StreamHellos = function(req, stream, _ctx)
    stream:send({greeting = 'first'})
    error('boom!', 0)
end

-- Client side:
local s = client.StreamHellos({name = 'x'}, {})
local r1 = s:recv()                  -- {greeting = 'first'}
local r2, err = s:recv()             -- nil, "boom!"
```

The first message goes through; the error surfaces when the channel
drains.

## The `ctx` argument

The second-or-third argument to every RPC is `ctx`, an opaque table.
Standard reserved keys (`ctx.deadline`, `ctx.headers`,
`ctx.trace_id`, `ctx.span_id`, `ctx.options`) are documented in
[grpc-contract.md → context](../reference/grpc-contract.md#context-ctx).

The `loopback` transport doesn't enforce deadlines today — it threads
`ctx` to the handler unchanged. Real external transports that
implement the contract are expected to honor the standard keys.

## Multiple services on one transport

```lua
local greeter = hello.Greeter_server(greeter_impl)
local catalog = catalog.Catalog_server(catalog_impl)

local transport = pb.grpc.multiplex({greeter, catalog})

local greeter_client = hello.Greeter_client(transport)
local catalog_client = catalog.Catalog_client(transport)
```

`pb.grpc.multiplex` errors on duplicate paths, so two services with
the same package + service name will fail loudly at setup time, not
silently at the first dispatch.

## What's next

- [Reference: grpc-contract](../reference/grpc-contract.md) — the
  shipped contract, stream objects, helper wrappers.
- [How-to: custom transport](13-custom-transport.md) — when you
  need to talk to a real network endpoint.
- [Specs: gRPC transports](../specs/grpc_transports.md) — the
  protocol matrix (HTTP/2 gRPC vs Connect vs net.box vs IProto) and
  why we recommend each.
