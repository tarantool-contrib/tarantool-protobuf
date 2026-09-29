-- pb.tuple.bind: descriptor/space-format validation and the plan it
-- compiles. Parameterized over both codegen modes.
local t = require('luatest')
local ffi = require('ffi')
local pb = require('pb')
local helper = require('tuple_helper')

-- Index of the plan entry for proto field `name`, or nil.
local function slot(node, name)
    for i = 1, node.n do
        if node.name[i] == name then return i end
    end
    return nil
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

-- record_format() with the entry for column `name` replaced by `entry`.
local function record_format_with(name, entry)
    local f = record_format()
    for i, e in ipairs(f) do
        if e.name == name then
            entry.name = name
            f[i] = entry
            return f
        end
    end
    error('no column ' .. name)
end

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('tuple_bind.' .. mode)
    local kv = require(mode .. '.kv.kv_pb')
    local hello = require(mode .. '.hello.hello_pb')

    g.before_all(function() helper.ensure_box() end)

    -- -----------------------------------------------------------------
    -- Accepted bindings
    -- -----------------------------------------------------------------

    g.test_keyvalue_binds_with_rename = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        local p = conv.plan
        t.assert_equals(p.layout, 'tuple')
        t.assert_equals(p.message, 'kv.KeyValue')
        t.assert_equals(p.n, 6)
        t.assert_equals(p.field_no, {1, 2, 3, 4, 5, 6})
        t.assert_equals(p.column, {1, 2, 3, 4, 5, 6})
        t.assert_equals(p.name, {'key', 'create_revision', 'mod_revision',
                                 'version', 'value', 'lease'})
        t.assert_equals(p.column_name[6], 'lease_id')
        t.assert_equals(p.kind, {'bytes', 'int64', 'int64', 'int64',
                                 'bytes', 'int64'})
        t.assert_equals(p.repr, {'scalar', 'scalar', 'scalar', 'scalar',
                                 'scalar', 'scalar'})
        t.assert_equals(p.conv, {'direct', 'range', 'range', 'range',
                                 'direct', 'range'})
        t.assert_equals(p.sub, {false, false, false, false, false, false})
        t.assert_equals(p.unbound_nonnull, {})
    end

    g.test_omit_leaves_column_unbound = function()
        local format = table.deepcopy(KV_FORMAT)
        format[5].is_nullable = true
        local s = helper.make_space('tuple_kv', format)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'},
                                    omit = {'value'}})
        local p = conv.plan
        t.assert_equals(p.n, 5)
        t.assert_equals(p.field_no, {1, 2, 3, 4, 6})
        t.assert_equals(p.column, {1, 2, 3, 4, 6})
        t.assert_is(slot(p, 'value'), nil)
        -- nullable, so not a decode-time error
        t.assert_equals(p.unbound_nonnull, {})
    end

    g.test_unbound_non_nullable_column_is_recorded = function()
        local format = table.deepcopy(KV_FORMAT)
        table.insert(format, {name = 'owner_id', type = 'unsigned'})
        table.insert(format, {name = 'comment', type = 'string',
                              is_nullable = true})
        local s = helper.make_space('tuple_kv', format)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'},
                                    omit = {'value'}})
        t.assert_equals(conv.plan.unbound_nonnull, {5, 7})
        t.assert_equals(conv.plan.unbound_nonnull_name, {'value', 'owner_id'})
    end

    g.test_record_representations = function()
        local s = helper.make_space('tuple_record', record_format())
        local p = pb.tuple.bind(kv.Record_descriptor, s).plan
        t.assert_equals(p.n, 15)
        -- ascending field numbers, whatever the column order
        for i = 2, p.n do
            t.assert(p.field_no[i - 1] < p.field_no[i])
        end

        local function check(name, want)
            local i = slot(p, name)
            t.assert_not_equals(i, nil, name)
            for k, v in pairs(want) do
                t.assert_equals(p[k][i], v, name .. '.' .. k)
            end
            return i
        end

        check('id',       {kind = 'uint64', repr = 'scalar', conv = 'direct',
                           column = 1, column_type = 'unsigned'})
        check('name',     {kind = 'string', conv = 'direct'})
        local ia = check('address', {kind = 'message', repr = 'msg_map',
                                     conv = 'direct', nullable = true})
        check('phones',   {kind = 'message', repr = 'list', conv = 'direct',
                           repeated = true})
        check('scores',   {kind = 'map', repr = 'dict', conv = 'direct',
                           key_kind = 'string', value_kind = 'int32'})
        check('nickname', {kind = 'string', optional = true, nullable = true})
        check('kind',     {kind = 'enum', repr = 'scalar', conv = 'range'})
        check('created_at', {kind = 'timestamp', repr = 'scalar',
                             conv = 'direct', column_type = 'datetime'})
        check('owner',    {kind = 'string', conv = 'uuid_text'})
        check('token',    {kind = 'bytes', conv = 'uuid_bin'})
        check('payload',  {kind = 'bytes', conv = 'direct'})
        check('weight',   {kind = 'double', conv = 'number'})
        check('active',   {kind = 'bool', conv = 'direct'})
        check('label',    {kind = 'message', repr = 'msg_map'})
        check('balance',  {kind = 'sint64', conv = 'range', column = 15})

        -- nested message as a map keyed by field name
        local a = p.sub[ia]
        t.assert_equals(a.layout, 'map')
        t.assert_equals(a.message, 'kv.Address')
        t.assert_equals(a.name, {'street', 'city', 'zip'})
        t.assert_equals(a.field_no, {1, 2, 4})
        t.assert_equals(a.column, {0, 0, 0})
        t.assert_equals(a.conv, {'any', 'any', 'any'})
        t.assert_equals(a.nullable, {true, true, true})

        -- repeated message elements are maps keyed by name
        local ph = p.sub[slot(p, 'phones')]
        t.assert_equals(ph.layout, 'map')
        t.assert_equals(ph.name, {'number', 'kind'})
        t.assert_equals(ph.kind, {'string', 'enum'})

        t.assert_equals(p.sub[slot(p, 'scores')], false)
        -- `note` has no proto field and is nullable
        t.assert_equals(p.unbound_nonnull, {})
    end

    g.test_message_in_array_column_is_positioned_by_field_number = function()
        local s = helper.make_space('tuple_record',
            record_format_with('address', {type = 'array', is_nullable = true}))
        local p = pb.tuple.bind(kv.Record_descriptor, s).plan
        local i = slot(p, 'address')
        t.assert_equals(p.repr[i], 'msg_array')
        local a = p.sub[i]
        t.assert_equals(a.layout, 'array')
        t.assert_equals(a.column, {1, 2, 4})
    end

    g.test_message_in_varbinary_column_is_raw = function()
        local s = helper.make_space('tuple_record',
            record_format_with('address', {type = 'varbinary',
                                           is_nullable = true}))
        local p = pb.tuple.bind(kv.Record_descriptor, s).plan
        local i = slot(p, 'address')
        t.assert_equals(p.repr[i], 'raw')
        t.assert_equals(p.sub[i], false)
    end

    g.test_any_column_is_checked_per_value = function()
        local s = helper.make_space('tuple_record',
            record_format_with('address', {type = 'any', is_nullable = true}))
        local p = pb.tuple.bind(kv.Record_descriptor, s).plan
        local i = slot(p, 'address')
        t.assert_equals(p.repr[i], 'msg_map')
        t.assert_equals(p.conv[i], 'any')
    end

    g.test_string_and_bytes_are_interchangeable = function()
        local s = helper.make_space('tuple_record',
            record_format_with('payload', {type = 'string'}))
        local p = pb.tuple.bind(kv.Record_descriptor, s).plan
        t.assert_equals(p.conv[slot(p, 'payload')], 'str_bin')
    end

    g.test_recursive_message_shares_its_node = function()
        local s = helper.make_space('tuple_person', {
            {name = 'name',    type = 'string'},
            {name = 'friends', type = 'array'},
        })
        local keep = {}
        for _, f in ipairs(hello.Person_descriptor.fields) do
            if f.name ~= 'name' and f.name ~= 'friends' then
                keep[#keep + 1] = f.name
            end
        end
        local p = pb.tuple.bind(hello.Person_descriptor, s,
                                {omit = keep}).plan
        local friend = p.sub[slot(p, 'friends')]
        t.assert_equals(friend.layout, 'map')
        t.assert_is(friend.sub[slot(friend, 'friends')], friend)
    end

    -- -----------------------------------------------------------------
    -- Bind errors
    -- -----------------------------------------------------------------

    g.test_field_without_column_raises = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        t.assert_error_msg_contains("field 'lease' of kv.KeyValue has no column 'lease'",
            pb.tuple.bind, kv.KeyValue_descriptor, s)
    end

    g.test_optional_on_non_nullable_column_raises = function()
        local s = helper.make_space('tuple_record',
            record_format_with('nickname', {type = 'string'}))
        t.assert_error_msg_contains(
            "optional field 'nickname' of kv.Record needs a nullable column",
            pb.tuple.bind, kv.Record_descriptor, s)
    end

    -- A singular message field has explicit presence: absent <-> NULL.
    g.test_message_on_non_nullable_column_raises = function()
        local cases = {
            {'address',    {type = 'map'}},
            {'address',    {type = 'array'}},
            {'address',    {type = 'varbinary'}},
            {'address',    {type = 'any'}},
            {'created_at', {type = 'datetime'}},
            {'label',      {type = 'map'}},
        }
        for _, c in ipairs(cases) do
            local s = helper.make_space('tuple_record',
                record_format_with(c[1], c[2]))
            t.assert_error_msg_contains(
                string.format("message field '%s' of kv.Record needs a "
                              .. "nullable column, column '%s' is not "
                              .. 'nullable', c[1], c[1]),
                pb.tuple.bind, kv.Record_descriptor, s)
        end
    end

    -- An empty string is not a uuid: implicit '' <-> NULL.
    g.test_uuid_column_must_be_nullable = function()
        for _, name in ipairs({'owner', 'token'}) do
            local s = helper.make_space('tuple_record',
                record_format_with(name, {type = 'uuid'}))
            t.assert_error_msg_contains(
                string.format("field '%s' of kv.Record is bound to uuid "
                              .. "column '%s', which must be nullable",
                              name, name),
                pb.tuple.bind, kv.Record_descriptor, s)
        end
    end

    g.test_repeated_on_non_array_column_raises = function()
        local s = helper.make_space('tuple_record',
            record_format_with('phones', {type = 'map'}))
        t.assert_error_msg_contains(
            "field 'phones' (repeated kv.Phone) of kv.Record cannot bind "
                .. "to column 'phones' (map)",
            pb.tuple.bind, kv.Record_descriptor, s)
    end

    g.test_proto_map_on_non_map_column_raises = function()
        local s = helper.make_space('tuple_record',
            record_format_with('scores', {type = 'array'}))
        t.assert_error_msg_contains(
            "field 'scores' (map<string, int32>) of kv.Record cannot bind "
                .. "to column 'scores' (array)",
            pb.tuple.bind, kv.Record_descriptor, s)
    end

    g.test_incompatible_scalar_types_raise = function()
        local cases = {
            {'id',         {type = 'string'},  'uint64',  'string'},
            {'name',       {type = 'integer'}, 'string',  'integer'},
            {'active',     {type = 'unsigned'}, 'bool',   'unsigned'},
            {'weight',     {type = 'integer'}, 'double',  'integer'},
            {'balance',    {type = 'number'},  'sint64',  'number'},
            {'kind',       {type = 'string'},  'enum kv.Kind', 'string'},
            {'created_at', {type = 'map', is_nullable = true},
                'google.protobuf.Timestamp', 'map'},
            {'payload',    {type = 'decimal'}, 'bytes',   'decimal'},
        }
        for _, c in ipairs(cases) do
            local s = helper.make_space('tuple_record',
                record_format_with(c[1], c[2]))
            t.assert_error_msg_contains(
                string.format("field '%s' (%s) of kv.Record cannot bind "
                              .. "to column '%s' (%s)", c[1], c[3], c[1], c[4]),
                pb.tuple.bind, kv.Record_descriptor, s)
        end
    end

    g.test_too_sparse_array_message_raises = function()
        local s = helper.make_space('tuple_record',
            record_format_with('label', {type = 'array', is_nullable = true}))
        t.assert_error_msg_contains(
            "field 'label' of kv.Record: kv.Label is too sparse for an "
                .. "array column (max field number 9, 2 fields)",
            pb.tuple.bind, kv.Record_descriptor, s)
    end

    g.test_opaque_wkt_binds_only_to_varbinary = function()
        local s = helper.make_space('tuple_event', {
            {name = 'title',    type = 'string'},
            {name = 'duration', type = 'map', is_nullable = true},
        })
        local keep = {}
        for _, f in ipairs(hello.Event_descriptor.fields) do
            if f.name ~= 'title' and f.name ~= 'duration' then
                keep[#keep + 1] = f.name
            end
        end
        t.assert_error_msg_contains(
            "field 'duration' (google.protobuf.Duration) of hello.Event "
                .. "cannot bind to column 'duration' (map)",
            pb.tuple.bind, hello.Event_descriptor, s, {omit = keep})
        s:format({
            {name = 'title',    type = 'string'},
            {name = 'duration', type = 'varbinary', is_nullable = true},
        })
        local p = pb.tuple.bind(hello.Event_descriptor, s, {omit = keep}).plan
        t.assert_equals(p.repr[slot(p, 'duration')], 'raw')
    end

    g.test_bad_options_raise = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local d = kv.KeyValue_descriptor
        t.assert_error_msg_contains("columns: kv.KeyValue has no field 'leese'",
            pb.tuple.bind, d, s, {columns = {leese = 'lease_id'}})
        t.assert_error_msg_contains("omit: kv.KeyValue has no field 'valeu'",
            pb.tuple.bind, d, s, {columns = {lease = 'lease_id'},
                                  omit = {'valeu'}})
        t.assert_error_msg_contains("unknown option 'colums'",
            pb.tuple.bind, d, s, {colums = {}})
        t.assert_error_msg_contains(
            "field 'lease' is both renamed and omitted",
            pb.tuple.bind, d, s, {columns = {lease = 'lease_id'},
                                  omit = {'lease'}})
        t.assert_error_msg_contains(
            "fields 'version' and 'lease' of kv.KeyValue both bind to "
                .. "column 'version'",
            pb.tuple.bind, d, s, {columns = {lease = 'version'}})
    end

    g.test_omit_must_be_a_sequence_of_names = function()
        local format = table.deepcopy(KV_FORMAT)
        format[5].is_nullable = true
        format[4].is_nullable = true
        local s = helper.make_space('tuple_kv', format)
        local d = kv.KeyValue_descriptor
        local cols = {lease = 'lease_id'}
        local cases = {
            {{value = true}, "omit must be an array of field names"},
            {{'value', value = true}, "omit must be an array of field names"},
            {{[1] = 'value', [3] = 'version'},
                "omit must be an array of field names"},
            {{[2] = 'value'}, "omit must be an array of field names"},
            {{'value', 'version', 'value'}, "omit: field 'value' is listed twice"},
            {{1}, "omit: field names must be strings, got number"},
        }
        for _, c in ipairs(cases) do
            t.assert_error_msg_contains(c[2], pb.tuple.bind, d, s,
                                        {columns = cols, omit = c[1]})
        end
        -- The proper form still works.
        local p = pb.tuple.bind(d, s, {columns = cols,
                                       omit = {'value', 'version'}}).plan
        t.assert_equals(p.name, {'key', 'create_revision', 'mod_revision',
                                 'lease'})
    end

    g.test_columns_values_must_be_names = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local d = kv.KeyValue_descriptor
        for _, bad in ipairs({6, true, '', {'lease_id'}}) do
            t.assert_error_msg_contains(
                "columns: column name for field 'lease' must be a "
                    .. 'non-empty string',
                pb.tuple.bind, d, s, {columns = {lease = bad}})
        end
        t.assert_error_msg_contains("columns: kv.KeyValue has no field '1'",
            pb.tuple.bind, d, s, {columns = {'lease_id'}})
    end

    g.test_bad_arguments_raise = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        t.assert_error_msg_contains('expected a message descriptor',
            pb.tuple.bind, nil, s)
        t.assert_error_msg_contains('expected a message descriptor',
            pb.tuple.bind, pb.wkt.Timestamp_descriptor, s)
        t.assert_error_msg_contains('expected a space object',
            pb.tuple.bind, kv.KeyValue_descriptor, 'tuple_kv')
    end

    -- -----------------------------------------------------------------
    -- Schema changes
    -- -----------------------------------------------------------------

    g.test_schema_version_changes_on_format = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local before = box.info.schema_version
        local format = table.deepcopy(KV_FORMAT)
        table.insert(format, {name = 'extra', type = 'any',
                              is_nullable = true})
        s:format(format)
        t.assert_not_equals(box.info.schema_version, before)
        -- the C API reports the same version
        pcall(ffi.cdef, 'uint32_t box_schema_version(void);')
        t.assert_equals(tonumber(ffi.C.box_schema_version()),
                        box.info.schema_version)
    end

    -- box.internal.schema_version is deprecated (it logs a warning on
    -- every call in Tarantool 3.x); bind and rebind read
    -- box.info.schema_version.
    g.test_no_deprecated_schema_version = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local internal = box.internal.schema_version
        box.internal.schema_version = function()
            error('box.internal.schema_version called', 0)
        end
        local ok, err = pcall(function()
            local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                       {columns = {lease = 'lease_id'}})
            local format = table.deepcopy(KV_FORMAT)
            table.insert(format, {name = 'extra', type = 'any',
                                  is_nullable = true})
            s:format(format)
            conv:_check_schema()
            t.assert_equals(conv.schema_version, box.info.schema_version)
        end)
        box.internal.schema_version = internal
        t.assert(ok, tostring(err))
    end

    g.test_rebinds_after_format_change = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        local old_plan = conv.plan
        conv:_check_schema()
        t.assert_is(conv.plan, old_plan, 'no DDL, no rebind')

        -- Move `lease_id` in front of a new non-nullable column.
        local format = table.deepcopy(KV_FORMAT)
        format[6] = {name = 'owner', type = 'unsigned', is_nullable = true}
        format[7] = {name = 'lease_id', type = 'integer', is_nullable = true}
        s:format(format)
        conv:_check_schema()
        t.assert_is_not(conv.plan, old_plan)
        t.assert_equals(conv.plan.column[slot(conv.plan, 'lease')], 7)
        t.assert_equals(conv.schema_version, box.info.schema_version)
    end

    g.test_rebind_raises_on_incompatible_format = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        local format = table.deepcopy(KV_FORMAT)
        format[6] = {name = 'lease_id', type = 'string'}
        s:truncate()
        s:format(format)
        t.assert_error_msg_contains(
            "field 'lease' (int64) of kv.KeyValue cannot bind to column "
                .. "'lease_id' (string)",
            conv._check_schema, conv)
    end

    g.test_rebind_raises_when_space_is_dropped = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        s:drop()
        t.assert_error_msg_contains("space 'tuple_kv'",
            conv._check_schema, conv)
        t.assert_error_msg_contains('no longer exists',
            conv._check_schema, conv)
    end

    g.test_rebind_refuses_another_space_with_the_same_id = function()
        local s = helper.make_space('tuple_kv', KV_FORMAT)
        local id = s.id
        local conv = pb.tuple.bind(kv.KeyValue_descriptor, s,
                                   {columns = {lease = 'lease_id'}})
        s:drop()
        if box.space.tuple_kv_other ~= nil then
            box.space.tuple_kv_other:drop()
        end
        -- Same id, same (bindable) format, different space.
        local other = box.schema.space.create('tuple_kv_other',
                                              {id = id, format = KV_FORMAT})
        t.assert_equals(other.id, id)
        t.assert_error_msg_contains("space 'tuple_kv' no longer exists",
            conv._check_schema, conv)
        other:drop()
    end
end

-- ---------------------------------------------------------------------
-- The compatibility table, cell by cell
--
-- Every proto kind against every column type Tarantool accepts in a
-- space format. The expectation is written out here rather than derived
-- from the table under test: a cell missing below must be refused.
-- ---------------------------------------------------------------------

local gc = t.group('tuple_bind.compat')

local COLUMN_TYPES = {
    'any', 'unsigned', 'string', 'number', 'double', 'integer', 'boolean',
    'varbinary', 'scalar', 'decimal', 'uuid', 'datetime', 'interval',
    'array', 'map',
    'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'int64',
    'uint64', 'float32', 'float64',
}

-- [kind] = {[column type] = {repr, conv}}
local S = 'scalar'
local EXPECTED = {
    int32    = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    int64    = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    uint32   = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    uint64   = {unsigned = {S, 'direct'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    sint32   = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    sint64   = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    fixed32  = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    fixed64  = {unsigned = {S, 'direct'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    sfixed32 = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    sfixed64 = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    enum     = {unsigned = {S, 'range'}, integer = {S, 'range'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    double   = {double = {S, 'direct'}, number = {S, 'number'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    float    = {double = {S, 'direct'}, number = {S, 'number'},
                any = {S, 'any'}, scalar = {S, 'any'}},
    bool     = {boolean = {S, 'direct'}, any = {S, 'any'},
                scalar = {S, 'any'}},
    string   = {string = {S, 'direct'}, varbinary = {S, 'str_bin'},
                uuid = {S, 'uuid_text'}, any = {S, 'any'},
                scalar = {S, 'any'}},
    bytes    = {varbinary = {S, 'direct'}, string = {S, 'str_bin'},
                uuid = {S, 'uuid_bin'}, any = {S, 'any'},
                scalar = {S, 'any'}},
    timestamp = {datetime = {S, 'direct'}, any = {S, 'any'},
                 varbinary = {'raw', 'direct'}},
    message  = {map = {'msg_map', 'direct'}, any = {'msg_map', 'any'},
                array = {'msg_array', 'direct'},
                varbinary = {'raw', 'direct'}},
    opaque   = {varbinary = {'raw', 'direct'}},
    ['repeated'] = {array = {'list', 'direct'}, any = {'list', 'any'}},
    map      = {map = {'dict', 'direct'}, any = {'dict', 'any'}},
}

local function kind_field(kind)
    local kv = require('runtime.kv.kv_pb')
    if kind == 'enum' then
        return {name = 'f', id = 1, kind = 'enum', enum = kv.Kind_descriptor}
    elseif kind == 'timestamp' then
        return {name = 'f', id = 1, kind = 'message',
                message = pb.wkt.Timestamp_descriptor}
    elseif kind == 'message' then
        return {name = 'f', id = 1, kind = 'message',
                message = kv.Address_descriptor}
    elseif kind == 'opaque' then
        return {name = 'f', id = 1, kind = 'message',
                message = pb.wkt.Duration_descriptor}
    elseif kind == 'repeated' then
        return {name = 'f', id = 1, kind = 'scalar', proto_type = 'int32',
                ['repeated'] = true}
    elseif kind == 'map' then
        return {name = 'f', id = 1, kind = 'map',
                key = {kind = 'scalar', proto_type = 'string'},
                value = {kind = 'scalar', proto_type = 'int32'}}
    end
    return {name = 'f', id = 1, kind = 'scalar', proto_type = kind}
end

gc.test_every_kind_against_every_column_type = function()
    local kinds = {}
    for kind in pairs(EXPECTED) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    t.assert_equals(#kinds, 21)
    local mismatches = {}
    for _, kind in ipairs(kinds) do
        local f = kind_field(kind)
        for _, ctype in ipairs(COLUMN_TYPES) do
            local want = EXPECTED[kind][ctype]
            local repr, conv = pb.tuple.check_compat(f, ctype)
            local got = repr ~= nil and {repr, conv} or nil
            if want == nil and got ~= nil then
                mismatches[#mismatches + 1] = string.format(
                    '%s x %s: accepted as %s/%s, expected refusal',
                    kind, ctype, repr, conv)
            elseif want ~= nil and got == nil then
                mismatches[#mismatches + 1] = string.format(
                    '%s x %s: refused, expected %s/%s',
                    kind, ctype, want[1], want[2])
            elseif want ~= nil and (want[1] ~= got[1] or want[2] ~= got[2]) then
                mismatches[#mismatches + 1] = string.format(
                    '%s x %s: %s/%s, expected %s/%s',
                    kind, ctype, got[1], got[2], want[1], want[2])
            end
        end
    end
    t.assert_equals(mismatches, {})
end

-- Every well-known type with a descriptor-level encode/decode other than
-- Timestamp -- Any included, though its descriptor also lists fields --
-- binds only raw, to a varbinary column.
gc.test_well_known_types_bind_only_raw = function()
    local names = {}
    for k, d in pairs(pb.wkt) do
        if type(d) == 'table' and k:match('_descriptor$')
                and (d.encode ~= nil or d.decode ~= nil)
                and d.name ~= 'google.protobuf.Timestamp' then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    t.assert_equals(#names, 16)
    local mismatches = {}
    for _, k in ipairs(names) do
        local f = {name = 'f', id = 1, kind = 'message',
                   message = pb.wkt[k]}
        for _, ctype in ipairs(COLUMN_TYPES) do
            local repr, conv = pb.tuple.check_compat(f, ctype)
            local want = ctype == 'varbinary' and 'raw/direct' or 'refused'
            local got = repr ~= nil and (repr .. '/' .. conv) or 'refused'
            if got ~= want then
                mismatches[#mismatches + 1] = string.format('%s x %s: %s',
                    pb.wkt[k].name, ctype, got)
            end
        end
        -- no element or map value representation either
        local r = {name = 'f', id = 1, kind = 'message', message = pb.wkt[k],
                   ['repeated'] = true}
        local m = {name = 'f', id = 1, kind = 'map',
                   key = {kind = 'scalar', proto_type = 'string'},
                   value = {kind = 'message', message = pb.wkt[k]}}
        for _, ctype in ipairs({'array', 'map', 'any'}) do
            if pb.tuple.check_compat(r, ctype) ~= nil
                    or pb.tuple.check_compat(m, ctype) ~= nil then
                mismatches[#mismatches + 1] = pb.wkt[k].name
                    .. ' as an element in ' .. ctype
            end
        end
    end
    t.assert_equals(mismatches, {})
end

gc.test_any_binds_only_raw = function()
    helper.ensure_box()
    local m = pb.parse([[
        syntax = "proto3";
        package bind_any;
        import "google/protobuf/any.proto";
        message E { uint64 id = 1; google.protobuf.Any detail = 2; }
        message W { uint64 id = 1; E e = 2; }
    ]])
    for _, ctype in ipairs({'map', 'array', 'any'}) do
        local s = helper.make_space('tuple_any', {
            {name = 'id', type = 'unsigned'},
            {name = 'detail', type = ctype, is_nullable = true},
        })
        t.assert_error_msg_contains(
            "field 'detail' (google.protobuf.Any) of bind_any.E cannot "
                .. "bind to column 'detail' (" .. ctype .. ')',
            pb.tuple.bind, m.E_descriptor, s)
    end
    local s = helper.make_space('tuple_any', {
        {name = 'id', type = 'unsigned'},
        {name = 'detail', type = 'varbinary', is_nullable = true},
    })
    local conv = pb.tuple.bind(m.E_descriptor, s)
    t.assert_equals(conv.plan.repr[2], 'raw')
    local any = pb.encode(m.E_descriptor, {id = 1, detail = {
        type_url = 'type.googleapis.com/x', value = 'v'}})
    t.assert_equals(conv:encode(conv:decode(any)), any)
    -- nested, where every slot is untyped
    local ws = helper.make_space('tuple_any_w', {
        {name = 'id', type = 'unsigned'},
        {name = 'e', type = 'map', is_nullable = true},
    })
    t.assert_error_msg_contains(
        "field 'detail' (google.protobuf.Any) of bind_any.E has no tuple "
            .. 'representation', pb.tuple.bind, m.W_descriptor, ws)
end

-- Every column type in the matrix is one Tarantool accepts in a format,
-- so the matrix is not testing names no space can have.
gc.test_column_types_are_real = function()
    helper.ensure_box()
    for _, ctype in ipairs(COLUMN_TYPES) do
        local s = helper.make_space('tuple_types', {
            {name = 'id', type = 'unsigned'},
            {name = 'c',  type = ctype, is_nullable = true},
        })
        t.assert_equals(s:format()[2].type, ctype)
    end
end

-- ---------------------------------------------------------------------
-- Descriptors built at run time
-- ---------------------------------------------------------------------

local gd = t.group('tuple_bind.dynamic')

gd.before_all(function() helper.ensure_box() end)

gd.test_parsed_descriptor_binds = function()
    local m = pb.parse([[
        syntax = "proto3";
        message M { int32 a = 1; string b = 2; }
    ]])
    local d = m.M_descriptor
    t.assert_is(d.field_by_name, nil, 'pb.parse builds no field_by_name')
    local s = helper.make_space('tuple_parsed', {
        {name = 'a',     type = 'integer'},
        {name = 'b_col', type = 'string'},
    })
    local p = pb.tuple.bind(d, s, {columns = {b = 'b_col'}}).plan
    t.assert_equals(p.name, {'a', 'b'})
    t.assert_equals(p.column, {1, 2})
    t.assert_is(d.field_by_name, nil, 'bind leaves the descriptor alone')
    t.assert_error_msg_contains("columns: M has no field 'c'",
        pb.tuple.bind, d, s, {columns = {c = 'b_col'}})
    t.assert_error_msg_contains("omit: M has no field 'c'",
        pb.tuple.bind, d, s, {omit = {'c'}})
end

-- Oneof membership survives into the plan: a oneof and two proto3
-- `optional` fields bound to the same columns must not compile alike.
gd.test_oneof_groups_are_in_the_plan = function()
    local m = pb.parse([[
        syntax = "proto3";
        message Inner {
            oneof pick { int32 p = 1; string q = 2; }
        }
        message M {
            int32 id = 1;
            oneof choice { int32 a = 2; string b = 3; }
            optional int32 c = 4;
            optional int32 d = 5;
            oneof other { bool x = 6; }
            Inner inner = 7;
        }
    ]])
    local s = helper.make_space('tuple_oneof', {
        {name = 'id',    type = 'integer'},
        {name = 'a',     type = 'integer', is_nullable = true},
        {name = 'b',     type = 'string',  is_nullable = true},
        {name = 'c',     type = 'integer', is_nullable = true},
        {name = 'd',     type = 'integer', is_nullable = true},
        {name = 'x',     type = 'boolean', is_nullable = true},
        {name = 'inner', type = 'map',     is_nullable = true},
    })
    local p = pb.tuple.bind(m.M_descriptor, s).plan
    t.assert_equals(p.name, {'id', 'a', 'b', 'c', 'd', 'x', 'inner'})
    t.assert_equals(p.oneof, {0, 1, 1, 0, 0, 2, 0})
    t.assert_equals(p.oneof_names, {'choice', 'other'})
    t.assert_equals(p.optional, {false, true, true, true, true, true, false})
    local inner = p.sub[7]
    t.assert_equals(inner.oneof, {1, 1})
    t.assert_equals(inner.oneof_names, {'pick'})

    -- A message without oneofs still carries the (empty) arrays.
    local s2 = helper.make_space('tuple_kv', KV_FORMAT)
    local kv = require('runtime.kv.kv_pb')
    local p2 = pb.tuple.bind(kv.KeyValue_descriptor, s2,
                             {columns = {lease = 'lease_id'}}).plan
    t.assert_equals(p2.oneof, {0, 0, 0, 0, 0, 0})
    t.assert_equals(p2.oneof_names, {})
end

gd.test_descriptor_set_binds = function()
    local fio = require('fio')
    local root = fio.abspath(fio.pathjoin(
        fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
    local out = fio.pathjoin(fio.tempdir(), 'kv.descpb')
    local cmd = string.format(
        'protoc --descriptor_set_out=%q -I %q -I %q %q', out,
        fio.pathjoin(root, 'examples', 'proto'), fio.pathjoin(root, 'options'),
        fio.pathjoin(root, 'examples', 'proto', 'kv.proto'))
    local rc = os.execute(cmd)
    t.assert(rc == 0 or rc == true, cmd)
    local f = assert(io.open(out, 'rb'))
    local bytes = f:read('*a')
    f:close()
    local set = pb.from_pb(bytes)
    local d = set.lookup('kv.KeyValue')
    t.assert_not_equals(d, nil)
    local s = helper.make_space('tuple_kv', KV_FORMAT)
    local p = pb.tuple.bind(d, s, {columns = {lease = 'lease_id'}}).plan
    t.assert_equals(p.column, {1, 2, 3, 4, 5, 6})
end
