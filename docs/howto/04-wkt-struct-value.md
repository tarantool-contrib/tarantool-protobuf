# How-to: round-tripping Struct, Value, and ListValue

`google.protobuf.Struct`, `Value`, and `ListValue` are designed to
carry arbitrary JSON-shaped data through proto. They're the WKT slice
with the most foot-guns — null sentinel, disambiguation between Struct
vs Value vs ListValue, integer-vs-float — so this how-to walks through
the Lua-side conventions.

## The shapes

| Proto type | Lua-side value | Use when |
|---|---|---|
| `Struct` | plain Lua table with string keys | The field is *typed* `Struct`. |
| `ListValue` | plain Lua array (1-based contiguous) | The field is *typed* `ListValue`. |
| `Value` | native Lua of matching shape (scalar / table / array / `pb.NULL`) | The field is `Value` — the codec auto-detects via Lua type. |

Pick `Struct` or `ListValue` whenever you can — they're unambiguous.
Pick `Value` when the schema needs a "this could be anything" cell.

## Setting a `Value` field

```lua
local pb = require('pb')
local hello = require('full.hello.hello_pb')  -- has Event.attribute: Value

-- Scalars round-trip natively:
hello.Event_encode({attribute = 'a string'})
hello.Event_encode({attribute = 42})
hello.Event_encode({attribute = true})
hello.Event_encode({attribute = pb.NULL})      -- JSON null
```

For container shapes, the codec needs to know whether you mean a
`Struct` (string-keyed map) or a `ListValue` (1-based array). Two
ways to disambiguate:

```lua
-- 1. Tag with pb.wkt.struct(t) / pb.wkt.list(t):
hello.Event_encode({attribute = pb.wkt.struct({nested = 'x'})})
hello.Event_encode({attribute = pb.wkt.list({1, 2, 3})})

-- 2. Or pass a table the codec can auto-classify: dictionary-shaped
--    tables become Struct, 1-based contiguous arrays become ListValue.
hello.Event_encode({attribute = {nested = 'x'}})  -- Struct
hello.Event_encode({attribute = {1, 2, 3}})       -- ListValue
```

The auto-classifier is good enough for most cases. Use the tags when
the table is ambiguous (empty `{}`, mixed keys, etc.) — explicit beats
the heuristic.

## Setting a `Struct` field (typed)

When the schema is `google.protobuf.Struct` directly, the field always
holds a string-keyed table — no disambiguation needed:

```lua
hello.Event_encode({
    payload = {
        greeting = 'hi',
        count = 42,
        active = true,
        when = pb.NULL,
        nested = {a = 1, b = 2},
    },
})
```

Decoded:

```lua
local d = hello.Event_decode(bytes)
print(d.payload.greeting)             -- 'hi'
print(d.payload.count)                -- 42
print(d.payload.when == pb.NULL)      -- true
print(d.payload.nested.a)             -- 1
```

## Null vs absent

Two distinct concepts:

- **Absent** — the field wasn't set. `t.foo` is `nil` (for
  `Value` / `Struct`) or `{}` (proto3 default for repeated/map).
- **Null** — the field is explicitly `Value{null_value}` /
  `Struct` value of null. Lua-side sentinel is `pb.NULL`.

```lua
hello.Event_encode({payload = {seen = pb.NULL}})        -- explicit null
hello.Event_encode({payload = {}})                      -- empty Struct
hello.Event_encode({})                                  -- payload absent
```

`pb.NULL` is equal to `box.NULL`. Use `pb.NULL` so app code doesn't
need to `require('box')` just for the sentinel.

## Number gotchas

Proto3 `Value` is a `double` under the hood — integers and floats
share the wire encoding. The codec preserves Lua integer-vs-float when
encoding (`42` stays integer; `42.5` stays float), but on the
*decode* side everything that travels through `Value` comes back as a
Lua `number`. If you need a 64-bit integer through `Value` you must
either:

1. Box it as a `Struct` with two fields (`hi` / `lo`), or
2. String-encode it, or
3. Switch to a strongly-typed schema field (`int64`).

This is a `Value` limitation, not a codec one — JSON has the same
trade-off and `Value` is `Struct`-shaped for JSON-compat reasons.

## Mixed lists

`ListValue` carries an array of `Value`s, so mixed-type arrays work:

```lua
hello.Event_encode({tags = {'a', 'b', 3, true, pb.NULL}})

local d = hello.Event_decode(bytes)
-- d.tags = {'a', 'b', 3, true, pb.NULL}
```

Each entry passes through the same `Value` auto-classification as
above, so tables inside a `ListValue` need the same `pb.wkt.struct` /
`pb.wkt.list` tagging when ambiguous.

## Round-tripping through JSON

The proto3 JSON mapping for `Struct` / `Value` / `ListValue` is
"native JSON" — no envelope, just the shape itself. `pb.json.encode`
emits the table content directly:

```lua
local pbjson = require('pb').json
print(pbjson.encode(hello.Event_descriptor, {
    payload = {greeting = 'hi'},
}))
-- {"payload":{"greeting":"hi"}}
```

This matches mainline protoc and is what makes `Struct` useful as a
JSON-in-proto cell.

## What's next

- [How-to: packing and unpacking Any](05-wkt-any.md) — the WKT for
  typed message payloads (vs `Struct` which is JSON-typed).
- [Reference: runtime API → WKT](../reference/runtime-api.md#well-known-types--pbwkt)
  — every WKT descriptor and helper.
