// protoc-gen-tarantool-doc generates Markdown reference documentation from
// proto3 .proto files. One Markdown file per input proto, named after the
// proto file (foo.proto -> foo.md). Output mirrors protoc's path layout
// relative to the -I directory.
//
// Usage:
//   protoc --tarantool-doc_out=./docs \
//          --plugin=./protoc-gen-tarantool-doc foo.proto
//
// Output sections (in order, omitted when empty):
//   - Header with package + imports
//   - Messages (per-message: leading comment, fields table, oneofs, nested)
//   - Enums (per-enum: leading comment, values table)
//   - Services (per-service: leading comment, methods table)
//
// Leading comments on messages/enums/fields/services/methods are preserved
// from SourceCodeInfo via protogen.
package main

import (
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/pluginpb"

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

	// Inject a synthetic go_package so protogen accepts the input even when
	// none of the files declare one (same trick as the codegen plugin).
	for _, f := range req.ProtoFile {
		if f.Options == nil {
			f.Options = &descriptorpb.FileOptions{}
		}
		if f.Options.GoPackage == nil {
			stub := "tarantooldoc_synthetic/" + strings.TrimSuffix(f.GetName(), ".proto")
			f.Options.GoPackage = proto.String(stub)
		}
	}

	// protobuf-go cannot load a MessageSet declaration. The option has no
	// bearing on the reference docs, so it is simply dropped.
	messageset.Strip(req)

	plugin, err := protogen.Options{}.New(req)
	if err != nil {
		fail("init protogen: %v", err)
	}
	plugin.SupportedFeatures = uint64(pluginpb.CodeGeneratorResponse_FEATURE_PROTO3_OPTIONAL)

	for _, file := range plugin.Files {
		if !file.Generate {
			continue
		}
		writeFile(plugin, file)
	}

	out, err := proto.Marshal(plugin.Response())
	if err != nil {
		fail("marshal CodeGeneratorResponse: %v", err)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		fail("write stdout: %v", err)
	}
}

func writeFile(plugin *protogen.Plugin, file *protogen.File) {
	base := strings.TrimSuffix(path.Base(file.Desc.Path()), ".proto") + ".md"
	relDir := path.Dir(file.Desc.Path())
	outPath := base
	if relDir != "" && relDir != "." {
		outPath = path.Join(relDir, base)
	}
	g := plugin.NewGeneratedFile(outPath, "")

	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", file.Desc.Path())
	if pkg := file.Desc.Package(); pkg != "" {
		fmt.Fprintf(&b, "**Package:** `%s`\n\n", pkg)
	}

	if imports := file.Desc.Imports(); imports.Len() > 0 {
		b.WriteString("**Imports:**\n\n")
		for i := 0; i < imports.Len(); i++ {
			fmt.Fprintf(&b, "- `%s`\n", imports.Get(i).Path())
		}
		b.WriteString("\n")
	}

	if len(file.Messages) > 0 {
		b.WriteString("## Messages\n\n")
		for _, m := range file.Messages {
			renderMessage(&b, m, 3)
		}
	}

	if len(file.Enums) > 0 {
		b.WriteString("## Enums\n\n")
		for _, e := range file.Enums {
			renderEnum(&b, e, 3)
		}
	}

	if len(file.Services) > 0 {
		b.WriteString("## Services\n\n")
		for _, s := range file.Services {
			renderService(&b, s)
		}
	}

	g.P(b.String())
}

// ----- rendering helpers ----------------------------------------------------

func heading(level int) string { return strings.Repeat("#", level) + " " }

func cleanComment(c protogen.Comments) string {
	// protogen.Comments leaves each line with a leading space and trailing
	// newline. Strip these and join with single newlines.
	raw := strings.TrimRight(string(c), "\n")
	if raw == "" {
		return ""
	}
	lines := strings.Split(raw, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimSpace(strings.TrimPrefix(l, " "))
	}
	return strings.Join(lines, " ")
}

// renderMessage emits a section for one message and recurses into nested
// types. `level` controls Markdown heading depth.
func renderMessage(b *strings.Builder, m *protogen.Message, level int) {
	// Skip synthetic map-entry messages.
	if m.Desc.IsMapEntry() {
		return
	}

	full := string(m.Desc.FullName())
	fmt.Fprintf(b, "%s`%s`\n\n", heading(level), full)
	if c := cleanComment(m.Comments.Leading); c != "" {
		fmt.Fprintf(b, "%s\n\n", c)
	}

	// Collect oneof groupings to annotate fields.
	oneofByField := map[string]string{}
	for _, oo := range m.Oneofs {
		if oo.Desc.IsSynthetic() {
			continue
		}
		for _, f := range oo.Fields {
			oneofByField[string(f.Desc.Name())] = string(oo.Desc.Name())
		}
	}

	if len(m.Fields) > 0 {
		b.WriteString("| # | Field | Type | Label | Description |\n")
		b.WriteString("|---|-------|------|-------|-------------|\n")
		// Display in declaration order.
		fields := append([]*protogen.Field(nil), m.Fields...)
		sort.SliceStable(fields, func(i, j int) bool {
			return fields[i].Desc.Number() < fields[j].Desc.Number()
		})
		for _, f := range fields {
			fmt.Fprintf(b, "| %d | `%s` | %s | %s | %s |\n",
				f.Desc.Number(),
				f.Desc.Name(),
				fieldTypeText(f),
				labelText(f, oneofByField[string(f.Desc.Name())]),
				inlineComment(f.Comments.Leading))
		}
		b.WriteString("\n")
	}

	// Recurse into nested messages and enums under deeper headings.
	for _, nm := range m.Messages {
		renderMessage(b, nm, level+1)
	}
	for _, ne := range m.Enums {
		renderEnum(b, ne, level+1)
	}
}

func renderEnum(b *strings.Builder, e *protogen.Enum, level int) {
	fmt.Fprintf(b, "%s`%s`\n\n", heading(level), e.Desc.FullName())
	if c := cleanComment(e.Comments.Leading); c != "" {
		fmt.Fprintf(b, "%s\n\n", c)
	}
	b.WriteString("| Value | Name | Description |\n")
	b.WriteString("|-------|------|-------------|\n")
	for _, v := range e.Values {
		fmt.Fprintf(b, "| %d | `%s` | %s |\n",
			v.Desc.Number(),
			v.Desc.Name(),
			inlineComment(v.Comments.Leading))
	}
	b.WriteString("\n")
}

func renderService(b *strings.Builder, s *protogen.Service) {
	fmt.Fprintf(b, "### `%s`\n\n", s.Desc.FullName())
	if c := cleanComment(s.Comments.Leading); c != "" {
		fmt.Fprintf(b, "%s\n\n", c)
	}
	if len(s.Methods) == 0 {
		return
	}
	b.WriteString("| Method | Request | Response | Streaming | Description |\n")
	b.WriteString("|--------|---------|----------|-----------|-------------|\n")
	for _, m := range s.Methods {
		streaming := streamingText(m)
		fmt.Fprintf(b, "| `%s` | `%s` | `%s` | %s | %s |\n",
			m.Desc.Name(),
			m.Desc.Input().FullName(),
			m.Desc.Output().FullName(),
			streaming,
			inlineComment(m.Comments.Leading))
	}
	b.WriteString("\n")
}

// fieldTypeText renders a field's type as a Markdown fragment. Scalars stay
// lowercase; messages/enums become full-name code spans. Map fields render
// as `map<K, V>`.
func fieldTypeText(f *protogen.Field) string {
	d := f.Desc
	if d.IsMap() {
		return fmt.Sprintf("`map<%s, %s>`",
			scalarOrName(d.MapKey()),
			scalarOrName(d.MapValue()))
	}
	return "`" + scalarOrName(d) + "`"
}

// scalarOrName resolves a FieldDescriptor's type as either the lowercase
// proto3 scalar name or the full name of the referenced message/enum.
func scalarOrName(d protoreflect.FieldDescriptor) string {
	switch d.Kind() {
	case protoreflect.MessageKind, protoreflect.GroupKind:
		return string(d.Message().FullName())
	case protoreflect.EnumKind:
		return string(d.Enum().FullName())
	}
	return d.Kind().String()
}

func labelText(f *protogen.Field, oneof string) string {
	parts := []string{}
	d := f.Desc
	if d.IsList() && !d.IsMap() {
		parts = append(parts, "repeated")
	}
	if d.HasOptionalKeyword() {
		parts = append(parts, "optional")
	}
	if oneof != "" {
		parts = append(parts, fmt.Sprintf("oneof `%s`", oneof))
	}
	if len(parts) == 0 {
		return "—"
	}
	return strings.Join(parts, ", ")
}

func streamingText(m *protogen.Method) string {
	cs := m.Desc.IsStreamingClient()
	ss := m.Desc.IsStreamingServer()
	switch {
	case cs && ss:
		return "bidi"
	case cs:
		return "client"
	case ss:
		return "server"
	}
	return "unary"
}

// inlineComment squashes a leading comment to a single line for use inside a
// Markdown table cell (newlines and pipes break table rendering). Empty
// comments render as an em-dash to keep the column non-empty.
func inlineComment(c protogen.Comments) string {
	s := cleanComment(c)
	if s == "" {
		return "—"
	}
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\n", " ")
	return s
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "protoc-gen-tarantool-doc: "+format+"\n", args...)
	os.Exit(1)
}
