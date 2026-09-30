# Spec: gRPC and HTTP/JSON serving for Tarantool

Status: **in progress.** The in-process transport contract
([`runtime/pb/grpc.lua`](../../runtime/pb/grpc.lua): generated
`M.<Service>_client(transport)` / `M.<Service>_server(impl)`, the
four-method `transport:unary` / `:server_stream` / `:client_stream` /
`:bidi` interface, `loopback` and `multiplex`) is shipped and stays as
is. This spec covers the network side: **a Tarantool process serves
real gRPC over HTTP/2 and Google-style HTTP/JSON transcoding, out of
the box, from one listener.**

An earlier revision of this spec ruled HTTP/2 out ("put Envoy in
front") and recommended Connect-JSON over `tarantool/http` instead.
That premise no longer holds: the `tarantool-http2` rock provides an
HTTP/2 server with gRPC framing, trailers and all four call kinds, in
pure Lua over `libnghttp2` via FFI. Envoy stays a deployment option,
not a requirement.

## Goals

1. **gRPC over HTTP/2 (h2c)** that off-the-shelf clients (grpc-go,
   grpc-java, grpcurl, …) talk to without a proxy. All four call kinds,
   status codes, metadata, deadlines, cancellation.
2. **HTTP/JSON transcoding driven by `google.api.http` annotations**
   ([AIP-127](https://google.aip.dev/127),
   [`google/api/http.proto`](https://github.com/googleapis/googleapis/blob/master/google/api/http.proto)),
   the same scheme Google Cloud APIs, ESP and grpc-gateway use:
   `GET /v1/{name=shelves/*}/books` routes to a gRPC method, path
   variables and query parameters bind to request fields, the body is
   proto3 JSON.
3. **Server reflection and health** (`grpc.reflection.v1`,
   `grpc.reflection.v1alpha`, `grpc.health.v1`) enabled by default, so
   `grpcurl list` works against a fresh server with no `.proto` files.
4. **One port.** gRPC, HTTP/2 JSON and HTTP/1.1 JSON share a listener.
5. **Out of the box.** One call builds the server from generated
   modules:

   ```lua
   local server = require('pb.server').new({
       listen   = '0.0.0.0:8080',
       services = {greeter_pb.Greeter_server(impl)},
   })
   server:start()
   ```

## Non-goals (for now)

- **TLS.** Plaintext only (h2c with prior knowledge, HTTP/1.1). TLS is
  deferred, not rejected: the planned route is OpenSSL through FFI with
  memory BIOs between the socket and the (already memory-I/O) nghttp2
  session, with ALPN (`h2`, `http/1.1`) replacing preface sniffing.
  Tarantool 3.9 is expected to export the `SSL_*` symbols this needs.
  Until then, terminate TLS in a proxy. The server is built so the TLS
  layer slots in between socket and session without touching dispatch.
- **Message compression.** v1 accepts `identity` only; a request with
  another `grpc-encoding` gets `UNIMPLEMENTED` and the server advertises
  `grpc-accept-encoding: identity`. gzip is a follow-up.
- **h2c upgrade** (`Upgrade: h2c` from HTTP/1.1). No gRPC client uses
  it and browsers never do. Prior knowledge only.
- **gRPC-Web, Connect.** Not in v1; they would ride the same listener
  later.
- **An outbound gRPC client over the network.** Server first.

## Architecture

Two repositories, one boundary:

```
tarantool-http2 (rock `http2`)               tarantool-protobuf (rock `pb`)
────────────────────────────────             ──────────────────────────────
socket accept (one listener)                 pb.server      glue + options
  └─ sniff first 24 bytes                      ├─ gRPC registry  ← M.<Svc>_server(impl)
      ├─ HTTP/2 preface → nghttp2 session      ├─ pb.transcode   google.api.http router
      │    per stream, on end of headers:      ├─ reflection     embedded descriptors
      │    content-type application/grpc*      └─ health
      │      → gRPC dispatch (bytes)  ─────────►  status errors, ctx
      │    otherwise → HTTP handler  ─────────►  transcoding (JSON)
      └─ anything else → HTTP/1.1 parser
           → HTTP handler            ─────────►  transcoding (JSON)
```

`http2` knows nothing about protobuf: gRPC handlers take and return
message bytes; HTTP handlers take and return request/response tables.
`pb` knows nothing about sockets or frames. `pb.server` requires
`http2` lazily, so the codecs keep working on a machine without
`libnghttp2`; only starting a server needs it.

### The `http2` side

- **One server object, one listener.** The first bytes of a connection
  decide the protocol: the HTTP/2 client preface
  (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) selects HTTP/2, anything else
  HTTP/1.1. The peeked bytes are fed to the chosen parser, not dropped.
- **HTTP/2 streams are routed per stream** by `content-type`:
  `application/grpc` and `application/grpc+*` go to the gRPC registry,
  everything else to the HTTP handler with a buffered body.
- **HTTP/1.1** is a deliberately small subset: request line, headers,
  `Content-Length` and `chunked` bodies, keep-alive, no pipelining, no
  `Expect: 100-continue`, no upgrade. Header and body size limits are
  enforced. A gRPC request over HTTP/1.1 is answered with
  `415`/`505`-style errors, not dispatched.
- **gRPC semantics** the server owns: `grpc-timeout` becomes
  `ctx.deadline` and is enforced (`DEADLINE_EXCEEDED`, stream reset);
  client `RST_STREAM` marks the call cancelled; unsupported
  `grpc-encoding` is rejected; maximum message size (default 4 MiB
  receive, as in grpc-go) yields `RESOURCE_EXHAUSTED`; graceful stop
  sends `GOAWAY` and drains in-flight calls up to a timeout.

Contracts `http2` exposes to `pb`:

```lua
-- HTTP request (HTTP/1.1 and HTTP/2 alike)
req = {
    method  = 'GET',
    path    = '/v1/shelves/1?view=FULL', -- as received, query included
    headers = {['content-type'] = '...'},-- lowercased; repeats joined by ', '
    body    = '',                        -- fully buffered
    version = 'HTTP/1.1' | 'HTTP/2',
    peer    = '127.0.0.1:53210',
}
resp = {status = 200, headers = {...}, body = '...'}

-- gRPC call context
ctx = {
    method        = '/pkg.Service/Method',
    metadata      = {...},   -- request headers minus pseudo/reserved ones
    deadline      = <fiber.clock() value> | nil,
    peer          = 'ip:port',
    response_metadata = {},  -- handler may fill; sent with the headers
    trailing_metadata = {},  -- handler may fill; sent with the trailers
}
ctx:is_cancelled() -> boolean   -- deadline passed or client reset
```

A unary gRPC handler returns `response_bytes`, or
`nil, status, message[, details_bin]` (`details_bin` becomes
`grpc-status-details-bin`). A handler that raises produces `INTERNAL`
without leaking the error text. Streaming handlers get a stream with
`:recv(timeout)`, `:send(bytes)`, `:close(status, message)`.

### The `pb` side

**Status errors.** `pb.grpc.code` holds the 17 canonical codes.
`pb.grpc.error(code, message[, details])` raises a status object;
`pb.grpc.is_status(v)` recognises one. Generated server wrappers are
unchanged: a handler raises a status to fail the call, and the glue
maps it. The in-process `loopback` transport propagates the same
status objects, so a test written against the loopback sees the same
errors as a network client.

**`pb.server`.** Builds the `http2` server from generated
`M.<Service>_server(impl)` results:

```lua
pb.server.new({
    listen      = 'host:port',          -- or host = ..., port = ...
    services    = {...},                -- generated server tables
    reflection  = true,                 -- default true
    health      = true,                 -- default true
    transcoding = true,                 -- default true
    http        = fn(req) -> resp,      -- optional fallback for unrouted HTTP
    limits      = {max_recv_message = 4 * 1024 * 1024, ...},
})
server:start(); server:stop(timeout)
server:set_serving_status(service_name, 'SERVING' | 'NOT_SERVING')
```

**Transcoding.** The plugin reads `google.api.http` on each method and
emits the normalised rules into the service descriptor
(`additional_bindings` flattened):

```lua
methods = {
    GetBook = {
        ...,
        http = {
            {method = 'GET', pattern = '/v1/{name=shelves/*/books/*}'},
            {method = 'POST', pattern = '/v1/books:lookup', body = '*'},
        },
    },
}
```

`pb.from_pb` produces the same field from a `FileDescriptorSet`, so
dynamic schemas transcode too. `pb.parse` support for aggregate
`option (google.api.http) = {...}` follows later.

`pb.transcode` is a pure function over the request/response tables,
testable without sockets. It ships in `runtime/pb/transcode.lua`; the
exact rules it follows are in
[reference/runtime-api.md](../reference/runtime-api.md#httpjson-transcoding--pbtranscode).
In outline:

- path templates per `http.proto`: literals, `*`, `**`, `{field}`,
  `{field=segments}`, nested field paths (`{book.shelf}`), a trailing
  `:verb`;
- match priority: segment by segment from the left a literal beats `*`
  beats `**` (an ended template beats one continuing with `**`), then a
  verb beats no verb, ties resolved by declaration order;
- bindings: `body` (`*`, a field, or none) first, then path variables,
  which override a field the body also set (with `body: "*"` the body
  carries only the fields the path does not bind), then query
  parameters for every field bound by neither (repeated fields via
  repeated keys, nested fields via dotted keys; none when the body is
  `*`);
- `response_body` selects a sub-field of the response;
- responses and errors are proto3 JSON via `pb.json`; errors use the
  `google.rpc.Status` JSON shape (`{"code", "message", "details"}`)
  with the HTTP status from the canonical mapping below;
- **unbound methods** (no annotation) are optionally exposed as
  `POST /{package.Service}/{Method}` with a JSON body, off by default.

**Reflection** needs every file's `FileDescriptorProto`. The plugin
embeds the serialized descriptor of each generated file
(`M._file_descriptor`) plus the names of the files it imports; the
runtime ships the descriptors of the well-known types and of
`google/api/{annotations,http}.proto`. The reflection and health
services are themselves generated by this plugin from their upstream
`.proto` files and shipped in `runtime/pb/`.

## Status code mapping

gRPC canonical codes, and the HTTP status transcoding answers with
(the mapping Google APIs and grpc-gateway use):

| Code | Name                  | HTTP |
| ---: | --------------------- | ---: |
|    0 | `OK`                  |  200 |
|    1 | `CANCELLED`           |  499 |
|    2 | `UNKNOWN`             |  500 |
|    3 | `INVALID_ARGUMENT`    |  400 |
|    4 | `DEADLINE_EXCEEDED`   |  504 |
|    5 | `NOT_FOUND`           |  404 |
|    6 | `ALREADY_EXISTS`      |  409 |
|    7 | `PERMISSION_DENIED`   |  403 |
|    8 | `RESOURCE_EXHAUSTED`  |  429 |
|    9 | `FAILED_PRECONDITION` |  400 |
|   10 | `ABORTED`             |  409 |
|   11 | `OUT_OF_RANGE`        |  400 |
|   12 | `UNIMPLEMENTED`       |  501 |
|   13 | `INTERNAL`            |  500 |
|   14 | `UNAVAILABLE`         |  503 |
|   15 | `DATA_LOSS`           |  500 |
|   16 | `UNAUTHENTICATED`     |  401 |

The table lives in `runtime/pb/grpc.lua` (`pb.grpc.code`,
`pb.grpc.http_status`).

## Verification

Tests that only talk to our own client prove only that our client and
server agree. Every layer is checked against an independent peer:

- **`http2`:** a Go harness with grpc-go as the client (raw-bytes
  codec, no generated code) covering all four call kinds, metadata in
  both directions, deadlines, cancellation, oversize messages and
  unknown methods; `curl --http2-prior-knowledge` and plain `curl` for
  the HTTP paths on the same port.
- **`pb.server`:** grpc-go with `dynamicpb` against a server built from
  the example protos; `grpcurl` driven only by reflection (`list`,
  `describe`, a call); `grpc_health_probe`-style health checks.
- **Transcoding:** table-driven tests of the path-template matcher and
  binder taken from the examples in `http.proto`, then end-to-end
  requests over HTTP/1.1 and HTTP/2.
- The [gRPC interop test cases](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md)
  (`empty_unary`, `large_unary`, `ping_pong`, `timeout_on_sleeping_server`, …)
  are the reference list for the Go harness.

## Open questions

1. **Handler fiber on deadline or cancel.** The server answers
   `DEADLINE_EXCEEDED` and drops the late result, but does not
   `fiber:cancel()` the handler, which may be inside a transaction.
   Handlers check `ctx:is_cancelled()`. Revisit if long handlers pile up.
2. **Streaming transcoding.** Server-streaming methods over HTTP/JSON
   (grpc-gateway emits newline-delimited JSON). Not in v1: such methods
   are not routed.
3. **In-cluster transport** (net.box / IProto tunnel) from the previous
   revision is still a valid idea for Tarantool-to-Tarantool calls and
   stays out of this spec.
