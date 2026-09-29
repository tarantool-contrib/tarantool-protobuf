-- Low-level protobuf wire format (proto3).
-- Pure Lua + LuaJIT FFI; no Tarantool-specific dependencies.
local ffi = require('ffi')
local bit = require('bit')

local M = {}

-- Wire type constants (https://protobuf.dev/programming-guides/encoding/#structure)
M.WIRE_VARINT = 0
M.WIRE_I64    = 1
M.WIRE_LEN    = 2
-- Wire 3/4 are proto2 groups. We never emit them, but unknown-field
-- skip must tolerate them so proto2-shaped payloads round-trip through
-- a proto3 decoder (conformance suite exercises this).
M.WIRE_SGROUP = 3
M.WIRE_EGROUP = 4
M.WIRE_I32    = 5

-- Maximum nesting of messages and groups a binary decoder descends into,
-- the same default as protobuf's C++ and upb parsers. Every decoder
-- threads a `depth` argument (0 for the top-level message) and refuses
-- input nested deeper than this, so hostile bytes fail with a parse
-- error instead of exhausting the Lua stack or, in the C codec, the
-- fiber's C stack. The C codec mirrors this value as PB_RECURSION_LIMIT.
M.RECURSION_LIMIT = 100

-- Raises the error every decoder reports for input nested too deeply.
function M.recursion_limit_error()
    error(('message nesting exceeds the recursion limit (%d)'):format(
        M.RECURSION_LIMIT), 0)
end

-- Precomputed 1-byte string for every possible byte value (0-255).
-- Replaces `string.char(b)` at length-prefix and tag-emit sites in the
-- codegen-emitted hot path. Profile attributed ~28% of Person_encode 1KB
-- time to a single `out[n] = string.char(_len)` line; a table lookup
-- skips the C-function call + dispatch and is ~27% faster on small
-- payloads, ~14% on 100 KB. Indexed by integer byte value.
local CHARS = {}
for i = 0, 255 do CHARS[i] = string.char(i) end
M.CHARS = CHARS

local UINT64 = ffi.typeof('uint64_t')
local INT64  = ffi.typeof('int64_t')
local UINT64_ZERO = UINT64(0)
local CONT_MASK   = UINT64(bit.bnot(0x7f))  -- 0xFFFFFFFFFFFFFF80

-- 2^53 thresholds used by the opt-in decode_<type>_n variants.
-- A Lua double exactly represents every integer in [-2^53, 2^53] (bounds
-- inclusive — both endpoints are themselves powers of two and fit a
-- double's 53-bit mantissa exactly). Outside that range tonumber() would
-- silently lose precision on odd values. The _n decoders return a Lua
-- number when the decoded value fits the bounds, otherwise the cdata.
-- LL/ULL literals are already int64_t/uint64_t cdata constants; cdata
-- comparisons against them compile to plain 64-bit integer compares on
-- a hot trace.
local FITS_MAX_I =  0x20000000000000LL   --  2^53
local FITS_MIN_I = -0x20000000000000LL   -- -2^53
local FITS_MAX_U =  0x20000000000000ULL  --  2^53

-- FFI scratch unions used by the fixed-width decoders. Allocated once
-- and reused — `ffi.copy` from a `uint8_t*` cast over the Lua string body
-- writes into the union's byte view; reading back via `.u` / `.d` /
-- `.u32[i]` reinterprets the bytes without further allocation.
ffi.cdef[[
    typedef union { float    f; uint32_t u; uint8_t b[4]; } pb_f32_u_t;
    typedef union {
        double   d;
        uint64_t u;
        uint32_t u32[2];   /* [0] = low half, [1] = high half (LE) */
        uint8_t  b[8];
    } pb_f64_u_t;
    typedef union { uint64_t u; uint32_t u32[2]; uint8_t b[8]; } pb_u64_u_t;
]]
local U8CP = ffi.typeof('const uint8_t *')
local F32  = ffi.new('pb_f32_u_t')
local F64  = ffi.new('pb_f64_u_t')
local U64  = ffi.new('pb_u64_u_t')

-- Coerce any integer-like value to uint64_t cdata.
-- Negative Lua numbers are sign-extended via int64_t (protobuf wire spec).
local function to_uint64(v)
    local t = type(v)
    if t == 'number' then
        if v < 0 then return UINT64(INT64(v)) end
        return UINT64(v)
    elseif t == 'cdata' then
        return UINT64(v)
    elseif t == 'boolean' then
        return v and UINT64(1) or UINT64_ZERO
    end
    error("cannot coerce " .. t .. " to uint64", 0)
end
M.to_uint64 = to_uint64

local function to_int64(v)
    local t = type(v)
    if t == 'number' or t == 'cdata' then return INT64(v) end
    error("cannot coerce " .. t .. " to int64", 0)
end
M.to_int64 = to_int64

-- Truncate a uint64 varint payload to proto3 int32/uint32 Lua numbers.
-- Per spec, int32/uint32/enum/sint32 fields must keep only the low 32 bits
-- of an over-range varint; int32/sint32 additionally sign-extend from bit 31.
local function varint_to_uint32(u)
    return tonumber(bit.band(u, 0xFFFFFFFF))
end
local function varint_to_int32(u)
    local n = tonumber(bit.band(u, 0xFFFFFFFF))
    if n >= 0x80000000 then n = n - 0x100000000 end
    return n
end
M.varint_to_uint32 = varint_to_uint32
M.varint_to_int32  = varint_to_int32

-- ---------------------------------------------------------------------------
-- Varint
-- ---------------------------------------------------------------------------

-- encode_varint(n) -> string
-- Accepts uint64_t/int64_t cdata, Lua number, or boolean.
--
-- Fast path: small non-negative Lua numbers (0..127) become a single
-- string.char(n) call with no cdata allocation, no `out` table, no
-- table.concat. Covers most length prefixes for short strings, many
-- enum ordinals, and most small int values in typical RPC payloads.
--
-- The outer function is kept tiny on purpose — adding 2/3/4-byte
-- branches to `encode_varint` itself pushes it past LuaJIT's inline
-- budget so parent traces stop inlining it, regressing the
-- 1-byte-dominant workloads by ~30%. Multi-byte Lua-number fast paths
-- live in `encode_varint_slow` below, which is not inlined into hot
-- traces anyway — so its size doesn't matter.
local encode_varint_slow

-- encode_varint_slow: handles every input that doesn't fit the
-- 1-byte fast path in `encode_varint`. Three layers, falling through:
--
--   1. Non-negative Lua numbers < 2^28 are encoded via `bit.rshift` /
--      `bit.band` / `string.char` — bit ops on Lua numbers operate as
--      uint32 and don't allocate cdata. Values up to 4 bytes covered.
--   2. Non-negative Lua numbers in [2^28, 2^53) are still exact in
--      double precision but exceed uint32 — emit one byte through bit
--      ops, then recurse with `n / 128` on the smaller residue.
--   3. Everything else (cdata uint64/int64, negative Lua numbers — the
--      latter get sign-extended to 10-byte varints) goes through the
--      uint64 cdata loop. Pre-change measurement: 18x slower than the
--      1-byte fast path; the Lua-number paths above bring 2-byte to
--      ~2x of the fast path instead.
encode_varint_slow = function(n)
    if type(n) == 'number' and n >= 0 then
        if n < 0x4000 then          -- 2-byte
            return string.char(
                bit.bor(bit.band(n, 0x7f), 0x80),
                bit.rshift(n, 7))
        end
        if n < 0x200000 then        -- 3-byte
            return string.char(
                bit.bor(bit.band(n, 0x7f), 0x80),
                bit.bor(bit.band(bit.rshift(n, 7), 0x7f), 0x80),
                bit.rshift(n, 14))
        end
        if n < 0x10000000 then      -- 4-byte (< 2^28, fits in uint32)
            return string.char(
                bit.bor(bit.band(n, 0x7f), 0x80),
                bit.bor(bit.band(bit.rshift(n, 7), 0x7f), 0x80),
                bit.bor(bit.band(bit.rshift(n, 14), 0x7f), 0x80),
                bit.rshift(n, 21))
        end
        -- 2^28 <= n < 2^51: emit one byte via a Lua-number bit op, then
        -- recurse on the residue (now < n/128, may fit a fast path).
        --
        -- The bound is 2^51, not 2^53: `bit.band(n, 0x7f)` routes through
        -- LuaJIT's number->int32 conversion, which on x64 uses the
        -- magic-number trick (add 2^52 + 2^51, read the low bits). That is
        -- exact only while n + 2^52 + 2^51 < 2^53, i.e. n < 2^51; above it
        -- the addition rounds to an even double and silently drops low
        -- bits, corrupting the varint. (arm64 uses an exact FP->int op, so
        -- this only ever bit on x86_64.) Values in [2^51, 2^53) fall
        -- through to the exact uint64 cdata loop below.
        if n < 2^51 then
            return string.char(bit.bor(bit.band(n, 0x7f), 0x80))
                .. encode_varint_slow(math.floor(n / 128))
        end
    end
    -- Fallback: uint64 cdata path. Reached by cdata inputs, negative
    -- Lua numbers (sign-extended to 10-byte varint), and Lua numbers in
    -- [2^51, 2^53) that the fast path above deliberately skips.
    n = to_uint64(n)
    local out = {}
    local i = 1
    while bit.band(n, CONT_MASK) ~= UINT64_ZERO do
        out[i] = string.char(tonumber(bit.bor(bit.band(n, 0x7f), 0x80)))
        n = bit.rshift(n, 7)
        i = i + 1
    end
    out[i] = string.char(tonumber(n))
    return table.concat(out)
end

local function encode_varint(n)
    if type(n) == 'number' and n >= 0 and n < 0x80 then
        return string.char(n)
    end
    return encode_varint_slow(n)
end
M.encode_varint = encode_varint

-- decode_varint(buf, pos) -> uint64_t cdata, new_pos (1-based)
--
-- Fast path is inlined: 1-byte varints (field tags for ids 1..15 and
-- many small values) take a straight-line branch with no loop, which
-- keeps the JIT trace single-rooted across hot decode callers. The
-- multi-byte tail still loops, but it's only entered for the small
-- minority of values that don't fit in 7 bits.
local function decode_varint(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then
        return UINT64(b), pos + 1
    end
    local result = UINT64(bit.band(b, 0x7f))
    local shift = 7
    pos = pos + 1
    while true do
        b = buf:byte(pos)
        if b == nil then error("truncated varint at offset " .. pos, 0) end
        pos = pos + 1
        result = bit.bor(result, bit.lshift(UINT64(bit.band(b, 0x7f)), shift))
        if b < 0x80 then return result, pos end
        shift = shift + 7
        if shift >= 70 then error("varint exceeds 10 bytes", 0) end
    end
end
M.decode_varint = decode_varint

-- ---------------------------------------------------------------------------
-- Tag
-- ---------------------------------------------------------------------------

local function encode_tag(field_id, wire_type)
    -- field_id < 2^29, fits in Lua double exactly.
    return encode_varint(field_id * 8 + wire_type)
end
M.encode_tag = encode_tag

-- The 1-byte varint fast path is duplicated at every hot decode call
-- site (decode_tag, decode_len, decode_int32 / int64 / uint32 / uint64 /
-- sint32 / sint64 / bool, skip_field VARINT branch) instead of being
-- factored into a helper. Reason: LuaJIT 2.1 inlines a small called
-- function into the caller's trace, so when the parent guard exits to
-- a side trace for the multi-byte case, the side trace has to return
-- from the inlined frame — and LuaJIT can't stitch that return back
-- to the parent, dropping to interpreter dispatch. Inlining the fast
-- path literally keeps the side trace inside the caller's own frame,
-- where stitching works.
local function decode_tag(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then
        local wt = bit.band(b, 7)
        if wt >= 6 then error("illegal wire type " .. wt, 0) end
        local fn = bit.rshift(b, 3)
        if fn == 0 then error("illegal field number 0", 0) end
        return fn, wt, pos + 1
    end
    local u, npos = decode_varint(buf, pos)
    -- A tag must use the minimum number of bytes to encode its value.
    -- The trailing byte of a multi-byte varint contributes 0 high bits
    -- only when the encoding is overlong (any prior byte already covered
    -- the value).
    if buf:byte(npos - 1) == 0 then
        error("overlong tag varint at offset " .. pos, 0)
    end
    -- Bit ops on the uint64 cdata preserve 64-bit width; going through
    -- tonumber first would truncate field numbers above 2^32.
    local wt = tonumber(bit.band(u, 7))
    if wt >= 6 then error("illegal wire type " .. wt, 0) end
    local fn = tonumber(bit.rshift(u, 3))
    if fn == 0 then error("illegal field number 0", 0) end
    -- Field numbers are 29-bit per the protobuf spec.
    if fn > 0x1FFFFFFF then
        error("field number out of range: " .. fn, 0)
    end
    return fn, wt, npos
end
M.decode_tag = decode_tag

-- ---------------------------------------------------------------------------
-- ZigZag (sint32 / sint64)
-- ---------------------------------------------------------------------------

-- 32-bit zigzag stays in Lua number range.
local function zigzag_encode32(n)
    n = tonumber(n)
    if n >= 0 then return n * 2 else return -n * 2 - 1 end
end
M.zigzag_encode32 = zigzag_encode32

local function zigzag_decode32(u)
    u = tonumber(u)
    if u % 2 == 0 then return u / 2 else return -((u + 1) / 2) end
end
M.zigzag_decode32 = zigzag_decode32

-- 64-bit zigzag uses cdata.
--
-- `~x` is written as `UINT64_MAX - x`, never `bit.bnot(x)`. The arm64
-- backend of LuaJIT before upstream commit 90742d91 ("ARM64: Don't fuse
-- sign extensions into logical operands", LuaJIT#1076) folds the sign
-- extension of an int into the operand of a logical instruction, which has
-- no such form, so a compiled `bit.bnot` of a sign-extended value computes
-- `x << 48`. Tarantool's LuaJIT predates that fix: encode_sint64(-5)
-- produced a 10-byte varint instead of 0x09. Covered by
-- test/wire_zigzag_jit_test.lua.
local UINT64_MAX = UINT64(-1)

local function zigzag_encode64(n)
    local i = to_int64(n)
    local doubled = bit.lshift(UINT64(i), 1)
    if i >= 0 then return doubled end
    return UINT64_MAX - doubled
end
M.zigzag_encode64 = zigzag_encode64

-- Variant that takes an int64_t cdata directly, skipping the to_int64()
-- type-dispatch wrapper. Use from mode=full codegen sites where the field
-- type is statically known.
local function zigzag_encode64_i(i)
    local doubled = bit.lshift(UINT64(i), 1)
    if i >= 0 then return doubled end
    return UINT64_MAX - doubled  -- not bit.bnot, see zigzag_encode64
end
M.zigzag_encode64_i = zigzag_encode64_i

local function zigzag_decode64(u)
    u = to_uint64(u)
    local half = bit.rshift(u, 1)
    if bit.band(u, 1) == UINT64_ZERO then return INT64(half) end
    return INT64(UINT64_MAX - half)  -- not bit.bnot, see zigzag_encode64
end
M.zigzag_decode64 = zigzag_decode64

-- ---------------------------------------------------------------------------
-- Fixed32 / Fixed64 (little-endian)
-- ---------------------------------------------------------------------------

local function encode_fixed32(v)
    -- Accepts uint32 (Lua number 0..2^32-1) or any integer cdata.
    local u
    if type(v) == 'cdata' then
        u = tonumber(bit.band(UINT64(v), 0xffffffff))
    else
        u = tonumber(v)
        if u < 0 then u = u + 0x100000000 end
    end
    return string.char(
        bit.band(u, 0xff),
        bit.band(bit.rshift(u, 8), 0xff),
        bit.band(bit.rshift(u, 16), 0xff),
        bit.band(bit.rshift(u, 24), 0xff))
end
M.encode_fixed32 = encode_fixed32

-- decode_fixed32(buf, pos) -> Lua number (0..2^32-1), new_pos
local function decode_fixed32(buf, pos)
    local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
    if b4 == nil then error("truncated fixed32", 0) end
    return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000, pos + 4
end
M.decode_fixed32 = decode_fixed32

-- Body shared by encode_fixed64 and encode_fixed64_u. Takes a uint64_t cdata.
local function encode_fixed64_u(u)
    local lo = tonumber(bit.band(u, 0xffffffff))
    local hi = tonumber(bit.rshift(u, 32))
    return string.char(
        bit.band(lo, 0xff),
        bit.band(bit.rshift(lo, 8), 0xff),
        bit.band(bit.rshift(lo, 16), 0xff),
        bit.band(bit.rshift(lo, 24), 0xff),
        bit.band(hi, 0xff),
        bit.band(bit.rshift(hi, 8), 0xff),
        bit.band(bit.rshift(hi, 16), 0xff),
        bit.band(bit.rshift(hi, 24), 0xff))
end
-- Generic wrapper: accepts Lua number / cdata / boolean via to_uint64.
local function encode_fixed64(v)
    return encode_fixed64_u(to_uint64(v))
end
M.encode_fixed64   = encode_fixed64
-- Variant for mode=full codegen sites where the value is already a uint64_t
-- cdata (caller wraps with UINT64() at the static-type-known call site).
-- Used for fixed64 and sfixed64 (sfixed64 reuses this body — same bit
-- pattern, different sign interpretation).
M.encode_fixed64_u = encode_fixed64_u

-- decode_fixed64(buf, pos) -> uint64_t cdata, new_pos
-- Reading via the FFI union avoids the multi-step `UINT64(lo) +
-- bit.lshift(UINT64(hi), 32)` cdata arithmetic, which allocated 2-3
-- intermediate cdata per call. ffi.copy from a uint8_t* cast over the
-- Lua string body skips the buf:sub allocation entirely.
local function decode_fixed64(buf, pos)
    if pos + 7 > #buf then error("truncated fixed64", 0) end
    ffi.copy(U64.b, ffi.cast(U8CP, buf) + (pos - 1), 8)
    return U64.u, pos + 8
end
M.decode_fixed64 = decode_fixed64

-- ---------------------------------------------------------------------------
-- Float / Double (IEEE 754 little-endian)
-- ---------------------------------------------------------------------------

local function encode_float(n)
    F32.f = n
    return ffi.string(F32.b, 4)
end
M.encode_float = encode_float

-- ffi.cast over the Lua string body (`U8CP`) avoids the buf:sub
-- allocation (saves ~40 bytes per fixed-width read on the GC, and one
-- alloc per call). Lua strings are immutable + zero-terminated, so the
-- pointer is valid for the duration of the cast.
local function decode_float(buf, pos)
    if pos + 3 > #buf then error("truncated float", 0) end
    ffi.copy(F32.b, ffi.cast(U8CP, buf) + (pos - 1), 4)
    -- Detect Inf/NaN from the raw bit pattern before going through
    -- tonumber(). LuaJIT 2.1 NaN-boxes Lua values, so some IEEE NaN
    -- payloads collide with internal type tags (nil/function/etc.) and
    -- `tonumber(F32.f)` yields a non-number. Reading via F32.u (uint32)
    -- keeps us in the integer domain until we decide what to return.
    local u  = F32.u
    local exp = bit.band(bit.rshift(u, 23), 0xff)
    if exp == 0xff then
        if bit.band(u, 0x7fffff) == 0 then
            if bit.band(u, 0x80000000) ~= 0 then return -math.huge, pos + 4 end
            return math.huge, pos + 4
        end
        return 0/0, pos + 4
    end
    return tonumber(F32.f), pos + 4
end
M.decode_float = decode_float

local function encode_double(n)
    F64.d = n
    return ffi.string(F64.b, 8)
end
M.encode_double = encode_double

local function decode_double(buf, pos)
    if pos + 7 > #buf then error("truncated double", 0) end
    ffi.copy(F64.b, ffi.cast(U8CP, buf) + (pos - 1), 8)
    -- Detect Inf/NaN from the raw bit pattern before going through
    -- tonumber(). LuaJIT 2.1 NaN-boxes Lua values, so some IEEE NaN
    -- payloads collide with internal type tags (nil/function/etc.) and
    -- `tonumber(F64.d)` yields a non-number. Splitting the uint64 into
    -- two uint32 halves lets the bit ops stay in Lua-number space —
    -- avoids per-op uint64 cdata allocation in the hot path.
    local hi = F64.u32[1]
    if bit.band(bit.rshift(hi, 20), 0x7ff) == 0x7ff then
        local frac_hi = bit.band(hi, 0xfffff)
        if frac_hi == 0 and F64.u32[0] == 0 then
            if bit.band(hi, 0x80000000) ~= 0 then return -math.huge, pos + 8 end
            return math.huge, pos + 8
        end
        return 0/0, pos + 8
    end
    return tonumber(F64.d), pos + 8
end
M.decode_double = decode_double

-- ---------------------------------------------------------------------------
-- Length-delimited (LEN)
-- ---------------------------------------------------------------------------

local function encode_len(s)
    return encode_varint(#s) .. s
end
M.encode_len = encode_len

-- decode_len(buf, pos) -> string, new_pos
local function decode_len(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    local len, npos
    if b < 0x80 then
        len = b; npos = pos + 1
    else
        local v
        v, npos = decode_varint(buf, pos)
        len = tonumber(v)
    end
    if npos + len - 1 > #buf then error("truncated LEN payload", 0) end
    return buf:sub(npos, npos + len - 1), npos + len
end
M.decode_len = decode_len

-- ---------------------------------------------------------------------------
-- Typed scalar encoders/decoders (one per proto3 scalar type).
--
-- Both code paths (descriptor-driven runtime and inline codegen) call into
-- these. They take the application-side Lua value and produce/consume only
-- the value's wire bytes — the field tag is the caller's responsibility.
-- ---------------------------------------------------------------------------

-- Encoders --------------------------------------------------------------------
M.encode_int32  = encode_varint
M.encode_int64  = encode_varint
M.encode_uint32 = encode_varint
M.encode_uint64 = encode_varint

local function encode_sint32(v) return encode_varint(zigzag_encode32(v)) end
local function encode_sint64(v) return encode_varint(zigzag_encode64(v)) end
local function encode_bool(v)   return encode_varint(v and 1 or 0)       end
M.encode_sint32 = encode_sint32
M.encode_sint64 = encode_sint64
M.encode_bool   = encode_bool

-- Fast variant for mode=full codegen: takes an int64_t cdata, skips to_int64.
local function encode_sint64_i(i) return encode_varint(zigzag_encode64_i(i)) end
M.encode_sint64_i = encode_sint64_i

M.encode_sfixed32   = encode_fixed32  -- bits are identical, only interpretation differs
M.encode_sfixed64   = encode_fixed64
-- sfixed64 reuses encode_fixed64_u — same 8-byte little-endian shape.
M.encode_sfixed64_u = encode_fixed64_u
M.encode_string   = encode_len
M.encode_bytes    = encode_len
-- (encode_fixed32, encode_fixed64, encode_float, encode_double already on M)

-- Decoders --------------------------------------------------------------------
-- The 1-byte fast path is inlined at every varint-based scalar decoder
-- (see comment above decode_tag). Each decoder reads the first byte,
-- handles the common 0..127 case in straight-line code, and falls
-- through to decode_varint only for multi-byte values.
local function decode_int32(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return b, pos + 1 end  -- 0..127 fits int32 directly
    local u, np = decode_varint(buf, pos)
    return varint_to_int32(u), np
end
local function decode_int64(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return INT64(b), pos + 1 end
    local u, np = decode_varint(buf, pos)
    return INT64(u), np
end
local function decode_uint32(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return b, pos + 1 end
    local u, np = decode_varint(buf, pos)
    return varint_to_uint32(u), np
end
local function decode_uint64(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return UINT64(b), pos + 1 end
    local u, np = decode_varint(buf, pos)
    return UINT64(u), np
end
local function decode_sint32(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return zigzag_decode32(b), pos + 1 end
    local u, np = decode_varint(buf, pos)
    return zigzag_decode32(varint_to_uint32(u)), np
end
local function decode_sint64(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return zigzag_decode64(b), pos + 1 end
    local u, np = decode_varint(buf, pos)
    return zigzag_decode64(u), np
end
local function decode_bool(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return b ~= 0, pos + 1 end
    local u, np = decode_varint(buf, pos)
    return u ~= UINT64_ZERO, np
end
local function decode_sfixed32(buf, pos)
    local n, np = decode_fixed32(buf, pos)
    if n > 0x7fffffff then n = n - 0x100000000 end
    return n, np
end
local function decode_sfixed64(buf, pos)
    local u, np = decode_fixed64(buf, pos)
    return INT64(u), np
end

M.decode_int32    = decode_int32
M.decode_int64    = decode_int64
M.decode_uint32   = decode_uint32
M.decode_uint64   = decode_uint64
M.decode_sint32   = decode_sint32
M.decode_sint64   = decode_sint64
M.decode_bool     = decode_bool
M.decode_sfixed32 = decode_sfixed32
M.decode_sfixed64 = decode_sfixed64

-- Opt-in decode variants that return a Lua number when the decoded value
-- fits in [-2^53, 2^53) (or [0, 2^53) for the unsigned ones), else the
-- usual cdata. Wired in by mode=full codegen when the plugin is invoked
-- with `int64_as_number=true` — see cmd/protoc-gen-tarantool docs. The
-- type at decode time is unstable (number vs cdata) under this option,
-- but Lua's `+`/`-`/`*`/`==` work transparently on both and the saved
-- cdata allocation pays off on workloads dominated by small IDs,
-- timestamps that fit 2^53, byte counts, etc.
local function decode_int64_n(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return b, pos + 1 end           -- 0..127, Lua number
    local u, np = decode_varint(buf, pos)
    local i = INT64(u)                                -- reinterpret bits
    if i <= FITS_MAX_I and i >= FITS_MIN_I then
        return tonumber(i), np
    end
    return i, np
end
local function decode_uint64_n(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return b, pos + 1 end
    local u, np = decode_varint(buf, pos)
    if u <= FITS_MAX_U then return tonumber(u), np end
    return u, np
end
local function decode_sint64_n(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then return zigzag_decode32(b), pos + 1 end
    local u, np = decode_varint(buf, pos)
    local i = zigzag_decode64(u)
    if i <= FITS_MAX_I and i >= FITS_MIN_I then
        return tonumber(i), np
    end
    return i, np
end
local function decode_fixed64_n(buf, pos)
    local u, np = decode_fixed64(buf, pos)
    if u <= FITS_MAX_U then return tonumber(u), np end
    return u, np
end
local function decode_sfixed64_n(buf, pos)
    local u, np = decode_fixed64(buf, pos)
    local i = INT64(u)
    if i <= FITS_MAX_I and i >= FITS_MIN_I then
        return tonumber(i), np
    end
    return i, np
end
M.decode_int64_n    = decode_int64_n
M.decode_uint64_n   = decode_uint64_n
M.decode_sint64_n   = decode_sint64_n
M.decode_fixed64_n  = decode_fixed64_n
M.decode_sfixed64_n = decode_sfixed64_n
-- RFC 3629 UTF-8 validator. Rejects: out-of-range continuation bytes,
-- truncated multi-byte sequences, overlong encodings, UTF-16 surrogate
-- code points (U+D800..U+DFFF), and code points above U+10FFFF.
--
-- Tarantool ships an ICU-backed `utf8.len` (src/lua/utf8.c:165) that uses
-- `U8_NEXT` for validation — it returns nil on the first invalid sequence
-- and matches every proto3 rejection case (overlong, surrogate, > U+10FFFF,
-- 5-byte). Empirically 15-30x faster than a pure-Lua `string.byte` loop on
-- ASCII payloads (decode throughput on string-heavy 1KB Person: ~1.9x).
local utf8_len = require('utf8').len
local function is_valid_utf8(s)
    return utf8_len(s) ~= nil
end
M.is_valid_utf8 = is_valid_utf8

-- Inlined 1-byte LEN fast path. Same rationale as the inlined varint
-- fast paths above (see decode_tag): strings ≤127 bytes are the common
-- RPC case; folding their length-prefix read in here skips two function
-- call layers (decode_string → decode_len → decode_varint) and lets the
-- JIT keep the trace single-rooted across the caller.
local function decode_string(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then
        local np = pos + 1
        local epos = np + b
        if epos - 1 > #buf then error("truncated LEN payload", 0) end
        local s = buf:sub(np, epos - 1)
        if utf8_len(s) == nil then
            error("invalid UTF-8 in string field at offset " .. pos, 0)
        end
        return s, epos
    end
    local s, np = decode_len(buf, pos)
    if utf8_len(s) == nil then
        error("invalid UTF-8 in string field at offset " .. pos, 0)
    end
    return s, np
end
M.decode_string = decode_string

local function decode_bytes(buf, pos)
    local b = buf:byte(pos)
    if b == nil then error("truncated varint at offset " .. pos, 0) end
    if b < 0x80 then
        local np = pos + 1
        local epos = np + b
        if epos - 1 > #buf then error("truncated LEN payload", 0) end
        return buf:sub(np, epos - 1), epos
    end
    return decode_len(buf, pos)
end
M.decode_bytes = decode_bytes
-- (decode_fixed32, decode_fixed64, decode_float, decode_double already on M
-- and have the right semantics for their proto types: fixed32 -> uint32 Lua
-- number 0..2^32-1, fixed64 -> uint64 cdata.)

-- ---------------------------------------------------------------------------
-- TYPE_INFO — single-source-of-truth metadata for the codec layer and codegen.
-- Each entry carries the wire type, packed-list eligibility, and the typed
-- encode/decode functions defined above.
-- ---------------------------------------------------------------------------

M.TYPE_INFO = {
    int32    = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_int32,    decode = M.decode_int32   },
    int64    = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_int64,    decode = M.decode_int64   },
    uint32   = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_uint32,   decode = M.decode_uint32  },
    uint64   = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_uint64,   decode = M.decode_uint64  },
    sint32   = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_sint32,   decode = M.decode_sint32  },
    sint64   = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_sint64,   decode = M.decode_sint64  },
    bool     = {wire = M.WIRE_VARINT, packable = true,  encode = M.encode_bool,     decode = M.decode_bool    },
    fixed32  = {wire = M.WIRE_I32,    packable = true,  encode = M.encode_fixed32,  decode = M.decode_fixed32 },
    sfixed32 = {wire = M.WIRE_I32,    packable = true,  encode = M.encode_sfixed32, decode = M.decode_sfixed32},
    float    = {wire = M.WIRE_I32,    packable = true,  encode = M.encode_float,    decode = M.decode_float   },
    fixed64  = {wire = M.WIRE_I64,    packable = true,  encode = M.encode_fixed64,  decode = M.decode_fixed64 },
    sfixed64 = {wire = M.WIRE_I64,    packable = true,  encode = M.encode_sfixed64, decode = M.decode_sfixed64},
    double   = {wire = M.WIRE_I64,    packable = true,  encode = M.encode_double,   decode = M.decode_double  },
    string   = {wire = M.WIRE_LEN,    packable = false, encode = M.encode_string,   decode = M.decode_string  },
    bytes    = {wire = M.WIRE_LEN,    packable = false, encode = M.encode_bytes,    decode = M.decode_bytes   },
}

-- ---------------------------------------------------------------------------
-- Skip an unknown field (used by decoder when an unrecognized id appears).
-- skip_field(buf, pos, wire_type, field_id) -> new_pos
--
-- field_id is required for SGROUP (wire 3) so the closing EGROUP can
-- be matched. Other wire types ignore it.
-- ---------------------------------------------------------------------------
local function skip_field(buf, pos, wire_type, field_id)
    if wire_type == M.WIRE_VARINT then
        local b = buf:byte(pos)
        if b == nil then error("truncated varint at offset " .. pos, 0) end
        if b < 0x80 then return pos + 1 end
        local _, npos = decode_varint(buf, pos)
        return npos
    elseif wire_type == M.WIRE_I64 then
        local np = pos + 8
        if np > #buf + 1 then error("truncated I64 at offset " .. pos, 0) end
        return np
    elseif wire_type == M.WIRE_LEN then
        local b = buf:byte(pos)
        if b == nil then error("truncated varint at offset " .. pos, 0) end
        if b < 0x80 then
            local np = pos + 1 + b
            if np > #buf + 1 then error("truncated LEN at offset " .. pos, 0) end
            return np
        end
        local len, npos = decode_varint(buf, pos)
        local np = npos + tonumber(len)
        if np > #buf + 1 then error("truncated LEN at offset " .. pos, 0) end
        return np
    elseif wire_type == M.WIRE_I32 then
        local np = pos + 4
        if np > #buf + 1 then error("truncated I32 at offset " .. pos, 0) end
        return np
    elseif wire_type == M.WIRE_SGROUP then
        -- Read inner tags until the matching EGROUP. Nested groups are
        -- tracked on an explicit stack of open ids rather than by
        -- recursion, capped at RECURSION_LIMIT like message nesting.
        -- EGROUP id mismatch is a hard error per spec.
        if field_id == nil then
            error("skip_field SGROUP requires field_id", 0)
        end
        local open, n = {field_id}, 1
        while true do
            local iid, iwt
            iid, iwt, pos = decode_tag(buf, pos)
            if iwt == M.WIRE_EGROUP then
                if iid ~= open[n] then
                    error(("EGROUP id %d does not match SGROUP id %d"):
                        format(iid, open[n]), 0)
                end
                n = n - 1
                if n == 0 then return pos end
            elseif iwt == M.WIRE_SGROUP then
                n = n + 1
                if n > M.RECURSION_LIMIT then M.recursion_limit_error() end
                open[n] = iid
            else
                pos = skip_field(buf, pos, iwt, iid)
            end
        end
    elseif wire_type == M.WIRE_EGROUP then
        error("unexpected EGROUP for field " .. tostring(field_id), 0)
    end
    error("unknown wire type " .. tostring(wire_type), 0)
end
M.skip_field = skip_field

return M
