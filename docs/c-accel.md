# C acceleration — architecture

This document records the architecture chosen for the C-accelerated
encode/decode path.

## Background

The pure-Lua runtime is competitive at small payload sizes but
hits a per-byte cliff on decode for messages above ~1 KB (see
[bench/PERF_LOG.md](../bench/PERF_LOG.md)). Profiling attributed the
cost to per-field Lua dispatch and table/string work, not the wire
format itself. Crossing into C *once per top-level message* lets C
own the inner loop and amortizes any boundary cost.

## The spike result

`bench/c_accel/` measured four boundary placements across 10 B –
100 KB on `hello.Person`. Summary speedup vs pure-Lua full mode
(full numbers in [bench/c_accel/README.md](../bench/c_accel/README.md)):

|        | 10 B | 100 B | 1 KB | 10 KB | 100 KB |
|--------|------|-------|------|-------|--------|
| S2 enc | 0.99 | 0.93  | 0.82 | 0.60  | 0.63   |
| S2 dec | 0.29 | 0.33  | 0.39 | 0.38  | 0.37   |
| S3 enc | 3.29 | 3.12  | 5.33 | 3.53  | 3.49   |
| S3 dec | 2.59 | 2.94  | 7.22 | 9.64  | 10.87  |
| S4 enc | 3.79 | 3.46  | 4.94 | 2.86  | 2.85   |
| S4 dec | 2.54 | 2.95  | 7.62 | 10.23 | 11.33  |

- **S2 (per-primitive FFI)**: loses to pure Lua at every size ≥ 1 KB
  on encode and at *every* size on decode. The `ffi.load`-library
  call cost (~60–75 ns) is the same order of magnitude as a
  pure-Lua varint decode (~75 ns), so swapping doesn't save
  anything; it just moves dispatch from bytecode to FFI.
  `ffi.cast` on Lua strings is an additional ~156 ns per decode.
- **S3 (one generic C call per message, descriptor-walking)** lands
  within ±15% of S4 (hand-written) and beats it at scale on
  encode.
- **S4 (codegen-emitted C per message)** has ≤15% headroom over S3
  and goes the wrong way for large messages, where its more
  divergent per-field paths cost branch predictability.

## Decision

1. **Ship S3.** Implement a generic C runtime (`pb.c_runtime`) that
   walks compiled descriptor plans at the C level and crosses the
   Lua↔C boundary exactly once per top-level encode or decode.
2. **Drop S2 entirely.** Per-primitive FFI is structurally worse
   than pure Lua and is not a viable architecture.
3. **Defer S4 (codegen-emitted C).** ≤15% headroom doesn't earn
   the codegen + maintenance + distribution complexity. Revival
   criteria below.

## User-facing contract

The C path is **disabled by default**. Existing installs get zero
behavior change.

- `require('pb')` returns the same Lua module table as today.
- The C runtime is loaded only when `PB_ENABLE_C=1` is set in the
  environment at module load time.
- When enabled, `pb.encode` / `pb.decode` and generated
  `M.<Type>_encode` / `M.<Type>_decode` dispatch into C. When the C
  module is absent or `PB_ENABLE_C` is unset, the pure-Lua path
  runs unchanged.
- No Lua-level toggle (no `pb.use_c_runtime = true`). The single
  knob is the env var, evaluated once at module load. Keeping the
  switch out-of-band prevents accidental API surface and keeps
  inadvertent activation impossible.
- 64-bit integers stay LuaJIT `int64_t` / `uint64_t` cdata in both
  modes. WKT shapes stay identical. Unknown fields keep
  round-tripping. Errors land as the same Lua error types.

The C path must be byte-equal to the Lua path on every encoded
output and decode result — see "Parity verification" below.

## Architecture sketch

### Descriptor compilation

When `pb.finalize_message(desc)` is called and `PB_ENABLE_C=1`,
the descriptor is compiled into a C-side **plan userdata**
allocated once and stashed on `desc.c_plan`. The plan carries:

- Per-field records (field number, wire type, kind tag, presence
  tracking offset, default-value index)
- Pre-encoded tag bytes (the same trick `mode=full` uses today)
- `luaL_ref` slots for cached field-name strings (so each
  `lua_setfield` call avoids re-interning)
- Sub-descriptor pointers for nested messages and map entries
- Oneof grouping metadata (parallel array, matches the
  `desc.oneofs_list` pattern from `runtime/pb/codec.lua`)
- Extension range hooks for proto2
- WKT override pointers — if `desc.encode` / `desc.decode` are
  set, the plan calls them instead of walking fields.

The plan is *not* serialized or shared between processes. It is
rebuilt at module load time from the descriptor tables that
`runtime/pb/{dynamic,fileset,wkt}.lua` and the generated `_pb.lua`
already produce. No new descriptor source, no protocol change.

### Encode

One C entry point per message type:

```c
int Person_encode_c(lua_State *L);  /* arg1 = table, returns string */
```

Generated Lua wrappers (in `mode=full` and `mode=runtime`) check
`desc.c_plan` and call the C function when present:

```lua
function M.Person_encode(t)
    if desc.c_plan then return pb.c_runtime.encode(desc.c_plan, t) end
    -- existing pure-Lua body
end
```

C-side encode loop walks the plan, reads each field via
`lua_getfield` with cached refs, dispatches on `kind` (scalar,
string, packed scalar, repeated string, sub-message, repeated
sub-message, map, oneof, group, extension), and writes into a
4 KB stack-backed buffer that promotes to malloc on overflow
(the pattern validated in `bench/c_accel/person_codec.c`).

Sub-messages use a separate sub-buffer (or backpatching — see
[c_accel_strategy.md → Sub-messages](specs/c_accel_strategy.md#sub-messages)
for the trade-off); packed and repeated use cached per-field
stack indices for the duration of the call — the spike showed
that the naive lazy-getfield pattern is 2× slower than the cached
one at 100 KB.

### Decode

Same shape, mirrored. One C entry point, descriptor-walk in C,
pre-sized result table via `lua_createtable(0, n_fields)`,
per-field repeated-array stack indices cached for the duration
of the call.

### WKT and the override hook

WKT types (`google.protobuf.Timestamp` etc.) keep their hand-
rolled `desc.encode` / `desc.decode` functions. When the C plan
sees those set, it passes the field bytes straight to them. No
WKT changes; the same composition mechanism that makes WKT plug
in today.

This is also the extension point if codegen-emitted C is ever
revived: emit a `Foo_encode_c` / `Foo_decode_c` per opted-in
message, register as `desc.encode` / `desc.decode`, done. Same
mechanism, narrower scope.

## Parity verification

No separate Lua-vs-C diff harness. Instead, every existing test
suite runs in CI **twice**: once with `PB_ENABLE_C` unset (pure
Lua, today's baseline) and once with `PB_ENABLE_C=1`. Both must
pass. Suites in scope:

- `just test` (luatest groups, ~639 tests, both modes already)
- `just conformance` (Google's proto3 + proto2 conformance, all
  paths)
- Interop fixtures (`test/interop/fixtures/*.txtpb` + `.bin`)

This works because every test asserts against a reference output
(golden byte string, txtpb fixture, conformance result), so Lua
== reference and C == reference implies Lua == C by transitivity.
No new test infrastructure required.

The CI configuration gains one extra job invoking the same recipes
with `PB_ENABLE_C=1`.

## Build and packaging

- `just build-c` — compile the C module into the project tree
  (mirrors the `bench/c_accel/Makefile` pattern; auto-detects
  Tarantool's include directory, supports macOS bundles + Linux
  shared objects).
- Rockspec optionally builds the C module when a C compiler is
  detected; the install never fails on a host without a
  compiler.
- `runtime/pb/init.lua` does `pcall(require, 'pb.c_runtime')` at
  load time, conditional on `os.getenv('PB_ENABLE_C') == '1'`.
- CI builds the C module on every supported platform; CI also
  runs one job with the C module *absent* to confirm the pure-Lua
  install works without a compiler.

## When codegen-emitted C gets revived

Trigger: a measured real-workload shape where the generic C
runtime's per-field descriptor dispatch costs ≥25% over
hand-written for that shape, demonstrated with a microbenchmark,
*and* the affected workload is on a hot path for a real user.
Shapes most likely to surface this:

- Wide messages with dozens of `optional` fields (more
  presence-tracking dispatch per call)
- Heavy oneof use where the C plan has to maintain a "which-one"
  state per oneof group
- Maps with non-trivial value types
- Deeply nested message hierarchies (5+ levels) where the
  recursive descriptor walk traverses many plan tables

When the trigger fires, write 2–3 paragraphs documenting the
shape and numbers, reopen this work, and scope it narrowly:

- Plugin emits a `Foo_encode_c` / `Foo_decode_c` for the
  specific opted-in messages
- Registered as `desc.encode` / `desc.decode` overrides; same
  mechanism as WKT
- No new "mode" flag, no fork of the codegen path

If 6 months pass after the generic C runtime ships and no such
trigger fires, consider codegen-emitted C "not justified."

## Out of scope

- Per-primitive FFI (`S2`) — spike showed it's structurally worse
  than pure Lua. Not pursued.
- Replacing the pure-Lua path. `mode=full` and `mode=runtime`
  remain the default for everyone who doesn't set `PB_ENABLE_C=1`.
- Cross-process plan caching. Plans are per-process, rebuilt at
  module load from descriptors that already live in memory.
- Vinyl or fiber-aware encoder buffers; orthogonal, separately
  scoped.

## References

- Spike code and full results: [bench/c_accel/](../bench/c_accel/)
- [specs/c_accel_strategy.md](specs/c_accel_strategy.md) — the
  C-side implementation strategy
- [specs/c_accel_compat.md](specs/c_accel_compat.md) — the
  Lua/C parity contract
- [specs/c_accel_build_packaging.md](specs/c_accel_build_packaging.md)
  — build, packaging, and CI
