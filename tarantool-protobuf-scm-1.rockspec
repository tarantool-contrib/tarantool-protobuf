package = "tarantool-protobuf"
version = "scm-1"

source = {
    url = "git+https://github.com/tarantool-contrib/tarantool-protobuf.git",
    branch = "master",
}

description = {
    summary = "Protocol Buffers (proto3) + gRPC runtime for Tarantool",
    detailed = [[
A protoc plugin (Go) and pure-Lua runtime that give Tarantool a complete
proto3 + gRPC stack — decode, map, oneof, services, well-known types, JSON
and text-format codecs, and zero-copy lazy decode views. The Lua module
is named `pb` to avoid colliding with Tarantool's encode-only built-in
`protobuf` module. This rockspec installs only the runtime; the
`protoc-gen-tarantool` plugin must be built separately from the Go
sources (see Justfile).
]],
    homepage = "https://github.com/tarantool-contrib/tarantool-protobuf",
    license  = "BSD-2-Clause",
    maintainer = "Eugene Blikh <bigbes@gmail.com>",
}

dependencies = {
    "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["pb"]               = "runtime/pb/init.lua",
        ["pb.c_loader"]      = "runtime/pb/c_loader.lua",
        ["pb.codec"]         = "runtime/pb/codec.lua",
        ["pb.descriptor_pb"] = "runtime/pb/descriptor_pb.lua",
        ["pb.dynamic"]       = "runtime/pb/dynamic.lua",
        ["pb.fileset"]       = "runtime/pb/fileset.lua",
        ["pb.grpc"]          = "runtime/pb/grpc.lua",
        ["pb.json"]          = "runtime/pb/json.lua",
        ["pb.lazy"]          = "runtime/pb/lazy.lua",
        ["pb.parser"]        = "runtime/pb/parser.lua",
        ["pb.text"]          = "runtime/pb/text.lua",
        ["pb.tuple"]         = "runtime/pb/tuple.lua",
        ["pb.wire"]          = "runtime/pb/wire.lua",
        ["pb.wkt"]           = "runtime/pb/wkt.lua",
    },
}
