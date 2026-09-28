#!/usr/bin/env tarantool
-- Surgical alloc probe. Strips the encode path apart, measures KB-delta
-- per primitive operation, so we can attribute the ~136 B/op encode floor
-- to a specific source (table, varint string, result string, ...).
--
-- All cases run with GC stopped so allocations accumulate. We divide by
-- N to get bytes/op. To eliminate string-interning noise we use *unique*
-- input bytes per iteration where appropriate (suffix counter).

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
-- Allocator counters don't depend on JIT, but keep the line for uniformity
-- across bench scripts (any future throughput micro-probe is one edit away).
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local wire = require('pb.wire')
local hello = require('full.hello.hello_pb')

local N = 50000

local function alloc_per_op(label, fn, mk_arg)
    -- Warmup: let the JIT compile and any one-shot allocations settle.
    for i = 1, 1000 do fn(mk_arg and mk_arg(i) or nil) end
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for i = 1, N do fn(mk_arg and mk_arg(i) or nil) end
    local after = collectgarbage('count')
    collectgarbage('restart')
    collectgarbage('collect')
    local per_op = (after - before) * 1024 / N
    print(string.format('  %-50s %8.1f B/op', label, per_op))
end

print('=== Baseline: noop ===')
alloc_per_op('empty function', function() end)
alloc_per_op('return nil', function() return nil end)

print('\n=== Table allocation ===')
alloc_per_op('local t = {}', function() local t = {} end)
alloc_per_op('local t, n = {}, 0', function() local t, n = {}, 0 end)
alloc_per_op('local t = {}; t[1]=1; t[2]=2; t[3]=3', function()
    local t = {}; t[1] = 1; t[2] = 2; t[3] = 3
end)
alloc_per_op('local t = {}; for i=1,5 do t[i]=i end', function()
    local t = {}; for i = 1, 5 do t[i] = i end
end)
alloc_per_op('local t = {}; for i=1,10 do t[i]=i end', function()
    local t = {}; for i = 1, 10 do t[i] = i end
end)

print('\n=== wire.encode_varint (interned: same input) ===')
alloc_per_op('encode_varint(42)         [1-byte fast]', function()
    local s = wire.encode_varint(42)
end)
alloc_per_op('encode_varint(200)        [2-byte slow]', function()
    local s = wire.encode_varint(200)
end)
alloc_per_op('encode_varint(1e6)        [3-byte slow]', function()
    local s = wire.encode_varint(1000000)
end)

print('\n=== wire.encode_varint (unique per iter) ===')
alloc_per_op('encode_varint(i % 128)    [1-byte, unique-ish]', function(i)
    local s = wire.encode_varint(i % 128)
end, function(i) return i end)
alloc_per_op('encode_varint(128 + i)    [2-byte, unique]', function(i)
    local s = wire.encode_varint(128 + i)
end, function(i) return i end)

print('\n=== string.char (intern check) ===')
alloc_per_op('string.char(42)           [1-byte, same]', function()
    local s = string.char(42)
end)
alloc_per_op('string.char(i % 256)      [1-byte, varying]', function(i)
    local s = string.char(i % 256)
end, function(i) return i end)

print('\n=== table.concat ===')
alloc_per_op('concat of 3 short literal strings', function()
    local s = table.concat({"\x0a", "\x06", "alicia"})
end)
alloc_per_op('concat of 5 short literal strings', function()
    local s = table.concat({"\x0a", "\x06", "alicia", "\x10", "\x2a"})
end)

print('\n=== Full encode (Person fixtures) ===')
local p10 = {name = 'alicia', age = 42}
alloc_per_op('Person_encode 10B (same input each iter)', function()
    local s = hello.Person_encode(p10)
end)

-- Unique per iter via the lucky_numbers field (varying).
alloc_per_op('Person_encode 10B (varying age field)', function(i)
    p10.age = 42 + (i % 100)
    local s = hello.Person_encode(p10)
end, function(i) return i end)

local p100 = {name = string.rep('a', 90), age = 42}
alloc_per_op('Person_encode 100B (same input)', function()
    local s = hello.Person_encode(p100)
end)

-- Decode floor probe.
local p10_bytes = hello.Person_encode(p10)
local p100_bytes = hello.Person_encode(p100)
print('\n=== Full decode (Person fixtures) ===')
alloc_per_op('Person_decode 10B (same input)', function()
    local t = hello.Person_decode(p10_bytes)
end)
alloc_per_op('Person_decode 100B (same input)', function()
    local t = hello.Person_decode(p100_bytes)
end)

print('\n=== Drill-down: encode pieces (10B Person) ===')
-- Imitate Person_encode body manually so we can attribute each step.
alloc_per_op('table {} + n', function()
    local out, n = {}, 0
end)
alloc_per_op('+ append tag literal', function()
    local out, n = {}, 0
    n = n + 1; out[n] = "\x0a"
end)
alloc_per_op('+ append name varlen + name string', function()
    local out, n = {}, 0
    local v = 'alicia'
    n = n + 1; out[n] = "\x0a"
    n = n + 1; out[n] = wire.encode_varint(#v)
    n = n + 1; out[n] = v
end)
alloc_per_op('+ append age tag + varint', function()
    local out, n = {}, 0
    local v = 'alicia'
    n = n + 1; out[n] = "\x0a"
    n = n + 1; out[n] = wire.encode_varint(#v)
    n = n + 1; out[n] = v
    n = n + 1; out[n] = "\x10"
    n = n + 1; out[n] = wire.encode_varint(42)
end)
alloc_per_op('+ final table.concat (full path)', function()
    local out, n = {}, 0
    local v = 'alicia'
    n = n + 1; out[n] = "\x0a"
    n = n + 1; out[n] = wire.encode_varint(#v)
    n = n + 1; out[n] = v
    n = n + 1; out[n] = "\x10"
    n = n + 1; out[n] = wire.encode_varint(42)
    local r = table.concat(out)
end)

print('\n=== Large payload encode (unique output to defeat interning) ===')
-- Build a 1KB+ Person; vary an integer field so the encoded output is
-- unique per iter and the result string can't be interned.
local p1k = {
    name = 'alicia', age = 42,
    address = {street = '1 Main St', city = 'Springfield', zip = 12345},
    lucky_numbers = {7, 13, 21, 42, 99},
    emails = {},
}
for i = 1, 26 do p1k.emails[i] = string.rep('e', 28) .. string.format('%04d', i) end
print(string.format('  1KB Person encoded size = %d bytes', #hello.Person_encode(p1k)))

alloc_per_op('Person_encode 1KB (same input — interned)', function()
    local s = hello.Person_encode(p1k)
end)
alloc_per_op('Person_encode 1KB (varying age — NOT interned)', function(i)
    p1k.age = 42 + i
    local s = hello.Person_encode(p1k)
end, function(i) return i end)
