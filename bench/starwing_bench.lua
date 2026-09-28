#!/usr/bin/env tarantool
-- Head-to-head bench: starwing/lua-protobuf vs this repo's pb runtime.
--
-- Mirrors bench/bench.lua's payload shapes, sizes, iteration counts, and
-- measurement loop so the numbers line up column-for-column. Runs ONLY
-- the starwing path; our path stays in bench/bench.lua and we put the
-- two outputs side-by-side.
--
-- We strip our runtime/ off package.path so `require('pb')` resolves to
-- starwing's pb.so (installed under .rocks/lib/tarantool/) — same module
-- name, different code.

-- Resolve `pb` to starwing's C module, not our Lua runtime that's
-- installed as a rock under .rocks/share/tarantool/pb/. We do this by
-- loading the .so directly through package.loadlib and stuffing the
-- result into package.loaded before require('pb') has a chance to hit
-- the Lua-path loader.

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
-- starwing's code generates traces too, so the arena pressure is the same.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local clock = require('clock')
local fio   = require('fio')

local so_path = '.rocks/lib/tarantool/pb.so'
assert(fio.path.exists(so_path), 'starwing pb.so not at ' .. so_path)
local loader = assert(package.loadlib(so_path, 'luaopen_pb'))
package.loaded.pb = loader()
local pb = require('pb')      -- starwing
local io_   = io

-- ---- schema load -----------------------------------------------------------

local function slurp(path)
    local f = assert(fio.open(path, {'O_RDONLY'}))
    local s = f:read()
    f:close()
    return s
end

assert(pb.load(slurp('bench/starwing/hello.pb')),
    'failed to load hello.pb')
assert(pb.load(slurp('bench/starwing/proto2_basic.pb')),
    'failed to load proto2_basic.pb')

-- Match our runtime's default: int64 as cdata (starwing calls this 'int64').
pb.option('int64_as_number')   -- bench payloads stay in number range; avoids
                               -- per-call cdata allocation noise. Same regime
                               -- our bench/bench.lua exercises.

-- ---- payload builders (verbatim from bench/bench.lua) ----------------------

local function build_person_payload(target)
    if target <= 10 then
        return {name = 'alicia', age = 42}
    end
    if target <= 100 then
        return {
            name  = string.rep('a', target - 10),
            age   = 42,
        }
    end
    local per_email   = 36
    local fixed_bytes = 80
    local n_emails    = math.max(1, math.floor((target - fixed_bytes) / per_email))
    local p = {
        name = 'alicia',
        age  = 42,
        address = {street = '1 Main St', city = 'Springfield', zip = 12345},
        lucky_numbers = {7, 13, 21, 42, 99},
        emails = {},
    }
    for i = 1, n_emails do
        p.emails[i] = string.rep('e', 28) .. string.format('%04d', i)
    end
    return p
end

local function build_proto2_payload(target)
    if target <= 0 then
        -- starwing accepts extensions inline as fields of the .pb type
        -- (it loads the descriptor set, which includes them). The
        -- registered extension names are short — see registry below.
        return {id = 7, ext_count = 42}
    end
    local n_tags    = 16
    local per_tag   = 30
    local tags      = {}
    for i = 1, n_tags do
        tags[i] = string.rep('t', per_tag - 2) .. string.format('%02d', i)
    end
    local lucky = {}
    for i = 1, 8 do lucky[i] = 1000 + i end
    return {
        id            = 7,
        name          = 'bench',
        retries       = 9,
        lucky_numbers = lucky,
        tags          = tags,
        inner         = {key = string.rep('k', 16), weight = 3},
        Stats         = {latency_ns = 1234567, attempts = 4},
        ext_count     = 99,
        ext_label     = string.rep('x', 32),
    }
end

-- ---- measurement (mirrors bench/bench.lua) ---------------------------------

local PERSON_SIZES = {
    {label = '10B',   target = 10},
    {label = '100B',  target = 100},
    {label = '1KB',   target = 1024},
    {label = '10KB',  target = 10240},
    {label = '100KB', target = 102400},
}
local PROTO2_SIZES = {
    {label = 'min',  target = 0},
    {label = 'mid',  target = 1024},
}

local function iter_count(size_bytes)
    if size_bytes <  100   then return 200000 end
    if size_bytes <  2000  then return  50000 end
    if size_bytes <  20000 then return   5000 end
    return 500
end

local function summarize(samples)
    table.sort(samples)
    local n = #samples
    return {
        median = samples[math.floor((n + 1) / 2)],
        min    = samples[1],
        max    = samples[n],
    }
end

local function time_loop(fn, n)
    local t0 = clock.monotonic64()
    for _ = 1, n do fn() end
    local t1 = clock.monotonic64()
    return tonumber(t1 - t0) / 1e9
end

local function bench_throughput(fn, n, runs)
    for _ = 1, math.min(n, 1000) do fn() end
    local times = {}
    for r = 1, runs do
        collectgarbage('collect')
        times[r] = time_loop(fn, n)
    end
    local s = summarize(times)
    return {
        ns_per_op   = s.median / n * 1e9,
        msgs_per_s  = n / s.median,
    }
end

local function bench_alloc(fn, expected_bytes)
    local budget   = 64 * 1024 * 1024
    local per_iter = math.max(1, expected_bytes) * 2
    local n        = math.max(100, math.min(2000, math.floor(budget / per_iter)))
    for _ = 1, 100 do fn() end
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, n do fn() end
    local after = collectgarbage('count')
    collectgarbage('restart')
    collectgarbage('collect')
    return {
        bytes_per_op = (after - before) * 1024 / n,
    }
end

local function bench_one(type_name, payload)
    local encode = function() return pb.encode(type_name, payload) end
    local bytes  = pb.encode(type_name, payload)
    local decode = function() return pb.decode(type_name, bytes) end

    -- warmup decode
    local _ = pb.decode(type_name, bytes)

    local n    = iter_count(#bytes)
    local runs = 5

    local enc = bench_throughput(encode, n, runs)
    local ea  = bench_alloc(encode, #bytes)
    enc.mb_per_s        = #bytes * enc.msgs_per_s / 1e6
    enc.bytes_per_op    = ea.bytes_per_op

    local dec = bench_throughput(decode, n, runs)
    local da  = bench_alloc(decode, #bytes)
    dec.mb_per_s        = #bytes * dec.msgs_per_s / 1e6
    dec.bytes_per_op    = da.bytes_per_op

    return {size_bytes = #bytes, encode = enc, decode = dec}
end

-- ---- run -------------------------------------------------------------------

io_.stderr:write('starwing/lua-protobuf bench\n')
io_.stderr:write(string.format('  version: pb 0.5.3  (tarantool %s)\n', _TARANTOOL))

io_.write('\n=== hello.Person ===\n')
io_.write(string.format('%-7s  %12s  %12s  %12s  %12s\n',
    'size', 'enc MB/s', 'enc B/op', 'dec MB/s', 'dec B/op'))
for _, sz in ipairs(PERSON_SIZES) do
    local p = build_person_payload(sz.target)
    local r = bench_one('hello.Person', p)
    io_.write(string.format('%-7s  %12.2f  %12.1f  %12.2f  %12.1f\n',
        sz.label, r.encode.mb_per_s, r.encode.bytes_per_op,
        r.decode.mb_per_s, r.decode.bytes_per_op))
end

io_.write('\n=== proto2_basic.BenchPayload ===\n')
io_.write(string.format('%-7s  %12s  %12s  %12s  %12s\n',
    'size', 'enc MB/s', 'enc B/op', 'dec MB/s', 'dec B/op'))
for _, sz in ipairs(PROTO2_SIZES) do
    local p = build_proto2_payload(sz.target)
    local r = bench_one('proto2_basic.BenchPayload', p)
    io_.write(string.format('%-7s  %12.2f  %12.1f  %12.2f  %12.1f\n',
        sz.label, r.encode.mb_per_s, r.encode.bytes_per_op,
        r.decode.mb_per_s, r.decode.bytes_per_op))
end

os.exit(0)
