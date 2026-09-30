#!/usr/bin/env tarantool
-- One-off profiler over the 1 KB Person fixture — the size where the
-- decode MB/s halves and the encode MB/s stops climbing. Uses jit.p
-- (sampling profiler shipped with LuaJIT) so output points at the
-- functions where wall time actually goes.
--
-- Usage:
--   tarantool bench/profile.lua            -- full report
--   tarantool bench/profile.lua encode     -- just encode
--   tarantool bench/profile.lua decode     -- just decode

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local jitp = require('jit.p')
local clock = require('clock')

local hello = require('full.hello.hello_pb')

-- Same payload shape as bench.lua build_person_payload(1024).
local per_email   = 36
local fixed_bytes = 80
local target      = 1024
local n_emails    = math.max(1, math.floor((target - fixed_bytes) / per_email))
local payload = {
    name = 'alicia',
    age  = 42,
    address = {street = '1 Main St', city = 'Springfield', zip = 12345},
    lucky_numbers = {7, 13, 21, 42, 99},
    emails = {},
}
for i = 1, n_emails do
    payload.emails[i] = string.rep('e', 28) .. string.format('%04d', i)
end

local encoded = hello.Person_encode(payload)
print(string.format('payload encoded size: %d bytes (%d emails)', #encoded, n_emails))

-- Warmup so JIT compiles before sampling.
for _ = 1, 5000 do hello.Person_encode(payload) end
for _ = 1, 5000 do hello.Person_decode(encoded) end

local ITER = 200000

local function profile(label, fn)
    print()
    print(('=== %s — jit.p mode=fl,4 (function + line, 4ms sample) ==='):format(label))
    -- 'fl' = group by function and line
    -- '4' = sample every 4 ms (default 10 ms; we run for ~2 s so 4 ms gives ~500 samples)
    -- '0' = no minimum count threshold
    -- 'm0.5' = show entries with >= 0.5% of total
    jitp.start('fl4m0.5')
    local t0 = clock.monotonic64()
    for _ = 1, ITER do fn() end
    local elapsed = tonumber(clock.monotonic64() - t0) / 1e9
    jitp.stop()
    print(string.format('iters=%d  elapsed=%.3fs  msgs/s=%.0f',
        ITER, elapsed, ITER / elapsed))
end

local function profile_v(label, fn)
    print()
    print(('=== %s — jit.p mode=vl,4 (full caller stack) ==='):format(label))
    jitp.start('vl4m1')
    for _ = 1, ITER do fn() end
    jitp.stop()
end

local what = arg[1] or 'all'

if what == 'all' or what == 'encode' then
    profile('Person_encode (1KB)', function() hello.Person_encode(payload) end)
    profile_v('Person_encode (1KB) callers', function() hello.Person_encode(payload) end)
end

if what == 'all' or what == 'decode' then
    profile('Person_decode (1KB)', function() hello.Person_decode(encoded) end)
    profile_v('Person_decode (1KB) callers', function() hello.Person_decode(encoded) end)
end

-- Also probe the encode-time intermediate string and table churn so we
-- can attribute the 1.3 KB/op allocation to specific call sites.
print()
print('=== alloc breakdown (gcinfo delta over 50k iters with GC stopped) ===')

local function alloc_for(label, fn)
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 50000 do fn() end
    local after = collectgarbage('count')
    collectgarbage('restart')
    collectgarbage('collect')
    print(string.format('%-32s  %.1f B/op', label,
        (after - before) * 1024 / 50000))
end

alloc_for('Person_encode (1KB)',    function() hello.Person_encode(payload) end)
alloc_for('Person_decode (1KB)',    function() hello.Person_decode(encoded) end)

-- Decode in pieces, to isolate the cost of repeated-string append.
local wire = require('pb.wire')
local emails_buf = string.char(0x1a, 32) .. string.rep('e', 32)  -- one email
alloc_for('decode_string x26 (just the field)', function()
    local list = {}
    for _ = 1, 26 do
        local v, _ = wire.decode_string(emails_buf, 2)
        list[#list + 1] = v
    end
end)
