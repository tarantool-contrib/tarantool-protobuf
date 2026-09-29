-- Recursion limit: every binary decoder descends at most
-- wire.RECURSION_LIMIT (100) levels of message / group nesting below the
-- top-level message and refuses deeper input with a parse error.
--
-- Without the bound, hostile input a few hundred bytes long exhausted the
-- Lua stack in the Lua codecs and, in the C codec, overflowed the fiber's
-- C stack and killed the whole process at about 90 levels. The conformance
-- suite checks the bound only in its opt-in --performance mode
-- (EnforceDepthLimit.*), so these tests pin it for every path that
-- recurses: nested messages, groups, map values, extensions, the
-- Struct/Value well-known types and skipped unknown groups.
--
-- Parametrized over both codegen modes and every decode entry point;
-- `just test-c` repeats the whole file with the C codec.
local t    = require('luatest')
local pb   = require('pb')
local wire = require('pb.wire')

local LIMIT = wire.RECURSION_LIMIT
local ERR   = 'message nesting exceeds the recursion limit (100)'

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

local RECURSIVE = 27                            -- recursive_message
local LEAF      = tag(1, 0) .. varint(123)      -- optional_int32 = 123

-- Wraps `body` (a message at level `levels`) in recursive_message fields
-- until it sits `levels` below the top-level message.
local function wrap(body, levels)
    for _ = 1, levels do body = len(RECURSIVE, body) end
    return body
end

-- A TestAllTypesProto* whose innermost message is at `levels`.
local function nested(levels) return wrap(LEAF, levels) end

-- The proto2 group `Data` (field 201) as the innermost level.
local function via_group(levels)
    return wrap(group(201, tag(202, 0) .. varint(1)), levels - 1)
end

-- The group-typed extension `groupfield` (121) as the innermost level.
local function via_extension_group(levels)
    return wrap(group(121, tag(122, 0) .. varint(1)), levels - 1)
end

-- Alternates map_string_nested_message (71) values with
-- NestedMessage.corecursive (2): each step adds two levels (the map entry
-- itself is not counted, same as the reference parsers).
local function via_map(levels)
    local body = LEAF
    for _ = 1, math.floor(levels / 2) do
        body = len(71, len(2, len(2, body)))
    end
    return wrap(body, levels % 2)
end

-- optional_value (306) -> Value.struct_value (5) -> Struct.fields (1)
-- entry value (2) -> Value -> ... Values sit on odd levels, Structs on
-- even ones; the innermost is a bool Value or an empty Struct.
local function via_struct(levels)
    local cur, is_value
    if levels % 2 == 1 then
        cur, is_value = tag(4, 0) .. '\1', true
    else
        cur, is_value = '', false
    end
    for _ = levels, 2, -1 do
        if is_value then cur = len(1, len(2, cur)) else cur = len(5, cur) end
        is_value = not is_value
    end
    return len(306, cur)
end

-- `n` unknown groups (field 999) nested inside each other.
local function unknown_groups(n)
    local body = ''
    for _ = 1, n do body = group(999, body) end
    return body
end

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g = t.group('recursion_limit.' .. mode)
    local p3 = require(mode .. '.protobuf_test_messages.proto3.test_messages_proto3_pb')
    local p2 = require(mode .. '.protobuf_test_messages.proto2.test_messages_proto2_pb')

    -- Every decode entry point a user can reach for a message type.
    local function entry_points(m, name)
        local d = m[name .. '_descriptor']
        return {
            ['pb.decode']        = function(b) return pb.decode(d, b) end,
            ['pb.decode_unsafe'] = function(b) return pb.decode_unsafe(d, b) end,
            ['_decode']          = m[name .. '_decode'],
            ['_decode_unsafe']   = m[name .. '_decode_unsafe'],
        }
    end

    local P3 = entry_points(p3, 'TestAllTypesProto3')
    local P2 = entry_points(p2, 'TestAllTypesProto2')

    -- Asserts the limit is exact for one input shape: `build(LIMIT)`
    -- decodes, `build(LIMIT + 1)` fails with the recursion-limit error.
    local function assert_bound(decoders, build)
        for name, decode in pairs(decoders) do
            local ok, err = pcall(decode, build(LIMIT))
            t.assert(ok, ('%s refused %d levels: %s'):format(name, LIMIT, tostring(err)))
            t.assert_error_msg_equals(ERR, decode, build(LIMIT + 1))
        end
    end

    g.test_nested_messages = function()
        assert_bound(P3, nested)
        assert_bound(P2, nested)
    end

    g.test_innermost_level_decodes_intact = function()
        local msg = P3['_decode'](nested(LIMIT))
        for _ = 1, LIMIT do msg = msg.recursive_message end
        t.assert_equals(msg.optional_int32, 123)
    end

    g.test_groups = function()
        assert_bound(P2, via_group)
    end

    g.test_extension_groups = function()
        assert_bound(P2, via_extension_group)
    end

    g.test_map_values = function()
        assert_bound(P3, via_map)
        assert_bound(P2, via_map)
    end

    g.test_struct_and_value = function()
        assert_bound(P3, via_struct)
    end

    -- Unknown groups are skipped, not decoded, but the skip still has to
    -- track every open group; it shares the bound.
    g.test_unknown_groups = function()
        for name, decode in pairs(P3) do
            local input = unknown_groups(LIMIT)
            local ok, msg = pcall(decode, input)
            t.assert(ok, ('%s refused %d unknown groups: %s'):format(name, LIMIT, tostring(msg)))
            t.assert_equals(hex(msg._unknown_fields), hex(input))
            t.assert_error_msg_equals(ERR, decode, unknown_groups(LIMIT + 1))
        end
    end

    -- Far past the limit every path fails cleanly instead of overflowing
    -- a stack. 2000 levels is well beyond where both used to break (about
    -- 90 for the C codec, about 1000 for full-mode Lua); the conformance
    -- test goes to 20000, which costs seconds just to build here.
    g.test_far_past_the_limit_fails_cleanly = function()
        for _, build in ipairs({nested, via_map, via_struct, unknown_groups}) do
            local input = build(2000)
            for _, decode in pairs(P3) do
                t.assert_error_msg_equals(ERR, decode, input)
            end
        end
    end
end

-- The C encoder recurses on the C stack too, and a Lua table can be
-- nested arbitrarily deep or refer to itself. It refuses to go past the
-- same bound instead of crashing. The Lua encoders need no bound: their
-- recursion ends in a catchable "stack overflow".
local c_encode = t.group('recursion_limit.c_encode')

c_encode.before_all(function()
    t.skip_if(pb.c_runtime == nil, 'C runtime disabled (PB_ENABLE_C != 1)')
end)

local function table_chain(levels)
    local root = {optional_int32 = 1}
    local cur = root
    for _ = 1, levels do
        cur.recursive_message = {optional_int32 = 1}
        cur = cur.recursive_message
    end
    return root
end

c_encode.test_bound = function()
    local p3 = require('full.protobuf_test_messages.proto3.test_messages_proto3_pb')
    local d = p3.TestAllTypesProto3_descriptor
    local bytes = pb.encode(d, table_chain(LIMIT))
    t.assert_equals(hex(bytes), hex(pb.encode(d, pb.decode(d, bytes))))
    t.assert_error_msg_equals(ERR, pb.encode, d, table_chain(LIMIT + 1))
end

c_encode.test_self_referencing_table = function()
    local p3 = require('full.protobuf_test_messages.proto3.test_messages_proto3_pb')
    local d = p3.TestAllTypesProto3_descriptor
    local cyclic = {optional_int32 = 1}
    cyclic.recursive_message = cyclic
    t.assert_error_msg_equals(ERR, pb.encode, d, cyclic)
    t.assert_error_msg_equals(ERR, p3.TestAllTypesProto3_encode, cyclic)
end
