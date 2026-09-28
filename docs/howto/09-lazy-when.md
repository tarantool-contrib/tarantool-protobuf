# How-to: when to use `decode_lazy`

The lazy decoder (`pb.decode_lazy` / generated `Foo_decode_lazy`)
trades a higher fixed cost per message for near-zero cost on
subsequent field reads. Pick it when the math works out; stick with
the eager `Foo_decode` otherwise.

The lazy view's full surface is documented in
[api-modes.md → lazy](../api-modes.md#lazy-zero-copy-view) (`:get`,
`:has`, `:set`, `:iter`, `:totable`, the field-name constants
contract). This page is the *picking* guide.

## When lazy wins

### 1. Sparse reads

If you decode a large message and read only a few fields, the eager
decoder wastes work on everything else. Lazy builds a wire-segment
index (one Lua table + four SoA int arrays) and only materializes
fields you `:get`.

The cross-over on `hello.Person` (the bench message) is roughly **1 KB**:
below that, eager wins on tiny payloads; above, lazy is competitive
on dense reads and wins on sparse ones. See `bench/baseline.json` for
the exact alloc-per-op numbers eager hits at each size.

### 2. Mostly-passthrough re-encode (proxy / router shapes)

Decode → look at a few fields → re-encode. Lazy's byte-splice path
re-emits untouched fields verbatim — only fields you `:set` go through
the encoder. On the 100 KB `hello.Person` workload this puts the
mutate-then-reencode shape at **1.09-1.26× of eager**'s full decode +
encode round-trip.

```lua
local view = hello.Person_decode_lazy(bytes)
local F = hello.Person_fields

-- Look at one field, mutate another, re-emit.
local id = view:get(F.user_id)
if id > 0 then
    view:set(F.user_id, pb.to_uint64(id + 1))
end
local new_bytes = view:encode()
```

### 3. Iterating large repeated fields without intermediate tables

`ArrayView:iter()` yields one value at a time without allocating a
flat Lua array first. Useful when the result of the iteration is
something other than "I want all the values in a Lua table" (filter,
fold, find-first).

```lua
local view = hello.Person_decode_lazy(bytes)
for i, email in view:get(hello.Person_fields.emails):iter() do
    if email:find('@example%.com$') then
        log.info('found ' .. email)
        break
    end
end
```

## When lazy loses

### 1. Dense reads

If you read every field, the index build is wasted work and each
`:get` adds a Lua-call boundary the eager decoder avoided. Eager wins
by ~10-30% on full-field walks. Rule of thumb: if you find yourself
calling `:totable()` to get a plain Lua table out, you wanted the
eager decoder to begin with.

### 2. Tiny messages

Below ~1 KB on `hello.Person`, the index build dominates. The
eager decoder also has a flat trace and dispatches into typed
helpers in one shot; lazy has unavoidable overhead from MessageView's
allocation and the SoA index initialization.

### 3. Code paths that need a plain Lua table

`:totable()` reverses the win — it forces a full materialize. Any
consumer that wants the result as a plain Lua table (JSON encoding
through `pb.json.encode`, persistence, comparing equal to another
table) is paying eager-decode work plus the index-build overhead.

## Picking by workload shape

| Workload | Pick | Reasoning |
|---|---|---|
| RPC handler that reads every field and runs business logic | Eager | Dense reads; index build is overhead. |
| Stream filter that drops 95% of messages after looking at one field | Lazy | Sparse reads; the 95% never paid for the body. |
| Proxy / router (decode, log, mutate one header, re-encode) | Lazy | Byte-splice re-encode skips most of the work. |
| Periodic snapshot that serializes 1k messages to JSON | Eager | `pb.json.encode` materializes everything anyway. |
| Lookup-by-id over a large repeated message | Lazy with `ArrayView:iter()` | Find-first avoids intermediate flat array. |
| Tiny messages (<1 KB), any access pattern | Eager | Index build dominates. |
| Storing decoded results across many requests | Eager | Lazy views hold references to the input bytes; keep allocations short-lived. |

## Field-name constants — required for lazy

The lazy view's `:get` / `:has` / `:set` / `:clear` / `:which` take a
field name **string**, not a Lua identifier. Always route through the
generated strict-table constants:

```lua
-- right
local F = hello.Person_fields
view:get(F.user_id)
-- typo: errors at the read site
-- view:get(F.user_di)  -- "unknown field name: 'user_di'"

-- wrong
view:get('user_id')      -- works
view:get('user_di')      -- silently returns nil (looks like absent)
```

Without the constants, a typo and a legitimately-absent field are
indistinguishable. The strict table catches the typo where it was
written. This is a lazy-view contract — the eager decoder doesn't
need it because misspelled table keys fail visibly in tests.

See [api-modes.md → field-name constants](../api-modes.md#field-name-constants--required)
for the full reasoning.

## Measuring

`just bench` prints alloc per op for full + runtime mode at 5 payload
sizes. `bench/baseline.json` is the committed reference.

For lazy specifically there's `bench/lazy_bench.lua` (run via the
same `just bench` target) that exercises the sparse-read and
mostly-passthrough-reencode shapes against the eager baseline. Use
this when comparing a hypothetical lazy migration against the
eager-decode allocation budget you already pay.

## What's next

- [API modes](../api-modes.md) — the full overview of full /
  runtime / lazy.
- [Reference: runtime API → decode_lazy](../reference/runtime-api.md#pbdecode_lazydesc-bytes---messageview)
  — signature and link to `MessageView` / `ArrayView` / `MapView`.
