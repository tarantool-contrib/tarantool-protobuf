# Spec: C-acceleration build and packaging

Status: **scaffolding landed, C module pending**. This spec records
how the C-accelerated runtime is built, installed, and exercised in
CI. The opt-in hook in `runtime/pb/init.lua`, the `just build-c`
recipe, and the CI configuration land alongside this doc; the
actual C source they refer to arrives with the generic C runtime
work.

## Where the C module lives

```
runtime/pb/
├── c/                       (NEW — C runtime sources)
│   ├── Makefile             (mirrors bench/c_accel/Makefile)
│   ├── c_runtime.c          (entry points + plan struct)
│   ├── plan.c               (descriptor -> plan compiler)
│   ├── encode.c
│   ├── decode.c
│   ├── buf.c                (4 KB stack-backed buffer)
│   ├── wkt.c                (override dispatch)
│   └── ...
├── c_runtime.so             (built output — gitignored)
├── c_runtime.dylib          (macOS build output — gitignored)
├── init.lua
├── codec.lua
└── ...
```

The build output sits alongside the Lua files at `runtime/pb/c_runtime.{so,dylib}`
so `require('pb.c_runtime')` resolves it via Lua's package.cpath once
the test runner adds `./runtime/?.so` to LUA_CPATH (see [Test runner](#test-runner-changes)).

## Build entry points

### `just build-c`

```
$ just build-c
make -C runtime/pb/c
cc -O2 -fPIC -Wall -Wextra -std=c99 -I/usr/include/tarantool ... \
    -o runtime/pb/c_runtime.dylib runtime/pb/c/c_runtime.c ...
```

Mirrors `bench/c_accel/Makefile`: same `TT_INC` auto-detection (env
override, brew prefix, common system dirs), same `-fPIC -O2`, same
platform-aware extension (`.dylib` bundle on macOS, `.so` on Linux).

The recipe is a stub today — it runs `make -C runtime/pb/c` and
errors out cleanly with "no C runtime source yet" until the plan
compiler lands the first source files.

### `just clean-c`

Removes `runtime/pb/c_runtime.so` and `runtime/pb/c_runtime.dylib`.
Folded into `just clean`.

### `just build` and `just test`

Unchanged. Building the C module is **not** part of the default
flow. Users who care about C must invoke `just build-c` explicitly.

This keeps the default contributor experience identical for anyone
not working on the C path — `just test` continues to work without
a C compiler.

## Activation

The single switch is the environment variable `PB_ENABLE_C`. See
[c_accel_compat.md § Activation](c_accel_compat.md#activation) for
the full contract.

`runtime/pb/init.lua` does:

```lua
local c_runtime
if os.getenv('PB_ENABLE_C') == '1' then
    local ok, mod = pcall(require, 'pb.c_runtime')
    if ok then c_runtime = mod end
end
```

When `c_runtime` is non-nil, `pb.finalize_message(desc)` calls into
it to compile a `desc.c_plan` userdata. When `c_runtime` is nil,
nothing changes — the pure-Lua path runs unchanged.

This hook is **wired today**; the finalize-time compile call is
deferred until the plan compiler lands.

## Test runner changes

The Justfile's `lua_path` constant covers Lua module resolution.
For the C module, the test recipe also sets `LUA_CPATH`:

```just
lua_cpath := "./runtime/?.so;./runtime/?.dylib;./runtime/?/init.so;;"

test: gen
    LUA_PATH="{{lua_path}}" LUA_CPATH="{{lua_cpath}}" {{luatest}} -v test/
```

This is added alongside the C build scaffolding. With
`runtime/pb/c_runtime.so` built, `require('pb.c_runtime')` resolves
to that path.

`tt rocks install` puts compiled modules under `.rocks/lib/tarantool/`,
which is already on the default cpath; these changes only affect
the local dev workflow, not installed rocks.

## Rockspec

The current rockspec uses `build.type = "builtin"` which copies Lua
files only. To optionally build the C module, the rockspec gains:

```lua
external_dependencies = {
    TARANTOOL = { header = "module.h" },
}

build = {
    type = "builtin",
    modules = {
        ["pb"]               = "runtime/pb/init.lua",
        -- ... existing Lua modules ...
        -- The C module is listed as a buildable source:
        ["pb.c_runtime"] = {
            sources = {
                "runtime/pb/c/c_runtime.c",
                "runtime/pb/c/plan.c",
                "runtime/pb/c/encode.c",
                "runtime/pb/c/decode.c",
            },
            incdirs = { "$(TARANTOOL_INCDIR)" },
        },
    },
}
```

Behavior:

- `tt rocks install` (or `luarocks install`) detects the C compiler
  and `module.h` via `external_dependencies`. If both are present,
  the C module compiles. If `module.h` is missing (older Tarantool,
  no `-dev` package), the install **fails** because the rockspec
  declares it as a hard dependency.
- To make the C build truly optional (install succeeds on hosts
  without `module.h`), we'd need to use `luarocks`-specific
  `build.platforms` or two separate rockspec variants. Deferred:
  for now, if the user installs and doesn't have `tarantool-dev`,
  installation fails with a clear error message — acceptable
  because every supported Tarantool environment ships `module.h`.

The rockspec change lands when the first C sources exist. The
current scaffolding leaves the rockspec at "builtin Lua only" for
now and documents the change here.

## CI

CI runs the test suite twice:

- **Pure Lua** — full test suite with `PB_ENABLE_C` unset. Validates
  the pure-Lua path and the silent-fallback case (env var unset
  means C is dormant even when present).
- **C-enabled** — same test suite plus `just build-c` and
  `PB_ENABLE_C=1`. Validates the C path end-to-end.

Conformance (`just conformance` / `just conformance-c`, both run
inside the Docker harness — see [docs/c-accel.md](../c-accel.md)
and the top-level `README.md`) is kept off the every-push
fast-feedback path as a deliberate cost-control choice — the suite
pulls a multi-GB Docker image and runs ~7000 tests. Run it before a
release or after wire-format changes.

## Platform support

The `bench/c_accel/Makefile` patterns we mirror in `runtime/pb/c/Makefile`:

- **Linux x86_64 / aarch64** — `-shared`, output is `.so`.
- **macOS arm64 / x86_64** — `-bundle -undefined dynamic_lookup`,
  output is `.dylib`. The `dynamic_lookup` flag is what lets the
  module use `lua_*` symbols without linking against a specific
  Lua/Tarantool binary.
- **Windows / WSL / FreeBSD** — out of scope for the initial ship.
  Tarantool's primary deployment targets are Linux servers and
  macOS dev hosts; FreeBSD ports exist but aren't on the CI
  matrix.

## What ships today

- `runtime/pb/init.lua` — `PB_ENABLE_C` pcall hook (lines added at
  module load; exposes `c_runtime` field on the returned table for
  introspection).
- `Justfile` — `build-c`, `clean-c` recipes; updated `lua_cpath`
  variable; `test` recipe sources `LUA_CPATH`.
- CI configuration running the pure-Lua and C-enabled test suites.
- `.gitignore` — `runtime/pb/c_runtime.{so,dylib}` ignored.
- This spec.

## What does NOT ship yet

- No actual C source. `runtime/pb/c/` doesn't exist; `just build-c`
  errors with a clear message until the C runtime sources land.
- No rockspec changes (still pure-Lua install). The rockspec
  changes land with the first C source files.
- No `finalize_message` C-plan compile call. Lands with the plan
  compiler.

## References

- [docs/c-accel.md](../c-accel.md) — architecture
- [docs/specs/c_accel_compat.md](c_accel_compat.md) — compat contract
- [docs/specs/c_accel_strategy.md](c_accel_strategy.md) — C-side strategy
- `bench/c_accel/Makefile` — reference build, the patterns here are
  the patterns there
