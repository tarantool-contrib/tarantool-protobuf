# How-to: migrating from the built-in `require('protobuf')`

Tarantool ships an in-tree `protobuf` module. It's small, encode-only,
and predates this project. If you're already using it, this is the
side-by-side guide to switching.

The relevant differences:

| | Built-in `protobuf` | `pb` (this project) |
|---|---|---|
| Module name | `require('protobuf')` | `require('pb')` (different name so both can coexist) |
| Schema source | Inline Lua tables (`protobuf.message{...}`) | `.proto` files + `protoc` plugin (or runtime `pb.parse`) |
| Encode | ✅ | ✅ |
| Decode | ❌ | ✅ |
| `map<K,V>` | ❌ | ✅ |
| `oneof` | ❌ | ✅ |
| `repeated` | ✅ | ✅ |
| WKT (Timestamp, Any, Struct, …) | ❌ | ✅ |
| `optional` (proto3) | ❌ | ✅ with `has_*`/`clear_*` |
| Services (gRPC stubs) | ❌ | ✅ |
| JSON / text format | ❌ | ✅ |
| 64-bit ints as cdata | ✅ | ✅ (same convention) |
| Conformance with mainline `protoc` | partial | proto3-complete (Google's conformance suite, 0 failures) |

Both can run in the same process — `pb` is named differently
specifically so they don't collide.

## Translating schemas

The built-in describes messages as Lua tables. Translate them to `.proto`
files for the codegen path, or to inline `pb.parse(...)` calls for the
runtime path.

### Built-in

```lua
local p = require('protobuf')
local proto = p.protocol{
    p.message('User', {
        name   = {'string', 1},
        age    = {'int32',  2},
        emails = {'string', 3, 'repeated'},
    }),
    p.enum('Role', {
        USER  = 0,
        ADMIN = 1,
    }),
}

local bytes = proto:encode('User', {name = 'Alice', age = 30, emails = {'a@x'}})
```

### `pb` (codegen path)

`user.proto`:

```proto
syntax = "proto3";
package app;

enum Role {
    USER  = 0;
    ADMIN = 1;
}

message User {
    string name = 1;
    int32  age  = 2;
    repeated string emails = 3;
}
```

`protoc --tarantool_out=./gen user.proto` then:

```lua
local user = require('app.user_pb')
local bytes = user.User_encode({name = 'Alice', age = 30, emails = {'a@x'}})
local back  = user.User_decode(bytes)  -- new capability!
```

### `pb` (no-codegen path)

If you want to keep schemas inline in Lua (matches the built-in's
ergonomics), use `pb.parse`:

```lua
local pb = require('pb')
local user = pb.parse([[
syntax = "proto3";
package app;
message User {
    string name = 1;
    int32  age  = 2;
    repeated string emails = 3;
}
]])

local bytes = user.User_encode({name = 'Alice', age = 30})
local back  = user.User_decode(bytes)
```

See [how-to: dynamic schemas](08-dynamic-schemas.md) for the runtime-
parse approach.

## API call-site changes

| Built-in | `pb` |
|---|---|
| `proto:encode('User', t)` | `user.User_encode(t)` |
| (no decode) | `user.User_decode(b)` |
| `proto:encode(msg_name, ...)` returns `string` | `User_encode(t)` returns `string` (same) |
| Lua tables: 1-based arrays for repeated, hash for map (encode only) | Same shape — repeated stays 1-based arrays, maps stay hash tables |
| 64-bit fields: `int64_t` / `uint64_t` cdata | Same |
| `pcall(proto.encode, proto, ...)` for errors | Same: `pcall(user.User_encode, t)` |

The data shape is the same — translating happens at the schema
declaration, not at the encode call sites. A direct find-replace from
`proto:encode('User', t)` to `user.User_encode(t)` covers most of the
migration.

## Behavioral differences

### Defaults

Proto3 elides default values on encode (`age = 0` is omitted from the
wire, unless the field is explicit-`optional`). The built-in followed
the same proto3 convention — no change.

### Packed repeated

Both encode `repeated int32` etc. as packed by default. No change.

### Unknown fields

The built-in didn't decode, so this didn't come up. `pb` preserves
unknown fields by default — they decode into `t._unknown_fields` (raw
bytes) and re-emit on encode. If your producer was encoding extra
fields the consumer didn't know about, those now round-trip cleanly
through `pb`.

### Errors

Built-in raised on encode of unknown fields (typo in the table key
silently encoded as nothing? or raised? — version-dependent). `pb`
ignores unknown table keys on encode but raises on shape mismatches
(wrong Lua type for the declared proto type, etc.).

If you relied on encode-side strictness for typo detection, route
field-name accesses through the strict `M.User_fields` table (only
emitted for the lazy view today; eager encoders trust the input
shape).

## Things you can do now that you couldn't before

- **Decode.** `User_decode(bytes)` round-trips any input the
  built-in produced (and any input mainline `protoc` produced).
- **Maps and oneofs.** Both round-trip.
- **WKT.** `google.protobuf.Timestamp` ↔ Tarantool `datetime`;
  `Duration`, wrappers, `Struct`, `Any`, `FieldMask`, `Empty`.
- **Services.** Generated `*_client` / `*_server` factories with a
  pluggable transport contract.
- **JSON.** `pb.json.encode` / `pb.json.decode` against the same
  descriptor.
- **Text format.** `User_text(t)` for debug printing.
- **Lazy view.** `User_decode_lazy(b)` for proxy/router shapes that
  touch a few fields and re-encode.
- **Runtime schemas.** `pb.parse` / `pb.from_pb` for descriptors
  built at runtime.

## What's next

- [How-to: first message](01-first-message.md) — the green-field
  path if you'd rather start fresh.
- [Reference: generated API](../reference/generated-api.md) —
  what `User_pb.lua` exposes.
- [How-to: dynamic schemas](08-dynamic-schemas.md) — for the
  inline-schema style the built-in encouraged.
