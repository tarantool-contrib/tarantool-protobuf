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
-- * A field with explicit presence (proto3 `optional`, or a oneof member)
--   needs a nullable column: absence has to be representable.
-- * Nested slots are untyped, so a nested field is checked as if its
--   column were `any`: its values are checked one by one at conversion.
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
--   conv.schema_version  box schema version the plan was compiled against
--   conv:_check_schema() rebinds when the schema version moved; raises when
--                        the space is gone or its new format no longer binds
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
--                as well as floats; encode converts integers to double
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
        unbound_nonnull = {}, unbound_nonnull_name = {},
    }
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
        if type(opts.omit) ~= 'table' then
            bind_error('omit must be an array, got %s', type(opts.omit))
        end
        for _, field in ipairs(opts.omit) do
            if known[field] == nil then
                bind_error("omit: %s has no field '%s'", desc.name,
                           tostring(field))
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

-- Compile the top-level plan of `conv` against `space`'s current format.
local function compile_plan(conv, space)
    local opts = {columns = conv.opts.columns, omit = conv.opts.omit,
                  space_name = space.name}
    return compile_node(conv.desc, space:format(), 0, 'tuple', {}, opts)
end

-- Rebind when the box schema changed since the plan was compiled.
function Conv:_check_schema()
    local version = schema_version()
    if version == self.schema_version then
        return
    end
    local space = box.space[self.space_id]
    if space == nil then
        error(string.format("pb.tuple: space '%s' (id %d) no longer exists",
                            self.space_name, self.space_id), 0)
    end
    local ok, plan = pcall(compile_plan, self, space)
    if not ok then
        error(string.format("pb.tuple: the format of space '%s' changed and "
                            .. 'no longer binds %s: %s', space.name,
                            self.desc.name, tostring(plan)), 0)
    end
    self.plan = plan
    self.space_name = space.name
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
    conv.plan = compile_plan(conv, space)
    return conv
end

return M
