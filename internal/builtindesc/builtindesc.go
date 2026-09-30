// Package builtindesc names the .proto files whose descriptors the Lua
// runtime ships itself (runtime/pb/descriptors_builtin.lua): the
// well-known types, descriptor.proto, plugin.proto, and the vendored
// google/api/{annotations,http}.proto. The plugin never generates a Lua
// module for these files, so it must not embed them either.
package builtindesc

// paths lists the built-in files, dependencies before the files that
// import them.
var paths = []string{
	"google/protobuf/descriptor.proto",
	"google/protobuf/any.proto",
	"google/protobuf/source_context.proto",
	"google/protobuf/type.proto",
	"google/protobuf/api.proto",
	"google/protobuf/duration.proto",
	"google/protobuf/empty.proto",
	"google/protobuf/field_mask.proto",
	"google/protobuf/struct.proto",
	"google/protobuf/timestamp.proto",
	"google/protobuf/wrappers.proto",
	"google/protobuf/compiler/plugin.proto",
	"google/api/http.proto",
	"google/api/annotations.proto",
}

var builtin = func() map[string]bool {
	m := map[string]bool{}
	for _, p := range paths {
		m[p] = true
	}
	return m
}()

// Paths returns the built-in file paths (as imported), dependencies
// first.
func Paths() []string {
	return append([]string(nil), paths...)
}

// IsBuiltin reports whether the runtime ships the descriptor of the
// .proto file at path (as imported, e.g. "google/protobuf/any.proto").
func IsBuiltin(path string) bool {
	return builtin[path]
}
