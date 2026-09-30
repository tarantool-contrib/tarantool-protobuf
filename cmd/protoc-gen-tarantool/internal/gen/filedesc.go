package gen

import (
	"fmt"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"

	"github.com/tarantool-contrib/tarantool-protobuf/internal/builtindesc"
	"github.com/tarantool-contrib/tarantool-protobuf/internal/luastr"
)

// registrationDeps sorts the import graph of file for descriptor
// registration:
//
//   - generated: direct or transitive imports generated in this protoc
//     run. Their modules register themselves; the caller requires them.
//     The walk stops at them, since each module covers its own imports.
//   - embedded: imports neither generated in this run nor shipped with
//     the runtime (builtindesc), e.g. an options file such as
//     tarantool/tarantool.proto that is only on the -I path. Their
//     descriptors are embedded into this module, dependencies first.
func registrationDeps(plug *protogen.Plugin, file *protogen.File) (generated []protoreflect.FileDescriptor, embedded []string) {
	seen := map[string]bool{file.Desc.Path(): true}
	var visit func(fd protoreflect.FileDescriptor)
	visit = func(fd protoreflect.FileDescriptor) {
		imports := fd.Imports()
		for i := 0; i < imports.Len(); i++ {
			imp := imports.Get(i).FileDescriptor
			p := imp.Path()
			if seen[p] || imp.IsPlaceholder() || builtindesc.IsBuiltin(p) {
				continue
			}
			seen[p] = true
			if f, ok := plug.FilesByPath[p]; ok && f.Generate {
				generated = append(generated, imp)
				continue
			}
			visit(imp)
			embedded = append(embedded, p)
		}
	}
	visit(file.Desc)
	return generated, embedded
}

// fileDescriptorBytes serializes the request's FileDescriptorProto for
// path the way protoc-gen-go embeds descriptors: source_code_info
// stripped, deterministic field order.
func fileDescriptorBytes(cfg Config, path string) ([]byte, error) {
	fdp := cfg.FileDescriptors[path]
	if fdp == nil {
		return nil, fmt.Errorf("%s: no FileDescriptorProto in the request", path)
	}
	c := proto.Clone(fdp).(*descriptorpb.FileDescriptorProto)
	c.SourceCodeInfo = nil
	return proto.MarshalOptions{Deterministic: true}.Marshal(c)
}

// emitFileDescriptors emits M._file_descriptor and the registration calls
// for it and for the embedded imports.
func emitFileDescriptors(w *writer, file *protogen.File, cfg Config, embedded []string) error {
	self, err := fileDescriptorBytes(cfg, file.Desc.Path())
	if err != nil {
		return err
	}
	w.line("-- Serialized FileDescriptorProto of %s (source_code_info", file.Desc.Path())
	w.line("-- stripped), registered with pb.descriptors for server reflection.")
	emitBytesExpr(w, "M._file_descriptor = ", self, "")
	w.line("pb.descriptors.register(M._file_descriptor)")
	if len(embedded) > 0 {
		w.line("-- Imported files that are not generated alongside this one and")
		w.line("-- that the runtime does not ship; registered so the import graph")
		w.line("-- of this file is complete.")
	}
	for _, p := range embedded {
		b, err := fileDescriptorBytes(cfg, p)
		if err != nil {
			return err
		}
		w.line("-- %s", p)
		emitBytesExpr(w, "pb.descriptors.register(", b, ")")
	}
	w.line("")
	return nil
}

// emitBytesExpr writes `<prefix>table.concat({ <chunks> })<suffix>`,
// splitting b into short string literals that concatenate back to b
// exactly.
func emitBytesExpr(w *writer, prefix string, b []byte, suffix string) {
	w.line("%stable.concat({", prefix)
	for _, chunk := range luastr.Chunks(b) {
		w.line("    %s,", chunk)
	}
	w.line("})%s", suffix)
}
