-- Proto2 round-trip + required-field validation, parametrized over both
-- codegen modes. The fixture is generated from test/proto/proto2_basic.proto
-- by `just gen-proto2-tests`.
local t   = require('luatest')
local ffi = require('ffi')

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g  = t.group('proto2_basic.' .. mode)
    local pb = require(mode .. '.proto2_basic.proto2_basic_pb')

    -- ----- Defaults: explicit-optional fields with [default = X] -----

    g.test_defaults_descriptor_carries_default_value = function()
        local d = pb.Defaults_descriptor.field_by_name
        t.assert_equals(d.i.default_value, 17)
        t.assert_equals(d.s.default_value, 'hello')
        t.assert_equals(d.b.default_value, true)
        t.assert_equals(d.f.default_value, 3.5)
        t.assert_equals(d.d.default_value, 1.5)
        t.assert(d.i64.default_value == ffi.cast('int64_t', 1234567890123),
            'int64 default cdata equality')
        t.assert(d.u64.default_value == ffi.cast('uint64_t', 17),
            'uint64 default cdata equality')
        t.assert_equals(d.by.default_value, '\x00\xff')
        t.assert_equals(d.color.default_value, 'GREEN')
    end

    g.test_empty_message_round_trips_to_empty_bytes = function()
        -- All proto2 fields are presence-tracked. An empty Lua table has no
        -- fields set, so encode produces zero bytes (no defaults serialized).
        local enc = pb.Defaults_encode({})
        t.assert_equals(enc, '', 'no defaults on the wire')
        t.assert_equals(pb.Defaults_decode(enc), {})
    end

    g.test_set_value_round_trip = function()
        local val = {i = 42, s = 'world', b = false, f = -1.5}
        local dec = pb.Defaults_decode(pb.Defaults_encode(val))
        t.assert_equals(dec.i, 42)
        t.assert_equals(dec.s, 'world')
        t.assert_equals(dec.b, false)
        t.assert_equals(dec.f, -1.5)
        -- d/i64/u64/by/color stay absent.
        t.assert_equals(dec.d, nil)
        t.assert_equals(dec.color, nil)
    end

    g.test_set_to_proto_default_still_serializes = function()
        -- proto2 presence means setting a field to its declared default
        -- still emits it on the wire (no proto3-style elision).
        local enc = pb.Defaults_encode({i = 17})
        t.assert_not_equals(enc, '', 'presence-tracked field at default must serialize')
        t.assert_equals(pb.Defaults_decode(enc).i, 17)
    end

    -- ----- Cardinality: required vs optional vs repeated -----

    g.test_required_missing_errors = function()
        local ok, err = pcall(pb.Cardinality_encode, {})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'required field missing on encode')
        t.assert_str_contains(err, 'proto2_basic.Cardinality.r')
    end

    g.test_required_zero_emitted = function()
        -- Required field at proto2-default zero must still be on the wire.
        local enc = pb.Cardinality_encode({r = 0})
        t.assert_equals(hex(enc), '0800',
            'required int32=0: tag 1/VARINT + varint 0')
    end

    g.test_required_set = function()
        local enc = pb.Cardinality_encode({r = 7})
        local dec = pb.Cardinality_decode(enc)
        t.assert_equals(dec.r, 7)
    end

    g.test_repeated_unpacked_by_default = function()
        -- Proto2 default for repeated scalars is NOT packed.
        local enc = pb.Cardinality_encode({r = 0, packed_default = {1, 2, 3}})
        -- field 3, wire VARINT (0x18) repeated three times.
        t.assert_equals(hex(enc), '0800' .. '180118021803')
    end

    g.test_repeated_explicit_packed = function()
        local enc = pb.Cardinality_encode({r = 0, explicitly_packed = {1, 2, 3}})
        -- field 4, wire LEN (0x22), len=3, varints 1,2,3.
        t.assert_equals(hex(enc), '0800' .. '2203' .. '010203')
    end

    g.test_repeated_explicit_unpacked = function()
        local enc = pb.Cardinality_encode({r = 0, explicitly_unpacked = {1, 2, 3}})
        -- field 5, wire VARINT (0x28) repeated three times.
        t.assert_equals(hex(enc), '0800' .. '280128022803')
    end

    g.test_repeated_decode_accepts_both_packed_and_unpacked = function()
        -- A wire stream with packed_default encoded as packed (legal — proto
        -- consumers must accept either form) decodes the same way as unpacked.
        local packed   = '\x08\x00\x1a\x03\x01\x02\x03'  -- field 3 with LEN
        local unpacked = '\x08\x00\x18\x01\x18\x02\x18\x03'
        local a = pb.Cardinality_decode(packed)
        local b = pb.Cardinality_decode(unpacked)
        t.assert_equals(a.packed_default, {1, 2, 3})
        t.assert_equals(b.packed_default, {1, 2, 3})
    end

    -- ----- Nested required message -----

    g.test_nested_required_message_missing_errors = function()
        local ok, err = pcall(pb.Nested_encode, {})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'required field missing on encode')
        t.assert_str_contains(err, 'proto2_basic.Nested.inner')
    end

    g.test_nested_required_inner_required = function()
        -- Inner message also has its own required field (x). When Inner
        -- itself is required on the outer message, missing it errors on the
        -- inner encode call.
        local ok, err = pcall(pb.Nested_encode, {inner = {}})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'proto2_basic.Nested.Inner.x')
    end

    g.test_nested_required_filled_round_trips = function()
        local val = {inner = {x = 5}, inner_opt = {x = 9}}
        local dec = pb.Nested_decode(pb.Nested_encode(val))
        t.assert_equals(dec.inner.x, 5)
        t.assert_equals(dec.inner_opt.x, 9)
    end

    -- ----- Enum default surfaced in descriptor -----

    g.test_enum_default_descriptor = function()
        local f = pb.Defaults_descriptor.field_by_name.color
        t.assert_equals(f.default_value, 'GREEN')
        -- The enum descriptor itself round-trips the symbolic name.
        t.assert_equals(pb.Defaults_Color_descriptor.by_name['GREEN'], 1)
    end

    -- ----- Proto2 legacy groups: SGROUP/EGROUP wire format -----

    g.test_group_singular_wire_bytes = function()
        -- Field 1 SGROUP (tag 0x0b) opens, body uses regular field tags
        -- (a is field 2 VARINT -> 0x10 0x07; s is field 3 LEN -> 0x1a 0x02 'ok'),
        -- EGROUP (tag 0x0c) closes. No length prefix anywhere.
        local enc = pb.WithGroup_encode({singlegroup = {a = 7, s = 'ok'}})
        t.assert_equals(hex(enc), '0b' .. '10' .. '07' .. '1a' .. '02' .. '6f' .. '6b' .. '0c')
    end

    g.test_group_round_trip = function()
        local dec = pb.WithGroup_decode(pb.WithGroup_encode(
            {singlegroup = {a = 7, s = 'ok'}}))
        t.assert_equals(dec.singlegroup.a, 7)
        t.assert_equals(dec.singlegroup.s, 'ok')
    end

    g.test_group_descriptor_kind = function()
        local f = pb.WithGroup_descriptor.field_by_name.singlegroup
        t.assert_equals(f.kind, 'group')
        t.assert_equals(pb.WithGroup_descriptor.field_by_name.repgroup.kind, 'group')
    end

    g.test_repeated_group = function()
        local enc = pb.WithGroup_encode({repgroup = {{n = 1}, {n = 2}}})
        -- Each repetition wraps its own SGROUP/EGROUP pair.
        t.assert_equals(hex(enc), '23' .. '28' .. '01' .. '24' ..
                                   '23' .. '28' .. '02' .. '24')
        local dec = pb.WithGroup_decode(enc)
        t.assert_equals(#dec.repgroup, 2)
        t.assert_equals(dec.repgroup[1].n, 1)
        t.assert_equals(dec.repgroup[2].n, 2)
    end

    g.test_group_text_render_uses_message_name = function()
        -- Proto2 convention: groups render under the capitalized submessage
        -- name (here `SingleGroup`), not the lowercase field name.
        local s = pb.WithGroup_text({singlegroup = {a = 7}})
        t.assert(s:find('SingleGroup'), 'expected SingleGroup label in: ' .. s)
        t.assert_not(s:find('singlegroup'), 'lowercase field name must not appear')
    end

    -- ----- Proto2 extensions -----

    g.test_extension_registry_uses_array_view = function()
        -- The hot encode loop iterates extensions_list (array) rather than
        -- pairs() over extensions_by_full_name to stay JIT-stable. If a
        -- future refactor drops the array view, encode silently falls off
        -- the JIT — pin both indices here.
        local d = pb.BenchPayload_descriptor
        t.assert(type(d.extensions_list) == 'table',
            'extensions_list array view must exist')
        t.assert(#d.extensions_list >= 2)
        t.assert(d.extensions_by_id[100])
        t.assert(d.extensions_by_full_name['proto2_basic.ext_count'])
    end

    g.test_extension_round_trip = function()
        local msg = {
            id = 7,
            _extensions = {
                ['proto2_basic.ext_count'] = 42,
                ['proto2_basic.ext_label'] = 'tag',
            },
        }
        local dec = pb.BenchPayload_decode(pb.BenchPayload_encode(msg))
        t.assert_equals(dec.id, 7)
        t.assert_equals(dec._extensions['proto2_basic.ext_count'], 42)
        t.assert_equals(dec._extensions['proto2_basic.ext_label'], 'tag')
    end

    g.test_extension_inline_codegen_walks_them = function()
        -- Regression pin: the inline (full-mode) generated code added an
        -- explicit extensions walk after the field loop. Verify that the
        -- bytes-on-wire match what the runtime codec produces for the
        -- same input.
        local full    = require('full.proto2_basic.proto2_basic_pb')
        local runtime = require('runtime.proto2_basic.proto2_basic_pb')
        local msg = {
            id = 9,
            _extensions = {['proto2_basic.ext_count'] = 17},
        }
        t.assert_equals(
            hex(full.BenchPayload_encode(msg)),
            hex(runtime.BenchPayload_encode(msg)),
            'inline and runtime extension emission must match byte-for-byte')
    end
end

-- Dynamic (source-parsed) proto2: load test/proto/proto2_basic.proto at
-- runtime and assert the same semantics as the build-time generated
-- modules. The static-vs-dynamic byte-parity is the conformance claim.
do
    local g    = t.group('proto2_basic.dynamic')
    local pb   = require('pb')
    local fio  = require('fio')
    local REPO_ROOT  = fio.abspath(fio.pathjoin(
        fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
    local PROTO_PATH = fio.pathjoin(REPO_ROOT, 'test', 'proto', 'proto2_basic.proto')

    local source = (function()
        local f = assert(io.open(PROTO_PATH, 'rb'))
        local s = f:read('*a'); f:close(); return s
    end)()
    local dyn = pb.parse(source)

    g.test_parser_records_proto2_syntax = function()
        local ast = pb.parser.parse(source)
        t.assert_equals(ast.syntax, 'proto2')
    end

    g.test_parser_captures_default = function()
        local ast = pb.parser.parse(source)
        local defaults
        for _, m in ipairs(ast.messages) do
            if m.name == 'Defaults' then defaults = m; break end
        end
        t.assert(defaults)
        local fmap = {}
        for _, f in ipairs(defaults.fields) do fmap[f.name] = f end
        t.assert_equals(fmap.i.default_value, 17)
        t.assert_equals(fmap.s.default_value, 'hello')
        t.assert_equals(fmap.b.default_value, true)
        t.assert_equals(fmap.color.default_value, 'GREEN')
    end

    g.test_parser_marks_required = function()
        local ast = pb.parser.parse(source)
        local card
        for _, m in ipairs(ast.messages) do
            if m.name == 'Cardinality' then card = m; break end
        end
        t.assert(card)
        local fmap = {}
        for _, f in ipairs(card.fields) do fmap[f.name] = f end
        t.assert(fmap.r.required, 'r is required')
        t.assert(fmap.o.optional, 'o is optional')
        t.assert_not(fmap.o.required)
    end

    g.test_dynamic_descriptor_surfaces_required = function()
        local desc = dyn.Cardinality_descriptor
        local r = desc.field_by_name and desc.field_by_name.r
            or (function()
                for _, f in ipairs(desc.fields) do
                    if f.name == 'r' then return f end
                end
            end)()
        t.assert(r and r.required, 'dynamic Cardinality.r must carry required=true')
    end

    g.test_dynamic_required_missing_errors = function()
        local ok, err = pcall(dyn.Cardinality_encode, {})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'required field missing')
    end

    g.test_dynamic_repeated_unpacked_by_default = function()
        -- Proto2 default for repeated scalars is NOT packed; the dynamic
        -- builder must flip the rule based on parsed.syntax.
        local enc = dyn.Cardinality_encode({r = 0, packed_default = {1, 2, 3}})
        t.assert_equals(hex(enc), '0800' .. '180118021803')
    end

    g.test_dynamic_byte_parity_with_static = function()
        -- Same value through dynamic and static (full mode) must produce
        -- identical wire bytes.
        local full = require('full.proto2_basic.proto2_basic_pb')
        local val  = {
            r = 1, o = 2,
            packed_default      = {3, 4, 5},
            explicitly_packed   = {6, 7, 8},
            explicitly_unpacked = {9, 10},
        }
        t.assert_equals(hex(dyn.Cardinality_encode(val)),
            hex(full.Cardinality_encode(val)),
            'dynamic and static must agree byte-for-byte')
    end
end

-- JSON and text format: proto2 fields are all presence-tracked, so the
-- elision rules built around proto3's implicit zero defaults must not
-- fire on required-set-to-zero or optional-set-to-default.
do
    local g    = t.group('proto2_basic.codecs')
    local pb   = require('pb')
    local full = require('full.proto2_basic.proto2_basic_pb')

    g.test_json_required_zero_emitted = function()
        local s = pb.json.encode(full.Cardinality_descriptor, {r = 0})
        local d = pb.json.decode(full.Cardinality_descriptor, s)
        t.assert_equals(d.r, 0)
        t.assert(s:find('"r"%s*:%s*0'), 'required int32=0 must appear in JSON: ' .. s)
    end

    g.test_json_optional_default_emitted_when_set = function()
        local s = pb.json.encode(full.Defaults_descriptor, {i = 17, b = false})
        t.assert(s:find('"i"'), 'optional int32 at declared default must be emitted')
        t.assert(s:find('"b"%s*:%s*false'), 'optional bool=false must be emitted')
    end

    g.test_json_absent_optional_not_emitted = function()
        -- Even with emit_defaults, proto2 presence-tracked fields stay
        -- absent if the user didn't set them. We don't auto-materialize
        -- declared defaults into JSON output.
        local s = pb.json.encode(full.Defaults_descriptor, {}, {emit_defaults = true})
        t.assert_not(s:find('"i"'), 'absent optional must not be emitted')
        t.assert_not(s:find('"color"'), 'absent enum optional must not be emitted')
    end

    g.test_text_required_zero_emitted = function()
        local s = pb.text.encode(full.Cardinality_descriptor, {r = 0})
        t.assert(s:find('r:%s*0'), 'required int32=0 must appear in text format: ' .. s)
    end
end

-- Parity: full and runtime modes must produce byte-identical output for
-- the same input. Equivalent to the existing parity.full_vs_runtime group.
do
    local g = t.group('proto2_basic.parity')
    local full    = require('full.proto2_basic.proto2_basic_pb')
    local runtime = require('runtime.proto2_basic.proto2_basic_pb')

    local function check_parity(msg, encode_full, encode_runtime, value)
        local bf, br = encode_full(value), encode_runtime(value)
        t.assert_equals(hex(bf), hex(br),
            msg .. ': full and runtime modes must produce identical bytes')
    end

    g.test_defaults_round_trip_parity = function()
        check_parity('Defaults set values', full.Defaults_encode,
            runtime.Defaults_encode,
            {i = 42, s = 'world', b = true, f = 0.5, d = -1.5})
    end

    g.test_cardinality_required_parity = function()
        check_parity('Cardinality.r=0', full.Cardinality_encode,
            runtime.Cardinality_encode, {r = 0})
        check_parity('Cardinality full', full.Cardinality_encode,
            runtime.Cardinality_encode, {
                r = 1,
                o = 2,
                packed_default      = {3, 4, 5},
                explicitly_packed   = {6, 7, 8},
                explicitly_unpacked = {9, 10},
            })
    end

    g.test_nested_parity = function()
        check_parity('Nested', full.Nested_encode, runtime.Nested_encode,
            {inner = {x = 5}, inner_opt = {x = 9}})
    end
end
