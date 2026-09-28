# Spec: C-acceleration C-side strategy

Status: **design locked, implementation pending**. This spec records
the low-level C-side decisions that the generic runtime and its
plan-compiler foundation inherit. Every choice here is validated
by the `bench/c_accel/` spike — see
[bench/c_accel/README.md](../../bench/c_accel/README.md) for the
microbenchmark numbers.

## Scope

This spec is about how C code interacts with the Lua state — field
access, table allocation, string handling, stack discipline, 64-bit
cdata. It is **not** about the wire format (which the pure-Lua
`runtime/pb/wire.lua` already specifies) or about the descriptor
shape (which [docs/codegen.md](../codegen.md) specifies).

If a strategy decision here conflicts with the
[compatibility contract](c_accel_compat.md), the contract wins.

## Strategy overview

Strategy 3 from the spike (`S3`): **one C entry point per top-level
encode or decode call.** The C side walks a compiled descriptor
plan, reads/writes the wire bytes, and crosses back to Lua once at
the end. Per-field dispatch happens in C, not in Lua.

Strategy 2 (per-primitive FFI) was rejected: spike showed every
size on decode is worse than pure Lua, and ≥1 KB encode regresses.
Strategy 4 (codegen-emitted C per message) is deferred — ≤15% over
S3 on the spike doesn't justify the codegen complexity without a
real-workload trigger.

## The plan userdata

Each finalized message descriptor gains an opaque `c_plan`
userdata when `PB_ENABLE_C=1` and the C module loads. The plan is:

- Allocated once, at module load time (during
  `pb.finalize_message(desc)`).
- Process-local. Not serialized, not shared, not cached.
- Anchored on the descriptor table to share its lifetime; freed by
  GC when the descriptor itself drops.
- Opaque to Lua. Only the C runtime reads its internals; Lua sees
  it as a regular userdata.

### Plan layout

```c
typedef struct pb_plan {
    int n_fields;
    pb_plan_field *fields;        /* sorted by field number for binary search on decode */
    pb_plan_field *fields_by_idx; /* iteration order for encode (proto declaration order) */
    int n_oneofs;
    pb_plan_oneof *oneofs;
    int extension_range_start;    /* proto2 only; 0 if none */
    int extension_range_end;
    int has_override;             /* 1 if desc.encode/desc.decode set */
    int override_encode_ref;      /* luaL_ref slot in REGISTRY */
    int override_decode_ref;      /* luaL_ref slot in REGISTRY */
    int field_names_ref;          /* slot for { [1]=name, [2]=name, ... } table */
    int sub_plans_ref;            /* slot for { [1]=sub_plan_userdata, ... } table */
} pb_plan;

typedef struct pb_plan_field {
    uint32_t field_number;
    uint8_t  wire_type;           /* 0,1,2,5 */
    uint8_t  kind;                /* PB_KIND_INT32 / _STRING / _SUBMSG / _MAP / ... */
    uint8_t  packed;              /* 1 if packed repeated */
    uint8_t  repeated;            /* 1 if repeated (incl. packed) */
    int      tag_bytes_len;       /* pre-encoded tag bytes */
    uint8_t  tag_bytes[5];        /* enough for any field number; tag fits in <= 5 bytes */
    int      sub_plan_idx;        /* index into sub_plans table; -1 for scalars */
    int      map_key_kind;        /* PB_KIND_* for map key; PB_KIND_NONE if not map */
    int      map_value_kind;
    int      map_value_sub_plan_idx;
    int      oneof_idx;           /* index into plan->oneofs; -1 if not in oneof */
    /* No name string stored in the struct — looked up via field_names_ref + index. */
} pb_plan_field;
```

Specifics:

- `tag_bytes` is the pre-encoded `(field_number << 3) | wire_type`
  varint. Same trick `mode=full` uses today; same logic. Up to 5
  bytes because the highest legal field number is 2^29-1.
- Field-name strings are *not* embedded in `pb_plan_field`. They
  live in a Lua table referenced by `field_names_ref` and are
  looked up via `lua_rawgeti(L, LUA_REGISTRYINDEX, ref); lua_rawgeti(L, -1, i+1)`.
  Rationale: `luaL_ref` makes the strings durably reachable
  without per-plan refcounting, and `lua_rawgeti` is faster than
  re-interning a C string via `lua_pushstring` on every call.
  Validated by spike Phase A.
- `sub_plan_idx` indirection (rather than a direct `pb_plan*`
  pointer) lets plans reference each other safely without
  invasive lifetime tracking; the sub-plans table holds strong
  refs to the userdata. GC handles cleanup.

## Field-name caching

The single largest source of per-field overhead in a naive C
codec is repeated `lua_pushstring("field_name")` calls — each does
a hash and intern lookup. We avoid it via the `field_names_ref`
table:

```c
/* At plan compile time, once per field: */
lua_pushstring(L, desc.fields[i].name);
lua_rawseti(L, names_table, i + 1);

/* In encode loop, per field: */
lua_rawgeti(L, LUA_REGISTRYINDEX, plan->field_names_ref);
lua_rawgeti(L, -1, i + 1);              /* pushes name string */
lua_gettable(L, input_table_stack_idx); /* pops name, pushes value */
```

The `lua_rawgeti` pair is two table indexes on already-interned
strings; no hashing of "field_name" required. Spike Phase A
measured this as ~30 ns/field cheaper than per-field
`lua_getfield` with literal C strings.

For very wide messages (>20 fields), the indirection through
`field_names_ref` becomes another lookup. We could specialize
small messages with inline name refs (each `pb_plan_field` carries
its own `name_ref`), but the spike didn't measure a win for that
shape — defer until profiling motivates it.

## Output buffer

Per-call, stack-backed buffer with malloc promotion on overflow.
Pattern validated in `bench/c_accel/person_codec.c`:

```c
typedef struct pb_buf {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    uint8_t  stack[4096];
} pb_buf;

static inline void pb_buf_init(pb_buf *b) {
    b->data = b->stack;
    b->len = 0;
    b->cap = sizeof(b->stack);
}

static inline void pb_buf_reserve(pb_buf *b, size_t extra) {
    if (b->len + extra <= b->cap) return;
    size_t new_cap = b->cap * 2;
    while (new_cap < b->len + extra) new_cap *= 2;
    uint8_t *new_data = malloc(new_cap);
    memcpy(new_data, b->data, b->len);
    if (b->data != b->stack) free(b->data);
    b->data = new_data;
    b->cap = new_cap;
}

static inline void pb_buf_free(pb_buf *b) {
    if (b->data != b->stack) free(b->data);
}
```

- 4 KB stack cap covers most production message sizes without a
  malloc round-trip. The spike measured 0 promotions at 100 B and
  1 KB, ~1 at 10 KB, several at 100 KB — and the 100 KB cost was
  dominated by Lua table reads, not allocator behavior.
- Doubling growth, not arithmetic. The 100 KB encode does at most
  4 promotions (4K → 8K → 16K → 32K → 64K → 128K), each
  amortizable.
- `pb_buf_free` is mandatory in the exit path even on Lua error;
  use a finalizer userdata or a `lua_State*`-attached error
  handler. (Cleanest: allocate the buffer as part of a userdata
  with `__gc`. See implementation note below.)

Why not `luaL_Buffer`? Spike Phase A tested it. `luaL_Buffer`
copies to a Lua-side string buffer at each `luaL_addchar` and
hits the same hash-string-allocation cost on `luaL_pushresult`.
The stack-backed approach measured 18% faster on 1 KB encodes.

### Buffer ownership and error safety

Buffer is allocated inside a userdata with `__gc` set to
`pb_buf_free`. The C entry point creates the userdata, runs the
encode (which may longjmp via `luaL_error`), and on success
constructs the result string via `lua_pushlstring(L, b->data, b->len)`
and returns 1. On longjmp, the userdata's `__gc` runs during stack
unwind and `pb_buf_free` reclaims any malloc'd memory.

## Result tables (decode)

Decode pre-sizes the result table from descriptor stats:

```c
lua_createtable(L, 0, plan->n_fields);
```

This sets the hash part's initial bucket count, avoiding rehashes
as fields populate. Repeated-field arrays are similarly pre-sized
once their length is known (the second pass for packed; for
unpacked we resize geometrically as we go).

The `narr=0` argument matches how the pure-Lua decoder shapes the
table — all named fields land in the hash part. Repeated arrays
live in sub-tables (their `narr` gets sized properly when created).

## Per-field stack discipline

The single most important decision from spike Phase B: **cache
per-field stack indices for the duration of one encode or decode
call.** A naive implementation does:

```c
/* Per field, in the encode loop: */
lua_pushstring(L, field_name);
lua_gettable(L, input_table_idx);
/* ... use top of stack ... */
lua_pop(L, 1);
```

This is correct but pays the lookup cost on every iteration of a
repeated/packed field. The cached version:

```c
/* Once at start of field: */
lua_rawgeti(L, names_table_idx, i + 1);  /* push name */
lua_gettable(L, input_table_idx);        /* pop name, push value table */
int value_stack_idx = lua_gettop(L);

/* Inner loop iterates value_stack_idx without re-fetching: */
for (int j = 1; ; j++) {
    lua_rawgeti(L, value_stack_idx, j);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); break; }
    /* encode element */
    lua_pop(L, 1);
}
```

Spike Phase B measured the naive version 2× slower than the
cached one at 100 KB. The cached pattern is mandatory for
repeated and packed fields. For singular scalars the difference
is negligible (single lookup); use whichever is cleaner.

Reviewers reject any PR that re-introduces the naive pattern for
repeated fields.

## 64-bit cdata

The C side uses Tarantool's `module.h` extensions to push/pull
LuaJIT `int64_t` / `uint64_t` cdata:

```c
#include <module.h>

/* Push as cdata onto the Lua stack: */
luaT_pushint64(L, (int64_t)val);
luaT_pushuint64(L, (uint64_t)val);

/* Read cdata or number from stack: */
int64_t i = luaL_checkint64(L, idx);
uint64_t u = luaL_checkuint64(L, idx);
```

`luaL_checkint64` accepts cdata, Lua number, and digit string (the
same forms `wire.encode_int64` accepts in pure Lua). On overflow
or non-numeric input it raises a Lua error with a Tarantool-style
message; the [compat contract](c_accel_compat.md#errors) treats
this as acceptable.

## Sub-messages

Two approaches were considered: sub-buffer + copy, or
backpatch-after-length.

### Sub-buffer (chosen)

Encode the sub-message into a fresh `pb_buf`, then emit
`tag + length-varint + sub_buf.data[0..sub_buf.len]` into the
parent buffer. The sub-buffer is per-call and uses its own stack
backing.

Pros: simple, no backpatching arithmetic, clean error recovery
(each sub-call allocates and frees its own buffer).

Cons: one extra memcpy per sub-message; an extra ~4 KB on the
C stack per nesting level.

The spike's `person_codec.c` uses this; performance was
indistinguishable from backpatching for typical message shapes
(≤5 levels of nesting). Backpatching wins when the same
sub-message has a very long encoding (>1 KB) and avoiding the
memcpy matters.

### Backpatch (deferred)

Reserve a worst-case length-varint slot in the parent buffer,
encode the sub-message directly into the parent buffer, then go
back and write the actual length. Requires careful handling: the
length varint can be 1, 2, 3, 4, or 5 bytes; either reserve the
max and emit shorter with leading-zero padding (wastes bytes), or
encode then memmove (slow for large sub-messages), or use the
worst-case slot and rewrite the length-varint encode to accept a
fixed-width target.

This is a candidate per-trace optimization for the generic C
runtime if the sub-buffer approach turns out to be a bottleneck
on deeply-nested workloads. Default is sub-buffer.

## Packed repeated fields

Two-pass on encode:

1. First pass: walk the input array, encode each element into a
   dedicated `pb_buf`. Track total length.
2. Second pass: emit `tag + length-varint(total) + buf.data`
   into the parent buffer.

Same pattern the pure-Lua encoder uses (`runtime/pb/codec.lua`'s
`encode_packed`). Validated by spike Phase A as the cleanest
approach.

## Maps

Maps are syntactic sugar over `repeated MapEntry`. The C plan
treats a map field as a `repeated` field with a synthesized
sub-plan for the entry type (two fields: key, value).

Encode walks the Lua table with `lua_next` (the only place we use
`lua_next` / iteration over hash). Each iteration:

1. Encode `MapEntry{key=k, value=v}` into a sub-buffer.
2. Emit `tag + length-varint + sub_buffer` into the parent buffer.

This matches the pure-Lua semantics and the wire format. **Map
iteration order is hash-determined** in both paths and is *not*
guaranteed stable across paths. The compat contract permits this.

## Oneofs

The plan carries a parallel array of `pb_plan_oneof` structs.
Encode walks the oneof groups: for each, find which member is
set (Lua-side check via `getfield` for each member, until one is
non-nil), and encode only that member.

For wide oneofs (many members) this is O(n) per oneof on encode.
A future optimization could cache the active member name on the
input table; for now the spike showed this isn't a bottleneck for
typical schemas.

Decode is simpler: when a oneof-member field is decoded, the
codec clears any previously-set member of the same oneof from
the result table.

## Unknown fields

The C decoder, when it hits a tag whose field number is not in
the plan, copies the raw wire bytes for that field (tag +
payload) into a per-call `pb_buf` for unknown bytes. At the end
of decode, the unknown buffer is stored on the result table as
`_unknown_fields` (a Lua string).

The C encoder, when it sees `t._unknown_fields` is non-nil, appends
those bytes verbatim to the output buffer after the known fields.
Position in the output is the same as pure-Lua (after, not
interleaved).

## What we will not optimize (yet)

Two micro-optimizations that look attractive but the spike showed
don't pay:

- **Inlining varint encode/decode into the dispatch loop.** Already
  inlined by the C compiler at `-O2`. Manual inlining bloated
  source without measurable speedup.
- **SIMD scan for varint terminators on decode.** Validated on
  another protobuf C lib (upb), measurable on huge messages, but
  the spike showed our bottleneck at 100 KB is the per-field Lua
  bridge work, not varint scanning. Revisit when a workload
  surfaces.

## Build environment expectations

- C99, `-O2`, `-Wall -Wextra`.
- Headers required: `module.h` and `lauxlib.h` (`module.h` does
  *not* re-export `lauxlib.h`; both must be included). Verified
  in spike.
- `module.h` resolution mirrors `bench/c_accel/Makefile`: env
  override (`TARANTOOL_INCLUDE`), then brew prefix, then standard
  paths. See [c_accel_build_packaging.md](c_accel_build_packaging.md)
  for the packaging side.

## Testing posture

Per the compat contract, no separate Lua-vs-C diff harness. The
existing `test/` suite runs twice in CI (PB_ENABLE_C unset vs
=1). The C path is exercised through the same generated
modules; bugs surface as test failures in the standard suite.

When debugging a specific C path, two helpful environment
variables (deferred, not implemented yet — file when needed):

- `PB_C_TRACE=1` — log each encode/decode call's descriptor name
  and message size to stderr. For debugging "which call is
  this?" during failures.
- `PB_C_CHECK_PARITY=1` — after every C encode/decode, run the
  pure-Lua path and assert bytes/table equality. Slow; useful
  when a conformance test fails and you want to localize.

## References

- [docs/c-accel.md](../c-accel.md) — architecture
- [docs/specs/c_accel_compat.md](c_accel_compat.md) — compat contract
- `bench/c_accel/spike_bench.lua` — the benchmark
- `bench/c_accel/person_codec.c` — reference S4 codec, the
  patterns here are the patterns there
- `bench/c_accel/generic_codec.c` — reference S3 prototype, what
  the generic C runtime generalizes from
