// EmmyLua / lua-language-server annotation emission.
//
// Annotations are pure comments — they have no runtime effect — but
// they teach the Lua language server about generated message shapes,
// enum aliases, and wrapper function signatures. Users of generated
// code get autocomplete, type-checking, and rename refactoring for
// free in any editor that consumes EmmyLua (VS Code + sumneko, Neovim
// LSP, JetBrains EmmyLua plugin).
//
// Output (per file):
//   1. ---@alias <pkg.Enum> integer        (one per enum)
//   2. ---@class <pkg.Message>             (one per message)
//      ---@field <name> <type>
//      ...
//   3. ---@param / ---@return on each emitted M.<Name>_* function.
//
// All three blocks are emitted by gen.go at well-defined points so
// they live alongside the code they describe.
//
// Type mapping (proto -> EmmyLua):
//   - bool                -> boolean
//   - string / bytes      -> string
//   - float / double      -> number
//   - all int kinds       -> integer  (64-bit are uint64_t/int64_t cdata
//                                     at runtime; LSP has no cdata model,
//                                     so they're typed as integer with
//                                     an inline note)
//   - enum<Name>          -> <Name>          (alias declared elsewhere)
//   - message<Name>       -> <Name>          (class declared elsewhere)
//   - repeated<T>         -> T[]
//   - map<K,V>            -> table<K, V>
//
// Field presence:
//   - proto3 explicit `optional`   -> trailing `?` on the field name
//   - oneof branch                 -> trailing `?` (only one is set at a time)
//   - everything else              -> no marker (proto3 defaults imply
//                                     a typed zero value if absent)

package gen

import (
	"fmt"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// emmyTypeName returns the qualified EmmyLua class/alias identifier for a
// message or enum. We use the proto full name verbatim (with dots), which
// lua-language-server accepts as a class identifier. This keeps cross-file
// references straightforward — every file referring to "hello.Person"
// resolves to the same `---@class hello.Person` block, regardless of which
// generated `.lua` declared it.
func emmyTypeName(td protoreflect.Descriptor) string {
	return string(td.FullName())
}

// emmyScalarType maps a proto3 scalar kind to its EmmyLua surface type.
func emmyScalarType(k protoreflect.Kind) string {
	switch k {
	case protoreflect.BoolKind:
		return "boolean"
	case protoreflect.StringKind, protoreflect.BytesKind:
		return "string"
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		return "number"
	default:
		// All int kinds. 64-bit are int64_t/uint64_t cdata at runtime,
		// but EmmyLua has no model for that; users either compare via
		// pb.to_int64/pb.to_uint64 or convert with tonumber for small
		// values. Typing as integer matches user mental model.
		return "integer"
	}
}

// emmyFieldType returns the surface type for one field, accounting for
// kind (scalar/enum/message/map) and the repeated modifier.
func emmyFieldType(f *protogen.Field) string {
	if f.Desc.IsMap() {
		kf := f.Message.Fields[0]
		vf := f.Message.Fields[1]
		return fmt.Sprintf("table<%s, %s>",
			emmyFieldTypeSingular(kf), emmyFieldTypeSingular(vf))
	}
	t := emmyFieldTypeSingular(f)
	if f.Desc.IsList() {
		return t + "[]"
	}
	return t
}

func emmyFieldTypeSingular(f *protogen.Field) string {
	switch {
	case f.Message != nil:
		return emmyTypeName(f.Message.Desc)
	case f.Enum != nil:
		return emmyTypeName(f.Enum.Desc)
	default:
		return emmyScalarType(f.Desc.Kind())
	}
}

// emmyFieldOptional reports whether the field should carry a trailing `?`.
// Two cases: proto3 explicit optional, and oneof branches (only one is
// set at a time, so every branch is presence-tracked).
func emmyFieldOptional(f *protogen.Field) bool {
	if f.Desc.HasOptionalKeyword() {
		return true
	}
	if f.Oneof != nil && !f.Desc.HasOptionalKeyword() {
		return true
	}
	return false
}

// emitEmmyEnumAlias emits `---@alias <pkg.Enum> integer` for each enum.
// Could be tightened to `<value> | <value> | ...` but that locks the
// schema in the annotation; users typically write `M.Status.OK` (an
// integer literal) so `integer` is the honest type.
func emitEmmyEnumAlias(w *writer, e *protogen.Enum) {
	emitProtoDoc(w, e.Comments.Leading)
	w.line("---@alias %s integer", emmyTypeName(e.Desc))
}

// emitEmmyMessageClass emits the `---@class` block for one message,
// listing every field with its surface type and optional marker. Leading
// proto comments on the message become `---` lines above `---@class`;
// per-field comments are appended to each `---@field` line.
func emitEmmyMessageClass(w *writer, m *protogen.Message) {
	emitProtoDoc(w, m.Comments.Leading)
	w.line("---@class %s", emmyTypeName(m.Desc))
	for _, f := range m.Fields {
		name := string(f.Desc.Name())
		if emmyFieldOptional(f) {
			name = name + "?"
		}
		line := fmt.Sprintf("---@field %s %s", name, emmyFieldType(f))
		if doc := flattenComment(f.Comments.Leading); doc != "" {
			line += " @ " + doc
		}
		w.line("%s", line)
	}
}

// emitProtoDoc emits each line of a proto leading-comment block as a
// `--- text` line. LuaLS treats those as the description of the next
// `---@class`/`---@alias`/function declaration, so they show up on hover.
func emitProtoDoc(w *writer, c protogen.Comments) {
	s := strings.TrimSuffix(string(c), "\n")
	if s == "" {
		return
	}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimPrefix(line, " ")
		if line == "" {
			w.line("---")
		} else {
			w.line("--- %s", line)
		}
	}
}

// emitProtoDocIndented emits each line of a proto leading-comment block
// as a regular Lua `-- text` line prefixed with `indent`. Use inside
// table literals (enum value rows, service method entries) where LuaLS
// doc attachment doesn't apply but the human-facing context is still
// worth preserving.
func emitProtoDocIndented(w *writer, c protogen.Comments, indent string) {
	s := strings.TrimSuffix(string(c), "\n")
	if s == "" {
		return
	}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimPrefix(line, " ")
		if line == "" {
			w.line("%s--", indent)
		} else {
			w.line("%s-- %s", indent, line)
		}
	}
}

// flattenComment collapses a (possibly multi-line) proto leading comment
// into a single trimmed line, suitable for trailing `@description` on a
// `---@field` line. Empty input returns "".
func flattenComment(c protogen.Comments) string {
	s := strings.TrimSuffix(string(c), "\n")
	if s == "" {
		return ""
	}
	parts := strings.Split(s, "\n")
	for i, line := range parts {
		parts[i] = strings.TrimSpace(line)
	}
	return strings.TrimSpace(strings.Join(parts, " "))
}

// emitEmmyWrappersHeader prefaces the M.<Name>_new / _encode / _decode /
// _decode_lazy / has_/clear_ stubs with their EmmyLua annotations. Each
// wrapper gets its own `---@param` / `---@return` lines printed
// immediately before the corresponding `function M.<Name>_*(...)` line.
//
// emitMessageWrappers (runtime mode) and emitInlineMessage (full mode)
// each call into this for the typed prelude; the function bodies stay
// where they were.
func emitEmmyWrapperAnnotations(w *writer, name string, fullName string, kind emmyWrapperKind) {
	t := fullName
	switch kind {
	case wrapperNew:
		w.line("---@param t? %s", t)
		w.line("---@return %s", t)
	case wrapperEncode:
		w.line("---@param t %s", t)
		w.line("---@return string")
	case wrapperDecode:
		w.line("---@param b string")
		w.line("---@return %s", t)
	case wrapperDecodeLazy:
		w.line("---@param b string")
		w.line("---@return pb.MessageView")
	case wrapperText:
		w.line("---@param t %s", t)
		w.line("---@param opts? {single_line: boolean?, indent: string?}")
		w.line("---@return string")
	case wrapperHas:
		w.line("---@param t %s", t)
		w.line("---@return boolean")
	case wrapperClear:
		w.line("---@param t %s", t)
	}
}

type emmyWrapperKind int

const (
	wrapperNew emmyWrapperKind = iota
	wrapperEncode
	wrapperDecode
	wrapperDecodeLazy
	wrapperText
	wrapperHas
	wrapperClear
)

// emitEmmyTypesBlock emits the file's whole types section: every enum
// alias, every message class. Called once per file by GenerateFile,
// after the descriptor pre-declarations and before the wrappers.
func emitEmmyTypesBlock(w *writer, enums []*protogen.Enum, msgs []*protogen.Message) {
	if len(enums) == 0 && len(msgs) == 0 {
		return
	}
	w.line("-- EmmyLua / lua-language-server type annotations.")
	w.line("-- These are comments — no runtime effect. They give editors")
	w.line("-- autocomplete and type-checking for the generated wrappers.")
	for _, e := range enums {
		emitEmmyEnumAlias(w, e)
	}
	if len(enums) > 0 {
		w.line("")
	}
	for i, m := range msgs {
		emitEmmyMessageClass(w, m)
		if i < len(msgs)-1 {
			w.line("")
		}
	}
	w.line("")
}

// emmyMessageFullName is a convenience wrapper used by the wrapper
// emitters to resolve the right `---@class` identifier for a message.
func emmyMessageFullName(m *protogen.Message) string {
	return strings.TrimSpace(string(m.Desc.FullName()))
}
