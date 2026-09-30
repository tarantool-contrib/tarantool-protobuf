# How-to: a gRPC, Connect and HTTP/JSON server on one port

`pb.server` turns the generated server tables into a real network
server. One listener answers:

- **gRPC** over HTTP/2 (h2c, prior knowledge), all four call kinds,
  that grpc-go, grpcurl and other off-the-shelf clients talk to;
- **server reflection** (`grpc.reflection.v1` and `v1alpha`), so
  `grpcurl list` works without `.proto` files;
- **health** (`grpc.health.v1.Health`) for load balancers and probes;
- **HTTP/JSON** routed by the services' `google.api.http` rules
  ([how-to 15](15-http-transcoding.md)), over HTTP/1.1 and HTTP/2;
- the **Connect protocol** ([how-to 17](17-connect.md)) for every
  service, over HTTP/1.1 and HTTP/2: `buf curl`'s default, connect-go,
  connect-es and plain `curl`.

```lua
local server = pb.server.new({
    listen   = '0.0.0.0:8080',
    services = {greeter_pb.Greeter_server(impl)},
}):start()
```

## Requirements

Sockets, HTTP/2 and gRPC framing come from the **tarantool-http2** rock
(`require('http2')`), which drives the system `libnghttp2` (≥ 1.57)
through FFI: `brew install nghttp2`, `apt install libnghttp2-dev` or
`dnf install libnghttp2-devel`. The rock is not published yet; install
it from its source tree with `tt rocks make`. Once it is published it
becomes a regular dependency of this rock.

Only `pb.server.new()` needs it. `require('pb')` and everything else
work without the rock or the library; `pb.server.new()` without them
fails with an error naming both.

To run this repository's examples and tests against a checkout of the
rock instead of an installed one, point `TARANTOOL_HTTP2_RUNTIME` at
its `runtime/` directory (an absolute path); the Justfile recipes add
it to `LUA_PATH`:

```bash
export TARANTOOL_HTTP2_RUNTIME=/path/to/tarantool-http2/runtime
just gen
just examples network-server          # starts, calls itself, stops
just examples network-server-listen   # serves on :8080 until Ctrl-C
```

The runnable version of this page is
[`examples/grpc/network_server.lua`](../../examples/grpc/network_server.lua).

## 1. Write the handlers

Handlers are the ones the loopback transport runs
([how-to 03](03-grpc-loopback.md)): they take and return decoded
messages. The example serves `hello.Greeter` and the `library` service
of [how-to 15](15-http-transcoding.md):

```lua
local greeter = hello.Greeter_server({
    SayHello = function(req, ctx)
        -- ctx.metadata holds the request metadata; handlers may add
        -- response (header) and trailing metadata.
        ctx.response_metadata['x-served-by'] = 'tarantool'
        -- A proto3 string left empty decodes as nil.
        if req.name == nil or req.name == '' then
            pb.grpc.error(pb.grpc.code.INVALID_ARGUMENT, 'name is required')
        end
        return {greeting = 'Hello, ' .. req.name}
    end,

    StreamHellos = function(req, stream)
        for i = 1, 3 do
            if stream:send({greeting = ('Hello #%d, %s'):format(i, req.name or '')}) == false then
                return -- the client went away
            end
        end
    end,

    CollectHellos = function(stream)
        local names = {}
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                break -- the client half-closed
            end
            names[#names + 1] = req.name or ''
        end
        return {greeting = 'Hello, ' .. table.concat(names, ', ')}
    end,
    -- Echo and Chat: see the example file.
})
```

## 2. Build and start the server

```lua
local server = pb.server.new({
    listen = '127.0.0.1:' .. port,
    services = {greeter, library},
    -- reflection, health, transcoding and Connect are on by default.
    transcoding = {json = {emit_defaults = false, emit_null_messages = false}},
    http = function(req)
        if req.path == '/' then
            return {status = 200, headers = {['content-type'] = 'text/plain'},
                    body = 'gRPC and HTTP/JSON on one port\n'}
        end
    end,
}):start()
```

`start()` binds at once and raises when it cannot. With port `0` the
system picks a free port; `server:address()` returns `{host, port}`.
Tarantool then keeps serving from its event loop.

## 3. Talk to it

With the interactive recipe running on `:8080`:

```bash
grpcurl -plaintext localhost:8080 list
# grpc.health.v1.Health
# grpc.reflection.v1.ServerReflection
# grpc.reflection.v1alpha.ServerReflection
# hello.Greeter
# library.Library

grpcurl -plaintext localhost:8080 describe library.Library.GetBook
# library.Library.GetBook is a method:
# rpc GetBook ( .library.GetBookRequest ) returns ( .library.Book ) {
#   option (.google.api.http) = { get: "/v1/{name=shelves/*/books/*}" };
# }

grpcurl -plaintext -d '{"name": "Ann"}' localhost:8080 hello.Greeter/SayHello
# { "greeting": "Hello, Ann" }
grpcurl -plaintext -d '{"name": "a"} {"name": "b"}' localhost:8080 hello.Greeter/CollectHellos
# { "greeting": "Hello, a, b" }
grpcurl -plaintext -d '{}' localhost:8080 hello.Greeter/SayHello
# ERROR:
#   Code: InvalidArgument
#   Message: name is required

grpcurl -plaintext -d '{"service": "hello.Greeter"}' localhost:8080 grpc.health.v1.Health/Check
# { "status": "SERVING" }

curl http://localhost:8080/v1/shelves/1/books/1
# {"title":"Dune","name":"shelves/1/books/1","isbn":"42"}
curl --http2-prior-knowledge http://localhost:8080/v1/shelves/1/books/9
# {"code":5,"message":"no book shelves/1/books/9"}   (HTTP 404)
```

(grpcurl prints JSON over several lines; `pb.json` emits keys in hash
order.)

[`buf curl`](https://buf.build/docs/reference/cli/buf/curl/) speaks
the [Connect protocol](17-connect.md) by default. With the schema from
a local file it needs no flags, over HTTP/1.1 (or h2c with
`--http2-prior-knowledge`):

```bash
buf curl --schema examples/proto/hello.proto \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/SayHello
# { "greeting": "Hello, Ann" }
buf curl --schema examples/proto/hello.proto \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/StreamHellos
# { "greeting": "Hello #1, Ann" }
# { "greeting": "Hello #2, Ann" }
# { "greeting": "Hello #3, Ann" }
buf curl --schema examples/proto/hello.proto \
    -d '{}' http://localhost:8080/hello.Greeter/SayHello
# { "code": "invalid_argument", "message": "name is required" }
# (exit status 24: buf curl exits with 8 x the numeric status code)
```

Through server reflection it works over gRPC, given `--protocol grpc
--http2-prior-knowledge`:

```bash
buf curl --protocol grpc --http2-prior-knowledge --list-services http://localhost:8080
# grpc.health.v1.Health
# grpc.reflection.v1.ServerReflection
# grpc.reflection.v1alpha.ServerReflection
# hello.Greeter
# library.Library

buf curl --protocol grpc --http2-prior-knowledge --list-methods http://localhost:8080
# grpc.health.v1.Health/Check
# ...
# hello.Greeter/SayHello
# hello.Greeter/StreamHellos
# ...

buf curl --protocol grpc --http2-prior-knowledge \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/SayHello
# { "greeting": "Hello, Ann" }
buf curl --protocol grpc --http2-prior-knowledge \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/StreamHellos
# { "greeting": "Hello #1, Ann" }
# { "greeting": "Hello #2, Ann" }
# { "greeting": "Hello #3, Ann" }
buf curl --protocol grpc --http2-prior-knowledge \
    -d '{"service": "hello.Greeter"}' http://localhost:8080/grpc.health.v1.Health/Check
# { "status": "SERVING" }
buf curl --protocol grpc --http2-prior-knowledge \
    -d '{"name": "shelves/1/books/9"}' http://localhost:8080/library.Library/GetBook
# { "code": "not_found", "message": "no book shelves/1/books/9" }
# (exit status 40: buf curl exits with 8 x the numeric status code)
```

`--list-methods` and `--list-services` take the base URL only; with a
service name in the URL, the reflection request goes to the wrong path
and fails with `unimplemented: malformed method name`.

**Both flags are required for reflection.** The reflection service is
a bidirectional stream that `buf curl` drives full-duplex: it sends a
request and waits for the answer before it sends the next one or ends
its request. Over Connect, `pb.server` sees a request only once its
body has ended ([how-to 17](17-connect.md#what-works-and-what-does-not)),
so that call never reaches it; over gRPC it works. Leaving the flags
out fails like this:

- no flags: `--reflect cannot be used with plain-text URLs (http)
  unless --http2-prior-knowledge flag is set`, at once;
- `--http2-prior-knowledge` alone: the reflection stream goes out as
  Connect and waits, and after about 30 seconds (the server's
  `request_timeout`) the call fails with the misleading `failed to
  find service named "hello.Greeter" in schema` (a `--list-services`
  fails with `unknown: HTTP status 408 Request Timeout`).

Reflection serves the descriptors the generated modules embed, as the
compiler serialized them: with modules generated by `buf` rather than
`protoc`, option fields come in another order in those bytes, and
decode to the same descriptors
([how-to 12](12-build-integration.md#differences-from-protoc-output)).

`just examples network-server` does the same from inside the process
with Tarantool's `http.client`, then stops the server. It prints:

```
listening on 127.0.0.1:<port>
GET /v1/shelves/1/books/1 -> 200 {"isbn":"42","name":"shelves/1/books/1","title":"Dune"}
POST /v1/shelves/1/books -> 200 {"name":"shelves/1/books/2","title":"Hyperion"}
GET /v1/shelves/1/books/9 -> 404 {"code":5,"message":"no book shelves/1/books/9"}
Connect POST /hello.Greeter/SayHello -> 200 {"greeting":"Hello, Ann"}
Connect POST /hello.Greeter/SayHello -> 400 {"code":"invalid_argument","message":"name is required"}
Connect GET /library.Library/GetBook -> 200 {"isbn":"42","name":"shelves/1/books/1","title":"Dune"}
Connect StreamHellos <- flags 0 {"greeting":"Hello #1, Ann"}
Connect StreamHellos <- flags 0 {"greeting":"Hello #2, Ann"}
Connect StreamHellos <- flags 0 {"greeting":"Hello #3, Ann"}
Connect StreamHellos <- flags 2 {}
gRPC SayHello -> Hello, Ann
gRPC Health.Check(hello.Greeter) -> SERVING
stopped; overall health: NOT_SERVING
```

(The gRPC lines need an `http.client` that speaks HTTP/2 with prior
knowledge, `http_version = '2-prior-knowledge'`; an older Tarantool
prints that it skipped them.)

## Errors, metadata, deadlines

- **Status errors.** A handler raising `pb.grpc.error(code, message,
  details)` fails the call with that status; `details` travel as
  `grpc-status-details-bin`, so grpc-go's `status.FromError(err).Details()`
  and similar APIs see them. Over HTTP/JSON the same status becomes the
  HTTP code of the canonical mapping and a `google.rpc.Status` JSON
  body. Any other error is `INTERNAL` with the message `internal error`;
  the real error and its traceback go to the log, never to the client.
- **Metadata.** `ctx.metadata` holds the request metadata (lowercase
  keys; `-bin` values decoded). Fill `ctx.response_metadata` before the
  first reply and `ctx.trailing_metadata` any time before the handler
  returns.
- **Deadlines and cancellation.** A client deadline arrives as
  `ctx.deadline` (a `fiber.clock()` value) and the server answers
  `DEADLINE_EXCEEDED` when it passes. The handler fiber is not
  cancelled (it may be inside a transaction): long handlers poll
  `ctx:is_cancelled()`. On a stream, `recv()` returns `nil, 'canceled'`
  after a client reset and `nil, <DEADLINE_EXCEEDED status>` after the
  deadline; `send()` returns `false` once the client is gone.
- A request nothing routes gets a 404 in the same `google.rpc.Status`
  shape, after the `http` fallback declined it (a plainly Connect
  request gets the Connect error shape instead, see
  [how-to 17](17-connect.md#routing)).

## Health and shutdown

Every service in `services` is registered `SERVING`, next to the whole
server (`''`). Change a status with
`server:set_serving_status('hello.Greeter', 'NOT_SERVING')`; `Watch`
callers see it at once. `server:health()` is the
[`pb.health`](../reference/runtime-api.md#grpc-health--pbhealth)
object behind it.

`server:stop(timeout)` first marks every service `NOT_SERVING`, so
watchers and load balancers hear it, then stops accepting connections,
sends `GOAWAY` and lets calls in flight finish for up to `timeout`
seconds before closing what is left. An open `Watch` never finishes on
its own, so a server with watchers takes the whole timeout to stop.

## Options

```lua
pb.server.new({
    listen      = 'host:port',   -- or host = ..., port = ...; port 0 = free port
    services    = {...},         -- generated server tables
    reflection  = true,          -- false: no reflection services
    health      = true,          -- false: none; a table: pb.health.new options
    transcoding = true,          -- false: no HTTP/JSON; a table: pb.transcode.new options
    connect     = true,          -- false: no Connect; a table: pb.connect.new options
    http        = fn(req),       -- fallback for HTTP requests nothing routed
    limits      = {...},         -- tarantool-http2 limits (message sizes, timeouts, ...)
})
```

The full reference is
[runtime-api.md → pb.server](../reference/runtime-api.md#grpc-and-httpjson-server--pbserver).

## What's next

- [Reference: runtime-api → pb.server](../reference/runtime-api.md#grpc-and-httpjson-server--pbserver).
- [How-to 15: HTTP/JSON transcoding](15-http-transcoding.md) — the
  routing and binding rules the server applies.
- [How-to 17: the Connect protocol](17-connect.md) — Connect calls, GET,
  streaming and what the buffered transport cannot do yet.
- [Specs: gRPC transports](../specs/grpc_transports.md) — the design,
  what is deferred (TLS, compression, gRPC-Web) and how it is verified.
