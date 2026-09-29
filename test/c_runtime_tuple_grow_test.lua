-- The C tuple encoder (pb.c_runtime.tuple_encode / tuple_encode_repeated)
-- across output-buffer growth.
--
-- The C tuple encoder writes into one buffer: 4 KiB on the C stack, then
-- a Lua userdata that doubles on every overflow and lives in a Lua stack
-- slot for the whole call. These tests push outputs across every growth
-- boundary (4 KiB, 8 KiB, 16 KiB, 64 KiB, 1 MiB) with singular message
-- fields ahead of, behind and between large repeated fields, nested
-- levels that each carry a large repeated field, map<K,V> values and
-- packed scalars, and require the C bytes to equal the Lua path's
-- (pb.tuple._lua). A last group runs a full GC cycle at every allocation
-- the encode makes, so a buffer that lost its stack slot would be freed
-- and overwritten while still in use.
--
-- The messages are test/proto/c_grow.proto, in both codegen modes.
-- Skipped unless PB_ENABLE_C=1 loaded pb.c_runtime.
local t = require('luatest')
local ffi = require('ffi')
local fiber = require('fiber')
local varbinary = require('varbinary')
local pb = require('pb')
local helper = require('tuple_helper')

local c = pb.c_runtime
local lua = pb.tuple._lua
local NULL = box.NULL
local MAP_MT = {__serialize = 'map'}

local function skip_if_no_c()
    if c == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

-- Outputs just below and just above each growth boundary.
local SIZES = {
    3500, 4200,
    7800, 8800,
    15800, 17000,
    60000, 70000,
    1000000, 1100000,
}

-- The sizes at which the buffer grows: past the 4 KiB stack buffer, then
-- at every doubling. SIZES aims at both sides of each; kvs_for only
-- approximates, so the tests check the lengths they actually produced.
local BOUNDARIES = {4096, 8192, 16384, 65536, 1048576}

local function assert_straddles(lengths, label)
    for _, b in ipairs(BOUNDARIES) do
        local below, above = false, false
        for _, n in ipairs(lengths) do
            if n < b then below = true elseif n > b then above = true end
        end
        t.assert(below and above,
                 ('%s: no outputs on both sides of %d bytes'):format(label, b))
    end
end

-- Value lengths: short, and longer than the 4 KiB stack buffer, so the
-- first growth happens inside a single value as well as between them.
local VALUE_LENS = {90, 600, 5000}

-- Compare two encodes without dumping megabytes on failure: report the
-- lengths and the first differing offset instead.
local function assert_same_bytes(got, want, label)
    if got == want then return end
    local n = math.min(#got, #want)
    local at = n + 1
    for i = 1, n do
        if got:byte(i) ~= want:byte(i) then at = i; break end
    end
    t.fail(('%s: C %d bytes, Lua %d bytes, first difference at %d')
        :format(label, #got, #want, at))
end

-- Encode `tuple` through the Lua path, the C function and the converter
-- method (which dispatches to C); all three must be equal. Returns the
-- length, so a test can check it really crossed the boundary it names.
local function check(conv, tuple, label)
    local want = lua.encode(conv, tuple)
    local ok, got = pcall(c.tuple_encode, conv._tplan, tuple)
    if not ok then
        t.fail(('%s: C encode raised: %s (Lua path: %d bytes)'):format(
            label, tostring(got), #want))
    end
    assert_same_bytes(got, want, label)
    assert_same_bytes(conv:encode(tuple), want, label .. ' (conv:encode)')
    return #want
end

local function check_repeated(conv, field_no, tuples, label)
    local want = lua.encode_repeated(conv, field_no, tuples)
    local ok, got = pcall(c.tuple_encode_repeated, conv._tplan, field_no,
                          tuples)
    if not ok then
        t.fail(('%s: C encode_repeated raised: %s (Lua path: %d bytes)')
            :format(label, tostring(got), #want))
    end
    assert_same_bytes(got, want, label)
    assert_same_bytes(conv:encode_repeated(field_no, tuples), want,
                      label .. ' (conv:encode_repeated)')
    return #want
end

-- KV maps adding up to roughly `total` encoded bytes. Values vary in
-- length so neighbouring outputs do not all land on the same offsets.
local function kvs_for(total, value_len)
    local out = {}
    local acc = 0
    local i = 0
    while acc < total do
        i = i + 1
        local v = string.rep(string.char(97 + i % 26), value_len + i % 7)
        out[i] = {key = 'k' .. i, value = v}
        acc = acc + #v + 8 + #tostring(i)
    end
    return out
end

-- A Header as each column type represents it: a map keyed by field name,
-- an array positioned by field number, or its own wire bytes.
local HEADER_TYPES = {'map', 'array', 'varbinary'}

local function header_as(column_type, a)
    if column_type == 'map' then return {a = a} end
    if column_type == 'array' then return {a} end
    -- Header.a is field 1, a varint; every value used here is < 128.
    return varbinary.new('\x08' .. string.char(a))
end

local function bind(desc, name, format)
    -- make_space is DDL, which box refuses to a fiber past its slice
    fiber.yield()
    return pb.tuple.bind(desc, helper.make_space(name, format))
end

-- Every format starts with an unbound primary key: encode ignores it.
local function format_of(columns)
    local format = {{name = 'id', type = 'unsigned'}}
    for _, col in ipairs(columns) do
        format[#format + 1] = {name = col[1], type = col[2],
                               is_nullable = col[3] or false}
    end
    return format
end

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_tuple_grow.' .. mode)
    local cg

    g.before_all(function()
        skip_if_no_c()
        cg = require(mode .. '.c_grow.c_grow_pb')
    end)

    g.before_each(function()
        skip_if_no_c()
        helper.ensure_box()
    end)

    -- A singular message field ahead of a repeated message field that
    -- pushes the output past the second growth, in every representation
    -- of the singular field; then every element count from 1 to 200 at
    -- 90-byte values, which walks the output through 4, 8 and 16 KiB one
    -- element at a time.
    function g.test_header_then_repeated()
        for _, ht in ipairs(HEADER_TYPES) do
            local conv = bind(cg.Before_descriptor, 'ctg_before', format_of({
                {'header', ht, true}, {'kvs', 'array'},
            }))
            for n = 1, 200 do
                local kvs = {}
                for i = 1, n do
                    kvs[i] = {key = 'k', value = string.rep('v', 90)}
                end
                check(conv, box.tuple.new({1, header_as(ht, 1), kvs}),
                      ('%s n=%d'):format(ht, n))
            end
        end
    end

    function g.test_singular_before_after_between()
        for _, ht in ipairs(HEADER_TYPES) do
            local before = bind(cg.Before_descriptor, 'ctg_before',
                format_of({{'header', ht, true}, {'kvs', 'array'}}))
            local after = bind(cg.After_descriptor, 'ctg_after',
                format_of({{'kvs', 'array'}, {'header', ht, true}}))
            local between = bind(cg.Between_descriptor, 'ctg_between',
                format_of({{'head', 'array'}, {'header', ht, true},
                           {'tail', 'array'}}))
            for _, vlen in ipairs(VALUE_LENS) do
                local lengths = {}
                for _, size in ipairs(SIZES) do
                    local label = ('%s value=%d size=%d'):format(ht, vlen,
                                                                size)
                    local h = header_as(ht, 7)
                    lengths[#lengths + 1] = check(before, box.tuple.new(
                        {1, h, kvs_for(size, vlen)}), 'Before ' .. label)
                    check(after, box.tuple.new(
                        {1, kvs_for(size, vlen), h}), 'After ' .. label)
                    check(between, box.tuple.new(
                        {1, kvs_for(size / 2, vlen), h,
                         kvs_for(size / 2, vlen)}), 'Between ' .. label)
                end
                -- longer values cannot make an output under 4 KiB
                if vlen == VALUE_LENS[1] then
                    assert_straddles(lengths, ('%s value=%d'):format(ht,
                                                                    vlen))
                end
            end
        end
    end

    -- The first growth happens in a scalar rather than in a message.
    function g.test_large_scalar_before_repeated_message()
        local conv = bind(cg.BigFirst_descriptor, 'ctg_bigfirst', format_of({
            {'big', 'varbinary'}, {'kvs', 'array'}, {'name', 'string'},
        }))
        for _, big in ipairs({3000, 4200, 9000}) do
            for _, size in ipairs(SIZES) do
                check(conv, box.tuple.new({1,
                    varbinary.new(string.rep('b', big)),
                    kvs_for(size, 90), 'tail'}),
                    ('big=%d size=%d'):format(big, size))
            end
        end
    end

    -- Three levels, each with a singular message ahead of a large
    -- repeated field and another behind it. The tuple holds level 1;
    -- levels 2 and 3 are maps inside its arrays.
    function g.test_nested_levels_with_large_repeated()
        local function level3(size)
            return {header = {a = 3}, kvs = kvs_for(size, 90)}
        end
        local function level2(size)
            return {
                header = {a = 2},
                items = {level3(size / 4), level3(size / 4)},
                kvs = kvs_for(size / 2, 600),
                trailer = {a = 22},
            }
        end
        for _, ht in ipairs(HEADER_TYPES) do
            local conv = bind(cg.Level1_descriptor, 'ctg_level1', format_of({
                {'header', ht, true}, {'items', 'array'}, {'kvs', 'array'},
                {'trailer', ht, true},
            }))
            for _, size in ipairs(SIZES) do
                check(conv, box.tuple.new({1, header_as(ht, 1),
                    {level2(size / 3), level2(size / 3)},
                    kvs_for(size / 3, 90), header_as(ht, 11)}),
                    ('%s size=%d'):format(ht, size))
            end
        end
    end

    -- map<K,V> entries between singular message fields; the values are
    -- messages, and those of `nested` carry large repeated fields of
    -- their own.
    function g.test_map_message_values()
        local conv = bind(cg.WithMap_descriptor, 'ctg_withmap', format_of({
            {'header', 'map', true}, {'by_key', 'map'}, {'nested', 'map'},
            {'trailer', 'map', true},
        }))
        for _, vlen in ipairs(VALUE_LENS) do
            for _, size in ipairs(SIZES) do
                local by_key = {}
                for i, kv in ipairs(kvs_for(size / 2, vlen)) do
                    by_key['key' .. i] = kv
                end
                local nested = setmetatable({}, MAP_MT)
                local per = math.max(1, math.floor(size / 2 / 4000))
                for i = 1, per do
                    nested[i] = {header = {a = i % 100},
                                 kvs = kvs_for(4000, 90)}
                end
                check(conv, box.tuple.new({1, {a = 1}, by_key, nested,
                                           {a = 2}}),
                      ('value=%d size=%d'):format(vlen, size))
            end
        end
    end

    function g.test_packed_between_messages()
        local conv = bind(cg.WithPacked_descriptor, 'ctg_withpacked',
            format_of({{'header', 'map', true}, {'nums', 'array'},
                       {'kvs', 'array'}, {'more', 'array'},
                       {'trailer', 'map', true}}))
        for _, size in ipairs(SIZES) do
            local nums, more = {}, {}
            for i = 1, math.floor(size / 16) do
                nums[i] = 0xFFFFFFFFFFFFULL + i
                more[i] = (i % 2 == 0) and i or -i
            end
            check(conv, box.tuple.new({1, {a = 1}, nums, kvs_for(size / 2, 90),
                                       more, {a = 2}}),
                  ('size=%d'):format(size))
        end
    end

    -- encode_repeated writes every row into the same buffer: rows of
    -- every size, so the growths land inside a row's header, inside its
    -- repeated field and between rows. Absent headers too.
    function g.test_encode_repeated()
        for _, ht in ipairs(HEADER_TYPES) do
            local conv = bind(cg.Before_descriptor, 'ctg_before', format_of({
                {'header', ht, true}, {'kvs', 'array'},
            }))
            for _, vlen in ipairs(VALUE_LENS) do
                local lengths = {}
                for _, size in ipairs(SIZES) do
                    local rows = {}
                    local acc, k = 0, 0
                    while acc < size do
                        k = k + 1
                        local part = (k % 3 == 0) and size / 4 or 300
                        local h = (k % 5 == 0) and NULL or header_as(ht, k % 100)
                        rows[k] = box.tuple.new({k, h, kvs_for(part, vlen)})
                        acc = acc + part
                    end
                    local label = ('%s value=%d size=%d'):format(ht, vlen,
                                                                size)
                    lengths[#lengths + 1] = check_repeated(conv, 2, rows,
                                                           label)
                end
                if vlen == VALUE_LENS[1] then
                    assert_straddles(lengths, ('%s value=%d'):format(ht,
                                                                    vlen))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- A full GC cycle at every allocation
-- ---------------------------------------------------------------------

-- A buffer growth is lua_newuserdata, which runs a GC step before it
-- allocates whenever the heap is past the GC threshold. With a pause of
-- 0 the threshold set at the end of every cycle is 0, so every growth
-- runs a step; with helper.GC_FULL_CYCLE_STEPMUL that one step finishes
-- the cycle, finalizers included. So each growth runs a full collection
-- while the storage it is about to copy from is the buffer's only copy.
-- None of this depends on timing or on the allocator: it is how LuaJIT
-- steps its collector.
--
-- A finalizer, run inside each of those cycles after the sweep, counts
-- the cycle, fills blocks of every buffer size with a marker byte, so
-- memory the sweep just freed is reused at once, and plants the next
-- finalizer for the next cycle. An output buffer that is not anchored on
-- the Lua stack is then freed and overwritten while the encoder still
-- writes to it and reads from it, and the bytes differ. The count is
-- checked against the number of growths the output length implies, so a
-- run in which the collections did not happen fails instead of passing
-- without having tested anything.
local ggc = t.group('c_runtime_tuple_grow.gc')

ggc.before_each(function()
    skip_if_no_c()
    helper.ensure_box()
end)

local marking = false
local marks = {}
local cycles = 0

local function mark()
    if not marking then return end
    cycles = cycles + 1
    local size = 256
    while size <= 131072 do
        for delta = -96, 160, 16 do
            local p = ffi.new('uint8_t[?]', size + delta)
            ffi.fill(p, size + delta, 0xEE)
            marks[#marks + 1] = p
        end
        size = size * 2
    end
    -- A finalizable object nothing refers to, for the next cycle.
    ffi.gc(ffi.new('char[1]'), mark)
end

-- Run fn(...) with a full collection at every allocation it makes.
-- Returns fn's pcall results and the number of cycles that ran.
local function with_gc_at_every_allocation(fn, ...)
    local pause = collectgarbage('setpause', 0)
    local stepmul = collectgarbage('setstepmul', helper.GC_FULL_CYCLE_STEPMUL)
    -- The threshold is set at the end of a cycle: finish one under the
    -- new pause.
    collectgarbage('collect')
    marks = {}
    cycles = 0
    marking = true
    ffi.gc(ffi.new('char[1]'), mark)
    local ok, res = pcall(fn, ...)
    marking = false
    collectgarbage('setpause', pause)
    collectgarbage('setstepmul', stepmul)
    marks = {}
    collectgarbage('collect')
    return ok, res, cycles
end

-- How many times the buffer grows to hold `len` bytes.
local function growths(len)
    local cap, n = 4096, 0
    while cap < len do
        cap = cap * 2
        n = n + 1
    end
    return n
end

-- `n` cycles ran during a call whose output is `len` bytes: one at each
-- growth, and one when the result string is made from the buffer
-- (lua_pushlstring steps the collector before it copies), at least.
local function assert_collected(n, len, label)
    local g = growths(len)
    t.assert_ge(g, 1, label .. ': the output never left the stack buffer')
    t.assert(n >= g + 1, ('%s: %d collections for %d growths: the harness '
        .. 'did not collect at every allocation'):format(label, n, g))
end

function ggc.test_buffer_stays_anchored_across_collection()
    local cg = require('full.c_grow.c_grow_pb')
    fiber.yield()
    local s = helper.make_space('ctg_gc', format_of({
        {'header', 'map', true}, {'items', 'array'}, {'kvs', 'array'},
        {'trailer', 'map', true},
    }))
    local conv = pb.tuple.bind(cg.Level1_descriptor, s)
    local tplan = conv._tplan
    local function level2(vlen)
        return {
            header = {a = 2},
            items = {{header = {a = 3}, kvs = kvs_for(3 * vlen, 90)}},
            kvs = kvs_for(2 * vlen, 600),
            trailer = {a = 22},
        }
    end
    for _, vlen in ipairs({300, 1000, 3000, 6000}) do
        local items = {}
        for i = 1, 4 do items[i] = level2(vlen) end
        local row = box.tuple.new({1, {a = 1}, items, kvs_for(4 * vlen, 90),
                                   {a = 11}})
        local rows = {row, box.tuple.new({2, NULL, {}, kvs_for(vlen, 5000),
                                          NULL}), row}
        local label = ('value=%d'):format(vlen)

        local want = lua.encode(conv, row)
        local ok, got, n = with_gc_at_every_allocation(c.tuple_encode, tplan,
                                                       row)
        t.assert(ok, tostring(got))
        assert_collected(n, #want, 'encode ' .. label)
        assert_same_bytes(got, want, 'encode ' .. label)

        local want_rep = lua.encode_repeated(conv, 2, rows)
        local ok_rep, got_rep, n_rep = with_gc_at_every_allocation(
            c.tuple_encode_repeated, tplan, 2, rows)
        t.assert(ok_rep, tostring(got_rep))
        assert_collected(n_rep, #want_rep, 'encode_repeated ' .. label)
        assert_same_bytes(got_rep, want_rep, 'encode_repeated ' .. label)
        fiber.yield()
    end

    -- map<K,V> entries with message values between singular messages
    fiber.yield()
    s = helper.make_space('ctg_gc', format_of({
        {'header', 'map', true}, {'by_key', 'map'}, {'nested', 'map'},
        {'trailer', 'map', true},
    }))
    conv = pb.tuple.bind(cg.WithMap_descriptor, s)
    for _, vlen in ipairs({300, 1000, 3000, 6000}) do
        local by_key = {}
        for i, kv in ipairs(kvs_for(6 * vlen, 90)) do
            by_key['key' .. i] = kv
        end
        local nested = setmetatable({}, MAP_MT)
        for i = 1, 4 do
            nested[i] = {header = {a = i}, kvs = kvs_for(2 * vlen, 600)}
        end
        local row = box.tuple.new({1, {a = 1}, by_key, nested, {a = 2}})
        local label = ('map value=%d'):format(vlen)
        local want = lua.encode(conv, row)
        local ok, got, n = with_gc_at_every_allocation(c.tuple_encode,
                                                       conv._tplan, row)
        t.assert(ok, tostring(got))
        assert_collected(n, #want, label)
        assert_same_bytes(got, want, label)
        fiber.yield()
    end
end
