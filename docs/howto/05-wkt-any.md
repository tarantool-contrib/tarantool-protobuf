# How-to: packing and unpacking `google.protobuf.Any`

`Any` carries a *typed* message payload as opaque bytes plus a
`type_url`. It's the WKT for "this field holds some other message,
and I don't know which until I look at it." (Compare with `Struct`,
which carries *JSON-shaped* data — see
[how-to: Struct, Value, ListValue](04-wkt-struct-value.md).)

## The shape

```lua
-- An Any value is a Lua table of this shape:
{
    type_url = 'type.googleapis.com/hello.Address',
    value    = '<wire bytes of the inner message>',
}
```

You can pass this verbatim into any `Any`-typed field. The runtime
provides two helpers to make pack/unpack ergonomic:
`pb.any.pack(desc, t)` and `pb.any.unpack(any_t, desc?)`.

## Packing

```lua
local pb = require('pb')
local hello = require('full.hello.hello_pb')

local addr = {street = '5th Ave', city = 'NYC', zip = 10001}
local any_t = pb.any.pack(hello.Address_descriptor, addr)

-- any_t = {
--     type_url = 'type.googleapis.com/hello.Address',
--     value    = '<encoded bytes>',
-- }

-- Drop it into an Any-typed field on some other message:
local e = hello.Event_encode({title = 'demo', extension = any_t})
```

By default the type URL prefix is `type.googleapis.com` (the gRPC
convention). Override with a third argument:

```lua
pb.any.pack(hello.Address_descriptor, addr, 'myorg.example.com')
-- type_url = 'myorg.example.com/hello.Address'
```

The part *after* the last `/` is the fully-qualified proto name; that's
what `pb.any.unpack` keys off, so the prefix is purely informational
unless your registry is prefix-aware.

## Unpacking

Two flavors:

### Explicit descriptor

```lua
local d = hello.Event_decode(e)
local addr = pb.any.unpack(d.extension, hello.Address_descriptor)
print(addr.street, addr.city)
```

This is the safe path — you've validated the descriptor matches what
you expect. Works without any registry setup.

### Registry lookup

If you have many possible types, register them up-front:

```lua
pb.register(hello.Address_descriptor)
pb.register(hello.Person_descriptor)
-- ...register every descriptor you might unpack...

local payload = pb.any.unpack(d.extension)  -- no second arg
```

`pb.any.unpack` reads `type_url`, strips the prefix, and looks up
`<fully-qualified-name>` in the registry. If not registered, it errors.

Registry registration is **not automatic** — generated `_pb.lua`
doesn't call `pb.register` on its descriptors. Decide which types
your app accepts via `Any` and register exactly those.

## When `type_url` is unknown

If you receive an `Any` whose type you don't recognize, leave it
opaque. The Lua table form is good enough for passthrough:

```lua
local function handle(any_t)
    if any_t.type_url == 'type.googleapis.com/hello.Address' then
        local addr = pb.any.unpack(any_t, hello.Address_descriptor)
        return process_address(addr)
    elseif any_t.type_url == 'type.googleapis.com/hello.Person' then
        local p = pb.any.unpack(any_t, hello.Person_descriptor)
        return process_person(p)
    else
        -- Unknown type — log, drop, or re-emit verbatim:
        log.warn('unknown Any type: ' .. any_t.type_url)
        return nil
    end
end
```

Re-encoding the opaque `{type_url, value}` table back into the outer
message is byte-stable — the codec doesn't second-guess the inner
bytes when you didn't unpack them. That makes proxy/router shapes
work without registering every possible type.

## JSON form

The proto3 JSON canonical mapping for `Any` is the flat
`{"@type": "...", "fieldA": ..., "fieldB": ...}` envelope when the type
is registered:

```lua
pb.register(hello.Address_descriptor)
local pbjson = require('pb').json

print(pbjson.encode(hello.Event_descriptor, {
    title = 'demo',
    extension = pb.any.pack(hello.Address_descriptor, addr),
}))
-- {"title":"demo","extension":{"@type":"type.googleapis.com/hello.Address","street":"5th Ave","city":"NYC","zip":10001}}
```

When the type isn't registered, the JSON encoder falls back to the
opaque form: `{"@type":"...","value":"<base64>"}`.

## Security notes

- An attacker who controls the `type_url` can make your code decode
  arbitrary registered types. Limit `pb.register` to the types you
  actually want to accept; treat the registry as an allowlist.
- The `value` bytes are *not* validated until you unpack. A
  `value`-only check (length, prefix bytes) is cheap and useful
  before calling `pb.any.unpack` on untrusted input.
- `type_url`'s prefix is purely informational unless your code
  enforces it. If you care that requests come from a specific
  authority, check the prefix explicitly:

```lua
if not any_t.type_url:find('^type.googleapis.com/') then
    error('unexpected type_url prefix', 0)
end
```

## What's next

- [Reference: runtime API → Any](../reference/runtime-api.md#any)
  — full signatures.
- [How-to: Struct/Value/ListValue](04-wkt-struct-value.md) — the
  JSON-shaped sibling to `Any`.
