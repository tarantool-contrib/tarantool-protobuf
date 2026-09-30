#!/usr/bin/env tarantool
-- Lazy-decode micro-benchmark.
--
-- Measures the read+mutate+re-encode workload where lazy decode_lazy
-- (zero-copy index + passthrough on untouched fields) is expected to beat
-- eager decode+encode: large messages where the caller only touches a
-- few fields. Three scenarios:
--
--   1. passthrough: decode_lazy + :encode (no mutation)
--      The strongest claim. Eager has to materialize the whole table
--      and re-walk every field on encode; lazy returns the original
--      bytes verbatim after a single tag-scanning pass.
--
--   2. sparse read: decode_lazy + :get(a) + :get(b)
--      The proxy/router workload — touch a handful of fields out of
--      many. Eager pays for materializing everything, lazy only for
--      the fields read.
--
--   3. one-field rewrite: decode_lazy + :get(a) + :set(b, ...) + :encode
--      The mutation passthrough case. Eager re-encodes every field,
--      lazy splices the original bytes for everything but the dirty one.
--
-- Run:  tarantool bench/lazy_bench.lua
-- Output is human-readable on stderr (varies with CPU load; not committed).

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local clock = require('clock')

local SIZES = {
    {label = '1KB',   target = 1024},
    {label = '10KB',  target = 10240},
    {label = '100KB', target = 102400},
}

-- Emails-heavy Person — scales repeated strings to hit target size.
-- Index pass cost ≈ decode cost on this shape: every email has its own
-- tag/len scan, so lazy can't skip-jump over large subtrees. Use this
-- shape to honestly bound the lazy-vs-eager comparison on a workload
-- that gives lazy *no* structural advantage from skip_field.
local function build_payload(target)
    local per_email   = 36
    local fixed_bytes = 80
    local n_emails    = math.max(1, math.floor((target - fixed_bytes) / per_email))
    local p = {
        name = 'alicia', age = 42,
        address = {street = '1 Main St', city = 'Springfield', zip = 12345},
        lucky_numbers = {7, 13, 21, 42, 99},
        emails = {},
    }
    for i = 1, n_emails do
        p.emails[i] = string.rep('e', 28) .. string.format('%04d', i)
    end
    return p
end

local function iter_count(size_bytes)
    if size_bytes <  2000  then return  50000 end
    if size_bytes <  20000 then return   5000 end
    return 500
end

local function time_loop(fn, n)
    local t0 = clock.monotonic64()
    for _ = 1, n do fn() end
    local t1 = clock.monotonic64()
    return tonumber(t1 - t0) / 1e9
end

local function bench(fn, n)
    for _ = 1, math.min(n, 1000) do fn() end  -- warmup
    local best = math.huge
    for _ = 1, 5 do
        collectgarbage('collect')
        local t = time_loop(fn, n)
        if t < best then best = t end
    end
    return n / best  -- msgs/s at best-run
end

local function compare(label, eager_fn, lazy_fn, n)
    local e = bench(eager_fn, n)
    local l = bench(lazy_fn,  n)
    local ratio = l / e
    io.stderr:write(string.format(
        '  %-40s  eager %10.0f msgs/s  lazy %10.0f msgs/s  %s%.2fx\n',
        label, e, l, ratio >= 1 and 'lazy ' or 'lazy ', ratio))
end

for _, mode in ipairs({'full', 'runtime'}) do
    io.stderr:write('\n== mode: ' .. mode .. ' ==\n')
    local hello = require(mode .. '.hello.hello_pb')

    for _, size in ipairs(SIZES) do
        io.stderr:write(string.format('\n  size: %s\n', size.label))
        local payload = build_payload(size.target)
        local bytes   = hello.Person_encode(payload)
        local n       = iter_count(#bytes)

        -- 1. passthrough: decode + re-encode with no mutation
        compare('passthrough (decode + reencode)',
            function() hello.Person_encode(hello.Person_decode(bytes)) end,
            function() return hello.Person_decode_lazy(bytes):encode() end,
            n)

        -- 2. sparse read: read 2 top-level fields
        compare('sparse read (name + age)',
            function()
                local t = hello.Person_decode(bytes)
                local _ = t.name; _ = t.age
            end,
            function()
                local v = hello.Person_decode_lazy(bytes)
                local _ = v:get('name'); _ = v:get('age')
            end,
            n)

        -- 3. one-field rewrite: change `name`, keep everything else
        compare('rewrite name (decode + set + reencode)',
            function()
                local t = hello.Person_decode(bytes)
                t.name = 'mallory'
                local _ = hello.Person_encode(t)
            end,
            function()
                local v = hello.Person_decode_lazy(bytes)
                v:set('name', 'mallory')
                local _ = v:encode()
            end,
            n)
    end
end
