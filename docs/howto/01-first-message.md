# How-to: your first message, end-to-end

Goal: take a `.proto` file from zero to a Tarantool process encoding
and decoding it.

## What you need

- `tarantool` (3.x, with LuaJIT 2.1)
- `protoc` (Google's compiler — `brew install protobuf` on macOS,
  `apt install protobuf-compiler` on Debian/Ubuntu)
- The `protoc-gen-tarantool` binary on `PATH` — build it with
  `just build` from this repo, or `go build -o protoc-gen-tarantool
  ./cmd/protoc-gen-tarantool` and copy the result.

## 1. Write the proto

The example file lives at `examples/proto/quickstart.proto`:

```proto
syntax = "proto3";

package quickstart;

enum Role {
  ROLE_UNSPECIFIED = 0;
  USER = 1;
  ADMIN = 2;
}

message User {
  int32 id = 1;
  string name = 2;
  Role role = 3;
  repeated string emails = 4;
}
```

## 2. Generate the Lua module

```bash
protoc --tarantool_out=./out -I. examples/proto/quickstart.proto
```

This drops `out/quickstart/quickstart_pb.lua`. The output path mirrors
the proto package (`package quickstart;` → `quickstart/`).

To change where it lands, see
[how-to: module layout](02-module-layout.md).

## 3. Round-trip in Tarantool

The generated module requires `pb` from `runtime/pb/`, so point
`LUA_PATH` at both `runtime/` and the generated `out/` directory:

```bash
tarantool -e '
package.path = "./runtime/?/init.lua;./runtime/?.lua;./out/?.lua;./out/?/init.lua;" .. package.path

local qs = require("quickstart.quickstart_pb")

-- Encode a Lua table to wire bytes.
local bytes = qs.User_encode({
    id = 7,
    name = "Alice",
    role = qs.Role.ADMIN,
    emails = {"a@x", "b@x"},
})
print(#bytes .. " bytes")

-- Decode back.
local user = qs.User_decode(bytes)
print(user.id, user.name, user.role, user.emails[1], user.emails[2])

-- Pretty-print with text format (mainline-protoc compatible).
print(qs.User_text(user))
'
```

Expected output:

```
21 bytes
7	Alice	2	a@x	b@x
id: 7
name: "Alice"
role: ADMIN
emails: "a@x"
emails: "b@x"
```

## 4. Common issues

**`module 'pb' not found`** — `LUA_PATH` doesn't include the
`runtime/` directory. The two patterns you need are
`./runtime/?/init.lua` (for `require('pb')` → `runtime/pb/init.lua`)
and `./runtime/?.lua` (for sibling modules like `require('pb.wire')`).

**`module 'quickstart.quickstart_pb' not found`** — generated path
isn't on `LUA_PATH`. Add `./out/?.lua;./out/?/init.lua;` (or whatever
directory you passed to `--tarantool_out`).

**`expected cdata int64_t, got number`** — you passed a Lua number
to a `int64` / `uint64` / `fixed64` / `sfixed64` / `sint64` field.
Use `pb.to_uint64(value)` or `pb.to_int64(value)` to coerce:

```lua
local pb = require("pb")
qs.User_encode({id = pb.to_int64(7)})
```

(The `User.id` example above is `int32`, which accepts a plain Lua
number — only 64-bit-typed fields need the coercion.)

**`protoc-gen-tarantool: program not found or is not executable`** —
`protoc` couldn't find the plugin on `PATH`. Either copy the binary
to a directory on `PATH`, or invoke `protoc` with an explicit
`--plugin=` flag:

```bash
protoc --plugin=protoc-gen-tarantool=./protoc-gen-tarantool \
       --tarantool_out=./out ...
```

## What's next

- [Module layout](02-module-layout.md) — control where generated
  modules land and what their require paths look like.
- [Reference: generated API](../reference/generated-api.md) — every
  symbol the plugin emits per message/enum/service.
- [Reference: runtime API](../reference/runtime-api.md) — what
  `require('pb')` gives you beyond `encode` / `decode`.
- [API modes](../api-modes.md) — when to use full vs runtime vs
  lazy.
