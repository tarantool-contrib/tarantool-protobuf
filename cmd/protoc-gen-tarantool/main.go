// protoc-gen-tarantool is a protoc plugin that generates Lua code targeting
// Tarantool's LuaJIT runtime, paired with the runtime/protobuf Lua package.
//
// Usage:
//
//	protoc --tarantool_out=./out --plugin=./protoc-gen-tarantool foo.proto
//
// File option (in your .proto):
//
//	import "tarantool/tarantool.proto";
//	option (tarantool.lua_package) = "myapp.proto.foo";
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/pluginpb"

	"github.com/tarantool-contrib/tarantool-protobuf/cmd/protoc-gen-tarantool/internal/gen"
	"github.com/tarantool-contrib/tarantool-protobuf/internal/messageset"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail("read stdin: %v", err)
	}
	req := &pluginpb.CodeGeneratorRequest{}
	if err := proto.Unmarshal(in, req); err != nil {
		fail("parse CodeGeneratorRequest: %v", err)
	}

	// protogen requires a go_package on every input file even when we are not
	// generating Go. Inject a synthetic value when it's missing — it's never
	// surfaced to the generated Lua.
	for _, f := range req.ProtoFile {
		if f.Options == nil {
			f.Options = &descriptorpb.FileOptions{}
		}
		if f.Options.GoPackage == nil {
			stub := "tarantoolpb_synthetic/" + strings.TrimSuffix(f.GetName(), ".proto")
			f.Options.GoPackage = proto.String(stub)
		}
	}

	// protobuf-go cannot load a MessageSet declaration; strip the option
	// and remember which messages had it.
	messageSets := messageset.Strip(req)

	var flags flag.FlagSet
	modeFlag := flags.String("mode", "full", "codegen mode: full | runtime")
	prefixFlag := flags.String("prefix", "",
		"prefix prepended to every generated module's Lua require path "+
			"(useful for side-by-side generation in tests)")
	int64AsNumberFlag := flags.Bool("int64_as_number", false,
		"opt-in (mode=full only): emit decoders that return a Lua number "+
			"for int64/uint64/sint64/fixed64/sfixed64 values that fit in "+
			"[-2^53, 2^53), falling back to cdata for values outside that "+
			"range. Skips the per-call cdata allocation on the common case "+
			"(IDs, timestamps in seconds/ms, byte counts). Decoded type is "+
			"unstable (number-or-cdata); arithmetic works transparently. "+
			"Default false (always cdata).")
	plugin, err := protogen.Options{ParamFunc: flags.Set}.New(req)
	if err != nil {
		fail("init protogen: %v", err)
	}

	mode, err := gen.ParseMode(*modeFlag)
	if err != nil {
		fail("%v", err)
	}
	if *int64AsNumberFlag && mode != gen.ModeFull {
		fail("int64_as_number is currently mode=full only " +
			"(runtime mode would require a descriptor flag wired through pb.codec)")
	}
	cfg := gen.Config{Mode: mode, Prefix: *prefixFlag, Int64AsNumber: *int64AsNumberFlag,
		MessageSets: messageSets}

	// Advertise proto3 optional support so protoc lets us see those fields.
	plugin.SupportedFeatures = uint64(pluginpb.CodeGeneratorResponse_FEATURE_PROTO3_OPTIONAL)

	for _, file := range plugin.Files {
		if !file.Generate {
			continue
		}
		if err := gen.GenerateFile(plugin, file, cfg); err != nil {
			plugin.Error(err)
		}
	}

	out, err := proto.Marshal(plugin.Response())
	if err != nil {
		fail("marshal CodeGeneratorResponse: %v", err)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		fail("write stdout: %v", err)
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "protoc-gen-tarantool: "+format+"\n", args...)
	os.Exit(1)
}
