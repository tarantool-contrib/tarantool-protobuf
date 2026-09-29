-- The C tuple encoder (pb.c_runtime.tuple_encode / tuple_encode_repeated)
-- against the Lua path of pb.tuple.
--
-- The Lua path (pb.tuple._lua) is the oracle: for every tuple below, the
-- C encoder must return the same bytes or raise the same error message.
-- The corpus is hand-picked rows plus randomly generated ones (fixed
-- seed), over every proto scalar kind, every representation and every
-- per-value check. Skipped unless PB_ENABLE_C=1 loaded pb.c_runtime.
local t = require('luatest')
local ffi = require('ffi')
local msgpack = require('msgpack')
local uuid = require('uuid')
local datetime = require('datetime')
local decimal = require('decimal')
local varbinary = require('varbinary')
local fiber = require('fiber')
local pb = require('pb')
local helper = require('tuple_helper')

-- The corpus loops run long without yielding, and box refuses DDL to a
-- fiber past its time slice (FiberSliceIsExceeded): yield now and then.
local function pace(k)
    if k % 50 == 0 then fiber.yield() end
end

local c = pb.c_runtime
local lua = pb.tuple._lua
local NULL = box.NULL

local function skip_if_no_c()
    if c == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

local function hex(s)
    return (s:gsub('.', function(ch)
        return string.format('%02x', ch:byte())
    end))
end

-- A pcall result in a comparable shape; bytes as hex, so a mismatch
-- shows where the two outputs part.
local function outcome(ok, res)
    if ok then return {ok = true, bytes = hex(res)} end
    return {ok = false, err = tostring(res)}
end

-- Encode `tuple` through the Lua path, the C function and the converter
-- method (which dispatches to C); all three must agree.
local function check_parity(conv, tuple, what)
    local want = outcome(pcall(lua.encode, conv, tuple))
    local got = outcome(pcall(c.tuple_encode, conv._tplan, tuple))
    t.assert_equals(got, want, what)
    t.assert_equals(outcome(pcall(conv.encode, conv, tuple)), want, what)
    return want
end

local function check_repeated_parity(conv, field_no, tuples, what)
    local want = outcome(pcall(lua.encode_repeated, conv, field_no, tuples))
    local got = outcome(pcall(c.tuple_encode_repeated, conv._tplan,
                              field_no, tuples))
    t.assert_equals(got, want, what)
    t.assert_equals(outcome(pcall(conv.encode_repeated, conv, field_no,
                                  tuples)), want, what)
    return want
end

-- ---------------------------------------------------------------------
-- msgpack building blocks
-- ---------------------------------------------------------------------

local raw = msgpack.object_from_raw

-- A msgpack map whose entries keep the order given: {{k, v}, ...}.
local function omap(entries)
    local n = #entries
    local head
    if n < 16 then
        head = string.char(0x80 + n)
    else
        head = '\xde' .. string.char(bit.rshift(n, 8), bit.band(n, 0xff))
    end
    local parts = {head}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = msgpack.encode(e[1])
        parts[#parts + 1] = msgpack.encode(e[2])
    end
    return raw(table.concat(parts))
end

local I64_MIN = -9223372036854775807LL - 1

-- Integers that fit each range, as msgpack encodes them from Lua, plus a
-- few spelled with a wider or signed msgpack type than needed.
local S32 = {0, 1, -1, 127, 128, -129, 16384, 2147483647, -2147483648,
             raw('\xd0\x05'), raw('\xd0\x00'), raw('\xcc\x00'),
             raw('\xd2\x7f\xff\xff\xff')}
local U32 = {0, 1, 127, 128, 16384, 2147483648, 4294967295,
             raw('\xd0\x05'), raw('\xcc\x00'), raw('\xce\xff\xff\xff\xff')}
local S64 = {0, 1, -1, 2147483648, -2147483649, 4294967296, -4294967296,
             2^53, -2^53, 9007199254740993LL, 9223372036854775807LL, I64_MIN,
             raw('\xd3\x7f\xff\xff\xff\xff\xff\xff\xff'),
             raw('\xcf\x7f\xff\xff\xff\xff\xff\xff\xff')}
local U64 = {0, 1, 4294967296, 2^53, 9007199254740993ULL,
             9223372036854775808ULL, 18446744073709551615ULL,
             raw('\xd3\x00\x00\x00\x00\x00\x00\x00\x07')}
local INTS = {}
for _, list in ipairs({S32, U32, S64, U64}) do
    for _, v in ipairs(list) do INTS[#INTS + 1] = v end
end
INTS[#INTS + 1] = -2147483649
INTS[#INTS + 1] = I64_MIN + 1

local INT_RANGE = {
    int32 = S32, sint32 = S32, sfixed32 = S32, enum = S32,
    uint32 = U32, fixed32 = U32,
    int64 = S64, sint64 = S64, sfixed64 = S64,
    uint64 = U64, fixed64 = U64,
}

local FLOATS = {
    1.5, -2.25, 1e300, -1e-300, 3.5e38, 1e-46, math.huge, -math.huge,
    0, 7, -7, 18446744073709551615ULL, 9007199254740993LL,
    raw('\xcb\x00\x00\x00\x00\x00\x00\x00\x00'),   -- +0.0
    raw('\xcb\x80\x00\x00\x00\x00\x00\x00\x00'),   -- -0.0
    raw('\xcb\x7f\xf8\x00\x00\x00\x00\x00\x00'),   -- quiet NaN
    raw('\xcb\x7f\xf8\x00\x00\x00\x00\x00\x01'),   -- NaN with a payload
    raw('\xcb\xff\xf0\x00\x00\x00\x00\x00\x01'),   -- signalling, negative
    raw('\xca\x3d\xcc\xcc\xcd'),                   -- float32 0.1
    raw('\xca\x80\x00\x00\x00'),                   -- float32 -0.0
    raw('\xca\x00\x00\x00\x00'),                   -- float32 +0.0
    raw('\xca\x7f\xc0\x00\x01'),                   -- float32 NaN
    raw('\xca\x7f\x80\x00\x00'),                   -- float32 +inf
}

local LONG = string.rep('0123456789abcdef', 1300)   -- 20800 bytes
local STRINGS = {'', 'a', 'h\0llo', string.rep('x', 200), 'Привет',
                 varbinary.new(''), varbinary.new('bin\0'),
                 raw('\xd9\x03abc'), raw('\xc5\x00\x02hi')}

local U = uuid.fromstr('6ba7b810-9dad-11d1-80b4-00c04fd430c8')
local U2 = uuid.fromstr('ffffffff-0000-4000-8000-00000000000a')
local DTS = {
    datetime.new({timestamp = 1700000000, nsec = 123456789}),
    datetime.new({timestamp = 0}),
    datetime.new({timestamp = -1, nsec = 1}),
    datetime.new({timestamp = -62135596800}),
    datetime.new({timestamp = 1700000000, nsec = 5, tzoffset = 180}),
    datetime.new({timestamp = 253402300799, nsec = 999999999}),
}

local MAP_MT = {__serialize = 'map'}

-- Values of every msgpack class and extension, including extension types
-- Tarantool's Lua msgpack decoder does not know, for the wrong-type
-- checks.
local ANY = {NULL, true, false, 0, 1, -1, 4294967296, 18446744073709551615ULL,
             I64_MIN, 1.5, raw('\xca\x3f\xc0\x00\x00'), '', 'x',
             varbinary.new('y'), U, DTS[1], decimal.new('1.5'),
             datetime.interval.new({day = 1}), {}, {1, 2},
             setmetatable({a = 1}, MAP_MT),
             raw('\xd4\x2a\x00'), raw('\xd4\xff\x00'),
             raw('\xc7\x03\x2a\x01\x02\x03')}

local function pick(list) return list[math.random(#list)] end

-- ---------------------------------------------------------------------
-- The corpus messages
-- ---------------------------------------------------------------------

local ALL_PROTO = [[
    syntax = "proto3";
    package ck;
    import "google/protobuf/timestamp.proto";
    enum E { E0 = 0; E1 = 1; E2 = 2; }
    message Leaf { string s = 1; int32 i = 2; }
    message Nothing {}
    message All {
        int32 i32 = 1; int64 i64 = 2; uint32 u32 = 3; uint64 u64 = 4;
        sint32 s32 = 5; sint64 s64 = 6; fixed32 f32 = 7; fixed64 f64 = 8;
        sfixed32 sf32 = 9; sfixed64 sf64 = 10; float fl = 11;
        double db = 12; bool b = 13; string str = 14; bytes byt = 15;
        E e = 16;
        optional int32 o_i32 = 17; optional double o_db = 18;
        optional string o_str = 19; optional bool o_b = 20;
        google.protobuf.Timestamp ts = 21;
        Leaf leaf = 22;
        repeated int32 r_i32 = 23; repeated sint64 r_s64 = 24;
        repeated fixed32 r_f32 = 25; repeated sfixed64 r_sf64 = 26;
        repeated float r_fl = 27; repeated double r_db = 28;
        repeated bool r_b = 29; repeated E r_e = 30;
        repeated string r_str = 31; repeated bytes r_byt = 32;
        repeated uint64 r_u64 = 33 [packed = false];
        repeated google.protobuf.Timestamp r_ts = 34;
        repeated Leaf r_leaf = 35;
        map<int32, string> m_i32 = 36; map<uint64, int64> m_u64 = 37;
        map<sint32, double> m_s32 = 38; map<fixed64, bool> m_f64 = 39;
        map<sfixed32, bytes> m_sf32 = 40; map<bool, E> m_b = 41;
        map<string, google.protobuf.Timestamp> m_ts = 42;
        map<string, Leaf> m_leaf = 43; map<int64, float> m_i64 = 44;
        map<uint32, sint64> m_u32 = 45; map<fixed32, fixed32> m_fx = 46;
        map<sfixed64, sfixed64> m_sfx = 47; map<sint64, uint32> m_s64 = 48;
        oneof pick { int32 p_i = 50; string p_s = 51; Leaf p_leaf = 52; }
        All self = 60;
        repeated All selves = 61;
        Nothing nothing = 62;
        uint32 far = 1000;
    }
]]

local all_mod
local function all_desc()
    if all_mod == nil then all_mod = pb.parse(ALL_PROTO) end
    return all_mod.All_descriptor
end

-- An `any`, nullable column per field of `desc`, in field-number order,
-- with an unbound column between them.
local function any_format(desc)
    local fields = {}
    for _, f in ipairs(desc.fields) do fields[#fields + 1] = f end
    table.sort(fields, function(a, b) return a.id < b.id end)
    local format = {{name = 'pk', type = 'unsigned'}}
    for k, f in ipairs(fields) do
        format[#format + 1] = {name = f.name, type = 'any', is_nullable = true}
        if k == 3 then
            format[#format + 1] = {name = 'unbound', type = 'any',
                                   is_nullable = true}
        end
    end
    return format
end

local function column_of(format, name)
    for i, e in ipairs(format) do
        if e.name == name then return i end
    end
    error('no column ' .. name)
end

-- A row for `format` from {[column name] = value}; missing ones NULL.
local function row_of(format, values)
    local row = {1}
    for i = 2, #format do
        local v = values[format[i].name]
        if v == nil then v = NULL end
        row[i] = v
    end
    return box.tuple.new(row)
end

local RECORD_FORMAT = {
    {name = 'id',         type = 'unsigned'},
    {name = 'name',       type = 'string'},
    {name = 'address',    type = 'map', is_nullable = true},
    {name = 'phones',     type = 'array'},
    {name = 'scores',     type = 'map'},
    {name = 'nickname',   type = 'string', is_nullable = true},
    {name = 'kind',       type = 'unsigned'},
    {name = 'created_at', type = 'datetime', is_nullable = true},
    {name = 'owner',      type = 'uuid', is_nullable = true},
    {name = 'token',      type = 'uuid', is_nullable = true},
    {name = 'payload',    type = 'varbinary'},
    {name = 'weight',     type = 'number'},
    {name = 'active',     type = 'boolean'},
    {name = 'label',      type = 'map', is_nullable = true},
    {name = 'balance',    type = 'integer'},
    {name = 'note',       type = 'string', is_nullable = true},
}

local function record_format(address_type)
    local format = table.deepcopy(RECORD_FORMAT)
    if address_type ~= nil then
        format[3] = {name = 'address', type = address_type,
                     is_nullable = true}
    end
    return format
end

local function record_row()
    return {
        42, 'Alice',
        {street = 'Main', city = 'Town', zip = 12345},
        {{number = '555', kind = 1}, {number = '777'}},
        {math = 7},
        NULL, 2, DTS[1], U, U2,
        varbinary.new('\x00\x01'),
        1.5, true,
        {text = 'hi', weight = 3},
        -5, NULL,
    }
end

local MIXED_FORMAT = {
    {name = 'id',       type = 'string'},
    {name = 'tags',     type = 'array'},
    {name = 'counts',   type = 'array'},
    {name = 'contacts', type = 'map'},
    {name = 'rank',     type = 'integer'},
    {name = 'seen',     type = 'array'},
    {name = 'kinds',    type = 'array'},
    {name = 'child',    type = 'map', is_nullable = true},
    {name = 'code',     type = 'integer', is_nullable = true},
    {name = 'text',     type = 'string', is_nullable = true},
}

local function mixed_row()
    return {
        'm1', {'a', ''}, {1, -2, 3},
        omap({{7, {number = '7'}}, {0, setmetatable({}, MAP_MT)},
              {-3, {kind = 2}}}),
        9, {DTS[1], DTS[3]}, {1, 0, 2},
        {id = 'c', rank = 4, child = {tags = {'z'}}},
        NULL, 'txt',
    }
end

-- ---------------------------------------------------------------------
-- Random values for a descriptor field
-- ---------------------------------------------------------------------

local TIMESTAMP = 'google.protobuf.Timestamp'

local gen_message

-- `chaos` is the probability of replacing a value by one of any class.
local function gen_elem(f, depth, chaos)
    if math.random() < chaos then return pick(ANY) end
    if f.kind == 'enum' then return pick(S32) end
    if f.kind == 'message' then
        if f.message.name == TIMESTAMP then return pick(DTS) end
        return gen_message(f.message, depth + 1, chaos)
    end
    local k = f.proto_type
    if INT_RANGE[k] ~= nil then
        if chaos > 0 and math.random() < 0.3 then return pick(INTS) end
        return pick(INT_RANGE[k])
    end
    if k == 'double' or k == 'float' then return pick(FLOATS) end
    if k == 'bool' then return math.random() < 0.5 end
    if math.random() < 0.02 then return LONG end
    return pick(STRINGS)
end

local function gen_value(f, depth, chaos)
    if math.random() < chaos then return pick(ANY) end
    if f.kind == 'map' then
        local entries = {}
        for k = 1, math.random(0, 3) do
            entries[k] = {gen_elem(f.key, depth, chaos),
                          gen_elem(f.value, depth, chaos)}
        end
        return omap(entries)
    end
    if f.repeated then
        local arr = {}
        for k = 1, math.random(0, 4) do arr[k] = gen_elem(f, depth, chaos) end
        return arr
    end
    return gen_elem(f, depth, chaos)
end

gen_message = function(desc, depth, chaos)
    local entries = {}
    if depth <= 2 then
        for _, f in ipairs(desc.fields) do
            if math.random() < 0.35 then
                local v = math.random() < 0.1 and NULL
                    or gen_value(f, depth, chaos)
                entries[#entries + 1] = {f.name, v}
            end
        end
    end
    -- shuffle: the key order in the tuple must not matter
    for i = #entries, 2, -1 do
        local j = math.random(i)
        entries[i], entries[j] = entries[j], entries[i]
    end
    if chaos > 0 then
        local r = math.random()
        if r < 0.03 then
            entries[#entries + 1] = {'nope', 1}
        elseif r < 0.06 and #entries > 0 then
            entries[#entries + 1] = entries[1]
        elseif r < 0.08 then
            entries[#entries + 1] = {1, 1}
        elseif r < 0.10 then
            entries[#entries + 1] = {varbinary.new('x'), 1}
        end
    end
    return omap(entries)
end

-- A random row for `conv` (bound to a space with `format`).
local function gen_row(conv, format, chaos)
    local plan = conv.plan
    local values = {}
    for i = 1, plan.n do
        local name = plan.name[i]
        if math.random() < 0.7 then
            local f
            for _, df in ipairs(conv.desc.fields) do
                if df.name == name then f = df end
            end
            local v
            local conv_code = plan.conv[i]
            if conv_code == 'uuid_text' or conv_code == 'uuid_bin' then
                v = math.random() < 0.9 and pick({U, U2}) or pick(ANY)
            elseif plan.repr[i] == 'msg_array' then
                -- positions by field number, some holes, maybe an extra
                local arr = {}
                for pos = 1, math.random(0, 5) do
                    arr[pos] = math.random() < 0.7 and pick(STRINGS)
                        or NULL
                end
                v = arr
            elseif plan.repr[i] == 'raw' then
                v = math.random() < 0.9 and varbinary.new('\x0a\x01z')
                    or pick(ANY)
            else
                v = gen_value(f, 0, chaos)
            end
            values[plan.column_name[i]] = v
        end
    end
    local row = {}
    for i, e in ipairs(format) do
        local v = values[e.name]
        if v == nil then v = NULL end
        row[i] = v
    end
    if row[1] == NULL then row[1] = 1 end
    if math.random() < 0.1 then
        for i = #row, math.random(2, #row), -1 do row[i] = nil end
    end
    return box.tuple.new(row)
end

-- ---------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_tuple.' .. mode)
    local kv = require(mode .. '.kv.kv_pb')

    g.before_each(function()
        skip_if_no_c()
        helper.ensure_box()
    end)

    local function bind(desc, name, format, opts)
        local s = helper.make_space(name, format)
        return pb.tuple.bind(desc, s, opts), s
    end

    g.test_plan_compiles_to_userdata = function()
        local conv = bind(kv.Mixed_descriptor, 'ctup_mixed', MIXED_FORMAT)
        t.assert_equals(type(conv._tplan), 'userdata')
        -- Mixed.child is Mixed again: the plan is cyclic
        t.assert_equals(conv.plan.name[8], 'child')
        t.assert_is(conv.plan.sub[8].sub[8], conv.plan.sub[8])
        t.assert_equals(type(c.tuple_compile(conv.plan, conv.desc)),
                        'userdata')
        t.assert_error_msg_contains('malformed plan', c.tuple_compile, {},
                                    conv.desc)
        -- the plan and the descriptor must describe the same message
        t.assert_error_msg_contains('disagree on a message',
            c.tuple_compile, conv.plan, kv.Record_descriptor)
        local kconv = bind(kv.KeyValue_descriptor, 'ctup_kv', {
            {name = 'key', type = 'varbinary'},
            {name = 'create_revision', type = 'integer'},
            {name = 'mod_revision', type = 'integer'},
            {name = 'version', type = 'integer'},
            {name = 'value', type = 'varbinary'},
            {name = 'lease', type = 'integer'},
        })
        for _, spoil in ipairs({
            function(p) p.kind[2] = 'int128' end,
            function(p) p.repr[1] = 'blob' end,
            function(p) p.layout = 'heap' end,
            function(p) p.name[3] = nil end,
            function(p) p.n = 7 end,
            function(p) p.column[1] = 0 end,
        }) do
            local bad = table.deepcopy(kconv.plan)
            spoil(bad)
            t.assert_error_msg_contains('malformed plan', c.tuple_compile,
                                        bad, kv.KeyValue_descriptor)
        end
    end

    g.test_keyvalue_rows = function()
        local format = {
            {name = 'key',             type = 'varbinary'},
            {name = 'create_revision', type = 'integer'},
            {name = 'mod_revision',    type = 'integer'},
            {name = 'version',         type = 'integer'},
            {name = 'value',           type = 'varbinary', is_nullable = true},
            {name = 'lease_id',        type = 'integer', is_nullable = true},
        }
        local conv, s = bind(kv.KeyValue_descriptor, 'ctup_kv', format,
                             {columns = {lease = 'lease_id'}})
        local rows = {
            {varbinary.new('k1'), 1, 2, 3, varbinary.new('v1'), 7},
            {varbinary.new(''), 0, 0, 0, varbinary.new(''), 0},
            {varbinary.new('k'), 1, 2, 3, NULL, NULL},
            {varbinary.new('k'), 9223372036854775807LL, I64_MIN, -1,
             varbinary.new(LONG), 18446744073709551615ULL},
            {varbinary.new('k'), 1, 2, 3},
            {'k', 1.5, 2, 3},
            {varbinary.new('k'), 1, 2, 3, NULL, 9223372036854775808ULL},
        }
        for k, r in ipairs(rows) do
            check_parity(conv, box.tuple.new(r), 'row ' .. k)
        end
        local tuples = {}
        for k = 1, 3 do
            tuples[k] = s:insert({varbinary.new('k' .. k), k, k, 1,
                                  varbinary.new('v' .. k), 0})
        end
        check_repeated_parity(conv, 2, tuples)
        check_repeated_parity(conv, 536870911, tuples)
        check_repeated_parity(conv, 16, {tuples[1],
            box.tuple.new({varbinary.new(''), 0, 0, 0})})
        check_repeated_parity(conv, 2, {})
        -- a projection with no field at all
        local none = pb.tuple.bind(kv.KeyValue_descriptor, s, {omit = {
            'key', 'create_revision', 'mod_revision', 'version', 'value',
            'lease'}})
        check_parity(none, tuples[1], 'no field')
        check_repeated_parity(none, 3, tuples, 'no field')
        for _, bad in ipairs({0, -1, 1.5, 536870912, 0 / 0, math.huge,
                              'kvs', '2', {}, NULL, true}) do
            check_repeated_parity(conv, bad, tuples, tostring(bad))
        end
        check_repeated_parity(conv, 2, nil)
        check_repeated_parity(conv, 2, 'rows')
        check_repeated_parity(conv, 2, {tuples[1], {}, tuples[2]})
        check_repeated_parity(conv, 2, {tuples[1], tuples[2],
            box.tuple.new({varbinary.new('k'), 'x', 2, 3})})
        -- not a tuple
        for _, bad in ipairs({{}, 'x', 1, NULL, uuid.new()}) do
            check_parity(conv, bad, tostring(bad))
        end
        t.assert_equals(outcome(pcall(c.tuple_encode, conv._tplan)),
                        outcome(pcall(lua.encode, conv, nil)))
    end

    g.test_record_rows = function()
        for _, address_type in ipairs({'map', 'any', 'array', 'varbinary'}) do
            local conv = bind(kv.Record_descriptor, 'ctup_record',
                              record_format(address_type))
            local function row_with(col, v)
                local r = record_row()
                if address_type == 'array' then
                    r[3] = {'Main', 'Town', NULL, 12345}
                elseif address_type == 'varbinary' then
                    r[3] = varbinary.new('\x12\x04Town\x0a\x04Main')
                end
                if col ~= nil then r[col] = v end
                return box.tuple.new(r)
            end
            local cases = {
                {}, {6, ''}, {6, 'nick'}, {3, NULL}, {3, {}},
                {3, omap({{'zip', 1}, {'street', 'S'}})},
                {3, {street = 'Main', bogus = 1}},
                {3, omap({{'city', 'a'}, {'city', 'b'}})},
                {3, omap({{1, 'a'}})},
                {3, {zip = -1}}, {3, {zip = 4294967296}},
                {3, {'Main', 'Town', 'hole', 12345}},
                {3, {'Main', 'Town', NULL, 12345, 'extra'}},
                {3, {'Main'}}, {3, 5}, {3, varbinary.new('')}, {3, 'str'},
                {4, {}}, {4, {{number = '1'}, {number = '1', extra = true}}},
                {4, {NULL}}, {4, {{kind = 2147483648}}}, {4, 'x'},
                {5, omap({{'a', 0}, {'', 5}, {'b', -1}})},
                {5, omap({{'a', NULL}})}, {5, omap({{NULL, 1}})},
                {5, {}}, {5, {1, 2}},
                {7, 2147483648}, {7, -2147483648}, {7, 'x'},
                {8, DTS[3]}, {8, DTS[2]}, {8, DTS[5]}, {8, 1},
                {9, 'text'}, {9, U2}, {10, varbinary.new(string.rep('u', 16))},
                {11, ''}, {11, 'as string'}, {11, 1},
                {12, 0}, {12, -7}, {12, raw('\xcb\x80\x00\x00\x00\x00\x00\x00\x00')},
                {12, 18446744073709551615ULL}, {12, true},
                {12, decimal.new('1.5')}, {12, decimal.new('0')},
                {13, false}, {13, NULL}, {13, 0},
                {14, {text = '', weight = 0}}, {14, {weight = -1}},
                {15, I64_MIN}, {15, 9223372036854775807LL},
                {15, 9223372036854775808ULL}, {15, 0},
                {16, 'unbound column'},
            }
            for k, case in ipairs(cases) do
                check_parity(conv, row_with(case[1], case[2]),
                             address_type .. ' case ' .. k)
            end
            local short = record_row()
            for i = 16, 5, -1 do short[i] = nil end
            check_parity(conv, box.tuple.new(short), 'short tuple')
        end
    end

    g.test_mixed_rows = function()
        local conv = bind(kv.Mixed_descriptor, 'ctup_mixed', MIXED_FORMAT)
        local function row_with(col, v)
            local r = mixed_row()
            if col ~= nil then r[col] = v end
            return box.tuple.new(r)
        end
        local cases = {
            {}, {2, {'a', NULL}}, {2, {}}, {2, {LONG, 'b'}},
            {3, {}}, {3, {2147483647, -2147483648, 0}}, {3, {2147483648}},
            {3, {1, 'x'}}, {3, 5},
            {4, omap({})}, {4, omap({{0, {number = ''}}})},
            {4, omap({{1, NULL}})}, {4, omap({{NULL, {}}})},
            {4, omap({{'1', {}}})}, {4, omap({{9223372036854775808ULL, {}}})},
            {4, omap({{1, {bogus = 1}}})},
            {6, {}}, {6, {DTS[2], DTS[6]}}, {6, {1}}, {6, {NULL}},
            {7, {}}, {7, {-1, 2147483648}}, {7, {0, 0, 0}},
            {8, NULL}, {8, {}}, {8, {code = 1, text = 'x'}},
            {8, {child = {child = {child = {rank = -1}}}}},
            {9, 5}, {9, 0}, {10, NULL}, {10, ''},
        }
        for k, case in ipairs(cases) do
            local r = row_with(case[1], case[2])
            check_parity(conv, r, 'case ' .. k)
        end
        -- both oneof members
        local r = mixed_row()
        r[9] = 5
        check_parity(conv, box.tuple.new(r), 'oneof')
        r[10] = NULL
        check_parity(conv, box.tuple.new(r), 'oneof code')
    end

    g.test_recursion_depth = function()
        local conv = bind(kv.Mixed_descriptor, 'ctup_mixed', MIXED_FORMAT)
        local function nest(levels)
            local v = omap({{'rank', levels}})
            for _ = 2, levels do v = omap({{'child', v}}) end
            return v
        end
        for _, levels in ipairs({1, 99, 100, 101, 150}) do
            local r = mixed_row()
            r[8] = nest(levels)
            local res = check_parity(conv, box.tuple.new(r),
                                     'levels ' .. levels)
            t.assert_equals(res.ok, levels <= 100, 'levels ' .. levels)
        end
        -- nested past the limit through repeated and map values
        local desc = all_desc()
        local format = any_format(desc)
        local aconv = bind(desc, 'ctup_all', format)
        local v = omap({{'i32', 1}})
        for k = 1, 101 do
            if k % 2 == 0 then
                v = omap({{'selves', {v}}})
            else
                v = omap({{'self', v}})
            end
        end
        local res = check_parity(aconv, row_of(format, {self = v}), 'deep')
        t.assert_not(res.ok)
    end

    g.test_all_kinds = function()
        local desc = all_desc()
        local format = any_format(desc)
        local conv = bind(desc, 'ctup_all', format)
        local rows = {
            {},
            {i32 = -1, i64 = I64_MIN, u32 = 4294967295,
             u64 = 18446744073709551615ULL, s32 = -2147483648,
             s64 = I64_MIN, f32 = 4294967295, f64 = 18446744073709551615ULL,
             sf32 = -1, sf64 = I64_MIN, fl = 0.1, db = -2.5, b = true,
             str = 'str', byt = varbinary.new('\0\1'), e = 2},
            {i32 = 0, i64 = 0, u32 = 0, u64 = 0, s32 = 0, s64 = 0, f32 = 0,
             f64 = 0, sf32 = 0, sf64 = 0, fl = 0, db = 0, b = false,
             str = '', byt = '', e = 0},
            {o_i32 = 0, o_db = 0, o_str = '', o_b = false},
            {o_db = raw('\xcb\x80\x00\x00\x00\x00\x00\x00\x00'),
             db = raw('\xcb\x80\x00\x00\x00\x00\x00\x00\x00'),
             fl = raw('\xca\x80\x00\x00\x00')},
            {ts = DTS[3], leaf = {}, r_ts = {DTS[1], DTS[2]},
             r_leaf = {{}, {s = 'x'}, {i = -1}}},
            {r_i32 = {1, -1, 0}, r_s64 = {I64_MIN, 9223372036854775807LL},
             r_f32 = {0, 4294967295}, r_sf64 = {-1}, r_fl = {1.5, 0},
             r_db = {-0.5}, r_b = {true, false}, r_e = {0, 1, -5},
             r_str = {'', 'a'}, r_byt = {varbinary.new('b'), 'c'},
             r_u64 = {0, 18446744073709551615ULL}},
            {m_i32 = omap({{0, ''}, {-1, 'neg'}, {2, ''}}),
             m_u64 = omap({{18446744073709551615ULL, I64_MIN}}),
             m_s32 = omap({{-2147483648, 0}, {1, 1.5}}),
             m_f64 = omap({{0, false}, {1, true}}),
             m_sf32 = omap({{-1, varbinary.new('')}, {0, 'x'}}),
             m_b = omap({{false, 0}, {true, 2}}),
             m_ts = omap({{'', DTS[2]}, {'a', DTS[1]}}),
             m_leaf = omap({{'', {}}, {'k', {s = 'v', i = 3}}}),
             m_i64 = omap({{I64_MIN, raw('\xca\x80\x00\x00\x00')}}),
             m_u32 = omap({{4294967295, -1}}),
             m_fx = omap({{0, 0}, {4294967295, 4294967295}}),
             m_sfx = omap({{I64_MIN, -1}}),
             m_s64 = omap({{-1, 4294967295}})},
            {p_i = 0}, {p_s = ''}, {p_leaf = {}},
            {p_i = 1, p_leaf = {}}, {p_s = 'a', p_leaf = {}},
            {self = {i32 = 1, self = {self = {str = 'deep'}}},
             selves = {{}, {selves = {{b = true}}}}},
            {self = omap({{'pick', 1}})},
            {str = LONG, self = {str = LONG, leaf = {s = LONG}},
             r_str = {LONG, LONG}},
            {far = 1},
            {nothing = setmetatable({}, MAP_MT)}, {nothing = {x = 1}},
            {nothing = {}},
            {fl = 1e-46, db = 1e-320},
        }
        for _, fv in ipairs(FLOATS) do
            rows[#rows + 1] = {fl = fv, db = fv, r_fl = {fv}, r_db = {fv},
                               m_i64 = omap({{1, fv}})}
        end
        for _, iv in ipairs(INTS) do
            for _, name in ipairs({'i32', 'i64', 'u32', 'u64', 's32', 's64',
                                   'f32', 'f64', 'sf32', 'sf64', 'e',
                                   'r_i32', 'r_u64'}) do
                local v = iv
                if name:sub(1, 2) == 'r_' then v = {iv} end
                rows[#rows + 1] = {[name] = v}
            end
            rows[#rows + 1] = {m_i32 = omap({{iv, 'x'}})}
            rows[#rows + 1] = {m_u64 = omap({{iv, iv}})}
            rows[#rows + 1] = {m_s64 = omap({{iv, iv}})}
        end
        for _, av in ipairs(ANY) do
            for _, name in ipairs({'i32', 'fl', 'b', 'str', 'byt', 'ts',
                                   'leaf', 'r_i32', 'r_str', 'r_ts', 'r_leaf',
                                   'm_i32', 'm_ts', 'm_leaf', 'self'}) do
                rows[#rows + 1] = {[name] = av}
            end
            rows[#rows + 1] = {r_i32 = {1, av}}
            rows[#rows + 1] = {r_leaf = {{}, av}}
            rows[#rows + 1] = {m_leaf = omap({{'k', av}})}
            rows[#rows + 1] = {m_b = omap({{av, 1}})}
            rows[#rows + 1] = {leaf = omap({{av, 1}})}
        end
        for k, values in ipairs(rows) do
            check_parity(conv, row_of(format, values), 'row ' .. k)
        end
        -- rows spliced into an enclosing message
        local tuples = {}
        for k = 1, 20 do tuples[k] = row_of(format, rows[k]) end
        check_repeated_parity(conv, 7, tuples)
    end

    g.test_random_rows = function()
        math.randomseed(20260929)
        local desc = all_desc()
        local cases = {
            {desc, 'ctup_all', any_format(desc)},
            {kv.Mixed_descriptor, 'ctup_mixed', MIXED_FORMAT},
            {kv.Record_descriptor, 'ctup_record', record_format()},
            {kv.Record_descriptor, 'ctup_record', record_format('array')},
            {kv.Record_descriptor, 'ctup_record', record_format('varbinary')},
        }
        local ok, failed = 0, 0
        for _, case in ipairs(cases) do
            local conv = bind(case[1], case[2], case[3])
            for k = 1, 600 do
                pace(k)
                local chaos = k % 2 == 0 and 0 or 0.03
                local row = gen_row(conv, case[3], chaos)
                local res = check_parity(conv, row, case[2] .. ' row ' .. k)
                if res.ok then ok = ok + 1 else failed = failed + 1 end
            end
        end
        -- the corpus exercises both outcomes in bulk
        t.assert_gt(ok, 1000)
        t.assert_gt(failed, 300)
    end

    g.test_rebind_recompiles_the_c_plan = function()
        local format = {
            {name = 'key',             type = 'varbinary'},
            {name = 'create_revision', type = 'integer'},
            {name = 'mod_revision',    type = 'integer'},
            {name = 'version',         type = 'integer'},
            {name = 'value',           type = 'varbinary'},
            {name = 'lease_id',        type = 'integer'},
        }
        local conv, s = bind(kv.KeyValue_descriptor, 'ctup_kv', format,
                             {columns = {lease = 'lease_id'}})
        local before = conv._tplan
        local moved = table.deepcopy(format)
        moved[6] = {name = 'extra', type = 'unsigned', is_nullable = true}
        moved[7] = {name = 'lease_id', type = 'integer'}
        s:format(moved)
        local row = box.tuple.new({'k', 0, 0, 0, '', 99, 5})
        t.assert_equals(conv:encode(row),
                        pb.encode(kv.KeyValue_descriptor, {key = 'k',
                                                           lease = 5}))
        t.assert_not_equals(conv._tplan, before)
        check_parity(conv, row)
    end

    -- Errors raised in C carry no file:line prefix, however the C entry
    -- point is called: as the Lua path's error(msg, 0), not luaL_error.
    g.test_errors_carry_no_position = function()
        local conv = bind(kv.Mixed_descriptor, 'ctup_mixed', MIXED_FORMAT)
        local tp = conv._tplan
        local function err_of(fn, ...)
            local args = {...}
            local ok, err = pcall(function()
                local r = fn(unpack(args))   -- not a tail call
                return r
            end)
            t.assert_not(ok)
            return tostring(err)
        end
        local cases = {
            {'pb.tuple: expected a box.tuple, got table',
             c.tuple_encode, tp, {}},
            {'pb.tuple: tuples must be an array of box.tuple, got string',
             c.tuple_encode_repeated, tp, 2, 'rows'},
            {'pb.tuple: expected a box.tuple, got table',
             c.tuple_encode_repeated, tp, 2, {box.tuple.new({}), {}}},
            {"pb.tuple: malformed plan of ?: 'n' is not a number",
             c.tuple_compile, {}, conv.desc},
            {'pb.tuple: cannot compile kv.Mixed for the C decoder: the '
                .. 'plan and the descriptor disagree on a message',
             c.tuple_compile, conv.plan, kv.Record_descriptor},
        }
        for _, case in ipairs(cases) do
            t.assert_equals(err_of(unpack(case, 2)), case[1])
        end
        -- and through the converter methods, as the Lua path words them
        t.assert_equals(err_of(conv.encode, conv, {}),
                        err_of(lua.encode, conv, {}))
        t.assert_equals(err_of(conv.encode_repeated, conv, 2, 'rows'),
                        err_of(lua.encode_repeated, conv, 2, 'rows'))
    end

    -- An extension type Tarantool's Lua msgpack decoder does not know is
    -- skipped where no field reads it (an unbound column, the value of a
    -- key that is about to be refused) and named where one does.
    g.test_unknown_extension_type = function()
        local desc = all_desc()
        local format = any_format(desc)
        local conv = bind(desc, 'ctup_all', format)
        local base = row_of(format, {i32 = 5, leaf = {s = 'x'}})
        for _, ext in ipairs({raw('\xd4\x2a\x00'), raw('\xd4\xff\x00'),
                              raw('\xc7\x03\x2a\x01\x02\x03')}) do
            local res = check_parity(conv, row_of(format, {
                i32 = 5, leaf = {s = 'x'}, unbound = ext}), 'unbound')
            t.assert_equals(res.bytes, hex(lua.encode(conv, base)))
            check_parity(conv, row_of(format, {
                r_leaf = {{s = 'x'}, {i = 1}},
                self = omap({{'i32', 1}, {'unbound_key', {ext}}})}),
                'skipped under a refused key')
            check_parity(conv, row_of(format, {i32 = ext}), 'bound')
            check_parity(conv, row_of(format, {leaf = {s = ext}}), 'nested')
            check_parity(conv, row_of(format, {r_str = {'a', ext}}),
                         'element')
        end
        t.assert_error_msg_equals(
            "pb.tuple: field 'i32' of ck.All (column 'i32'): expected an "
                .. 'integer, got extension type 42',
            c.tuple_encode, conv._tplan,
            row_of(format, {i32 = raw('\xd4\x2a\x00')}))
    end
end

-- ---------------------------------------------------------------------
-- Re-entrancy: an encode can run Lua code (a finalizer, when growing the
-- output buffer lets the GC run) that encodes with the same plan
-- ---------------------------------------------------------------------

local gre = t.group('c_runtime_tuple.reentrancy')

gre.before_each(function()
    skip_if_no_c()
    helper.ensure_box()
end)

gre.test_finalizer_encoding_with_the_same_plan = function()
    local m = pb.parse([[
        syntax = "proto3";
        package reentry;
        message R { string s = 1; int32 i = 2; }
    ]])
    local s = helper.make_space('ctup_reentry', {
        {name = 's', type = 'string'},
        {name = 'i', type = 'integer'},
    })
    local conv = pb.tuple.bind(m.R_descriptor, s)
    local tplan = conv._tplan
    -- The outer row outgrows the 4KB stack buffer many times over, so
    -- the buffer grows (allocates) between reading `s` and reading `i`.
    local outer = box.tuple.new({string.rep('x', 100 * 1024), 123})
    local inner = box.tuple.new({'', 999})
    local bad = box.tuple.new({'', 'not an integer'})
    local want_outer = lua.encode(conv, outer)
    local want_inner = lua.encode(conv, inner)
    local want_rep = lua.encode_repeated(conv, 3, {inner, outer})

    local hits, inner_bad, inner_errors = 0, 0, 0
    local function reenter()
        hits = hits + 1
        if c.tuple_encode(tplan, inner) ~= want_inner then
            inner_bad = inner_bad + 1
        end
        -- an error inside the re-entrant call
        if not pcall(c.tuple_encode, tplan, bad) then
            inner_errors = inner_errors + 1
        end
    end
    -- Finalizable garbage, made in a frame of its own so that no stack
    -- slot of the caller keeps it alive.
    local function plant(n)
        for _ = 1, n do ffi.gc(ffi.new('char[1]'), reenter) end
    end
    -- Make the next allocation run a whole GC cycle, finalizers included:
    -- with the collector stopped nothing is collected while the garbage
    -- is made; `restart` puts the threshold at the current heap size, and
    -- a huge step multiplier lets one step finish the cycle. The next
    -- allocation is the output buffer growing inside the encode, after
    -- the slots of the tuple level are filled and before they are read.
    local function encode_with_gc(fn, ...)
        collectgarbage('collect')
        collectgarbage('stop')
        plant(10)
        collectgarbage('restart')
        return fn(...)
    end
    local stepmul = collectgarbage('setstepmul', 2^30)
    local rows = {inner, outer}
    local ok, err = pcall(function()
        for round = 1, 3 do
            local out = encode_with_gc(c.tuple_encode, tplan, outer)
            t.assert(out == want_outer, 'encode, round ' .. round)
            local rep = encode_with_gc(c.tuple_encode_repeated, tplan, 3,
                                       rows)
            t.assert(rep == want_rep, 'encode_repeated, round ' .. round)
        end
    end)
    collectgarbage('setstepmul', stepmul)
    collectgarbage('restart')
    t.assert(ok, tostring(err))
    t.assert_equals({hits = hits, inner_bad = inner_bad,
                     inner_errors = inner_errors},
                    {hits = 60, inner_bad = 0, inner_errors = 60})

    -- The error path calls the global tostring; re-enter from there, and
    -- raise inside the re-entrant call too.
    local big = box.tuple.new({'', 2^40})
    local want_err = select(2, pcall(lua.encode, conv, big))
    local orig = tostring
    local ok2, err2 = pcall(function()
        rawset(_G, 'tostring', function(v)
            reenter()
            return orig(v)
        end)
        return c.tuple_encode(tplan, big)
    end)
    rawset(_G, 'tostring', orig)
    t.assert_not(ok2)
    t.assert_equals(err2, want_err)
    t.assert_equals({hits = hits, inner_bad = inner_bad,
                     inner_errors = inner_errors},
                    {hits = 61, inner_bad = 0, inner_errors = 61})

    -- an error in an outermost call leaves the plan usable as well
    t.assert_error_msg_contains('expected an integer', c.tuple_encode,
                                tplan, bad)
    t.assert(c.tuple_encode(tplan, outer) == want_outer)
    t.assert(c.tuple_encode_repeated(tplan, 3, rows) == want_rep)
end

-- ---------------------------------------------------------------------
-- IV3: the C path allocates the result string and nothing per row
-- ---------------------------------------------------------------------

local ga = t.group('c_runtime_tuple.alloc')

ga.before_each(function()
    skip_if_no_c()
    helper.ensure_box()
end)

local misc_ok, misc = pcall(require, 'misc')

-- Bytes allocated by the Lua GC while running `fn`.
local function allocated(fn)
    collectgarbage('collect')
    collectgarbage('stop')
    local before, res
    if misc_ok then
        before = misc.getmetrics().gc_allocated
        res = fn()
        local after = misc.getmetrics().gc_allocated
        collectgarbage('restart')
        return after - before, res
    end
    before = collectgarbage('count')
    res = fn()
    local after = collectgarbage('count')
    collectgarbage('restart')
    return (after - before) * 1024, res
end

ga.test_encode_repeated_allocates_the_result = function()
    local kv = require('full.kv.kv_pb')
    local s = helper.make_space('ctup_alloc', MIXED_FORMAT)
    local conv = pb.tuple.bind(kv.Mixed_descriptor, s)
    local rows = {}
    for k = 1, 1000 do
        local r = mixed_row()
        r[1] = 'm' .. k
        rows[k] = s:insert(r)
    end
    local tplan = conv._tplan
    -- warm up both paths (plan aux data, traces)
    c.tuple_encode_repeated(tplan, 2, rows)
    lua.encode_repeated(conv, 2, rows)

    local c_bytes, out = allocated(function()
        return c.tuple_encode_repeated(tplan, 2, rows)
    end)
    local lua_bytes, lua_out = allocated(function()
        return lua.encode_repeated(conv, 2, rows)
    end)
    t.assert_equals(out, lua_out)
    -- The result string, plus the encode buffer's growth: a doubling
    -- series of userdata whose sum is under twice the final capacity,
    -- itself under twice the result.
    t.assert_le(c_bytes, 5 * #out + 8192,
                string.format('C: %d bytes allocated for a %d-byte result',
                              c_bytes, #out))
    -- the Lua path allocates per field and per row
    t.assert_gt(lua_bytes, 10 * c_bytes)

    -- one row at a time: a string per row and nothing else
    local per_row = allocated(function()
        local total = 0
        for k = 1, #rows do
            total = total + #c.tuple_encode(tplan, rows[k])
        end
        return total
    end)
    local total = 0
    for k = 1, #rows do total = total + #c.tuple_encode(tplan, rows[k]) end
    -- a Lua string costs its length plus a header of a few dozen bytes
    t.assert_le(per_row, total + 64 * #rows + 4096)
end

-- =====================================================================
-- Decode: wire -> tuple, through the C decoder (tuple_decode) and the
-- Lua path. The Lua path is the oracle here too.
-- =====================================================================

-- Canonical text of the msgpack value at s[p], and the position past
-- it: every scalar as its own bytes (the integer width, float vs double
-- and str vs bin all count), arrays in order, map entries sorted. The
-- Lua path writes the keys of a map in Lua's hash order, which no other
-- writer reproduces; the entries themselves must agree.
local MP_FIXED = {
    [0xc0] = 1, [0xc2] = 1, [0xc3] = 1, [0xca] = 5, [0xcb] = 9,
    [0xcc] = 2, [0xcd] = 3, [0xce] = 5, [0xcf] = 9,
    [0xd0] = 2, [0xd1] = 3, [0xd2] = 5, [0xd3] = 9,
    [0xd4] = 3, [0xd5] = 4, [0xd6] = 6, [0xd7] = 10, [0xd8] = 18,
}

local function be(s, p, n)
    local v = 0
    for k = 0, n - 1 do v = v * 256 + s:byte(p + k) end
    return v
end

local mp_canon

local function mp_items(s, p, n, is_map)
    local items = {}
    for k = 1, n do
        local key, v
        key, p = mp_canon(s, p)
        if is_map then
            v, p = mp_canon(s, p)
            key = key .. '=' .. v
        end
        items[k] = key
    end
    if is_map then
        table.sort(items)
        return '{' .. table.concat(items, ',') .. '}', p
    end
    return '[' .. table.concat(items, ',') .. ']', p
end

mp_canon = function(s, p)
    local ch = s:byte(p)
    local size
    if ch <= 0x7f or ch >= 0xe0 then
        size = 1
    elseif ch <= 0x8f then
        return mp_items(s, p + 1, ch - 0x80, true)
    elseif ch <= 0x9f then
        return mp_items(s, p + 1, ch - 0x90, false)
    elseif ch <= 0xbf then
        size = 1 + ch - 0xa0
    elseif MP_FIXED[ch] ~= nil then
        size = MP_FIXED[ch]
    elseif ch == 0xc4 or ch == 0xd9 then
        size = 2 + be(s, p + 1, 1)
    elseif ch == 0xc5 or ch == 0xda then
        size = 3 + be(s, p + 1, 2)
    elseif ch == 0xc6 or ch == 0xdb then
        size = 5 + be(s, p + 1, 4)
    elseif ch == 0xc7 then
        size = 3 + be(s, p + 1, 1)
    elseif ch == 0xc8 then
        size = 4 + be(s, p + 1, 2)
    elseif ch == 0xc9 then
        size = 6 + be(s, p + 1, 4)
    elseif ch == 0xdc then
        return mp_items(s, p + 3, be(s, p + 1, 2), false)
    elseif ch == 0xdd then
        return mp_items(s, p + 5, be(s, p + 1, 4), false)
    elseif ch == 0xde then
        return mp_items(s, p + 3, be(s, p + 1, 2), true)
    else
        return mp_items(s, p + 5, be(s, p + 1, 4), true)
    end
    return hex(s:sub(p, p + size - 1)), p + size
end

local function tuple_canon(tuple)
    return (mp_canon(msgpack.encode(tuple), 1))
end

local function decode_outcome(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then return {ok = false, err = tostring(res)} end
    if res == nil then return {ok = true, tuple = 'nil'} end
    return {ok = true, tuple = tuple_canon(res)}
end

local function lua_new(conv, bytes)
    return box.tuple.new(lua.decode(conv, bytes))
end

-- Decode `bytes` through the Lua path, the converter method (C) and the C
-- function; all must agree. The C function returns false exactly where
-- the Lua path raises a conversion error.
local function check_decode(conv, bytes, what)
    local want = decode_outcome(lua_new, conv, bytes)
    t.assert_equals(decode_outcome(conv.decode, conv, bytes), want, what)
    local ok, flag, tuple = pcall(c.tuple_decode, conv._tplan, bytes,
                                  'new', 0)
    if want.ok then
        t.assert(ok and flag == true, what)
        t.assert_equals(tuple_canon(tuple), want.tuple, what)
    elseif ok then
        t.assert_equals(flag, false, what)
    else
        t.assert_equals(tostring(flag), want.err, what)
    end
    return want
end

-- A space with `format` and no index: decode needs only the format.
local function format_space(name, format)
    helper.ensure_box()
    if box.space[name] ~= nil then box.space[name]:drop() end
    return (box.schema.space.create(name, {format = format}))
end

-- -- Wire building -------------------------------------------------------

local wire = pb.wire

local function wvarint(n) return wire.encode_varint(n) end
local function wtag(id, wt) return wvarint(id * 8 + wt) end
local function wlen(id, payload)
    return wtag(id, 2) .. wvarint(#payload) .. payload
end

local function rand_bytes(n)
    local b = {}
    for k = 1, n do b[k] = string.char(math.random(0, 255)) end
    return table.concat(b)
end

local VARINTS = {0, 1, 127, 128, 300, 2147483647, 2147483648, 4294967295,
                 4294967296, -1, -2147483648, 9223372036854775807LL,
                 18446744073709551615ULL, I64_MIN, 1000000000, 1000000001}
local STRING_VALUES = {
    '', 'a', 'Привет', 'h\0i', string.rep('s', 300),
    '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
    'ffffffff-0000-4000-8000-00000000000a',
    '6BA7B810-9DAD-11D1-80B4-00C04FD430C8',
    '6ba7b810-9dad-11d1-80b4-00c04fd430c',
    '6ba7b810x9dad-11d1-80b4-00c04fd430c8',
    string.rep('\x01', 16), string.rep('\x02', 15),
    '\xff', '\xc0\xaf', '\xed\xa0\x80', '\xf4\x90\x80\x80', '\xe2\x82',
}
local VARINT_KINDS = {int32 = true, int64 = true, uint32 = true,
                      uint64 = true, sint32 = true, sint64 = true,
                      bool = true}
local I32_KINDS = {fixed32 = true, sfixed32 = true, float = true}
local I32_VALUES = {'\0\0\0\0', '\0\0\128\127', '\0\0\128\255',
                    '\1\0\192\127', '\0\0\0\128', '\255\255\255\255',
                    '\0\0\192\63'}
local I64_VALUES = {'\0\0\0\0\0\0\0\0', '\0\0\0\0\0\0\240\127',
                    '\0\0\0\0\0\0\240\255', '\1\0\0\0\0\0\248\127',
                    '\0\0\0\0\0\0\0\128', '\255\255\255\255\255\255\255\255',
                    '\0\0\0\0\0\0\248\63'}

-- Wire type and value bytes of a random value of scalar/enum field `f`.
local function rand_value(kind)
    if kind == 'enum' or VARINT_KINDS[kind] then
        return 0, wvarint(pick(VARINTS))
    elseif I32_KINDS[kind] then
        return 5, math.random() < 0.3 and rand_bytes(4) or pick(I32_VALUES)
    elseif kind == 'fixed64' or kind == 'sfixed64' or kind == 'double' then
        return 1, math.random() < 0.3 and rand_bytes(8) or pick(I64_VALUES)
    end
    local s = math.random() < 0.1 and rand_bytes(math.random(0, 20))
        or pick(STRING_VALUES)
    return 2, wvarint(#s) .. s
end

local function field_kind(f)
    if f.kind == 'scalar' then return f.proto_type end
    return f.kind
end

local function payload_for(wt)
    if wt == 0 then return wvarint(pick(VARINTS)) end
    if wt == 1 then return rand_bytes(8) end
    if wt == 5 then return rand_bytes(4) end
    local s = rand_bytes(math.random(0, 6))
    return wvarint(#s) .. s
end

local TS_SECS = {0, 1, -1, 1700000000, -62135596800, 253402300799,
                 185480451417600, 185480451417601, -185604722870400,
                 -185604722870401, 4611686018427387904LL}
local TS_NANOS = {0, 1, 999999999, 1000000000, 1000000001, -1}

local gen_wire

-- Wire bytes of one occurrence of field `f` (tag included).
local function gen_field(f, depth)
    local kind = field_kind(f)
    if kind == 'map' then
        local entry = {}
        if math.random() < 0.9 then
            local wt, v = rand_value(field_kind(f.key))
            entry[#entry + 1] = wtag(1, wt) .. v
        end
        if math.random() < 0.9 then
            local vk = field_kind(f.value)
            if vk == 'message' then
                entry[#entry + 1] = wlen(2, gen_wire(f.value.message,
                                                     depth + 1))
            else
                local wt, v = rand_value(vk)
                entry[#entry + 1] = wtag(2, wt) .. v
            end
        end
        if math.random() < 0.1 then entry[#entry + 1] = wtag(3, 0) .. '\1' end
        return wlen(f.id, table.concat(entry))
    elseif kind == 'message' then
        return wlen(f.id, gen_wire(f.message, depth + 1))
    elseif kind == 'group' then
        return wtag(f.id, 3) .. gen_wire(f.message, depth + 1)
            .. wtag(f.id, 4)
    end
    if f.repeated and kind ~= 'string' and kind ~= 'bytes'
            and math.random() < 0.5 then
        local parts = {}
        for k = 1, math.random(0, 4) do
            local _, v = rand_value(kind)
            parts[k] = v
        end
        return wlen(f.id, table.concat(parts))
    end
    local wt, v = rand_value(kind)
    if math.random() < 0.05 then wt = pick({0, 1, 2, 3, 4, 5}) end
    return wtag(f.id, wt) .. v
end

-- Random wire bytes of a message `desc`: its fields in random order,
-- some given twice, some unknown ones.
gen_wire = function(desc, depth)
    if desc.decode ~= nil then
        if desc.name == TIMESTAMP then
            local parts = {}
            if math.random() < 0.8 then
                parts[#parts + 1] = wtag(1, 0) .. wvarint(pick(TS_SECS))
            end
            if math.random() < 0.6 then
                parts[#parts + 1] = wtag(2, 0) .. wvarint(pick(TS_NANOS))
            end
            return table.concat(parts)
        end
        return pick({'', '', '', '\8\1', '\255', '\10\1a'})
    end
    if depth > 3 then return '' end
    local fields = desc.fields
    local parts = {}
    for _ = 1, math.random(0, 7) do
        if #fields == 0 or math.random() < 0.08 then
            local wt = pick({0, 1, 2, 5})
            parts[#parts + 1] = wtag(math.random(2000, 3000), wt)
                .. payload_for(wt)
        else
            parts[#parts + 1] = gen_field(pick(fields), depth)
        end
    end
    return table.concat(parts)
end

-- The bytes with one random defect.
local function mangle(bytes)
    local r = math.random(1, 6)
    local n = #bytes
    if r == 1 and n > 0 then
        return bytes:sub(1, math.random(0, n - 1))
    elseif r == 2 and n > 0 then
        local k = math.random(1, n)
        return bytes:sub(1, k - 1) .. string.char(math.random(0, 255))
            .. bytes:sub(k + 1)
    elseif r == 3 then
        local k = math.random(0, n)
        return bytes:sub(1, k) .. string.char(math.random(0, 255))
            .. bytes:sub(k + 1)
    elseif r == 4 then
        return bytes .. pick({'\0', '\14', '\15', '\12', '\11', '\136\0',
                              '\255\255\255\255\255\255\255\255\255\255\1',
                              '\10\5ab', '\128\128\128\128\16'})
    elseif r == 5 then
        return pick({'\11', '\12', '\3\4'}) .. bytes
    end
    return bytes .. bytes
end

-- Bind `desc` with every field it can bind in a column of its own,
-- omitting the fields that have no tuple representation.
local function bind_what_binds(desc, name)
    local function column(f)
        local raw = f.kind == 'message' and f.message.decode ~= nil
            and f.message.name ~= TIMESTAMP and not f.repeated
        return {name = f.name, type = raw and 'varbinary' or 'any',
                is_nullable = true}
    end
    -- Probe each field on its own: a message field can fail deep down.
    local keep = {}
    for _, f in ipairs(desc.fields) do
        local omit = {}
        for _, o in ipairs(desc.fields) do
            if o ~= f then omit[#omit + 1] = o.name end
        end
        local s = format_space(name, {column(f)})
        if pcall(pb.tuple.bind, desc, s, {omit = omit}) then
            keep[f.name] = true
        end
    end
    local format, omit = {}, {}
    for _, f in ipairs(desc.fields) do
        if keep[f.name] then
            format[#format + 1] = column(f)
        else
            omit[#omit + 1] = f.name
        end
    end
    local s = format_space(name, format)
    return pb.tuple.bind(desc, s, {omit = omit}), s
end

local function sorted_fields(desc)
    local list = {}
    for _, f in ipairs(desc.fields) do list[#list + 1] = f end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local KV_DECODE_FORMAT = {
    {name = 'key',             type = 'varbinary'},
    {name = 'create_revision', type = 'integer'},
    {name = 'mod_revision',    type = 'integer'},
    {name = 'version',         type = 'integer'},
    {name = 'value',           type = 'varbinary'},
    {name = 'lease_id',        type = 'integer'},
}

-- The conversions the decode corpus runs through: {name, conv, desc}.
local function decode_convs(mode)
    local kv = require(mode .. '.kv.kv_pb')
    local p3 = require(mode .. '.protobuf_test_messages.proto3'
                       .. '.test_messages_proto3_pb')
    local p2 = require(mode .. '.protobuf_test_messages.proto2'
                       .. '.test_messages_proto2_pb')
    local list = {}
    local function add(name, desc, format, opts)
        local s = format_space('ctd_' .. name, format)
        list[#list + 1] = {name = name, desc = desc,
                           conv = pb.tuple.bind(desc, s, opts)}
    end
    local desc = all_desc()
    local all_format = {}
    for _, f in ipairs(sorted_fields(desc)) do
        all_format[#all_format + 1] = {name = f.name, type = 'any',
                                       is_nullable = true}
    end
    add('all', desc, all_format)
    add('mixed', kv.Mixed_descriptor, MIXED_FORMAT)
    add('record', kv.Record_descriptor, record_format())
    add('record_array', kv.Record_descriptor, record_format('array'))
    add('record_raw', kv.Record_descriptor, record_format('varbinary'))
    add('kv', kv.KeyValue_descriptor, KV_DECODE_FORMAT,
        {columns = {lease = 'lease_id'}})
    for _, d in ipairs({p3.TestAllTypesProto3_descriptor,
                        p2.TestAllTypesProto2_descriptor}) do
        local name = d == p3.TestAllTypesProto3_descriptor and 'p3' or 'p2'
        list[#list + 1] = {name = name, desc = d,
                           conv = (bind_what_binds(d, 'ctd_' .. name))}
    end
    return list
end

for _, mode in ipairs({'full', 'runtime'}) do
    local gd = t.group('c_runtime_tuple.decode.' .. mode)
    local kv = require(mode .. '.kv.kv_pb')

    gd.before_each(function()
        skip_if_no_c()
        helper.ensure_box()
    end)

    gd.test_random_wire = function()
        math.randomseed(20260930)
        local count = {ok = 0, err = 0}
        for _, cv in ipairs(decode_convs(mode)) do
            for k = 1, 400 do
                pace(k)
                local bytes = gen_wire(cv.desc, 0)
                if k % 3 == 0 then bytes = mangle(bytes) end
                local res = check_decode(cv.conv, bytes, string.format(
                    '%s #%d %s', cv.name, k, hex(bytes)))
                count[res.ok and 'ok' or 'err'] =
                    count[res.ok and 'ok' or 'err'] + 1
            end
        end
        -- both outcomes in bulk
        t.assert_gt(count.ok, 1000)
        t.assert_gt(count.err, 600)
    end

    gd.test_encoded_rows = function()
        math.randomseed(20261001)
        local convs = {}
        for _, cv in ipairs(decode_convs(mode)) do convs[cv.name] = cv end
        local desc = all_desc()
        local cases = {
            {desc, 'ctup_all', any_format(desc), 'all'},
            {kv.Mixed_descriptor, 'ctup_mixed', MIXED_FORMAT, 'mixed'},
            {kv.Record_descriptor, 'ctup_record', record_format(), 'record'},
        }
        local decoded = 0
        for _, case in ipairs(cases) do
            local s = helper.make_space(case[2], case[3])
            local econv = pb.tuple.bind(case[1], s)
            local dconv = convs[case[4]].conv
            for k = 1, 300 do
                pace(k)
                local row = gen_row(econv, case[3], k % 2 == 0 and 0 or 0.02)
                local ok, bytes = pcall(lua.encode, econv, row)
                if ok then
                    local res = check_decode(dconv, bytes, case[4] .. ' #' .. k)
                    if res.ok then decoded = decoded + 1 end
                    -- every prefix of a short one
                    if #bytes < 60 then
                        for n = 0, #bytes - 1 do
                            check_decode(dconv, bytes:sub(1, n),
                                         case[4] .. ' prefix ' .. n)
                        end
                    end
                end
            end
        end
        t.assert_gt(decoded, 150)
    end

    gd.test_targeted_wire = function()
        local convs = {}
        for _, cv in ipairs(decode_convs(mode)) do convs[cv.name] = cv end
        local all = convs.all.conv
        local function msg(...) return table.concat({...}) end
        local leaf_s = wlen(1, 'a')
        local cases = {
            -- tags
            '\0', '\8', '\14\1', '\15\1', '\12', '\11', '\136\0\1',
            '\248\255\255\255\31\1', '\248\255\255\255\15\1',
            '\128\128\128\128\128\128\128\128\128\128\1',
            '\8\255\255\255\255\255\255\255\255\255\1',
            '\8\255\255\255\255\255\255\255\255\255\127',
            '\8\255\255\255\255\255\255\255\255\255\255\1',
            -- LEN past the end, inside and outside a message
            '\114\5ab', '\178\1\2\10\5a',
            -- unknown groups: nested, mismatched, unterminated, too deep
            wtag(2000, 3) .. wtag(2001, 0) .. '\1' .. wtag(2000, 4),
            wtag(2000, 3) .. wtag(2001, 4),
            wtag(2000, 3) .. wtag(2001, 0) .. '\1',
            string.rep(wtag(2000, 3), 100) .. string.rep(wtag(2000, 4), 100),
            string.rep(wtag(2000, 3), 101) .. string.rep(wtag(2000, 4), 101),
            -- wrong wire types for known fields
            wtag(1, 2) .. '\2\8\7', wtag(14, 0) .. '\5', wtag(22, 0) .. '\1',
            wtag(12, 5) .. '\0\0\0\0\0\0\0\0', wtag(1, 3) .. '\1',
            wtag(23, 1) .. '\1\2\3\4\5\6\7\8',
            -- invalid UTF-8 in a string, a map key, a nested string
            wlen(14, '\xff'), wlen(36, msg(wtag(1, 0), '\1', wlen(2, '\xc0'))),
            wlen(43, msg(wlen(1, '\xed\xa0\x80'))),
            wlen(22, wlen(1, '\xf4\x90\x80\x80')),
            -- map entries: missing key / value, duplicates, extra fields
            wlen(36, ''), wlen(36, wtag(1, 0) .. '\5'),
            wlen(36, wlen(2, 'x')) .. wlen(36, wlen(2, 'y')),
            wlen(36, msg(wtag(1, 0), '\1', wlen(2, 'a'))) ..
                wlen(36, msg(wtag(1, 0), '\1', wlen(2, 'b'))),
            wlen(42, wlen(1, 'k')), wlen(43, wlen(1, 'k')),
            wlen(42, msg(wlen(1, 'k'), wlen(2, wtag(2, 0) .. '\255\147\235\220\3'))),
            wlen(42, msg(wlen(1, 'k'), wlen(2, wtag(2, 0) .. '\128\148\235\220\3'))),
            -- Timestamps at and past the datetime range
            wlen(21, wtag(1, 0) .. wvarint(185480451417600)),
            wlen(21, wtag(1, 0) .. wvarint(185480451417601)),
            wlen(21, wtag(1, 0) .. wvarint(-185604722870400)),
            wlen(21, wtag(1, 0) .. wvarint(-185604722870401)),
            wlen(21, wtag(2, 0) .. wvarint(-1)),
            wlen(21, wtag(2, 0) .. wvarint(1000000000)),
            wlen(21, msg(wtag(2, 0), wvarint(5), wtag(2, 0), wvarint(0))),
            wlen(21, wtag(1, 0) .. '\1') .. wlen(21, wtag(2, 0) .. '\1'),
            wlen(34, '') .. wlen(34, wtag(1, 1) .. '\1\2\3\4\5\6\7\8'),
            -- packed and unpacked, mixed
            wlen(23, '\1\2\255\255\255\255\15') .. wtag(23, 0) .. '\3',
            wlen(30, '\1\2') .. wtag(30, 0) .. '\255\255\255\255\255\255\255\255\255\1',
            wlen(27, '\0\0\128\127\1\0\192\127') .. wtag(27, 5) .. '\0\0\0\128',
            wlen(28, '\0\0\0\0\0\0\0\128') .. wlen(28, '\1\0\0'),
            -- oneof: last member wins, members merge, siblings unset
            wtag(50, 0) .. '\1' .. wlen(51, 'x'),
            wlen(52, leaf_s) .. wtag(50, 0) .. '\1' .. wlen(52, wtag(2, 0) .. '\2'),
            wlen(52, leaf_s) .. wlen(52, wtag(2, 0) .. '\2'),
            -- a message given twice merges field by field; a oneof member
            -- inside it that comes back after a sibling is merged with
            -- the earlier occurrence's value (codec merge, not the
            -- concatenation of the two payloads)
            wlen(60, wlen(52, leaf_s)) ..
                wlen(60, msg(wlen(52, wtag(2, 0) .. '\1'), wlen(51, 'x'),
                             wlen(52, wtag(2, 0) .. '\2'))),
            wlen(60, wlen(21, wtag(1, 0) .. '\5')) ..
                wlen(60, wlen(21, wtag(2, 0) .. '\7')),
            -- int64-keyed maps merged keep both entries of a key
            wlen(60, wlen(37, msg(wtag(1, 0), '\5', wtag(2, 0), '\1'))) ..
                wlen(60, wlen(37, msg(wtag(1, 0), '\5', wtag(2, 0), '\2'))),
            wlen(60, wlen(36, msg(wtag(1, 0), '\5', wlen(2, 'a')))) ..
                wlen(60, wlen(36, msg(wtag(1, 0), '\5', wlen(2, 'b')))),
            wlen(60, wlen(47, msg(wtag(1, 1), '\5\0\0\0\0\0\0\0'))) ..
                wlen(60, wlen(47, msg(wtag(1, 1), '\5\0\0\0\0\0\0\0'))),
            -- repeated messages and their merges
            wlen(61, wtag(1, 0) .. '\1') .. wlen(61, wtag(1, 0) .. '\2'),
            wlen(60, wlen(61, leaf_s)) .. wlen(60, wlen(61, leaf_s)),
            -- floats: NaN payloads, infinities, -0
            wtag(11, 5) .. '\1\0\192\127' .. wtag(12, 1) .. '\1\0\0\0\0\0\248\255',
            wtag(11, 5) .. '\0\0\128\255' .. wtag(12, 1) .. '\0\0\0\0\0\0\240\127',
            wtag(11, 5) .. '\0\0\0\128' .. wtag(12, 1) .. '\0\0\0\0\0\0\0\128',
            wtag(18, 1) .. '\0\0\0\0\0\0\0\128',
            -- presence: optional fields set to their defaults
            msg(wtag(17, 0), '\0', wtag(18, 1), '\0\0\0\0\0\0\0\0',
                wlen(19, ''), wtag(20, 0), '\0'),
            -- field numbers far apart, unknown fields of every type
            wtag(1000, 0) .. '\1' .. wtag(2000, 1) .. '12345678'
                .. wtag(2001, 5) .. '1234' .. wlen(2002, 'xyz'),
        }
        -- Maps with 64-bit keys, merged. The codec keys a map with the
        -- key it decodes: a key given on the wire is a fresh int64/uint64
        -- cdata (a key of its own in a Lua table, whatever its value), a
        -- key missing from its entry is the number 0 (the same key in
        -- every entry that omits it). Within one message the entries are
        -- deduplicated by value, across merged messages by that identity.
        local KEY64 = {
            -- field, key tag and zero/five bytes, value tag and two values
            {37, wtag(1, 0), '\0', '\5', wtag(2, 0), '\1', '\2'},
            {44, wtag(1, 0), '\0', '\5', wtag(2, 5), '\0\0\128\63',
             '\0\0\0\64'},
            {39, wtag(1, 1), '\0\0\0\0\0\0\0\0', '\5\0\0\0\0\0\0\0',
             wtag(2, 0), '\1', '\0'},
            {47, wtag(1, 1), '\0\0\0\0\0\0\0\0', '\5\0\0\0\0\0\0\0',
             wtag(2, 1), '\1\0\0\0\0\0\0\0', '\2\0\0\0\0\0\0\0'},
            {48, wtag(1, 0), '\0', '\10', wtag(2, 0), '\1', '\2'},
        }
        for _, k in ipairs(KEY64) do
            local function entry(key, v)
                return wlen(k[1], (key ~= nil and k[2] .. key or '')
                            .. k[5] .. v)
            end
            local omit1, omit2 = entry(nil, k[6]), entry(nil, k[7])
            local zero1, five1 = entry(k[3], k[6]), entry(k[4], k[6])
            local zero2 = entry(k[3], k[7])
            for _, occurrences in ipairs({
                {omit1, omit2}, {omit1, zero2}, {zero1, omit2},
                {zero1, zero2}, {omit1 .. zero2, omit1}, {zero1 .. omit2, zero1},
                {omit1, omit2, omit1}, {five1, omit1}, {omit1, five1},
                {omit1 .. omit2}, {zero1 .. omit2}, {omit1 .. zero2},
            }) do
                local b = {}
                for n, o in ipairs(occurrences) do b[n] = wlen(60, o) end
                cases[#cases + 1] = table.concat(b)
                cases[#cases + 1] = occurrences[1]
            end
        end
        -- nesting at and past the recursion limit
        for _, levels in ipairs({99, 100, 101}) do
            local b = wtag(1, 0) .. '\1'
            for _ = 1, levels do b = wlen(60, b) end
            cases[#cases + 1] = b
        end
        for k, bytes in ipairs(cases) do
            check_decode(all, bytes, 'all #' .. k .. ' ' .. hex(bytes))
        end
        -- typed columns: uuid text and bytes, unsigned, double, datetime
        local rec = convs.record.conv
        local rcases = {
            wlen(9, '6ba7b810-9dad-11d1-80b4-00c04fd430c8'),
            wlen(9, '6BA7B810-9DAD-11D1-80B4-00C04FD430C8'),
            wlen(9, '6ba7b810-9dad-11d1-80b4-00c04fd430c8 '),
            wlen(9, '6ba7b8109dad11d180b400c04fd430c8'),
            wlen(9, '6ba7b810-9dad-11d1-80b4-00c04fd430cg'),
            wlen(9, '6ba7b810-9dad-11d1-80b4-00c04fd430c\0'),
            wlen(9, ''), wlen(10, ''), wlen(10, string.rep('\1', 16)),
            wlen(10, string.rep('\1', 17)), wlen(10, string.rep('\1', 15)),
            wtag(1, 0) .. wvarint(18446744073709551615ULL),
            wtag(7, 0) .. wvarint(-1), wtag(7, 0) .. wvarint(2147483647),
            wtag(100, 0) .. wvarint(18446744073709551615ULL),
            wtag(12, 1) .. '\0\0\0\0\0\0\0\64', wtag(12, 1) .. '\0\0\0\0\0\0\248\63',
            wlen(8, ''), wlen(8, wtag(2, 0) .. '\1'),
            wlen(3, msg(wlen(1, 'x'), wtag(4, 0), wvarint(-1))),
            wlen(11, 'raw bytes') .. wlen(11, 'more'),
        }
        for k, bytes in ipairs(rcases) do
            check_decode(rec, bytes, 'record #' .. k .. ' ' .. hex(bytes))
            check_decode(convs.record_array.conv, bytes, 'array #' .. k)
            check_decode(convs.record_raw.conv, bytes, 'raw #' .. k)
        end
        -- proto2: an extension, groups, MessageSet items
        local function group(id, body)
            return wtag(id, 3) .. body .. wtag(id, 4)
        end
        local function item(type_id, payload)
            return group(1, wtag(2, 0) .. wvarint(type_id) .. wlen(3, payload))
        end
        local p2cases = {
            wtag(120, 0) .. '\5', wtag(120, 2) .. '\1\5', wtag(120, 0),
            group(201, wtag(202, 0) .. '\1'),
            wtag(201, 3) .. wtag(202, 0) .. '\1' .. wtag(202, 4),
            wtag(201, 3) .. wtag(202, 0) .. '\1',
            group(201, wlen(202, 'x')),
            wlen(500, item(4135312, wtag(9, 0) .. '\7')),
            wlen(500, item(4135312, wtag(9, 0))),
            wlen(500, item(1547769, wlen(25, '\xff'))),
            wlen(500, item(1547769, wlen(25, 'ok'))),
            wlen(500, item(999, 'junk')),
            wlen(500, group(1, wtag(2, 0) .. '\1')),
            wlen(500, wtag(1, 3) .. wtag(2, 4)),
            wlen(500, wtag(1, 3) .. wtag(2, 0) .. '\1'),
        }
        for k, bytes in ipairs(p2cases) do
            check_decode(convs.p2.conv, bytes, 'p2 #' .. k .. ' ' .. hex(bytes))
        end
        -- a message given twice whose map entries omit their int64 key
        local nm = pb.parse([[
            syntax = "proto3";
            package decode_map_merge;
            message N { map<int64, int32> m = 1; }
            message R { N n = 1; }
        ]])
        local nconv = pb.tuple.bind(nm.R_descriptor, format_space('ctd_nm', {
            {name = 'n', type = 'map', is_nullable = true},
        }))
        local function unhex(h)
            return (h:gsub('%x%x', function(x)
                return string.char(tonumber(x, 16))
            end))
        end
        for _, h in ipairs({'0a040a0210010a040a021002',
                            '0a060a0408001001' .. '0a040a021002',
                            '0a040a021001' .. '0a060a0408001002'}) do
            check_decode(nconv, unhex(h), 'map merge ' .. h)
        end
        -- the same through Mixed.child (random wire, seed 987654321,
        -- 12000 iterations, mixed #2565)
        local child = '5e288194ebdc034800122336626137623831302d396461642d3131'
            .. '64312d383062342d303063303466643433306322251223a99601b62afa'
            .. '087caa22bc0a036800690a000a0f020202020202020202020202020202'
            .. '28ffffffffffffffff7f32080880e2cfaa061001aab70102ac624274cd'
            .. '920153456630226b088194ebdc03126310ffffffff0f0a243662613762'
            .. '3831302d396461642d313164312d383062342d30306330346664343330'
            .. '6338108094ebdc0312808080808080808080010a0f0202020202020202'
            .. '0202020202020210ac020a1001010101010101010101010101010101'
        check_decode(convs.mixed.conv, unhex('42' .. child .. '42' .. child),
                     'mixed #2565')
        -- a raw member of a oneof, its sibling bound or not
        local om = pb.parse([[
            syntax = "proto3";
            package decode_oneof_raw;
            message C { int32 x = 1; }
            message M { oneof pick { C a = 1; int32 b = 2; } uint64 id = 3; }
        ]])
        local both = pb.tuple.bind(om.M_descriptor, format_space('ctd_oo1', {
            {name = 'id', type = 'unsigned'},
            {name = 'a', type = 'varbinary', is_nullable = true},
            {name = 'b', type = 'integer', is_nullable = true},
        }))
        local only_a = pb.tuple.bind(om.M_descriptor, format_space('ctd_oo2', {
            {name = 'id', type = 'unsigned'},
            {name = 'a', type = 'varbinary', is_nullable = true},
        }), {omit = {'b'}})
        local a1, a2 = wlen(1, '\8\7'), wlen(1, '\8\1')
        local b1 = wtag(2, 0) .. '\9'
        for k, bytes in ipairs({
            a1 .. b1, b1 .. a1, a1 .. b1 .. wlen(1, ''), a1 .. a2,
            a1 .. b1 .. a2 .. b1, b1 .. a1 .. b1 .. a2, a1 .. a2 .. b1 .. a1,
            wtag(1, 0) .. '\1' .. b1, a1 .. wtag(1, 0) .. '\1',
        }) do
            check_decode(both, bytes, 'oneof raw #' .. k)
            check_decode(only_a, bytes, 'oneof raw, b omitted #' .. k)
        end
        -- an unbound non-nullable column
        local s = format_space('ctd_unbound', {
            {name = 'key', type = 'varbinary'},
            {name = 'extra', type = 'unsigned'},
        })
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {omit = {'create_revision', 'mod_revision',
                                            'version', 'value', 'lease'}})
        check_decode(conv, '', 'unbound')
        check_decode(conv, nil, 'not a string')
        check_decode(all, {}, 'not a string')
    end

    gd.test_insert_and_replace = function()
        local s = helper.make_space('ctd_kv_space', KV_DECODE_FORMAT)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        local function lua_op(op, bytes)
            return box.space[s.id][op](box.space[s.id],
                                       lua.decode(conv, bytes))
        end
        local function outcome(ok, res)
            if not ok then
                local e = {ok = false, err = tostring(res)}
                if type(res) == 'cdata' then
                    e.type, e.code = res.type, res.code
                end
                return e
            end
            return {ok = true, tuple = res == nil and 'nil'
                    or tuple_canon(res)}
        end
        for k = 1, 30 do
            local bytes = pb.encode(kv.KeyValue_descriptor, {
                key = 'k' .. (k % 7), version = k, lease = -k,
                value = string.rep('v', k)})
            for _, op in ipairs({'replace', 'insert'}) do
                s:truncate()
                if op == 'insert' and k % 2 == 0 then
                    -- a duplicate key: the same box error both ways
                    s:insert(lua.decode(conv, bytes))
                end
                local want = outcome(pcall(lua_op, op, bytes))
                local rows_lua = s:select()
                s:truncate()
                if op == 'insert' and k % 2 == 0 then
                    s:insert(lua.decode(conv, bytes))
                end
                local got = outcome(pcall(conv[op], conv, bytes))
                t.assert_equals(got, want, op .. ' #' .. k)
                t.assert_equals(s:select(), rows_lua, op .. ' #' .. k)
            end
        end
        -- a conversion error does not reach the space
        t.assert_error_msg_contains('truncated', conv.insert, conv, '\10\5a')
    end

    gd.test_region_is_restored = function()
        local ffi_ok = pcall(ffi.cdef, 'size_t box_region_used(void);')
        t.assert(ffi_ok or pcall(function() return ffi.C.box_region_used end))
        local function used() return tonumber(ffi.C.box_region_used()) end
        local s = helper.make_space('ctd_kv_space', KV_DECODE_FORMAT)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        local good = pb.encode(kv.KeyValue_descriptor, {key = 'k',
                                                        value = 'v'})
        local rconv = pb.tuple.bind(kv.Record_descriptor,
                                    format_space('ctd_region', record_format()))
        local steps = {
            {'new', function() return conv:decode(good) end},
            {'replace', function() return conv:replace(good) end},
            {'duplicate insert', function() return conv:insert(good) end},
            {'wire error', function() return conv:decode('\10\5a') end},
            {'wire error in C', function()
                return c.tuple_decode(conv._tplan, '\10\5a', 'new', 0)
            end},
            {'layout error', function()
                return rconv:decode(wlen(9, 'not a uuid'))
            end},
            {'layout error in C', function()
                return c.tuple_decode(rconv._tplan, wlen(9, 'x'), 'new', 0)
            end},
            {'bad utf-8 deep inside', function()
                return rconv:decode(wlen(4, wlen(1, '\xff')))
            end},
        }
        for _, step in ipairs(steps) do
            local before = used()
            pcall(step[2])
            t.assert_equals(used(), before, step[1])
        end
    end

    gd.test_reentrant_decode = function()
        local m = pb.parse([[
            syntax = "proto3";
            package reentry_decode;
            import "google/protobuf/duration.proto";
            message R {
                google.protobuf.Duration d = 1;
                string s = 2;
                int32 i = 3;
            }
        ]])
        local s = format_space('ctd_reentry', {
            {name = 'd', type = 'varbinary', is_nullable = true},
            {name = 's', type = 'string'},
            {name = 'i', type = 'integer'},
        })
        local conv = pb.tuple.bind(m.R_descriptor, s)
        local tplan = conv._tplan
        local ffi_ok = pcall(ffi.cdef, 'size_t box_region_used(void);')
        t.assert(ffi_ok or true)
        -- the Duration is checked through its Lua decode before s and i
        -- are read: that call allocates, and can run finalizers
        local outer = wlen(1, wtag(1, 0) .. '\7') .. wlen(2, 'outer')
            .. wtag(3, 0) .. '\123'
        local inner = wlen(2, 'inner') .. wtag(3, 0) .. '\99'
        local bad = wlen(2, '\xff')
        local want_outer = tuple_canon(lua_new(conv, outer))
        local want_inner = tuple_canon(lua_new(conv, inner))
        local hits, inner_bad, refused = 0, 0, 0
        local function reenter()
            hits = hits + 1
            local ok, tuple = c.tuple_decode(tplan, inner, 'new', 0)
            if not ok or tuple_canon(tuple) ~= want_inner then
                inner_bad = inner_bad + 1
            end
            if not c.tuple_decode(tplan, bad, 'new', 0) then
                refused = refused + 1
            end
            -- and an error raised inside the re-entrant call
            pcall(conv.decode, conv, bad)
        end
        local function plant(n)
            for _ = 1, n do ffi.gc(ffi.new('char[1]'), reenter) end
        end
        local stepmul = collectgarbage('setstepmul', 2^30)
        local region_before = tonumber(ffi.C.box_region_used())
        local ok, err = pcall(function()
            for round = 1, 3 do
                collectgarbage('collect')
                collectgarbage('stop')
                plant(10)
                collectgarbage('restart')
                local done, tuple = c.tuple_decode(tplan, outer, 'new', 0)
                t.assert(done, 'round ' .. round)
                t.assert_equals(tuple_canon(tuple), want_outer,
                                'round ' .. round)
            end
        end)
        collectgarbage('setstepmul', stepmul)
        collectgarbage('restart')
        t.assert(ok, tostring(err))
        t.assert_equals({hits = hits, inner_bad = inner_bad,
                         refused = refused},
                        {hits = 30, inner_bad = 0, refused = 30})
        t.assert_equals(tonumber(ffi.C.box_region_used()), region_before)
    end
end

-- IV3 for decode: no Lua value per field or per row, only the tuple.
ga.test_decode_allocates_the_tuple = function()
    local kv = require('full.kv.kv_pb')
    local s = format_space('ctd_alloc', KV_DECODE_FORMAT)
    local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                               {columns = {lease = 'lease_id'}})
    local wires = {}
    for k = 1, 1000 do
        wires[k] = pb.encode(kv.KeyValue_descriptor, {
            key = 'key-' .. k, create_revision = k, mod_revision = k + 1,
            version = 3, value = string.rep('v', 40), lease = k * 7})
    end
    local tplan = conv._tplan
    local decode = c.tuple_decode
    -- keep the tuples, so the GC frees nothing mid-measure
    local keep = {}
    for k = 1, #wires do keep[k] = false end
    for k = 1, #wires do select(2, decode(tplan, wires[k], 'new', 0)) end
    for k = 1, #wires do lua.decode(conv, wires[k]) end
    local c_bytes = allocated(function()
        for k = 1, #wires do
            local _, tuple = decode(tplan, wires[k], 'new', 0)
            keep[k] = tuple
        end
    end)
    local lua_bytes = allocated(function()
        for k = 1, #wires do
            keep[k] = box.tuple.new(lua.decode(conv, wires[k]))
        end
    end)
    -- What a tuple reference costs by itself: box.tuple.new of a table
    -- that already exists.
    local row = {'k', 1, 2, 3, 'v', 4}
    local baseline = allocated(function()
        for k = 1, #wires do keep[k] = box.tuple.new(row) end
    end)
    -- the tuple reference and nothing per field
    t.assert_le(c_bytes, baseline + 16 * #wires,
                string.format('C: %d bytes for %d rows, a tuple reference '
                              .. 'alone: %d', c_bytes, #wires, baseline))
    -- the Lua path builds a table per message and per row on top
    t.assert_gt(lua_bytes, 4 * c_bytes)
end
