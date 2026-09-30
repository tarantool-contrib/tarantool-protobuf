// Package builtindesc names the .proto files whose descriptors the Lua
// runtime ships itself (runtime/pb/descriptors_builtin.lua): the
// well-known types, descriptor.proto, plugin.proto, and the vendored
// google/api/{annotations,http}.proto. The plugin never generates a Lua
// module for these files, so it must not embed them either.
package builtindesc

import (
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/apipb"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	"google.golang.org/protobuf/types/known/sourcecontextpb"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/typepb"
	"google.golang.org/protobuf/types/known/wrapperspb"
	"google.golang.org/protobuf/types/pluginpb"
)

// Files returns the built-in file descriptors, dependencies before the
// files that import them.
func Files() []protoreflect.FileDescriptor {
	return []protoreflect.FileDescriptor{
		descriptorpb.File_google_protobuf_descriptor_proto,
		anypb.File_google_protobuf_any_proto,
		sourcecontextpb.File_google_protobuf_source_context_proto,
		typepb.File_google_protobuf_type_proto,
		apipb.File_google_protobuf_api_proto,
		durationpb.File_google_protobuf_duration_proto,
		emptypb.File_google_protobuf_empty_proto,
		fieldmaskpb.File_google_protobuf_field_mask_proto,
		structpb.File_google_protobuf_struct_proto,
		timestamppb.File_google_protobuf_timestamp_proto,
		wrapperspb.File_google_protobuf_wrappers_proto,
		pluginpb.File_google_protobuf_compiler_plugin_proto,
		annotations.File_google_api_http_proto,
		annotations.File_google_api_annotations_proto,
	}
}

var builtin = func() map[string]bool {
	m := map[string]bool{}
	for _, f := range Files() {
		m[f.Path()] = true
	}
	return m
}()

// IsBuiltin reports whether the runtime ships the descriptor of the
// .proto file at path (as imported, e.g. "google/protobuf/any.proto").
func IsBuiltin(path string) bool {
	return builtin[path]
}
