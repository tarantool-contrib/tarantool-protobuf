package gen

import (
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/runtime/protoimpl"
	"google.golang.org/protobuf/types/descriptorpb"
)

// E_LuaPackage mirrors the option declared in options/tarantool/tarantool.proto.
// We register it manually here to avoid having to ship a generated stub for our
// own option file.
var E_LuaPackage = &protoimpl.ExtensionInfo{
	ExtendedType:  (*descriptorpb.FileOptions)(nil),
	ExtensionType: (*string)(nil),
	Field:         53301,
	Name:          "tarantool.lua_package",
	Tag:           "bytes,53301,opt,name=lua_package",
	Filename:      "tarantool/tarantool.proto",
}

// Register the extension in the global type registry so that
// proto.GetExtension can resolve it on FileOptions parsed by protoc-gen-go's
// plugin scaffolding. Without this, the option's value lands in the message's
// unknown fields and GetExtension returns the zero value ("").
func init() {
	if err := protoregistry.GlobalTypes.RegisterExtension(E_LuaPackage); err != nil {
		panic("tarantool-protobuf: register E_LuaPackage: " + err.Error())
	}
}

// luaPackageOption returns the value of (tarantool.lua_package) on the file
// options, or "" when unset.
func luaPackageOption(f protoreflect.FileDescriptor) string {
	opts, _ := f.Options().(*descriptorpb.FileOptions)
	if opts == nil {
		return ""
	}
	v, ok := proto.GetExtension(opts, E_LuaPackage).(string)
	if !ok {
		return ""
	}
	return v
}
