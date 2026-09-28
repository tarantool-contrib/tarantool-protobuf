# Spec: gRPC transports for Tarantool

Status: **shipped contract + loopback/multiplex; external transports
deferred**. The transport *contract* is locked in
[`runtime/pb/grpc.lua`](../../runtime/pb/grpc.lua) — generated
`M.<Service>_client(transport)` / `M.<Service>_server(impl)` and the
four-method `transport:unary` / `:server_stream` / `:client_stream` /
`:bidi` interface are stable, with `loopback` and `multiplex`
reference transports in the runtime. What this spec covers is the
forward-looking work: **which concrete external transports we'd build
or recommend, and how a user picks between them**.

This spec maps the protocol landscape, says where Tarantool fits, and
flags what we'd build vs. recommend an external library for.

## What's already shipped (and won't change)

Generated `M.<Service>_client(transport)` and `M.<Service>_server(impl)`
talk to the transport in a single contract, regardless of wire protocol:

```
transport:unary(path, req_bytes, ctx)         -> resp_bytes
transport:server_stream(path, req_bytes, ctx) -> stream
transport:client_stream(path, ctx)            -> stream
transport:bidi(path, ctx)                     -> stream
```

`path` is `/pkg.Service/Method`. `ctx` is an opaque Lua table (headers,
deadline, metadata, …). Generated code encodes the request, hands raw
bytes to the transport, and decodes the response.

This is deliberately HTTP/2-shaped — `path`, byte-oriented messages,
streams — but **the contract makes no commitment to a wire protocol**.
Every transport in this spec is a different plug-in behind the same
four methods.

Reference transports already in `runtime/pb/grpc.lua`:

- `pb.grpc.loopback(server)` — in-process; uses `fiber.channel`. Bridges
  client → server fiber for tests and same-process apps.
- `pb.grpc.multiplex({srv1, srv2})` — fans several servers onto one
  transport. Errors on duplicate paths.

## The protocol matrix

For a request that crosses a process boundary, you pick a pair: a
**wire protocol** (how bytes flow between processes) and a **codec**
(how a message turns into bytes). The Lua-side transport bridges between
the generated code and that wire/codec combo.

| Wire protocol             | Body codec   | Streaming           | Status signaling          | Browser-friendly | Off-the-shelf clients/servers | Tarantool fit                  |
| ------------------------- | ------------ | ------------------- | ------------------------- | :--------------: | ----------------------------- | ------------------------------ |
| **gRPC over HTTP/2**      | proto wire   | unary + all 3       | HTTP/2 trailers           | no               | every gRPC lib                 | needs an external HTTP/2 lib   |
| **gRPC-Web over HTTP/2**  | proto wire   | unary + server      | trailers in body          | yes (with proxy) | grpc-web JS, Envoy             | same problem as gRPC + framing |
| **gRPC-Web over HTTP/1.1**| proto wire   | unary + server      | trailers in body          | yes              | grpc-web JS                    | works with `tarantool/http`    |
| **Connect over HTTP/1.1** | proto wire   | unary only          | HTTP status + body        | yes              | connectrpc clients             | works with `tarantool/http`    |
| **Connect over HTTP/2**   | proto wire   | unary + all 3       | HTTP status / trailers    | yes              | connectrpc clients             | same HTTP/2 problem            |
| **Connect-JSON**          | proto3 JSON  | unary only          | HTTP status + body        | yes              | curl + connectrpc clients      | drop-in for `tarantool/http`   |
| **gRPC-Gateway / transcoded REST + JSON** | proto3 JSON | unary | HTTP status + body | yes | any HTTP client              | drop-in for `tarantool/http`   |
| **gRPC over IProto tunnel** (Tarantool-native) | proto wire | unary + all 3 | IProto error code     | n/a              | this project, custom clients   | first-class                    |
| **gRPC over net.box tunnel**                   | proto wire | unary + all 3 | net.box error           | n/a              | this project, custom clients   | first-class                    |

What's **not** in the matrix and why:

- **gRPC over HTTP/3 / QUIC** — too early; the Go and C++ gRPC stacks
  themselves treat it as experimental. Not worth specifying yet.
- **JSON-RPC, Thrift, etc.** — different IDL; off-topic.

## What "Tarantool fit" actually means

Tarantool gives us:

- **`tarantool/http` server (HTTP/1.1)** — solid, idiomatic, lives in a
  Lua rock. No HTTP/2, no server-pushed trailers. Good substrate for
  Connect-JSON and gRPC-Gateway-style REST.
- **`http_client` (libcurl-based)** — HTTP/1.1 and HTTP/2 client. Has
  streaming via callbacks, but trailers and gRPC framing are not
  first-class. Usable for HTTP/2 unary; awkward for streaming.
- **`net.box`** — Tarantool's binary RPC protocol. Already gives us
  request/response, streaming via long-poll, error propagation. Sane
  default for in-cluster Tarantool→Tarantool calls.
- **IProto** — the wire protocol under net.box. Lower level; lets us
  define our own request type that carries gRPC framing if we want
  zero overhead.
- **No HTTP/2 server.** Real HTTP/2 termination needs a sidecar (Envoy,
  nginx) or a new Lua library. Neither is something we'd ship.

So the practical bands are:

1. **In-cluster Tarantool↔Tarantool** → IProto or net.box tunnel.
2. **External clients calling Tarantool over HTTP** → Connect-JSON or
   gRPC-Gateway-style REST behind `tarantool/http`. Both are HTTP/1.1
   only, both speak JSON, both work with `curl`/browsers without a
   proxy.
3. **External clients that insist on real gRPC** → put Envoy or
   grpcurl in front, terminate HTTP/2 there, and send unary calls into
   Tarantool over HTTP/1.1 or IProto. We don't terminate HTTP/2
   ourselves.
4. **Outbound calls from Tarantool to external gRPC services** →
   `http_client` for HTTP/2 unary. For streaming, accept "we don't
   support that yet" rather than shipping a half-baked HTTP/2 client.

## Recommended transports to build

Names below refer to packages we'd publish; nothing here lives in this
repo yet beyond the contract.

### `pb.grpc.transport.http_server` (HTTP/1.1 server-side)

Adapts an `M.<Service>_server(impl)` result into a `tarantool/http`
route handler. Wire protocol: **Connect-JSON over HTTP/1.1** by default,
with content-negotiation for Connect-protobuf.

- POST `/{package.Service}/{Method}` with `Content-Type: application/json`
  → decode body via `pb.json.decode(input_desc, body)`, call the
  generated handler, encode reply via `pb.json.encode`.
- `application/proto` content type → use `pb.encode/pb.decode` instead.
- Streaming methods: respond 501 for now. Connect's `application/connect+json`
  framed streaming over HTTP/1.1 chunked transfer is feasible later;
  out of scope for v1.
- Errors: surface as Connect's JSON error envelope. Map common
  gRPC status codes to HTTP status per the Connect spec.

Why this first: it's the lowest-effort transport that gives us a real
external interface, and it works with browsers and `curl`. It also
covers the gRPC-Gateway use case without needing the gateway:
`POST /myapp.v1.Greeter/SayHello` with a JSON body is a fine REST
shape on its own.

### `pb.grpc.transport.netbox` (in-cluster)

`net.box` connection → speaks `pb.grpc` over a single user-defined
function (e.g. `box.schema.func.create('grpc_dispatch')`). Body is
a 2-tuple `{path, req_bytes}`; reply is `{ok, resp_bytes}` or
`{err, status_code, message}`.

Streaming: lean on net.box's stream/iterator support. Server runs the
handler on a fiber; messages flow through `box.iproto.override` /
`box.session.push`. Concretely tractable; out of scope for v1 but
straightforward to add.

Why second: in-cluster Tarantool clusters are a real and ready use
case. The transport is small and self-contained.

### `pb.grpc.transport.http_client_unary` (outbound, optional)

Adapts `http_client` to speak Connect-JSON or Connect-protobuf to
external services. Unary only. Easy. Useful for calling out from
Tarantool app code to a Connect or HTTP/1.1 gRPC-Web server.

## Not recommended (don't build)

- **Tarantool-side HTTP/2 server.** Would require a new HTTP/2 library
  in Lua or a C module. Effort vastly exceeds payoff — anyone needing
  HTTP/2 termination should run Envoy in front. Document the Envoy
  setup instead.
- **Tarantool-side HTTP/2 streaming client.** `http_client`'s streaming
  API isn't a clean fit for gRPC trailers and per-message framing.
  Anyone needing this should bind to a real gRPC client (C, Go), not
  reimplement in Lua. Document this limitation.
- **gRPC-Web framing.** It's a small spec, but every modern stack
  (browser SDK, mobile SDK) prefers Connect now. Don't fragment effort
  unless a user demands it.

## How a user picks

Decision tree, top-down:

1. Both endpoints in a Tarantool cluster?
   → `pb.grpc.transport.netbox`.
2. External clients only (browsers, curl, mobile)?
   → `pb.grpc.transport.http_server` (Connect-JSON).
3. Need to call an external gRPC service from Tarantool?
   → Unary: `pb.grpc.transport.http_client_unary` (Connect or HTTP/1.1
     gateway). Streaming: not supported; document the Envoy/sidecar
     alternative.
4. External clients insist on real HTTP/2 gRPC?
   → Envoy in front. Envoy terminates HTTP/2, talks Connect to
     Tarantool. Document the Envoy config; we don't ship it.

## Conformance

Validate against [`connectrpc/conformance`](https://github.com/connectrpc/conformance).
Operationally identical to the protobuf conformance suite already
running here (`docker/conformance.Dockerfile`, `cmd/conformance-runner.lua`):

- Our impl runs as a subprocess that reads framed `ClientCompatRequest`
  / writes `ClientCompatResponse` on stdin/stdout.
- Two modes: `--mode server` (our impl is the server; Connect's
  reference client drives it — fits `pb.grpc.transport.http_server`
  validation) and `--mode client` (our impl is the client — fits
  `pb.grpc.transport.http_client_unary` validation).
- One harness covers all three protocols in scope: **gRPC over HTTP/2**,
  **gRPC-Web**, and **Connect**. So if HTTP/2 termination ever ships
  via Envoy or otherwise, the same runner re-validates it without a
  second suite.
- Coverage: unary, server-stream, client-stream, bidi, errors with
  details, cancellation, deadlines, trailers, gzip/deflate compression,
  TLS, HTTP/1.1 vs HTTP/2 negotiation.
- Watchlist discipline: maintain `test/grpc_conformance/known_failures.txt`
  (server mode) and `..._client.txt` (client mode) mirroring the
  proto suite's pattern at `test/conformance/known_failures.txt`.

Canonical [gRPC interop tests](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md)
(`empty_unary`, `large_unary`, `ping_pong`, …) are pre-Connect,
HTTP/2-only, and use a client-and-server-binary model rather than a
framed pipe. Skip them: less useful while we don't terminate HTTP/2,
and operationally distant from what we already run.

## Status code mapping

We adopt gRPC's canonical status codes (12 of them) as the cross-wire
status type. Every transport translates to and from its native error
representation:

| gRPC status        | HTTP (Connect)  | net.box / IProto error      |
| ------------------ | --------------- | --------------------------- |
| `OK`               | 200             | success                     |
| `CANCELLED`        | 499             | `ER_CANCELLED`              |
| `INVALID_ARGUMENT` | 400             | `ER_PROC_LUA` (categorized) |
| `DEADLINE_EXCEEDED`| 504             | `ER_TIMEOUT`                |
| `NOT_FOUND`        | 404             | `ER_NO_SUCH_PROC`           |
| `ALREADY_EXISTS`   | 409             | `ER_TUPLE_FOUND`            |
| `PERMISSION_DENIED`| 403             | `ER_ACCESS_DENIED`          |
| `RESOURCE_EXHAUSTED`| 429            | `ER_MEMORY_ISSUE` (etc.)    |
| `FAILED_PRECONDITION`| 400           | `ER_*`                      |
| `INTERNAL`         | 500             | `ER_PROC_LUA`               |
| `UNAVAILABLE`      | 503             | `ER_NO_CONNECTION`          |
| `UNAUTHENTICATED`  | 401             | `ER_LOGIN_REQUIRED`         |

The mapping table belongs in `runtime/pb/grpc.lua`. Each transport
references it.

## Context propagation

The `ctx` argument in the transport contract carries metadata between
caller and transport. We standardize three keys:

- `ctx.deadline` — fiber-clock timestamp (seconds, double). Transport
  enforces by cancelling on overrun.
- `ctx.headers` — flat `{string -> string}` map. Wire-side translation
  is transport-specific (HTTP headers, IProto headers, …).
- `ctx.trace_id`, `ctx.span_id` — optional tracing hooks. Transports
  inject/extract per W3C `traceparent` for HTTP, custom IProto field
  for net.box.

Per-call overrides go in `ctx.options` (e.g. retry policy). User code
shouldn't put anything else in `ctx`; we may add more standard keys.

## File / module layout

```
runtime/pb/grpc.lua                already exists; gains status-code
                                    + ctx-key constants
runtime/pb/grpc/http_server.lua    new — Connect-style HTTP/1.1 server
runtime/pb/grpc/netbox.lua         new — net.box tunnel (in-cluster)
runtime/pb/grpc/http_client.lua    new — outbound, unary only
docs/grpc-howto.md                 new — user-facing recipes
```

Tests follow the existing pattern: each transport plugs into the
loopback's test harness by replacing the in-process transport with the
networked one, asserting end-to-end round-trip equality.

## Open questions (defer)

1. **Connect protocol version.** Connect v1 is stable; do we target the
   spec verbatim, or shave it down to "POST + JSON body + JSON error"
   without the framing layer? Probably full spec — clients depend on it.
2. **Streaming over HTTP/1.1.** Connect frames bidi over HTTP/1.1
   chunked transfer. Doable but adds parser surface. v1 ships unary
   only and 501s on streaming; revisit when a user asks.
3. **Tarantool admin protocol surface.** Should `box.iproto.override`
   carry a dedicated `IPROTO_GRPC` request type so net.box transport
   doesn't sit on top of `func_call`? Probably eventually; not now.
4. **Auth.** Out of this spec. Each transport delegates to its host:
   HTTP transports honor `Authorization` headers, net.box uses
   Tarantool users.
5. **Metadata semantics for in-cluster.** Net.box has no concept of
   metadata; we'd thread it as an extra map argument. Cleanly resolved
   once `IPROTO_GRPC` is its own request type.

## What "later" decisions look like

When this spec gets picked back up, the load-bearing calls are:

1. **Connect-JSON as the default external transport.** Picking it
   because it works with `tarantool/http` as-is, browsers can call it
   without a proxy, and gRPC-Gateway folks have a clean migration.
   Revisit if a user has a hard dependency on grpc-web or REST shapes
   that don't match Connect's URL convention.
2. **Don't ship HTTP/2 termination.** Push the HTTP/2 frontier to
   Envoy. Revisit only if a Lua HTTP/2 library appears that's not a
   sandcastle.
3. **net.box tunnel before IProto type.** Cheaper to start, retains
   the door for an `IPROTO_GRPC` type later. Once net.box is in real
   use, we'll know what's missing.
