#!/usr/bin/env tarantool
-- ffi_probe.lua -- diagnose why S2 (per-primitive FFI) is slow.
--
-- Microbenchmarks the individual FFI calls used in prim_ffi.lua to
-- decompose where decode/encode time actually goes. Also dumps JIT
-- traces for the hottest call shapes.

local SCRIPT_DIR = (debug.getinfo(1, 'S').source:match('@?(.*/)') or './')
package.cpath = SCRIPT_DIR .. '?.dylib;' .. SCRIPT_DIR .. '?.so;' .. package.cpath

local ffi = require('ffi')
local bit = require('bit')
local clock = require('clock')

ffi.cdef[[
    typedef struct ibuf_s {
        uint8_t *data;
        size_t   len;
        size_t   cap;
    } ibuf_t;
    void pb_ibuf_init(ibuf_t *b);
    void pb_ibuf_reset(ibuf_t *b);
    void pb_write_varint(ibuf_t *b, uint64_t v);
    void pb_write_bytes(ibuf_t *b, const uint8_t *src, size_t n);
    void pb_write_string_field(ibuf_t *b, uint32_t tag,
                               const uint8_t *src, size_t n);
    const uint8_t *pb_read_varint(const uint8_t *p,
                                  const uint8_t *end, uint64_t *out);
]]

local UNAME = io.popen('uname -s'):read('*l')
local ext = (UNAME == 'Darwin') and '.dylib' or '.so'
local C = ffi.load(SCRIPT_DIR .. 'libpb_prim' .. ext)

local outbuf = ffi.new('ibuf_t')
C.pb_ibuf_init(outbuf)

local v_out = ffi.new('uint64_t[1]')

local function time_loop(fn, n)
    -- Warm: let the JIT trace
    for _ = 1, 5000 do fn() end
    collectgarbage('collect')
    local t0 = clock.monotonic64()
    for _ = 1, n do fn() end
    local t1 = clock.monotonic64()
    return tonumber(t1 - t0) / n  -- ns/op
end

io.write('FFI primitive probe — Tarantool ', _TARANTOOL, '\n\n')

-- ----------------------------------------------------------------
-- Bench 1: bare FFI call into ffi.load'd lib, simplest signature.
-- pb_ibuf_reset is void(ibuf_t*). No marshalling beyond pointer pass.
-- ----------------------------------------------------------------
local N = 2000000

io.write('=== Bare FFI calls (no return marshalling) ===\n')
local t = time_loop(function() C.pb_ibuf_reset(outbuf) end, N)
io.write(string.format('  pb_ibuf_reset(buf):                    %6.1f ns/call\n', t))

-- One write_varint with constant value (simplest).
local t = time_loop(function()
    C.pb_ibuf_reset(outbuf)
    C.pb_write_varint(outbuf, 42)
end, N)
io.write(string.format('  reset + write_varint(42):              %6.1f ns/call\n', t))

-- Just write_varint, no reset.
local t = time_loop(function() C.pb_write_varint(outbuf, 42) end, N)
io.write(string.format('  write_varint(42) only:                 %6.1f ns/call (note: drifts buf)\n', t))

-- ----------------------------------------------------------------
-- Bench 2: FFI call with pointer return + output parameter.
-- This is the suspected smoking gun. pb_read_varint returns
-- const uint8_t*. Trace formation around return-by-pointer is the
-- common LuaJIT FFI pitfall.
-- ----------------------------------------------------------------
io.write('\n=== Pointer-return FFI (suspect: pb_read_varint) ===\n')

local buf_str = string.char(0x96, 0x01)  -- varint encoding of 150
local p0   = ffi.cast('const uint8_t*', buf_str)
local end0 = p0 + #buf_str

local t = time_loop(function()
    local p = C.pb_read_varint(p0, end0, v_out)
    -- discard p
end, N)
io.write(string.format('  pb_read_varint(p, end, out) [1B]:      %6.1f ns/call\n', t))

-- Variant: assign return + read v_out[0] (the realistic decode pattern).
local t = time_loop(function()
    local p = C.pb_read_varint(p0, end0, v_out)
    local v = v_out[0]
end, N)
io.write(string.format('  read_varint + v_out[0] read:           %6.1f ns/call\n', t))

-- Variant: ditto + tonumber.
local t = time_loop(function()
    local p = C.pb_read_varint(p0, end0, v_out)
    local v = tonumber(v_out[0])
end, N)
io.write(string.format('  read_varint + v_out[0] + tonumber:     %6.1f ns/call\n', t))

-- ----------------------------------------------------------------
-- Bench 3: per-call overhead components.
-- ffi.cast / ffi.string allocate. Quantify.
-- ----------------------------------------------------------------
io.write('\n=== Allocation-heavy FFI ops ===\n')

local s32 = string.rep('a', 32)

local t = time_loop(function()
    local p = ffi.cast('const uint8_t*', s32)
end, N)
io.write(string.format('  ffi.cast(const uint8_t*, str):         %6.1f ns/call\n', t))

local p_cdata = ffi.cast('const uint8_t*', s32)
local t = time_loop(function()
    local s = ffi.string(p_cdata, 32)
end, N)
io.write(string.format('  ffi.string(ptr, 32):                   %6.1f ns/call\n', t))

-- ----------------------------------------------------------------
-- Bench 4: same op, but call ffi.C symbol vs ffi.load'd lib.
-- LuaJIT can sometimes inline ffi.C calls (libc symbols loaded via
-- the process namespace) more aggressively than ffi.load'd libs.
-- ----------------------------------------------------------------
io.write('\n=== ffi.C (libc) vs ffi.load (libpb_prim) calls ===\n')

ffi.cdef[[
    int memcmp(const void *s1, const void *s2, size_t n);
]]

local b1 = ffi.cast('const uint8_t*', 'aaaaaaaa')
local b2 = ffi.cast('const uint8_t*', 'aaaaaaaa')

local t = time_loop(function() ffi.C.memcmp(b1, b2, 8) end, N)
io.write(string.format('  ffi.C.memcmp(p, p, 8):                 %6.1f ns/call\n', t))

-- ----------------------------------------------------------------
-- Bench 5: pure-Lua equivalent — a Lua varint decoder.
-- The baseline that beats us. If pure-Lua varint is ~10 ns,
-- FFI is paying a real boundary cost per call.
-- ----------------------------------------------------------------
io.write('\n=== Pure Lua varint decode (the thing we are losing to) ===\n')

local function lua_decode_varint(s, pos)
    local v = 0
    local shift = 0
    while true do
        local b = s:byte(pos)
        pos = pos + 1
        v = v + (b - (b >= 128 and 128 or 0)) * (2 ^ shift)
        if b < 128 then break end
        shift = shift + 7
    end
    return v, pos
end

local s150 = string.char(0x96, 0x01)
local t = time_loop(function()
    local v, p = lua_decode_varint(s150, 1)
end, N)
io.write(string.format('  lua_decode_varint(s150) — Lua only:    %6.1f ns/call\n', t))

-- ----------------------------------------------------------------
-- Bench 6: jit.dump on the suspect path to see whether a trace
-- actually compiles for the FFI read_varint loop.
-- ----------------------------------------------------------------
io.write('\n=== JIT trace status (read_varint loop) ===\n')
local jutil = require('jit.util')
local jv = require('jit.v')

io.write('  Run with TARANTOOL_VERBOSE_JIT=1 to dump traces; below is a 100k-iter loop:\n')

-- Compile-trigger loop
local function read_varint_loop()
    for _ = 1, 100 do
        local p = C.pb_read_varint(p0, end0, v_out)
        local v = tonumber(v_out[0])
    end
end

-- Try to expose trace formation.
local jv_enabled = false
local ok = pcall(function()
    jv.start('-')
    jv_enabled = true
end)
read_varint_loop()
read_varint_loop()
if jv_enabled then
    pcall(function() jv.stop() end)
end

-- ----------------------------------------------------------------
-- Bench 7: same FFI primitives, but loop the calls so the trace
-- has the loop body to compile. If per-call cost falls dramatically
-- inside a loop, then the issue is trace formation per inner-most
-- call. If it stays the same, the FFI call itself is slow.
-- ----------------------------------------------------------------
io.write('\n=== Tight loop of read_varint (amortize boundary, look for trace) ===\n')

local function run_loop_n(reps)
    -- pre-warm
    for _ = 1, 100 do
        for _ = 1, reps do
            local p = C.pb_read_varint(p0, end0, v_out)
        end
    end
    collectgarbage('collect')
    local t0 = clock.monotonic64()
    for _ = 1, 1000 do
        for _ = 1, reps do
            local p = C.pb_read_varint(p0, end0, v_out)
        end
    end
    local t1 = clock.monotonic64()
    return tonumber(t1 - t0) / (1000 * reps)
end

for _, reps in ipairs({1, 4, 16, 64, 256}) do
    io.write(string.format('  read_varint x %3d in loop:             %6.1f ns/call\n',
        reps, run_loop_n(reps)))
end
