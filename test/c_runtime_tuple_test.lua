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
local pb = require('pb')
local helper = require('tuple_helper')

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
