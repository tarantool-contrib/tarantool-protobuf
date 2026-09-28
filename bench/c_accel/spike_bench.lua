#!/usr/bin/env tarantool
-- Spike harness for the C-acceleration spike.
--
-- Compares pure-Lua `full` mode (current baseline) against the
-- hand-written C codec for hello.Person across 5 payload sizes.
-- Strategies 2 (per-primitive FFI) and 3 (one generic C call) land
-- in follow-up sub-issues.
--
-- Usage:
--   make -C bench/c_accel
--   tarantool bench/c_accel/spike_bench.lua

local SCRIPT_DIR = (debug.getinfo(1, 'S').source:match('@?(.*/)') or './')
local REPO_ROOT  = SCRIPT_DIR .. '../..'

package.path  = REPO_ROOT .. '/runtime/?.lua;'
             .. REPO_ROOT .. '/runtime/?/init.lua;'
             .. REPO_ROOT .. '/examples/expected/?.lua;'
             .. REPO_ROOT .. '/examples/expected/?/init.lua;'
             .. package.path
package.cpath = SCRIPT_DIR .. '?.dylib;' .. SCRIPT_DIR .. '?.so;' .. package.cpath

local clock = require('clock')

local full = require('full.hello.hello_pb')

local ok, c_person = pcall(require, 'pb_c_person')
if not ok then
    io.stderr:write('failed to load pb_c_person: ' .. tostring(c_person) .. '\n')
    io.stderr:write('run `make -C bench/c_accel` first\n')
    os.exit(1)
end

local ok2, c_generic = pcall(require, 'pb_c_generic')
if not ok2 then
    io.stderr:write('failed to load pb_c_generic: ' .. tostring(c_generic) .. '\n')
    io.stderr:write('run `make -C bench/c_accel` first\n')
    os.exit(1)
end

local ok3, prim_ffi = pcall(require, 'prim_ffi')
if not ok3 then
    io.stderr:write('failed to load prim_ffi: ' .. tostring(prim_ffi) .. '\n')
    io.stderr:write('run `make -C bench/c_accel` first\n')
    os.exit(1)
end

-- Payload builder mirrors bench/bench.lua so numbers are comparable.
local function build_person_payload(target)
    if target <= 10 then
        return {name = 'alicia', age = 42}
    end
    if target <= 100 then
        return {name = string.rep('a', target - 10), age = 42}
    end
    local per_email   = 36
    local fixed_bytes = 80
    local n_emails    = math.max(1,
        math.floor((target - fixed_bytes) / per_email))
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

local SIZES = {
    {label = '10B',   target = 10},
    {label = '100B',  target = 100},
    {label = '1KB',   target = 1024},
    {label = '10KB',  target = 10240},
    {label = '100KB', target = 102400},
}

local function iter_count(size_bytes)
    if size_bytes <  100   then return 200000 end
    if size_bytes <  2000  then return  50000 end
    if size_bytes <  20000 then return   5000 end
    return 500
end

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

local function bench(fn, n, runs)
    for _ = 1, math.min(n, 1000) do fn() end
    local samples = {}
    for r = 1, runs do
        collectgarbage('collect')
        samples[r] = time_loop(fn, n)
    end
    return summarize(samples) / n  -- seconds per op
end

-- Sanity: every encoder must emit byte-equal output, every decoder must
-- return a table.
local function sanity_check()
    for _, sz in ipairs(SIZES) do
        local p = build_person_payload(sz.target)
        local lua_bytes = full.Person_encode(p)
        for label, mod in pairs({c_person = c_person, c_generic = c_generic, prim_ffi = prim_ffi}) do
            local bytes = mod.Person_encode(p)
            if bytes ~= lua_bytes then
                io.stderr:write(string.format(
                    'sanity FAIL %s at %s: lua=%d bytes %s=%d bytes\n',
                    label, sz.label, #lua_bytes, label, #bytes))
            end
            local back = mod.Person_decode(lua_bytes)
            if type(back) ~= 'table' then
                io.stderr:write(label .. ' decode non-table at ' .. sz.label .. '\n')
                os.exit(2)
            end
        end
    end
end

sanity_check()

local function fmt_op(t, bytes)
    return string.format('%8.0f / %7.1f', 1 / t, bytes / t / 1e6)
end

io.write('hello.Person — pure-Lua (full) vs S2 FFI prims vs S3 generic C vs S4 hand C\n')
io.write('×L columns = speedup vs pure-Lua baseline\n\n')
io.write(string.format(
    '%-6s %7s   %18s  %18s %5s  %18s %5s  %18s %5s\n',
    'size', 'bytes', 'pure-Lua', 'S2 FFI prim', '×L', 'S3 generic C', '×L', 'S4 hand C', '×L'))
io.write(string.rep('-', 124) .. '\n')

local runs = 5
local function run_phase(phase_name, get_fn)
    io.write(string.format('\n== %s ==\n', phase_name))
    for _, sz in ipairs(SIZES) do
        local p = build_person_payload(sz.target)
        local bytes = full.Person_encode(p)
        local n = iter_count(#bytes)
        local t_lua = bench(get_fn(full,      p, bytes), n, runs)
        local t_s2  = bench(get_fn(prim_ffi,  p, bytes), n, runs)
        local t_s3  = bench(get_fn(c_generic, p, bytes), n, runs)
        local t_s4  = bench(get_fn(c_person,  p, bytes), n, runs)
        io.write(string.format(
            '%-6s %7d   %18s  %18s %5.2f  %18s %5.2f  %18s %5.2f\n',
            sz.label, #bytes,
            fmt_op(t_lua, #bytes),
            fmt_op(t_s2,  #bytes), t_lua / t_s2,
            fmt_op(t_s3,  #bytes), t_lua / t_s3,
            fmt_op(t_s4,  #bytes), t_lua / t_s4))
    end
end

run_phase('ENCODE', function(mod, p, _) return function() mod.Person_encode(p) end end)
run_phase('DECODE', function(mod, _, bytes) return function() mod.Person_decode(bytes) end end)

os.exit(0)
