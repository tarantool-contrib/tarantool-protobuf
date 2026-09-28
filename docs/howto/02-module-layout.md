# How-to: module layout

Where generated files land, what `require()` path they get, and how to
control both. The full path-resolution rules live in
[reference/cli.md](../reference/cli.md#path-resolution-rules); this
how-to is the practical "what should I put in my Makefile / Justfile" answer.

## The defaults

For a single `.proto` file, with no overrides:

```proto
// foo.proto
syntax = "proto3";
package my.app;
message Bar { ... }
```

```bash
protoc --tarantool_out=./gen foo.proto
```

| Generated file | `require()` path |
|---|---|
| `gen/my/app/foo_pb.lua` | `require('my.app.foo_pb')` |

The Lua module path is the `package` declaration plus the source file's
basename with `_pb` appended. Subdirectories of the input path do not
appear in the output — only the package and the basename matter.

If there's no `package`, just the basename: `foo.proto` →
`gen/foo_pb.lua`, `require('foo_pb')`.

## Three ways to override

### 1. `prefix=` plugin arg

Prepend a path to every generated module:

```bash
protoc --tarantool_out=./gen \
       --tarantool_opt=prefix=apps.myapp \
       foo.proto
```

| Without prefix | With `prefix=apps.myapp` |
|---|---|
| `gen/my/app/foo_pb.lua` | `gen/apps/myapp/my/app/foo_pb.lua` |
| `require('my.app.foo_pb')` | `require('apps.myapp.my.app.foo_pb')` |

Affects every file in the codegen invocation. Useful for vendoring —
"all generated modules belong under `apps.myapp.gen.*`".

The repo's Justfile uses this trick to produce `full/` and
`runtime/` copies side by side:

```bash
protoc --tarantool_opt=mode=full,prefix=full         ...
protoc --tarantool_opt=mode=runtime,prefix=runtime   ...
# => examples/expected/full/...  and  examples/expected/runtime/...
```

### 2. `option (tarantool.lua_package)` — per file

Override one file's path with a file option:

```proto
syntax = "proto3";
package my.app;

import "tarantool/tarantool.proto";
option (tarantool.lua_package) = "myapp.proto.foo";

message Bar { ... }
```

```bash
protoc -Ioptions --tarantool_out=./gen foo.proto
```

| Without `lua_package` | With `lua_package = "myapp.proto.foo"` |
|---|---|
| `gen/my/app/foo_pb.lua` | `gen/myapp/proto/foo_pb.lua` |
| `require('my.app.foo_pb')` | `require('myapp.proto.foo_pb')` |

The `-Ioptions` argument lets `protoc` find the option definition
file at `options/tarantool/tarantool.proto` inside this repo. Copy
that file into your project (or vendor the repo) and use the same
import path.

If `lua_package` already ends in `_pb`, the plugin doesn't append a
second one — `lua_package = "myapp.foo_pb"` lands at `myapp/foo_pb.lua`,
not `myapp/foo_pb_pb.lua`.

### 3. Both: `prefix` composes with `lua_package`

`prefix` is prepended to whatever path the per-file rules produced —
including `lua_package` overrides:

```bash
protoc -Ioptions \
       --tarantool_out=./gen \
       --tarantool_opt=prefix=vendor \
       foo.proto
```

With the `lua_package = "myapp.proto.foo"` option above:

| Final path |
|---|
| `gen/vendor/myapp/proto/foo_pb.lua` |
| `require('vendor.myapp.proto.foo_pb')` |

## Side-by-side: three invocations

Same input proto, three different layouts:

```bash
# 1. Default — mirrors the package
protoc --tarantool_out=./out1 my/app/foo.proto
# => out1/my/app/foo_pb.lua  (require 'my.app.foo_pb')

# 2. Prefix only — vendor namespace
protoc --tarantool_out=./out2 \
       --tarantool_opt=prefix=apps.myapp \
       my/app/foo.proto
# => out2/apps/myapp/my/app/foo_pb.lua  (require 'apps.myapp.my.app.foo_pb')

# 3. lua_package only (with `option (tarantool.lua_package) = "app.foo";`)
protoc -Ioptions --tarantool_out=./out3 my/app/foo.proto
# => out3/app/foo_pb.lua  (require 'app.foo_pb')
```

## Wiring `LUA_PATH`

Two patterns the generated code expects:

```bash
LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./gen/?.lua;./gen/?/init.lua;;"
```

- `./runtime/?/init.lua` — resolves `require('pb')` to
  `runtime/pb/init.lua`.
- `./runtime/?.lua` — resolves sibling modules like
  `require('pb.wire')` to `runtime/pb/wire.lua`.
- `./gen/?.lua` and `./gen/?/init.lua` — resolves your generated
  modules. Add **both** patterns so flat (`gen/foo_pb.lua`) and
  nested (`gen/my/app/foo_pb.lua`) layouts both work.
- The trailing `;;` defers to Lua's built-in path for everything
  else (the `box.*` modules, `fiber`, etc.).

In a `tt`-managed app, drop the same string into the `LUA_PATH`
environment variable in your instance config, or extend
`package.path` from `main.lua` before the first `require`.

## WKT imports

`google/protobuf/*.proto` files referenced by your protos are **not**
generated as Lua modules. References to WKT types are rewritten at
codegen time to point at `pb.wkt.<Name>_descriptor`. The runtime side
ships them in `runtime/pb/wkt.lua`. So:

```proto
import "google/protobuf/timestamp.proto";
message Event {
    google.protobuf.Timestamp created_at = 1;
}
```

Doesn't require a `protoc -I` pointing at the WKT proto path beyond
what your `protoc` already knows about (`protoc` finds them itself).
The plugin will not emit a `google/protobuf/timestamp_pb.lua`.

## What's next

- [Reference: CLI](../reference/cli.md) — every flag and option.
- [How-to: build integration](12-build-integration.md) — wiring
  this into `make`, `just`, `buf`, CMake.
