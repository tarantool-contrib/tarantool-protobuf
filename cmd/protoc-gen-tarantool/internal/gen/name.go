package gen

import (
	"fmt"
	"path"
	"strings"

	"google.golang.org/protobuf/reflect/protoreflect"
)

// luaReservedWords is the frozen set of Lua 5.1 / LuaJIT keywords. A proto
// field whose name collides with one of these can't be emitted as a bare
// identifier in generated Lua — table-key form and bracket-index form
// must be used instead. See luaTableKey / luaFieldAccess.
var luaReservedWords = map[string]bool{
	"and": true, "break": true, "do": true, "else": true,
	"elseif": true, "end": true, "false": true, "for": true,
	"function": true, "goto": true, "if": true, "in": true,
	"local": true, "nil": true, "not": true, "or": true,
	"repeat": true, "return": true, "then": true, "true": true,
	"until": true, "while": true,
}

func isLuaReservedWord(name string) bool { return luaReservedWords[name] }

func isValidLuaIdentifier(name string) bool {
	if name == "" {
		return false
	}
	for i, r := range name {
		switch {
		case r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
		case i > 0 && r >= '0' && r <= '9':
		default:
			return false
		}
	}
	return true
}

// luaTableKey returns a representation of `name` valid as a Lua table key.
// Bare identifier when the name is a valid Lua identifier and not reserved;
// bracket-quoted form otherwise.
func luaTableKey(name string) string {
	if isLuaReservedWord(name) || !isValidLuaIdentifier(name) {
		return fmt.Sprintf("[%q]", name)
	}
	return name
}

// luaFieldAccess returns Lua source for `<receiver>.<name>`, falling back
// to `<receiver>[<name:q>]` when `name` is a Lua keyword or otherwise
// invalid as a bare identifier.
func luaFieldAccess(receiver, name string) string {
	if isLuaReservedWord(name) || !isValidLuaIdentifier(name) {
		return fmt.Sprintf("%s[%q]", receiver, name)
	}
	return fmt.Sprintf("%s.%s", receiver, name)
}

// luaPackagePath returns the dotted Lua require path for a generated file.
//
// Resolution order:
//  1. file option (tarantool.lua_package), used as-is
//  2. proto package + file basename + "_pb"
//     e.g. package=foo.bar, file=baz.proto -> "foo.bar.baz_pb"
//  3. file basename only (when proto package is empty)
//     e.g. file=baz.proto -> "baz_pb"
func luaPackagePath(f protoreflect.FileDescriptor, prefix string) string {
	var p string
	if v := luaPackageOption(f); v != "" {
		p = v
	} else {
		base := strings.TrimSuffix(path.Base(f.Path()), ".proto") + "_pb"
		if pkg := string(f.Package()); pkg != "" {
			p = pkg + "." + base
		} else {
			p = base
		}
	}
	if prefix != "" {
		return prefix + "." + p
	}
	return p
}

// outputFilename returns the on-disk path (relative to the protoc out dir)
// for a generated file. Mirrors the dotted Lua require path with `/`-separators
// and a `.lua` extension.
//
// For example, lua package "myapp.proto.foo" -> "myapp/proto/foo.lua".
func outputFilename(f protoreflect.FileDescriptor, prefix string) string {
	return strings.ReplaceAll(luaPackagePath(f, prefix), ".", "/") + ".lua"
}

// luaTypeName returns the underscore-flattened type name used in generated
// Lua module tables. Strips the leading proto-package prefix.
//
// Examples (assuming file package = "foo.bar"):
//   foo.bar.Person          -> "Person"
//   foo.bar.Outer.Inner     -> "Outer_Inner"
//   foo.bar.Color           -> "Color"
func luaTypeName(fullName protoreflect.FullName, filePkg protoreflect.FullName) string {
	s := string(fullName)
	if filePkg != "" {
		prefix := string(filePkg) + "."
		s = strings.TrimPrefix(s, prefix)
	}
	return strings.ReplaceAll(s, ".", "_")
}

// importAlias produces a stable Lua local-variable name for a required module.
// It dot-separates the module path and joins with underscores, prefixed with
// "_imp_" to avoid clashing with user identifiers.
//
//	"myapp.proto.foo" -> "_imp_myapp_proto_foo"
func importAlias(luaPath string) string {
	return "_imp_" + strings.ReplaceAll(luaPath, ".", "_")
}

// isWellKnownTypeFile reports whether the file declares Google's
// google.protobuf.* well-known types. Those are fulfilled by `pb.wkt`
// at runtime and don't need a separate generated module.
func isWellKnownTypeFile(fd protoreflect.FileDescriptor) bool {
	return string(fd.Package()) == "google.protobuf"
}

// wktTypeName strips the `google.protobuf.` prefix from a WKT type's full
// name. Example: "google.protobuf.Timestamp" -> "Timestamp".
func wktTypeName(full protoreflect.FullName) string {
	return strings.TrimPrefix(string(full), "google.protobuf.")
}

