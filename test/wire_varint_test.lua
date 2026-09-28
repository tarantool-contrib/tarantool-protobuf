-- Regression coverage for varint encoding of large Lua-number inputs.
--
-- encode_varint had a fast path for Lua numbers in [2^28, 2^53) that emitted
-- bytes via `bit.band(n, 0x7f)`. On x86_64 LuaJIT's number->int32 conversion
-- uses the magic-number trick (add 2^52 + 2^51, read the low bits), which is
-- exact only for n < 2^51; above that it rounds and silently dropped low bits,
-- corrupting the varint. arm64 uses an exact FP->int op, so the bug was
-- invisible on Apple-Silicon dev machines and only surfaced on x86_64 CI
-- (a 64-bit lease ID round-tripped to a different value over gRPC).
local t = require('luatest')
local ffi = require('ffi')
local wire = require('pb.wire')

local g = t.group('wire.varint')

-- Round-trip a value through encode_varint -> decode_varint and assert the
-- decoded uint64 equals the input. Inputs are given as Lua numbers; the bug
-- only manifested for the Lua-number encode path, not for cdata inputs.
local function assert_roundtrip(n)
    local enc = wire.encode_varint(n)
    local dec = wire.decode_varint(enc, 1)
    t.assert_equals(dec, ffi.cast('uint64_t', n),
        string.format('varint round-trip for %.0f', n))
end

g.test_large_lua_number_roundtrip = function()
    -- The exact value that corrupted on x86_64 (a representative lease ID),
    -- plus the boundaries around the old 2^53 / new 2^51 fast-path cutoff.
    assert_roundtrip(3041234677171912)   -- corrupted to ...171940 on x64 pre-fix
    assert_roundtrip(2 ^ 51)             -- first value past the safe fast path
    assert_roundtrip(2 ^ 51 + 12345)
    assert_roundtrip(2 ^ 52)
    assert_roundtrip(2 ^ 53 - 1)         -- largest exact double integer
end

g.test_fast_path_boundaries_still_exact = function()
    for _, n in ipairs({0, 1, 127, 128, 16383, 16384, 2 ^ 21, 2 ^ 28,
                        2 ^ 28 + 1, 2 ^ 51 - 1}) do
        assert_roundtrip(n)
    end
end

g.test_cdata_inputs_unchanged = function()
    for _, n in ipairs({ffi.cast('uint64_t', 3041234677171912ULL),
                        ffi.cast('uint64_t', 0xFFFFFFFFFFFFFFFFULL)}) do
        local dec = wire.decode_varint(wire.encode_varint(n), 1)
        t.assert_equals(dec, n)
    end
end
