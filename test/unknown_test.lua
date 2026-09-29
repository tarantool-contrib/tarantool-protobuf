-- Unknown-field passthrough: a decoder that meets fields not in its schema
-- must capture their raw bytes into result._unknown_fields and a subsequent
-- encode must re-emit them verbatim. Mirrors Tarantool's built-in `protobuf`
-- module convention.
local t = require('luatest')
local pb = require('pb')

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

local MODES = {'full', 'runtime'}

-- Wire-tag for (field_id, wire_type). Single-byte for id <= 15; we always
-- produce the multi-byte varint here for safety.
local function tag_bytes(id, wt)
    local v = id * 8 + wt
    local out = {}
    while v >= 0x80 do
        out[#out + 1] = string.char(v % 0x80 + 0x80)
        v = math.floor(v / 0x80)
    end
    out[#out + 1] = string.char(v)
    return table.concat(out)
end

-- Construct one byte-slice per wire type, using field IDs not declared in
-- examples/proto/hello.proto's Address (fields 1..4). These should all be
-- treated as unknown by the Address decoder.
local UNK_VARINT  = tag_bytes(50, 0) .. '\x2a'                      -- value 42
local UNK_I32     = tag_bytes(51, 5) .. '\x01\x00\x00\x00'          -- value 1
local UNK_I64     = tag_bytes(52, 1) .. '\x02\x00\x00\x00\x00\x00\x00\x00'
local UNK_LEN     = tag_bytes(53, 2) .. '\x03foo'                   -- 3-byte string

local ALL_UNK     = UNK_VARINT .. UNK_I32 .. UNK_I64 .. UNK_LEN

for _, mode in ipairs(MODES) do
    local g = t.group('unknown.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    g.test_no_unknown_means_field_absent = function()
        local dec = hello.Address_decode(hello.Address_encode({street = 'X'}))
        t.assert_equals(dec.street, 'X')
        t.assert_equals(dec._unknown_fields, nil,
            '_unknown_fields must be absent when input had only known fields')
    end

    g.test_varint_unknown_round_trips = function()
        local known = hello.Address_encode({street = 'X', zip = 7})
        local mixed = known .. UNK_VARINT
        local dec = hello.Address_decode(mixed)
        t.assert_equals(dec.street, 'X')
        t.assert_equals(dec.zip, 7)
        t.assert_equals(hex(dec._unknown_fields), hex(UNK_VARINT))
    end

    g.test_all_wire_types_captured_in_order = function()
        local known = hello.Address_encode({street = 'X'})
        local mixed = known .. ALL_UNK
        local dec = hello.Address_decode(mixed)
        t.assert_equals(dec.street, 'X')
        t.assert_equals(hex(dec._unknown_fields), hex(ALL_UNK),
            'all four wire types must be captured verbatim in source order')
    end

    g.test_unknowns_interleaved_with_knowns = function()
        -- Bytes ordering: unknown, known, unknown — capture must preserve the
        -- two unknown chunks in encounter order (the known field stays out).
        local known1 = hello.Address_encode({street = 'A'})
        local known2 = hello.Address_encode({zip = 99})
        local mixed = UNK_VARINT .. known1 .. UNK_I64 .. known2
        local dec = hello.Address_decode(mixed)
        t.assert_equals(dec.street, 'A')
        t.assert_equals(dec.zip, 99)
        t.assert_equals(hex(dec._unknown_fields), hex(UNK_VARINT .. UNK_I64))
    end

    g.test_re_encode_preserves_unknown_bytes = function()
        local mixed = hello.Address_encode({street = 'X'}) .. ALL_UNK
        local dec = hello.Address_decode(mixed)
        local re_enc = hello.Address_encode(dec)
        -- Knowns are re-encoded in field-declaration order; unknowns trail.
        local expected = hello.Address_encode({street = 'X'}) .. ALL_UNK
        t.assert_equals(hex(re_enc), hex(expected),
            'unknown bytes must be re-emitted verbatim at the tail')
    end

    g.test_re_encode_decode_idempotent = function()
        local mixed = hello.Address_encode({street = 'X', zip = 1}) .. UNK_LEN
        local dec1 = hello.Address_decode(mixed)
        local dec2 = hello.Address_decode(hello.Address_encode(dec1))
        t.assert_equals(dec2.street, 'X')
        t.assert_equals(dec2.zip, 1)
        t.assert_equals(hex(dec2._unknown_fields), hex(UNK_LEN))
    end

    g.test_empty_unknown_string_treated_as_absent = function()
        -- User explicitly sets _unknown_fields = '' on encode; should be a no-op.
        local enc = hello.Address_encode({street = 'X', _unknown_fields = ''})
        t.assert_equals(hex(enc), hex(hello.Address_encode({street = 'X'})))
    end
end

-- ---------------------------------------------------------------------------
-- Cross-mode parity: full and runtime must capture identical unknown bytes.
-- ---------------------------------------------------------------------------
local g_parity = t.group('unknown.parity')
local hello_full    = require('full.hello.hello_pb')
local hello_runtime = require('runtime.hello.hello_pb')

g_parity.test_capture_identical_across_modes = function()
    local mixed = hello_full.Address_encode({street = 'X'}) .. ALL_UNK
    local d1 = hello_full.Address_decode(mixed)
    local d2 = hello_runtime.Address_decode(mixed)
    t.assert_equals(hex(d1._unknown_fields), hex(d2._unknown_fields))
    t.assert_equals(hex(d1._unknown_fields), hex(ALL_UNK))
end

g_parity.test_reencode_identical_across_modes = function()
    local table_with_unknowns = {
        street = 'X', zip = 9, _unknown_fields = ALL_UNK,
    }
    t.assert_equals(
        hex(hello_full.Address_encode(table_with_unknowns)),
        hex(hello_runtime.Address_encode(table_with_unknowns)))
end

-- A message that declares no fields still carries unknown fields. The C
-- encoder used to return early on a plan without fields and dropped them.
for _, mode in ipairs(MODES) do
    local g = t.group('unknown.empty_message.' .. mode)
    local p3 = require(mode .. '.protobuf_test_messages.proto3.test_messages_proto3_pb')

    g.test_unknown_fields_survive_a_message_without_fields = function()
        local d = p3.NullHypothesisProto3_descriptor
        t.assert_equals(#d.fields, 0)
        for _, codec in ipairs({
            {p3.NullHypothesisProto3_decode, p3.NullHypothesisProto3_encode},
            {function(b) return pb.decode(d, b) end,
             function(m) return pb.encode(d, m) end},
        }) do
            local decode, encode = codec[1], codec[2]
            local msg = decode(ALL_UNK)
            t.assert_equals(hex(msg._unknown_fields), hex(ALL_UNK))
            t.assert_equals(hex(encode(msg)), hex(ALL_UNK))
        end
    end
end
