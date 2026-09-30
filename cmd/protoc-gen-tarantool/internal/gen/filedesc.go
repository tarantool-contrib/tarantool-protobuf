package gen

import (
	"fmt"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/reflect/protoreflect"

	"github.com/tarantool-contrib/tarantool-protobuf/internal/builtindesc"
	"github.com/tarantool-contrib/tarantool-protobuf/internal/luastr"
)

// snapshotDeps returns the paths of every direct and transitive import
// of file that the runtime does not ship (builtindesc), dependencies
// first. The generated module embeds a snapshot of each, so the
// descriptor registry holds the file's whole import graph once the
// module is loaded.
//
// The rule deliberately ignores which files protoc generates in the
// same run: generating files together or one per protoc invocation
// must produce the same module. A dependency's own module, when it is
// loaded, registers the authoritative copy, which snapshots never
// override (see runtime/pb/descriptors.lua).
func snapshotDeps(file *protogen.File) []string {
	seen := map[string]bool{file.Desc.Path(): true}
	var out []string
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
			visit(imp)
			out = append(out, p)
		}
	}
	visit(file.Desc)
	return out
}

// fileDescriptorBytes returns the FileDescriptorProto for path exactly
// as protoc serialized it in the request, minus source_code_info.
func fileDescriptorBytes(cfg Config, path string) ([]byte, error) {
	b, ok := cfg.FileDescriptors[path]
	if !ok {
		return nil, fmt.Errorf("%s: no FileDescriptorProto in the request", path)
	}
	return b, nil
}

// emitFileDescriptors emits M._file_descriptor with its registration,
// then a snapshot registration per non-builtin import.
func emitFileDescriptors(w *writer, file *protogen.File, cfg Config) error {
	self, err := fileDescriptorBytes(cfg, file.Desc.Path())
	if err != nil {
		return err
	}
	w.line("-- Serialized FileDescriptorProto of %s (source_code_info", file.Desc.Path())
	w.line("-- stripped), registered with pb.descriptors for server reflection.")
	emitBytesExpr(w, "M._file_descriptor = ", self, "")
	w.line("pb.descriptors.register(M._file_descriptor)")
	deps := snapshotDeps(file)
	if len(deps) > 0 {
		w.line("-- Snapshots of the imports the runtime does not ship, so the import")
		w.line("-- graph of this file is registered. A snapshot never replaces the")
		w.line("-- descriptor an imported file's own module registers.")
	}
	for _, p := range deps {
		b, err := fileDescriptorBytes(cfg, p)
		if err != nil {
			return err
		}
		w.line("-- %s", p)
		emitBytesExpr(w, "pb.descriptors.register(", b, ", {snapshot = true})")
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
