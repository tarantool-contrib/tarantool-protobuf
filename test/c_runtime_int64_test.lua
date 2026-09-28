-- 64-bit cdata fidelity.
--
-- int64/uint64/sint64/fixed64/sfixed64 must round-trip as LuaJIT
-- int64_t/uint64_t cdata through the C runtime — never narrowed to
-- a Lua double. Same convention as Tarantool's msgpackffi, net.box,
-- box.tuple, and the built-in protobuf. The C decode path pushes
-- cdata via luaL_pushint64 / luaL_pushuint64; the C encode path
-- accepts cdata via luaL_toint64 / luaL_touint64 alongside plain
-- Lua numbers.
--
-- Acceptance criteria:
--   A value > 2^53 round-trips byte-equal to mode=full pure-Lua, and
--   the decoded value remains cdata. Covers all five 64-bit kinds in
--   both codegen modes. Only runs when PB_ENABLE_C=1 is set and the
--   C runtime module is loadable.

local t = require('luatest')
local ffi = require('ffi')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

-- Values past Lua's 2^53 double-precision boundary, picked so the
-- top bits would silently drop if any code path narrowed to double.
-- int64_max - 1, uint64_max - 1, and high bit patterns for fixed.
local U64_BIG     = 0xDEADBEEFCAFEBABEULL
local U64_MAX_ISH = 0xFFFFFFFFFFFFFFFEULL  -- one off all-ones
local I64_NEG_BIG = -0x0123456789ABCDEFLL  -- past -2^53
local I64_POS_BIG =  0x0123456789ABCDEFLL  -- past  2^53

local full_wide

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_int64.' .. mode)
    local wide

    g.before_all(function()
        skip_if_no_c()
        wide = require(mode .. '.c_int64.c_int64_pb')
        full_wide = require('full.c_int64.c_int64_pb')
    end)

    g.before_each(skip_if_no_c)

    -- ---------- Acceptance ----------

    function g.test_acceptance_all_kinds_round_trip_past_2pow53()
        -- One message carries every 64-bit kind with a value that
        -- would lose precision if narrowed through a Lua double.
        -- Bytes must match mode=full, and every decoded field must
        -- remain cdata.
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local msg = {
            a_int64    = ffi.new('int64_t',  I64_POS_BIG),
            a_uint64   = U64_BIG,
            a_sint64   = ffi.new('int64_t',  I64_NEG_BIG),
            a_fixed64  = U64_MAX_ISH,
            a_sfixed64 = ffi.new('int64_t',  I64_NEG_BIG),
        }
        local c_bytes   = c_runtime.encode(plan, msg)
        local lua_bytes = full_wide.Wide_encode(msg)
        t.assert_equals(c_bytes, lua_bytes, 'encode bytes match mode=full')

        local c_decoded = c_runtime.decode(plan, c_bytes)
        local lua_decoded = full_wide.Wide_decode(c_bytes)
        t.assert_equals(c_decoded, lua_decoded, 'decoded table matches mode=full')

        -- Every value must surface as cdata, not double.
        for _, k in ipairs({'a_int64', 'a_uint64', 'a_sint64',
                            'a_fixed64', 'a_sfixed64'}) do
            t.assert_equals(type(c_decoded[k]), 'cdata',
                ('field %s decoded as %s, expected cdata')
                :format(k, type(c_decoded[k])))
        end

        -- Value comparison done via cdata equality so the top bits
        -- are checked, not just the low 53.
        t.assert_equals(c_decoded.a_int64,   msg.a_int64)
        t.assert_equals(c_decoded.a_uint64,  msg.a_uint64)
        t.assert_equals(c_decoded.a_sint64,  msg.a_sint64)
        t.assert_equals(c_decoded.a_fixed64, msg.a_fixed64)
        t.assert_equals(c_decoded.a_sfixed64, msg.a_sfixed64)
    end

    -- ---------- Per-kind: encode from cdata + decode preserves cdata --

    function g.test_int64_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local v = ffi.new('int64_t', I64_POS_BIG)
        local bytes = c_runtime.encode(plan, {a_int64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_int64 = v}))
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_int64), 'cdata')
        t.assert_equals(d.a_int64, v)
    end

    function g.test_int64_negative_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        -- Negative int64 is sign-extended to 10-byte varint on the wire.
        local v = ffi.new('int64_t', I64_NEG_BIG)
        local bytes = c_runtime.encode(plan, {a_int64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_int64 = v}))
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_int64), 'cdata')
        t.assert_equals(d.a_int64, v)
    end

    function g.test_uint64_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local v = U64_BIG
        local bytes = c_runtime.encode(plan, {a_uint64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_uint64 = v}))
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_uint64), 'cdata')
        t.assert_equals(d.a_uint64, v)
    end

    function g.test_uint64_near_max_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local v = U64_MAX_ISH
        local bytes = c_runtime.encode(plan, {a_uint64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_uint64 = v}))
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_uint64), 'cdata')
        t.assert_equals(d.a_uint64, v)
    end

    function g.test_sint64_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local v = ffi.new('int64_t', I64_NEG_BIG)
        local bytes = c_runtime.encode(plan, {a_sint64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_sint64 = v}))
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_sint64), 'cdata')
        t.assert_equals(d.a_sint64, v)
    end

    function g.test_fixed64_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local v = U64_BIG
        local bytes = c_runtime.encode(plan, {a_fixed64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_fixed64 = v}))
        -- fixed64 is always 8 bytes + 1 tag byte; spot-check the wire size.
        t.assert_equals(#bytes, 9, 'fixed64 wire size = tag + 8B')
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_fixed64), 'cdata')
        t.assert_equals(d.a_fixed64, v)
    end

    function g.test_sfixed64_cdata_round_trip()
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local v = ffi.new('int64_t', I64_NEG_BIG)
        local bytes = c_runtime.encode(plan, {a_sfixed64 = v})
        t.assert_equals(bytes, full_wide.Wide_encode({a_sfixed64 = v}))
        local d = c_runtime.decode(plan, bytes)
        t.assert_equals(type(d.a_sfixed64), 'cdata')
        t.assert_equals(d.a_sfixed64, v)
    end

    -- ---------- Encode also accepts plain Lua numbers (in-range) ------

    function g.test_int64_from_lua_number_within_double_range()
        -- Plain Lua numbers below 2^53 must encode identically to
        -- the cdata path. This is the common case for IDs/counters
        -- that happen to fit a double exactly. Tarantool's
        -- luaL_pushint64 surfaces small values as Lua numbers (not
        -- cdata) by convention — same as msgpackffi, net.box, the
        -- built-in protobuf — so the decoded type tracks that, and
        -- equality compares numerically across number/cdata.
        local plan = c_runtime.compile_plan(wide.Wide_descriptor)
        local msg_num   = {a_int64 = 42}
        local msg_cdata = {a_int64 = ffi.new('int64_t', 42)}
        local b_num = c_runtime.encode(plan, msg_num)
        local b_cd  = c_runtime.encode(plan, msg_cdata)
        t.assert_equals(b_num, b_cd, 'Lua number encodes same as cdata')
        t.assert_equals(b_num, full_wide.Wide_encode(msg_num))
        local d = c_runtime.decode(plan, b_num)
        t.assert_equals(d.a_int64, 42)
        t.assert_equals(d, full_wide.Wide_decode(b_num),
            'C decode matches mode=full shape-for-shape')
    end
end
