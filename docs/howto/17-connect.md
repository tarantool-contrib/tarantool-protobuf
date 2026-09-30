# How-to: the Connect protocol

[Connect](https://connectrpc.com/docs/protocol/) is an RPC protocol over
plain HTTP from the authors of `buf`: a unary call is a POST of the bare
message (`application/proto` or `application/json`) to
`/<package.Service>/<Method>`, answered with the bare response or a JSON
error and a meaningful HTTP status; side-effect-free calls can be GETs;
streams wrap messages in the same 5-byte envelopes as gRPC but need no
HTTP trailers. It works over HTTP/1.1 and HTTP/2, from `curl`, browsers
(connect-es), `buf curl` (its default protocol), connect-go and the
other Connect clients.

`pb.server` ([how-to 16](16-network-server.md)) speaks it on the same
port as gRPC and HTTP/JSON, for every service it serves, with the same
handlers: a handler cannot tell a Connect call from a gRPC one (unless
it asks `ctx.protocol`). It is on by default:

```lua
local server = pb.server.new({
    listen   = '0.0.0.0:8080',
    services = {greeter_pb.Greeter_server(impl)},
    -- connect = false turns it off; a table is pb.connect.new's options.
}):start()
```

The runnable version is the self-check of
[`examples/grpc/network_server.lua`](../../examples/grpc/network_server.lua)
(`just examples network-server`, see how-to 16 for the http2 rock it
needs).

## Unary calls

```bash
curl -H 'content-type: application/json' -H 'connect-protocol-version: 1' \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/SayHello
# {"greeting":"Hello, Ann"}                                     (HTTP 200)

curl -H 'content-type: application/json' -d '{}' \
    http://localhost:8080/hello.Greeter/SayHello
# {"code":"invalid_argument","message":"name is required"}      (HTTP 400)

buf curl --schema examples/proto/hello.proto \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/SayHello
# { "greeting": "Hello, Ann" }
```

- **Codecs.** `application/json` is proto3 JSON through `pb.json`
  (unknown fields are ignored, as connect-go does; the response omits
  default values), `application/proto` the binary format. The response
  has the request's content-type. `application/json; charset=utf-8` is
  the same codec. Any other codec is `415 Unsupported Media Type`.
- **Errors** are `{"code", "message", "details"}` with the HTTP status
  of the protocol's table: `canceled` 499, `unknown` 500,
  `invalid_argument` 400, `deadline_exceeded` 504, `not_found` 404,
  `already_exists` 409, `permission_denied` 403, `resource_exhausted`
  429, `failed_precondition` 400, `aborted` 409, `out_of_range` 400,
  `unimplemented` 501, `internal` 500, `unavailable` 503, `data_loss`
  500, `unauthenticated` 401. A `pb.grpc` status object raised by the
  handler becomes one: `details` (the `google.protobuf.Any` tables of
  `pb.grpc.error`) go out as `{"type": "<message name>", "value":
  "<unpadded base64>"}`. A plain Lua error is `internal` with the
  message `internal error`, the real one going to the log, as over
  gRPC.
- **Metadata.** Request headers become `ctx.metadata` (lowercase; the
  protocol's own `connect-*`, `content-*` and hop-by-hop headers left
  out; `-bin` values decoded from base64, padded or not).
  `ctx.response_metadata` goes out as response headers,
  `ctx.trailing_metadata` as `trailer-<key>` headers; `-bin` values are
  sent as unpadded base64, others must be printable ASCII.
- **Timeouts.** `Connect-Timeout-Ms` becomes `ctx.deadline`. When it
  passes, the call answers `deadline_exceeded` at once and
  `ctx:is_cancelled()` turns true; the handler fiber runs on (it may be
  inside a transaction) and its result is dropped. The deadline is read
  from a fresh monotonic clock (`clock.monotonic()`, the origin
  `fiber.clock()` also counts from, without its per-iteration caching),
  so CPU-bound work does not hide it: a result finished after the
  deadline, or whose encoding took the call past it, is dropped too.
- **Compression.** Only `identity`: a request with another
  `Content-Encoding` is `unimplemented` naming the supported encoding.
- **Size.** A message over `limits.max_recv_message_size` (4 MiB by
  default, the same limit as gRPC's) is `resource_exhausted`.

### GET

A method whose `idempotency_level` is `NO_SIDE_EFFECTS` can also be
called with GET, the message in the query:

```proto
rpc GetBook(GetBookRequest) returns (Book) {
  option (google.api.http) = { get: "/v1/{name=shelves/*/books/*}" };
  option idempotency_level = NO_SIDE_EFFECTS;
}
```

```bash
curl 'http://localhost:8080/library.Library/GetBook?connect=v1&encoding=json&message=%7B%22name%22%3A%22shelves%2F1%2Fbooks%2F1%22%7D'
# {"title":"Dune","name":"shelves/1/books/1","isbn":"42"}
```

`encoding` (`json` or `proto`) is required; `message` is the
percent-encoded message, or URL-safe base64 of it with `base64=1` (the
way to send `proto`); `compression` may only be `identity`; `connect`
may be `v1`; the order is free and other parameters are ignored (a
handler sees them all in `ctx.connect.query`). GET on any other method
is `405 Method Not Allowed`. The service descriptor carries the level
as `methods.<M>.idempotency_level` ([codegen.md](../codegen.md#service-descriptors)).

## Streaming calls

Content-types `application/connect+proto` and
`application/connect+json`; the body is a sequence of envelopes
(a flags byte, a 4-byte big-endian length, the message). The response
is always HTTP 200: its messages, then an envelope with flag `0x02`
holding the EndStreamResponse, `{}` on success or
`{"error": {...}, "metadata": {"key": ["value"]}}`, where `metadata` is
`ctx.trailing_metadata`.

```bash
buf curl --schema examples/proto/hello.proto \
    -d '{"name": "Ann"}' http://localhost:8080/hello.Greeter/StreamHellos
# { "greeting": "Hello #1, Ann" }
# { "greeting": "Hello #2, Ann" }
# { "greeting": "Hello #3, Ann" }
buf curl --schema examples/proto/hello.proto \
    -d '{"name": "a"} {"name": "b"}' http://localhost:8080/hello.Greeter/CollectHellos
# { "greeting": "Hello, a, b" }
```

The generated streaming handlers run unchanged: `stream:recv()` walks
the request envelopes (`nil, nil` at the end), `stream:send()` adds a
response envelope. A server stream with zero or several request
messages is `unimplemented`; an envelope with the compressed flag is
`internal`; a torn envelope or an end-stream flag in a request is
`invalid_argument`.

## What works and what does not

The HTTP handler of tarantool-http2 is called once a request's body has
fully arrived, and returns one whole response. That shapes what the
streaming kinds can do:

| Call | HTTP/1.1 | HTTP/2 |
|---|---|---|
| unary (POST, GET) | yes | yes |
| client streaming | yes | yes |
| server streaming | yes, delivered at once when the handler returns | same |
| bidi, half-duplex (the client sends everything, then reads) | yes | yes |
| bidi, full-duplex (the client waits for a reply before it goes on) | no | no: the request never ends, so the handler never runs, and the client times out |

So a server stream is wire-correct but not incremental: the client gets
every message together with the end of the stream, which suits
bounded result sets and not long-lived subscriptions (use gRPC for
those). Server reflection over Connect is a full-duplex stream too:
`buf curl` finds services through reflection only with `--protocol grpc
--http2-prior-knowledge` (how-to 16). Serving these needs a streaming
HTTP handler API in tarantool-http2, planned as the next step; the
protocol code already keeps its envelope I/O behind one small object
for that.

Not supported: compression other than `identity`, and CORS (a browser
client on another origin needs a proxy or an `http` fallback that
answers the preflight).

## Routing

A Connect call and an HTTP/JSON rule can claim the same URL (the
transcoder's `unbound` option routes `POST /<package.Service>/<Method>`
with a JSON body, and a `google.api.http` rule may use such a path).
`pb.server` decides in this order:

1. a request that can only be Connect: a Connect-Protocol-Version
   header, a protobuf or enveloped content-type, or a GET with
   `connect=v1` or `encoding=proto` — to Connect;
2. the transcoding router;
3. a plain JSON POST or JSON GET to a procedure path that no rule took
   — to Connect;
4. the `http` fallback;
5. a procedure path with the wrong method or content-type — `405` or
   `415`, as the protocol asks;
6. `404`: in the Connect error shape (`unimplemented`) for a plainly
   Connect request, in the `google.rpc.Status` shape otherwise.

Connect clients send `Connect-Protocol-Version: 1`, so they always
reach Connect.

## The handler's view

The `ctx` is the one gRPC handlers get, plus two fields:

```lua
ctx = {
    method = '/hello.Greeter/SayHello',
    metadata = {...}, deadline = <clock.monotonic() value> | nil, peer = 'ip:port',
    response_metadata = {}, trailing_metadata = {},
    protocol = 'connect',         -- 'grpc' over gRPC, 'http' when transcoded
    connect = {
        get = false,              -- true for a GET
        codec = 'json',           -- or 'proto'
        query = {name = {value, ...}},  -- the GET query, nil for POST
    },
}
ctx:is_cancelled()
```

## Verification

`just connect-conformance` runs the official
[Connect conformance suite](https://github.com/connectrpc/conformance)
(v1.0.5) in server mode: its connect-go and grpc-go clients drive
`test/connect-conformance/server.lua` over HTTP/1.1 and h2c, Connect
and gRPC, proto and JSON, every stream kind, Connect GET and the
message size limit. The cases expected to fail, with the reason for
each, are listed in `test/connect-conformance/known-failing.txt`: the
Connect full-duplex calls above, and a few gRPC cases that trace to
tarantool-http2. `test/server-go` checks `buf curl` and `net/http`
against the example services.

## What's next

- [Reference: runtime-api → pb.connect](../reference/runtime-api.md#the-connect-protocol--pbconnect).
- [How-to 16: the network server](16-network-server.md).
- [Specs: gRPC transports](../specs/grpc_transports.md).
