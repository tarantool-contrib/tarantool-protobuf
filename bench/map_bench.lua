#!/usr/bin/env tarantool
-- Map-field encode microbench for verifying map-codegen changes.
-- Person has `ages_by_nickname` (map<string,int32>) which we populate
-- across multiple sizes and time encode-only throughput.
--
-- Run before and after a map codegen change; compare medians.
-- The build_person_payload from bench/bench.lua doesn't exercise maps,
-- so the headline perf log can't show this. This script fills the gap.

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local clock = require('clock')
local hello_full    = require('full.hello.hello_pb')
local hello_runtime = require('runtime.hello.hello_pb')

local function build(n_entries)
    local m = {}
    for i = 1, n_entries do
        m['nick_' .. tostring(i)] = i
    end
    return {name = 'alicia', age = 42, ages_by_nickname = m}
end

local SIZES = {1, 3, 10, 50, 200}

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
    print(string.format('  %-40s  %10.0f msgs/s  %8.1f MB/s', label, msgs, mb))
    return msgs
end

print('=== Map encode bench (Person.ages_by_nickname, map<string,int32>) ===')
for _, n_entries in ipairs(SIZES) do
    local p = build(n_entries)
    local bytes = #hello_full.Person_encode(p)
    print(string.format('\n[map size %d, encoded %d bytes]', n_entries, bytes))
    bench_one('full Person_encode',    hello_full.Person_encode,    p, bytes)
    bench_one('runtime Person_encode', hello_runtime.Person_encode, p, bytes)
end
