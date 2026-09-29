package gen

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// decodeFnSuffix returns "_n" when the int64_as_number option is set
// and `st` is one of the cdata-returning 64-bit scalar kinds, "" otherwise.
// Used to swap wire.decode_int64 -> wire.decode_int64_n at codegen sites
// where the value type is statically known.
func decodeFnSuffix(w *writer, st string) string {
	if !w.int64AsNumber {
		return ""
	}
	switch st {
	case "int64", "uint64", "sint64", "fixed64", "sfixed64":
		return "_n"
	}
	return ""
}

// encodeCallExpr returns the Lua expression that encodes a single value
// of the given scalar type `st`. For types where mode=full can elide
// wire.to_int64 / wire.to_uint64's runtime type dispatch (sint64, fixed64,
// sfixed64), the expression pre-casts the value to int64_t / uint64_t at
// the call site and routes through the typed fast variant (encode_sint64_i
// / encode_fixed64_u / encode_sfixed64_u). For everything else it emits
// the generic wire.encode_<st> call. INT64 and UINT64 are localized in
// the file header (see emitHeader).
func encodeCallExpr(st, valExpr string) string {
	switch st {
	case "sint64":
		return fmt.Sprintf("wire.encode_sint64_i(INT64(%s))", valExpr)
	case "fixed64":
		return fmt.Sprintf("wire.encode_fixed64_u(UINT64(%s))", valExpr)
	case "sfixed64":
		return fmt.Sprintf("wire.encode_sfixed64_u(UINT64(%s))", valExpr)
	}
	return fmt.Sprintf("wire.encode_%s(%s)", st, valExpr)
}

// wireRefRe matches `wire.<name>` references inside generated function
// bodies. Generated code never embeds `wire.` inside a string literal, so a
// straight textual sweep is safe here. (Verified: error messages mention
// "wire type" with a space, no dot.)
var wireRefRe = regexp.MustCompile(`\bwire\.([A-Za-z_][A-Za-z0-9_]*)`)

// localizeWireRefs scans `body` for `wire.<name>` references and, for any
// name that appears at least `minUses` times, returns it (sorted) and
// rewrites those occurrences in `body` to the bare name. Caller is
// responsible for emitting `local <name> = wire.<name>` lines for the
// returned refs before flushing the body. Names that occur fewer than
// `minUses` times are left as `wire.<name>` so we don't pay a prelude
// TGETS on every call to save a single in-body lookup.
//
// Why: each `wire.X` access is a hash lookup on the `wire` upvalue.
// LuaJIT hoists it when traces stay hot, but every nested-message
// boundary breaks the trace and re-pays the lookup in the side trace /
// interpreter. Localizing turns each in-body call into a bare local read
// with no table indirection. Measured 35-50% improvements
// on scalar-heavy / packed_int32 workloads where wire.* dominates the
// inner loop; the single-use guard prevents a regression on sparse
// small-message decode where the prelude cost outweighs the in-body
// savings.
func localizeWireRefs(body []string, minUses int) (refs []string, rewritten []string) {
	count := map[string]int{}
	for _, ln := range body {
		for _, m := range wireRefRe.FindAllStringSubmatch(ln, -1) {
			count[m[1]]++
		}
	}
	keep := map[string]struct{}{}
	for n, c := range count {
		if c >= minUses {
			keep[n] = struct{}{}
		}
	}
	if len(keep) == 0 {
		return nil, body
	}
	refs = make([]string, 0, len(keep))
	for n := range keep {
		refs = append(refs, n)
	}
	sort.Strings(refs)
	// Only rewrite the kept names; one-shot refs stay as `wire.X` so we
	// don't end up referring to a local that was never declared.
	keepRe := regexp.MustCompile(`\bwire\.(` + strings.Join(refs, "|") + `)\b`)
	rewritten = make([]string, len(body))
	for i, ln := range body {
		rewritten[i] = keepRe.ReplaceAllString(ln, "$1")
	}
	return refs, rewritten
}

// emitLocalizedFunction emits the function header, the captured body with
// frequently-used wire.* references rewritten to bare locals (and the
// corresponding `local <name> = wire.<name>` preamble), and the closing
// `end` line. The `minUses` threshold of 2 means a wire ref needs at
// least one repeat use to be worth the prelude allocation.
func emitLocalizedFunction(w *writer, header string, bodyFn func()) {
	body := w.captureLines(bodyFn)
	refs, body := localizeWireRefs(body, 2)
	w.line("%s", header)
	for _, name := range refs {
		w.line("    local %s = wire.%s", name, name)
	}
	for _, ln := range body {
		w.P(ln)
	}
	w.line("end")
	w.line("")
}

// emitInlineMessage emits per-message _new / _encode / _decode functions with
// no descriptor dispatch. Tag bytes are precomputed as Lua string literals;
// each scalar field's encode/decode call resolves to one wire.<typed> call.
// `exts` is the list of statically-known extensions targeting this message
// (collected via collectExtsByExtendee across all input files). They are
// inlined into the emitted encode/decode bodies so the hot path skips the
// pb.codec.encode_field / decode_extension dispatch.
func emitInlineMessage(w *writer, file *protogen.File, m *protogen.Message, imports map[string]string, prefix string, exts []*protogen.Extension) {
	name := luaTypeName(m.Desc.FullName(), file.Desc.Package())
	full := emmyMessageFullName(m)
	selfPath := luaPackagePath(file.Desc, prefix)

	emitEmmyWrapperAnnotations(w, name, full, wrapperNew)
	w.line("function M.%s_new(t) return t or {} end", name)
	w.line("")

	emitInlineEncode(w, name, m, file, selfPath, imports, prefix, exts)
	emitInlineDecode(w, name, m, file, selfPath, imports, prefix, exts, true)
	emitInlineDecode(w, name, m, file, selfPath, imports, prefix, exts, false)
	emitEmmyWrapperAnnotations(w, name, full, wrapperDecodeLazy)
	w.line("function M.%s_decode_lazy(b) return pb.decode_lazy(M.%s_descriptor, b) end", name, name)
	emitEmmyWrapperAnnotations(w, name, full, wrapperText)
	w.line("function M.%s_text(t, opts) return pb.text.encode(M.%s_descriptor, t, opts) end", name, name)
	emitOptionalAccessors(w, name, m, full)
	w.line("")
}

func emitInlineEncode(w *writer, name string, m *protogen.Message, file *protogen.File, selfPath string, imports map[string]string, prefix string, exts []*protogen.Extension) {
	emitEmmyWrapperAnnotations(w, name, emmyMessageFullName(m), wrapperEncode)
	emitLocalizedFunction(w, fmt.Sprintf("function M.%s_encode(t)", name), func() {
		// C-acceleration: when PB_ENABLE_C=1 was set at module load, dispatch
		// into pb.c_runtime.encode. Plan compilation is lazy on first call —
		// eager compile would chase sub-message refs that aren't filled in
		// yet when finalize_message runs at module load (see init.lua). On
		// the default pure-Lua build pb.c_runtime is nil and the branch is a
		// single nil-compare.
		w.line("    local _d = M.%s_descriptor", name)
		w.line("    if pb.c_runtime ~= nil then")
		w.line("        local _p = _d.c_plan or pb.c_runtime.compile_plan(_d)")
		w.line("        return pb.c_runtime.encode(_p, t)")
		w.line("    end")
		w.line("    if type(t) ~= 'table' then")
		w.line("        error(\"expected table for %s, got \" .. type(t), 0)", m.Desc.FullName())
		w.line("    end")
		w.line("    local out, n = {}, 0")
		w.line("    local v")

		// Oneof pre-pass: pick the active branch per oneof (last-set wins).
		for _, oo := range realOneofs(m) {
			w.line("    local %s", oneofVar(string(oo.Desc.Name())))
			for _, f := range oo.Fields {
				w.line("    if %s ~= nil then %s = %q end",
					luaFieldAccess("t", string(f.Desc.Name())),
					oneofVar(string(oo.Desc.Name())),
					string(f.Desc.Name()))
			}
		}

		for _, f := range m.Fields {
			emitInlineEncodeField(w, f, file, selfPath, imports, prefix)
		}
		// Proto2 extensions. Static extensions (those visible at codegen
		// time) are inlined as dedicated writers — same hot-path quality
		// as a regular field. The dynamic walk over extensions_list[N+1..]
		// catches anything registered via pb.register_extension after
		// module load; `#extensions_list > N` short-circuits when no
		// runtime extension was added, which is the common case (every
		// known caller defines extensions in the .proto, not at runtime).
		// Skip entirely when no extension targets this message — most
		// proto3 messages and proto2 messages without `extensions` ranges.
		if len(exts) > 0 {
			w.line("    local _exts = t._extensions")
			w.line("    if _exts ~= nil then")
			// Single re-used local for each extension's value, matching the
			// pattern in emitInlineEncode for regular fields (`local v` at
			// the top).
			w.line("        local _ev")
			for _, ext := range exts {
				emitInlineEncodeExtension(w, ext, file, selfPath, imports, prefix)
			}
			w.line("    end")
			w.line("    local _elist = M.%s_descriptor.extensions_list", name)
			w.line("    if _elist ~= nil and #_elist > %d then", len(exts))
			w.line("        local _exts2 = t._extensions")
			w.line("        if _exts2 ~= nil then")
			w.line("            for _i = %d, #_elist do", len(exts)+1)
			w.line("                local _ext = _elist[_i]")
			w.line("                local _ev = _exts2[_ext.full_name]")
			w.line("                if _ev ~= nil then")
			w.line("                    pb.codec.encode_field(_ext, _ev, out, true)")
			w.line("                end")
			w.line("            end")
			// encode_field uses out[#out + 1] = … and doesn't know
			// about our local `n` cursor — resync so the unknown-fields
			// append below lands after the extension bytes, not on top.
			w.line("            n = #out")
			w.line("        end")
			w.line("    end")
		}
		// Preserve unknown fields captured at decode time.
		w.line("    local _uf = t._unknown_fields")
		w.line("    if _uf ~= nil and _uf ~= '' then n = n + 1; out[n] = _uf end")
		w.line("    return table.concat(out)")
	})
}

// emitInlineLenPrefix emits the length-prefix append for a length-delimited
// field (LEN wire type: string, bytes, message body, packed scalars).
//
// Lifts the 1-byte varint fast path out of wire.encode_varint and inlines it
// at the call site. Eliminates the function call + dispatch on the dominant
// short-payload case (length < 128). encode_varint dispatch alone was ~17%
// of encode time on the hello.Person 1KB benchmark before this; the
// surrounding `out[n] = wire.encode_varint(#_b)` was another ~33%.
//
// `indent` is the Lua indentation string (e.g. "    " or "        ") that
// each emitted line starts with. `bodyExpr` is the Lua expression for the
// payload local (typically "v" or "_b"); its length is read once into a
// local so `#bodyExpr` doesn't re-evaluate. Caller is responsible for
// emitting the tag and the body itself around this call.
func emitInlineLenPrefix(w *writer, indent, bodyExpr string) {
	w.line("%slocal _len = #%s", indent, bodyExpr)
	w.line("%sif _len < 128 then", indent)
	w.line("%s    n = n + 1; out[n] = CHARS[_len]", indent)
	w.line("%selse", indent)
	w.line("%s    n = n + 1; out[n] = wire.encode_varint(_len)", indent)
	w.line("%send", indent)
}

// emitPackedVarintElemDecode emits the per-element decode inside a packed
// varint loop, with 1-byte and 2-byte fast paths inlined for the common
// Lua-number-returning scalar types (int32/uint32/enum/bool). The 2-byte
// branch covers values 128..16383 — the range that drives the residual
// side-trace bridges from the packed-int32 inner loop (see ozn). For
// other types (int64/uint64/sint*/cdata returns) the helper just emits
// the existing wire.decode_<st> call so the call frame stays.
//
// `valExpr` is the lvalue Lua expression for the decoded value (e.g.
// `val`, `list[cnt]`). `indent` is the Lua indentation prefix.
//
// For `enum`, the value is an int32 and bypasses wire.varint_to_int32
// in the inlined branches since 2-byte values 128..16383 fit int32
// directly; the fallback call still wraps with varint_to_int32.
func emitPackedVarintElemDecode(w *writer, indent, st, valExpr string) {
	switch st {
	case "int32", "uint32":
		w.line("%slocal _b = string_byte(payload, p2)", indent)
		w.line("%sif _b ~= nil and _b < 0x80 then", indent)
		w.line("%s    %s = _b", indent, valExpr)
		w.line("%s    p2 = p2 + 1", indent)
		w.line("%selseif _b ~= nil and p2 < lim then", indent)
		w.line("%s    local _b2 = string_byte(payload, p2 + 1)", indent)
		w.line("%s    if _b2 ~= nil and _b2 < 0x80 then", indent)
		w.line("%s        if _b2 == 0 then error(\"overlong varint at offset \" .. p2, 0) end", indent)
		w.line("%s        %s = _b - 128 + _b2 * 128", indent, valExpr)
		w.line("%s        p2 = p2 + 2", indent)
		w.line("%s    else", indent)
		w.line("%s        %s, p2 = wire.decode_%s%s(payload, p2)", indent, valExpr, st, decodeFnSuffix(w, st))
		w.line("%s    end", indent)
		w.line("%selse", indent)
		w.line("%s    %s, p2 = wire.decode_%s%s(payload, p2)", indent, valExpr, st, decodeFnSuffix(w, st))
		w.line("%send", indent)
	case "bool":
		// Bool values are spec-valid only as 0 or 1, always 1-byte on the wire.
		// A 2-byte form would be either overlong-0 or out-of-range. Keep just
		// the 1-byte fast path and let any anomaly fall through to wire.decode_bool.
		w.line("%slocal _b = string_byte(payload, p2)", indent)
		w.line("%sif _b ~= nil and _b < 0x80 then", indent)
		w.line("%s    %s = _b ~= 0", indent, valExpr)
		w.line("%s    p2 = p2 + 1", indent)
		w.line("%selse", indent)
		w.line("%s    %s, p2 = wire.decode_bool(payload, p2)", indent, valExpr)
		w.line("%send", indent)
	default:
		w.line("%s%s, p2 = wire.decode_%s%s(payload, p2)", indent, valExpr, st, decodeFnSuffix(w, st))
	}
}

// emitPackedEnumElemDecode is the enum counterpart to
// emitPackedVarintElemDecode. Enum payload is a varint reinterpreted as
// int32; for values 0..16383 the 1-byte and 2-byte fast paths bypass
// wire.varint_to_int32 since the result already fits the int32 range.
func emitPackedEnumElemDecode(w *writer, indent, valExpr string) {
	w.line("%slocal _b = string_byte(payload, p2)", indent)
	w.line("%sif _b ~= nil and _b < 0x80 then", indent)
	w.line("%s    %s = _b", indent, valExpr)
	w.line("%s    p2 = p2 + 1", indent)
	w.line("%selseif _b ~= nil and p2 < lim then", indent)
	w.line("%s    local _b2 = string_byte(payload, p2 + 1)", indent)
	w.line("%s    if _b2 ~= nil and _b2 < 0x80 then", indent)
	w.line("%s        if _b2 == 0 then error(\"overlong varint at offset \" .. p2, 0) end", indent)
	w.line("%s        %s = _b - 128 + _b2 * 128", indent, valExpr)
	w.line("%s        p2 = p2 + 2", indent)
	w.line("%s    else", indent)
	w.line("%s        local _u; _u, p2 = wire.decode_varint(payload, p2)", indent)
	w.line("%s        %s = wire.varint_to_int32(_u)", indent, valExpr)
	w.line("%s    end", indent)
	w.line("%selse", indent)
	w.line("%s    local _u; _u, p2 = wire.decode_varint(payload, p2)", indent)
	w.line("%s    %s = wire.varint_to_int32(_u)", indent, valExpr)
	w.line("%send", indent)
}

// emitPackedVarintElem emits the per-element write inside a packed-varint
// loop with an inlined 1-byte CHARS-lookup fast path matching
// wire.encode_varint's hot case. Falls through to wire.encode_<st> for
// negatives, large values, and cdata. For fixed-width scalars (no varint
// fast path) it just emits a straight wire.encode_<st> call.
//
//   - indent is the Lua indentation prefix (e.g. "            ").
//   - list/idx are the parts-table and counter variable names.
//   - valExpr is the source expression for the element (e.g. "v[_i]"
//     or "nv" after enum-string resolve).
//   - st is the scalar name from scalarName().
//
// For sint32/sint64 the 7-bit zigzag range is -64..63 and is encoded
// inline with bit ops. For bool the emit is always 1 byte. For
// int32/int64/uint32/uint64 the fast path triggers when v is a Lua
// number in [0, 128) — covers the dominant small-positive case that
// pure-Lua wire.encode_varint already optimizes for.
func emitPackedVarintElem(w *writer, indent, list, idx, valExpr, st string) {
	switch st {
	case "bool":
		w.line("%s%s = %s + 1; %s[%s] = CHARS[(%s) and 1 or 0]",
			indent, idx, idx, list, idx, valExpr)
	case "sint32", "sint64":
		w.line("%slocal _e = %s", indent, valExpr)
		w.line("%sif type(_e) == 'number' and _e >= -64 and _e <= 63 then", indent)
		w.line("%s    %s = %s + 1; %s[%s] = CHARS[bit.bxor(bit.lshift(_e, 1), bit.arshift(_e, 31))]",
			indent, idx, idx, list, idx)
		w.line("%selse", indent)
		w.line("%s    %s = %s + 1; %s[%s] = %s",
			indent, idx, idx, list, idx, encodeCallExpr(st, "_e"))
		w.line("%send", indent)
	case "int32", "int64", "uint32", "uint64":
		w.line("%slocal _e = %s", indent, valExpr)
		w.line("%sif type(_e) == 'number' and _e >= 0 and _e < 128 then", indent)
		w.line("%s    %s = %s + 1; %s[%s] = CHARS[_e]",
			indent, idx, idx, list, idx)
		w.line("%selse", indent)
		w.line("%s    %s = %s + 1; %s[%s] = %s",
			indent, idx, idx, list, idx, encodeCallExpr(st, "_e"))
		w.line("%send", indent)
	default:
		w.line("%s%s = %s + 1; %s[%s] = %s",
			indent, idx, idx, list, idx, encodeCallExpr(st, valExpr))
	}
}

// realOneofs returns the message's non-synthetic oneofs (skips the ones
// proto3 expands explicit `optional` into).
func realOneofs(m *protogen.Message) []*protogen.Oneof {
	var out []*protogen.Oneof
	for _, oo := range m.Oneofs {
		if oo.Fields[0].Desc.HasOptionalKeyword() {
			continue
		}
		out = append(out, oo)
	}
	return out
}

func oneofVar(name string) string { return "_of_" + name }

// fieldRealOneof returns the oneof name a field belongs to, or "" if the
// field is not in a real oneof (i.e. either standalone or in a synthetic
// proto3 explicit-optional oneof).
func fieldRealOneof(f *protogen.Field) string {
	if f.Oneof == nil || f.Desc.HasOptionalKeyword() {
		return ""
	}
	return string(f.Oneof.Desc.Name())
}

func emitInlineEncodeField(w *writer, f *protogen.Field, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	id := int32(f.Desc.Number())
	tag := tagBytesLit(id, wireTypeForField(f))
	fname := string(f.Desc.Name())

	w.line("    -- field %d: %s", id, fname)
	w.line("    v = %s", luaFieldAccess("t", fname))

	// Proto2 `required`: error on encode if missing, never elide. Mutually
	// exclusive with oneof and repeated, so the rest of the branching below
	// stays unchanged for non-required fields.
	if f.Desc.Cardinality() == protoreflect.Required {
		emitInlineEncodeRequiredField(w, f, tag, file, selfPath, imports, prefix)
		return
	}

	oneof := fieldRealOneof(f)
	// Default presence gate: a regular nil check. For message fields we
	// also need to accept box.NULL (which == nil via Tarantool's cdata
	// metamethod) because google.protobuf.Value uses it as the canonical
	// null_value sentinel.
	gate := "v ~= nil"
	if oneof != "" {
		gate = fmt.Sprintf("%s == %q", oneofVar(oneof), fname)
	} else if f.Message != nil {
		gate = "v ~= nil or type(v) == 'cdata'"
	}
	// Presence semantics: oneof branches, proto3 explicit `optional`, and
	// every proto2 singular field (`optional` keyword). No default elision.
	hasPresence := oneof != "" || f.Desc.HasOptionalKeyword()

	switch {
	case f.Desc.IsMap():
		emitInlineEncodeMap(w, f, tag, file, selfPath, imports, prefix)
	case f.Desc.IsList():
		emitInlineEncodeRepeated(w, f, tag, fname, file, selfPath, imports, prefix)
	case f.Message != nil:
		ref := typeRef(file, f.Message.Desc, selfPath, imports, "_encode", prefix)
		if f.Desc.Kind() == protoreflect.GroupKind {
			// Proto2 group: SGROUP tag + body + EGROUP tag. No length
			// prefix — the receiver reads until the matching EGROUP id.
			endTag := tagBytesLit(int32(f.Desc.Number()), 4 /* EGROUP */)
			w.line("    if %s then", gate)
			w.line("        n = n + 1; out[n] = %s", tag)
			w.line("        n = n + 1; out[n] = %s(v)", ref)
			w.line("        n = n + 1; out[n] = %s", endTag)
			w.line("    end")
		} else {
			// Split the length-delimited payload into separate `out`
			// slots: emit tag, varint(#body), body. Avoids the per-field
			// concat that wire.encode_len would do.
			w.line("    if %s then", gate)
			w.line("        local _b = %s(v)", ref)
			w.line("        n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "        ", "_b")
			w.line("        n = n + 1; out[n] = _b")
			w.line("    end")
		}
	case f.Enum != nil:
		enumLocal := typeRef(file, f.Enum.Desc, selfPath, imports, "", prefix)
		fullName := string(f.Enum.Desc.FullName())
		// Presence (oneof or optional): emit even when value is the enum default.
		w.line("    if %s then", gate)
		w.line("        local nv = v")
		w.line("        if type(v) == 'string' then")
		w.line("            nv = %s[v]", enumLocal)
		w.line("            if nv == nil then error(\"unknown enum value '\" .. v .. \"' for %s\", 0) end", fullName)
		w.line("        end")
		if !hasPresence {
			w.line("        if nv ~= 0 then")
			w.line("            n = n + 1; out[n] = %s", tag)
			w.line("            n = n + 1; out[n] = wire.encode_int32(nv)")
			w.line("        end")
		} else {
			w.line("        n = n + 1; out[n] = %s", tag)
			w.line("        n = n + 1; out[n] = wire.encode_int32(nv)")
		}
		w.line("    end")
	default:
		st := scalarName(f.Desc.Kind())
		if st == "" {
			panic("unhandled scalar kind: " + f.Desc.Kind().String())
		}
		if !hasPresence {
			w.line("    if v ~= nil and %s then", scalarNotDefaultExpr(st, "v"))
		} else {
			w.line("    if %s then", gate)
		}
		if st == "string" || st == "bytes" {
			// Length-delimited scalar: same split rationale as nested
			// messages above. `encode_string` / `encode_bytes` would
			// concatenate the length prefix and body — emit them as
			// separate `out` slots instead and let table.concat join.
			w.line("        n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "        ", "v")
			w.line("        n = n + 1; out[n] = v")
		} else {
			w.line("        n = n + 1; out[n] = %s", tag)
			w.line("        n = n + 1; out[n] = %s", encodeCallExpr(st, "v"))
		}
		w.line("    end")
	}
}

// emitInlineEncodeRequiredField generates the encode body for a proto2
// `required` field: error if missing, always emit (no default elision).
func emitInlineEncodeRequiredField(w *writer, f *protogen.Field, tag string, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	fullName := string(f.Desc.FullName())
	w.line("    if v == nil then")
	w.line("        error(%q, 0)", "required field missing on encode: "+fullName)
	w.line("    end")
	switch {
	case f.Message != nil:
		ref := typeRef(file, f.Message.Desc, selfPath, imports, "_encode", prefix)
		w.line("    local _b = %s(v)", ref)
		w.line("    n = n + 1; out[n] = %s", tag)
		emitInlineLenPrefix(w, "    ", "_b")
		w.line("    n = n + 1; out[n] = _b")
	case f.Enum != nil:
		enumLocal := typeRef(file, f.Enum.Desc, selfPath, imports, "", prefix)
		enumFull := string(f.Enum.Desc.FullName())
		w.line("    do")
		w.line("        local nv = v")
		w.line("        if type(v) == 'string' then")
		w.line("            nv = %s[v]", enumLocal)
		w.line("            if nv == nil then error(\"unknown enum value '\" .. v .. \"' for %s\", 0) end", enumFull)
		w.line("        end")
		w.line("        n = n + 1; out[n] = %s", tag)
		w.line("        n = n + 1; out[n] = wire.encode_int32(nv)")
		w.line("    end")
	default:
		st := scalarName(f.Desc.Kind())
		if st == "" {
			panic("unhandled scalar kind: " + f.Desc.Kind().String())
		}
		if st == "string" || st == "bytes" {
			w.line("    n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "    ", "v")
			w.line("    n = n + 1; out[n] = v")
		} else {
			w.line("    n = n + 1; out[n] = %s", tag)
			w.line("    n = n + 1; out[n] = %s", encodeCallExpr(st, "v"))
		}
	}
}

func emitInlineEncodeRepeated(w *writer, f *protogen.Field, tag, fname string, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	switch {
	case f.Message != nil:
		ref := typeRef(file, f.Message.Desc, selfPath, imports, "_encode", prefix)
		if f.Desc.Kind() == protoreflect.GroupKind {
			endTag := tagBytesLit(int32(f.Desc.Number()), 4 /* EGROUP */)
			w.line("    if v ~= nil and #v > 0 then")
			w.line("        local _stag = %s", tag)
			w.line("        local _etag = %s", endTag)
			w.line("        for _i = 1, #v do")
			w.line("            n = n + 1; out[n] = _stag")
			w.line("            n = n + 1; out[n] = %s(v[_i])", ref)
			w.line("            n = n + 1; out[n] = _etag")
			w.line("        end")
			w.line("    end")
		} else {
			w.line("    if v ~= nil and #v > 0 then")
			w.line("        local _tag = %s", tag)
			w.line("        for _i = 1, #v do")
			w.line("            local _b = %s(v[_i])", ref)
			w.line("            n = n + 1; out[n] = _tag")
			emitInlineLenPrefix(w, "            ", "_b")
			w.line("            n = n + 1; out[n] = _b")
			w.line("        end")
			w.line("    end")
		}
	case f.Enum != nil:
		enumLocal := typeRef(file, f.Enum.Desc, selfPath, imports, "", prefix)
		fullName := string(f.Enum.Desc.FullName())
		w.line("    if v ~= nil and #v > 0 then")
		w.line("        local _n = #v")
		w.line("        local parts, m = table_new(_n, 0), 0")
		w.line("        for _i = 1, _n do")
		w.line("            local elem = v[_i]")
		w.line("            local nv = elem")
		w.line("            if type(elem) == 'string' then")
		w.line("                nv = %s[elem]", enumLocal)
		w.line("                if nv == nil then error(\"unknown enum value '\" .. elem .. \"' for %s\", 0) end", fullName)
		w.line("            end")
		emitPackedVarintElem(w, "            ", "parts", "m", "nv", "int32")
		w.line("        end")
		w.line("        local _b = table.concat(parts)")
		w.line("        n = n + 1; out[n] = %s", tag)
		emitInlineLenPrefix(w, "        ", "_b")
		w.line("        n = n + 1; out[n] = _b")
		w.line("    end")
	default:
		st := scalarName(f.Desc.Kind())
		packable := st != "string" && st != "bytes"
		if packable && f.Desc.IsPacked() {
			w.line("    if v ~= nil and #v > 0 then")
			w.line("        local _n = #v")
			w.line("        local parts, m = table_new(_n, 0), 0")
			w.line("        for _i = 1, _n do")
			emitPackedVarintElem(w, "            ", "parts", "m", "v[_i]", st)
			w.line("        end")
			w.line("        local _b = table.concat(parts)")
			w.line("        n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "        ", "_b")
			w.line("        n = n + 1; out[n] = _b")
			w.line("    end")
		} else if st == "string" || st == "bytes" {
			w.line("    if v ~= nil and #v > 0 then")
			w.line("        local _tag = %s", tag)
			w.line("        for _i = 1, #v do")
			w.line("            local _b = v[_i]")
			w.line("            n = n + 1; out[n] = _tag")
			emitInlineLenPrefix(w, "            ", "_b")
			w.line("            n = n + 1; out[n] = _b")
			w.line("        end")
			w.line("    end")
		} else {
			w.line("    if v ~= nil and #v > 0 then")
			w.line("        local _tag = %s", tag)
			w.line("        for _i = 1, #v do")
			w.line("            n = n + 1; out[n] = _tag")
			w.line("            n = n + 1; out[n] = %s", encodeCallExpr(st, "v[_i]"))
			w.line("        end")
			w.line("    end")
		}
	}
}

// emitInlineEncodeExtension emits an inline writer for a single statically
// known proto2 extension targeting the current message. Lives inside the
// `if _exts ~= nil then` block of the encode body, so the access pattern
// is `_exts[<full_name>]` rather than `t.<fname>`. Extensions are always
// presence-tracked (never proto3 implicit zero), never required, never in
// oneofs, never maps — the dispatch is correspondingly simpler than
// emitInlineEncodeField.
func emitInlineEncodeExtension(w *writer, ext *protogen.Extension, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	id := int32(ext.Desc.Number())
	full := string(ext.Desc.FullName())
	tag := tagBytesLit(id, wireTypeForField(ext))

	w.line("        -- extension %d: %s", id, full)
	w.line("        _ev = _exts[%q]", full)
	if ext.Desc.IsList() {
		emitInlineEncodeExtensionRepeated(w, ext, tag, full, file, selfPath, imports, prefix)
		return
	}
	switch {
	case ext.Message != nil:
		ref := typeRef(file, ext.Message.Desc, selfPath, imports, "_encode", prefix)
		if ext.Desc.Kind() == protoreflect.GroupKind {
			endTag := tagBytesLit(id, 4 /* EGROUP */)
			w.line("        if _ev ~= nil then")
			w.line("            n = n + 1; out[n] = %s", tag)
			w.line("            n = n + 1; out[n] = %s(_ev)", ref)
			w.line("            n = n + 1; out[n] = %s", endTag)
			w.line("        end")
		} else {
			w.line("        if _ev ~= nil then")
			w.line("            local _b = %s(_ev)", ref)
			w.line("            n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "            ", "_b")
			w.line("            n = n + 1; out[n] = _b")
			w.line("        end")
		}
	case ext.Enum != nil:
		enumLocal := typeRef(file, ext.Enum.Desc, selfPath, imports, "", prefix)
		enumFull := string(ext.Enum.Desc.FullName())
		w.line("        if _ev ~= nil then")
		w.line("            local _nv = _ev")
		w.line("            if type(_ev) == 'string' then")
		w.line("                _nv = %s[_ev]", enumLocal)
		w.line("                if _nv == nil then error(\"unknown enum value '\" .. _ev .. \"' for %s\", 0) end", enumFull)
		w.line("            end")
		w.line("            n = n + 1; out[n] = %s", tag)
		w.line("            n = n + 1; out[n] = wire.encode_int32(_nv)")
		w.line("        end")
	default:
		st := scalarName(ext.Desc.Kind())
		if st == "" {
			panic("unhandled extension scalar kind: " + ext.Desc.Kind().String())
		}
		w.line("        if _ev ~= nil then")
		if st == "string" || st == "bytes" {
			w.line("            n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "            ", "_ev")
			w.line("            n = n + 1; out[n] = _ev")
		} else {
			w.line("            n = n + 1; out[n] = %s", tag)
			w.line("            n = n + 1; out[n] = %s", encodeCallExpr(st, "_ev"))
		}
		w.line("        end")
	}
}

// emitInlineEncodeExtensionRepeated mirrors emitInlineEncodeRepeated but
// uses `_ev` (the extension value table read from `_exts[full_name]`) as
// the source instead of a field access on `t`. Same packing rules:
// packable scalars under [packed=true] pack into a single LEN payload,
// string/bytes and messages emit one wire entry per element, groups use
// SGROUP/EGROUP framing.
func emitInlineEncodeExtensionRepeated(w *writer, ext *protogen.Extension, tag, full string, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	switch {
	case ext.Message != nil:
		ref := typeRef(file, ext.Message.Desc, selfPath, imports, "_encode", prefix)
		if ext.Desc.Kind() == protoreflect.GroupKind {
			endTag := tagBytesLit(int32(ext.Desc.Number()), 4 /* EGROUP */)
			w.line("        if _ev ~= nil and #_ev > 0 then")
			w.line("            local _stag, _etag = %s, %s", tag, endTag)
			w.line("            for _i = 1, #_ev do")
			w.line("                n = n + 1; out[n] = _stag")
			w.line("                n = n + 1; out[n] = %s(_ev[_i])", ref)
			w.line("                n = n + 1; out[n] = _etag")
			w.line("            end")
			w.line("        end")
		} else {
			w.line("        if _ev ~= nil and #_ev > 0 then")
			w.line("            local _tag = %s", tag)
			w.line("            for _i = 1, #_ev do")
			w.line("                local _b = %s(_ev[_i])", ref)
			w.line("                n = n + 1; out[n] = _tag")
			emitInlineLenPrefix(w, "                ", "_b")
			w.line("                n = n + 1; out[n] = _b")
			w.line("            end")
			w.line("        end")
		}
	case ext.Enum != nil:
		enumLocal := typeRef(file, ext.Enum.Desc, selfPath, imports, "", prefix)
		enumFull := string(ext.Enum.Desc.FullName())
		w.line("        if _ev ~= nil and #_ev > 0 then")
		if ext.Desc.IsPacked() {
			w.line("            local _n = #_ev")
			w.line("            local parts, m = table_new(_n, 0), 0")
			w.line("            for _i = 1, _n do")
			w.line("                local elem = _ev[_i]")
			w.line("                local nv = elem")
			w.line("                if type(elem) == 'string' then")
			w.line("                    nv = %s[elem]", enumLocal)
			w.line("                    if nv == nil then error(\"unknown enum value '\" .. elem .. \"' for %s\", 0) end", enumFull)
			w.line("                end")
			emitPackedVarintElem(w, "                ", "parts", "m", "nv", "int32")
			w.line("            end")
			w.line("            local _b = table.concat(parts)")
			w.line("            n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "            ", "_b")
			w.line("            n = n + 1; out[n] = _b")
		} else {
			w.line("            local _tag = %s", tag)
			w.line("            for _i = 1, #_ev do")
			w.line("                local elem = _ev[_i]")
			w.line("                local nv = elem")
			w.line("                if type(elem) == 'string' then")
			w.line("                    nv = %s[elem]", enumLocal)
			w.line("                    if nv == nil then error(\"unknown enum value '\" .. elem .. \"' for %s\", 0) end", enumFull)
			w.line("                end")
			w.line("                n = n + 1; out[n] = _tag")
			w.line("                n = n + 1; out[n] = wire.encode_int32(nv)")
			w.line("            end")
		}
		w.line("        end")
	default:
		st := scalarName(ext.Desc.Kind())
		packable := st != "string" && st != "bytes"
		if packable && ext.Desc.IsPacked() {
			w.line("        if _ev ~= nil and #_ev > 0 then")
			w.line("            local _n = #_ev")
			w.line("            local parts, m = table_new(_n, 0), 0")
			w.line("            for _i = 1, _n do")
			emitPackedVarintElem(w, "                ", "parts", "m", "_ev[_i]", st)
			w.line("            end")
			w.line("            local _b = table.concat(parts)")
			w.line("            n = n + 1; out[n] = %s", tag)
			emitInlineLenPrefix(w, "            ", "_b")
			w.line("            n = n + 1; out[n] = _b")
			w.line("        end")
		} else if st == "string" || st == "bytes" {
			w.line("        if _ev ~= nil and #_ev > 0 then")
			w.line("            local _tag = %s", tag)
			w.line("            for _i = 1, #_ev do")
			w.line("                local _b = _ev[_i]")
			w.line("                n = n + 1; out[n] = _tag")
			emitInlineLenPrefix(w, "                ", "_b")
			w.line("                n = n + 1; out[n] = _b")
			w.line("            end")
			w.line("        end")
		} else {
			w.line("        if _ev ~= nil and #_ev > 0 then")
			w.line("            local _tag = %s", tag)
			w.line("            for _i = 1, #_ev do")
			w.line("                n = n + 1; out[n] = _tag")
			w.line("                n = n + 1; out[n] = %s", encodeCallExpr(st, "_ev[_i]"))
			w.line("            end")
			w.line("        end")
		}
	}
}

// emitInlineDecodeExtension emits an elseif-body that decodes one wire
// entry for a statically known extension and stores it under
// result._extensions[full_name]. For repeated extensions, appends to the
// existing list (creating it on first encounter). Mirrors
// pb.codec.decode_extension but inlines the dispatch and skips the
// per-call function frame.
func emitInlineDecodeExtension(w *writer, ext *protogen.Extension, file *protogen.File, selfPath string, imports map[string]string, prefix string, validateUTF8 bool) {
	full := string(ext.Desc.FullName())
	// Common preamble: ensure result._extensions exists.
	if ext.Desc.IsList() {
		emitInlineDecodeExtensionRepeated(w, ext, full, file, selfPath, imports, prefix, validateUTF8)
		return
	}
	switch {
	case ext.Message != nil:
		decodeSuffix := "_decode"
		if !validateUTF8 && !isWellKnownTypeFile(ext.Message.Desc.ParentFile()) {
			decodeSuffix = "_decode_unsafe"
		}
		ref := typeRef(file, ext.Message.Desc, selfPath, imports, decodeSuffix, prefix)
		if ext.Desc.Kind() == protoreflect.GroupKind {
			descRef := typeRef(file, ext.Message.Desc, selfPath, imports, "_descriptor", prefix)
			w.line("            local _payload")
			w.line("            _payload, pos = pb.codec.decode_group(%s, buf, pos, %d, depth + 1)",
				descRef, ext.Desc.Number())
			w.line("            local _e = result._extensions")
			w.line("            if _e == nil then _e = {}; result._extensions = _e end")
			w.line("            _e[%q] = _payload", full)
		} else {
			w.line("            local _payload")
			w.line("            _payload, pos = wire.decode_len(buf, pos)")
			w.line("            local _e = result._extensions")
			w.line("            if _e == nil then _e = {}; result._extensions = _e end")
			w.line("            _e[%q] = %s(_payload, depth + 1)", full, ref)
		}
	case ext.Enum != nil:
		w.line("            local _u")
		w.line("            _u, pos = wire.decode_varint(buf, pos)")
		w.line("            local _e = result._extensions")
		w.line("            if _e == nil then _e = {}; result._extensions = _e end")
		w.line("            _e[%q] = wire.varint_to_int32(_u)", full)
	default:
		st := scalarName(ext.Desc.Kind())
		if st == "" {
			panic("unhandled extension scalar kind: " + ext.Desc.Kind().String())
		}
		if st == "string" && !validateUTF8 {
			st = "bytes"
		}
		w.line("            local _val")
		w.line("            _val, pos = wire.decode_%s%s(buf, pos)", st, decodeFnSuffix(w, st))
		w.line("            local _e = result._extensions")
		w.line("            if _e == nil then _e = {}; result._extensions = _e end")
		w.line("            _e[%q] = _val", full)
	}
}

// emitInlineDecodeExtensionRepeated handles the repeated branch. Uses
// `#list + 1` rather than a hoisted counter — repeated extensions are
// uncommon enough that adding per-extension counters at function scope
// isn't worth the prelude noise.
func emitInlineDecodeExtensionRepeated(w *writer, ext *protogen.Extension, full string, file *protogen.File, selfPath string, imports map[string]string, prefix string, validateUTF8 bool) {
	w.line("            local _e = result._extensions")
	w.line("            if _e == nil then _e = {}; result._extensions = _e end")
	w.line("            local _list = _e[%q]", full)
	w.line("            if _list == nil then _list = {}; _e[%q] = _list end", full)
	switch {
	case ext.Message != nil:
		decodeSuffix := "_decode"
		if !validateUTF8 && !isWellKnownTypeFile(ext.Message.Desc.ParentFile()) {
			decodeSuffix = "_decode_unsafe"
		}
		ref := typeRef(file, ext.Message.Desc, selfPath, imports, decodeSuffix, prefix)
		if ext.Desc.Kind() == protoreflect.GroupKind {
			descRef := typeRef(file, ext.Message.Desc, selfPath, imports, "_descriptor", prefix)
			w.line("            local _payload")
			w.line("            _payload, pos = pb.codec.decode_group(%s, buf, pos, %d, depth + 1)",
				descRef, ext.Desc.Number())
			w.line("            _list[#_list + 1] = _payload")
		} else {
			w.line("            local _payload")
			w.line("            _payload, pos = wire.decode_len(buf, pos)")
			w.line("            _list[#_list + 1] = %s(_payload, depth + 1)", ref)
		}
	case ext.Enum != nil:
		w.line("            if wt == 2 then")
		w.line("                local _payload")
		w.line("                _payload, pos = wire.decode_len(buf, pos)")
		w.line("                local p2, lim = 1, #_payload")
		w.line("                while p2 <= lim do")
		w.line("                    local _u")
		w.line("                    _u, p2 = wire.decode_varint(_payload, p2)")
		w.line("                    _list[#_list + 1] = wire.varint_to_int32(_u)")
		w.line("                end")
		w.line("            else")
		w.line("                local _u")
		w.line("                _u, pos = wire.decode_varint(buf, pos)")
		w.line("                _list[#_list + 1] = wire.varint_to_int32(_u)")
		w.line("            end")
	default:
		st := scalarName(ext.Desc.Kind())
		packable := st != "string" && st != "bytes"
		if st == "string" && !validateUTF8 {
			st = "bytes"
		}
		if packable {
			w.line("            if wt == 2 then")
			w.line("                local _payload")
			w.line("                _payload, pos = wire.decode_len(buf, pos)")
			w.line("                local p2, lim = 1, #_payload")
			w.line("                while p2 <= lim do")
			w.line("                    local _val")
			w.line("                    _val, p2 = wire.decode_%s%s(_payload, p2)", st, decodeFnSuffix(w, st))
			w.line("                    _list[#_list + 1] = _val")
			w.line("                end")
			w.line("            else")
			w.line("                local _val")
			w.line("                _val, pos = wire.decode_%s%s(buf, pos)", st, decodeFnSuffix(w, st))
			w.line("                _list[#_list + 1] = _val")
			w.line("            end")
		} else {
			w.line("            local _val")
			w.line("            _val, pos = wire.decode_%s%s(buf, pos)", st, decodeFnSuffix(w, st))
			w.line("            _list[#_list + 1] = _val")
		}
	}
}

// emitInlineDecode emits a per-message decoder. When validateUTF8 is true the
// emitted function is `<Name>_decode` (proto3-conformant — every decoded string
// field is checked with utf8_len). When false the function is
// `<Name>_decode_unsafe`, intended for re-decoding bytes produced by a trusted
// peer (typed RPC against our own encoder, JSON/text round-trips, in-process
// pipelines). The unsafe variant drops the utf8_len check at every string site
// and routes the >=128-byte fallback through wire.decode_bytes instead of
// wire.decode_string. Both variants dispatch to the C runtime when available;
// the unsafe path calls c_runtime.decode_unsafe which gates is_valid_utf8 on
// a per-call flag.
func emitInlineDecode(w *writer, name string, m *protogen.Message, file *protogen.File, selfPath string, imports map[string]string, prefix string, exts []*protogen.Extension, validateUTF8 bool) {
	suffix := "_decode"
	cEntry := "decode"
	if !validateUTF8 {
		suffix = "_decode_unsafe"
		cEntry = "decode_unsafe"
	}
	emitEmmyWrapperAnnotations(w, name, emmyMessageFullName(m), wrapperDecode)
	// `depth` is the nesting level (nil for a top-level call); nested
	// messages and groups are decoded at depth + 1, and input nested past
	// wire.RECURSION_LIMIT is refused.
	emitLocalizedFunction(w, fmt.Sprintf("function M.%s%s(buf, depth)", name, suffix), func() {
		w.line("    local _d = M.%s_descriptor", name)
		// C-acceleration: see emitInlineEncode for rationale and lazy-compile.
		w.line("    if pb.c_runtime ~= nil then")
		w.line("        local _p = _d.c_plan or pb.c_runtime.compile_plan(_d)")
		w.line("        return pb.c_runtime.%s(_p, buf)", cEntry)
		w.line("    end")
		w.line("    if type(buf) ~= 'string' then")
		w.line("        error(\"expected string for %s decode, got \" .. type(buf), 0)", m.Desc.FullName())
		w.line("    end")
		w.line("    depth = depth or 0")
		w.line("    if depth > wire.RECURSION_LIMIT then wire.recursion_limit_error() end")
		w.line("    local result = {}")
		w.line("    local pos, len = 1, #buf")
		w.line("    local _uf")
		// Per-repeated-field counters. Replace `#list + 1` (re-traverses
		// the list every append) with `_n_<fname> = _n_<fname> + 1`. The
		// counter survives across loop iterations, so out-of-order wire
		// entries for the same field continue counting from the existing
		// position without re-scanning. Map fields don't need a counter
		// (hash keys, not array indices).
		for _, f := range m.Fields {
			if f.Desc.IsList() && !f.Desc.IsMap() {
				w.line("    local _n_%s = 0", string(f.Desc.Name()))
			}
		}
		w.line("    while pos <= len do")
		w.line("        local _tag_start = pos")
		w.line("        local id, wt")
		// Inline the 1-byte tag fast path (field numbers 1..15) and the
		// 2-byte tag fast path (field numbers 16..4095) directly. Together
		// these cover almost every real RPC payload — the >=3-byte fallback
		// only fires for field numbers >= 4096. Inlining literally at the
		// dispatch site keeps the side trace inside the parent's own frame
		// when the 1-byte guard fails, instead of bridging to interpreter
		// through wire.decode_tag's frame return.
		w.line("        local _b = string_byte(buf, pos)")
		w.line("        if _b ~= nil and _b < 0x80 then")
		w.line("            wt = band(_b, 7)")
		w.line("            if wt >= 6 then error(\"illegal wire type \" .. wt, 0) end")
		w.line("            id = rshift(_b, 3)")
		w.line("            if id == 0 then error(\"illegal field number 0\", 0) end")
		w.line("            pos = pos + 1")
		w.line("        elseif _b ~= nil and pos < len then")
		w.line("            local _b2 = string_byte(buf, pos + 1)")
		w.line("            if _b2 < 0x80 then")
		w.line("                if _b2 == 0 then error(\"overlong tag varint at offset \" .. pos, 0) end")
		w.line("                local _v = _b - 128 + _b2 * 128")
		w.line("                wt = band(_v, 7)")
		w.line("                if wt >= 6 then error(\"illegal wire type \" .. wt, 0) end")
		w.line("                id = rshift(_v, 3)")
		w.line("                pos = pos + 2")
		w.line("            else")
		w.line("                id, wt, pos = wire.decode_tag(buf, pos)")
		w.line("            end")
		w.line("        else")
		w.line("            id, wt, pos = wire.decode_tag(buf, pos)")
		w.line("        end")

		first := true
		for _, f := range m.Fields {
			op := "elseif"
			if first {
				op = "if"
				first = false
			}
			w.line("        %s id == %d then", op, f.Desc.Number())
			emitInlineDecodeFieldBody(w, f, file, selfPath, imports, prefix, validateUTF8)
		}
		// Static extension dispatch arms: route known extension ids
		// straight into inline decoders that store into
		// result._extensions[full_name]. Skips the
		// pb.codec.decode_extension dispatch for the common case.
		for _, ext := range exts {
			op := "elseif"
			if first {
				op = "if"
				first = false
			}
			w.line("        %s id == %d then", op, ext.Desc.Number())
			emitInlineDecodeExtension(w, ext, file, selfPath, imports, prefix, validateUTF8)
		}
		if first {
			// No fields — every tag takes the `else` arm below, which
			// resolves extensions and keeps the rest as unknown bytes.
			w.line("        if false then")
		}
		w.line("        else")
		// Proto2 extensions registered at runtime (past the static set):
		// fall back to pb.codec.decode_extension. Unknown ids land in
		// the unknown-fields buffer.
		w.line("            local _ebid = M.%s_descriptor.extensions_by_id", name)
		w.line("            local _ext = _ebid and _ebid[id] or nil")
		w.line("            if _ext ~= nil then")
		w.line("                pos = pb.codec.decode_extension(_ext, buf, pos, wt, result, depth)")
		w.line("            else")
		w.line("                pos = wire.skip_field(buf, pos, wt, id)")
		w.line("                if _uf == nil then _uf = {} end")
		w.line("                _uf[#_uf + 1] = buf:sub(_tag_start, pos - 1)")
		w.line("            end")
		w.line("        end")
		w.line("    end")
		w.line("    if _uf ~= nil then result._unknown_fields = table.concat(_uf) end")
		w.line("    return result")
	})
}

func emitInlineDecodeFieldBody(w *writer, f *protogen.Field, file *protogen.File, selfPath string, imports map[string]string, prefix string, validateUTF8 bool) {
	fname := string(f.Desc.Name())
	switch {
	case f.Desc.IsMap():
		emitInlineDecodeMap(w, f, fname, file, selfPath, imports, prefix, validateUTF8)
	case f.Desc.IsList():
		emitInlineDecodeRepeated(w, f, fname, file, selfPath, imports, prefix, validateUTF8)
	case f.Message != nil:
		// Recurse into the sub-message's matching unsafe variant when the
		// caller is itself an _decode_unsafe — otherwise nested string
		// fields would still be validated. WKT decoders (Timestamp,
		// Duration, Any, …) live in pb.wkt and don't have an _unsafe
		// twin; they're cheap (no string-validation hot path) so route
		// through the normal _decode unconditionally.
		decodeSuffix := "_decode"
		if !validateUTF8 && !isWellKnownTypeFile(f.Message.Desc.ParentFile()) {
			decodeSuffix = "_decode_unsafe"
		}
		ref := typeRef(file, f.Message.Desc, selfPath, imports, decodeSuffix, prefix)
		dst := luaFieldAccess("result", fname)
		descRef := typeRef(file, f.Message.Desc, selfPath, imports, "_descriptor", prefix)
		if f.Desc.Kind() == protoreflect.GroupKind {
			// Group: no length prefix. The codec reads body fields until
			// it hits an EGROUP tag matching this field's id; returns the
			// decoded table and the new position.
			w.line("            local payload")
			w.line("            payload, pos = pb.codec.decode_group(%s, buf, pos, %d, depth + 1)",
				descRef, f.Desc.Number())
			w.line("            local prev = %s", dst)
			w.line("            if prev == nil then")
			w.line("                %s = payload", dst)
			w.line("            else")
			w.line("                pb.codec.merge_message(%s, prev, payload)", descRef)
			w.line("            end")
		} else {
			w.line("            local payload")
			w.line("            payload, pos = wire.decode_len(buf, pos)")
			if isWellKnownTypeFile(f.Message.Desc.ParentFile()) {
				// WKT decoders return unwrapped values (datetime, number, string),
				// not Lua tables — there is nothing to merge into. Replace.
				w.line("            %s = %s(payload, depth + 1)", dst, ref)
			} else {
				// Per proto3 spec, repeated occurrences of a singular message
				// field merge recursively. This holds for oneof branches too;
				// sibling clearing below enforces oneof exclusivity.
				w.line("            local prev = %s", dst)
				w.line("            if prev == nil then")
				w.line("                %s = %s(payload, depth + 1)", dst, ref)
				w.line("            else")
				w.line("                pb.codec.merge_message(%s, prev, %s(payload, depth + 1))",
					descRef, ref)
				w.line("            end")
			}
		}
	case f.Enum != nil:
		w.line("            local u")
		w.line("            u, pos = wire.decode_varint(buf, pos)")
		w.line("            %s = wire.varint_to_int32(u)", luaFieldAccess("result", fname))
	default:
		st := scalarName(f.Desc.Kind())
		if st == "string" || st == "bytes" {
			// Inline the 1-byte LEN fast path (length < 128). Skips the
			// `wire.decode_string` / `wire.decode_bytes` function call
			// frame for the typical short-string case; the resulting
			// straight-line code stays inside the parent JIT trace
			// instead of stitching through a child trace.
			dst := luaFieldAccess("result", fname)
			emitInlineStringBytesScalar(w, st, dst, validateUTF8)
		} else {
			w.line("            local val")
			w.line("            val, pos = wire.decode_%s%s(buf, pos)", st, decodeFnSuffix(w, st))
			w.line("            %s = val", luaFieldAccess("result", fname))
		}
	}

	// Oneof: clear sibling branches so callers see exactly one set field.
	if oneof := fieldRealOneof(f); oneof != "" {
		for _, sib := range f.Oneof.Fields {
			if sib == f {
				continue
			}
			w.line("            %s = nil",
				luaFieldAccess("result", string(sib.Desc.Name())))
		}
	}
}

func emitInlineDecodeRepeated(w *writer, f *protogen.Field, fname string, file *protogen.File, selfPath string, imports map[string]string, prefix string, validateUTF8 bool) {
	dst := luaFieldAccess("result", fname)
	cnt := "_n_" + string(f.Desc.Name())

	// For packable scalar/enum fields, defer the list allocation into the
	// wt==2 branch so the element count estimate (derived from the packed
	// payload length) can drive table.new(N, 0) and avoid the rehash
	// cascade. For non-packable types (message/string/bytes) and for the
	// per-element wt!=2 fallback, fall back to a bare `{}` — the size
	// hint would require a per-tag scan that costs more than it saves.
	packable := false
	estExpr := ""
	switch {
	case f.Message != nil:
		// fallthrough to default alloc + standard emit
	case f.Enum != nil:
		packable = true
		estExpr = "lim" // upper-bound (each varint ≥ 1 byte)
	default:
		st := scalarName(f.Desc.Kind())
		if st != "string" && st != "bytes" {
			packable = true
			if sz := fixedScalarBytes(f.Desc.Kind()); sz > 0 {
				estExpr = fmt.Sprintf("rshift(lim, %d)", sz) // /4 or /8 via bit shift
			} else {
				estExpr = "lim"
			}
		}
	}

	if !packable {
		// Default-allocation prelude for non-packable fields.
		w.line("            local list = %s", dst)
		w.line("            if list == nil then list = {}; %s = list end", dst)
	}

	switch {
	case f.Message != nil:
		decodeSuffix := "_decode"
		if !validateUTF8 && !isWellKnownTypeFile(f.Message.Desc.ParentFile()) {
			decodeSuffix = "_decode_unsafe"
		}
		ref := typeRef(file, f.Message.Desc, selfPath, imports, decodeSuffix, prefix)
		if f.Desc.Kind() == protoreflect.GroupKind {
			descRef := typeRef(file, f.Message.Desc, selfPath, imports, "_descriptor", prefix)
			w.line("            local payload")
			w.line("            payload, pos = pb.codec.decode_group(%s, buf, pos, %d, depth + 1)",
				descRef, f.Desc.Number())
			w.line("            %s = %s + 1; list[%s] = payload", cnt, cnt, cnt)
		} else {
			w.line("            local payload")
			w.line("            payload, pos = wire.decode_len(buf, pos)")
			w.line("            %s = %s + 1; list[%s] = %s(payload, depth + 1)", cnt, cnt, cnt, ref)
		}
	case f.Enum != nil:
		// Enums are packable (proto3 default). Accept both packed and per-element.
		// The packed inner loop uses the enum-aware inline varint decoder so
		// 1-byte and 2-byte values bypass the wire.decode_varint + varint_to_int32
		// frames.
		w.line("            if wt == 2 then")
		w.line("                local payload")
		w.line("                payload, pos = wire.decode_len(buf, pos)")
		w.line("                local p2, lim = 1, #payload")
		w.line("                local list = %s", dst)
		w.line("                if list == nil then list = table_new(%s, 0); %s = list end", estExpr, dst)
		w.line("                while p2 <= lim do")
		w.line("                    local val")
		emitPackedEnumElemDecode(w, "                    ", "val")
		w.line("                    %s = %s + 1; list[%s] = val", cnt, cnt, cnt)
		w.line("                end")
		w.line("            else")
		w.line("                local list = %s", dst)
		w.line("                if list == nil then list = {}; %s = list end", dst)
		w.line("                local u")
		w.line("                u, pos = wire.decode_varint(buf, pos)")
		w.line("                %s = %s + 1; list[%s] = wire.varint_to_int32(u)", cnt, cnt, cnt)
		w.line("            end")
	default:
		st := scalarName(f.Desc.Kind())
		if packable {
			w.line("            if wt == 2 then")
			w.line("                local payload")
			w.line("                payload, pos = wire.decode_len(buf, pos)")
			w.line("                local p2, lim = 1, #payload")
			w.line("                local list = %s", dst)
			w.line("                if list == nil then list = table_new(%s, 0); %s = list end", estExpr, dst)
			w.line("                while p2 <= lim do")
			w.line("                    local val")
			// Inline 1-byte and 2-byte varint fast paths for int32/uint32/bool
			// (Lua-number returns). Other types fall through to wire.decode_<st>
			// per the helper.
			emitPackedVarintElemDecode(w, "                    ", st, "val")
			w.line("                    %s = %s + 1; list[%s] = val", cnt, cnt, cnt)
			w.line("                end")
			w.line("            else")
			w.line("                local list = %s", dst)
			w.line("                if list == nil then list = {}; %s = list end", dst)
			w.line("                local val")
			w.line("                val, pos = wire.decode_%s%s(buf, pos)", st, decodeFnSuffix(w, st))
			w.line("                %s = %s + 1; list[%s] = val", cnt, cnt, cnt)
			w.line("            end")
		} else {
			// Repeated string/bytes — inline 1-byte LEN fast path.
			emitInlineStringBytesRepeated(w, st, cnt, validateUTF8)
		}
	}
}

// fixedScalarBytes returns the log2 of element size in bytes for
// fixed-width scalar kinds, or 0 for varint-based kinds. Used to derive
// an exact count from the packed payload length via bit shift
// (count = lim >> log2_sz).
func fixedScalarBytes(k protoreflect.Kind) int {
	switch k {
	case protoreflect.Fixed32Kind, protoreflect.Sfixed32Kind, protoreflect.FloatKind:
		return 2 // 4 bytes -> shift right by 2
	case protoreflect.Fixed64Kind, protoreflect.Sfixed64Kind, protoreflect.DoubleKind:
		return 3 // 8 bytes -> shift right by 3
	}
	return 0
}

// emitInlineStringBytesScalar emits the singular string/bytes decode with the
// 1-byte LEN fast path (lengths 0..127) and the 2-byte LEN fast path (lengths
// 128..16383) inlined directly. Falls back to `wire.decode_<st>` only for
// lengths >= 16384. UTF-8 validation runs only for `string`, not `bytes`. When
// validateUTF8 is false the inline check is dropped and the fallback for
// strings is routed through wire.decode_bytes (same shape, no utf8_len call).
func emitInlineStringBytesScalar(w *writer, st, dst string, validateUTF8 bool) {
	wireCall := st
	if st == "string" && !validateUTF8 {
		wireCall = "bytes"
	}
	w.line("            local _lb = string_byte(buf, pos)")
	w.line("            if _lb ~= nil and _lb < 0x80 then")
	w.line("                local _np = pos + 1")
	w.line("                local _epos = _np + _lb")
	w.line("                if _epos - 1 > len then error(\"truncated LEN at offset \" .. pos, 0) end")
	w.line("                local _s = buf:sub(_np, _epos - 1)")
	if st == "string" && validateUTF8 {
		w.line("                if utf8_len(_s) == nil then error(\"invalid UTF-8 in string field at offset \" .. pos, 0) end")
	}
	w.line("                %s = _s", dst)
	w.line("                pos = _epos")
	w.line("            elseif _lb ~= nil and pos < len then")
	w.line("                local _lb2 = string_byte(buf, pos + 1)")
	w.line("                if _lb2 ~= nil and _lb2 < 0x80 then")
	w.line("                    if _lb2 == 0 then error(\"overlong LEN varint at offset \" .. pos, 0) end")
	w.line("                    local _ln = _lb - 128 + _lb2 * 128")
	w.line("                    local _np = pos + 2")
	w.line("                    local _epos = _np + _ln")
	w.line("                    if _epos - 1 > len then error(\"truncated LEN at offset \" .. pos, 0) end")
	w.line("                    local _s = buf:sub(_np, _epos - 1)")
	if st == "string" && validateUTF8 {
		w.line("                    if utf8_len(_s) == nil then error(\"invalid UTF-8 in string field at offset \" .. pos, 0) end")
	}
	w.line("                    %s = _s", dst)
	w.line("                    pos = _epos")
	w.line("                else")
	w.line("                    local val")
	w.line("                    val, pos = wire.decode_%s(buf, pos)", wireCall)
	w.line("                    %s = val", dst)
	w.line("                end")
	w.line("            else")
	w.line("                local val")
	w.line("                val, pos = wire.decode_%s(buf, pos)", wireCall)
	w.line("                %s = val", dst)
	w.line("            end")
}

// emitInlineStringBytesRepeated mirrors emitInlineStringBytesScalar but
// appends to the per-field list via the `_n_<f>` counter. Both 1-byte and
// 2-byte LEN fast paths are inlined; falls back only for lengths >= 16384.
func emitInlineStringBytesRepeated(w *writer, st, cnt string, validateUTF8 bool) {
	wireCall := st
	if st == "string" && !validateUTF8 {
		wireCall = "bytes"
	}
	w.line("            local _lb = string_byte(buf, pos)")
	w.line("            if _lb ~= nil and _lb < 0x80 then")
	w.line("                local _np = pos + 1")
	w.line("                local _epos = _np + _lb")
	w.line("                if _epos - 1 > len then error(\"truncated LEN at offset \" .. pos, 0) end")
	w.line("                local _s = buf:sub(_np, _epos - 1)")
	if st == "string" && validateUTF8 {
		w.line("                if utf8_len(_s) == nil then error(\"invalid UTF-8 in string field at offset \" .. pos, 0) end")
	}
	w.line("                %s = %s + 1; list[%s] = _s", cnt, cnt, cnt)
	w.line("                pos = _epos")
	w.line("            elseif _lb ~= nil and pos < len then")
	w.line("                local _lb2 = string_byte(buf, pos + 1)")
	w.line("                if _lb2 ~= nil and _lb2 < 0x80 then")
	w.line("                    if _lb2 == 0 then error(\"overlong LEN varint at offset \" .. pos, 0) end")
	w.line("                    local _ln = _lb - 128 + _lb2 * 128")
	w.line("                    local _np = pos + 2")
	w.line("                    local _epos = _np + _ln")
	w.line("                    if _epos - 1 > len then error(\"truncated LEN at offset \" .. pos, 0) end")
	w.line("                    local _s = buf:sub(_np, _epos - 1)")
	if st == "string" && validateUTF8 {
		w.line("                    if utf8_len(_s) == nil then error(\"invalid UTF-8 in string field at offset \" .. pos, 0) end")
	}
	w.line("                    %s = %s + 1; list[%s] = _s", cnt, cnt, cnt)
	w.line("                    pos = _epos")
	w.line("                else")
	w.line("                    local val")
	w.line("                    val, pos = wire.decode_%s(buf, pos)", wireCall)
	w.line("                    %s = %s + 1; list[%s] = val", cnt, cnt, cnt)
	w.line("                end")
	w.line("            else")
	w.line("                local val")
	w.line("                val, pos = wire.decode_%s(buf, pos)", wireCall)
	w.line("                %s = %s + 1; list[%s] = val", cnt, cnt, cnt)
	w.line("            end")
}

// ----------------------------------------------------------------------------
// Map field codegen
// ----------------------------------------------------------------------------

// emitInlineEncodeMap emits the encode block for a map<K,V> field. Map fields
// are wire-equivalent to `repeated <Field>Entry`, where the synthetic Entry
// message has key=field 1 and value=field 2.
func emitInlineEncodeMap(w *writer, f *protogen.Field, tag string, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	keyF, valF := f.Message.Fields[0], f.Message.Fields[1]

	keyTag := tagBytesLit(1, mapSubFieldWireType(keyF))
	valTag := tagBytesLit(2, mapSubFieldWireType(valF))

	w.line("    if v ~= nil and next(v) ~= nil then")
	w.line("        local _tag, _ktag, _vtag = %s, %s, %s", tag, keyTag, valTag)
	w.line("        for _k, _val in pairs(v) do")
	w.line("            local entry, _m = {}, 0")

	// Key emit
	keyDef := mapKeyDefaultExpr(keyF)
	w.line("            if _k ~= %s then", keyDef)
	emitMapPiece(w, "entry", "_m", "_ktag", "_k", keyF, file, selfPath, imports, prefix)
	w.line("            end")

	// Value emit
	emitMapValueGuard(w, valF, "_val")
	emitMapPiece(w, "entry", "_m", "_vtag", "_val", valF, file, selfPath, imports, prefix)
	w.line("            end")

	w.line("            n = n + 1; out[n] = _tag")
	w.line("            local _b = table.concat(entry)")
	emitInlineLenPrefix(w, "            ", "_b")
	w.line("            n = n + 1; out[n] = _b")
	w.line("        end")
	w.line("    end")
}

// emitMapPiece emits the two-line append:
//
//	<list>[<idx> + 1] = <tag>; <list>[<idx> + 2] = wire.encode_<typed>(<expr>)
//
// (or the message form). Increments <idx> by 2 in two separate statements.
func emitMapPiece(w *writer, list, idx, tag, valExpr string, f *protogen.Field, file *protogen.File, selfPath string, imports map[string]string, prefix string) {
	switch {
	case f.Message != nil:
		ref := typeRef(file, f.Message.Desc, selfPath, imports, "_encode", prefix)
		w.line("                %s = %s + 1; %s[%s] = %s",
			idx, idx, list, idx, tag)
		w.line("                %s = %s + 1; %s[%s] = wire.encode_len(%s(%s))",
			idx, idx, list, idx, ref, valExpr)
	case f.Enum != nil:
		// For enum value: input may be string name; resolve.
		enumLocal := typeRef(file, f.Enum.Desc, selfPath, imports, "", prefix)
		fullName := string(f.Enum.Desc.FullName())
		w.line("                local _nv = %s", valExpr)
		w.line("                if type(%s) == 'string' then", valExpr)
		w.line("                    _nv = %s[%s]", enumLocal, valExpr)
		w.line("                    if _nv == nil then error(\"unknown enum value '\" .. %s .. \"' for %s\", 0) end",
			valExpr, fullName)
		w.line("                end")
		w.line("                %s = %s + 1; %s[%s] = %s", idx, idx, list, idx, tag)
		w.line("                %s = %s + 1; %s[%s] = wire.encode_int32(_nv)", idx, idx, list, idx)
	default:
		st := scalarName(f.Desc.Kind())
		w.line("                %s = %s + 1; %s[%s] = %s", idx, idx, list, idx, tag)
		w.line("                %s = %s + 1; %s[%s] = %s",
			idx, idx, list, idx, encodeCallExpr(st, valExpr))
	}
}

// emitMapValueGuard emits an `if <not-default> then` guarding the value emit
// for default-elision in map entries. Closing `end` is the caller's job.
func emitMapValueGuard(w *writer, f *protogen.Field, valExpr string) {
	switch {
	case f.Message != nil:
		// Messages have no notion of "default value" elision in this position;
		// emit unconditionally (nil is excluded by the outer iteration anyway).
		w.line("            if %s ~= nil then", valExpr)
	case f.Enum != nil:
		// Need to resolve string -> int first, but we delay that. The cheap
		// guard here is only for default elision, so check `~= 0` once it's
		// been resolved. To keep things simple, always emit and let the proto
		// receiver re-resolve to default. (Defaults round-trip correctly.)
		w.line("            do")
	default:
		st := scalarName(f.Desc.Kind())
		w.line("            if %s then", scalarNotDefaultExpr(st, valExpr))
	}
}

// mapKeyDefaultExpr returns the Lua literal for the proto3 default of a map key.
// Only string + integer + bool keys are valid in maps.
func mapKeyDefaultExpr(f *protogen.Field) string {
	switch f.Desc.Kind() {
	case protoreflect.StringKind:
		return "''"
	case protoreflect.BoolKind:
		return "false"
	}
	return "0"
}

// mapSubFieldWireType returns the wire type for a map entry's key or value
// (both are singular and never packed).
func mapSubFieldWireType(f *protogen.Field) int {
	switch {
	case f.Message != nil:
		return 2 // LEN
	case f.Enum != nil:
		return 0 // VARINT
	}
	switch f.Desc.Kind() {
	case protoreflect.Int32Kind, protoreflect.Int64Kind,
		protoreflect.Uint32Kind, protoreflect.Uint64Kind,
		protoreflect.Sint32Kind, protoreflect.Sint64Kind,
		protoreflect.BoolKind:
		return 0 // VARINT
	case protoreflect.Fixed32Kind, protoreflect.Sfixed32Kind, protoreflect.FloatKind:
		return 5 // I32
	case protoreflect.Fixed64Kind, protoreflect.Sfixed64Kind, protoreflect.DoubleKind:
		return 1 // I64
	case protoreflect.StringKind, protoreflect.BytesKind:
		return 2 // LEN
	}
	panic("unhandled map sub-field kind: " + f.Desc.Kind().String())
}

// emitInlineDecodeMap emits the decode block for a map<K,V> field.
func emitInlineDecodeMap(w *writer, f *protogen.Field, fname string, file *protogen.File, selfPath string, imports map[string]string, prefix string, validateUTF8 bool) {
	keyF, valF := f.Message.Fields[0], f.Message.Fields[1]

	dst := luaFieldAccess("result", fname)
	w.line("            local map = %s", dst)
	w.line("            if map == nil then map = {}; %s = map end", dst)
	w.line("            local payload")
	w.line("            payload, pos = wire.decode_len(buf, pos)")
	w.line("            local _ep, _elim = 1, #payload")
	w.line("            local _key, _val = %s, %s",
		mapDefaultExpr(keyF), mapDefaultExpr(valF))
	w.line("            while _ep <= _elim do")
	w.line("                local eid, ewt")
	w.line("                eid, ewt, _ep = wire.decode_tag(payload, _ep)")
	w.line("                if eid == 1 then")
	emitMapDecode(w, "_key", keyF, file, selfPath, imports, prefix, validateUTF8)
	w.line("                elseif eid == 2 then")
	emitMapDecode(w, "_val", valF, file, selfPath, imports, prefix, validateUTF8)
	w.line("                else")
	w.line("                    _ep = wire.skip_field(payload, _ep, ewt, eid)")
	w.line("                end")
	w.line("            end")
	if mapKeyNeedsCdataDedup(keyF) {
		// 64-bit int keys are LuaJIT cdata; LuaJIT hashes cdata by pointer,
		// so duplicate-key wire entries land in different hash buckets even
		// though __eq matches. Walk once to find a canonical key and
		// preserve proto3 "last value wins" semantics. Only emitted for
		// cdata-yielding key types so string/int32-keyed maps stay on the
		// JIT trace.
		w.line("            for _k in pairs(map) do")
		w.line("                if _k == _key then _key = _k; break end")
		w.line("            end")
	}
	w.line("            map[_key] = _val")
}

// mapKeyNeedsCdataDedup reports whether a map key type yields LuaJIT
// cdata and therefore needs pointer-vs-value dedup on decode. Mirrors the
// runtime gate set up in pb.finalize_message.
func mapKeyNeedsCdataDedup(keyF *protogen.Field) bool {
	switch keyF.Desc.Kind() {
	case protoreflect.Int64Kind, protoreflect.Uint64Kind,
		protoreflect.Sint64Kind, protoreflect.Fixed64Kind,
		protoreflect.Sfixed64Kind:
		return true
	}
	return false
}

// mapDefaultExpr returns the Lua expression for a map sub-field's default.
func mapDefaultExpr(f *protogen.Field) string {
	switch {
	case f.Message != nil:
		return "{}"
	case f.Enum != nil:
		return "0"
	}
	switch f.Desc.Kind() {
	case protoreflect.StringKind, protoreflect.BytesKind:
		return "''"
	case protoreflect.BoolKind:
		return "false"
	}
	return "0"
}

// emitMapDecode emits the per-sub-field decode body inside the map entry's
// while-loop. Stores into <dst>; advances _ep.
func emitMapDecode(w *writer, dst string, f *protogen.Field, file *protogen.File, selfPath string, imports map[string]string, prefix string, validateUTF8 bool) {
	switch {
	case f.Message != nil:
		decodeSuffix := "_decode"
		if !validateUTF8 && !isWellKnownTypeFile(f.Message.Desc.ParentFile()) {
			decodeSuffix = "_decode_unsafe"
		}
		ref := typeRef(file, f.Message.Desc, selfPath, imports, decodeSuffix, prefix)
		w.line("                    local _payload")
		w.line("                    _payload, _ep = wire.decode_len(payload, _ep)")
		w.line("                    %s = %s(_payload, depth + 1)", dst, ref)
	case f.Enum != nil:
		w.line("                    local _u")
		w.line("                    _u, _ep = wire.decode_varint(payload, _ep)")
		w.line("                    %s = wire.varint_to_int32(_u)", dst)
	default:
		st := scalarName(f.Desc.Kind())
		// Map key/value strings on the unsafe path bypass UTF-8 validation
		// by calling wire.decode_bytes (identical wire shape, no utf8_len).
		if st == "string" && !validateUTF8 {
			st = "bytes"
		}
		w.line("                    %s, _ep = wire.decode_%s%s(payload, _ep)", dst, st, decodeFnSuffix(w, st))
	}
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

// wireTypeForField returns the proto wire type used to encode this field.
//
// For repeated packable fields with packed=true (proto3 default for primitive
// scalars and enums), the *element* tag is LEN — caller still calls this with
// care. We return the singular-element wire type and let the emit logic decide
// when to swap it to LEN for packed encoding.
func wireTypeForField(f *protogen.Field) int {
	switch {
	case f.Message != nil:
		// Proto2 groups: the *opening* tag carries SGROUP (3). The
		// closing tag is emitted separately as EGROUP (4) at the end of
		// the field body.
		if f.Desc.Kind() == protoreflect.GroupKind {
			return 3 // SGROUP
		}
		return 2 // LEN
	case f.Enum != nil:
		// Repeated packed enums use LEN tag; non-packed elements use VARINT.
		if f.Desc.IsList() && f.Desc.IsPacked() {
			return 2
		}
		return 0 // VARINT
	}
	switch f.Desc.Kind() {
	case protoreflect.Int32Kind, protoreflect.Int64Kind,
		protoreflect.Uint32Kind, protoreflect.Uint64Kind,
		protoreflect.Sint32Kind, protoreflect.Sint64Kind,
		protoreflect.BoolKind:
		// Repeated packed primitives use LEN tag.
		if f.Desc.IsList() && f.Desc.IsPacked() {
			return 2
		}
		return 0 // VARINT
	case protoreflect.Fixed32Kind, protoreflect.Sfixed32Kind, protoreflect.FloatKind:
		if f.Desc.IsList() && f.Desc.IsPacked() {
			return 2
		}
		return 5 // I32
	case protoreflect.Fixed64Kind, protoreflect.Sfixed64Kind, protoreflect.DoubleKind:
		if f.Desc.IsList() && f.Desc.IsPacked() {
			return 2
		}
		return 1 // I64
	case protoreflect.StringKind, protoreflect.BytesKind:
		return 2 // LEN (never packable)
	}
	panic("unhandled kind: " + f.Desc.Kind().String())
}

// tagBytesLit returns a Lua string literal (e.g. "\"\\x0a\"") encoding the
// varint for tag = (id << 3) | wireType. Tags are 1 byte for ids ≤ 15 with
// VARINT/I32/I64, 1 byte for ids ≤ 31 with LEN, 2 bytes for ids ≤ 2047,
// and so on.
func tagBytesLit(id int32, wireType int) string {
	tag := uint64(id)*8 + uint64(wireType)
	var b []byte
	for tag >= 128 {
		b = append(b, byte(tag&0x7f)|0x80)
		tag >>= 7
	}
	b = append(b, byte(tag))
	return luaByteString(b)
}

func luaByteString(b []byte) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for _, c := range b {
		sb.WriteString(fmt.Sprintf("\\x%02x", c))
	}
	sb.WriteByte('"')
	return sb.String()
}

// scalarNotDefaultExpr returns a Lua expression that evaluates true when
// the value `v` is NOT the proto3 default for the given scalar type.
// Default is elided on encode.
//
// Floats and doubles need a sign-bit guard: -0.0 == 0.0 in IEEE, but
// they aren't the proto3 default (the wire bytes differ, and the
// TextFormatInput conformance corpus pins this). `1/v == -math.huge`
// is the standard sign-bit probe — division by +0 yields +inf, by -0
// yields -inf, and any non-zero value short-circuits via `v ~= 0`.
func scalarNotDefaultExpr(scalar, v string) string {
	switch scalar {
	case "string", "bytes":
		return v + ` ~= ''`
	case "bool":
		return v + ` ~= false`
	case "float", "double":
		return "(" + v + ` ~= 0 or 1/` + v + " == -math.huge)"
	}
	return v + ` ~= 0`
}
