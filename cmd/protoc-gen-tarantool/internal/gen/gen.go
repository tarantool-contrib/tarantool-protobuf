// Package gen contains the per-file Lua codegen used by protoc-gen-tarantool.
package gen

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"

	"github.com/tarantool-contrib/tarantool-protobuf/internal/messageset"
)

const runtimeRequire = "pb"

// Mode controls how generated _encode / _decode wrappers are produced.
//
//   - ModeFull (default): emit per-message inline encode/decode functions
//     that call wire primitives directly, no descriptor dispatch. Faster,
//     more JIT-friendly, larger output.
//   - ModeRuntime: emit thin wrappers that delegate to pb.encode / pb.decode
//     against the (always-emitted) descriptor table. Slower, smaller output,
//     useful for introspection.
//
// The descriptor table is emitted in both modes so users can introspect
// schemas and so future tooling (registry, dynamic types) keeps working.
type Mode int

const (
	ModeFull Mode = iota
	ModeRuntime
)

// ParseMode converts a CLI value (full|runtime) to a Mode. Empty -> default.
func ParseMode(s string) (Mode, error) {
	switch s {
	case "", "full":
		return ModeFull, nil
	case "runtime":
		return ModeRuntime, nil
	}
	return ModeFull, fmt.Errorf("unknown mode %q (want full|runtime)", s)
}

// Config carries per-invocation generator options.
type Config struct {
	Mode Mode
	// Prefix, when non-empty, is prepended to every generated module's Lua
	// require path (and its on-disk subpath). Lets the same .proto be
	// generated under multiple namespaces in one project — e.g. for
	// side-by-side full vs runtime mode comparison in tests.
	Prefix string
	// Int64AsNumber: when true (mode=full only), 64-bit decoders return a
	// Lua number for values that fit in [-2^53, 2^53] (or [0, 2^53] for
	// unsigned) and cdata otherwise. Skips the per-call cdata allocation
	// on the dominant small-value case (IDs, timestamps, byte counts).
	// Default false — decoded 64-bit fields are always cdata.
	Int64AsNumber bool
	// MessageSets names the messages declared with
	// `option message_set_wire_format = true` (see messageset.Strip).
	MessageSets messageset.Set
	// FileDescriptors holds every file of the request, by name, as
	// protoc sent it (before the plugin's own request fix-ups). Each
	// generated module embeds its file's entry; see filedesc.go.
	FileDescriptors map[string]*descriptorpb.FileDescriptorProto
}

// GenerateFile emits one `<lua_pkg>.lua` file per input `.proto`.
func GenerateFile(plug *protogen.Plugin, file *protogen.File, cfg Config) error {
	syntax := file.Desc.Syntax()
	if syntax != protoreflect.Proto3 && syntax != protoreflect.Proto2 {
		return fmt.Errorf("%s: only proto2 and proto3 are supported, got %s",
			file.Desc.Path(), syntax)
	}

	allMsgs := flattenMessagesSkippingMapEntries(file.Messages, nil)
	allEnums := flattenEnums(file.Enums, file.Messages)

	out := plug.NewGeneratedFile(outputFilename(file.Desc, cfg.Prefix), "")
	w := &writer{
		GeneratedFile: out,
		opts:          newOptionsResolver(plug),
		int64AsNumber: cfg.Int64AsNumber,
	}

	emitHeader(w, file)
	imports := collectImports(file, allMsgs, cfg.Prefix)
	// Imports generated in this run register their own descriptors when
	// loaded; require them even when no field references them, so the
	// descriptor registry holds this file's whole import graph.
	generatedDeps, embeddedDeps := registrationDeps(plug, file)
	for _, d := range generatedDeps {
		if lp := luaPackagePath(d, cfg.Prefix); lp != luaPackagePath(file.Desc, cfg.Prefix) {
			imports[lp] = importAlias(lp)
		}
	}
	emitRequires(w, imports)

	w.line("local M = {}")
	w.line("")

	// File-level options (FileOptions + any extensions on it). Includes
	// `(tarantool.lua_package)` when set; consumers introspect the rest.
	if opts := w.renderOpts(file.Desc.Options()); opts != "" {
		w.line("M.options = %s", opts)
		w.line("")
	}

	// 1) Enums first (no forward-ref problems).
	for _, e := range allEnums {
		emitEnum(w, file, e)
	}

	// 2) Predeclare all message descriptor tables (so cross-references resolve).
	if len(allMsgs) > 0 {
		w.line("-- Pre-declare message descriptors so cross-references resolve.")
		for _, m := range allMsgs {
			name := luaTypeName(m.Desc.FullName(), file.Desc.Package())
			if cfg.MessageSets[string(m.Desc.FullName())] {
				// The codecs read and write this message's extensions
				// in the MessageSet item format.
				w.line("M.%s_descriptor = {name = %q, message_set = true}",
					name, string(m.Desc.FullName()))
				continue
			}
			w.line("M.%s_descriptor = {name = %q}", name, string(m.Desc.FullName()))
		}
		w.line("")
	}

	// 3) Fill in fields[] for each message and finalize.
	for _, m := range allMsgs {
		emitMessageFields(w, file, m, imports, cfg.Prefix)
	}

	// 3a) EmmyLua type annotations (---@class per message, ---@alias per
	// enum). Emitted between the descriptors and the wrappers so the
	// wrapper annotations a few lines down can reference these class names.
	emitEmmyTypesBlock(w, allEnums, allMsgs)

	// 4) Wrappers: _new / _encode / _decode.
	// Build a cross-file map of extensions keyed by extendee FullName so
	// the full-mode emitter can inline per-extension writers/readers.
	// Both files in the current generation pass and previously-loaded
	// imported files contribute; protogen surfaces every reachable
	// Extension via plug.Files.
	extsByExtendee := collectExtsByExtendee(plug)
	for _, m := range allMsgs {
		switch cfg.Mode {
		case ModeFull:
			if cfg.MessageSets[string(m.Desc.FullName())] {
				// The inline emitter has no MessageSet item codec;
				// delegate to pb.codec, which has one.
				emitMessageWrappers(w, file, m, true)
				continue
			}
			extsForMe := extsByExtendee[string(m.Desc.FullName())]
			emitInlineMessage(w, file, m, imports, cfg.Prefix, extsForMe)
		default:
			emitMessageWrappers(w, file, m, false)
		}
	}

	// 5) Services (mode-independent — client/server stubs delegate to the
	// per-message _encode/_decode functions emitted in step 4).
	for _, svc := range file.Services {
		emitService(w, file, svc, imports, cfg.Prefix)
	}

	// 6) Proto2 extensions: top-level `extend Foo { ... }` declarations
	// plus the same form nested inside messages. Each one registers a
	// new tag on the extendee's descriptor; the codec routes wire bytes
	// at that tag through the extension's field shape and stores the
	// value under `data._extensions[full_name]`.
	emitExtensions(w, file, file.Extensions, imports, cfg.Prefix)
	for _, m := range allMsgs {
		emitExtensions(w, file, m.Extensions, imports, cfg.Prefix)
	}

	// 7) Serialized FileDescriptorProto of this file (and of imports not
	// generated with it), registered with pb.descriptors at load time.
	if err := emitFileDescriptors(w, file, cfg, embeddedDeps); err != nil {
		return err
	}

	w.line("return M")
	return nil
}

// ----------------------------------------------------------------------------
// writer: thin wrapper for line-oriented emission.
// ----------------------------------------------------------------------------

type writer struct {
	*protogen.GeneratedFile
	// opts re-links *Options messages so in-file extensions surface via the
	// generic walker — see optionsResolver in descopts.go.
	opts *optionsResolver
	// buf, when non-nil, captures line() output instead of writing it
	// straight to the GeneratedFile. captureLines sets/restores it; used by
	// emitInlineEncode/Decode to scan a function body for wire.* refs and
	// rewrite them to bare locals.
	buf *[]string
	// int64AsNumber mirrors Config.Int64AsNumber. Attached to the
	// writer rather than threaded through every emit-* signature so the
	// option is one field-lookup away wherever a decode call is emitted.
	int64AsNumber bool
}

func (w *writer) line(format string, args ...any) {
	var s string
	if len(args) == 0 {
		s = format
	} else {
		s = fmt.Sprintf(format, args...)
	}
	if w.buf != nil {
		*w.buf = append(*w.buf, s)
		return
	}
	w.P(s)
}

// captureLines runs fn while diverting w.line() output to a buffer,
// returning the captured lines and restoring the previous output mode.
// Nested calls stack correctly via the saved buf pointer.
func (w *writer) captureLines(fn func()) []string {
	var buf []string
	prev := w.buf
	w.buf = &buf
	fn()
	w.buf = prev
	return buf
}

// renderOpts is the writer-bound shortcut for rendering a descriptor's
// *Options message into a Lua table literal, threading the writer's
// extension resolver. Returns "" when no fields are populated — caller
// must omit the `options` key entirely.
func (w *writer) renderOpts(opts proto.Message) string {
	return mustRenderOptions(w.opts, opts)
}

// ----------------------------------------------------------------------------
// Header & requires
// ----------------------------------------------------------------------------

func emitHeader(w *writer, file *protogen.File) {
	w.line("-- Code generated by protoc-gen-tarantool. DO NOT EDIT.")
	w.line("-- source: %s", file.Desc.Path())
	w.line("-- syntax: %s", file.Desc.Syntax())
	if pkg := string(file.Desc.Package()); pkg != "" {
		w.line("-- package: %s", pkg)
	}
	w.line("")
	w.line("local pb = require(%q)", runtimeRequire)
	w.line("local wire = pb.wire")
	// Hot-path locals used by the inlined tag/length fast paths in each
	// generated _decode function. Localizing turns the LuaJIT references
	// into upvalue reads on the trace instead of repeated global lookups.
	w.line("local string_byte = string.byte")
	w.line("local utf8_len = require('utf8').len")
	w.line("local band = bit.band")
	w.line("local rshift = bit.rshift")
	// 256-byte lookup table replacing string.char(b) at length-prefix
	// emit sites. ~27% faster on small Person encode (see wire.CHARS).
	w.line("local CHARS = wire.CHARS")
	// table.new(N, 0) presizes a list's array part to avoid the rehash
	// cascade that fresh-`{}` tables pay as items are pushed. The
	// decoder hot path uses it for packed repeated fields where the
	// element count is recoverable from the LEN payload. LuaJIT
	// 2.1 (Tarantool's bundled fork) ships `table.new`.
	w.line("local table_new = require('table.new')")
	// Pre-typed cdata constructors for sint64/fixed64/sfixed64 singular
	// encode sites — the codegen casts at the call site instead of going
	// through wire.to_int64 / wire.to_uint64's runtime type dispatch.
	w.line("local ffi = require('ffi')")
	w.line("local INT64  = ffi.typeof('int64_t')")
	w.line("local UINT64 = ffi.typeof('uint64_t')")
}

// collectImports returns the deduplicated set of Lua require paths for all
// other .proto files referenced by message fields *and* service inputs/outputs
// in this file.
func collectImports(file *protogen.File, msgs []*protogen.Message, prefix string) map[string]string {
	selfPath := luaPackagePath(file.Desc, prefix)
	out := map[string]string{}
	addType := func(ext protoreflect.FileDescriptor) {
		if ext == nil {
			return
		}
		if isWellKnownTypeFile(ext) {
			return // pb.wkt is reachable via the existing `pb` require
		}
		lp := luaPackagePath(ext, prefix)
		if lp == selfPath {
			return
		}
		out[lp] = importAlias(lp)
	}
	for _, m := range msgs {
		for _, f := range m.Fields {
			switch {
			case f.Message != nil:
				addType(f.Message.Desc.ParentFile())
			case f.Enum != nil:
				addType(f.Enum.Desc.ParentFile())
			}
		}
	}
	for _, svc := range file.Services {
		for _, meth := range svc.Methods {
			addType(meth.Input.Desc.ParentFile())
			addType(meth.Output.Desc.ParentFile())
		}
	}
	return out
}

func emitRequires(w *writer, imports map[string]string) {
	if len(imports) == 0 {
		w.line("")
		return
	}
	keys := make([]string, 0, len(imports))
	for k := range imports {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		w.line("local %s = require(%q)", imports[k], k)
	}
	w.line("")
}

// ----------------------------------------------------------------------------
// Enum emission
// ----------------------------------------------------------------------------

func emitEnum(w *writer, file *protogen.File, e *protogen.Enum) {
	name := luaTypeName(e.Desc.FullName(), file.Desc.Package())
	w.line("-- Enum: %s", e.Desc.FullName())
	w.line("M.%s_descriptor = pb.enum(%q, {", name, string(e.Desc.FullName()))
	for _, v := range e.Values {
		emitProtoDocIndented(w, v.Comments.Leading, "    ")
		w.line("    %s = %d,", string(v.Desc.Name()), v.Desc.Number())
	}
	w.line("})")
	if opts := w.renderOpts(e.Desc.Options()); opts != "" {
		w.line("M.%s_descriptor.options = %s", name, opts)
	}
	// Proto2 enums are closed: unknown numeric values must be rejected at
	// JSON/text decode time and on wire they round-trip as unknown fields.
	// Proto3 enums are open. Surface the flag so codecs can branch.
	if e.Desc.IsClosed() {
		w.line("M.%s_descriptor.closed = true", name)
	}
	emitEnumValueOptions(w, name, e)
	// Convenience aliases the user can reach via `M.MyEnum.RED`, etc.
	w.line("M.%s = M.%s_descriptor.by_name", name, name)
	w.line("")
}

// emitEnumValueOptions emits `M.<Enum>_descriptor.value_options =
// { NAME = {...}, ... }` when any value carries populated options. Skipped
// otherwise so today's option-free enums stay byte-identical.
func emitEnumValueOptions(w *writer, name string, e *protogen.Enum) {
	type row struct {
		name string
		opts string
	}
	var rows []row
	for _, v := range e.Values {
		opts := w.renderOpts(v.Desc.Options())
		if opts == "" {
			continue
		}
		rows = append(rows, row{name: string(v.Desc.Name()), opts: opts})
	}
	if len(rows) == 0 {
		return
	}
	w.line("M.%s_descriptor.value_options = {", name)
	for _, r := range rows {
		w.line("    %s = %s,", luaTableKey(r.name), r.opts)
	}
	w.line("}")
}

// ----------------------------------------------------------------------------
// Message emission
// ----------------------------------------------------------------------------

// emitMessageFields fills the predeclared M.<Name>_descriptor with its
// fields[] array and finalizes it (which builds field_by_id).
func emitMessageFields(w *writer, file *protogen.File, m *protogen.Message, imports map[string]string, prefix string) {
	name := luaTypeName(m.Desc.FullName(), file.Desc.Package())
	selfPath := luaPackagePath(file.Desc, prefix)

	w.line("-- Message: %s", m.Desc.FullName())
	w.line("M.%s_descriptor.fields = {", name)
	for _, f := range m.Fields {
		w.line("    %s,", renderFieldEntry(w, file, f, selfPath, imports, prefix))
	}
	w.line("}")
	if opts := w.renderOpts(m.Desc.Options()); opts != "" {
		w.line("M.%s_descriptor.options = %s", name, opts)
	}
	emitOneofTable(w, name, m)
	emitOneofOptions(w, name, m)
	emitReservedNames(w, name, m)
	w.line("pb.finalize_message(M.%s_descriptor)", name)
	emitFieldNamesTable(w, name, m)
	emitOneofNamesTable(w, name, m)
	w.line("")
}

// emitFieldNamesTable emits a strict, typo-checked field-name constants
// table per message:
//
//	M.<Name>_fields = pb.field_names({
//	    foo = "foo",
//	    bar = "bar",
//	})
//
// Callers of the lazy view (`view:get(F.foo)`) get a load-time error on
// typos instead of the silent `nil` that a raw `view:get('fooo')` would
// return. See docs/api-modes.md for the documented contract.
func emitFieldNamesTable(w *writer, name string, m *protogen.Message) {
	if len(m.Fields) == 0 {
		return
	}
	w.line("M.%s_fields = pb.field_names({", name)
	for _, f := range m.Fields {
		fn := string(f.Desc.Name())
		w.line("    %s = %q,", luaTableKey(fn), fn)
	}
	w.line("})")
}

// emitOneofNamesTable emits a strict, typo-checked oneof-name constants
// table per message that declares non-synthetic oneofs. Symmetric to
// emitFieldNamesTable; used by `view:which(O.outcome)` etc.
func emitOneofNamesTable(w *writer, name string, m *protogen.Message) {
	var names []string
	for _, oo := range m.Oneofs {
		if oo.Fields[0].Desc.HasOptionalKeyword() {
			continue
		}
		names = append(names, string(oo.Desc.Name()))
	}
	if len(names) == 0 {
		return
	}
	w.line("M.%s_oneofs = pb.field_names({", name)
	for _, on := range names {
		w.line("    %s = %q,", luaTableKey(on), on)
	}
	w.line("})")
}

// emitOneofTable emits `M.<Name>_descriptor.oneofs = { <name> = {...members...} }`
// when the message has any non-synthetic oneofs.
func emitOneofTable(w *writer, name string, m *protogen.Message) {
	type oneofRow struct {
		name    string
		members []string
	}
	var rows []oneofRow
	for _, oo := range m.Oneofs {
		// Skip synthetic oneofs created for proto3 explicit `optional` — those
		// have a single member that uses HasOptionalKeyword().
		if oo.Fields[0].Desc.HasOptionalKeyword() {
			continue
		}
		row := oneofRow{name: string(oo.Desc.Name())}
		for _, f := range oo.Fields {
			row.members = append(row.members, string(f.Desc.Name()))
		}
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		return
	}
	w.line("M.%s_descriptor.oneofs = {", name)
	for _, row := range rows {
		quoted := make([]string, 0, len(row.members))
		for _, fn := range row.members {
			quoted = append(quoted, fmt.Sprintf("%q", fn))
		}
		w.line("    %s = {%s},", luaTableKey(row.name), strings.Join(quoted, ", "))
	}
	w.line("}")
}

// emitOneofOptions emits `M.<Name>_descriptor.oneof_options = { <oname> = {...} }`
// when any non-synthetic oneof carries populated OneofOptions. Skipped when
// no oneof has options to keep generated output identical to today for the
// common case.
func emitOneofOptions(w *writer, name string, m *protogen.Message) {
	type row struct {
		name string
		opts string
	}
	var rows []row
	for _, oo := range m.Oneofs {
		if oo.Fields[0].Desc.HasOptionalKeyword() {
			continue
		}
		opts := w.renderOpts(oo.Desc.Options())
		if opts == "" {
			continue
		}
		rows = append(rows, row{name: string(oo.Desc.Name()), opts: opts})
	}
	if len(rows) == 0 {
		return
	}
	w.line("M.%s_descriptor.oneof_options = {", name)
	for _, r := range rows {
		w.line("    %s = %s,", luaTableKey(r.name), r.opts)
	}
	w.line("}")
}

// emitReservedNames emits `M.<Name>_descriptor.reserved_names = { ["x"] = true }`
// when the message declares any reserved field names. The text-format decoder
// uses this to silently drop fields named in `reserved "..."` declarations.
// Reserved field numbers are not emitted: unknown numeric IDs fall through the
// same drop path as truly unknown fields.
func emitReservedNames(w *writer, name string, m *protogen.Message) {
	rn := m.Desc.ReservedNames()
	if rn.Len() == 0 {
		return
	}
	w.line("M.%s_descriptor.reserved_names = {", name)
	for i := 0; i < rn.Len(); i++ {
		w.line("    [%q] = true,", string(rn.Get(i)))
	}
	w.line("}")
}

// renderFieldEntry produces the Lua table literal for a single field descriptor.
func renderFieldEntry(w *writer, file *protogen.File, f *protogen.Field, selfPath string, imports map[string]string, prefix string) string {
	parts := []string{
		fmt.Sprintf("name=%q", string(f.Desc.Name())),
		fmt.Sprintf("id=%d", f.Desc.Number()),
	}

	if f.Desc.IsMap() {
		parts = append(parts, "kind='map'")
		parts = append(parts, "key="+renderMapEntry(file, f.Message.Fields[0], selfPath, imports, prefix))
		parts = append(parts, "value="+renderMapEntry(file, f.Message.Fields[1], selfPath, imports, prefix))
		return "{" + strings.Join(parts, ", ") + "}"
	}

	switch {
	case f.Message != nil:
		// Proto2 `group` fields surface as a synthetic submessage whose
		// Kind is GroupKind. Wire format differs from a regular nested
		// message (SGROUP/EGROUP tag pair vs LEN prefix), so the codec
		// needs to dispatch on the kind.
		if f.Desc.Kind() == protoreflect.GroupKind {
			parts = append(parts, "kind='group'")
		} else {
			parts = append(parts, "kind='message'")
		}
		parts = append(parts, "message="+typeRef(file, f.Message.Desc, selfPath, imports, "_descriptor", prefix))
	case f.Enum != nil:
		parts = append(parts, "kind='enum'")
		parts = append(parts, "enum="+typeRef(file, f.Enum.Desc, selfPath, imports, "_descriptor", prefix))
	default:
		s := scalarName(f.Desc.Kind())
		if s == "" {
			panic("unhandled scalar kind: " + f.Desc.Kind().String())
		}
		parts = append(parts, "kind='scalar'")
		parts = append(parts, "proto_type="+strconv.Quote(s))
	}

	if f.Desc.IsList() {
		parts = append(parts, "repeated=true")
		// proto3 packed default for primitives + enums is true; explicit
		// `[packed=false]` flips it. IsPacked() returns the effective value.
		if f.Message == nil && f.Desc.Kind() != protoreflect.StringKind &&
			f.Desc.Kind() != protoreflect.BytesKind {
			if f.Desc.IsPacked() {
				parts = append(parts, "packed=true")
			} else {
				parts = append(parts, "packed=false")
			}
		}
	}

	// Oneof membership. (Skip synthetic oneofs that proto3 explicit `optional`
	// expands into — those are surfaced as `optional=true` instead.)
	if f.Oneof != nil && !f.Desc.HasOptionalKeyword() {
		parts = append(parts, fmt.Sprintf("oneof=%q", string(f.Oneof.Desc.Name())))
	}

	// Presence-tracked singular field. Proto3: explicit `optional` keyword
	// (synthetic-oneof wrapped). Proto2: every singular field declared
	// `optional` (and `required` — required fields also have presence).
	// Repeated/map already short-circuit above; messages don't need the
	// flag because the codec's message writer is presence-aware anyway.
	if f.Desc.HasOptionalKeyword() {
		parts = append(parts, "optional=true")
	}

	// Proto2 required cardinality. Codec validates on encode.
	if f.Desc.Cardinality() == protoreflect.Required {
		parts = append(parts, "required=true")
	}

	// Explicit `[default = X]` (proto2 only — proto3 has no custom defaults).
	if f.Desc.HasDefault() {
		parts = append(parts, "default_value="+renderDefaultValueLiteral(f))
	}

	if opts := w.renderOpts(f.Desc.Options()); opts != "" {
		parts = append(parts, "options="+opts)
	}

	return "{" + strings.Join(parts, ", ") + "}"
}

// collectExtsByExtendee walks every file the plugin knows about (input
// files plus dependencies) and groups extensions by extendee FullName.
// Used by the full-mode codegen to inline per-extension writers/readers
// in the generated _encode / _decode bodies — eliminates the
// pb.codec.encode_field / decode_extension dispatch for statically known
// extensions, while preserving the runtime registry for extensions
// registered after module load. Results are sorted by extension number
// so generated code stays deterministic.
func collectExtsByExtendee(plug *protogen.Plugin) map[string][]*protogen.Extension {
	out := map[string][]*protogen.Extension{}
	collect := func(exts []*protogen.Extension) {
		for _, e := range exts {
			if e.Extendee == nil {
				continue
			}
			fn := string(e.Extendee.Desc.FullName())
			out[fn] = append(out[fn], e)
		}
	}
	var walkMsgs func([]*protogen.Message)
	walkMsgs = func(ms []*protogen.Message) {
		for _, m := range ms {
			collect(m.Extensions)
			walkMsgs(m.Messages)
		}
	}
	for _, f := range plug.Files {
		collect(f.Extensions)
		walkMsgs(f.Messages)
	}
	for k := range out {
		list := out[k]
		sort.Slice(list, func(i, j int) bool {
			return list[i].Desc.Number() < list[j].Desc.Number()
		})
		out[k] = list
	}
	return out
}

// emitExtensions registers each proto2 extension with the extendee's
// descriptor at module-load time. Skipped for proto3 files (no extensions
// possible there).
func emitExtensions(w *writer, file *protogen.File, exts []*protogen.Extension, imports map[string]string, prefix string) {
	if len(exts) == 0 {
		return
	}
	selfPath := luaPackagePath(file.Desc, prefix)
	for _, ext := range exts {
		extendee := ext.Extendee
		if extendee == nil {
			continue
		}
		// Extensions on google.protobuf.* descriptors (file/message/field
		// options) are meta-only — they decorate the proto compilation
		// pipeline, not user wire bytes. Skip them: the WKT module
		// doesn't expose those descriptors at runtime, so attempting to
		// `pb.register_extension(nil, ...)` would crash module load.
		if isWellKnownTypeFile(extendee.Desc.ParentFile()) {
			continue
		}
		// Reference the extendee descriptor (possibly in another file).
		extendeeRef := typeRef(file, extendee.Desc, selfPath, imports, "_descriptor", prefix)
		shortName := string(ext.Desc.Name())
		fullName := string(ext.Desc.FullName())
		w.line("-- Extension: %s extends %s (tag %d)",
			fullName, extendee.Desc.FullName(), ext.Desc.Number())
		w.line("pb.register_extension(%s, %s)",
			extendeeRef, renderExtensionEntry(w, file, ext, selfPath, imports, prefix, shortName, fullName))
	}
	w.line("")
}

// renderExtensionEntry produces the Lua table literal for an extension's
// field descriptor. Mirrors renderFieldEntry but includes the extension's
// fully-qualified name and elides the `oneof` / `optional`-keyword paths
// (extensions are always presence-tracked, never in oneofs).
func renderExtensionEntry(w *writer, file *protogen.File, ext *protogen.Extension, selfPath string, imports map[string]string, prefix string, shortName, fullName string) string {
	parts := []string{
		fmt.Sprintf("name=%q", shortName),
		fmt.Sprintf("full_name=%q", fullName),
		fmt.Sprintf("id=%d", ext.Desc.Number()),
	}
	switch {
	case ext.Message != nil:
		if ext.Desc.Kind() == protoreflect.GroupKind {
			parts = append(parts, "kind='group'")
		} else {
			parts = append(parts, "kind='message'")
		}
		parts = append(parts, "message="+typeRef(file, ext.Message.Desc, selfPath, imports, "_descriptor", prefix))
	case ext.Enum != nil:
		parts = append(parts, "kind='enum'")
		parts = append(parts, "enum="+typeRef(file, ext.Enum.Desc, selfPath, imports, "_descriptor", prefix))
	default:
		s := scalarName(ext.Desc.Kind())
		if s == "" {
			panic("unhandled scalar kind for extension: " + ext.Desc.Kind().String())
		}
		parts = append(parts, "kind='scalar'")
		parts = append(parts, "proto_type="+strconv.Quote(s))
	}
	if ext.Desc.IsList() {
		parts = append(parts, "repeated=true")
		if ext.Message == nil && ext.Desc.Kind() != protoreflect.StringKind &&
			ext.Desc.Kind() != protoreflect.BytesKind {
			if ext.Desc.IsPacked() {
				parts = append(parts, "packed=true")
			} else {
				parts = append(parts, "packed=false")
			}
		}
	} else {
		// Singular extensions have presence by spec.
		parts = append(parts, "optional=true")
	}
	if ext.Desc.HasDefault() {
		parts = append(parts, "default_value="+renderExtensionDefault(ext))
	}
	if opts := w.renderOpts(ext.Desc.Options()); opts != "" {
		parts = append(parts, "options="+opts)
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

// renderExtensionDefault mirrors renderDefaultValueLiteral but for an
// extension's descriptor (different protogen wrapper).
func renderExtensionDefault(ext *protogen.Extension) string {
	v := ext.Desc.Default()
	switch ext.Desc.Kind() {
	case protoreflect.BoolKind:
		if v.Bool() {
			return "true"
		}
		return "false"
	case protoreflect.Int32Kind, protoreflect.Sint32Kind, protoreflect.Sfixed32Kind:
		return strconv.FormatInt(int64(int32(v.Int())), 10)
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind:
		return strconv.FormatUint(uint64(uint32(v.Uint())), 10)
	case protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		return strconv.FormatInt(v.Int(), 10) + "LL"
	case protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return strconv.FormatUint(v.Uint(), 10) + "ULL"
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		return formatLuaFloat(v.Float())
	case protoreflect.StringKind:
		return strconv.Quote(v.String())
	case protoreflect.BytesKind:
		return luaByteString(v.Bytes())
	case protoreflect.EnumKind:
		ev := ext.Enum.Desc.Values().ByNumber(v.Enum())
		if ev != nil {
			return strconv.Quote(string(ev.Name()))
		}
		return strconv.FormatInt(int64(v.Enum()), 10)
	}
	panic("renderExtensionDefault: unhandled kind " + ext.Desc.Kind().String())
}

// renderDefaultValueLiteral converts a field's proto2 default value to the
// Lua expression that materializes it. Matches the runtime convention:
// strings/bytes are quoted, 64-bit integers use LuaJIT cdata literals,
// enums use the symbolic name so codec lookups stay readable.
func renderDefaultValueLiteral(f *protogen.Field) string {
	v := f.Desc.Default()
	switch f.Desc.Kind() {
	case protoreflect.BoolKind:
		if v.Bool() {
			return "true"
		}
		return "false"
	case protoreflect.Int32Kind, protoreflect.Sint32Kind, protoreflect.Sfixed32Kind:
		return strconv.FormatInt(int64(int32(v.Int())), 10)
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind:
		return strconv.FormatUint(uint64(uint32(v.Uint())), 10)
	case protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		return strconv.FormatInt(v.Int(), 10) + "LL"
	case protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return strconv.FormatUint(v.Uint(), 10) + "ULL"
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		return formatLuaFloat(v.Float())
	case protoreflect.StringKind:
		return strconv.Quote(v.String())
	case protoreflect.BytesKind:
		return luaByteString(v.Bytes())
	case protoreflect.EnumKind:
		ev := f.Enum.Desc.Values().ByNumber(v.Enum())
		if ev != nil {
			return strconv.Quote(string(ev.Name()))
		}
		return strconv.FormatInt(int64(v.Enum()), 10)
	}
	panic("renderDefaultValueLiteral: unhandled kind " + f.Desc.Kind().String())
}

// renderMapEntry renders a sub-field descriptor for a map's key or value.
// It mirrors renderFieldEntry but always for a singular non-map value, and
// emits without the `name`/`id` (caller knows: id 1 = key, id 2 = value).
func renderMapEntry(file *protogen.File, f *protogen.Field, selfPath string, imports map[string]string, prefix string) string {
	parts := []string{}
	switch {
	case f.Message != nil:
		parts = append(parts, "kind='message'")
		parts = append(parts, "message="+typeRef(file, f.Message.Desc, selfPath, imports, "_descriptor", prefix))
	case f.Enum != nil:
		parts = append(parts, "kind='enum'")
		parts = append(parts, "enum="+typeRef(file, f.Enum.Desc, selfPath, imports, "_descriptor", prefix))
	default:
		s := scalarName(f.Desc.Kind())
		if s == "" {
			panic("unhandled map sub-field kind: " + f.Desc.Kind().String())
		}
		parts = append(parts, "kind='scalar'")
		parts = append(parts, "proto_type="+strconv.Quote(s))
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

// typeRef returns a Lua expression evaluating to the descriptor of the given
// type (a Message or Enum), resolving cross-file imports as needed.
func typeRef(file *protogen.File, td protoreflect.Descriptor, selfPath string, imports map[string]string, suffix string, prefix string) string {
	parent := td.ParentFile()
	if isWellKnownTypeFile(parent) {
		return "pb.wkt." + wktTypeName(td.FullName()) + suffix
	}
	luaName := luaTypeName(td.FullName(), parent.Package())
	parentPath := luaPackagePath(parent, prefix)
	if parentPath == selfPath {
		return "M." + luaName + suffix
	}
	alias, ok := imports[parentPath]
	if !ok {
		// Should be impossible if collectImports walked all fields.
		alias = importAlias(parentPath)
	}
	return alias + "." + luaName + suffix
}

// emitMessageWrappers emits the small _new / _encode / _decode helpers plus
// has_<field> / clear_<field> for each explicit-optional field.
//
// withDepth is set when the wrappers stand in for full-mode inline code:
// the inline decoders of other messages call them as `_decode(b, depth)`
// for a nested field, and the nesting level has to reach pb.codec for
// the recursion limit to hold. With the C runtime loaded the inline
// decoders never recurse in Lua, so pb.decode is used as usual.
func emitMessageWrappers(w *writer, file *protogen.File, m *protogen.Message, withDepth bool) {
	name := luaTypeName(m.Desc.FullName(), file.Desc.Package())
	full := emmyMessageFullName(m)

	emitEmmyWrapperAnnotations(w, name, full, wrapperNew)
	w.line("function M.%s_new(t) return t or {} end", name)
	emitEmmyWrapperAnnotations(w, name, full, wrapperEncode)
	w.line("function M.%s_encode(t) return pb.encode(M.%s_descriptor, t) end", name, name)
	emitEmmyWrapperAnnotations(w, name, full, wrapperDecode)
	if withDepth {
		for _, v := range []struct{ suffix, entry string }{
			{"_decode", "decode"}, {"_decode_unsafe", "decode_unsafe"},
		} {
			w.line("function M.%s%s(b, depth)", name, v.suffix)
			w.line("    if pb.c_runtime ~= nil then return pb.%s(M.%s_descriptor, b) end",
				v.entry, name)
			w.line("    return pb.codec.%s(M.%s_descriptor, b, depth)", v.entry, name)
			w.line("end")
		}
	} else {
		w.line("function M.%s_decode(b) return pb.decode(M.%s_descriptor, b) end", name, name)
		// API-symmetric unsafe-decode wrapper. Routes through
		// pb.decode_unsafe which uses the parallel `_reader_unsafe`
		// closures compiled in pb.finalize_message. Full mode emits
		// inline (a literal sister decoder); runtime mode shares one
		// dispatcher.
		w.line("function M.%s_decode_unsafe(b) return pb.decode_unsafe(M.%s_descriptor, b) end", name, name)
	}
	emitEmmyWrapperAnnotations(w, name, full, wrapperDecodeLazy)
	w.line("function M.%s_decode_lazy(b) return pb.decode_lazy(M.%s_descriptor, b) end", name, name)
	emitEmmyWrapperAnnotations(w, name, full, wrapperText)
	w.line("function M.%s_text(t, opts) return pb.text.encode(M.%s_descriptor, t, opts) end", name, name)
	emitOptionalAccessors(w, name, m, full)
	w.line("")
}

// emitOptionalAccessors writes M.<Name>_has_<field>(t) and _clear_<field>(t)
// for every field marked with proto3 explicit `optional`.
func emitOptionalAccessors(w *writer, name string, m *protogen.Message, fullName string) {
	for _, f := range m.Fields {
		if !f.Desc.HasOptionalKeyword() {
			continue
		}
		fname := string(f.Desc.Name())
		access := luaFieldAccess("t", fname)
		emitEmmyWrapperAnnotations(w, name, fullName, wrapperHas)
		w.line("function M.%s_has_%s(t) return %s ~= nil end", name, fname, access)
		emitEmmyWrapperAnnotations(w, name, fullName, wrapperClear)
		w.line("function M.%s_clear_%s(t) %s = nil end", name, fname, access)
	}
}

// ----------------------------------------------------------------------------
// Flattening helpers
// ----------------------------------------------------------------------------

// flattenMessages returns top-level + all nested messages in declaration order.
func flattenMessages(top []*protogen.Message, acc []*protogen.Message) []*protogen.Message {
	for _, m := range top {
		acc = append(acc, m)
		acc = flattenMessages(m.Messages, acc)
	}
	return acc
}

// flattenMessagesSkippingMapEntries is like flattenMessages but excludes the
// synthetic <Field>Entry messages protoc generates for `map<K,V>` fields.
// Those don't get their own Lua descriptor — map handling is inline.
func flattenMessagesSkippingMapEntries(top []*protogen.Message, acc []*protogen.Message) []*protogen.Message {
	for _, m := range top {
		if m.Desc.IsMapEntry() {
			continue
		}
		acc = append(acc, m)
		acc = flattenMessagesSkippingMapEntries(m.Messages, acc)
	}
	return acc
}

// flattenEnums returns top-level enums + all enums nested inside messages.
func flattenEnums(topEnums []*protogen.Enum, msgs []*protogen.Message) []*protogen.Enum {
	out := append([]*protogen.Enum{}, topEnums...)
	var walk func(ms []*protogen.Message)
	walk = func(ms []*protogen.Message) {
		for _, m := range ms {
			out = append(out, m.Enums...)
			walk(m.Messages)
		}
	}
	walk(msgs)
	return out
}
