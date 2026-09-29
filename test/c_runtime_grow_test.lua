-- C-side encode across output-buffer growth.
--
-- The C encoder starts every message in a stack-backed buffer (4 KiB at
-- the top level, 512 bytes for nested messages, groups and map entries)
-- and moves it to a Lua userdata on overflow, doubling from there. The
-- userdata lives in a Lua stack slot for the whole encode; these tests
-- push outputs across every growth boundary (4 KiB, 8 KiB, 16 KiB,
-- 64 KiB, 1 MiB) while sub-message, group, map and extension encodes
-- run in between, and require the C output to be byte-equal to the
-- pure-Lua codec's.
--
-- Only runs when PB_ENABLE_C=1 is set and the C runtime is loadable.

local t = require('luatest')
local ffi = require('ffi')

local pb = require('pb')
local codec = require('pb.codec')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
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

-- Compare C and pure-Lua encodes without dumping megabytes on failure:
-- report the lengths and the first differing offset instead.
local function assert_same_encode(desc, msg, label)
    local plan = c_runtime.compile_plan(desc)
    local ok, c_bytes = pcall(c_runtime.encode, plan, msg)
    local lua_bytes = codec.encode(desc, msg)
    if not ok then
        t.fail(('%s: C encode raised: %s (Lua codec: %d bytes)'):format(
            label, tostring(c_bytes), #lua_bytes))
    end
    if c_bytes ~= lua_bytes then
        local n = math.min(#c_bytes, #lua_bytes)
        local at = n + 1
        for i = 1, n do
            if c_bytes:byte(i) ~= lua_bytes:byte(i) then at = i; break end
        end
        t.fail(('%s: C %d bytes, Lua %d bytes, first difference at %d')
            :format(label, #c_bytes, #lua_bytes, at))
    end
    return #lua_bytes
end

-- KV entries adding up to roughly `total` encoded bytes. Values vary in
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

-- Value lengths: well below the nested 512-byte buffer, just above it
-- (nested buffers grow too), and above the 4 KiB top-level buffer.
local VALUE_LENS = {90, 600, 5000}

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_grow.' .. mode)
    local cg, cg2, p2

    g.before_all(function()
        skip_if_no_c()
        cg  = require(mode .. '.c_grow.c_grow_pb')
        cg2 = require(mode .. '.c_grow_proto2.c_grow_proto2_pb')
        p2  = require(mode ..
            '.protobuf_test_messages.proto2.test_messages_proto2_pb')
    end)

    g.before_each(skip_if_no_c)

    -- The reported shape: a singular message field ahead of a repeated
    -- message field that pushes the output past the second growth.
    function g.test_header_then_repeated_reported_shape()
        for _, n in ipairs({80, 90, 200, 800}) do
            local kvs = {}
            for i = 1, n do
                kvs[i] = {key = 'k', value = string.rep('v', 90)}
            end
            assert_same_encode(cg.Before_descriptor,
                {header = {a = 1}, kvs = kvs}, ('n=%d'):format(n))
        end
    end

    -- Every element count from 1 to 200 at 90-byte values walks the
    -- output through 4 KiB, 8 KiB and 16 KiB one element at a time.
    function g.test_header_then_repeated_element_sweep()
        for n = 1, 200 do
            local kvs = {}
            for i = 1, n do
                kvs[i] = {key = 'k', value = string.rep('v', 90)}
            end
            assert_same_encode(cg.Before_descriptor,
                {header = {a = 1}, kvs = kvs}, ('n=%d'):format(n))
        end
    end

    function g.test_singular_before_after_between()
        for _, vlen in ipairs(VALUE_LENS) do
            for _, size in ipairs(SIZES) do
                local label = ('value=%d size=%d'):format(vlen, size)
                assert_same_encode(cg.Before_descriptor, {
                    header = {a = 7}, kvs = kvs_for(size, vlen),
                }, 'Before ' .. label)
                assert_same_encode(cg.After_descriptor, {
                    kvs = kvs_for(size, vlen), header = {a = 7},
                }, 'After ' .. label)
                assert_same_encode(cg.Between_descriptor, {
                    head = kvs_for(size / 2, vlen),
                    header = {a = 7},
                    tail = kvs_for(size / 2, vlen),
                }, 'Between ' .. label)
            end
        end
    end

    function g.test_large_scalar_before_repeated_message()
        for _, big in ipairs({3000, 4200, 9000}) do
            for _, size in ipairs(SIZES) do
                assert_same_encode(cg.BigFirst_descriptor, {
                    big = string.rep('b', big),
                    kvs = kvs_for(size, 90),
                    name = 'tail',
                }, ('big=%d size=%d'):format(big, size))
            end
        end
    end

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
        for _, size in ipairs(SIZES) do
            assert_same_encode(cg.Level1_descriptor, {
                header = {a = 1},
                items = {level2(size / 3), level2(size / 3)},
                kvs = kvs_for(size / 3, 90),
                trailer = {a = 11},
            }, ('size=%d'):format(size))
        end
    end

    -- Map entries go through their own sub-buffers; the parent grows
    -- between entries. Byte equality holds because both codecs walk the
    -- same Lua table with next().
    function g.test_map_message_values()
        for _, vlen in ipairs(VALUE_LENS) do
            for _, size in ipairs(SIZES) do
                local by_key, nested = {}, {}
                for i, kv in ipairs(kvs_for(size / 2, vlen)) do
                    by_key['key' .. i] = kv
                end
                local per = math.max(1, math.floor(size / 2 / 4000))
                for i = 1, per do
                    nested[i] = {header = {a = i}, kvs = kvs_for(4000, 90)}
                end
                assert_same_encode(cg.WithMap_descriptor, {
                    header = {a = 1},
                    by_key = by_key,
                    nested = nested,
                    trailer = {a = 2},
                }, ('value=%d size=%d'):format(vlen, size))
            end
        end
    end

    function g.test_packed_between_submessages()
        for _, size in ipairs(SIZES) do
            local nums, more = {}, {}
            for i = 1, math.floor(size / 16) do
                nums[i] = 0xFFFFFFFFFFFFULL + i
                more[i] = (i % 2 == 0) and i or -i
            end
            assert_same_encode(cg.WithPacked_descriptor, {
                header = {a = 1},
                nums = nums,
                kvs = kvs_for(size / 2, 90),
                more = more,
                trailer = {a = 2},
            }, ('size=%d'):format(size))
        end
    end

    function g.test_proto2_groups()
        for _, size in ipairs(SIZES) do
            local entries = {}
            for i, kv in ipairs(kvs_for(size / 2, 90)) do
                entries[i] = {blob = string.rep('e', 40 + i % 5), kv = kv}
            end
            assert_same_encode(cg2.Holder_descriptor, {
                first = {key = 'f', value = 'first'},
                entry = entries,
                single = {
                    kv = {key = 's', value = 'single'},
                    kvs = kvs_for(size / 2, 600),
                },
                last = {key = 'l', value = 'last'},
            }, ('size=%d'):format(size))
        end
    end

    function g.test_proto2_extensions()
        for _, size in ipairs(SIZES) do
            assert_same_encode(cg2.Holder_descriptor, {
                first = {key = 'f', value = 'first'},
                entry = {{blob = string.rep('x', size / 4)}},
                last = {key = 'l', value = 'last'},
                _extensions = {
                    ['c_grow_proto2.ext_kv'] = {
                        key = 'e', value = string.rep('y', size / 4),
                    },
                    ['c_grow_proto2.ext_kvs'] = kvs_for(size / 4, 90),
                    ['c_grow_proto2.ext_blob'] = string.rep('z', size / 4),
                },
            }, ('size=%d'):format(size))
        end
    end

    -- MessageSet items wrap each extension in a group around an ordinary
    -- sub-message encode.
    function g.test_message_set_items()
        local pkg = 'protobuf_test_messages.proto2.TestAllTypesProto2.'
        local ext1 = pkg .. 'MessageSetCorrectExtension1.message_set_extension'
        local ext2 = pkg .. 'MessageSetCorrectExtension2.message_set_extension'
        for _, size in ipairs(SIZES) do
            assert_same_encode(p2.TestAllTypesProto2_descriptor, {
                optional_string = string.rep('s', size / 2),
                message_set_correct = {
                    _extensions = {
                        [ext1] = {str = string.rep('m', size / 2)},
                        [ext2] = {i = 7},
                    },
                },
                optional_int32 = 5,
            }, ('size=%d'):format(size))
        end
    end

    -- The item header of the second extension is reserved before its
    -- message is encoded; sweep the first item's size so that reserve
    -- lands on every nested-buffer boundary (1, 2, 4 and 8 KiB).
    function g.test_message_set_item_boundary_sweep()
        local pkg = 'protobuf_test_messages.proto2.TestAllTypesProto2.'
        local ext1 = pkg .. 'MessageSetCorrectExtension1.message_set_extension'
        local ext2 = pkg .. 'MessageSetCorrectExtension2.message_set_extension'
        for _, boundary in ipairs({1024, 2048, 4096, 8192}) do
            for len = boundary - 40, boundary + 8 do
                assert_same_encode(p2.TestAllTypesProto2_descriptor, {
                    message_set_correct = {
                        _extensions = {
                            [ext1] = {str = string.rep('m', len)},
                            [ext2] = {i = 7},
                        },
                    },
                }, ('len=%d'):format(len))
            end
        end
    end
end

-- A descriptor-level encode override is Lua code the C encoder calls in
-- the middle of an encode. Running a full collection there, then
-- allocating blocks of every buffer size filled with a marker byte,
-- turns any encode buffer that is not anchored on the Lua stack into
-- freed memory that the marker blocks reuse — so a lost anchor shows up
-- as corrupted output instead of depending on when the GC happens to run.
local gc = t.group('c_runtime_grow.gc')

gc.before_each(skip_if_no_c)

function gc.test_buffers_stay_anchored_across_collection()
    local m = pb.parse([[
        syntax = "proto3";
        package grow_gc;
        message Tick { bytes x = 1; }
        message Item { bytes v = 1; Tick t = 2; repeated Tick more = 3; }
        message Root {
            Tick head = 1;
            repeated Item items = 2;
            map<string, Item> by_key = 3;
            bytes tail = 4;
        }
    ]])
    local keep = {}
    m.Tick_descriptor.encode = function(v)
        collectgarbage('collect')
        collectgarbage('collect')
        local size = 256
        while size <= 65536 do
            for delta = -96, 160, 16 do
                local p = ffi.new('uint8_t[?]', size + delta)
                ffi.fill(p, size + delta, 0xEE)
                keep[#keep + 1] = p
            end
            size = size * 2
        end
        return v.x
    end
    m.Tick_descriptor.decode = function(b) return {x = b} end

    for _, vlen in ipairs({300, 1000, 3000, 6000}) do
        local items, by_key = {}, {}
        for i = 1, 6 do
            items[i] = {
                v = string.rep(string.char(65 + i), vlen),
                t = {x = 't' .. i},
                more = {{x = 'a'}, {x = string.rep('b', vlen)}},
            }
            by_key['k' .. i] = items[i]
        end
        local msg = {
            head = {x = 'h'},
            items = items,
            by_key = by_key,
            tail = string.rep('z', vlen),
        }
        keep = {}
        assert_same_encode(m.Root_descriptor, msg,
            ('value=%d'):format(vlen))
        keep = {}
    end
end

-- The decoder captures unknown fields in the same kind of buffer; push
-- it past several growths while repeated-field list tables are being
-- created on the stack.
function gc.test_decode_unknown_fields_across_growth()
    local cg = require('full.c_grow.c_grow_pb')
    local desc = cg.Before_descriptor
    local parts = {}
    for i = 1, 400 do
        parts[#parts + 1] = codec.encode(desc, {
            header = (i % 50 == 0) and {a = i} or nil,
            kvs = {{key = 'k' .. i, value = string.rep('v', i % 90)}},
        })
        -- Field 50, LEN: 0x92 0x03, then length and payload.
        local u = string.rep(string.char(48 + i % 10), 20 + i % 30)
        parts[#parts + 1] = '\x92\x03' .. string.char(#u) .. u
    end
    local bytes = table.concat(parts)
    local plan = c_runtime.compile_plan(desc)
    local c_msg = c_runtime.decode(plan, bytes)
    local lua_msg = codec.decode(desc, bytes)
    t.assert_equals(#c_msg._unknown_fields, #lua_msg._unknown_fields)
    t.assert_equals(c_msg, lua_msg)
end
