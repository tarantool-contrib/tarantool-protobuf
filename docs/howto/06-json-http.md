# How-to: JSON over `tarantool/http`

Use `pb.json` to expose proto-defined messages as a JSON HTTP API.
This is the lowest-friction way to give external clients (browsers,
curl, mobile) a typed API without running HTTP/2 termination or a
gRPC proxy.

The wire is JSON; the *schema* is your `.proto`. Same shape on both
sides; same field names (camelCase per proto3 JSON spec — see
[the proto3 JSON mapping][proto3json] for the canonical rules the
codec follows).

[proto3json]: https://protobuf.dev/programming-guides/proto3/#json

## Setup

Install the `http` rock (`tt rocks install http`) and the standard
runtime/example `LUA_PATH`:

```bash
LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;" \
    tarantool examples/http/json_api.lua
```

## The handler

`examples/http/json_api.lua`:

```lua
local pb    = require('pb')
local http  = require('http.server')
local hello = require('full.hello.hello_pb')

local httpd = http.new('127.0.0.1', 8080)

httpd:route({path = '/v1/users', method = 'POST'}, function(req)
    local body = req:read_cached()

    -- proto3 JSON → Lua table, validated against the schema.
    local ok, person = pcall(pb.json.decode, hello.Person_descriptor, body, {
        ignore_unknown_fields = true,
    })
    if not ok then
        return {status = 400,
                headers = {['content-type'] = 'application/json'},
                body = pb.json.encode(hello.HelloReply_descriptor,
                                      {greeting = 'bad request: ' .. person})}
    end

    -- Business logic.
    person.user_id = pb.to_uint64(42)

    return {
        status = 200,
        headers = {['content-type'] = 'application/json'},
        body = pb.json.encode(hello.Person_descriptor, person),
    }
end)

httpd:start()
```

Call it:

```bash
curl -X POST http://127.0.0.1:8080/v1/users \
     -H 'Content-Type: application/json' \
     -d '{"name":"Alice","age":30,"emails":["a@x"]}'
```

Response:

```json
{"age":30,"name":"Alice","emails":["a@x"],"userId":"42"}
```

Notes on the response:

- `userId` is camelCase per the proto3 JSON spec, even though the
  proto field is `user_id`.
- `userId` is a JSON **string** because the field is `fixed64` and
  64-bit integers don't fit a JSON `number` losslessly. The codec
  follows the spec here; `int32` and `uint32` come out as numbers.

## `ignore_unknown_fields`

Default is **strict** — `pb.json.decode` errors on unknown keys. Pass
`{ignore_unknown_fields = true}` to accept them silently (matches the
conformance suite's `JSON_IGNORE_UNKNOWN_PARSING_TEST` category and is
the right choice for forward-compat: clients can send fields you
haven't shipped support for yet).

## Mapping the proto3 JSON rules

What the codec does, per the spec:

| Proto type | JSON shape |
|---|---|
| `string` | string |
| `bytes` | base64 string |
| `bool` | bool |
| `int32`, `uint32`, `enum` | number (or enum-name string for known enum values) |
| `int64`, `uint64`, `fixed64`, `sfixed64`, `sint64` | **string** (lossless 64-bit) |
| `float`, `double` | number, or `"NaN"` / `"Infinity"` / `"-Infinity"` |
| `repeated T` | array |
| `map<K, V>` | object (keys coerced to strings per spec) |
| `Timestamp` | RFC 3339 string (`"2026-05-16T10:30:00Z"`) |
| `Duration` | string with `s` suffix (`"3.5s"`) |
| `Struct` / `Value` / `ListValue` | native JSON of matching shape |
| `Any` (registered) | flat object with `"@type": "..."` |
| `Any` (unregistered) | `{"@type": "...", "value": "<base64>"}` |
| `FieldMask` | lowerCamelCase paths joined by `,` |
| `<T>Value` wrappers | unwrapped scalar |
| missing proto3 implicit field | omitted from JSON (proto3 default) |
| missing explicit-optional | omitted; decoded back as `nil` |

## Errors

`pb.json.encode` raises on:
- 64-bit fields holding bare Lua numbers (use `pb.to_int64` /
  `pb.to_uint64`)
- Invalid UTF-8 in `string` fields
- Out-of-spec `Timestamp` (negative nanos, year > 9999)
- A `Value` holding a Lua type the spec doesn't map (function,
  userdata)

`pb.json.decode` raises on:
- Malformed JSON (parse error)
- Unknown keys, unless `ignore_unknown_fields = true`
- Duplicate keys at the same nesting level (strict-validation pass)
- Numbers that don't fit the target proto type (overflow,
  fractional values for integer fields)

Wrap calls in `pcall` and surface a clean error response to the
client.

## Production checklist

- **Content type negotiation.** Real services should support both
  `application/json` (this howto) and `application/proto` (raw wire
  bytes via `Foo_encode`/`Foo_decode`). Branch on
  `req.headers['content-type']`.
- **Schema versioning.** Adding fields is wire-compatible; removing
  fields means old clients can still send them, and JSON
  `ignore_unknown_fields` lets you ignore the leftovers. Reuse
  field numbers only after a `reserved` declaration.
- **Logging.** Don't log raw bodies that may contain credentials or
  PII. The codec roundtrips `bytes` fields as base64 — if you log a
  decoded message you'll see the base64; if you log the raw body
  you'll see whatever JSON was sent.
- **Streaming responses.** `pb.json` is one-shot (encode the whole
  message). For NDJSON-style streaming, encode each message
  separately and join with `\n`.

## What's next

- [Reference: runtime API → JSON](../reference/runtime-api.md#pbjson)
  — full `pb.json.encode` / `pb.json.decode` signatures.
- [How-to: Struct, Value, ListValue](04-wkt-struct-value.md) — when
  your JSON has dynamic shape inside a fixed schema.
