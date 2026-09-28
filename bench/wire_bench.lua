#!/usr/bin/env tarantool
-- Wire-layer microbenchmark.
--
-- Times each `wire.encode_*` / `wire.decode_*` helper in isolation so
-- a regression at the wire layer is visible independently of message
-- shape. Complements bench/bench.lua, which measures composite encode/
-- decode throughput on a real message and folds wire-layer changes in
-- with codegen, table allocation, and table.concat costs.
--
-- Output: one row per (helper, sample) pair with ns/op. Times are
-- median over 5 runs. No baseline / regression gate; this is a manual
-- inspection tool used when tuning wire.lua.
--
-- Usage: `make bench-wire` or `tarantool bench/wire_bench.lua`.

package.path = './runtime/?.lua;./runtime/?/init.lua;' .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local clock = require('clock')
local ffi   = require('ffi')
local wire  = require('pb.wire')

local function timeit(fn, iters)
    -- warmup
    for _ = 1, math.min(iters, 1000) do fn() end
    local samples = {}
    for r = 1, 5 do
        collectgarbage('collect')
        local t0 = clock.monotonic64()
        for _ = 1, iters do fn() end
        local t1 = clock.monotonic64()
        samples[r] = tonumber(t1 - t0) / iters
    end
    table.sort(samples)
    return samples[3]  -- median of 5
end

local function row(label, fn, iters)
    iters = iters or 200000
    print(string.format('  %-44s %8.0f ns/op', label, timeit(fn, iters)))
end

local function section(name)
    print()
    print('-- ' .. name .. ' --')
end

io.stderr:write(string.format('tarantool-protobuf wire bench (%s)\n', _TARANTOOL))

-- =========================================================================
-- Encoders
-- =========================================================================

section('Varint encode (Lua-number inputs)')
row('encode_varint(0)        [1-byte]', function() wire.encode_varint(0) end)
row('encode_varint(127)      [1-byte]', function() wire.encode_varint(127) end)
row('encode_varint(150)      [2-byte]', function() wire.encode_varint(150) end)
row('encode_varint(20000)    [3-byte]', function() wire.encode_varint(20000) end)
row('encode_varint(1<<28)    [5-byte]', function() wire.encode_varint(1 * 2^28) end)

section('Varint encode (cdata uint64 inputs)')
local u64_small = ffi.cast('uint64_t', 42)
local u64_large = ffi.cast('uint64_t', 0xfeedface00000001ULL)
row('encode_varint(uint64 42)',         function() wire.encode_varint(u64_small) end)
row('encode_varint(uint64 large)',      function() wire.encode_varint(u64_large) end)

section('ZigZag encode')
row('zigzag_encode32(42)',              function() wire.zigzag_encode32(42) end)
row('zigzag_encode32(-42)',             function() wire.zigzag_encode32(-42) end)
row('zigzag_encode64(42)',              function() wire.zigzag_encode64(42) end)
row('encode_sint32(-12345)',            function() wire.encode_sint32(-12345) end)
row('encode_sint64(-12345)',            function() wire.encode_sint64(-12345) end)

section('Fixed-width encode')
row('encode_fixed32(0xdeadbeef)',       function() wire.encode_fixed32(0xdeadbeef) end)
row('encode_fixed64(u64_large)',        function() wire.encode_fixed64(u64_large) end)
row('encode_float(3.14)',               function() wire.encode_float(3.14) end)
row('encode_double(3.14159265358979)',  function() wire.encode_double(3.14159265358979) end)
row('encode_bool(true)',                function() wire.encode_bool(true) end)

section('LEN encode (length-prefixed)')
local s10  = string.rep('a', 10)
local s32  = string.rep('a', 32)
local s127 = string.rep('a', 127)
local s200 = string.rep('a', 200)
local s1k  = string.rep('a', 1024)
row('encode_string(10B)',               function() wire.encode_string(s10) end)
row('encode_string(32B)',               function() wire.encode_string(s32) end)
row('encode_string(127B)  [1-byte LEN]', function() wire.encode_string(s127) end)
row('encode_string(200B)  [2-byte LEN]', function() wire.encode_string(s200) end)
row('encode_string(1KB)   [2-byte LEN]', function() wire.encode_string(s1k) end, 50000)
row('encode_bytes(32B)',                function() wire.encode_bytes(s32) end)

section('Tag encode')
row('encode_tag(1, VARINT)   [1-byte]', function() wire.encode_tag(1, wire.WIRE_VARINT) end)
row('encode_tag(15, VARINT)  [1-byte]', function() wire.encode_tag(15, wire.WIRE_VARINT) end)
row('encode_tag(16, LEN)     [2-byte]', function() wire.encode_tag(16, wire.WIRE_LEN) end)
row('encode_tag(2048, LEN)   [3-byte]', function() wire.encode_tag(2048, wire.WIRE_LEN) end)

-- =========================================================================
-- Decoders
-- =========================================================================

local b1   = string.char(42)
local b2   = string.char(0x96, 0x01)
local b3   = string.char(0xa0, 0x9c, 0x01)
local b_f32 = wire.encode_fixed32(0xdeadbeef)
local b_f64 = wire.encode_fixed64(u64_large)
local b_str10  = wire.encode_string(s10)
local b_str32  = wire.encode_string(s32)
local b_str200 = wire.encode_string(s200)
local b_str1k  = wire.encode_string(s1k)
local b_tag1   = wire.encode_tag(1, wire.WIRE_VARINT)
local b_tag16  = wire.encode_tag(16, wire.WIRE_LEN)
local b_bool   = string.char(1)

section('Varint decode')
row('decode_varint(1-byte 42)',         function() wire.decode_varint(b1, 1) end)
row('decode_varint(2-byte 150)',        function() wire.decode_varint(b2, 1) end)
row('decode_varint(3-byte 20000)',      function() wire.decode_varint(b3, 1) end)

section('Typed varint decode')
row('decode_int32(1-byte)',             function() wire.decode_int32(b1, 1) end)
row('decode_int32(2-byte)',             function() wire.decode_int32(b2, 1) end)
row('decode_int64(1-byte)',             function() wire.decode_int64(b1, 1) end)
row('decode_uint32(1-byte)',            function() wire.decode_uint32(b1, 1) end)
row('decode_uint64(1-byte)',            function() wire.decode_uint64(b1, 1) end)
row('decode_sint32(1-byte)',            function() wire.decode_sint32(b1, 1) end)
row('decode_sint64(1-byte)',            function() wire.decode_sint64(b1, 1) end)
row('decode_bool(1)',                   function() wire.decode_bool(b_bool, 1) end)

section('Fixed-width decode')
row('decode_fixed32',                   function() wire.decode_fixed32(b_f32, 1) end)
row('decode_fixed64',                   function() wire.decode_fixed64(b_f64, 1) end)
row('decode_sfixed32',                  function() wire.decode_sfixed32(b_f32, 1) end)
row('decode_sfixed64',                  function() wire.decode_sfixed64(b_f64, 1) end)
row('decode_float',                     function() wire.decode_float(b_f32, 1) end)
row('decode_double',                    function() wire.decode_double(b_f64, 1) end)

section('LEN decode')
row('decode_string(10B)',               function() wire.decode_string(b_str10, 1) end)
row('decode_string(32B)',               function() wire.decode_string(b_str32, 1) end)
row('decode_string(200B) [2-byte LEN]', function() wire.decode_string(b_str200, 1) end)
row('decode_string(1KB)  [2-byte LEN]', function() wire.decode_string(b_str1k, 1) end, 50000)
row('decode_bytes(32B)',                function() wire.decode_bytes(b_str32, 1) end)
row('decode_len(32B)',                  function() wire.decode_len(b_str32, 1) end)

section('Tag decode')
row('decode_tag(1-byte tag)',           function() wire.decode_tag(b_tag1, 1) end)
row('decode_tag(2-byte tag)',           function() wire.decode_tag(b_tag16, 1) end)

section('Skip field')
row('skip_field(VARINT 1-byte)',        function() wire.skip_field(b1, 1, wire.WIRE_VARINT) end)
row('skip_field(I64)',                  function() wire.skip_field(b_f64, 1, wire.WIRE_I64) end)
row('skip_field(LEN 32B)',              function() wire.skip_field(b_str32, 1, wire.WIRE_LEN) end)
row('skip_field(I32)',                  function() wire.skip_field(b_f32, 1, wire.WIRE_I32) end)

section('UTF-8 validator')
row('is_valid_utf8(10B ASCII)',         function() wire.is_valid_utf8(s10) end)
row('is_valid_utf8(32B ASCII)',         function() wire.is_valid_utf8(s32) end)
row('is_valid_utf8(200B ASCII)',        function() wire.is_valid_utf8(s200) end)
row('is_valid_utf8(1KB ASCII)',         function() wire.is_valid_utf8(s1k) end, 50000)
local utf8mix = string.rep('\xe2\x9c\x94', 10)  -- 30 bytes of ✔
row('is_valid_utf8(30B mixed UTF-8)',   function() wire.is_valid_utf8(utf8mix) end)
