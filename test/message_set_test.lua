-- MessageSet wire format (`option message_set_wire_format = true`).
--
-- A MessageSet message has no fields of its own, only extensions, and each
-- extension travels as an item group rather than as a field keyed by the
-- extension number:
--
--   group 1 { uint32 type_id = 2; bytes message = 3; }
--
-- Fixtures come from the conformance suite's TestAllTypesProto2, whose
-- field 500 `message_set_correct` is a MessageSet with two registered
-- extensions. The cases mirror the suite's ValidMessageSetEncoding*,
-- MessageSetEncoding.UnknownExtension and EnforceDepthLimit.
-- MessageSetExtension tests; the last one only runs with --performance.
--
-- Parametrized over both codegen modes and both decode entry points;
-- `just test-c` repeats the whole file with the C codec.
local t    = require('luatest')
local pb   = require('pb')
local wire = require('pb.wire')

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
local function len(id, body) return tag(id, 2) .. varint(#body) .. body end
local function group(id, body) return tag(id, 3) .. body .. tag(id, 4) end

local SET = 500   -- TestAllTypesProto2.message_set_correct

local PKG  = 'protobuf_test_messages.proto2.TestAllTypesProto2.'
local EXT1 = PKG .. 'MessageSetCorrectExtension1.message_set_extension'   -- 1547769
local EXT2 = PKG .. 'MessageSetCorrectExtension2.message_set_extension'   -- 4135312
local ONEOF = PKG .. 'ExtensionWithOneof.extension_with_oneof'            -- 123456789

local function item(type_id, message)
    return group(1, tag(2, 0) .. varint(type_id) .. len(3, message))
end

-- MessageSetCorrectExtension2 { i = v }
local function ext2(v) return tag(9, 0) .. varint(v) end

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g  = t.group('message_set.' .. mode)
    local p2 = require(mode .. '.protobuf_test_messages.proto2.test_messages_proto2_pb')
    local d  = p2.TestAllTypesProto2_descriptor

    local DECODERS = {
        ['pb.decode'] = function(b) return pb.decode(d, b) end,
        ['_decode']   = p2.TestAllTypesProto2_decode,
    }
    local function encode(m) return p2.TestAllTypesProto2_encode(m) end

    g.test_descriptor_is_marked = function()
        t.assert_equals(p2.TestAllTypesProto2_MessageSetCorrect_descriptor.message_set, true)
        t.assert_equals(p2.TestAllTypesProto2_descriptor.message_set, nil)
    end

    g.test_item_decodes_into_extension = function()
        for name, decode in pairs(DECODERS) do
            local msg = decode(len(SET, item(4135312, ext2(99))))
            local set = msg.message_set_correct
            t.assert_equals(set._extensions[EXT2], {i = 99}, name)
            t.assert_equals(set._unknown_fields, nil, name)
        end
    end

    -- The item's fields may come in either order.
    g.test_item_fields_in_any_order = function()
        local input = len(SET, group(1, len(3, ext2(99)) .. tag(2, 0) .. varint(4135312)))
        for name, decode in pairs(DECODERS) do
            t.assert_equals(decode(input).message_set_correct._extensions[EXT2],
                {i = 99}, name)
        end
    end

    -- An extension encoded as an ordinary field (by an encoder unaware of
    -- the MessageSet format) is accepted too...
    g.test_plain_extension_field_is_accepted = function()
        for name, decode in pairs(DECODERS) do
            local msg = decode(len(SET, len(4135312, ext2(99))))
            t.assert_equals(msg.message_set_correct._extensions[EXT2], {i = 99}, name)
        end
    end

    -- ...and merges with an item for the same extension in wire order: the
    -- oneof member set by the later item wins. Were the plain field kept
    -- as unknown and re-appended, `a` would win instead.
    g.test_plain_field_and_item_merge_in_wire_order = function()
        local input = len(SET, len(123456789, tag(1, 0) .. varint(42))
            .. item(123456789, tag(2, 0) .. varint(99)))
        for name, decode in pairs(DECODERS) do
            t.assert_equals(decode(input).message_set_correct._extensions[ONEOF],
                {b = 99}, name)
        end
    end

    g.test_two_items_for_one_extension_merge = function()
        local input = len(SET, item(1547769, tag(25, 2) .. varint(1) .. 'x')
            .. item(4135312, ext2(1)) .. item(4135312, ext2(2)))
        for name, decode in pairs(DECODERS) do
            local exts = decode(input).message_set_correct._extensions
            t.assert_equals(exts[EXT1], {str = 'x'}, name)
            t.assert_equals(exts[EXT2], {i = 2}, name)
        end
    end

    -- An item for an unregistered type_id is kept verbatim and re-encoded
    -- unchanged, even when its payload would not parse.
    g.test_unknown_type_id_round_trips = function()
        local unknown = item(4135300, tag(0, 0) .. varint(99))
        local input = len(SET, unknown)
        for name, decode in pairs(DECODERS) do
            local msg = decode(input)
            t.assert_equals(hex(msg.message_set_correct._unknown_fields), hex(unknown), name)
            t.assert_equals(msg.message_set_correct._extensions, nil, name)
            t.assert_equals(hex(encode(msg)), hex(input), name)
        end
    end

    -- Extensions are written as items, whatever form they were read in.
    g.test_encode_writes_items = function()
        local msg = {message_set_correct = {_extensions = {[EXT2] = {i = 99}}}}
        local want = len(SET, item(4135312, ext2(99)))
        t.assert_equals(hex(encode(msg)), hex(want))
        t.assert_equals(hex(pb.encode(d, msg)), hex(want))
        for name, decode in pairs(DECODERS) do
            t.assert_equals(hex(encode(decode(len(SET, len(4135312, ext2(99)))))),
                hex(want), name)
        end
    end

    g.test_text_and_json = function()
        local msg = {message_set_correct = {_extensions = {[EXT2] = {i = 99}}}}
        local text = pb.text.encode(d, msg)
        t.assert_str_contains(text, '[' .. EXT2 .. ']')
        t.assert_equals(hex(encode(pb.text.decode(d, text))), hex(encode(msg)))
        local json = pb.json.encode(d, msg)
        t.assert_equals(hex(encode(pb.json.decode(d, json))), hex(encode(msg)))
    end

    -- MessageSetCorrectExtension2.sub_msg is itself a MessageSet, so items
    -- nest: set -> extension -> set -> ... The recursion limit counts each
    -- message on the way down, the same as for ordinary fields.
    g.test_nested_items_obey_recursion_limit = function()
        -- A MessageSet at `levels` below the top-level message, reached
        -- through alternating extension messages and sub_msg fields.
        local function chain(levels)
            local body = ''                            -- innermost MessageSet
            for _ = 2, levels, 2 do
                body = item(4135312, len(10, body))    -- ext2 { sub_msg = body }
            end
            return len(SET, body)
        end
        local limit = wire.RECURSION_LIMIT
        local err = ('message nesting exceeds the recursion limit (%d)'):format(limit)
        for name, decode in pairs(DECODERS) do
            local ok, e = pcall(decode, chain(limit - 1))
            t.assert(ok, name .. ': ' .. tostring(e))
            t.assert_error_msg_equals(err, decode, chain(limit + 1))
            t.assert_error_msg_equals(err, decode, chain(2001))
        end
    end
end
