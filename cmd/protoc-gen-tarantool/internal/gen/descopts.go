package gen

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/dynamicpb"
)

// optionsResolver re-links *Options messages so custom extensions defined
// inside an input .proto file are reachable to the protoreflect walker.
//
// Why this is needed: protogen builds each File's descriptor BEFORE in-file
// extensions get registered into its internal resolver. As a result,
// `file.Desc.Options()` (and the same for nested messages / fields /
// services / methods) parses options against a resolver that doesn't yet
// know the in-file extensions — those land silently in the unknown-fields
// bucket and don't surface via `Range`. The Plugin's re-marshal pass
// (`hasNovelExtensions`) only fixes `file.Proto`, which protogen.Message
// & co. don't expose.
//
// Workaround: build a single resolver carrying every extension defined in
// every input file (transitively — nested message extensions included), and
// re-decode each *Options message through it on demand. Marshal + unmarshal
// per options message is cheap (options are tiny).
type optionsResolver struct {
	types *protoregistry.Types
}

func newOptionsResolver(plug *protogen.Plugin) *optionsResolver {
	types := new(protoregistry.Types)
	for _, f := range plug.Files {
		registerExtensions(types, f.Desc)
	}
	return &optionsResolver{types: types}
}

// extensionContainer is the common slice of FileDescriptor / MessageDescriptor
// that exposes both extensions and nested messages.
type extensionContainer interface {
	Extensions() protoreflect.ExtensionDescriptors
	Messages() protoreflect.MessageDescriptors
}

func registerExtensions(types *protoregistry.Types, c extensionContainer) {
	exts := c.Extensions()
	for i := 0; i < exts.Len(); i++ {
		// Best-effort: an already-registered name (when two input files
		// re-import the same extension) returns AlreadyExists, which we
		// can safely ignore.
		_ = types.RegisterExtension(dynamicpb.NewExtensionType(exts.Get(i)))
	}
	msgs := c.Messages()
	for i := 0; i < msgs.Len(); i++ {
		registerExtensions(types, msgs.Get(i))
	}
}

// relink re-decodes an *Options message through the resolver so populated
// extensions move from the unknown-fields bucket into typed fields.
// Returns nil on a nil input.
func (r *optionsResolver) relink(opts proto.Message) (proto.Message, error) {
	if opts == nil {
		return nil, nil
	}
	if r == nil || r.types == nil {
		return opts, nil
	}
	b, err := proto.Marshal(opts)
	if err != nil {
		return nil, err
	}
	fresh := opts.ProtoReflect().Type().New().Interface()
	if err := (proto.UnmarshalOptions{Resolver: r.types}).Unmarshal(b, fresh); err != nil {
		return nil, err
	}
	return fresh, nil
}

// renderDescriptorOptions walks every populated field on a descriptor's
// *Options message and emits it as a Lua table literal `{key = value, ...}`.
//
// Returns "" when nothing is populated — callers must omit the `options`
// key entirely in that case (we never emit `options = {}`).
//
// The walker is generic: there are no extension-specific code paths. Every
// extension defined against any *Options message surfaces with the same
// shape, so consumers can pull whatever they care about (google.api.http,
// versionpb.etcd_version_*, in-house extensions) without pb knowing about it.
func renderDescriptorOptions(resolver *optionsResolver, opts proto.Message) (string, error) {
	if opts == nil {
		return "", nil
	}
	relinked, err := resolver.relink(opts)
	if err != nil {
		return "", err
	}
	msg := relinked.ProtoReflect()
	if !msg.IsValid() {
		return "", nil
	}
	return renderOptionsMessage(msg)
}

// optionEntry holds one populated field for sorted, deterministic emission.
type optionEntry struct {
	isExt bool
	// sortName: proto field name for standard fields, extension full name
	// for extensions. Lets us sort standard-then-extension, each alphabetical.
	sortName string
	// key is the Lua source for the key (`foo` or `["full.name"]`).
	key   string
	value string
}

func renderOptionsMessage(msg protoreflect.Message) (string, error) {
	var items []optionEntry
	var walkErr error

	msg.Range(func(fd protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		// UninterpretedOption is protoc's parser-internal slot. Once the
		// option's defining .proto is in the input set, the option lands
		// as a real extension and uninterpreted_option stays empty. A
		// populated entry means protoc couldn't resolve the extension —
		// surface that explicitly rather than emit opaque parser state.
		if !fd.IsExtension() && fd.Name() == "uninterpreted_option" {
			walkErr = fmt.Errorf(
				"%s carries unresolved UninterpretedOption %q — the "+
					"defining .proto for the extension must be in the "+
					"protoc input set (-I path)",
				msg.Descriptor().FullName(),
				describeUninterpreted(v))
			return false
		}
		val, err := renderOptionValue(fd, v)
		if err != nil {
			walkErr = err
			return false
		}
		var key, sortName string
		if fd.IsExtension() {
			key = fmt.Sprintf("[%q]", string(fd.FullName()))
			sortName = string(fd.FullName())
		} else {
			key = luaTableKey(string(fd.Name()))
			sortName = string(fd.Name())
		}
		items = append(items, optionEntry{
			isExt:    fd.IsExtension(),
			sortName: sortName,
			key:      key,
			value:    val,
		})
		return true
	})

	if walkErr != nil {
		return "", walkErr
	}
	if len(items) == 0 {
		return "", nil
	}

	// Deterministic ordering: standard fields first (alphabetical), then
	// extensions (alphabetical by full name).
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].isExt != items[j].isExt {
			return !items[i].isExt
		}
		return items[i].sortName < items[j].sortName
	})

	parts := make([]string, 0, len(items))
	for _, p := range items {
		parts = append(parts, p.key+" = "+p.value)
	}
	return "{" + strings.Join(parts, ", ") + "}", nil
}

// renderOptionValue handles cardinality (singular / repeated / map). Singular
// values are dispatched to renderOptionScalar.
func renderOptionValue(fd protoreflect.FieldDescriptor, v protoreflect.Value) (string, error) {
	switch {
	case fd.IsList():
		list := v.List()
		parts := make([]string, list.Len())
		for i := 0; i < list.Len(); i++ {
			s, err := renderOptionLeaf(fd, list.Get(i))
			if err != nil {
				return "", err
			}
			parts[i] = s
		}
		return "{" + strings.Join(parts, ", ") + "}", nil
	case fd.IsMap():
		// Map options are rare; emit `{[k] = v, ...}` sorted by stringified
		// key for stable output.
		m := v.Map()
		keyFD := fd.MapKey()
		valFD := fd.MapValue()
		type kv struct{ k, v string }
		var pairs []kv
		var err error
		m.Range(func(mk protoreflect.MapKey, mv protoreflect.Value) bool {
			ks, e := renderOptionLeaf(keyFD, mk.Value())
			if e != nil {
				err = e
				return false
			}
			vs, e := renderOptionLeaf(valFD, mv)
			if e != nil {
				err = e
				return false
			}
			pairs = append(pairs, kv{ks, vs})
			return true
		})
		if err != nil {
			return "", err
		}
		sort.Slice(pairs, func(i, j int) bool { return pairs[i].k < pairs[j].k })
		parts := make([]string, len(pairs))
		for i, p := range pairs {
			parts[i] = "[" + p.k + "] = " + p.v
		}
		return "{" + strings.Join(parts, ", ") + "}", nil
	}
	return renderOptionLeaf(fd, v)
}

// renderOptionLeaf renders a single (non-list, non-map) value.
func renderOptionLeaf(fd protoreflect.FieldDescriptor, v protoreflect.Value) (string, error) {
	switch fd.Kind() {
	case protoreflect.BoolKind:
		if v.Bool() {
			return "true", nil
		}
		return "false", nil
	case protoreflect.Int32Kind, protoreflect.Sint32Kind, protoreflect.Sfixed32Kind:
		return strconv.FormatInt(int64(int32(v.Int())), 10), nil
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind:
		return strconv.FormatUint(uint64(uint32(v.Uint())), 10), nil
	case protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		// LuaJIT cdata literal — matches the convention pb decoders use
		// for proto3 int64 fields.
		return strconv.FormatInt(v.Int(), 10) + "LL", nil
	case protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return strconv.FormatUint(v.Uint(), 10) + "ULL", nil
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		return formatLuaFloat(v.Float()), nil
	case protoreflect.StringKind:
		return strconv.Quote(v.String()), nil
	case protoreflect.BytesKind:
		return luaByteString(v.Bytes()), nil
	case protoreflect.EnumKind:
		ev := fd.Enum().Values().ByNumber(v.Enum())
		if ev != nil {
			return strconv.Quote(string(ev.Name())), nil
		}
		return strconv.FormatInt(int64(v.Enum()), 10), nil
	case protoreflect.MessageKind, protoreflect.GroupKind:
		nested, err := renderOptionsMessage(v.Message())
		if err != nil {
			return "", err
		}
		if nested == "" {
			// Message-valued option with all fields defaulted — emit `{}`
			// so the option's presence remains visible to consumers.
			return "{}", nil
		}
		return nested, nil
	}
	return "", fmt.Errorf("unsupported option kind: %s", fd.Kind())
}

// formatLuaFloat renders a Go float64 as Lua source. NaN/Inf get the
// idiomatic Lua expressions instead of strconv's "NaN"/"+Inf" tokens.
func formatLuaFloat(f float64) string {
	switch {
	case math.IsNaN(f):
		return "0/0"
	case math.IsInf(f, 1):
		return "math.huge"
	case math.IsInf(f, -1):
		return "-math.huge"
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// mustRenderOptions is the panic-on-error variant for hot codegen sites
// where threading an error return would balloon every emit signature.
// A populated UninterpretedOption (the only error we surface) is a
// codegen-time invariant violation — failing loudly via the plugin's
// panic handler is the right escalation.
func mustRenderOptions(resolver *optionsResolver, opts proto.Message) string {
	s, err := renderDescriptorOptions(resolver, opts)
	if err != nil {
		panic("tarantool-protobuf: " + err.Error())
	}
	return s
}

// describeUninterpreted formats UninterpretedOption.name parts into the
// proto dotted-identifier form so the codegen error tells the user
// exactly which option went unresolved.
func describeUninterpreted(v protoreflect.Value) string {
	list := v.List()
	if list.Len() == 0 {
		return "(empty)"
	}
	first := list.Get(0).Message()
	desc := first.Descriptor()
	nameFD := desc.Fields().ByName("name")
	if nameFD == nil {
		return "(unknown)"
	}
	parts := first.Get(nameFD).List()
	var sb strings.Builder
	partDesc := nameFD.Message()
	partNameFD := partDesc.Fields().ByName("name_part")
	partExtFD := partDesc.Fields().ByName("is_extension")
	for i := 0; i < parts.Len(); i++ {
		part := parts.Get(i).Message()
		if i > 0 {
			sb.WriteByte('.')
		}
		isExt := partExtFD != nil && part.Get(partExtFD).Bool()
		if isExt {
			sb.WriteByte('(')
		}
		sb.WriteString(part.Get(partNameFD).String())
		if isExt {
			sb.WriteByte(')')
		}
	}
	return sb.String()
}
