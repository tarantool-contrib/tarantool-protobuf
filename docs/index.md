# Documentation

The user-facing docs for `tarantool-protobuf`, grouped by what you're
trying to do. The [README](../README.md) has the feature matrix, quick
start, and status numbers; this page is the map for everything else.

## Getting started

If you're new to the project, work through the how-tos in order; each
links to the next.

1. **[Your first message, end-to-end](howto/01-first-message.md)** —
   write a proto, run the plugin, encode/decode in Tarantool.
2. **[Module layout](howto/02-module-layout.md)** — `prefix`,
   `lua_package`, `LUA_PATH`, three side-by-side `protoc` invocations.
3. **[gRPC with the loopback transport](howto/03-grpc-loopback.md)** —
   Greeter end-to-end with all four streaming flavors.
4. **[WKT: Struct / Value / ListValue](howto/04-wkt-struct-value.md)** —
   round-tripping JSON-shaped data through proto.
5. **[Packing and unpacking `Any`](howto/05-wkt-any.md)** — typed
   message payloads, registry, opaque fallback.
6. **[JSON over `tarantool/http`](howto/06-json-http.md)** — exposing
   a proto-defined API as JSON HTTP.
7. **[Text format for debugging](howto/07-text-format.md)** —
   mainline-protoc-compatible printer and parser.
8. **[Dynamic schemas from a Tarantool space](howto/08-dynamic-schemas.md)** —
   `pb.parse` and `pb.from_pb` for runtime descriptors.
9. **[When to use `decode_lazy`](howto/09-lazy-when.md)** —
   picking eager vs lazy by workload shape.
10. **[Migrating from the built-in `protobuf`](howto/11-migrate-from-builtin.md)** —
    side-by-side schema and call-site diffs.
11. **[Build integration](howto/12-build-integration.md)** — `protoc`,
    Makefile, Justfile, `buf`, CMake.
12. **[Writing a custom transport](howto/13-custom-transport.md)** —
    implementing the four-method contract.
13. **[Tuples to protobuf and back](howto/14-tuples.md)** —
    `pb.tuple`: bind a message to a space format, convert rows in one
    call each (without a Lua table per row on the C runtime).
14. **[HTTP/JSON transcoding](howto/15-http-transcoding.md)** —
    `pb.transcode`: route HTTP requests to gRPC handlers by their
    `google.api.http` rules.
15. **[A gRPC and HTTP/JSON server on one port](howto/16-network-server.md)** —
    `pb.server`: real gRPC, reflection, health and transcoding over
    the network (needs the tarantool-http2 rock).

When something doesn't work, **[troubleshooting](troubleshooting.md)**
collects the common errors and their fixes.

## Reference

- **[reference/runtime-api.md](reference/runtime-api.md)** — every
  export of `require('pb')`: codec, lazy view, dynamic descriptors,
  JSON/text/WKT/gRPC, server reflection and health, the network
  server (`pb.server`), the tuple bridge,
  sentinels, codegen helpers.
- **[reference/generated-api.md](reference/generated-api.md)** —
  what each `_pb.lua` exposes per message, enum, and service.
- **[reference/cli.md](reference/cli.md)** — driving
  `protoc-gen-tarantool` and `protoc-gen-tarantool-doc` from
  `protoc`. Flags, file options, path-resolution rules.
- **[reference/grpc-contract.md](reference/grpc-contract.md)** —
  the four-method transport interface, stream-object shapes, and
  the shipped `loopback` / `multiplex` transports.
- **[api-modes.md](api-modes.md)** — full / runtime / lazy. Same
  descriptor, three call shapes. When to pick which, with measured
  trade-offs and the field-name-constants contract for lazy views.
- **[codegen.md](codegen.md)** — how `protoc-gen-tarantool` works:
  the pipeline, the descriptor-table contract (canonical shape),
  inline-mode vs runtime-mode emission, the LuaJIT hot-path rules
  generated code observes, and how to add a new scalar type.
- **Auto-generated proto reference** — `examples/docs/hello.md` is
  the output of the sibling `protoc-gen-tarantool-doc` plugin
  against `examples/proto/hello.proto`. Same plugin can run against
  any `.proto` to produce its own per-file Markdown.

## Specs

Forward-looking design docs. These describe contracts and trade-offs
for work that's either partly shipped or planned.

- **[specs/grpc_transports.md](specs/grpc_transports.md)** — gRPC
  and HTTP/JSON serving: the split between `pb` and the tarantool-http2
  rock, `pb.server`, transcoding, reflection and health, the status-code
  mapping, and how each layer is verified against independent clients.
  Shipped; TLS, compression, gRPC-Web and an outbound network client
  are deferred.
- **[specs/msgpack_encoding.md](specs/msgpack_encoding.md)** —
  brainstorm for a sibling MsgPack codec over the same descriptors.
  Not implemented; design sketch for picking up later.

## Maintainers

- **[releasing.md](releasing.md)** — what a release publishes besides
  the tag: the options module on the Buf Schema Registry (exact
  commands, CI sketch) and the extension-number question.

## Internals

- **[codegen.md → The hot-path rules the generated code observes](codegen.md#the-hot-path-rules-the-generated-code-observes)**
  — invariants enforced across the codebase: no `pairs()` on hot
  paths, 64-bit ints as cdata, SoA over AoS for large index
  structures, keep hot helpers small, WKT routing.
