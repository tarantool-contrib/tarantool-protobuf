#!/usr/bin/env tarantool
-- Workload-variety benchmark.
--
-- bench/bench.lua measures Person at 5 sizes, but the shape is always
-- "name + a bunch of email strings" — so it stresses the string fast
-- paths but says little about scalar-heavy, deeply-nested, or map-heavy
-- traffic. This file fills that gap by running encode + decode against
-- a handful of fundamentally different Person shapes.
--
-- Each shape is constructed with one knob dialed up and the others kept
-- minimal so the cost attribution stays clean — when "nested-heavy"
-- regresses but "scalar-heavy" doesn't, you know which codegen path
-- changed.
--
-- No baseline file. Throughput is informational; allocation per op is
-- shown alongside so churn at the GC level is also visible.

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local clock = require('clock')

local MODES = {'full', 'runtime'}

-- ---------------------------------------------------------------------------
-- Shape definitions. Each returns {label, payload, description}.
-- ---------------------------------------------------------------------------

local function shape_scalar_heavy()
    -- Lots of numeric + bool fields, no strings, no nesting, no maps.
    -- Exercises varint / fixed / float encode/decode paths.
    return {
        label = 'scalar-heavy',
        desc  = 'age + status + balance + user_id + weight_kg, no strings',
        payload = {
            age       = 42,
            status    = 1,    -- OK
            balance   = -12345,
            user_id   = require('ffi').cast('uint64_t', 0xfeedface00000001ULL),
            weight_kg = 72.5,
        },
    }
end

local function shape_packed_ints(n)
    -- Big packed repeated int32 — single field, N elements, exercises
    -- the packed encode/decode hot loop.
    local nums = {}
    for i = 1, n do nums[i] = i * 7 - 3 end
    return {
        label = 'packed-int32x' .. n,
        desc  = n .. ' packed int32s in a single lucky_numbers field',
        payload = {lucky_numbers = nums},
    }
end

local function shape_nested_heavy(n)
    -- Repeated Person friends — exercises nested-message encode + the
    -- generated _decode recursion + length-prefix path.
    local friends = {}
    for i = 1, n do
        friends[i] = {name = 'friend-' .. i, age = 20 + (i % 50)}
    end
    return {
        label = 'nested-x' .. n,
        desc  = n .. ' friend Persons, each {name, age}',
        payload = {friends = friends},
    }
end

local function shape_map_heavy(n)
    -- map<string, int32> with N entries. Exercises the map-entry decode
    -- (pairs-iter on encode, dispatch on decode), key dedup, etc.
    local m = {}
    for i = 1, n do m['name-' .. string.format('%04d', i)] = i end
    return {
        label = 'map-strxi32-x' .. n,
        desc  = n .. ' ages_by_nickname entries',
        payload = {ages_by_nickname = m},
    }
end

local function shape_map_msg(n)
    -- map<string, Address> — message-valued map. Stresses both the map
    -- entry framing and the nested-message recursion.
    local m = {}
    for i = 1, n do
        m['label-' .. i] = {street = 'St', city = 'City', zip = 10000 + i}
    end
    return {
        label = 'map-strxmsg-x' .. n,
        desc  = n .. ' addresses_by_label entries (message values)',
        payload = {addresses_by_label = m},
    }
end

local function shape_oneof_text()
    -- Result with the `text` oneof branch active.
    return {
        label = 'oneof-text',
        desc  = 'Result{id, oneof outcome.text="..."}',
        payload = {id = 7, text = 'all good'},
        message = 'Result',
    }
end

local function shape_wkt()
    -- Event with all WKT fields populated. Exercises Timestamp /
    -- Duration / Wrappers / Struct round-trip.
    local datetime = require('datetime')
    return {
        label = 'wkt-event',
        desc  = 'Event with Timestamp + Duration + Wrappers + Struct',
        payload = {
            title       = 'ev',
            created_at  = datetime.new({timestamp = 1700000000, nsec = 123456789}),
            duration    = {seconds = 60, nanos = 0},
            retry_count = 3,
            note        = 'hi',
            is_admin    = true,
            payload     = {foo = 'bar', n = 42, b = true},
        },
        message = 'Event',
    }
end

local SHAPES = {
    shape_scalar_heavy(),
    shape_packed_ints(100),
    shape_packed_ints(1000),
    shape_nested_heavy(10),
    shape_nested_heavy(100),
    shape_map_heavy(10),
    shape_map_heavy(100),
    shape_map_msg(50),
    shape_oneof_text(),
    shape_wkt(),
}

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local function summarize(samples)
    table.sort(samples)
    return samples[math.floor((#samples + 1) / 2)]
end

local function time_loop(fn, n)
    local t0 = clock.monotonic64()
    for _ = 1, n do fn() end
    local t1 = clock.monotonic64()
    return tonumber(t1 - t0) / 1e9
end

local function bench_throughput(fn, n, runs)
    for _ = 1, math.min(n, 1000) do fn() end
    local samples = {}
    for r = 1, runs do
        collectgarbage('collect')
        samples[r] = time_loop(fn, n)
    end
    local med = summarize(samples)
    return n / med, med
end

local function bench_alloc(fn, payload_bytes)
    local budget   = 64 * 1024 * 1024
    local per_iter = math.max(1, payload_bytes) * 2
    local n        = math.max(100, math.min(2000, math.floor(budget / per_iter)))
    for _ = 1, 100 do fn() end
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, n do fn() end
    local after = collectgarbage('count')
    collectgarbage('restart')
    collectgarbage('collect')
    return (after - before) * 1024 / n
end

local function iter_for(bytes)
    if bytes < 100   then return 100000 end
    if bytes < 2000  then return  20000 end
    if bytes < 20000 then return   2000 end
    return 200
end

local function run_shape(mode, shape)
    local pb_mod  = require(mode .. '.hello.hello_pb')
    local msg     = shape.message or 'Person'
    local encode  = pb_mod[msg .. '_encode']
    local decode  = pb_mod[msg .. '_decode']

    local bytes   = encode(shape.payload)
    local size    = #bytes
    local iters   = iter_for(size)

    local _ = decode(bytes)  -- warmup decode + verify it works

    local enc_mps, _ = bench_throughput(function() encode(shape.payload) end, iters, 5)
    local enc_bpo    = bench_alloc(function() encode(shape.payload) end, size)
    local dec_mps, _ = bench_throughput(function() decode(bytes) end, iters, 5)
    local dec_bpo    = bench_alloc(function() decode(bytes) end, size)

    return size, enc_mps, enc_bpo, dec_mps, dec_bpo
end

io.stderr:write(string.format('tarantool-protobuf shapes bench (%s)\n\n', _TARANTOOL))
print(string.format('%-10s %-22s %6s %14s %10s %14s %10s',
    'mode', 'shape', 'bytes',
    'enc msgs/s', 'enc B/op',
    'dec msgs/s', 'dec B/op'))
print(string.rep('-', 92))

for _, mode in ipairs(MODES) do
    for _, shape in ipairs(SHAPES) do
        local ok, size, enc_mps, enc_bpo, dec_mps, dec_bpo = pcall(run_shape, mode, shape)
        if ok then
            print(string.format('%-10s %-22s %6d %14.0f %10.0f %14.0f %10.0f',
                mode, shape.label, size,
                enc_mps, enc_bpo, dec_mps, dec_bpo))
        else
            io.stderr:write(string.format('  %s/%s FAILED: %s\n', mode, shape.label, tostring(size)))
        end
    end
    print()
end
