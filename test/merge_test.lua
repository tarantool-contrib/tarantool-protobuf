-- Merge semantics of a repeated singular message field on the binary wire.
--
-- When a singular message field occurs more than once, the occurrences
-- merge into one message: scalars last-wins, repeated fields concatenate,
-- nested messages merge recursively, a oneof member clears its siblings,
-- and proto2 extensions and unknown fields of every occurrence survive.
-- These tests pin the cases the conformance suite only exercises in its
-- opt-in --performance mode (TestBinaryPerformanceMergeMessageWith*), so a
-- regression shows up in `just test` rather than only in that run.
--
-- Parametrized over both codegen modes; `just test-c` repeats the whole
-- file with the C codec.
local t = require('luatest')

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

local function varint(v)
    local out = {}
    while v >= 0x80 do
        out[#out + 1] = string.char(v % 0x80 + 0x80)
        v = math.floor(v / 0x80)
    end
    out[#out + 1] = string.char(v)
    return table.concat(out)
end

local function tag(id, wt) return varint(id * 8 + wt) end

-- A length-delimited field `id` wrapping `body`.
local function len(id, body) return tag(id, 2) .. varint(#body) .. body end

-- Field 27 is recursive_message in both TestAllTypesProto3 and
-- TestAllTypesProto2; field 999 is unknown to both.
local RECURSIVE = 27
local function unknown(v) return tag(999, 0) .. varint(v) end

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g = t.group('merge.' .. mode)
    local p3 = require(mode .. '.protobuf_test_messages.proto3.test_messages_proto3_pb')
    local p2 = require(mode .. '.protobuf_test_messages.proto2.test_messages_proto2_pb')

    local SCHEMAS = {
        proto3 = {p3.TestAllTypesProto3_decode, p3.TestAllTypesProto3_encode},
        proto2 = {p2.TestAllTypesProto2_decode, p2.TestAllTypesProto2_encode},
    }

    for name, s in pairs(SCHEMAS) do
        local decode, encode = s[1], s[2]

        -- The minimal repro: each occurrence carries one unknown field,
        -- the merged message must carry both, in wire order.
        g['test_unknown_fields_of_every_occurrence_survive_' .. name] = function()
            local input = len(RECURSIVE, unknown(1)) .. len(RECURSIVE, unknown(2))
            t.assert_equals(hex(input), 'da0103b83e01da0103b83e02')
            local msg = decode(input)
            t.assert_equals(hex(msg.recursive_message._unknown_fields),
                hex(unknown(1) .. unknown(2)))
            t.assert_equals(hex(encode(msg)), 'da0106b83e01b83e02')
        end

        -- Unknown fields one level further down merge through the
        -- recursive merge of the inner message.
        g['test_nested_unknown_fields_merge_' .. name] = function()
            local input = len(RECURSIVE, len(RECURSIVE, unknown(1)))
                       .. len(RECURSIVE, len(RECURSIVE, unknown(2)))
            local msg = decode(input)
            t.assert_equals(msg.recursive_message._unknown_fields, nil)
            t.assert_equals(hex(encode(msg)),
                hex(len(RECURSIVE, len(RECURSIVE, unknown(1) .. unknown(2)))))
        end

        -- An occurrence without unknown fields must not drop those an
        -- earlier one brought, and known fields keep merging alongside.
        g['test_unknown_fields_mix_with_known_fields_' .. name] = function()
            local input = len(RECURSIVE, unknown(1))
                       .. len(RECURSIVE, tag(1, 0) .. varint(7))  -- optional_int32
                       .. len(RECURSIVE, unknown(3))
            local msg = decode(input)
            t.assert_equals(msg.recursive_message.optional_int32, 7)
            t.assert_equals(hex(msg.recursive_message._unknown_fields),
                hex(unknown(1) .. unknown(3)))
        end

        -- The shape of the conformance performance test, scaled down:
        -- N occurrences collapse into one message with N unknown fields.
        g['test_many_occurrences_collapse_into_one_' .. name] = function()
            local n = 1000
            local occ, want = {}, {}
            for i = 1, n do
                occ[i] = len(RECURSIVE, unknown(i % 100))
                want[i] = unknown(i % 100)
            end
            local out = encode(decode(table.concat(occ)))
            t.assert_equals(hex(out), hex(len(RECURSIVE, table.concat(want))))
        end

        -- A oneof member set by a later occurrence wins over the sibling
        -- an earlier occurrence left behind — in both declaration orders,
        -- since the encoder resolves two set members by declaration order.
        g['test_later_oneof_member_clears_earlier_sibling_' .. name] = function()
            local uint32 = tag(111, 0) .. varint(5)          -- oneof_uint32
            local str    = tag(113, 2) .. varint(1) .. 'x'   -- oneof_string

            local msg = decode(len(RECURSIVE, str) .. len(RECURSIVE, uint32))
            t.assert_equals(msg.recursive_message.oneof_uint32, 5)
            t.assert_equals(msg.recursive_message.oneof_string, nil)
            t.assert_equals(hex(encode(msg)), hex(len(RECURSIVE, uint32)))

            msg = decode(len(RECURSIVE, uint32) .. len(RECURSIVE, str))
            t.assert_equals(msg.recursive_message.oneof_string, 'x')
            t.assert_equals(msg.recursive_message.oneof_uint32, nil)
            t.assert_equals(hex(encode(msg)), hex(len(RECURSIVE, str)))
        end
    end

    -- Proto2 extensions follow the same rules as regular fields: an
    -- extension from one occurrence survives the next, and a scalar
    -- extension set twice takes the last value.
    g.test_extensions_of_every_occurrence_survive = function()
        local ext = 'protobuf_test_messages.proto2.extension_int32'
        local ext_field = function(v) return tag(120, 0) .. varint(v) end

        local msg = p2.TestAllTypesProto2_decode(
            len(RECURSIVE, ext_field(7)) .. len(RECURSIVE, tag(1, 0) .. varint(1)))
        t.assert_equals(msg.recursive_message.optional_int32, 1)
        t.assert_equals(msg.recursive_message._extensions[ext], 7)

        msg = p2.TestAllTypesProto2_decode(
            len(RECURSIVE, ext_field(7)) .. len(RECURSIVE, ext_field(8)))
        t.assert_equals(msg.recursive_message._extensions[ext], 8)
        t.assert_equals(hex(p2.TestAllTypesProto2_encode(msg)),
            hex(len(RECURSIVE, ext_field(8))))
    end
end
