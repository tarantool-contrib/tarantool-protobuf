# Spec: C-acceleration compatibility contract

Status: **contract locked, implementation pending**. This spec
formalizes the compatibility boundaries that the C-acceleration work
([`docs/c-accel.md`](../c-accel.md)) must preserve. It is the
reference that the plan compiler, the generic C runtime, the
deferred codegen-C backend, and the parity gate consume to decide
what is — and isn't — allowed to change.

## Principle

The C path is an **opt-in performance enhancement**, not a new mode.
Every Lua-visible behavior must be byte-equal between `PB_ENABLE_C`
unset and `PB_ENABLE_C=1`. A user who never sets the variable should
never observe any difference — including memory layout of returned
values, error messages, error types, iteration order of returned
tables, or the structure of generated `_pb.lua` modules.

If a C-path optimization conflicts with this principle, the C path
loses. There are no exceptions and no per-feature carve-outs.

## Activation

Exactly one switch: the environment variable `PB_ENABLE_C`.

- Read once at module load (`runtime/pb/init.lua`), via
  `os.getenv('PB_ENABLE_C')`. Value `'1'` enables; anything else
  (including unset, `'0'`, `'true'`, `''`) leaves the C path off.
- No Lua-side toggle (`pb.use_c_runtime = true` is **not** part of
  the surface). No per-call override. No per-message override. The
  knob is out-of-band by design — keeping it out of Lua makes
  accidental activation impossible and prevents the C path from
  becoming a feature with its own API surface.
- When `PB_ENABLE_C=1` but `require('pb.c_runtime')` fails (no `.so`
  built, ABI mismatch, etc.), `runtime/pb/init.lua` falls back to
  the pure-Lua path **silently**. No warning, no error. A failed
  `pcall` is indistinguishable from `PB_ENABLE_C` unset for every
  downstream observer. Rationale: a noisy fallback turns a missing
  build artifact into a runtime error for users who didn't ask for
  C anyway (rockspec installed without compiler available).

## Public Lua surface — preserved

The following modules and their public functions must keep their
exact signatures, argument types, return types, and error behavior
in both paths:

### `runtime/pb/init.lua` (the `pb` module)

| Function | Behavior | Test coverage |
|----------|----------|---------------|
| `pb.encode(desc, t)` → string | Same bytes. | `test/interop/*`, `test/parity_full_vs_runtime_test.lua` |
| `pb.decode(desc, bytes)` → table | Same table shape. Same iteration order is **not** guaranteed in either path (Lua hash order), but tests must remain green. | `test/interop/*` |
| `pb.decode_lazy(desc, bytes)` → MessageView | Returns the same `MessageView` API. See [Lazy view](#lazy-view-pbdecode_lazy). | `test/lazy_test.lua` |
| `pb.parse(src)` → descriptor module | Pure Lua, parser stays in Lua. **Not affected by C path.** | `test/dynamic_test.lua` |
| `pb.from_pb(bytes)` → descriptor module | Same. | `test/fileset_test.lua` |
| `pb.json.encode` / `pb.json.decode` | Same JSON output. The JSON codec composes on top of the encoder/decoder, so it picks up C automatically without code change. | `test/json_test.lua` |
| `pb.text.encode` / `pb.text.decode` | Same as JSON. | `test/text_test.lua` |
| `pb.grpc.loopback` / `multiplex` | gRPC transports treat encoded bytes as opaque; not affected. | `test/grpc_test.lua` |
| `pb.finalize_message(desc)` | Existing call site; gains side effect of compiling the C plan when `PB_ENABLE_C=1`. Return value unchanged (`nil`). Idempotent. | implicit (used by all generated modules) |

Generated modules (`mode=full` and `mode=runtime`):

| Symbol | Behavior |
|--------|----------|
| `M.<Type>_encode(t)` → string | Same bytes. Wrapper checks `desc.c_plan`; if present, calls `pb.c_runtime.encode(desc.c_plan, t)`. Otherwise runs existing pure-Lua body. |
| `M.<Type>_decode(b)` → table | Same. Mirrors encode wrapper. |
| `M.<Type>_descriptor` | Unchanged shape. Gains optional `c_plan` field at finalize time (opaque userdata). |
| `M.<Type>_fields` / `M.<Type>_oneofs` | Strict-table wrappers used by lazy view; unchanged. |
| `M.<Service>_service` / `M.<Service>_client` / `M.<Service>_server` | gRPC factories; unchanged. |

### What the C plan **may not** change

- The on-disk format of `examples/expected/{full,runtime}/*_pb.lua`.
  Files in version control must stay byte-equal across this work.
  C-plan compilation happens at module load, in memory, from
  descriptor tables — no codegen-time change.
- The structure of `desc` tables documented in
  [docs/codegen.md](../codegen.md#the-descriptor-table--the-contract).
  Plan compilation reads `desc`; it does not mutate it except for
  attaching the opaque `c_plan` userdata.
- Generated module return value (`return M`). No new exports.

## 64-bit integers

`int64`, `uint64`, `sint64`, `fixed64`, `sfixed64` are LuaJIT
`int64_t` / `uint64_t` cdata in **both** paths.

- Encode accepts `cdata`, Lua number (within ±2^53), or string of
  digits (existing behavior in `pb.codec`). The C path must accept
  all three.
- Decode always returns `cdata`. The pure-Lua decoder already
  returns cdata; the C decoder must use
  `luaT_pushint64` / `luaT_pushuint64` (Tarantool's `module.h`
  extensions) so the value lands on the Lua stack as cdata, not as
  a Lua number.
- `tostring` of a returned 64-bit value must produce the same
  string in both paths. (Lua's default `cdata` `__tostring` already
  guarantees this.)

This rule is **load-bearing for downstream users.** msgpackffi,
net.box, box.tuple, IProto all consume cdata. Narrowing to double
silently corrupts IDs and timestamp nanos past 2^53. The pure-Lua
path holds this line today, and the C path must hold it tomorrow.

## WKT shapes

`google.protobuf.*` types keep their hand-rolled shapes
(`runtime/pb/wkt.lua`):

- `Timestamp` / `Duration` accept and return a `datetime` cdata,
  with `{seconds=, nanos=}` table accepted on encode for ergonomics.
- `Empty` is `box.NULL`.
- Wrappers (`Int32Value`, `StringValue`, …) accept and return the
  wrapped scalar directly.
- `Any`, `Struct`, `Value`, `ListValue` keep their existing
  representations.

Mechanism: WKT descriptors carry `desc.encode` / `desc.decode`
function fields. The C plan, when finalizing a descriptor, must
detect those overrides and arrange to call the Lua functions for
that descriptor's encode/decode instead of walking fields in C.
This is the same composition point that lets WKT plug into the
pure-Lua codec today (`runtime/pb/codec.lua` short-circuits on
`desc.encode` / `desc.decode`).

## Unknown fields

The pure-Lua decoder preserves unknown fields in
`t._unknown_fields` (a string of raw wire bytes), and the encoder
appends them after the known fields. The C path must round-trip
identically:

- Decode of a message with unknown wire bytes returns a table
  whose `_unknown_fields` is the same byte string the pure-Lua
  decoder would produce.
- Encode of a table with `_unknown_fields` set appends those bytes
  verbatim after known-field output.

Conformance gates this — every
`Required.Proto3.ProtobufInput.ValidDataUnknown.*` test exercises
this round-trip. The C path runs the same conformance suite, so
regressions surface immediately.

## Extensions (proto2)

Extension representation in tables: `t[<ext_name>]` where
`<ext_name>` is the fully-qualified extension field name. Same
in both paths.

Extension range handling on decode: unknown extension numbers
fall through to `_unknown_fields` (above). Known extension numbers
populate `t[<ext_name>]`.

## Lazy view (`pb.decode_lazy`)

The lazy view is **out of scope for C acceleration in the initial
ship of the generic C runtime.** `pb.decode_lazy` continues to use
the pure-Lua path in `runtime/pb/lazy.lua` regardless of
`PB_ENABLE_C`.

Rationale: the lazy view's value is *not* doing a full decode. Its
hot operations are `MessageView:get(name)` and `:has(name)`, which
do a single field scan over the wire bytes — already O(field_pos)
in pure Lua, not the per-message dispatch cost C-accel targets.
Adding a C entry point per `:get` call would re-introduce the
boundary cost the architecture sketches were trying to avoid.

Future work (deferred, not yet scoped): a `lazy_c` variant could
provide a single C entry point for `:get_many({names})` if a
workload surfaces. Until then, the lazy view stays Lua-only.

The lazy view's **public API** is unchanged either way —
`:get(name)`, `:has(name)`, `:which(oneof)`, `:set`, `:clear`,
`:iter`, `:names`, `:to_table`, plus `ArrayView` and `MapView`
methods. Users observe no difference.

## Errors

The C path raises Lua errors via `luaL_error`, producing the same
shape as `error(string)` in pure Lua. Specifically:

- Type mismatches (wrong field type in input table) → string error
  with the same template as `runtime/pb/codec.lua` ("field X
  expected Y, got Z" or close).
- Wire-format errors on decode → string error matching the
  pure-Lua message for the same input.
- 64-bit cdata required but Lua number out of range → same
  message as `wire.encode_int64` raises today.

This is **expected-output compatibility**, not source-text
compatibility. The exact prose of error messages may shift
slightly between paths as the generic C runtime is implemented;
the contract is that error *type* (Lua error vs. silent return)
and approximate message content (mentions the field name and the
type involved) must match. Tests that pattern-match on error
strings should use `string.find` with anchor patterns, not
full-string equality.

## Installation paths

Two paths to install:

### Pure-Lua install (no compiler)

```
tt rocks install tarantool-protobuf
```

- Rockspec's optional C build skips when no `cc` available.
- Install succeeds. Only Lua files land.
- `pb.encode` / `pb.decode` work; `pb.c_runtime` is absent.
- Setting `PB_ENABLE_C=1` is silently ignored.
- This is the **default install path** for everyone who doesn't
  ask for C.

### C-enabled install

```
tt rocks install tarantool-protobuf
PB_ENABLE_C=1 tarantool app.lua
```

- Same rockspec, same `tt rocks install` command. The rockspec
  detects `cc` and builds `pb/c_runtime.so` (or `.dylib` on
  macOS). The same install command produces a C-enabled install
  when a compiler is present.
- User sets `PB_ENABLE_C=1` to activate.

## ABI and version skew

The C module's exposed symbols (essentially `pb.c_runtime.encode`
and `pb.c_runtime.decode`, plus the plan-compilation entry point)
are versioned via a single `pb.c_runtime._abi_version` integer
string. `runtime/pb/init.lua` checks it on load and treats a
mismatch as a load failure (same fallback as missing module).

The plan userdata is **not** ABI. It's process-local, opaque, and
recompiled at every module load. Cross-process plan sharing is
out of scope (and would also require `desc` to be serializable,
which it isn't today). See
[c_accel_build_packaging.md](c_accel_build_packaging.md) for the
packaging discussion.

## Conformance and parity

No new Lua-vs-C diff harness. The existing test infrastructure
asserts against reference outputs (golden byte strings, txtpb
fixtures, conformance results). When both paths run the same
suite and both pass, byte equality is implied by transitivity.

CI matrix runs the full suite twice — `PB_ENABLE_C` unset and
`PB_ENABLE_C=1`. Both must pass for every merge to master.

## What changes

To be unambiguous about what this work *does* alter:

- `runtime/pb/init.lua` gains a load-time `pcall(require, 'pb.c_runtime')`
  guarded on `PB_ENABLE_C=1`. (~5 lines.)
- `pb.finalize_message(desc)` gains a load-time compile step that
  attaches `desc.c_plan` when the C runtime is loaded. (~5 lines
  in the existing finalize function; the actual compile lives in
  `pb.c_runtime`.)
- Each generated `M.<Type>_encode` / `M.<Type>_decode` wrapper
  gains a one-line dispatch check. The pure-Lua body underneath
  is untouched.
- New file `runtime/pb/c_runtime.c` (or split across several files
  under `runtime/pb/c/`) — the actual C implementation.
- New file `runtime/pb/c_runtime.lua` — a thin Lua wrapper around
  the C module that performs ABI check and exposes plan
  compilation and encode/decode functions. Could also be inlined
  into the C module itself; deferred to the plan-compiler and
  generic-C-runtime work.
- Justfile gains `build-c` recipe.
- Rockspec gains optional C build hook.
- CI gains a `PB_ENABLE_C=1` job.

That's the complete delta. Nothing else in the runtime tree,
nothing in the codegen tree, nothing in `examples/expected/`,
nothing in `test/`.

## Out of scope

- Replacing the pure-Lua path. `mode=full` and `mode=runtime`
  remain the default forever.
- C-acceleration for `pb.decode_lazy` (see above).
- C-acceleration for `pb.parse` (Lua parser, not on hot path).
- C-acceleration for JSON / text codecs beyond what they
  inherit by composing on top of `pb.encode` / `pb.decode`.
- Per-call activation, per-message activation, runtime toggle.
- Cross-process plan caching.

## References

- [docs/c-accel.md](../c-accel.md) — architecture
- [docs/specs/c_accel_strategy.md](c_accel_strategy.md) — C-level design
- [docs/codegen.md](../codegen.md#the-descriptor-table--the-contract) — descriptor contract
- [docs/specs/c_accel_build_packaging.md](c_accel_build_packaging.md) — build, packaging, and CI
