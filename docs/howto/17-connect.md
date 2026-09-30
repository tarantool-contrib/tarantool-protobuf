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
  sent as unpadded base64, others must be printable ASCII. Keys starting
  with `connect-` are the protocol's and dropped; so are, in response
  metadata only, `trailer-*` keys and the headers the transport owns. A
  trailing key may itself start with `trailer-` (it goes out as
  `trailer-trailer-...`).
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

The generated streaming handlers run unchanged: `stream:recv()` returns
the next request message as it arrives (`nil, nil` once the client
ended its request), `stream:send()` puts a response message on the wire
at once and returns `false` once the client is gone. A server stream
with zero or several request messages is `unimplemented`; an envelope
with the compressed flag is `internal`; a torn envelope or an
end-stream flag in a request is `invalid_argument`; a message over the
size limit is `resource_exhausted`, refused from its length prefix
before its bytes are read.

## How streams are carried

Streaming calls run on tarantool-http2's streaming handlers
(`http_stream`): the request body is read as it arrives and the
response is written as the handler produces it.

**Minimum transport:** tarantool-http2 master e656208 or later, whose
streaming exchange has `write(data, timeout)` and `abort()` — what
bounds a stream by its deadline. On an older exchange (no `abort()`)
every Connect stream is refused with HTTP 500 and no body, and the
first refusal logs an error naming this requirement; unary calls and
gRPC are not affected.

| Call | HTTP/1.1 | HTTP/2 |
|---|---|---|
| unary (POST, GET) | yes | yes |
| client streaming | yes, messages read as they arrive | same |
| server streaming | yes, each message sent as the handler sends it | same |
| bidi, half-duplex (the client sends everything, then reads) | yes | yes |
| bidi, full-duplex (the client waits for a reply before it goes on) | no: HTTP/1.1 clients send the whole request first | yes |

- **Cancellation.** When the client goes away (an HTTP/2 reset, a
  closed connection), `ctx:is_cancelled()` turns true, `stream:send()`
  returns `false` and `stream:recv()` returns `nil, 'canceled'`. On
  HTTP/1.1 the server notices at the next read or write.
- **Deadlines.** `Connect-Timeout-Ms` bounds the whole call, writes
  included: a handler waiting in `recv()` wakes up at the deadline, a
  `send()` waits for a slow client at most until the deadline, and when
  the deadline passes while the handler still runs, the stream ends with
  `deadline_exceeded` and later sends return `false`. That
  EndStreamResponse gets `pb.connect.DEADLINE_GRACE` (0.1 s) to go out;
  a client that is not taking the response (an HTTP/2 window held at 0,
  an HTTP/1.1 client that does not read) gets the exchange aborted
  instead — a reset stream on HTTP/2, a closed connection on HTTP/1.1 —
  and no fiber of the call is left waiting on it.
- **HTTP/1.1.** A stream that ends before reading the whole request (a
  message over the limit, a handler that stopped reading) answers at
  once; tarantool-http2 discards a bounded rest of the body or closes
  with a lingering close (and announces `connection: close` when it
  will), so a client still sending gets the whole response.

Unary calls, GETs and the protocol's rejections stay on the buffered
HTTP handler: a unary message is needed whole before the handler runs
anyway, and the transcoding router, which takes some of those requests
first, needs the body. A consequence: a client that goes away during a
unary call is not noticed (`ctx:is_cancelled()` stays false unless the
deadline passes).

Server reflection is a full-duplex stream, so `buf curl` finds
services through reflection over Connect too, given
`--http2-prior-knowledge` for a plain `http://` URL (how-to 16).

Not supported: compression other than `identity`, and CORS (a browser
client on another origin needs a proxy or an `http` fallback that
answers the preflight).

## Routing

A Connect call and an HTTP/JSON rule can claim the same URL (the
transcoder's `unbound` option routes `POST /<package.Service>/<Method>`
with a JSON body, and a `google.api.http` rule may use such a path).
`pb.server` decides in this order:

1. a request to a procedure path that can only be Connect: a
   Connect-Protocol-Version header (any value), a protobuf or enveloped
   content-type, or a GET with a `connect` parameter or
   `encoding=proto` — to Connect, which serves it or rejects it
   (`415` for a codec or cardinality it does not serve, `405` for a
   wrong method, `invalid_argument` for a protocol version other than
   `1`); it never reaches transcoding or the fallback;
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
and gRPC, proto and JSON, every stream kind (full-duplex bidi on
HTTP/2, half-duplex bidi on HTTP/1.1 as well), Connect GET and the
message size limit. All 612 cases pass; there is no list of expected
failures. `test/server-go` checks `buf curl` (with a local schema and
through reflection) and `net/http` against the example services,
including incremental delivery, full duplex, cancellation and
deadlines of streams.

## What's next

- [Reference: runtime-api → pb.connect](../reference/runtime-api.md#the-connect-protocol--pbconnect).
- [How-to 16: the network server](16-network-server.md).
- [Specs: gRPC transports](../specs/grpc_transports.md).
