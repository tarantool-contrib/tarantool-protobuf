#!/usr/bin/env tarantool
-- Packed-scalar encode microbench for verifying the inlined
-- 1-byte-varint fast path for packed scalar elements.
-- c_repeated.Holder has packed_int32 / packed_int64 / packed_sint32 /
-- packed_uint32 / packed_bool — exercises every packed varint flavor.
-- Element values are kept in the 1-byte fast-path range so the CHARS
-- lookup branch dominates (the realistic hot case).

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local clock = require('clock')
local ffi   = require('ffi')

local holder_full = require('full.c_repeated.c_repeated_pb')

local INT64 = ffi.typeof('int64_t')

local function build_payload(n_elems, field)
    local arr = {}
    for i = 1, n_elems do
        -- Cycle through 0-127 to stay on the 1-byte varint fast path.
        arr[i] = i % 128
    end
    if field == 'packed_int64' then
        -- Convert to int64_t cdata to match the documented convention.
        for i = 1, n_elems do arr[i] = INT64(arr[i]) end
    elseif field == 'packed_bool' then
        for i = 1, n_elems do arr[i] = (i % 2 == 0) end
    end
    return {[field] = arr}
end

local FIELDS = {'packed_int32', 'packed_sint32', 'packed_uint32', 'packed_bool', 'packed_int64'}
local SIZES = {10, 100, 1000}

local function bench_one(label, fn, p, encoded_bytes)
    for _ = 1, 1000 do fn(p) end
    local probe = 5000
    local t0 = clock.proc()
    for _ = 1, probe do fn(p) end
    local dt = clock.proc() - t0
    local rate = probe / dt
    local iters = math.max(probe, math.min(2000000, math.floor(rate * 0.5)))
    t0 = clock.proc()
    for _ = 1, iters do fn(p) end
    dt = clock.proc() - t0
    local msgs = iters / dt
    local mb = msgs * encoded_bytes / 1024 / 1024
    print(string.format('  %-30s  %10.0f msgs/s  %8.1f MB/s', label, msgs, mb))
end

print('=== Packed scalar encode bench (c_repeated.Holder) ===')
for _, field in ipairs(FIELDS) do
    for _, n in ipairs(SIZES) do
        local p = build_payload(n, field)
        local bytes = #holder_full.Holder_encode(p)
        print(string.format('\n[%s × %d, encoded %d bytes]', field, n, bytes))
        bench_one('Holder_encode', holder_full.Holder_encode, p, bytes)
    end
end
