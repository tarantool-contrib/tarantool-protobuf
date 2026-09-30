# tarantool-protobuf options

Custom Protocol Buffers options read by
[`protoc-gen-tarantool`](https://github.com/tarantool-contrib/tarantool-protobuf),
the protoc plugin that generates Lua modules for Tarantool.

`tarantool/tarantool.proto` defines one file option:

```proto
syntax = "proto3";

package shop.v1;

import "tarantool/tarantool.proto";

// The Lua module path of the generated code: require('shop.shop_pb').
// Without it, the path is derived from the package and the file name.
option (tarantool.lua_package) = "shop.shop_pb";
```

Import it as `tarantool/tarantool.proto`: this directory is the import
root.

- **protoc**: `-I <checkout>/options`.
- **buf**: `deps: [buf.build/tarantool-contrib/tarantool-protobuf]` in
  `buf.yaml`, once the module is published on the Buf Schema Registry.
- **EasyP**: `deps: [github.com/tarantool-contrib/tarantool-protobuf@<tag>]`
  in `easyp.yaml`.

See
[docs/howto/12-build-integration.md](https://github.com/tarantool-contrib/tarantool-protobuf/blob/master/docs/howto/12-build-integration.md#using-the-options-module)
for the details and
[docs/reference/cli.md](https://github.com/tarantool-contrib/tarantool-protobuf/blob/master/docs/reference/cli.md#tarantoollua_package)
for what the option does.
