# Troubleshooting

Errors you might hit and how to fix them. Organized by where they
surface (build, require, encode, decode, runtime).

## Build / codegen

### `protoc-gen-tarantool: program not found or is not executable`

`protoc` couldn't find the plugin on `PATH`. Either:

```bash
# Put the binary on PATH:
export PATH=$PWD:$PATH

# Or invoke protoc with an explicit plugin path:
protoc --plugin=protoc-gen-tarantool=./protoc-gen-tarantool ...
```

### `imported "tarantool/tarantool.proto" but couldn't find it`

You're using `option (tarantool.lua_package) = ...` but `protoc`
doesn't see the option definition file. Add an `-I` for the
`options/` directory of this repo:

```bash
protoc -I. -Ioptions --tarantool_out=... ...
```

If you've vendored the repo elsewhere, point to its `options/`
subdirectory.

## Require / load

### `module 'pb' not found`

`LUA_PATH` is missing the `runtime/` directory. The two patterns you
need:

```bash
LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;...;;"
```

- `./runtime/?/init.lua` resolves `require('pb')` to
  `runtime/pb/init.lua`.
- `./runtime/?.lua` resolves `require('pb.wire')` to
  `runtime/pb/wire.lua` (and the other sibling modules).

### `module 'app.foo_pb' not found`

Generated module isn't on `LUA_PATH`. Add the generated-output
directory:

```bash
LUA_PATH="...;./gen/?.lua;./gen/?/init.lua;...;;"
```

Include both patterns — `gen/?.lua` for top-level (`gen/foo_pb.lua`)
and `gen/?/init.lua` for nested layouts.

### `attempt to call nil` on a WKT field

The generated code references `pb.wkt.<Name>_*` for WKT fields. If
the `pb` module hasn't loaded, the reference resolves to nil and the
call fails. Make sure `require('pb')` happens before (or as part of)
the generated module load — generated `_pb.lua` does this at the top
(`local pb = require('pb')`), so this only surfaces when something
has overridden `package.loaded.pb` or replaced the runtime.

### Tarantool's built-in `protobuf` vs this project's `pb`

If your code does `require('protobuf')` and gets the encode-only
built-in's API, that's because the project module is named `pb`,
not `protobuf`. They're deliberately different to coexist; see
[how-to: migrate from builtin](howto/11-migrate-from-builtin.md).

## Encode

### `expected cdata int64_t, got number`

You passed a Lua number to a 64-bit-typed field (`int64`, `uint64`,
`sint64`, `fixed64`, `sfixed64`). The codec requires cdata for
those — Lua numbers lose precision past 2^53.

```lua
local pb = require('pb')
hello.Person_encode({user_id = pb.to_uint64(42)})
-- or
hello.Person_encode({user_id = require('ffi').cast('uint64_t', 42)})
```

`pb.to_uint64` / `pb.to_int64` accept Lua numbers, cdata, or numeric
strings — use them at any boundary (JSON parsing, user input,
net.box arguments) where the input might not already be cdata.

### `expected table for hello.Foo, got string`

You passed wire bytes to `Foo_encode` instead of a Lua table.
`Foo_encode(t) -> bytes`, `Foo_decode(bytes) -> t`. Easy to swap.

### `invalid UTF-8 in string field`

Proto3 `string` fields require valid UTF-8 (the spec). Use `bytes`
for arbitrary binary, or sanitize/encode the input before assigning
to a `string` field.

### Map encode order differs from mainline `protoc`

Lua's `pairs()` iteration order over a hash table isn't stable
across Lua versions — it differs from mainline `protoc`'s
text-proto-order output. **Two-key+ maps are byte-equal *by
coincidence*** when the hash happens to iterate in the right order.

Test impact: use single-key map fixtures for byte-for-byte interop
assertions; cover multi-key behavior with decode-then-compare-table
assertions where iteration order doesn't matter. The existing
`person_map` fixture in `test/interop/fixtures/` follows this rule.

## Decode

### `truncated input` / `unexpected end of input`

The wire bytes are short — either the producer cut off mid-message or
your `bytes` variable doesn't hold what you think it holds. Check the
length first; mainline-protoc messages start with field-tag bytes,
not a length prefix.

If you're reading from a length-delimited stream (gRPC frame, custom
framing), strip the framing before decoding.

### `unknown wire type N`

The bytes aren't proto3 wire format — likely you're decoding JSON,
msgpack, or some other format against a proto descriptor. The four
valid wire types are 0 (varint), 1 (i64), 2 (LEN), 5 (i32); 3 and 4
(SGROUP/EGROUP) are proto2-only and tolerated on the skip path.

### `enum value N out of range`

Decoded enum value isn't in the descriptor. Proto3 enums are *open* —
unknown values pass through as their integer form. The decoder
doesn't raise on unknown values; if you're seeing this error, it's
likely from a strict consumer (JSON decode in strict mode, custom
validator) rather than the wire-level decoder.

## Lazy view

### `view:get('field_name')` returns nil when the field IS set

Field-name typo, or you passed a literal string instead of the
strict constants table:

```lua
-- Right
local F = hello.Person_fields
view:get(F.user_id)

-- Wrong
view:get('user_id')        -- works
view:get('user_di')        -- silently nil (typo!)

-- F.user_di errors at the call site:
-- "unknown field name: 'user_di'"
```

See [api-modes.md → field-name constants](api-modes.md#field-name-constants--required)
for the reasoning.

### `MessageView holds a reference to the input bytes`

Lazy views don't copy the wire bytes — they index into them. If you
mutate the underlying string or let it get GC'd, the view's reads
are undefined.

In practice strings are immutable in Lua, so the only way to hit this
is to drop the *only* reference to the string while the view is
still in use. Keep the bytes around as long as the view is.

## gRPC

### Stream `:send` raises `pb.grpc: stream canceled`

The peer (or this side) called `:cancel()`. Treat as end-of-stream;
the call is over.

### Stream `:send` raises `pb.grpc: send after close_send`

You called `:send` after `:close_send` on the same stream. Once
close_send fires, no more outgoing messages.

### `unknown unary method "/pkg.Service/Method"`

The path isn't in the server's `methods` map. Check that:

- The service / method name matches between client and server
  generated code.
- For `pb.grpc.multiplex`, every server was passed.
- The path uses the `/pkg.Service/Method` form, not just
  `Method` or `Service.Method`.

### Loopback hangs on a streaming call

Single-fiber bidi can self-deadlock — if your send buffer fills
faster than the server pulls, `:send` blocks on the channel, and the
server fiber can't drain because the main fiber owns the runtime.
Split sends to a separate fiber, or interleave send/recv in lockstep.
See [how-to: gRPC loopback → bidi from a single fiber](howto/03-grpc-loopback.md#bidi-from-a-single-fiber).

## Performance

### `pairs()` warning from `bench/jit_trace.lua`

The hot encode/decode paths must use `ipairs` / `for i=1,#t do`, not
`pairs`. `pairs()` over a hash compiles to bytecode `ISNEXT`, which
is NYI in Tarantool's LuaJIT 2.1 fork — the trace aborts. Map fields
are the one allowed exception; the gate pins the limitation.

See [codegen.md → hot-path rules](codegen.md#the-hot-path-rules-the-generated-code-observes).

### Encode is much slower than the bench reports

Two common causes:

1. **Tarantool starts with `jit.off`** by default in some contexts.
   Confirm: `print(jit.status())` should print `true ...`. If false,
   `jit.on()` enables it.
2. **JIT mcode disabled on macOS arm64.** `luatest` blocks JIT mcode
   on that platform; benchmarks should run via `just bench`, not via
   `luatest`. Tests of perf characteristics live in `bench/`, not
   `test/`.

## Other

### Worktree-based dev: `.rocks` is missing

After `git worktree add`, the new worktree doesn't share `.rocks/`
with the main checkout. Symlink it:

```bash
ln -s ../path/to/main/.rocks .rocks
```

Otherwise `just test` can't find `luatest`.

### Need to log a 64-bit cdata as a string

`tostring(cdata_uint64)` gives `12345ULL` (LuaJIT formatting).
For clean output, use `tostring():gsub('ULL$', '')` or print the
numeric form via `tonumber()` (with the usual 2^53 precision
caveat — use only for display, not for math).

### Where do generated modules log from?

They don't. The codegen produces no `log.*` calls; if you see logs,
they came from your app or from `pb`'s runtime modules (none of
which log on the happy path). Error conditions surface as `error()`,
not log lines.
