-- pb.tuple — bind a protobuf message descriptor to a Tarantool space
-- format, so tuples convert to wire bytes and back without a Lua table
-- per row.
--
--   local conv = pb.tuple.bind(desc, space,
--       {columns = {lease = 'lease_id'}, omit = {'value'}})
--
-- `bind` is the only code that maps descriptor fields to columns and
-- checks their compatibility. Every descriptor/format mismatch raises
-- here; conversion-time errors are limited to per-value checks. The
-- conversion paths (Lua and C) execute the plan `bind` produces and never
-- consult the descriptor or the format on their own.
--
-- Binding rules
-- -------------
-- * Top-level proto fields bind to columns by name, renamed through
--   `opts.columns` ({[proto_field_name] = column_name}); `opts.omit`
--   drops proto fields from the projection. A bound field with no column
--   is a bind error.
-- * A column with no proto field is ignored by encode. Decode writes nil
--   into it when it is nullable; non-nullable ones are listed in
--   `plan.unbound_nonnull` and decode raises naming them.
-- * A singular message field's representation follows its column type
--   (`map`/`any` -> map keyed by field name, `array` -> array positioned
--   by field number, `varbinary` -> raw wire bytes). Every deeper level,
--   and every element of a `repeated` or `map<K,V>` field, is a map keyed
--   by field name.
-- * A field with explicit presence needs a nullable column: absence has
--   to be representable, and NULL is how it is represented. Explicit
--   presence means proto3 `optional`, a oneof member, or a singular
--   message field (google.protobuf.Timestamp included).
-- * A proto `string`/`bytes` field bound to a `uuid` column needs a
--   nullable column as well: an empty value is not a uuid, so the proto3
--   default '' is stored as NULL.
-- * Nested slots are untyped, so a nested field is checked as if its
--   column were `any`: its values are checked one by one at conversion.
--   A `number` column is checked per value too: besides integers and
--   floats it holds decimals, which a double/float field refuses.
--
-- The plan (IF2)
-- --------------
-- One node per message level. Per-field data is held in parallel arrays,
-- 1-based, in ascending field-number order, dense (no nil holes: an
-- absent value is `false`, `''` or 0 as noted):
--
--   node = {
--     message  = 'pkg.Msg',       -- full message name, for error messages
--     layout   = 'tuple' | 'map' | 'array',
--                                  -- how this level is laid out: the tuple
--                                  -- itself, a map keyed by field name, or
--                                  -- an array positioned by field number
--     n        = <int>,           -- number of bound fields
--     field_no = {<int>},         -- proto field number
--     name     = {<string>},      -- proto field name (the key in a map layout)
--     column   = {<int>},         -- tuple layout: 1-based tuple field number;
--                                  -- array layout: array index (= field_no);
--                                  -- map layout: 0
--     column_name = {<string>},   -- tuple layout: column name; else ''
--     column_type = {<string>},   -- tuple layout: the column's field type,
--                                  -- aliases normalized ('*' -> 'any',
--                                  -- 'num' -> 'unsigned', 'str' -> 'string');
--                                  -- nested layouts: 'any'
--     kind     = {<string>},      -- proto scalar type ('int32', 'bytes', ...),
--                                  -- 'enum', 'message', 'timestamp'
--                                  -- (google.protobuf.Timestamp, a datetime
--                                  -- value in tuples, not a sub-node) or
--                                  -- 'map'; for a repeated field, the
--                                  -- element kind
--     repeated = {<bool>},
--     packed   = {<bool>},        -- repeated scalar written packed
--     repr     = {<string>},      -- representation of the value in its slot:
--                                  --   'scalar'    single value
--                                  --   'msg_map'   message as a map keyed by name
--                                  --   'msg_array' message as an array positioned
--                                  --               by field number, holes nil
--                                  --   'raw'       message as its wire bytes
--                                  --   'list'      repeated field: an array of
--                                  --               elements (scalars, datetime
--                                  --               for Timestamp, msg_map maps)
--                                  --   'dict'      map<K,V>: a map of values
--                                  --               (scalars or msg_map maps)
--     conv     = {<string>},      -- conversion code, see COMPAT below
--     nullable = {<bool>},        -- the slot may hold nil (always true nested)
--     optional = {<bool>},        -- explicit presence: proto3 `optional` or a
--                                  -- oneof member (encode even when default)
--     key_kind   = {<string>},    -- map<K,V>: key proto type; else ''
--     value_kind = {<string>},    -- map<K,V>: value kind (as `kind`); else ''
--     sub      = {<node|false>},  -- child node of a message-typed field, of a
--                                  -- repeated message's elements, or of a map's
--                                  -- message values; false otherwise
--     oneof    = {<int>},         -- 0 when the field is in no oneof, else the
--                                  -- 1-based index into oneof_names of its group
--     oneof_names = {<string>},   -- per node: the oneof groups' names, in
--                                  -- order of their lowest-numbered member
--     oneof_member_no    = {<int>}, -- every member of those groups, bound
--                                    -- or not (an omitted member still
--                                    -- unsets its siblings on decode), by
--                                    -- field number, ascending
--     oneof_member_group = {<int>}, -- its 1-based index into oneof_names
--     unbound_nonnull      = {<int>},    -- tuple layout: non-nullable columns
--                                         -- with no proto field; else {}
--     unbound_nonnull_name = {<string>}, -- their names
--   }
--
-- Map-layout nodes are shared per descriptor within one plan, so a
-- recursive message yields a cyclic plan (the node is its own `sub`).
--
-- The converter
-- -------------
--   conv.plan            the top-level node
--   conv._tplan          the plan compiled for the C encoder
--                        (pb.c_runtime.tuple_compile); present when the C
--                        runtime is loaded (PB_ENABLE_C=1), and then
--                        conv:encode / conv:encode_repeated run in C
--   conv.schema_version  box schema version the plan was compiled against
--   conv:_check_schema() rebinds when the schema version moved; raises when
--                        the space is gone (a space is its id and name
--                        together: another space that reuses the id is
--                        not the bound one) or its new format no longer
--                        binds
--   conv:encode(tuple)   -> wire bytes of the message the tuple holds
--   conv:encode_repeated(field_no, tuples)
--                        -> for each tuple: the tag of `field_no` (LEN), the
--                           length, the encoded tuple. Splices rows into an
--                           enclosing message as a `repeated` field.
--   conv:decode(bytes)   -> box.tuple laid out per the space format
--   conv:insert(bytes), conv:replace(bytes)
--                        -> decode, then space:insert / space:replace
-- Every method first calls _check_schema.
--
-- Conversion rules
-- ----------------
-- Tuple -> wire (encode) reads the tuple's msgpack and walks the plan:
-- * Fields are written in ascending field-number order at every level,
--   whatever the key order inside the tuple's maps. (The descriptor codec
--   writes declaration order, so the tuple path does not go through it.)
-- * NULL (or a column missing from the end of the tuple) is an unset
--   field. An implicit-presence field holding its proto3 default is not
--   written; a field with explicit presence is written whenever it is not
--   NULL. Two non-NULL members of one oneof are an error.
-- * The entries of a map<K,V> field are written in the order of the keys
--   in the tuple's msgpack map. A key or value equal to its proto3 default
--   is left out of the entry (message values are always written).
-- * A `raw` message is written as tag + length + the stored bytes verbatim.
-- * Per-value checks: the msgpack type must suit the proto type (integers
--   for integer kinds, integers or floats for double/float (a decimal,
--   which a `number` or `any` column can hold, is refused rather than
--   rounded), str or bin for
--   string/bytes, a uuid for a uuid column, a datetime for Timestamp, a
--   map / array for a message or repeated field); integers must fit the
--   proto type; a key in a message map must name a field; an array
--   position with no field must be NULL; NULL is not allowed as an
--   element of a repeated field or as a map key or value.
--
-- Wire -> tuple (decode) goes through the descriptor codec, then lays the
-- decoded message out per the plan:
-- * Unknown wire fields are skipped. Defaults of implicit-presence fields
--   are written out (0, '', false, empty array, empty map), at every
--   level; an unset field with explicit presence is NULL in the tuple (a
--   missing key in a nested map). For a oneof, the last member on the wire
--   wins and the others are NULL.
-- * A `raw` column receives the field's payload bytes verbatim; a field
--   given more than once receives the payloads joined, which is protobuf's
--   merge. In a oneof, a later sibling on the wire unsets a raw member,
--   and a raw member that comes back after a sibling starts over.
-- * Values are written in the msgpack type their column needs (bin for
--   varbinary, a double for `double`, a uuid for `uuid`); in untyped
--   slots `bytes` becomes bin and `string` str. A negative integer in an
--   `unsigned` column is an error (an `integer` column holds -2^63 ..
--   2^64-1, so every proto integer fits it), as is a Timestamp outside
--   the datetime range or a string/bytes value that is not a uuid for a
--   uuid column.
-- * A map<K,V> is written in the order `pairs` yields the decoded map, so
--   a multi-key map is not guaranteed to come back in wire order.
-- * A non-nullable column with no proto field makes decode raise.
local M = {}

-- An `array` column holds a message positioned by field number, so the
-- array is as long as the largest field number. Refuse a message whose
-- largest field number exceeds this many times its field count: such an
-- array would be mostly holes.
local MAX_ARRAY_SPARSENESS = 4
M.MAX_ARRAY_SPARSENESS = MAX_ARRAY_SPARSENESS

local TIMESTAMP = 'google.protobuf.Timestamp'

-- Old spellings Tarantool still accepts in a space format and reports
-- back unchanged from space:format().
local COLUMN_TYPE_ALIAS = {
    ['*'] = 'any',
    num   = 'unsigned',
    str   = 'string',
}

-- ---------------------------------------------------------------------------
-- The compatibility table — the only place it lives.
--
-- COMPAT[<kind class>][<column type>] = {repr, conv}. A pair missing from
-- the table is a bind error. Column types not mentioned anywhere
-- (decimal, interval, and the fixed-size numeric types) bind to nothing.
--
-- Conversion codes:
--   'direct'     the column type admits exactly the values the proto type
--                needs in the tuple; no per-value check
--   'range'      integer both sides; per-value check that the value fits
--                both the proto type's and the column type's range
--   'number'     `number` column <-> double/float: the column holds integers
--                as well as floats; encode converts integers to double. It
--                holds decimals too, and encode refuses one per value:
--                a decimal is not rounded to floating point
--   'str_bin'    string <-> bytes: same wire bytes, the column holds the
--                other msgpack type (MP_STR vs MP_BIN)
--   'uuid_text'  uuid column <-> proto string, canonical 36-character text
--   'uuid_bin'   uuid column <-> proto bytes, 16 raw bytes
--   'any'        the column (or nested slot) is untyped: every value is
--                checked against the proto type at conversion time
--
-- Kind classes: a proto scalar type name, 'enum', 'timestamp'
-- (google.protobuf.Timestamp), 'message' (a message with fields),
-- 'opaque' (a well-known type whose descriptor overrides encode/decode
-- and has no fields — Duration, wrappers, Struct, Any, ...), 'repeated'
-- (any element kind) and 'map'.
-- ---------------------------------------------------------------------------

local function scalar(conv) return {'scalar', conv} end

local INTEGER = {
    unsigned = scalar('range'),
    integer  = scalar('range'),
    any      = scalar('any'),
    scalar   = scalar('any'),
}
local UNSIGNED64 = {
    unsigned = scalar('direct'),
    integer  = scalar('range'),
    any      = scalar('any'),
    scalar   = scalar('any'),
}
local FLOATING = {
    double = scalar('direct'),
    number = scalar('number'),
    any    = scalar('any'),
    scalar = scalar('any'),
}

local COMPAT = {
    int32    = INTEGER,
    int64    = INTEGER,
    uint32   = INTEGER,
    uint64   = UNSIGNED64,
    sint32   = INTEGER,
    sint64   = INTEGER,
    fixed32  = INTEGER,
    fixed64  = UNSIGNED64,
    sfixed32 = INTEGER,
    sfixed64 = INTEGER,
    enum     = INTEGER,
    double   = FLOATING,
    float    = FLOATING,
    bool = {
        boolean = scalar('direct'),
        any     = scalar('any'),
        scalar  = scalar('any'),
    },
    string = {
        string    = scalar('direct'),
        varbinary = scalar('str_bin'),
        uuid      = scalar('uuid_text'),
        any       = scalar('any'),
        scalar    = scalar('any'),
    },
    bytes = {
        varbinary = scalar('direct'),
        string    = scalar('str_bin'),
        uuid      = scalar('uuid_bin'),
        any       = scalar('any'),
        scalar    = scalar('any'),
    },
    timestamp = {
        datetime  = scalar('direct'),
        any       = scalar('any'),
        varbinary = {'raw', 'direct'},
    },
    message = {
        map       = {'msg_map', 'direct'},
        any       = {'msg_map', 'any'},
        array     = {'msg_array', 'direct'},
        varbinary = {'raw', 'direct'},
    },
    opaque = {
        varbinary = {'raw', 'direct'},
    },
    ['repeated'] = {
        array = {'list', 'direct'},
        any   = {'list', 'any'},
    },
    map = {
        map = {'dict', 'direct'},
        any = {'dict', 'any'},
    },
}

-- ---------------------------------------------------------------------------
-- Descriptor helpers
-- ---------------------------------------------------------------------------

-- Kind of a field or of a map key/value sub-field, as stored in the plan.
local function field_kind(f)
    if f.kind == 'scalar' then return f.proto_type end
    if f.kind == 'enum' then return 'enum' end
    if f.kind == 'map' then return 'map' end
    if f.kind == 'message' then
        if f.message.name == TIMESTAMP then return 'timestamp' end
        return 'message'
    end
    return f.kind
end

-- Kind class of a single value (COMPAT row), ignoring `repeated`.
local function value_class(f)
    local k = field_kind(f)
    if k == 'message' and f.message.fields == nil then return 'opaque' end
    return k
end

-- Human-readable proto type of a field, for error messages.
local function type_name(f)
    local base
    if f.kind == 'scalar' then
        base = f.proto_type
    elseif f.kind == 'enum' then
        base = 'enum ' .. f.enum.name
    elseif f.kind == 'map' then
        base = string.format('map<%s, %s>', type_name(f.key),
                             type_name(f.value))
    elseif f.message ~= nil then
        base = f.message.name
    else
        base = tostring(f.kind)
    end
    if f.repeated then return 'repeated ' .. base end
    return base
end

-- Fields of `desc` in ascending field-number order.
local function sorted_fields(desc)
    local list = {}
    for i, f in ipairs(desc.fields) do list[i] = f end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- A message descriptor from any producer: generated code, pb.parse or
-- pb.from_pb. Only `name` and `fields` are relied on; the lookup tables
-- pb.finalize_message adds (field_by_name, ...) are not built by every
-- producer.
local function is_message_desc(desc)
    return type(desc) == 'table' and type(desc.name) == 'string'
        and type(desc.fields) == 'table'
end

-- {[field name] = true} for the fields of `desc`.
local function field_name_set(desc)
    local set = {}
    for _, f in ipairs(desc.fields) do set[f.name] = true end
    return set
end

-- ---------------------------------------------------------------------------
-- check_compat
-- ---------------------------------------------------------------------------

-- Look up the representation and conversion code for descriptor field `f`
-- stored in a column (or nested slot) of type `column_type`. Returns
-- repr, conv; or nil, reason when the pair is not in COMPAT.
local function check_compat(f, column_type)
    local class = f.repeated and 'repeated' or value_class(f)
    local row = COMPAT[class]
    local entry = row and row[column_type]
    if entry == nil then
        return nil, 'incompatible'
    end
    -- Elements of a repeated field and values of a map sit in untyped
    -- slots: they must be representable in an `any` slot.
    if f.repeated then
        local elem = COMPAT[value_class(f)]
        if elem == nil or elem.any == nil then
            return nil, 'element'
        end
    elseif f.kind == 'map' then
        local vrow = COMPAT[value_class(f.value)]
        local krow = COMPAT[value_class(f.key)]
        if vrow == nil or vrow.any == nil or krow == nil
                or krow.any == nil then
            return nil, 'element'
        end
    end
    return entry[1], entry[2]
end
M.check_compat = check_compat

-- ---------------------------------------------------------------------------
-- compile_node
-- ---------------------------------------------------------------------------

local function new_node(desc, layout)
    return {
        message = desc.name, layout = layout, n = 0,
        field_no = {}, name = {}, column = {}, column_name = {},
        column_type = {}, kind = {}, ['repeated'] = {}, packed = {},
        repr = {}, conv = {}, nullable = {}, optional = {},
        key_kind = {}, value_kind = {}, sub = {},
        oneof = {}, oneof_names = {},
        oneof_member_no = {}, oneof_member_group = {},
        unbound_nonnull = {}, unbound_nonnull_name = {},
    }
end

-- Record every member of the node's oneof groups, bound or not: on
-- decode, any member on the wire unsets the others. Groups with no bound
-- member have nothing to unset and are left out.
local function add_oneof_members(node, desc)
    local names = node.oneof_names
    for _, f in ipairs(sorted_fields(desc)) do
        if f.oneof ~= nil then
            for j = 1, #names do
                if names[j] == f.oneof then
                    local k = #node.oneof_member_no + 1
                    node.oneof_member_no[k] = f.id
                    node.oneof_member_group[k] = j
                    break
                end
            end
        end
    end
end

-- 1-based index of oneof `name` in node.oneof_names, registering it on
-- first sight. Fields are added in ascending field-number order, so a
-- group's index follows its lowest-numbered member.
local function oneof_index(node, name)
    local names = node.oneof_names
    for j = 1, #names do
        if names[j] == name then return j end
    end
    names[#names + 1] = name
    return #names
end

local function has_presence(f)
    return f.optional == true or f.oneof ~= nil
end

local compile_node

-- Descriptor of the message a field's sub-node describes, or nil.
local function sub_message(f)
    if f.kind == 'message' and f.message.fields ~= nil
            and f.message.name ~= TIMESTAMP then
        return f.message
    end
    if f.kind == 'map' and f.value.kind == 'message'
            and f.value.message.fields ~= nil
            and f.value.message.name ~= TIMESTAMP then
        return f.value.message
    end
    return nil
end

local function bind_error(fmt, ...)
    error('pb.tuple: ' .. string.format(fmt, ...), 0)
end

-- Append field `f` to `node`. `slot` = {column, column_name, column_type,
-- nullable} describes where its value lives.
local function add_field(node, desc, f, slot, cache)
    local repr, conv = check_compat(f, slot.column_type)
    if repr == nil then
        if conv == 'element' then
            bind_error("field '%s' (%s) of %s has no tuple representation "
                .. "for its elements", f.name, type_name(f), desc.name)
        end
        if slot.column_name ~= '' then
            bind_error("field '%s' (%s) of %s cannot bind to column '%s' (%s)",
                       f.name, type_name(f), desc.name, slot.column_name,
                       slot.column_type)
        end
        bind_error("field '%s' (%s) of %s has no tuple representation",
                   f.name, type_name(f), desc.name)
    end
    if has_presence(f) and not slot.nullable then
        bind_error("optional field '%s' of %s needs a nullable column, "
                   .. "column '%s' is not nullable", f.name, desc.name,
                   slot.column_name)
    end
    -- A singular message field has explicit presence in proto3 too.
    if f.kind == 'message' and not f.repeated and not slot.nullable then
        bind_error("message field '%s' of %s needs a nullable column, "
                   .. "column '%s' is not nullable", f.name, desc.name,
                   slot.column_name)
    end
    -- An empty string/bytes value is not a uuid, so it is stored as NULL.
    if (conv == 'uuid_text' or conv == 'uuid_bin') and not slot.nullable then
        bind_error("field '%s' of %s is bound to uuid column '%s', which "
                   .. 'must be nullable: an empty value is stored as NULL',
                   f.name, desc.name, slot.column_name)
    end

    local sub = false
    local msg = sub_message(f)
    if msg ~= nil and repr ~= 'raw' then
        if repr == 'msg_array' then
            local max_id = 0
            for _, sf in ipairs(msg.fields) do
                if sf.id > max_id then max_id = sf.id end
            end
            if max_id > MAX_ARRAY_SPARSENESS * #msg.fields then
                bind_error("field '%s' of %s: %s is too sparse for an array "
                           .. "column (max field number %d, %d fields)",
                           f.name, desc.name, msg.name, max_id, #msg.fields)
            end
            sub = compile_node(msg, nil, 1, 'array', cache)
        else
            sub = compile_node(msg, nil, 1, 'map', cache)
        end
    end

    local i = node.n + 1
    node.n = i
    node.field_no[i] = f.id
    node.name[i] = f.name
    node.column[i] = slot.column
    node.column_name[i] = slot.column_name
    node.column_type[i] = slot.column_type
    node.kind[i] = field_kind(f)
    node['repeated'][i] = f.repeated == true
    node.packed[i] = f.packed == true
    node.repr[i] = repr
    node.conv[i] = conv
    node.nullable[i] = slot.nullable
    node.optional[i] = has_presence(f)
    if f.kind == 'map' then
        node.key_kind[i] = field_kind(f.key)
        node.value_kind[i] = field_kind(f.value)
    else
        node.key_kind[i] = ''
        node.value_kind[i] = ''
    end
    node.sub[i] = sub
    node.oneof[i] = f.oneof ~= nil and oneof_index(node, f.oneof) or 0
end

-- Compile the plan node for one message level.
--   desc    message descriptor
--   format  the space format for the top level (depth 0); nil below
--   depth   0 for the tuple itself, 1+ for nested levels
--   layout  'tuple' at depth 0; 'map' or 'array' below
--   cache   {[desc] = node} for map-layout nodes of this plan
--   opts    normalized bind options plus `space_name` (depth 0 only)
compile_node = function(desc, format, depth, layout, cache, opts)
    if layout == 'map' and cache[desc] ~= nil then
        return cache[desc]
    end
    local node = new_node(desc, layout)
    if layout == 'map' then
        -- Registered before the children compile, so a recursive message
        -- refers back to this node.
        cache[desc] = node
    end

    if depth > 0 then
        for _, f in ipairs(sorted_fields(desc)) do
            add_field(node, desc, f, {
                column      = layout == 'array' and f.id or 0,
                column_name = '',
                column_type = 'any',
                nullable    = true,
            }, cache)
        end
        add_oneof_members(node, desc)
        return node
    end

    local by_name = {}
    for i, e in ipairs(format) do
        by_name[e.name] = i
    end
    local bound = {}
    for _, f in ipairs(sorted_fields(desc)) do
        if not opts.omit[f.name] then
            local cname = opts.columns[f.name] or f.name
            local col = by_name[cname]
            if col == nil then
                bind_error("field '%s' of %s has no column '%s' in space '%s'",
                           f.name, desc.name, cname, opts.space_name)
            end
            if bound[col] ~= nil then
                bind_error("fields '%s' and '%s' of %s both bind to column '%s'",
                           bound[col], f.name, desc.name, cname)
            end
            bound[col] = f.name
            local e = format[col]
            local ctype = e.type
            ctype = COLUMN_TYPE_ALIAS[ctype] or ctype
            add_field(node, desc, f, {
                column      = col,
                column_name = cname,
                column_type = ctype,
                nullable    = e.is_nullable == true,
            }, cache)
        end
    end
    add_oneof_members(node, desc)
    for i, e in ipairs(format) do
        if bound[i] == nil and e.is_nullable ~= true then
            local k = #node.unbound_nonnull + 1
            node.unbound_nonnull[k] = i
            node.unbound_nonnull_name[k] = e.name
        end
    end
    return node
end

M.compile_node = compile_node

-- ---------------------------------------------------------------------------
-- bind
-- ---------------------------------------------------------------------------

local function schema_version()
    local internal = box.internal
    if internal == nil or internal.schema_version == nil then
        error('pb.tuple: box.internal.schema_version() is not available '
              .. 'in this Tarantool', 0)
    end
    return internal.schema_version()
end

local KNOWN_OPTS = {columns = true, omit = true}

-- Validate and normalize bind options against `desc`.
local function normalize_opts(desc, opts)
    if opts == nil then opts = {} end
    if type(opts) ~= 'table' then
        bind_error('opts must be a table, got %s', type(opts))
    end
    for k in pairs(opts) do
        if not KNOWN_OPTS[k] then
            bind_error("unknown option '%s'", tostring(k))
        end
    end
    local known = field_name_set(desc)
    local columns, omit = {}, {}
    if opts.columns ~= nil then
        if type(opts.columns) ~= 'table' then
            bind_error('columns must be a table, got %s', type(opts.columns))
        end
        for field, column in pairs(opts.columns) do
            if known[field] == nil then
                bind_error("columns: %s has no field '%s'", desc.name,
                           tostring(field))
            end
            if type(column) ~= 'string' or column == '' then
                bind_error("columns: column name for field '%s' must be a "
                           .. 'non-empty string', field)
            end
            columns[field] = column
        end
    end
    if opts.omit ~= nil then
        local list = opts.omit
        if type(list) ~= 'table' then
            bind_error('omit must be an array of field names, got %s',
                       type(list))
        end
        -- A proper sequence: keys exactly 1..n. A hash key or a hole
        -- would otherwise be skipped by ipairs without a word.
        local count = 0
        for _ in pairs(list) do count = count + 1 end
        for i = 1, count do
            if list[i] == nil then
                bind_error('omit must be an array of field names '
                           .. '(keys 1..n with no holes)')
            end
        end
        for i = 1, count do
            local field = list[i]
            if type(field) ~= 'string' then
                bind_error('omit: field names must be strings, got %s',
                           type(field))
            end
            if known[field] == nil then
                bind_error("omit: %s has no field '%s'", desc.name, field)
            end
            if omit[field] then
                bind_error("omit: field '%s' is listed twice", field)
            end
            if columns[field] ~= nil then
                bind_error("field '%s' is both renamed and omitted", field)
            end
            omit[field] = true
        end
    end
    return {columns = columns, omit = omit}
end

local Conv = {}
Conv.__index = Conv

-- The C encoder, loaded under the switch pb/init.lua uses: PB_ENABLE_C=1
-- and pb.c_runtime loadable.
local c_runtime
if os.getenv('PB_ENABLE_C') == '1' then
    local ok, mod = pcall(require, 'pb.c_runtime')
    if ok then c_runtime = mod end
end

-- Compile the top-level plan of `conv` against `space`'s current format.
local function compile_plan(conv, space)
    local opts = {columns = conv.opts.columns, omit = conv.opts.omit,
                  space_name = space.name}
    return compile_node(conv.desc, space:format(), 0, 'tuple', {}, opts)
end

-- Install `plan` on `conv`; the only place conv.plan is assigned, so the
-- C plan is recompiled whenever the Lua plan is rebuilt.
local function set_plan(conv, plan)
    if c_runtime ~= nil then
        if c_runtime.tuple_compile == nil then
            error('pb.tuple: the loaded pb.c_runtime has no tuple encoder; '
                  .. 'rebuild it', 0)
        end
        conv._tplan = c_runtime.tuple_compile(plan, conv.desc)
    end
    conv.plan = plan
end

-- Rebind when the box schema changed since the plan was compiled.
function Conv:_check_schema()
    local version = schema_version()
    if version == self.schema_version then
        return
    end
    -- A space is identified by (id, name): an id freed by a drop can be
    -- reused by an unrelated space, which must not be rebound silently.
    local space = box.space[self.space_id]
    if space == nil or space.name ~= self.space_name then
        error(string.format("pb.tuple: space '%s' no longer exists (id %d)",
                            self.space_name, self.space_id), 0)
    end
    local ok, plan = pcall(compile_plan, self, space)
    if not ok then
        error(string.format("pb.tuple: the format of space '%s' changed and "
                            .. 'no longer binds %s: %s', space.name,
                            self.desc.name, tostring(plan)), 0)
    end
    set_plan(self, plan)
    self.schema_version = version
end

function M.bind(desc, space, opts)
    if not is_message_desc(desc) then
        bind_error('expected a message descriptor, got %s',
                   type(desc) == 'table' and tostring(desc.name) or type(desc))
    end
    if type(space) ~= 'table' or type(space.id) ~= 'number'
            or type(space.format) ~= 'function' then
        bind_error('expected a space object, got %s', type(space))
    end
    local conv = setmetatable({
        desc       = desc,
        opts       = normalize_opts(desc, opts),
        space_id   = space.id,
        space_name = space.name,
    }, Conv)
    conv.schema_version = schema_version()
    set_plan(conv, compile_plan(conv, space))
    return conv
end

-- ===========================================================================
-- Conversion through the Lua codec
--
-- The reference implementation of the conversion rules in the header. It
-- walks the tuple's msgpack itself (a Lua table would lose the key order
-- of maps) and writes the wire bytes with pb.wire's typed helpers in plan
-- order. Everything here iterates the plan's arrays with a numeric `for`.
-- ===========================================================================

local ffi      = require('ffi')
local msgpack  = require('msgpack')
local uuid     = require('uuid')
local datetime = require('datetime')
local codec    = require('pb.codec')
local wire     = require('pb.wire')
local wkt      = require('pb.wkt')

local NULL = box.NULL
local byte, sub = string.byte, string.sub
local concat = table.concat
local encode_varint = wire.encode_varint
local encode_tag = wire.encode_tag
local TYPE_INFO = wire.TYPE_INFO
local WIRE_VARINT, WIRE_LEN = wire.WIRE_VARINT, wire.WIRE_LEN
local RECURSION_LIMIT = wire.RECURSION_LIMIT
local MAX_FIELD_NO = 536870911  -- 2^29 - 1

local MAP_MT = {__serialize = 'map'}
local ARRAY_MT = {__serialize = 'array'}

-- MP_BIN can only be produced from Lua through the varbinary module
-- (Tarantool 3.0+). Loaded on first use, so `require('pb')` keeps working
-- where it is missing; decoding into a binary slot there raises.
local varbinary
local function to_varbinary(s)
    if varbinary == nil then
        local ok, mod = pcall(require, 'varbinary')
        if not ok then
            error('pb.tuple: writing binary data into a tuple needs the '
                  .. 'varbinary module (Tarantool 3.0 or later)', 0)
        end
        varbinary = mod
    end
    return varbinary.new(s)
end

-- ---------------------------------------------------------------------------
-- msgpack reading
-- ---------------------------------------------------------------------------

local MP_NIL, MP_BOOL, MP_UINT, MP_INT, MP_FLOAT, MP_STR, MP_BIN, MP_ARRAY,
      MP_MAP, MP_EXT = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
local MP_CLASS_NAME = {'nil', 'boolean', 'unsigned integer', 'integer',
                       'float', 'string', 'binary', 'array', 'map'}
local MP_EXT_DECIMAL, MP_EXT_UUID, MP_EXT_DATETIME = 1, 2, 4
local MP_EXT_NAME = {[1] = 'decimal', [2] = 'uuid', [3] = 'error',
                     [4] = 'datetime', [6] = 'interval'}

local function be16(s, p)
    local a, b = byte(s, p, p + 1)
    return a * 0x100 + b
end

local function be32(s, p)
    local a, b, c, d = byte(s, p, p + 3)
    return ((a * 0x100 + b) * 0x100 + c) * 0x100 + d
end

local function ext_type(s, p)
    local x = byte(s, p)
    if x >= 0x80 then x = x - 0x100 end
    return x
end

-- Head of the msgpack value at s[p]: class, n, body[, ext type].
--   str/bin: n = byte length, body = first payload byte
--   array/map: n = element / pair count, body = first element
--   ext: n = payload length, body = first payload byte
--   scalars: n = 0, body = p (read them with msgpack.decode)
local function mp_head(s, p)
    local c = byte(s, p)
    if c <= 0x7f then return MP_UINT, 0, p end
    if c <= 0x8f then return MP_MAP, c - 0x80, p + 1 end
    if c <= 0x9f then return MP_ARRAY, c - 0x90, p + 1 end
    if c <= 0xbf then return MP_STR, c - 0xa0, p + 1 end
    if c >= 0xe0 then return MP_INT, 0, p end
    if c == 0xc0 then return MP_NIL, 0, p end
    if c == 0xc2 or c == 0xc3 then return MP_BOOL, 0, p end
    if c == 0xc4 then return MP_BIN, byte(s, p + 1), p + 2 end
    if c == 0xc5 then return MP_BIN, be16(s, p + 1), p + 3 end
    if c == 0xc6 then return MP_BIN, be32(s, p + 1), p + 5 end
    if c == 0xc7 then return MP_EXT, byte(s, p + 1), p + 3, ext_type(s, p + 2) end
    if c == 0xc8 then return MP_EXT, be16(s, p + 1), p + 4, ext_type(s, p + 3) end
    if c == 0xc9 then return MP_EXT, be32(s, p + 1), p + 6, ext_type(s, p + 5) end
    if c == 0xca or c == 0xcb then return MP_FLOAT, 0, p end
    if c <= 0xcf then return MP_UINT, 0, p end
    if c <= 0xd3 then return MP_INT, 0, p end
    if c <= 0xd8 then
        return MP_EXT, bit.lshift(1, c - 0xd4), p + 2, ext_type(s, p + 1)
    end
    if c == 0xd9 then return MP_STR, byte(s, p + 1), p + 2 end
    if c == 0xda then return MP_STR, be16(s, p + 1), p + 3 end
    if c == 0xdb then return MP_STR, be32(s, p + 1), p + 5 end
    if c == 0xdc then return MP_ARRAY, be16(s, p + 1), p + 3 end
    if c == 0xdd then return MP_ARRAY, be32(s, p + 1), p + 5 end
    if c == 0xde then return MP_MAP, be16(s, p + 1), p + 3 end
    if c == 0xdf then return MP_MAP, be32(s, p + 1), p + 5 end
    error(string.format('pb.tuple: invalid msgpack byte 0x%02x', c), 0)
end

-- Byte size of a msgpack scalar by its first byte, for the codes whose
-- size is not in their head (fixints, nil and booleans are 1 byte).
local MP_SCALAR_SIZE = {
    [0xca] = 5, [0xcb] = 9,
    [0xcc] = 2, [0xcd] = 3, [0xce] = 5, [0xcf] = 9,
    [0xd0] = 2, [0xd1] = 3, [0xd2] = 5, [0xd3] = 9,
}

-- Position just past the msgpack value at s[p]. Walks the structure
-- without decoding anything: a value no field reads is never
-- materialized, and an extension type Tarantool's Lua decoder does not
-- know is as skippable as any other.
local function mp_next(s, p)
    local pending = 1
    while pending > 0 do
        pending = pending - 1
        local cls, n, body = mp_head(s, p)
        if cls == MP_ARRAY then
            pending = pending + n
            p = body
        elseif cls == MP_MAP then
            pending = pending + 2 * n
            p = body
        elseif cls == MP_STR or cls == MP_BIN or cls == MP_EXT then
            p = body + n
        else
            p = p + (MP_SCALAR_SIZE[byte(s, p)] or 1)
        end
    end
    return p
end

local function class_name(cls, ext)
    if cls == MP_EXT then
        return MP_EXT_NAME[ext] or ('extension type ' .. tostring(ext))
    end
    return MP_CLASS_NAME[cls]
end

-- ---------------------------------------------------------------------------
-- Per-value errors
-- ---------------------------------------------------------------------------

-- `elem` narrows the location inside field i: nil (the field's own
-- value), an element index of a repeated field, or 'map key' /
-- 'map value'.
local function value_error(node, i, elem, fmt, ...)
    local col = node.column_name[i]
    local where
    if col ~= '' then
        where = string.format("field '%s' of %s (column '%s')",
                              node.name[i], node.message, col)
    else
        where = string.format("field '%s' of %s", node.name[i], node.message)
    end
    if type(elem) == 'number' then
        where = where .. ': element ' .. elem
    elseif elem ~= nil then
        where = where .. ': ' .. elem
    end
    error('pb.tuple: ' .. where .. ': ' .. string.format(fmt, ...), 0)
end

local function type_error(node, i, elem, what, cls, ext)
    value_error(node, i, elem, 'expected %s, got %s', what,
                class_name(cls, ext))
end

-- ---------------------------------------------------------------------------
-- Scalars
-- ---------------------------------------------------------------------------

local I32_MIN, I32_MAX = -2147483648, 2147483647
local U32_MAX = 4294967295
local I64_MAX = 9223372036854775807ULL

-- Integer kinds and the range their values must fit.
local INT_RANGE = {
    int32 = 's32', sint32 = 's32', sfixed32 = 's32', enum = 's32',
    uint32 = 'u32', fixed32 = 'u32',
    int64 = 's64', sint64 = 's64', sfixed64 = 's64',
    uint64 = 'u64', fixed64 = 'u64',
}

-- Whether integer `v`, read from a msgpack value of class `cls`, fits
-- `range`. MP_UINT values are never negative (possibly uint64 cdata), so
-- only their upper bound is checked; comparing a uint64 cdata against a
-- negative bound would convert the bound to uint64.
local function int_fits(range, v, cls)
    if range == 's32' then
        if cls == MP_UINT then return v <= I32_MAX end
        return v >= I32_MIN and v <= I32_MAX
    elseif range == 'u32' then
        if cls == MP_UINT then return v <= U32_MAX end
        return v >= 0 and v <= U32_MAX
    elseif range == 's64' then
        if cls == MP_UINT then return v <= I64_MAX end
        return true
    end
    return cls == MP_UINT or v >= 0
end

-- Read the msgpack value at s[p] as a value of proto scalar `kind` bound
-- with conversion `conv`. Returns the value in the form pb.wire's encoder
-- for `kind` takes, and the position past it.
local function read_scalar(node, i, elem, kind, conv, s, p)
    local cls, n, body, ext = mp_head(s, p)
    local range = INT_RANGE[kind]
    if range ~= nil then
        if cls ~= MP_UINT and cls ~= MP_INT then
            type_error(node, i, elem, 'an integer', cls, ext)
        end
        local v, np = msgpack.decode(s, p)
        if not int_fits(range, v, cls) then
            value_error(node, i, elem, 'value %s is out of range for %s',
                        tostring(v), kind)
        end
        return v, np
    elseif kind == 'double' or kind == 'float' then
        if cls == MP_FLOAT then
            return msgpack.decode(s, p)
        elseif cls == MP_UINT or cls == MP_INT then
            local v, np = msgpack.decode(s, p)
            return tonumber(v), np
        elseif cls == MP_EXT and ext == MP_EXT_DECIMAL then
            -- A `number` column holds decimals as well; rounding one to
            -- a double would lose digits without a word.
            value_error(node, i, elem, 'expected a number, got decimal (a '
                        .. 'decimal is not converted to floating point)')
        end
        type_error(node, i, elem, 'a number', cls, ext)
    elseif kind == 'bool' then
        if cls ~= MP_BOOL then
            type_error(node, i, elem, 'a boolean', cls, ext)
        end
        return byte(s, p) == 0xc3, p + 1
    elseif kind == 'string' or kind == 'bytes' then
        if conv == 'uuid_text' or conv == 'uuid_bin' then
            if cls ~= MP_EXT or ext ~= MP_EXT_UUID or n ~= 16 then
                type_error(node, i, elem, 'a uuid', cls, ext)
            end
            -- msgpack stores a uuid as its 16 bytes in RFC 4122 order.
            local b = sub(s, body, body + 15)
            if conv == 'uuid_bin' then return b, body + 16 end
            return uuid.frombin(b, 'b'):str(), body + 16
        end
        if cls ~= MP_STR and cls ~= MP_BIN then
            type_error(node, i, elem,
                       kind == 'string' and 'a string' or 'binary data',
                       cls, ext)
        end
        return sub(s, body, body + n - 1), body + n
    end
    error('pb.tuple: no scalar conversion for kind ' .. tostring(kind), 0)
end

-- proto3 default test, for elision. -0.0 is not the default: it encodes
-- to different bytes.
local function is_default(kind, v)
    if kind == 'string' or kind == 'bytes' then return v == '' end
    if kind == 'bool' then return v == false end
    if kind == 'double' or kind == 'float' then
        return v == 0 and 1 / v > 0
    end
    return v == 0
end

-- Wire bytes of a scalar value, without the tag.
local function scalar_bytes(kind, v)
    if kind == 'enum' then return encode_varint(v) end
    return TYPE_INFO[kind].encode(v)
end

local function value_wire(kind)
    if kind == 'enum' then return WIRE_VARINT end
    local info = TYPE_INFO[kind]
    if info ~= nil then return info.wire end
    return WIRE_LEN
end

-- Timestamp body of the datetime at s[p], and the position past it.
local function read_timestamp(node, i, elem, s, p)
    local cls, _, _, ext = mp_head(s, p)
    if cls ~= MP_EXT or ext ~= MP_EXT_DATETIME then
        type_error(node, i, elem, 'a datetime', cls, ext)
    end
    local dt, np = msgpack.decode(s, p)
    return wkt.Timestamp_encode(dt), np
end

-- ---------------------------------------------------------------------------
-- Per-node lookup data for the Lua path, derived from the plan once and
-- kept beside it (weak keys: it goes away with the plan).
-- ---------------------------------------------------------------------------

local AUX = setmetatable({}, {__mode = 'k'})

local function aux_of(node)
    local a = AUX[node]
    if a ~= nil then return a end
    a = {
        tag = {},      -- [i] the field's tag (LEN for packed and messages)
        key_tag = {},  -- [i] map<K,V>: tag of an entry's key
        val_tag = {},  -- [i] map<K,V>: tag of an entry's value
        packed = {},   -- [i] repeated scalar written packed
        index = {},    -- map layout: field name -> i
        at = {},       -- array layout: array position -> i
        raw_at = {},   -- field number -> i, for `raw` fields
        oneof_at = {}, -- field number -> oneof group, for every member
        has_raw = false,
        width = 0,     -- tuple/array layout: largest column/position
    }
    for i = 1, node.n do
        local kind, repr = node.kind[i], node.repr[i]
        local info = TYPE_INFO[kind]
        local packed = repr == 'list' and node.packed[i]
            and (kind == 'enum' or (info ~= nil and info.packable))
        a.packed[i] = packed and true or false
        local wt = WIRE_LEN
        if not packed and (repr == 'scalar' or repr == 'list') then
            wt = value_wire(kind)
        end
        a.tag[i] = encode_tag(node.field_no[i], wt)
        if repr == 'dict' then
            a.key_tag[i] = encode_tag(1, value_wire(node.key_kind[i]))
            a.val_tag[i] = encode_tag(2, value_wire(node.value_kind[i]))
        end
        a.index[node.name[i]] = i
        if node.layout == 'array' then a.at[node.column[i]] = i end
        if repr == 'raw' then
            a.has_raw = true
            a.raw_at[node.field_no[i]] = i
        end
        if node.column[i] > a.width then a.width = node.column[i] end
    end
    local member_no, member_group = node.oneof_member_no, node.oneof_member_group
    for k = 1, #member_no do a.oneof_at[member_no[k]] = member_group[k] end
    AUX[node] = a
    return a
end

-- ---------------------------------------------------------------------------
-- Encode: tuple -> wire
-- ---------------------------------------------------------------------------

local encode_message
local emit_fields

local function emit_len(out, tag, body)
    local n = #out
    out[n + 1] = tag
    out[n + 2] = encode_varint(#body)
    out[n + 3] = body
end

local function emit_list(node, i, s, p, out, depth, a)
    local cls, count, q, ext = mp_head(s, p)
    if cls ~= MP_ARRAY then
        type_error(node, i, nil, 'an array', cls, ext)
    end
    if count == 0 then return end
    local kind, tag = node.kind[i], a.tag[i]
    if kind == 'message' then
        local child = node.sub[i]
        for k = 1, count do
            local body
            body, q = encode_message(child, s, q, depth + 1, node, i, k)
            emit_len(out, tag, body)
        end
    elseif kind == 'timestamp' then
        for k = 1, count do
            local body
            body, q = read_timestamp(node, i, k, s, q)
            emit_len(out, tag, body)
        end
    elseif a.packed[i] then
        local parts = {}
        for k = 1, count do
            local v
            v, q = read_scalar(node, i, k, kind, 'any', s, q)
            parts[k] = scalar_bytes(kind, v)
        end
        emit_len(out, tag, concat(parts))
    else
        for k = 1, count do
            local v
            v, q = read_scalar(node, i, k, kind, 'any', s, q)
            local n = #out
            out[n + 1] = tag
            out[n + 2] = scalar_bytes(kind, v)
        end
    end
end

-- Entries go out in the order of the keys in the msgpack map.
local function emit_dict(node, i, s, p, out, depth, a)
    local cls, count, q, ext = mp_head(s, p)
    if cls ~= MP_MAP then
        type_error(node, i, nil, 'a map', cls, ext)
    end
    local kkind, vkind = node.key_kind[i], node.value_kind[i]
    local tag, ktag, vtag = a.tag[i], a.key_tag[i], a.val_tag[i]
    for _ = 1, count do
        local entry = {}
        local k, v
        k, q = read_scalar(node, i, 'map key', kkind, 'any', s, q)
        if not is_default(kkind, k) then
            entry[1] = ktag
            entry[2] = scalar_bytes(kkind, k)
        end
        if vkind == 'message' then
            v, q = encode_message(node.sub[i], s, q, depth + 1, node, i,
                                  'map value')
            emit_len(entry, vtag, v)
        elseif vkind == 'timestamp' then
            v, q = read_timestamp(node, i, 'map value', s, q)
            emit_len(entry, vtag, v)
        else
            v, q = read_scalar(node, i, 'map value', vkind, 'any', s, q)
            if not is_default(vkind, v) then
                local n = #entry
                entry[n + 1] = vtag
                entry[n + 2] = scalar_bytes(vkind, v)
            end
        end
        emit_len(out, tag, concat(entry))
    end
end

-- Write field i, whose value at s[p] is not NULL.
local function emit_value(node, i, s, p, out, depth, a)
    local repr, kind = node.repr[i], node.kind[i]
    if repr == 'scalar' then
        if kind == 'timestamp' then
            emit_len(out, a.tag[i], (read_timestamp(node, i, nil, s, p)))
            return
        end
        local v = read_scalar(node, i, nil, kind, node.conv[i], s, p)
        if node.optional[i] or not is_default(kind, v) then
            local n = #out
            out[n + 1] = a.tag[i]
            out[n + 2] = scalar_bytes(kind, v)
        end
    elseif repr == 'msg_map' or repr == 'msg_array' then
        emit_len(out, a.tag[i],
                 (encode_message(node.sub[i], s, p, depth + 1, node, i, nil)))
    elseif repr == 'raw' then
        local cls, n, body, ext = mp_head(s, p)
        if cls ~= MP_BIN then
            type_error(node, i, nil, 'binary data', cls, ext)
        end
        emit_len(out, a.tag[i], sub(s, body, body + n - 1))
    elseif repr == 'list' then
        emit_list(node, i, s, p, out, depth, a)
    else
        emit_dict(node, i, s, p, out, depth, a)
    end
end

-- Write the fields of `node` in plan order. fpos[i] is the position of
-- field i's value in `s`, or nil when the slot is missing.
emit_fields = function(node, a, s, fpos, out, depth)
    local oneof = node.oneof
    local seen
    for i = 1, node.n do
        local p = fpos[i]
        if p ~= nil and byte(s, p) ~= 0xc0 then
            local grp = oneof[i]
            if grp ~= 0 then
                if seen == nil then seen = {} end
                local other = seen[grp]
                if other ~= nil then
                    error(string.format("pb.tuple: oneof '%s' of %s has more "
                        .. "than one member set: '%s' and '%s'",
                        node.oneof_names[grp], node.message, node.name[other],
                        node.name[i]), 0)
                end
                seen[grp] = i
            end
            emit_value(node, i, s, p, out, depth, a)
        end
    end
end

-- Body of the nested message at s[p] (a map or an array per the node's
-- layout) and the position past it. `parent`, `pi`, `elem` locate the
-- value for error messages.
encode_message = function(node, s, p, depth, parent, pi, elem)
    if depth > RECURSION_LIMIT then
        error(string.format('pb.tuple: %s nests deeper than %d levels',
                            parent.message, RECURSION_LIMIT), 0)
    end
    local a = aux_of(node)
    local cls, count, q, ext = mp_head(s, p)
    local fpos = {}
    if node.layout == 'map' then
        if cls ~= MP_MAP then
            type_error(parent, pi, elem, 'a map', cls, ext)
        end
        for _ = 1, count do
            local kcls, kn, kbody, kext = mp_head(s, q)
            if kcls ~= MP_STR then
                value_error(parent, pi, elem, 'a %s map has a key of type %s, '
                            .. 'field names are strings', node.message,
                            class_name(kcls, kext))
            end
            local key = sub(s, kbody, kbody + kn - 1)
            local i = a.index[key]
            if i == nil then
                value_error(parent, pi, elem, "unknown key '%s' in a %s map",
                            key, node.message)
            end
            if fpos[i] ~= nil then
                value_error(parent, pi, elem, "key '%s' appears twice in a %s "
                            .. 'map', key, node.message)
            end
            q = kbody + kn
            fpos[i] = q
            q = mp_next(s, q)
        end
    else
        if cls ~= MP_ARRAY then
            type_error(parent, pi, elem, 'an array', cls, ext)
        end
        for pos = 1, count do
            local i = a.at[pos]
            if i ~= nil then
                fpos[i] = q
            elseif byte(s, q) ~= 0xc0 then
                value_error(parent, pi, elem, 'position %d of a %s array has '
                            .. 'no field', pos, node.message)
            end
            q = mp_next(s, q)
        end
    end
    local out = {}
    emit_fields(node, a, s, fpos, out, depth)
    return concat(out), q
end

local function lua_encode(conv, tuple)
    if not box.tuple.is(tuple) then
        error('pb.tuple: expected a box.tuple, got ' .. type(tuple), 0)
    end
    local plan = conv.plan
    local a = aux_of(plan)
    -- A tuple encodes to its own msgpack array.
    local s = msgpack.encode(tuple)
    local _, count, q = mp_head(s, 1)
    local cols = {}
    local last = count < a.width and count or a.width
    for c = 1, last do
        cols[c] = q
        q = mp_next(s, q)
    end
    local fpos = {}
    for i = 1, plan.n do fpos[i] = cols[plan.column[i]] end
    local out = {}
    emit_fields(plan, a, s, fpos, out, 0)
    return concat(out)
end

local function lua_encode_repeated(conv, field_no, tuples)
    if type(field_no) ~= 'number' or field_no ~= math.floor(field_no)
            or field_no < 1 or field_no > MAX_FIELD_NO then
        error(string.format('pb.tuple: field number must be an integer in '
                            .. '[1, %d], got %s', MAX_FIELD_NO,
                            tostring(field_no)), 0)
    end
    if type(tuples) ~= 'table' then
        error('pb.tuple: tuples must be an array of box.tuple, got '
              .. type(tuples), 0)
    end
    local tag = encode_tag(field_no, WIRE_LEN)
    local out, n = {}, 0
    for k = 1, #tuples do
        local b = lua_encode(conv, tuples[k])
        out[n + 1] = tag
        out[n + 2] = encode_varint(#b)
        out[n + 3] = b
        n = n + 3
    end
    return concat(out, '', 1, n)
end

-- ---------------------------------------------------------------------------
-- Decode: wire -> tuple
-- ---------------------------------------------------------------------------

local DEFAULT = {
    int32 = 0, int64 = 0, uint32 = 0, uint64 = 0, sint32 = 0, sint64 = 0,
    fixed32 = 0, fixed64 = 0, sfixed32 = 0, sfixed64 = 0, enum = 0,
    double = 0, float = 0, bool = false, string = '', bytes = '',
}

-- Tuple value of scalar `v` (proto `kind`) for a slot of type `ctype`
-- bound with `conv`. nil means NULL.
local function tuple_scalar(node, i, elem, kind, conv, ctype, v)
    local range = INT_RANGE[kind]
    if range ~= nil then
        -- An `integer` column holds int64 and uint64 alike, so every
        -- proto integer fits it; only `unsigned` refuses negatives.
        if ctype == 'unsigned' and v < 0 then
            value_error(node, i, elem, 'value %s does not fit column type '
                        .. 'unsigned', tostring(v))
        end
        return v
    elseif kind == 'double' or kind == 'float' then
        -- A `double` column refuses a msgpack integer, which is how a
        -- whole Lua number would be written.
        if ctype == 'double' then return ffi.cast('double', v) end
        return v
    elseif kind == 'bool' then
        return v
    end
    -- string / bytes
    if conv == 'uuid_text' then
        if v == '' then return nil end
        local u = uuid.fromstr(v)
        if u == nil or u:str() ~= v then
            value_error(node, i, elem, "'%s' is not a canonical uuid", v)
        end
        return u
    elseif conv == 'uuid_bin' then
        if v == '' then return nil end
        if #v ~= 16 then
            value_error(node, i, elem, 'a uuid is 16 bytes, got %d', #v)
        end
        return uuid.frombin(v, 'b')
    end
    if ctype == 'varbinary' then return to_varbinary(v) end
    if ctype == 'string' then return v end
    -- untyped slot: the msgpack type follows the proto type
    if kind == 'bytes' then return to_varbinary(v) end
    return v
end

local function tuple_timestamp(node, i, elem, v)
    -- The codec returns a {seconds, nanos} table for a Timestamp that
    -- datetime cannot represent.
    if not datetime.is_datetime(v) then
        value_error(node, i, elem, 'Timestamp is outside the datetime range')
    end
    return v
end

local tuple_message

local function tuple_element(node, i, elem, kind, v)
    if kind == 'message' then return tuple_message(node.sub[i], v) end
    if kind == 'timestamp' then return tuple_timestamp(node, i, elem, v) end
    return tuple_scalar(node, i, elem, kind, 'any', 'any', v)
end

-- Tuple value of field i given its decoded value `v` (nil when unset).
-- nil means NULL. `raw` fields are the caller's.
local function tuple_value(node, i, v)
    local repr, kind = node.repr[i], node.kind[i]
    if repr == 'scalar' then
        if v == nil then
            if node.optional[i] or kind == 'timestamp' then return nil end
            v = DEFAULT[kind]
        end
        if kind == 'timestamp' then return tuple_timestamp(node, i, nil, v) end
        return tuple_scalar(node, i, nil, kind, node.conv[i],
                            node.column_type[i], v)
    elseif repr == 'msg_map' or repr == 'msg_array' then
        if v == nil then return nil end
        return tuple_message(node.sub[i], v)
    elseif repr == 'list' then
        local arr = setmetatable({}, ARRAY_MT)
        if v ~= nil then
            for k = 1, #v do arr[k] = tuple_element(node, i, k, kind, v[k]) end
        end
        return arr
    end
    -- dict. The codec hands a map<K,V> back as a Lua hash table, so this
    -- is the one `pairs` of the conversion path.
    local m = setmetatable({}, MAP_MT)
    if v ~= nil then
        local vkind = node.value_kind[i]
        for key, val in pairs(v) do
            m[key] = tuple_element(node, i, 'map value', vkind, val)
        end
    end
    return m
end

tuple_message = function(node, v)
    if node.layout == 'map' then
        local m = setmetatable({}, MAP_MT)
        for j = 1, node.n do
            local name = node.name[j]
            local tv = tuple_value(node, j, v[name])
            if tv ~= nil then m[name] = tv end
        end
        return m
    end
    local arr = setmetatable({}, ARRAY_MT)
    for pos = 1, aux_of(node).width do arr[pos] = NULL end
    for j = 1, node.n do
        local tv = tuple_value(node, j, v[node.name[j]])
        if tv ~= nil then arr[node.column[j]] = tv end
    end
    return arr
end

-- Payload bytes of every `raw` field, verbatim: {[i] = bytes}. A field
-- present more than once gets its payloads joined (protobuf's merge).
--
-- A oneof keeps the member that comes last on the wire, as the codec
-- does: a member clears the payloads collected for the group's previous
-- member, so a raw member followed by a sibling is unset, and a raw
-- member that comes back after a sibling starts over.
local function collect_raw(a, bytes)
    local parts = {}
    local active  -- {[oneof group] = field number of the member last seen}
    local pos, len = 1, #bytes
    while pos <= len do
        local id, wt, np = wire.decode_tag(bytes, pos)
        local grp = a.oneof_at[id]
        if grp ~= nil then
            if active == nil then active = {} end
            local prev = active[grp]
            if prev ~= nil and prev ~= id then
                local r = a.raw_at[prev]
                if r ~= nil then parts[r] = nil end
            end
            active[grp] = id
        end
        local i = a.raw_at[id]
        if i ~= nil and wt == WIRE_LEN then
            local payload
            payload, pos = wire.decode_len(bytes, np)
            local list = parts[i]
            if list == nil then
                list = {}
                parts[i] = list
            end
            list[#list + 1] = payload
        else
            pos = wire.skip_field(bytes, np, wt, id)
        end
    end
    return parts
end

local function lua_decode(conv, bytes)
    if type(bytes) ~= 'string' then
        error('pb.tuple: expected a string to decode, got ' .. type(bytes), 0)
    end
    local plan = conv.plan
    local unbound = plan.unbound_nonnull_name
    if #unbound > 0 then
        error(string.format("pb.tuple: cannot decode %s into space '%s': "
                            .. "column%s '%s' %s not nullable and no field "
                            .. 'binds to %s', plan.message, conv.space_name,
                            #unbound > 1 and 's' or '',
                            concat(unbound, "', '"),
                            #unbound > 1 and 'are' or 'is',
                            #unbound > 1 and 'them' or 'it'), 0)
    end
    local msg = codec.decode(conv.desc, bytes)
    local a = aux_of(plan)
    local raw = a.has_raw and collect_raw(a, bytes) or nil
    local row = {}
    for c = 1, a.width do row[c] = NULL end
    for i = 1, plan.n do
        local tv
        if plan.repr[i] == 'raw' then
            local list = raw[i]
            if list ~= nil then tv = to_varbinary(concat(list)) end
        else
            tv = tuple_value(plan, i, msg[plan.name[i]])
        end
        if tv ~= nil then row[plan.column[i]] = tv end
    end
    return row
end

-- ---------------------------------------------------------------------------
-- Converter methods
-- ---------------------------------------------------------------------------

if c_runtime ~= nil then
    local c_encode = c_runtime.tuple_encode
    local c_encode_repeated = c_runtime.tuple_encode_repeated

    function Conv:encode(tuple)
        self:_check_schema()
        return c_encode(self._tplan, tuple)
    end

    function Conv:encode_repeated(field_no, tuples)
        self:_check_schema()
        return c_encode_repeated(self._tplan, field_no, tuples)
    end
else
    function Conv:encode(tuple)
        self:_check_schema()
        return lua_encode(self, tuple)
    end

    function Conv:encode_repeated(field_no, tuples)
        self:_check_schema()
        return lua_encode_repeated(self, field_no, tuples)
    end
end

if c_runtime ~= nil then
    local c_decode = c_runtime.tuple_decode

    -- The C decoder does not word conversion errors: on bytes it refuses
    -- it returns false, and the Lua path, run on the same bytes, raises
    -- the error in its own words. The Lua path accepting them would mean
    -- the two decoders disagree, which is a bug to report, not a result.
    local function c_convert(conv, bytes, op)
        local ok, tuple = c_decode(conv._tplan, bytes, op, conv.space_id)
        if ok then return tuple end
        lua_decode(conv, bytes)
        error('pb.tuple: the C decoder refused input the Lua decoder '
              .. 'accepts', 0)
    end

    function Conv:decode(bytes)
        self:_check_schema()
        return c_convert(self, bytes, 'new')
    end

    function Conv:insert(bytes)
        self:_check_schema()
        return c_convert(self, bytes, 'insert')
    end

    function Conv:replace(bytes)
        self:_check_schema()
        return c_convert(self, bytes, 'replace')
    end
else
    function Conv:decode(bytes)
        self:_check_schema()
        return box.tuple.new(lua_decode(self, bytes))
    end

    function Conv:insert(bytes)
        self:_check_schema()
        return box.space[self.space_id]:insert(lua_decode(self, bytes))
    end

    function Conv:replace(bytes)
        self:_check_schema()
        return box.space[self.space_id]:replace(lua_decode(self, bytes))
    end
end

-- The Lua path on its own, for parity tests against other converters.
M._lua = {
    encode          = lua_encode,
    encode_repeated = lua_encode_repeated,
    decode          = lua_decode,
}

return M
