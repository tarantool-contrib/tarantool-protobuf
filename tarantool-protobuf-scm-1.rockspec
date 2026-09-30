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
        ["pb.descriptors"]   = "runtime/pb/descriptors.lua",
        ["pb.descriptors_builtin"] = "runtime/pb/descriptors_builtin.lua",
        ["pb.dynamic"]       = "runtime/pb/dynamic.lua",
        ["pb.fileset"]       = "runtime/pb/fileset.lua",
        ["pb.gen.grpc.health.v1.health_pb"] = "runtime/pb/gen/grpc/health/v1/health_pb.lua",
        ["pb.gen.grpc.reflection.v1.reflection_pb"] = "runtime/pb/gen/grpc/reflection/v1/reflection_pb.lua",
        ["pb.gen.grpc.reflection.v1alpha.reflection_pb"] = "runtime/pb/gen/grpc/reflection/v1alpha/reflection_pb.lua",
        ["pb.grpc"]          = "runtime/pb/grpc.lua",
        ["pb.health"]        = "runtime/pb/health.lua",
        ["pb.json"]          = "runtime/pb/json.lua",
        ["pb.lazy"]          = "runtime/pb/lazy.lua",
        ["pb.parser"]        = "runtime/pb/parser.lua",
        ["pb.reflection"]    = "runtime/pb/reflection.lua",
        ["pb.server"]        = "runtime/pb/server.lua",
        ["pb.text"]          = "runtime/pb/text.lua",
        ["pb.transcode"]     = "runtime/pb/transcode.lua",
        ["pb.tuple"]         = "runtime/pb/tuple.lua",
        ["pb.wire"]          = "runtime/pb/wire.lua",
        ["pb.wkt"]           = "runtime/pb/wkt.lua",
    },
}
