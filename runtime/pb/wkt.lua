-- Well-known types (WKT) — implementations of selected google.protobuf.*
-- messages with idiomatic Lua surfaces.
--
-- Each WKT is exposed three ways for parity with generated user code:
--   pb.wkt.<Name>_descriptor   -- usable in field descriptors
--   pb.wkt.<Name>_encode(v)    -- value -> wire bytes (no tag/len prefix)
--   pb.wkt.<Name>_decode(buf)  -- wire bytes -> value
--
-- Descriptors carry custom .encode / .decode functions; the codec dispatches
-- to them in place of the generic message walk.
local ffi      = require('ffi')
local datetime = require('datetime')
local wire     = require('pb.wire')

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function emit_field_int64(out, n, tag, v)
    if v ~= 0 and v ~= ffi.cast('int64_t', 0) then
        out[n + 1] = tag
        out[n + 2] = wire.encode_int64(v)
        return n + 2
    end
    return n
end

local function emit_field_int32(out, n, tag, v)
    if v ~= 0 then
        out[n + 1] = tag
        out[n + 2] = wire.encode_int32(v)
        return n + 2
    end
    return n
end

-- ---------------------------------------------------------------------------
-- google.protobuf.Timestamp
--   message Timestamp { int64 seconds = 1; int32 nanos = 2; }
--
-- Lua representation:
--   - encode accepts a `datetime` cdata, a {seconds=, nanos=} table,
--     or a Lua number (whole seconds; fractional part discarded).
--   - decode returns a `datetime` cdata.
-- ---------------------------------------------------------------------------

local INT64_ZERO = ffi.cast('int64_t', 0)

local function timestamp_to_parts(v)
    if type(v) == 'cdata' and datetime.is_datetime(v) then
        return ffi.cast('int64_t', v.epoch), v.nsec
    elseif type(v) == 'table' then
        return ffi.cast('int64_t', v.seconds or 0), v.nanos or 0
    elseif type(v) == 'number' then
        local secs = math.floor(v)
        return ffi.cast('int64_t', secs), math.floor((v - secs) * 1e9 + 0.5)
    end
    error("Timestamp: expected datetime, table {seconds,nanos}, or number; got " .. type(v), 0)
end

local function timestamp_encode(v)
    if v == nil then return '' end
    local seconds, nanos = timestamp_to_parts(v)
    local out, n = {}, 0
    n = emit_field_int64(out, n, '\x08', seconds)
    n = emit_field_int32(out, n, '\x10', nanos)
    return table.concat(out, '', 1, n)
end

local function timestamp_decode(buf)
    local seconds, nanos = INT64_ZERO, 0
    local pos, len = 1, #buf
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            seconds, pos = wire.decode_int64(buf, pos)
        elseif id == 2 then
            nanos, pos = wire.decode_int32(buf, pos)
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    -- datetime.new validates nanos/seconds ranges. Out-of-spec Timestamps
    -- (e.g. negative nanos, year > 9999) are kept as raw {seconds, nanos}
    -- so JSON serialization can reject them with serialize_error rather
    -- than crashing here with parse_error.
    local ok, dt = pcall(datetime.new,
        {timestamp = tonumber(seconds), nsec = nanos})
    if not ok then return {seconds = seconds, nanos = nanos} end
    return dt
end

M.Timestamp_encode = timestamp_encode
M.Timestamp_decode = timestamp_decode
M.Timestamp_descriptor = {
    name = 'google.protobuf.Timestamp',
    encode = timestamp_encode,
    decode = timestamp_decode,
}

-- ---------------------------------------------------------------------------
-- google.protobuf.Duration
--   message Duration { int64 seconds = 1; int32 nanos = 2; }
--
-- Lua representation: {seconds=N, nanos=M} table (Tarantool's `interval` is
-- richer — months/days — and not a clean fit for raw seconds+nanos).
-- ---------------------------------------------------------------------------

local function duration_encode(v)
    if v == nil then return '' end
    local seconds, nanos
    if type(v) == 'table' then
        seconds = ffi.cast('int64_t', v.seconds or 0)
        nanos = v.nanos or 0
    elseif type(v) == 'number' then
        local s = math.floor(v)
        seconds = ffi.cast('int64_t', s)
        nanos = math.floor((v - s) * 1e9 + 0.5)
    else
        error("Duration: expected table {seconds,nanos} or number, got " .. type(v), 0)
    end
    local out, n = {}, 0
    n = emit_field_int64(out, n, '\x08', seconds)
    n = emit_field_int32(out, n, '\x10', nanos)
    return table.concat(out, '', 1, n)
end

local function duration_decode(buf)
    local seconds, nanos = INT64_ZERO, 0
    local pos, len = 1, #buf
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            seconds, pos = wire.decode_int64(buf, pos)
        elseif id == 2 then
            nanos, pos = wire.decode_int32(buf, pos)
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    return {seconds = seconds, nanos = nanos}
end

M.Duration_encode = duration_encode
M.Duration_decode = duration_decode
M.Duration_descriptor = {
    name = 'google.protobuf.Duration',
    encode = duration_encode,
    decode = duration_decode,
}

-- ---------------------------------------------------------------------------
-- google.protobuf.Empty
--   message Empty {}
-- ---------------------------------------------------------------------------

local function empty_encode(_) return '' end
local function empty_decode(_) return {} end
M.Empty_encode = empty_encode
M.Empty_decode = empty_decode
M.Empty_descriptor = {
    name = 'google.protobuf.Empty',
    encode = empty_encode,
    decode = empty_decode,
}

-- ---------------------------------------------------------------------------
-- google.protobuf.<T>Value wrappers
--   message <T>Value { <T> value = 1; }
--
-- The Lua-side surface is the unwrapped value: encode accepts the raw
-- value, decode returns the raw value (default if missing).
-- ---------------------------------------------------------------------------

-- For each wrapper type: {wire_type, encode_fn, decode_fn, default, default_check_fn}
local WRAPPERS = {
    {'DoubleValue', wire.WIRE_I64,    'encode_double',  'decode_double',  0,    function(v) return v == 0 end},
    {'FloatValue',  wire.WIRE_I32,    'encode_float',   'decode_float',   0,    function(v) return v == 0 end},
    {'Int64Value',  wire.WIRE_VARINT, 'encode_int64',   'decode_int64',   0,    function(v) return v == 0 or v == INT64_ZERO end},
    {'UInt64Value', wire.WIRE_VARINT, 'encode_uint64',  'decode_uint64',  0,    function(v) return v == 0 or v == ffi.cast('uint64_t', 0) end},
    {'Int32Value',  wire.WIRE_VARINT, 'encode_int32',   'decode_int32',   0,    function(v) return v == 0 end},
    {'UInt32Value', wire.WIRE_VARINT, 'encode_uint32',  'decode_uint32',  0,    function(v) return v == 0 end},
    {'BoolValue',   wire.WIRE_VARINT, 'encode_bool',    'decode_bool',    false,function(v) return v == false end},
    {'StringValue', wire.WIRE_LEN,    'encode_string',  'decode_string',  '',   function(v) return v == '' end},
    {'BytesValue',  wire.WIRE_LEN,    'encode_bytes',   'decode_bytes',   '',   function(v) return v == '' end},
}

local TAG_BY_WIRE = {
    [wire.WIRE_VARINT] = '\x08',  -- field 1, VARINT
    [wire.WIRE_I64]    = '\x09',  -- field 1, I64
    [wire.WIRE_LEN]    = '\x0a',  -- field 1, LEN
    [wire.WIRE_I32]    = '\x0d',  -- field 1, I32
}

for _, spec in ipairs(WRAPPERS) do
    local name, wt, enc_fn, dec_fn, default, is_default = unpack(spec)
    local encode = wire[enc_fn]
    local decode = wire[dec_fn]
    local tag = TAG_BY_WIRE[wt]

    if wt == wire.WIRE_LEN then
        -- StringValue / BytesValue: skip encode_len's `varint(#v) .. v` and
        -- let LuaJIT fold tag + varint + body into a single multi-concat
        -- instead of two sequential concats.
        M[name .. '_encode'] = function(v)
            if v == nil or is_default(v) then return '' end
            return tag .. wire.encode_varint(#v) .. v
        end
    else
        M[name .. '_encode'] = function(v)
            if v == nil or is_default(v) then return '' end
            return tag .. encode(v)
        end
    end

    M[name .. '_decode'] = function(buf)
        if #buf == 0 then return default end
        local pos, len = 1, #buf
        local val = default
        while pos <= len do
            local id, wt2
            id, wt2, pos = wire.decode_tag(buf, pos)
            if id == 1 then
                val, pos = decode(buf, pos)
            else
                pos = wire.skip_field(buf, pos, wt2, id)
            end
        end
        return val
    end

    M[name .. '_descriptor'] = {
        name = 'google.protobuf.' .. name,
        encode = M[name .. '_encode'],
        decode = M[name .. '_decode'],
    }
end

-- ---------------------------------------------------------------------------
-- google.protobuf.Struct / Value / ListValue
--
--   message Value {
--     oneof kind {
--       NullValue null_value   = 1;   // varint enum
--       double    number_value = 2;   // I64
--       string    string_value = 3;   // LEN
--       bool      bool_value   = 4;   // varint
--       Struct    struct_value = 5;   // LEN
--       ListValue list_value   = 6;   // LEN
--     }
--   }
--   message Struct    { map<string, Value> fields = 1; }
--   message ListValue { repeated Value     values = 1; }
--
-- Lua representation:
--   - `box.NULL`  → null_value sentinel (re-exported as pb.NULL).
--   - boolean    ↔ bool_value
--   - number     ↔ number_value (proto double)
--   - string     ↔ string_value
--   - table      ↔ Struct (if hash-like or tagged via pb.wkt.struct) or
--                  ListValue (if array-like / tagged via pb.wkt.list)
--
-- Decode tags returned tables with hidden metatables so a Struct{}/ListValue{}
-- distinction survives an empty round trip; empty plain `{}` defaults to Struct.
-- ---------------------------------------------------------------------------

local NULL = box.NULL
M.NULL = NULL

-- google.protobuf.NullValue is a singleton enum (NULL_VALUE = 0). It shows
-- up as the type of Value's null_value field and as a standalone enum
-- field type (e.g. oneof_null_value in the conformance test message). We
-- export a minimal descriptor so the codec layer can route enum decode
-- through enum.by_name lookups instead of crashing on a nil descriptor.
M.NullValue_descriptor = {
    name = 'google.protobuf.NullValue',
    by_name = {NULL_VALUE = 0},
    by_value = {[0] = 'NULL_VALUE'},
}

local STRUCT_MT = {__pb_kind = 'struct'}
local LIST_MT   = {__pb_kind = 'list'}

local function struct_tag(t)  return setmetatable(t or {}, STRUCT_MT) end
local function list_tag(t)    return setmetatable(t or {}, LIST_MT)   end
M.struct = struct_tag
M.list   = list_tag

local function is_list_like(t)
    local mt = getmetatable(t)
    if mt == LIST_MT   then return true  end
    if mt == STRUCT_MT then return false end
    return t[1] ~= nil  -- empty {} → struct
end

local value_encode, struct_encode, list_encode
local value_decode, struct_decode, list_decode

value_encode = function(v)
    if v == nil or v == NULL then return '\x08\x00' end  -- field 1, varint 0
    local ty = type(v)
    if ty == 'boolean' then
        return '\x20' .. (v and '\x01' or '\x00')        -- field 4, varint
    end
    if ty == 'number' then
        return '\x11' .. wire.encode_double(v)            -- field 2, I64
    end
    if ty == 'string' then
        return '\x1a' .. wire.encode_len(v)               -- field 3, LEN
    end
    if ty == 'cdata' then
        -- LuaJIT 64-bit ints get a double-precision approximation here.
        return '\x11' .. wire.encode_double(tonumber(v))
    end
    if ty == 'table' then
        if is_list_like(v) then
            return '\x32' .. wire.encode_len(list_encode(v))   -- field 6, LEN
        end
        return '\x2a' .. wire.encode_len(struct_encode(v))     -- field 5, LEN
    end
    error("Value: unsupported Lua type " .. ty, 0)
end

struct_encode = function(t)
    if t == nil then return '' end
    local out, n = {}, 0
    -- Each Struct entry: tag(1, LEN)=0x0a, entry_len, entry_payload
    -- Entry payload: tag(1, LEN)=0x0a + key_len_prefixed_bytes
    --              + tag(2, LEN)=0x12 + value_len_prefixed_bytes
    -- Split the outer entry wrap so the final `table.concat` joins entries
    -- in one pass (matches the codec.lua nested-message pattern). The inner
    -- entry stays a single multi-concat: it's cheaper than three more out
    -- slots once the entry is small.
    for k, v in pairs(t) do
        local key_str = type(k) == 'string' and k or tostring(k)
        local val_body = value_encode(v)
        local entry = '\x0a' .. wire.encode_varint(#key_str) .. key_str
                   .. '\x12' .. wire.encode_varint(#val_body) .. val_body
        n = n + 1; out[n] = '\x0a'
        n = n + 1; out[n] = wire.encode_varint(#entry)
        n = n + 1; out[n] = entry
    end
    return table.concat(out)
end

list_encode = function(t)
    if t == nil then return '' end
    local out, n = {}, 0
    for i = 1, #t do
        local body = value_encode(t[i])
        n = n + 1; out[n] = '\x0a'
        n = n + 1; out[n] = wire.encode_varint(#body)
        n = n + 1; out[n] = body
    end
    return table.concat(out)
end

-- Value / Struct / ListValue recurse into each other, so they take the
-- nesting `depth` from the codec (nil at the top level) and enforce the
-- same limit as message decoding.
value_decode = function(buf, depth)
    depth = depth or 0
    if depth > wire.RECURSION_LIMIT then wire.recursion_limit_error() end
    -- Empty Value (no kind set on wire) → null per common impl convention.
    if #buf == 0 then return NULL end
    local pos, len = 1, #buf
    local result = NULL  -- last-set-wins; default to NULL if only unknowns
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            local _u
            _u, pos = wire.decode_varint(buf, pos)
            result = NULL
        elseif id == 2 then
            local nv
            nv, pos = wire.decode_double(buf, pos)
            result = nv
        elseif id == 3 then
            local s
            s, pos = wire.decode_string(buf, pos)
            result = s
        elseif id == 4 then
            local b
            b, pos = wire.decode_bool(buf, pos)
            result = b
        elseif id == 5 then
            local payload
            payload, pos = wire.decode_len(buf, pos)
            result = struct_decode(payload, depth + 1)
        elseif id == 6 then
            local payload
            payload, pos = wire.decode_len(buf, pos)
            result = list_decode(payload, depth + 1)
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    return result
end

struct_decode = function(buf, depth)
    depth = depth or 0
    if depth > wire.RECURSION_LIMIT then wire.recursion_limit_error() end
    local result = setmetatable({}, STRUCT_MT)
    local pos, len = 1, #buf
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            local payload
            payload, pos = wire.decode_len(buf, pos)
            local key, val = '', NULL
            local ep, elim = 1, #payload
            while ep <= elim do
                local eid, ewt
                eid, ewt, ep = wire.decode_tag(payload, ep)
                if eid == 1 then
                    key, ep = wire.decode_string(payload, ep)
                elseif eid == 2 then
                    local vbuf
                    vbuf, ep = wire.decode_len(payload, ep)
                    val = value_decode(vbuf, depth + 1)
                else
                    ep = wire.skip_field(payload, ep, ewt, eid)
                end
            end
            result[key] = val
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    return result
end

list_decode = function(buf, depth)
    depth = depth or 0
    if depth > wire.RECURSION_LIMIT then wire.recursion_limit_error() end
    local result = setmetatable({}, LIST_MT)
    local pos, len = 1, #buf
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            local payload
            payload, pos = wire.decode_len(buf, pos)
            result[#result + 1] = value_decode(payload, depth + 1)
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    return result
end

M.Value_encode      = value_encode
M.Value_decode      = value_decode
M.Value_descriptor  = {name='google.protobuf.Value',  encode=value_encode,  decode=value_decode}

M.Struct_encode     = struct_encode
M.Struct_decode     = struct_decode
M.Struct_descriptor = {name='google.protobuf.Struct', encode=struct_encode, decode=struct_decode}

M.ListValue_encode     = list_encode
M.ListValue_decode     = list_decode
M.ListValue_descriptor = {name='google.protobuf.ListValue', encode=list_encode, decode=list_decode}

-- ---------------------------------------------------------------------------
-- google.protobuf.Any
--   message Any { string type_url = 1; bytes value = 2; }
--
-- Lua representation (opaque):
--   {type_url = 'type.googleapis.com/pkg.Msg', value = '<bytes>'}
--
-- The `pb.any.pack(desc, t)` / `pb.any.unpack(any_t)` helpers (see init.lua)
-- bridge the opaque form to user message tables via a process-global type
-- registry. They are optional — the opaque form round-trips on its own.
-- ---------------------------------------------------------------------------

local any_encode, any_decode

any_encode = function(v)
    if v == nil then return '' end
    if type(v) ~= 'table' then
        error('Any: expected {type_url=,value=} table, got ' .. type(v), 0)
    end
    local out, n = {}, 0
    local type_url = v.type_url
    if type_url ~= nil and type_url ~= '' then
        n = n + 1; out[n] = '\x0a'                          -- field 1, LEN
        n = n + 1; out[n] = wire.encode_varint(#type_url)
        n = n + 1; out[n] = type_url
    end
    local value = v.value
    if value ~= nil and value ~= '' then
        n = n + 1; out[n] = '\x12'                          -- field 2, LEN
        n = n + 1; out[n] = wire.encode_varint(#value)
        n = n + 1; out[n] = value
    end
    return table.concat(out)
end

any_decode = function(buf)
    local type_url, value = '', ''
    local pos, len = 1, #buf
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            type_url, pos = wire.decode_string(buf, pos)
        elseif id == 2 then
            value, pos = wire.decode_bytes(buf, pos)
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    return {type_url = type_url, value = value}
end

M.Any_encode     = any_encode
M.Any_decode     = any_decode
-- The Any descriptor advertises its two real fields (type_url + value) so
-- the text-format parser can fall through to the generic body walker
-- when an Any is written in direct form (`{ type_url: "..." value: "..." }`)
-- instead of the inline `[type.url] { ... }` form. encode/decode still
-- intercept the wire path.
M.Any_descriptor = {
    name = 'google.protobuf.Any',
    encode = any_encode,
    decode = any_decode,
    fields = {
        {name='type_url', id=1, kind='scalar', proto_type='string'},
        {name='value',    id=2, kind='scalar', proto_type='bytes'},
    },
    field_by_name = {
        type_url = {name='type_url', id=1, kind='scalar', proto_type='string'},
        value    = {name='value',    id=2, kind='scalar', proto_type='bytes'},
    },
    field_by_id = {},  -- filled below
}
M.Any_descriptor.field_by_id[1] = M.Any_descriptor.field_by_name.type_url
M.Any_descriptor.field_by_id[2] = M.Any_descriptor.field_by_name.value

-- Per-process registry mapping type_url (or bare full name) to a message
-- descriptor. `pb.register(desc)` adds entries; pack/unpack look them up.
local REGISTRY = {}
M._registry = REGISTRY

local DEFAULT_PREFIX = 'type.googleapis.com/'

local function type_url_full_name(url)
    return url:match('([^/]+)$') or url
end

---@param desc pb.Descriptor
---@return pb.Descriptor
M.register = function(desc)
    if type(desc) ~= 'table' or desc.name == nil then
        error('pb.register: expected a descriptor with a `name` field', 0)
    end
    REGISTRY[desc.name] = desc
    REGISTRY[DEFAULT_PREFIX .. desc.name] = desc
    return desc
end

---@param name_or_url string                     bare full name (`pkg.Foo`) or a type URL (`type.googleapis.com/pkg.Foo`)
---@return pb.Descriptor?
M.lookup = function(name_or_url)
    return REGISTRY[name_or_url] or REGISTRY[type_url_full_name(name_or_url)]
end

-- Pack a Lua message table into an opaque Any form.
---@param desc pb.Descriptor
---@param t    table
---@param type_url_prefix? string                defaults to `type.googleapis.com/`
---@return pb.AnyMessage
M.any_pack = function(desc, t, type_url_prefix)
    if desc == nil or desc.name == nil then
        error('pb.any.pack: descriptor must have a `name`', 0)
    end
    local prefix = type_url_prefix or DEFAULT_PREFIX
    local enc = desc.encode and desc.encode(t)
              or require('pb.codec').encode(desc, t)
    return {type_url = prefix .. desc.name, value = enc}
end

-- Unpack an Any table. `desc_or_nil` overrides the registry lookup.
---@param any_t      pb.AnyMessage                google.protobuf.Any-shaped table {type_url=..., value=...}
---@param desc_or_nil? pb.Descriptor              override the registry lookup
---@return table
M.any_unpack = function(any_t, desc_or_nil)
    if type(any_t) ~= 'table' then
        error('pb.any.unpack: expected Any table', 0)
    end
    local desc = desc_or_nil or M.lookup(any_t.type_url or '')
    if desc == nil then
        error('pb.any.unpack: no descriptor for ' .. tostring(any_t.type_url), 0)
    end
    if desc.decode then return desc.decode(any_t.value or '') end
    return require('pb.codec').decode(desc, any_t.value or '')
end

-- ---------------------------------------------------------------------------
-- google.protobuf.FieldMask
--   message FieldMask { repeated string paths = 1; }
--
-- Lua representation: Lua array of strings. (Plain table; no special tag.)
-- ---------------------------------------------------------------------------

local function fieldmask_encode(v)
    if v == nil or #v == 0 then return '' end
    local out, n = {}, 0
    for i = 1, #v do
        local s = v[i]
        n = n + 1; out[n] = '\x0a'  -- field 1, LEN
        n = n + 1; out[n] = wire.encode_varint(#s)
        n = n + 1; out[n] = s
    end
    return table.concat(out)
end

local function fieldmask_decode(buf)
    local result = {}
    local pos, len = 1, #buf
    while pos <= len do
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if id == 1 then
            local s
            s, pos = wire.decode_string(buf, pos)
            result[#result + 1] = s
        else
            pos = wire.skip_field(buf, pos, wt, id)
        end
    end
    return result
end

M.FieldMask_encode     = fieldmask_encode
M.FieldMask_decode     = fieldmask_decode
M.FieldMask_descriptor = {name='google.protobuf.FieldMask', encode=fieldmask_encode, decode=fieldmask_decode}

-- Self-register every WKT so `pb.lookup(type_url)` resolves them without
-- the user having to call `pb.register` explicitly. This is what makes
-- Any-of-WKT JSON decode work out of the box.
for k, v in pairs(M) do
    if type(k) == 'string' and k:sub(-11) == '_descriptor'
       and type(v) == 'table' and v.name ~= nil then
        M.register(v)
    end
end

return M
