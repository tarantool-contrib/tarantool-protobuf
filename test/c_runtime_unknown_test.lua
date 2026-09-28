-- C-side unknown-fields capture + re-emission.
--
-- A C-runtime decoder that meets fields not in the plan must capture
-- their raw bytes into result._unknown_fields, and a subsequent C
-- encode must re-emit them verbatim — same contract as
-- test/unknown_test.lua against the pure-Lua paths.
--
-- Gated on PB_ENABLE_C=1 + a loadable c_runtime module, same as the
-- sibling c_runtime_*_test.lua files.

local t = require('luatest')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

-- Wire-tag for (field_id, wire_type). Multi-byte varint emission for
-- field ids > 15 — Address has fields 1..4 declared, so 50/51/52/53 are
-- guaranteed unknown.
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

-- One byte-slice per wire type. Field ids picked outside Address (1..4).
local UNK_VARINT  = tag_bytes(50, 0) .. '\x2a'                      -- value 42
local UNK_I32     = tag_bytes(51, 5) .. '\x01\x00\x00\x00'          -- value 1
local UNK_I64     = tag_bytes(52, 1) .. '\x02\x00\x00\x00\x00\x00\x00\x00'
local UNK_LEN     = tag_bytes(53, 2) .. '\x03foo'                   -- 3-byte string

local ALL_UNK     = UNK_VARINT .. UNK_I32 .. UNK_I64 .. UNK_LEN

local full_hello

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_unknown.' .. mode)
    local hello
    local plan

    g.before_all(function()
        skip_if_no_c()
        hello = require(mode .. '.hello.hello_pb')
        full_hello = require('full.hello.hello_pb')
        plan = c_runtime.compile_plan(hello.Address_descriptor)
    end)

    g.before_each(skip_if_no_c)

    function g.test_no_unknown_means_field_absent()
        local dec = c_runtime.decode(plan,
            c_runtime.encode(plan, {street = 'X'}))
        t.assert_equals(dec.street, 'X')
        t.assert_equals(dec._unknown_fields, nil,
            '_unknown_fields must be absent when input had only known fields')
    end

    function g.test_varint_unknown_round_trips()
        local known = c_runtime.encode(plan, {street = 'X', zip = 7})
        local mixed = known .. UNK_VARINT
        local dec = c_runtime.decode(plan, mixed)
        t.assert_equals(dec.street, 'X')
        t.assert_equals(dec.zip, 7)
        t.assert_equals(hex(dec._unknown_fields), hex(UNK_VARINT))
    end

    function g.test_all_wire_types_captured_in_order()
        local known = c_runtime.encode(plan, {street = 'X'})
        local mixed = known .. ALL_UNK
        local dec = c_runtime.decode(plan, mixed)
        t.assert_equals(dec.street, 'X')
        t.assert_equals(hex(dec._unknown_fields), hex(ALL_UNK),
            'all four wire types must be captured verbatim in source order')
    end

    function g.test_unknowns_interleaved_with_knowns()
        -- Bytes order: unknown, known, unknown — capture must preserve
        -- the two unknown chunks in encounter order, knowns stay parsed.
        local known1 = c_runtime.encode(plan, {street = 'A'})
        local known2 = c_runtime.encode(plan, {zip = 99})
        local mixed = UNK_VARINT .. known1 .. UNK_I64 .. known2
        local dec = c_runtime.decode(plan, mixed)
        t.assert_equals(dec.street, 'A')
        t.assert_equals(dec.zip, 99)
        t.assert_equals(hex(dec._unknown_fields), hex(UNK_VARINT .. UNK_I64))
    end

    function g.test_re_encode_preserves_unknown_bytes()
        local mixed = c_runtime.encode(plan, {street = 'X'}) .. ALL_UNK
        local dec = c_runtime.decode(plan, mixed)
        local re_enc = c_runtime.encode(plan, dec)
        local expected = c_runtime.encode(plan, {street = 'X'}) .. ALL_UNK
        t.assert_equals(hex(re_enc), hex(expected),
            'unknown bytes must be re-emitted verbatim at the tail')
    end

    function g.test_re_encode_decode_idempotent()
        local mixed = c_runtime.encode(plan, {street = 'X', zip = 1}) .. UNK_LEN
        local dec1 = c_runtime.decode(plan, mixed)
        local dec2 = c_runtime.decode(plan,
            c_runtime.encode(plan, dec1))
        t.assert_equals(dec2.street, 'X')
        t.assert_equals(dec2.zip, 1)
        t.assert_equals(hex(dec2._unknown_fields), hex(UNK_LEN))
    end

    function g.test_empty_unknown_string_treated_as_absent()
        -- User explicitly sets _unknown_fields = '' on encode; must be
        -- a no-op (mirrors codec.lua's nil/'' short-circuit).
        local enc = c_runtime.encode(plan,
            {street = 'X', _unknown_fields = ''})
        t.assert_equals(hex(enc),
            hex(c_runtime.encode(plan, {street = 'X'})))
    end

    function g.test_capture_matches_pure_lua_decode()
        -- Acceptance: shape-for-shape parity with the pure-Lua decode
        -- for the same mixed input.
        local mixed = full_hello.Address_encode({street = 'X'}) .. ALL_UNK
        local c_dec   = c_runtime.decode(plan, mixed)
        local lua_dec = full_hello.Address_decode(mixed)
        t.assert_equals(hex(c_dec._unknown_fields),
                        hex(lua_dec._unknown_fields))
    end

    function g.test_reencode_matches_pure_lua_with_seeded_unknown_bytes()
        -- Table with _unknown_fields set — encode under C must agree
        -- byte-for-byte with the pure-Lua encoder.
        local tbl = {street = 'X', zip = 9, _unknown_fields = ALL_UNK}
        t.assert_equals(
            hex(c_runtime.encode(plan, tbl)),
            hex(full_hello.Address_encode(tbl)))
    end
end

-- ---------------------------------------------------------------------------
-- Nested-message coverage: each recursive decode_body gets its own
-- _unknown_fields buffer — parent and child must not bleed into each
-- other.
-- ---------------------------------------------------------------------------
local g_nested = t.group('c_runtime_unknown.nested')
local full_hello_n

g_nested.before_all(function()
    skip_if_no_c()
    full_hello_n = require('full.hello.hello_pb')
end)

g_nested.before_each(skip_if_no_c)

g_nested.test_inner_unknown_isolated_from_outer = function()
    -- Build a Person whose nested address payload includes an unknown
    -- trailing tag. The outer Person decode must NOT inherit the inner
    -- _unknown_fields. Acceptance for the per-frame buffer isolation.
    local person_plan = c_runtime.compile_plan(
        full_hello_n.Person_descriptor)
    local addr_plan   = c_runtime.compile_plan(
        full_hello_n.Address_descriptor)

    -- inner address body = encode({street = 'X'}) plus an unknown tag
    local addr_body = c_runtime.encode(addr_plan, {street = 'X'})
                      .. UNK_VARINT
    -- outer person body wraps that as a length-delimited field id=5
    -- (Person.address). Tag = (5<<3)|2 = 0x2A.
    local function uvarint(v)
        local out = {}
        while v >= 0x80 do
            out[#out + 1] = string.char(v % 0x80 + 0x80)
            v = math.floor(v / 0x80)
        end
        out[#out + 1] = string.char(v)
        return table.concat(out)
    end
    local person_body = '\x2a' .. uvarint(#addr_body) .. addr_body

    local dec = c_runtime.decode(person_plan, person_body)
    t.assert_equals(dec._unknown_fields, nil,
        'outer Person must not carry the inner Address unknown bytes')
    t.assert_equals(dec.address.street, 'X')
    t.assert_equals(hex(dec.address._unknown_fields), hex(UNK_VARINT))
end
