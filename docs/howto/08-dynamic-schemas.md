# How-to: dynamic schemas from a Tarantool space

When you can't (or don't want to) run `protoc` at build time — schema
registries, multi-tenant apps where each tenant has their own messages,
plugin systems where users upload protos — `pb.parse` and `pb.from_pb`
let you build descriptor modules at runtime from `.proto` source or
binary `FileDescriptorSet` bytes.

## Two entry points

| Function | Input | Best for |
|---|---|---|
| `pb.parse(text)` | `.proto` source string | User-uploaded protos, schemas living in a space as text, REPL exploration. |
| `pb.from_pb(bytes)` | Binary `FileDescriptorSet` | `protoc --descriptor_set_out=…` artifacts; gRPC reflection responses; multi-file schemas with imports. |

Both return modules **shaped exactly like generated `mode=runtime`
output** — same `<Msg>_descriptor`, `<Msg>_encode`, `<Msg>_decode`,
`<Msg>_decode_lazy`, `<Msg>_text` surface. Anything that consumes a
generated module consumes these.

## `pb.parse` — source string in, module out

```lua
local pb = require('pb')

local source = [[
syntax = "proto3";
package demo;

message User {
    int32 id = 1;
    string name = 2;
    repeated string tags = 3;
}
]]

local demo = pb.parse(source)

local bytes = demo.User_encode({
    id = 42, name = 'Alice', tags = {'admin', 'active'},
})
local user = demo.User_decode(bytes)
```

The parser handles every proto3 grammar bucket: services, options,
imports, nested messages, oneofs, maps, explicit-optional. WKT imports
(`google/protobuf/*.proto`) resolve to the runtime's `pb.wkt`
descriptors automatically — no extra setup needed.

## Storing schemas in a space

The runnable example lives at
`examples/dynamic/load_from_space.lua`. Pattern:

```lua
local pb = require('pb')

-- One row per schema, keyed by name + carrying a version for invalidation.
box.schema.space.create('proto_schemas')
box.space.proto_schemas:format({
    {name = 'name',    type = 'string'},
    {name = 'version', type = 'unsigned'},
    {name = 'source',  type = 'string'},
})
box.space.proto_schemas:create_index('pk', {parts = {'name'}})

-- Cache parsed modules by (name, version). Bumping the version in the
-- row evicts the cache entry naturally on next get_module.
local cache = {}

local function get_module(name)
    local row = box.space.proto_schemas:get(name)
    if row == nil then error('schema not found: ' .. name, 0) end
    local key = name .. '@' .. tostring(row.version)
    local mod = cache[key]
    if mod == nil then
        mod = pb.parse(row.source)
        cache[key] = mod
    end
    return mod
end
```

Why version-keyed cache: an UPDATE on the row bumps the version, so
the next `get_module` parses the new source and the old module
naturally becomes unreachable.

## Schema evolution

Adding a field is wire-compatible. Bytes encoded with the old schema
decode fine with the new one (the new field reads as its proto3
default; explicit-optional reads as `nil`):

```lua
local bytes_v1 = old.User_encode({id = 42, name = 'Alice'})

box.space.proto_schemas:replace{'demo.user', 2, [[
syntax = "proto3";
package demo;
message User {
    int32 id = 1;
    string name = 2;
    repeated string tags = 3;
    string email = 4;  -- new
}
]]}

local user_via_v2 = get_module('demo.user').User_decode(bytes_v1)
-- user_via_v2.email == ""  (proto3 default for implicit-presence string)
```

Removing a field is **not** wire-compatible — the bytes for that field
become "unknown" to the new schema. The runtime preserves them via
`_unknown_fields` so a round-trip back through the same instance
keeps the data, but consumers that only see the new schema can't see
the field.

Reusing a field number after removal is a category of data corruption
the wire format can't catch. If you remove a field, `reserved 4;` the
number to prevent reuse.

## `pb.from_pb` — for compiled descriptor sets

When you have a `FileDescriptorSet` (from `protoc --descriptor_set_out`
or a gRPC reflection response), `pb.from_pb` ingests it:

```lua
local pb = require('pb')

-- Build the FileDescriptorSet at deploy time, ship it as a blob.
--   protoc --descriptor_set_out=schemas.pb --include_imports my/app/*.proto
local bytes = io.open('schemas.pb', 'rb'):read('*a')
local set = pb.from_pb(bytes)

-- Lookup by file name (the original .proto path):
local hello = set.files['hello.proto']
local user_bytes = hello.User_encode({...})

-- Or by fully-qualified message name across all files:
local desc = set.lookup('hello.Person')
local user_bytes = pb.encode(desc, {...})
```

`--include_imports` is important — it embeds every transitively-imported
file in the set. Without it, references to imports won't resolve.

## When to pick which

| Use case | Pick |
|---|---|
| Schemas authored by users (admin UI, REST endpoint) | `pb.parse` — they paste `.proto` source. |
| Multi-tenant where each tenant has their own schemas | `pb.parse`, keyed by tenant in a space. |
| Schemas built at deploy time, distributed as a blob | `pb.from_pb` — runs ~10x faster than `pb.parse` on large schemas, and you skip the parser entirely. |
| gRPC server reflection consumer | `pb.from_pb` — the response is a `FileDescriptorSet`. |
| REPL exploration | `pb.parse` — paste a string. |

For known-at-build-time schemas, generated `_pb.lua` is still the
right choice — same module shape, no startup cost, JIT-friendly
inline encode/decode in `mode=full`.

## Cost notes

`pb.parse` does real lexing/parsing work — keep it out of hot paths.
Parse once at boot (or per-schema-update) and cache the resulting
module. Encode/decode against a parsed-descriptor module runs the
same codec as generated `mode=runtime`, ~5-15% slower than full-mode
inline; allocation profile matches.

`pb.from_pb` skips parsing entirely (it consumes binary protobuf
itself, via the hand-built `descriptor.proto` descriptors in
`runtime/pb/descriptor_pb.lua`).

## What's next

- [Reference: runtime API](../reference/runtime-api.md#dynamic-descriptors)
  — full `pb.parse` / `pb.from_pb` signatures.
- [How-to: build integration](12-build-integration.md) — generating
  `--descriptor_set_out` from your build system.
