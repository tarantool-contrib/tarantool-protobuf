-- pb.tuple conversion through the Lua codec: tuple -> wire bytes and
-- back, per representation and per type conversion. Parameterized over
-- both codegen modes.
local t = require('luatest')
local msgpack = require('msgpack')
local uuid = require('uuid')
local datetime = require('datetime')
local varbinary = require('varbinary')
local pb = require('pb')
local helper = require('tuple_helper')

local NULL = box.NULL

local function hex(s)
    return (s:gsub('.', function(c)
        return string.format('%02x', c:byte())
    end))
end

local function varint(n)
    return pb.wire.encode_varint(n)
end

-- Wire bytes of `tbl` with its fields in ascending field-number order.
-- pb.encode writes fields in declaration order, so each field is encoded
-- on its own and the pieces are joined by field number. `raw` maps a
-- field name to bytes to use verbatim instead (tag included).
local function canon(desc, tbl, raw)
    local fields = {}
    for _, f in ipairs(desc.fields) do fields[#fields + 1] = f end
    table.sort(fields, function(a, b) return a.id < b.id end)
    local out = {}
    for _, f in ipairs(fields) do
        if raw ~= nil and raw[f.name] ~= nil then
            out[#out + 1] = raw[f.name]
        elseif tbl[f.name] ~= nil then
            out[#out + 1] = pb.encode(desc, {[f.name] = tbl[f.name]})
        end
    end
    return table.concat(out)
end

-- A msgpack map whose entries keep the order given: {{k, v}, ...}.
local function ordered_map(entries)
    local n = #entries
    assert(n < 16)
    local parts = {string.char(0x80 + n)}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = msgpack.encode(e[1])
        parts[#parts + 1] = msgpack.encode(e[2])
    end
    return msgpack.object_from_raw(table.concat(parts))
end

local function is_array(v)
    local mt = getmetatable(v)
    return type(v) == 'table' and mt ~= nil and mt.__serialize == 'array'
end

local function is_map(v)
    local mt = getmetatable(v)
    return type(v) == 'table' and mt ~= nil and mt.__serialize == 'map'
end

local KV_FORMAT = {
    {name = 'key',             type = 'varbinary'},
    {name = 'create_revision', type = 'integer'},
    {name = 'mod_revision',    type = 'integer'},
    {name = 'version',         type = 'integer'},
    {name = 'value',           type = 'varbinary'},
    {name = 'lease_id',        type = 'integer'},
}

local function record_format()
    return {
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
end

local function format_with(format, name, entry)
    for i, e in ipairs(format) do
        if e.name == name then
            entry.name = name
            format[i] = entry
            return format
        end
    end
    error('no column ' .. name)
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

local U = uuid.fromstr('6ba7b810-9dad-11d1-80b4-00c04fd430c8')
local DT = datetime.new({timestamp = 1700000000, nsec = 123456789})

-- A Record row with every column set, and the same message as a table.
local function record_row()
    return {
        42, 'Alice',
        {street = 'Main', city = 'Town', zip = 12345},
        {{number = '555', kind = 1}, {number = '777'}},
        {math = 7},
        NULL, 2, DT, U, U,
        varbinary.new('\x00\x01'),
        1.5, true,
        {text = 'hi', weight = 3},
        -5, NULL,
    }
end

local function record_table()
    return {
        id = 42, name = 'Alice',
        address = {street = 'Main', city = 'Town', zip = 12345},
        phones = {{number = '555', kind = 1}, {number = '777'}},
        scores = {math = 7},
        kind = 2, created_at = DT,
        owner = U:str(), token = U:bin('b'),
        payload = '\x00\x01', weight = 1.5, active = true,
        label = {text = 'hi', weight = 3},
        balance = -5,
    }
end

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('tuple_convert.' .. mode)
    local kv = require(mode .. '.kv.kv_pb')

    g.before_all(function() helper.ensure_box() end)

    local function kv_conv(format)
        local s = helper.make_space('tuple_kv', format or KV_FORMAT)
        return pb.tuple.bind(kv.KeyValue_descriptor, s,
                             {columns = {lease = 'lease_id'}}), s
    end

    local function record_conv(format)
        local s = helper.make_space('tuple_record', format or record_format())
        return pb.tuple.bind(kv.Record_descriptor, s), s
    end

    local function mixed_conv()
        local s = helper.make_space('tuple_mixed', MIXED_FORMAT)
        return pb.tuple.bind(kv.Mixed_descriptor, s), s
    end

    -- -----------------------------------------------------------------
    -- Scalars
    -- -----------------------------------------------------------------

    g.test_keyvalue_round_trip = function()
        local conv, s = kv_conv()
        local row = s:insert({varbinary.new('k1'), 1, 2, 3,
                              varbinary.new('v1'), 7})
        local bytes = conv:encode(row)
        local want = pb.encode(kv.KeyValue_descriptor, {
            key = 'k1', create_revision = 1, mod_revision = 2, version = 3,
            value = 'v1', lease = 7})
        t.assert_equals(hex(bytes), hex(want))

        local back = conv:decode(bytes)
        t.assert(box.tuple.is(back))
        t.assert(varbinary.is(back[1]))
        t.assert_equals(tostring(back[1]), 'k1')
        t.assert_equals(back[2], 1)
        t.assert_equals(tostring(back[5]), 'v1')
        t.assert_equals(back[6], 7)
        t.assert_equals(hex(conv:encode(back)), hex(bytes))
    end

    g.test_null_reads_as_default_on_encode = function()
        local format = table.deepcopy(KV_FORMAT)
        format[5].is_nullable = true
        format[6].is_nullable = true
        local conv = kv_conv(format)
        local want = pb.encode(kv.KeyValue_descriptor, {
            key = 'k', create_revision = 1, mod_revision = 2, version = 3})
        -- NULL in place, and columns missing from the end of the tuple
        t.assert_equals(hex(conv:encode(box.tuple.new({'k', 1, 2, 3, NULL, 0}))),
                        hex(want))
        t.assert_equals(hex(conv:encode(box.tuple.new({'k', 1, 2, 3}))),
                        hex(want))
        -- proto3 defaults are omitted whatever column holds them
        t.assert_equals(conv:encode(box.tuple.new({'', 0, 0, 0, '', 0})), '')
    end

    g.test_defaults_are_materialized_on_decode = function()
        local conv = kv_conv()
        local row = pb.tuple._lua.decode(conv, '')
        t.assert_equals(#row, 6)
        t.assert(varbinary.is(row[1]))
        t.assert_equals(tostring(row[1]), '')
        t.assert_equals({row[2], row[3], row[4], row[6]}, {0, 0, 0, 0})
        t.assert_equals(tostring(row[5]), '')
        -- the result fits the space format
        conv:insert('')

        local rconv, rs = record_conv()
        local r = rconv:decode('')
        t.assert_equals(r[1], 0)
        t.assert_equals(r[2], '')
        t.assert_equals(r[3], nil, 'message field: presence')
        t.assert_equals(r[4], {})
        local lr = pb.tuple._lua.decode(rconv, '')
        t.assert(is_array(lr[4]), 'repeated: an empty array')
        t.assert(is_map(lr[5]), 'map<K,V>: an empty map')
        t.assert_equals(r[6], nil, 'optional: presence')
        t.assert_equals(r[7], 0)
        t.assert_equals(r[8], nil, 'Timestamp: presence')
        t.assert_equals(r[9], nil, "'' in a uuid column is NULL")
        t.assert_equals(r[10], nil, "'' in a uuid column is NULL")
        t.assert_equals(tostring(r[11]), '')
        t.assert_equals(r[12], 0)
        t.assert_equals(r[13], false)
        t.assert_equals(r[14], nil)
        t.assert_equals(r[15], 0)
        rs:insert(r)
    end

    g.test_unset_optional_is_null_and_set_empty_is_kept = function()
        local conv = record_conv()
        t.assert_equals(conv:decode('')[6], nil)
        local bytes = pb.encode(kv.Record_descriptor, {nickname = ''})
        t.assert_equals(conv:decode(bytes)[6], '')
        -- and an explicitly-set empty optional is written back
        local row = record_row()
        row[6] = ''
        local out = conv:encode(box.tuple.new(row))
        t.assert_equals(conv:decode(out)[6], '')
        t.assert_str_contains(out, '\x32\x00')
    end

    g.test_string_and_bytes_swap_msgpack_types = function()
        local format = record_format()
        format_with(format, 'payload', {type = 'string'})
        format_with(format, 'name', {type = 'varbinary'})
        local conv, s = record_conv(format)
        local row = record_row()
        row[2] = varbinary.new('Alice')
        row[11] = '\x00\x01'
        local tuple = s:insert(row)
        local bytes = conv:encode(tuple)
        t.assert_equals(hex(bytes), hex(canon(kv.Record_descriptor,
                                              record_table())))
        local back = conv:decode(bytes)
        t.assert(varbinary.is(back[2]), 'string field in a varbinary column')
        t.assert_equals(tostring(back[2]), 'Alice')
        t.assert_equals(type(back[11]), 'string',
                        'bytes field in a string column')
        s:replace(back)
    end

    g.test_unsigned_to_int64_range = function()
        local format = table.deepcopy(KV_FORMAT)
        format[2].type = 'unsigned'
        local conv, s = kv_conv(format)
        t.assert_equals(pb.tuple.bind(kv.KeyValue_descriptor, s,
                            {columns = {lease = 'lease_id'}}).plan.conv[2],
                        'range')
        local max = 9223372036854775807ULL
        local ok_row = s:insert({varbinary.new('a'), max, 0, 0,
                                 varbinary.new(''), 0})
        t.assert_equals(hex(conv:encode(ok_row)),
                        hex(pb.encode(kv.KeyValue_descriptor, {
                            key = 'a', create_revision = 9223372036854775807LL})))
        local big = s:insert({varbinary.new('b'), max + 1, 0, 0,
                              varbinary.new(''), 0})
        t.assert_error_msg_contains(
            "field 'create_revision' of kv.KeyValue (column "
                .. "'create_revision'): value 9223372036854775808ULL is out "
                .. 'of range for int64',
            conv.encode, conv, big)
        -- the other direction: a negative int64 does not fit `unsigned`
        local neg = pb.encode(kv.KeyValue_descriptor, {create_revision = -1})
        t.assert_error_msg_contains(
            "field 'create_revision' of kv.KeyValue (column "
                .. "'create_revision'): value -1LL does not fit column type "
                .. 'unsigned',
            conv.decode, conv, neg)
    end

    g.test_int32_range = function()
        local conv = record_conv()
        local row = record_row()
        row[7] = 2147483648
        t.assert_error_msg_contains(
            "field 'kind' of kv.Record (column 'kind'): value 2147483648 is "
                .. 'out of range for enum',
            conv.encode, conv, box.tuple.new(row))
        row = record_row()
        row[3] = {zip = -1}
        t.assert_error_msg_contains(
            "field 'zip' of kv.Address: value -1 is out of range for uint32",
            conv.encode, conv, box.tuple.new(row))
    end

    g.test_double_column_gets_a_double = function()
        local format = record_format()
        format_with(format, 'weight', {type = 'double'})
        local conv = record_conv(format)
        local bytes = pb.encode(kv.Record_descriptor, {id = 1, weight = 2})
        -- a `double` column refuses a msgpack integer
        local tuple = conv:insert(bytes)
        t.assert_equals(tuple[12], 2)
        t.assert_equals(hex(conv:encode(tuple)), hex(bytes))
    end

    g.test_wrong_msgpack_type_raises = function()
        local conv = record_conv()
        local row = record_row()
        row[3] = {street = 5}
        t.assert_error_msg_contains(
            "field 'street' of kv.Address: expected a string, got "
                .. 'unsigned integer',
            conv.encode, conv, box.tuple.new(row))
        row = record_row()
        row[13] = 1
        t.assert_error_msg_contains(
            "field 'active' of kv.Record (column 'active'): expected a "
                .. 'boolean, got unsigned integer',
            conv.encode, conv, box.tuple.new(row))
    end

    -- -----------------------------------------------------------------
    -- Messages per representation
    -- -----------------------------------------------------------------

    g.test_record_map_representation_round_trip = function()
        local conv, s = record_conv()
        local tuple = s:insert(record_row())
        local bytes = conv:encode(tuple)
        t.assert_equals(hex(bytes), hex(canon(kv.Record_descriptor,
                                              record_table())))
        local back = conv:decode(bytes)
        t.assert_equals(back[3], {street = 'Main', city = 'Town',
                                  zip = 12345})
        -- defaults are materialized at nested levels too
        t.assert_equals(back[4], {{number = '555', kind = 1},
                                  {number = '777', kind = 0}})
        t.assert_equals(back[14], {text = 'hi', weight = 3})
        t.assert_equals(back[16], nil)
        s:replace(back)
        t.assert_equals(hex(conv:encode(back)), hex(bytes))
    end

    g.test_nested_key_order_does_not_matter = function()
        local conv = record_conv()
        local a = record_row()
        local b = record_row()
        a[3] = ordered_map({{'street', 'Main'}, {'city', 'Town'},
                            {'zip', 12345}})
        b[3] = ordered_map({{'zip', 12345}, {'city', 'Town'},
                            {'street', 'Main'}})
        t.assert_equals(hex(conv:encode(box.tuple.new(a))),
                        hex(conv:encode(box.tuple.new(b))))
    end

    g.test_unknown_nested_key_raises = function()
        local conv = record_conv()
        local row = record_row()
        row[3] = {street = 'Main', bogus = 1}
        t.assert_error_msg_contains("unknown key 'bogus' in a kv.Address map",
            conv.encode, conv, box.tuple.new(row))
        row = record_row()
        row[4] = {{number = '1', extra = true}}
        t.assert_error_msg_contains("unknown key 'extra' in a kv.Phone map",
            conv.encode, conv, box.tuple.new(row))
    end

    g.test_message_in_array_column = function()
        local format = record_format()
        format_with(format, 'address', {type = 'array', is_nullable = true})
        local conv, s = record_conv(format)
        local row = record_row()
        row[3] = {'Main', 'Town', NULL, 12345}
        local bytes = conv:encode(s:insert(row))
        t.assert_equals(hex(bytes), hex(canon(kv.Record_descriptor,
                                              record_table())))
        local back = conv:decode(bytes)
        t.assert_equals(back[3], {'Main', 'Town', NULL, 12345})
        t.assert(is_array(pb.tuple._lua.decode(conv, bytes)[3]))
        -- short arrays leave the missing fields at their defaults
        row[3] = {'Main'}
        t.assert_equals(hex(conv:encode(box.tuple.new(row))),
            hex(canon(kv.Record_descriptor, (function()
                local r = record_table()
                r.address = {street = 'Main'}
                return r
            end)())))
    end

    g.test_array_position_without_field_raises = function()
        local format = record_format()
        format_with(format, 'address', {type = 'array', is_nullable = true})
        local conv = record_conv(format)
        local row = record_row()
        row[3] = {'Main', 'Town', 'hole', 12345}
        t.assert_error_msg_contains(
            'position 3 of a kv.Address array has no field',
            conv.encode, conv, box.tuple.new(row))
        row[3] = {'Main', 'Town', NULL, 12345, 'extra'}
        t.assert_error_msg_contains(
            'position 5 of a kv.Address array has no field',
            conv.encode, conv, box.tuple.new(row))
    end

    g.test_message_in_varbinary_column_is_raw = function()
        local format = record_format()
        format_with(format, 'address', {type = 'varbinary',
                                        is_nullable = true})
        local conv, s = record_conv(format)
        -- not in field-number order: raw bytes pass through verbatim
        local raw = pb.encode(kv.Address_descriptor, {city = 'Town'})
            .. pb.encode(kv.Address_descriptor, {street = 'Main'})
        local row = record_row()
        row[3] = varbinary.new(raw)
        local bytes = conv:encode(s:insert(row))
        t.assert_equals(hex(bytes), hex(canon(kv.Record_descriptor,
            record_table(), {address = '\x1a' .. varint(#raw) .. raw})))
        local back = conv:decode(bytes)
        t.assert(varbinary.is(back[3]))
        t.assert_equals(hex(tostring(back[3])), hex(raw))
        -- a message given twice on the wire is merged: the payloads join
        local a = pb.encode(kv.Record_descriptor, {address = {street = 'A'}})
        local b = pb.encode(kv.Record_descriptor, {address = {zip = 7}})
        local merged = conv:decode(a .. b)
        t.assert_equals(hex(tostring(merged[3])),
                        hex(a:sub(3) .. b:sub(3)))
        -- present but empty is not absent
        local empty = conv:decode('\x1a\x00')
        t.assert_equals(tostring(empty[3]), '')
        t.assert_equals(conv:decode('')[3], nil)
        t.assert_equals(hex(conv:encode(empty)), '1a00')
    end

    g.test_any_column_checks_each_value = function()
        local format = record_format()
        format_with(format, 'address', {type = 'any', is_nullable = true})
        local conv, s = record_conv(format)
        local bytes = conv:encode(s:insert(record_row()))
        t.assert_equals(hex(bytes), hex(canon(kv.Record_descriptor,
                                              record_table())))
        t.assert_equals(conv:decode(bytes)[3],
                        {street = 'Main', city = 'Town', zip = 12345})
        local row = record_row()
        row[3] = 5
        t.assert_error_msg_contains(
            "field 'address' of kv.Record (column 'address'): expected a "
                .. 'map, got unsigned integer',
            conv.encode, conv, box.tuple.new(row))
    end

    g.test_datetime_and_timestamp = function()
        local conv = record_conv()
        local row = record_row()
        local bytes = conv:encode(box.tuple.new(row))
        t.assert_equals(hex(bytes), hex(canon(kv.Record_descriptor,
                                              record_table())))
        local back = conv:decode(bytes)
        t.assert(datetime.is_datetime(back[8]))
        t.assert_equals(back[8].epoch, 1700000000)
        t.assert_equals(back[8].nsec, 123456789)
        -- a zone offset does not move the instant: the same instant in
        -- UTC encodes to the same bytes
        local zoned = datetime.new({timestamp = 1700000000, nsec = 5,
                                    tzoffset = 180})
        local utc = datetime.new({timestamp = zoned.epoch, nsec = 5})
        row[8] = zoned
        local a = conv:encode(box.tuple.new(row))
        row[8] = utc
        t.assert_equals(hex(a), hex(conv:encode(box.tuple.new(row))))
        -- the epoch itself is present, not absent
        row[8] = datetime.new({timestamp = 0})
        local zero = conv:encode(box.tuple.new(row))
        t.assert_str_contains(zero, '\x42\x00')
        t.assert_equals(conv:decode(zero)[8].epoch, 0)
        -- a Timestamp datetime cannot hold (datetime stops near year
        -- 5.8 million, int64 seconds go further)
        local far = pb.encode(kv.Record_descriptor, {
            created_at = {seconds = 4611686018427387904LL, nanos = 0}})
        t.assert_error_msg_contains(
            "field 'created_at' of kv.Record (column 'created_at'): "
                .. 'Timestamp is outside the datetime range',
            conv.decode, conv, far)
    end

    g.test_uuid_as_string_and_bytes = function()
        local conv, s = record_conv()
        local bytes = conv:encode(s:insert(record_row()))
        local want = pb.encode(kv.Record_descriptor, {
            owner = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'})
        t.assert_str_contains(bytes, want)
        -- bytes: the 16 bytes in RFC 4122 order, as msgpack stores them
        t.assert_str_contains(bytes, '\x52\x10' .. msgpack.encode(U):sub(-16))
        local back = conv:decode(bytes)
        t.assert(uuid.is_uuid(back[9]))
        t.assert_equals(back[9], U)
        t.assert_equals(back[10], U)
    end

    g.test_invalid_uuid_on_decode_raises = function()
        local conv = record_conv()
        local cases = {
            {{owner = 'not-a-uuid'}, "field 'owner' of kv.Record (column "
                .. "'owner'): 'not-a-uuid' is not a canonical uuid"},
            {{owner = '6BA7B810-9DAD-11D1-80B4-00C04FD430C8'},
                "is not a canonical uuid"},
            {{token = string.rep('\x01', 15)}, "field 'token' of kv.Record "
                .. "(column 'token'): a uuid is 16 bytes, got 15"},
        }
        for _, c in ipairs(cases) do
            t.assert_error_msg_contains(c[2], conv.decode, conv,
                pb.encode(kv.Record_descriptor, c[1]))
        end
        -- a uuid column holding something else
        local row = record_row()
        row[9] = 'text'
        t.assert_error_msg_contains(
            "field 'owner' of kv.Record (column 'owner'): expected a uuid, "
                .. 'got string',
            conv.encode, conv, box.tuple.new(row))
    end

    -- -----------------------------------------------------------------
    -- Field order, repeated fields, maps, oneofs
    -- -----------------------------------------------------------------

    local function mixed_row()
        return {
            'm1', {'a', ''}, {1, -2, 3},
            ordered_map({{7, {number = '7'}}}),
            9, {DT}, {1, 0, 2},
            {id = 'c', rank = 4},
            NULL, 'txt',
        }
    end

    g.test_fields_in_field_number_order = function()
        local conv, s = mixed_conv()
        local bytes = conv:encode(s:insert(mixed_row()))
        local tbl = {
            id = 'm1', tags = {'a', ''}, counts = {1, -2, 3},
            contacts = {[7] = {number = '7'}}, rank = 9, seen = {DT},
            kinds = {1, 0, 2}, child = {id = 'c', rank = 4}, text = 'txt',
        }
        -- the nested message is in field-number order as well
        local child = pb.encode(kv.Mixed_descriptor, {id = 'c'})
            .. pb.encode(kv.Mixed_descriptor, {rank = 4})
        local want = canon(kv.Mixed_descriptor, tbl,
                           {child = '\x42' .. varint(#child) .. child})
        t.assert_equals(hex(bytes), hex(want))
        t.assert_not_equals(hex(pb.encode(kv.Mixed_descriptor, tbl)),
                            hex(want), 'the codec follows declaration order')

        local back = conv:decode(bytes)
        t.assert_equals(back[2], {'a', ''})
        t.assert_equals(back[3], {1, -2, 3})
        t.assert_equals(back[4], {[7] = {number = '7', kind = 0}})
        t.assert_equals(back[6][1].epoch, DT.epoch)
        t.assert_equals(back[7], {1, 0, 2})
        t.assert_equals(back[8].id, 'c')
        t.assert_equals(back[8].rank, 4)
        t.assert_equals(back[8].tags, {})
        t.assert_equals(back[8].child, nil)
        t.assert_equals(back[9], nil)
        t.assert_equals(back[10], 'txt')
        s:replace(back)
        t.assert_equals(hex(conv:encode(back)), hex(bytes))
    end

    g.test_map_entries_follow_msgpack_order = function()
        local conv = mixed_conv()
        local function entries(order)
            local row = mixed_row()
            local e = {}
            for _, k in ipairs(order) do
                e[#e + 1] = {k, {number = tostring(k)}}
            end
            row[4] = ordered_map(e)
            return conv:encode(box.tuple.new(row))
        end
        local function want(order)
            local parts = {}
            for _, k in ipairs(order) do
                parts[#parts + 1] = pb.encode(kv.Mixed_descriptor, {
                    contacts = {[k] = {number = tostring(k)}}})
            end
            return table.concat(parts)
        end
        local a = entries({3, 1, 2})
        local b = entries({2, 3, 1})
        t.assert_str_contains(a, want({3, 1, 2}))
        t.assert_str_contains(b, want({2, 3, 1}))
        t.assert_not_equals(a, b)
    end

    g.test_null_list_element_raises = function()
        local conv = mixed_conv()
        local row = mixed_row()
        row[2] = {'a', NULL}
        t.assert_error_msg_contains(
            "field 'tags' of kv.Mixed (column 'tags'): element 2: expected "
                .. 'a string, got nil',
            conv.encode, conv, box.tuple.new(row))
    end

    g.test_oneof_with_two_members_set_raises = function()
        local conv = mixed_conv()
        local row = mixed_row()
        row[9] = 5
        t.assert_error_msg_contains(
            "oneof 'pick' of kv.Mixed has more than one member set: "
                .. "'code' and 'text'",
            conv.encode, conv, box.tuple.new(row))
        row[10] = NULL
        t.assert_str_contains(conv:encode(box.tuple.new(row)), '\x48\x05')
    end

    g.test_oneof_last_member_on_the_wire_wins = function()
        local conv = mixed_conv()
        local a = pb.encode(kv.Mixed_descriptor, {code = 5})
        local b = pb.encode(kv.Mixed_descriptor, {text = 'x'})
        local row = conv:decode(a .. b)
        t.assert_equals(row[9], nil)
        t.assert_equals(row[10], 'x')
        row = conv:decode(b .. a)
        t.assert_equals(row[9], 5)
        t.assert_equals(row[10], nil)
        -- a member set to its default is present
        row = conv:decode(pb.encode(kv.Mixed_descriptor, {code = 0}))
        t.assert_equals(row[9], 0)
    end

    -- -----------------------------------------------------------------
    -- Decode edges
    -- -----------------------------------------------------------------

    g.test_unknown_wire_field_is_skipped = function()
        local conv = kv_conv()
        local bytes = pb.encode(kv.KeyValue_descriptor, {key = 'k', version = 3})
        -- field 127, varint 1; then field 99, LEN 'zz'
        local extra = bytes .. '\xf8\x07\x01' .. '\x9a\x06\x02zz'
        t.assert_equals(conv:decode(extra):totable(),
                        conv:decode(bytes):totable())
    end

    g.test_unbound_non_nullable_column_raises_on_decode = function()
        local format = table.deepcopy(KV_FORMAT)
        table.insert(format, {name = 'owner_id', type = 'unsigned'})
        local conv = kv_conv(format)
        t.assert_error_msg_contains(
            "cannot decode kv.KeyValue into space 'tuple_kv': column "
                .. "'owner_id' is not nullable and no field binds to it",
            conv.decode, conv, '')
        -- encode does not care
        t.assert_equals(conv:encode(box.tuple.new({'k', 0, 0, 0, '', 0, 1})),
                        pb.encode(kv.KeyValue_descriptor, {key = 'k'}))
    end

    -- -----------------------------------------------------------------
    -- Space operations and plumbing
    -- -----------------------------------------------------------------

    g.test_insert_and_replace = function()
        local conv, s = kv_conv()
        local a = pb.encode(kv.KeyValue_descriptor, {key = 'k', version = 1})
        local b = pb.encode(kv.KeyValue_descriptor, {key = 'k', version = 2})
        local ta = conv:insert(a)
        t.assert(box.tuple.is(ta))
        t.assert_equals(ta[4], 1)
        t.assert_error_msg_contains('Duplicate key', conv.insert, conv, a)
        local tb = conv:replace(b)
        t.assert_equals(tb[4], 2)
        t.assert_equals(s:get({varbinary.new('k')})[4], 2)
        t.assert_equals(s:count(), 1)
    end

    g.test_methods_follow_format_changes = function()
        local conv, s = kv_conv()
        local format = table.deepcopy(KV_FORMAT)
        format[6] = {name = 'extra', type = 'unsigned', is_nullable = true}
        format[7] = {name = 'lease_id', type = 'integer'}
        s:format(format)
        local row = box.tuple.new({'k', 0, 0, 0, '', 99, 5})
        t.assert_equals(conv:encode(row),
                        pb.encode(kv.KeyValue_descriptor, {key = 'k',
                                                           lease = 5}))
        t.assert_equals(conv:decode(pb.encode(kv.KeyValue_descriptor,
                                              {lease = 5}))[7], 5)
    end

    g.test_encode_needs_a_tuple = function()
        local conv = kv_conv()
        t.assert_error_msg_contains('expected a box.tuple, got table',
            conv.encode, conv, {'k', 0, 0, 0, '', 0})
        t.assert_error_msg_contains('expected a string to decode, got nil',
            conv.decode, conv, nil)
    end

    g.test_lua_functions_are_exported = function()
        local conv = kv_conv()
        local row = box.tuple.new({'k', 1, 2, 3, 'v', 4})
        local bytes = conv:encode(row)
        t.assert_equals(pb.tuple._lua.encode(conv, row), bytes)
        t.assert_equals(pb.tuple._lua.encode_repeated(conv, 2, {row}),
                        conv:encode_repeated(2, {row}))
        t.assert_equals(pb.tuple._lua.decode(conv, bytes),
                        conv:decode(bytes):totable())
    end
end

-- ---------------------------------------------------------------------
-- encode_repeated: rows spliced into an enclosing message
-- ---------------------------------------------------------------------

local gr = t.group('tuple_convert.repeated')

gr.before_all(function() helper.ensure_box() end)

gr.test_encode_repeated_after_a_header = function()
    local m = pb.parse([[
        syntax = "proto3";
        package range;
        message KeyValue {
            bytes key = 1; int64 create_revision = 2; int64 mod_revision = 3;
            int64 version = 4; bytes value = 5; int64 lease = 6;
        }
        message Range { int64 revision = 1; repeated KeyValue kvs = 2;
                        bool more = 3; }
    ]])
    local s = helper.make_space('tuple_kv', KV_FORMAT)
    local conv = pb.tuple.bind(m.KeyValue_descriptor, s,
                               {columns = {lease = 'lease_id'}})
    local rows = {}
    for i = 1, 3 do
        s:insert({varbinary.new('k' .. i), i, i, 1, varbinary.new('v' .. i), 0})
        rows[i] = {key = 'k' .. i, create_revision = i, mod_revision = i,
                   version = 1, value = 'v' .. i}
    end
    local msg = pb.encode(m.Range_descriptor, {revision = 10})
        .. conv:encode_repeated(2, s:select())
        .. pb.encode(m.Range_descriptor, {more = true})
    t.assert_equals(hex(msg), hex(pb.encode(m.Range_descriptor, {
        revision = 10, kvs = rows, more = true})))
    local back = pb.decode(m.Range_descriptor, msg)
    t.assert_equals(#back.kvs, 3)
    t.assert_equals(back.kvs[2].key, 'k2')
    t.assert_equals(back.more, true)

    t.assert_equals(conv:encode_repeated(2, {}), '')
    t.assert_error_msg_contains('field number must be an integer in',
        conv.encode_repeated, conv, 0, {})
    t.assert_error_msg_contains('field number must be an integer in',
        conv.encode_repeated, conv, 'kvs', {})
    t.assert_error_msg_contains('tuples must be an array',
        conv.encode_repeated, conv, 2, nil)
end
