-- Tests for google.protobuf.Struct / Value / ListValue.
-- Lua surface:
--   * box.NULL                      ↔ null_value
--   * boolean                       ↔ bool_value
--   * number                        ↔ number_value (double)
--   * string                        ↔ string_value
--   * table (hash-like)             ↔ Struct
--   * table (array-like or pb.wkt.list-tagged) ↔ ListValue
local t   = require('luatest')
local pb  = require('pb')
local wkt = pb.wkt

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Direct Value wire format
-- ---------------------------------------------------------------------------
local g = t.group('struct_value.wire')

g.test_null_round_trip = function()
    local enc = wkt.Value_encode(pb.NULL)
    t.assert_equals(hex(enc), '0800',
        'NULL encodes as field 1 (null_value) varint 0')
    t.assert_equals(wkt.Value_decode(enc), pb.NULL)
end

g.test_bool_branches = function()
    t.assert_equals(hex(wkt.Value_encode(true)),  '2001')
    t.assert_equals(hex(wkt.Value_encode(false)), '2000')
    t.assert_equals(wkt.Value_decode(wkt.Value_encode(true)),  true)
    t.assert_equals(wkt.Value_decode(wkt.Value_encode(false)), false)
end

g.test_number_round_trip = function()
    local samples = {0, 1, -1, 3.14159, 1e100, -1e-10, math.huge}
    for _, n in ipairs(samples) do
        local r = wkt.Value_decode(wkt.Value_encode(n))
        if n ~= n then
            t.assert(r ~= r, 'NaN round trip preserves NaN-ness')
        else
            t.assert_equals(r, n)
        end
    end
end

g.test_string_round_trip = function()
    for _, s in ipairs({'', 'hello', 'unicode: ünîcö∂é', string.rep('x', 1024)}) do
        t.assert_equals(wkt.Value_decode(wkt.Value_encode(s)), s)
    end
end

g.test_empty_buf_decodes_as_null = function()
    -- Empty Value{} on wire has no kind set → conventional reading is NULL.
    t.assert_equals(wkt.Value_decode(''), pb.NULL)
end

g.test_unknown_field_in_value_falls_back_to_null = function()
    -- A Value with only an unknown field id (e.g. field 99 varint).
    local buf = '\x98\x06\x2a'  -- tag(99, varint), value 42
    t.assert_equals(wkt.Value_decode(buf), pb.NULL)
end

-- ---------------------------------------------------------------------------
-- Struct
-- ---------------------------------------------------------------------------
local gs = t.group('struct_value.struct')

gs.test_empty_struct = function()
    t.assert_equals(wkt.Struct_encode({}), '')
    local dec = wkt.Struct_decode('')
    t.assert_equals(next(dec), nil)
end

gs.test_scalar_struct_round_trip = function()
    local s = {name = 'Alice', age = 30, active = true, deleted = pb.NULL}
    local dec = wkt.Struct_decode(wkt.Struct_encode(s))
    t.assert_equals(dec.name, 'Alice')
    t.assert_equals(dec.age, 30)
    t.assert_equals(dec.active, true)
    t.assert_equals(dec.deleted, pb.NULL)
end

gs.test_nested_struct = function()
    local s = {outer = {inner = {leaf = 42}}}
    local dec = wkt.Struct_decode(wkt.Struct_encode(s))
    t.assert_equals(dec.outer.inner.leaf, 42)
end

-- ---------------------------------------------------------------------------
-- ListValue
-- ---------------------------------------------------------------------------
local gl = t.group('struct_value.list')

gl.test_empty_list = function()
    t.assert_equals(wkt.ListValue_encode(wkt.list({})), '')
    local dec = wkt.ListValue_decode('')
    t.assert_equals(#dec, 0)
end

gl.test_mixed_element_list_round_trip = function()
    local list = wkt.list({1, 'two', true, pb.NULL, wkt.struct({k = 'v'})})
    local dec = wkt.ListValue_decode(wkt.ListValue_encode(list))
    t.assert_equals(#dec, 5)
    t.assert_equals(dec[1], 1)
    t.assert_equals(dec[2], 'two')
    t.assert_equals(dec[3], true)
    t.assert_equals(dec[4], pb.NULL)
    t.assert_equals(dec[5].k, 'v')
end

gl.test_array_like_table_auto_routes_to_list = function()
    -- A plain {1,2,3} (no tagging) is detected as list because t[1] ~= nil.
    local v_buf = wkt.Value_encode({10, 20, 30})
    local dec = wkt.Value_decode(v_buf)
    t.assert_equals(type(dec), 'table')
    t.assert_equals(#dec, 3)
    t.assert_equals(dec[2], 20)
end

gl.test_empty_table_routes_to_struct = function()
    -- Empty {} → Struct (more common dict-like case).
    local v_buf = wkt.Value_encode({})
    -- Tag should be 0x2a (field 5, struct_value).
    t.assert_equals(v_buf:byte(1), 0x2a)
end

-- ---------------------------------------------------------------------------
-- Round-trip Value through wire then back; verify Struct/List tagging survives.
-- ---------------------------------------------------------------------------
local gt = t.group('struct_value.tagging')

gt.test_decoded_struct_round_trips_byte_equal = function()
    local original = wkt.struct({a = 1, b = 'hi'})
    local enc1 = wkt.Value_encode(original)
    local roundtrip = wkt.Value_decode(enc1)
    local enc2 = wkt.Value_encode(roundtrip)
    t.assert_equals(hex(enc1), hex(enc2))
end

gt.test_decoded_empty_list_round_trips_byte_equal = function()
    -- Without tagging, an empty list would re-encode as struct. Decoded
    -- ListValue keeps its LIST_MT so the next encode reproduces the wire.
    local enc1 = wkt.Value_encode(wkt.list({}))
    local roundtrip = wkt.Value_decode(enc1)
    local enc2 = wkt.Value_encode(roundtrip)
    t.assert_equals(hex(enc1), hex(enc2))
end

-- ---------------------------------------------------------------------------
-- End-to-end: generated Event message exercising payload/attribute/tags.
-- ---------------------------------------------------------------------------
for _, mode in ipairs({'full', 'runtime'}) do
    local ge = t.group('struct_value.event.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    ge.test_event_with_struct_and_list = function()
        local e = {
            title     = 'launch',
            payload   = wkt.struct({region = 'eu-west-1', priority = 2, urgent = true}),
            attribute = 'experimental',
            tags      = wkt.list({'alpha', 'beta', 99}),
        }
        local dec = hello.Event_decode(hello.Event_encode(e))
        t.assert_equals(dec.title, 'launch')
        t.assert_equals(dec.payload.region, 'eu-west-1')
        t.assert_equals(dec.payload.priority, 2)
        t.assert_equals(dec.payload.urgent, true)
        t.assert_equals(dec.attribute, 'experimental')
        t.assert_equals(#dec.tags, 3)
        t.assert_equals(dec.tags[1], 'alpha')
        t.assert_equals(dec.tags[3], 99)
    end

    ge.test_event_attribute_with_null = function()
        local e = {title = 'x', attribute = pb.NULL}
        local dec = hello.Event_decode(hello.Event_encode(e))
        t.assert_equals(dec.attribute, pb.NULL)
    end

    ge.test_event_with_nested_struct = function()
        local e = {
            payload = wkt.struct({
                stats = wkt.struct({calls = 7, errors = 0}),
                hosts = wkt.list({'a.example', 'b.example'}),
            }),
        }
        local dec = hello.Event_decode(hello.Event_encode(e))
        t.assert_equals(dec.payload.stats.calls, 7)
        t.assert_equals(dec.payload.stats.errors, 0)
        t.assert_equals(#dec.payload.hosts, 2)
        t.assert_equals(dec.payload.hosts[2], 'b.example')
    end
end

-- ---------------------------------------------------------------------------
-- Parity: full and runtime mode produce identical bytes for Event.
-- ---------------------------------------------------------------------------
local gp = t.group('struct_value.parity')
local hello_full    = require('full.hello.hello_pb')
local hello_runtime = require('runtime.hello.hello_pb')

gp.test_event_bytes_match = function()
    local e = {
        title     = 'parity',
        payload   = wkt.struct({k = 'v', n = 42, flag = pb.NULL}),
        attribute = wkt.list({1, 2, 3}),
        tags      = wkt.list({'x', 'y'}),
    }
    t.assert_equals(hex(hello_full.Event_encode(e)),
                    hex(hello_runtime.Event_encode(e)))
end
