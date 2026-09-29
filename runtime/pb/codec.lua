-- Descriptor-driven protobuf encoder/decoder (proto3).
-- Operates on the descriptor tables emitted by protoc-gen-tarantool.
--
-- Descriptor shape:
--   {
--     name = 'pkg.Foo',
--     fields = { <field>... },               -- ordered, used for encode
--     field_by_id = { [id] = <field> ... },  -- used for decode
--   }
--
-- Field shape:
--   { name='x', id=1, kind=<'scalar'|'message'|'enum'|'map'>,
--     proto_type=<scalar name>,    -- when kind='scalar'
--     message=<descriptor>,        -- when kind='message'
--     enum=<enum_descriptor>,      -- when kind='enum'
--     key=<sub-field>,             -- when kind='map' (synthetic id=1)
--     value=<sub-field>,           -- when kind='map' (synthetic id=2)
--     repeated=true|nil,
--     packed=true|nil,             -- only meaningful when repeated and scalar
--     oneof=<oneof_name>|nil,      -- set on oneof branches
--     optional=true|nil }          -- proto3 explicit optional (presence)
--
-- Enum descriptor shape (no encode/decode logic; used for value lookup):
--   { name='pkg.Color', by_name={RED=0,...}, by_value={[0]='RED',...} }
local ffi  = require('ffi')
local wire = require('pb.wire')

local RECURSION_LIMIT = wire.RECURSION_LIMIT

local M = {}

local UINT64       = ffi.typeof('uint64_t')
local UINT64_ZERO  = UINT64(0)

-- Reuse the single source of truth defined in pb.wire.
local scalar = wire.TYPE_INFO
M.scalar = scalar

-- Parallel scalar table for the opt-in unsafe decode path: identical to
-- `scalar` except `string` decoder skips UTF-8 validation by routing
-- through the bytes handler (same wire format, no utf8_len). Compiled
-- readers built against this table inherit the swap as a captured
-- upvalue — the alternative (swap-on-call) cannot reach pre-compiled
-- f._reader closures because they capture handler.decode by value.
-- See M.decode_unsafe / pb.compile_readers_unsafe.
local scalar_unsafe = {}
for k, v in pairs(scalar) do scalar_unsafe[k] = v end
scalar_unsafe.string = scalar.bytes

-- ---------------------------------------------------------------------------
-- proto3 default-value detection (for elision on encode)
-- ---------------------------------------------------------------------------

local function is_default_scalar(proto_type, v)
    if proto_type == 'string' or proto_type == 'bytes' then
        return v == ''
    elseif proto_type == 'bool' then
        return v == false
    elseif proto_type == 'float' or proto_type == 'double' then
        -- -0.0 == 0.0 in IEEE but they encode to different bytes; the
        -- proto3 conformance suite pins that -0.0 round-trips intact.
        -- `1/v == math.huge` is the sign-bit probe — +0 yields +inf,
        -- -0 yields -inf.
        return v == 0 and 1 / v == math.huge
    elseif proto_type == 'int64' or proto_type == 'uint64'
        or proto_type == 'sint64' or proto_type == 'fixed64'
        or proto_type == 'sfixed64' then
        if type(v) == 'cdata' then return v == UINT64_ZERO or v == ffi.cast('int64_t', 0) end
        return v == 0
    end
    -- All remaining numeric scalars compare against Lua 0.
    return v == 0
end

-- ---------------------------------------------------------------------------
-- Encode
-- ---------------------------------------------------------------------------

-- Forward declarations: encode_field/build_writer/build_reader need to
-- close over encode_message and decode_msg before those are assigned
-- further down (writers/readers built by compile_* at finalize-time).
-- decode_group is for proto2 groups; its assignment is deferred because
-- the per-tag dispatch shares fast-path knowledge with decode_message.
local encode_message
local decode_msg
local decode_group
-- Unsafe-decode twins. The unsafe reader closures (one per field,
-- built by compile_readers_unsafe) capture these so sub-message recursion
-- and group decoding stay on the unsafe path all the way down.
local decode_msg_unsafe
local decode_group_unsafe

-- merge_message(desc, prev, decoded): recursively merge `decoded` into
-- `prev` per proto3 spec semantics:
--   - scalar / enum fields: last-wins (replace)
--   - repeated fields: concatenate (append decoded elements)
--   - map fields: last-wins per key
--   - sub-message fields: recursive merge
--   - oneof members: setting one clears the siblings already in `prev`
--   - proto2 extensions (`_extensions`): the same rules, per extension
--   - unknown fields (`_unknown_fields`): appended after `prev`'s, so a
--     re-encode emits both occurrences' unknown bytes in wire order
-- Sub-messages whose descriptor carries a custom decode (WKT) are replaced
-- wholesale because their decoded value is not a generic Lua table.
local merge_message

-- merge_value merges one decoded value `v` of field shape `f` into
-- `tbl[key]`. Shared by regular fields (tbl = prev, key = f.name) and
-- extensions (tbl = prev._extensions, key = f.full_name).
local function merge_value(f, tbl, key, v)
    local pv = tbl[key]
    if pv == nil then
        tbl[key] = v
    elseif f.kind == 'map' then
        for mk, mv in pairs(v) do pv[mk] = mv end
    elseif f.repeated then
        local n = #pv
        for j = 1, #v do pv[n + j] = v[j] end
    elseif f.kind == 'message' and not f.message.decode then
        merge_message(f.message, pv, v)
    else
        tbl[key] = v
    end
end

---@param desc    pb.Descriptor
---@param prev    table  decoded message being accumulated
---@param decoded table  newly-decoded copy to merge into `prev` in place
merge_message = function(desc, prev, decoded)
    local fields = desc.fields
    for i = 1, #fields do
        local f = fields[i]
        local fname = f.name
        local v = decoded[fname]
        if v ~= nil then
            merge_value(f, prev, fname, v)
            local sibs = f.oneof_siblings
            if sibs ~= nil then
                for j = 1, #sibs do prev[sibs[j]] = nil end
            end
        end
    end
    local exts = decoded._extensions
    if exts ~= nil then
        local pexts = prev._extensions
        if pexts == nil then
            prev._extensions = exts
        else
            local elist = desc.extensions_list or {}
            for i = 1, #elist do
                local ext = elist[i]
                local v = exts[ext.full_name]
                if v ~= nil then merge_value(ext, pexts, ext.full_name, v) end
            end
        end
    end
    local uf = decoded._unknown_fields
    if uf ~= nil then
        local puf = prev._unknown_fields
        prev._unknown_fields = puf == nil and uf or puf .. uf
    end
end
M.merge_message = merge_message

local function encode_enum_value(enum_desc, v)
    if type(v) == 'number' then return v end
    if type(v) == 'string' then
        local n = enum_desc.by_name[v]
        if n == nil then
            error(("unknown enum value '%s' for %s"):format(v, enum_desc.name), 0)
        end
        return n
    end
    error("enum value must be a number or string", 0)
end

-- encode_msg dispatches to a descriptor's custom encode function (used by
-- WKT) when present; otherwise walks fields generically.
local function encode_msg(desc, value)
    if desc.encode then return desc.encode(value) end
    return encode_message(desc, value)
end

-- encode_one returns wire bytes for a single value (no tag), based on the
-- field's kind/proto_type. Used for map keys/values and as a building block.
local function encode_one(field, v)
    local kind = field.kind
    if kind == 'scalar' then
        return scalar[field.proto_type].encode(v)
    elseif kind == 'enum' then
        return wire.encode_varint(encode_enum_value(field.enum, v))
    elseif kind == 'message' then
        return wire.encode_len(encode_msg(field.message, v))
    end
    error("encode_one: unknown kind " .. tostring(kind), 0)
end

-- wire_type_for returns the wire type for a field's value (singular).
local function wire_type_for(field)
    local kind = field.kind
    if kind == 'scalar' then return scalar[field.proto_type].wire end
    if kind == 'enum'   then return wire.WIRE_VARINT end
    if kind == 'message' then return wire.WIRE_LEN end
    error("wire_type_for: unknown kind " .. tostring(kind), 0)
end

-- encode_field writes one field's bytes to `out`. When `force` is true,
-- proto3 default-value elision is disabled (used for oneof branches where
-- the user's intent to set a default value is meaningful).
local function encode_field(field, value, out, force)
    local id   = field.id
    local kind = field.kind

    if kind == 'map' then
        if value == nil or next(value) == nil then return end
        local tag = wire.encode_tag(id, wire.WIRE_LEN)
        local key_field, value_field = field.key, field.value
        local key_tag = wire.encode_tag(1, wire_type_for(key_field))
        local val_tag = wire.encode_tag(2, wire_type_for(value_field))
        for k, v in pairs(value) do
            local entry = {}
            -- Defaults round-trip through proto3 elision; emit only non-defaults.
            if not is_default_scalar(key_field.proto_type or '', k) then
                entry[#entry + 1] = key_tag
                entry[#entry + 1] = encode_one(key_field, k)
            end
            local v_kind = value_field.kind
            local skip_v = false
            if v_kind == 'scalar' then
                skip_v = is_default_scalar(value_field.proto_type, v)
            elseif v_kind == 'enum' then
                skip_v = (encode_enum_value(value_field.enum, v) == 0)
            end
            if not skip_v then
                entry[#entry + 1] = val_tag
                entry[#entry + 1] = encode_one(value_field, v)
            end
            out[#out + 1] = tag
            out[#out + 1] = wire.encode_len(table.concat(entry))
        end
        return
    end

    if field.repeated then
        if value == nil or #value == 0 then return end

        if kind == 'scalar' then
            local h = scalar[field.proto_type]
            if not h then error("unknown scalar " .. tostring(field.proto_type), 0) end

            if field.packed and h.packable then
                local parts = {}
                for i = 1, #value do parts[i] = h.encode(value[i]) end
                local payload = table.concat(parts)
                out[#out + 1] = wire.encode_tag(id, wire.WIRE_LEN)
                out[#out + 1] = wire.encode_len(payload)
            else
                local tag = wire.encode_tag(id, h.wire)
                for i = 1, #value do
                    out[#out + 1] = tag
                    out[#out + 1] = h.encode(value[i])
                end
            end
        elseif kind == 'enum' then
            -- Repeated enums are packed by default in proto3.
            if field.packed ~= false then
                local parts = {}
                for i = 1, #value do
                    parts[i] = wire.encode_varint(encode_enum_value(field.enum, value[i]))
                end
                out[#out + 1] = wire.encode_tag(id, wire.WIRE_LEN)
                out[#out + 1] = wire.encode_len(table.concat(parts))
            else
                local tag = wire.encode_tag(id, wire.WIRE_VARINT)
                for i = 1, #value do
                    out[#out + 1] = tag
                    out[#out + 1] = wire.encode_varint(encode_enum_value(field.enum, value[i]))
                end
            end
        elseif kind == 'message' then
            local tag = wire.encode_tag(id, wire.WIRE_LEN)
            for i = 1, #value do
                out[#out + 1] = tag
                out[#out + 1] = wire.encode_len(encode_msg(field.message, value[i]))
            end
        elseif kind == 'group' then
            -- Proto2 repeated group: each element brackets its own
            -- SGROUP/EGROUP tag pair around the encoded body.
            local stag = wire.encode_tag(id, wire.WIRE_SGROUP)
            local etag = wire.encode_tag(id, wire.WIRE_EGROUP)
            for i = 1, #value do
                out[#out + 1] = stag
                out[#out + 1] = encode_msg(field.message, value[i])
                out[#out + 1] = etag
            end
        else
            error("unknown field kind " .. tostring(kind), 0)
        end
        return
    end

    -- Singular field
    if value == nil then return end

    if kind == 'scalar' then
        if not force and is_default_scalar(field.proto_type, value) then return end
        local h = scalar[field.proto_type]
        if not h then error("unknown scalar " .. tostring(field.proto_type), 0) end
        out[#out + 1] = wire.encode_tag(id, h.wire)
        out[#out + 1] = h.encode(value)
    elseif kind == 'enum' then
        local n = encode_enum_value(field.enum, value)
        if not force and n == 0 then return end  -- proto3 default
        out[#out + 1] = wire.encode_tag(id, wire.WIRE_VARINT)
        out[#out + 1] = wire.encode_varint(n)
    elseif kind == 'message' then
        out[#out + 1] = wire.encode_tag(id, wire.WIRE_LEN)
        out[#out + 1] = wire.encode_len(encode_msg(field.message, value))
    elseif kind == 'group' then
        out[#out + 1] = wire.encode_tag(id, wire.WIRE_SGROUP)
        out[#out + 1] = encode_msg(field.message, value)
        out[#out + 1] = wire.encode_tag(id, wire.WIRE_EGROUP)
    else
        error("unknown field kind " .. tostring(kind), 0)
    end
end

-- ---------------------------------------------------------------------------
-- Per-field "writer" specialization
--
-- For shapes we can specialize (singular scalar/enum/message without
-- presence semantics on the hot path), build a monomorphic closure at
-- finalize-time that knows its tag bytes, encoder, and default predicate.
-- The encode_message loop calls writers in order. Eliminates per-field
-- kind/proto_type dispatch and the inlined `is_default_scalar` predicate
-- — both of which create side-trace-can't-stitch-back-to-parent bridges
-- in LuaJIT 2.1 when the trace recorder sees mixed shapes across fields.
--
-- Shapes that fall through to encode_field (no writer set):
--   - map fields (need `pairs()` over user data; can't be helped)
--   - fields inside a oneof (active-branch dispatch happens in encode_message)
-- ---------------------------------------------------------------------------

local function build_repeated_writer(f)
    local fname = f.name
    local kind  = f.kind

    if kind == 'scalar' then
        local handler = scalar[f.proto_type]
        if not handler then return nil end
        local encode_value = handler.encode

        -- Split length-prefix emission: emit `tag → varint(#payload)
        -- → payload` as three separate `out` slots instead of letting
        -- `wire.encode_len` concatenate the prefix and body. Saves the
        -- per-field string allocation; table.concat at the end joins
        -- everything in one pass. Mirror of the inline.go codegen
        -- change for full mode.
        if f.packed and handler.packable then
            local tag_bytes = wire.encode_tag(f.id, wire.WIRE_LEN)
            return function(data, out)
                local v = data[fname]
                if v == nil then return end
                local nv = #v
                if nv == 0 then return end
                local parts = {}
                for i = 1, nv do parts[i] = encode_value(v[i]) end
                local payload = table.concat(parts)
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = wire.encode_varint(#payload)
                out[n + 3] = payload
            end
        end

        -- Unpacked repeated string/bytes: split each element's length
        -- prefix from its body, same rationale as above.
        if f.proto_type == 'string' or f.proto_type == 'bytes' then
            local tag_bytes = wire.encode_tag(f.id, handler.wire)
            return function(data, out)
                local v = data[fname]
                if v == nil then return end
                local nv = #v
                if nv == 0 then return end
                local n = #out
                for i = 1, nv do
                    local s = v[i]
                    n = n + 1; out[n] = tag_bytes
                    n = n + 1; out[n] = wire.encode_varint(#s)
                    n = n + 1; out[n] = s
                end
            end
        end

        -- Unpacked repeated numeric/bool scalar: not length-delimited,
        -- emit tag + encoded value per element.
        local tag_bytes = wire.encode_tag(f.id, handler.wire)
        return function(data, out)
            local v = data[fname]
            if v == nil then return end
            local nv = #v
            if nv == 0 then return end
            local n = #out
            for i = 1, nv do
                n = n + 1; out[n] = tag_bytes
                n = n + 1; out[n] = encode_value(v[i])
            end
        end
    end

    if kind == 'message' then
        local sub_desc  = f.message
        local tag_bytes = wire.encode_tag(f.id, wire.WIRE_LEN)
        return function(data, out)
            local v = data[fname]
            if v == nil then return end
            local nv = #v
            if nv == 0 then return end
            local n = #out
            for i = 1, nv do
                local body = encode_msg(sub_desc, v[i])
                n = n + 1; out[n] = tag_bytes
                n = n + 1; out[n] = wire.encode_varint(#body)
                n = n + 1; out[n] = body
            end
        end
    end

    if kind == 'group' then
        local sub_desc = f.message
        local stag = wire.encode_tag(f.id, wire.WIRE_SGROUP)
        local etag = wire.encode_tag(f.id, wire.WIRE_EGROUP)
        return function(data, out)
            local v = data[fname]
            if v == nil then return end
            local nv = #v
            if nv == 0 then return end
            local n = #out
            for i = 1, nv do
                n = n + 1; out[n] = stag
                n = n + 1; out[n] = encode_msg(sub_desc, v[i])
                n = n + 1; out[n] = etag
            end
        end
    end

    if kind == 'enum' then
        local enum_desc = f.enum
        -- proto3 default: repeated enums are packed unless explicitly disabled.
        if f.packed ~= false then
            local tag_bytes = wire.encode_tag(f.id, wire.WIRE_LEN)
            return function(data, out)
                local v = data[fname]
                if v == nil then return end
                local nv = #v
                if nv == 0 then return end
                local parts = {}
                for i = 1, nv do
                    parts[i] = wire.encode_varint(encode_enum_value(enum_desc, v[i]))
                end
                local payload = table.concat(parts)
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = wire.encode_varint(#payload)
                out[n + 3] = payload
            end
        end
        local tag_bytes = wire.encode_tag(f.id, wire.WIRE_VARINT)
        return function(data, out)
            local v = data[fname]
            if v == nil then return end
            local nv = #v
            if nv == 0 then return end
            local n = #out
            for i = 1, nv do
                n = n + 1; out[n] = tag_bytes
                n = n + 1; out[n] = wire.encode_varint(encode_enum_value(enum_desc, v[i]))
            end
        end
    end

    return nil
end

-- build_required_writer specializes for proto2 `required` singular fields:
-- error if the value is missing, never elide (defaults are not skipped).
-- Required is mutually exclusive with repeated/map/oneof, so this only
-- handles singular scalar/enum/message. `owner_name` is the parent
-- message's full name; threaded through compile_writers so the missing-
-- field error tells the caller which message they were encoding.
local function build_required_writer(f, owner_name)
    local fname = f.name
    local kind  = f.kind
    local missing_msg = "required field missing on encode: "
        .. tostring(owner_name) .. "." .. tostring(f.name)

    if kind == 'scalar' then
        local handler = scalar[f.proto_type]
        if not handler then return nil end
        local tag_bytes    = wire.encode_tag(f.id, handler.wire)
        local encode_value = handler.encode
        local proto_type   = f.proto_type
        if proto_type == 'string' or proto_type == 'bytes' then
            return function(data, out)
                local v = data[fname]
                if v == nil then error(missing_msg, 0) end
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = wire.encode_varint(#v)
                out[n + 3] = v
            end
        end
        return function(data, out)
            local v = data[fname]
            if v == nil then error(missing_msg, 0) end
            local n = #out
            out[n + 1] = tag_bytes
            out[n + 2] = encode_value(v)
        end
    end

    if kind == 'enum' then
        local enum_desc = f.enum
        local tag_bytes = wire.encode_tag(f.id, wire.WIRE_VARINT)
        return function(data, out)
            local v = data[fname]
            if v == nil then error(missing_msg, 0) end
            local n_enum = encode_enum_value(enum_desc, v)
            local n = #out
            out[n + 1] = tag_bytes
            out[n + 2] = wire.encode_varint(n_enum)
        end
    end

    if kind == 'message' then
        local sub_desc  = f.message
        local tag_bytes = wire.encode_tag(f.id, wire.WIRE_LEN)
        return function(data, out)
            local v = data[fname]
            if v == nil and type(v) ~= 'cdata' then error(missing_msg, 0) end
            local body = encode_msg(sub_desc, v)
            local n = #out
            out[n + 1] = tag_bytes
            out[n + 2] = wire.encode_varint(#body)
            out[n + 3] = body
        end
    end

    return nil
end

local function build_writer(f, owner_name)
    -- Maps and oneof branches keep going through encode_field.
    if f.kind == 'map' or f.oneof then return nil end

    if f.required then return build_required_writer(f, owner_name) end

    if f.repeated then return build_repeated_writer(f) end

    local fname  = f.name
    local kind   = f.kind
    local optional = f.optional

    if kind == 'scalar' then
        local handler = scalar[f.proto_type]
        if not handler then return nil end
        local tag_bytes    = wire.encode_tag(f.id, handler.wire)
        local encode_value = handler.encode
        local proto_type   = f.proto_type

        if optional then
            return function(data, out)
                local v = data[fname]
                if v == nil then return end
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = encode_value(v)
            end
        end

        if proto_type == 'string' or proto_type == 'bytes' then
            -- Split: emit tag + varint(#v) + v as three separate `out`
            -- slots, avoiding the per-field `varint(#v) .. v` concat
            -- that `encode_value` (== wire.encode_string/bytes) would
            -- do. See packed/repeated writers above for the rationale.
            return function(data, out)
                local v = data[fname]
                if v == nil or v == '' then return end
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = wire.encode_varint(#v)
                out[n + 3] = v
            end
        end
        if proto_type == 'bool' then
            return function(data, out)
                local v = data[fname]
                if v == nil or v == false then return end
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = encode_value(v)
            end
        end
        -- Numeric scalar (int32/uint32/int64/uint64/sint32/sint64/
        -- fixed32/sfixed32/fixed64/sfixed64/float/double). For cdata
        -- 64-bit values, `v == 0` is the LuaJIT-canonical default
        -- check — it works across UINT64 / INT64 because cdata-to-
        -- number comparison normalizes via int64.
        --
        -- Float/double need a sign-bit guard so -0.0 isn't elided. `1/v
        -- == -math.huge` short-circuits via the prior `v == 0` test, so
        -- the cost lands only on the rare zero-valued field — and the
        -- proto3 conformance corpus pins that -0 must survive a
        -- round-trip.
        if proto_type == 'float' or proto_type == 'double' then
            return function(data, out)
                local v = data[fname]
                if v == nil or (v == 0 and 1 / v == math.huge) then return end
                local n = #out
                out[n + 1] = tag_bytes
                out[n + 2] = encode_value(v)
            end
        end
        return function(data, out)
            local v = data[fname]
            if v == nil or v == 0 then return end
            local n = #out
            out[n + 1] = tag_bytes
            out[n + 2] = encode_value(v)
        end
    end

    if kind == 'enum' then
        local enum_desc = f.enum
        local tag_bytes = wire.encode_tag(f.id, wire.WIRE_VARINT)
        return function(data, out)
            local v = data[fname]
            if v == nil then return end
            local n_enum = encode_enum_value(enum_desc, v)
            if not optional and n_enum == 0 then return end
            local n = #out
            out[n + 1] = tag_bytes
            out[n + 2] = wire.encode_varint(n_enum)
        end
    end

    if kind == 'message' then
        local sub_desc  = f.message
        local tag_bytes = wire.encode_tag(f.id, wire.WIRE_LEN)
        return function(data, out)
            local v = data[fname]
            -- box.NULL equals nil under Tarantool's cdata metamethod, but
            -- google.protobuf.Value uses box.NULL as the canonical
            -- null_value sentinel — its sub_desc.encode handles it. Only
            -- treat the field as absent if it's actually nil (no cdata).
            if v == nil and type(v) ~= 'cdata' then return end
            local body = encode_msg(sub_desc, v)
            local n = #out
            out[n + 1] = tag_bytes
            out[n + 2] = wire.encode_varint(#body)
            out[n + 3] = body
        end
    end

    if kind == 'group' then
        local sub_desc = f.message
        local stag = wire.encode_tag(f.id, wire.WIRE_SGROUP)
        local etag = wire.encode_tag(f.id, wire.WIRE_EGROUP)
        return function(data, out)
            local v = data[fname]
            if v == nil and type(v) ~= 'cdata' then return end
            local n = #out
            out[n + 1] = stag
            out[n + 2] = encode_msg(sub_desc, v)
            out[n + 3] = etag
        end
    end

    return nil
end

-- Expose encode_field for callers that need to emit a single field's bytes
-- without walking a full message (e.g. lazy passthrough re-encode, which
-- splices original wire segments for untouched fields and calls
-- encode_field for the dirty ones).
---@param field pb.Field
---@param value any
---@param out   string[]    table.concat-friendly chunk buffer; encoded bytes are appended
---@param force? boolean    bypass proto3 default-value elision (used for extensions and inside oneofs)
M.encode_field = function(field, value, out, force)
    return encode_field(field, value, out, force)
end

-- compile_writers attaches `f._writer` to each field where the shape is
-- specialized. Called from pb.finalize_message after the oneof flatten.
---@param desc pb.Descriptor
function M.compile_writers(desc)
    for _, f in ipairs(desc.fields) do
        f._writer = build_writer(f, desc.name)
    end
end

-- compile_encode_body emits a per-descriptor `_encode_body(data, out, active)`
-- function with one **monomorphic** call site per field. Replaces the old
-- generic loop in `encode_message` whose `writer(data, out)` call was
-- megamorphic (different closure each iteration), which fragmented the
-- runtime-mode encode trace topology into 3× the side traces of full mode
-- (see bench/jit_trace.lua measurements pre-fix).
--
-- The generated source looks like:
--
--   local _u = ...
--   return function(data, out, active)
--     _u[2](data, out)
--     _u[3](data, out)
--     if active and active['choice'] == 'a' then _u[1](_u[4], data['a'], out, true) end
--   end
--
-- `_u` is a single upvalue (avoids LuaJIT's 60-upvalue function limit;
-- TestAllTypesProto2 has ~140 fields). With literal-int keys against a
-- stable array, TGETI is specialized on trace and the call target lifts
-- to a constant per call site — same trace stability as direct upvalues.
---@param desc pb.Descriptor
function M.compile_encode_body(desc)
    local fields = desc.fields
    local refs = {}
    local function bind(value)
        refs[#refs + 1] = value
        return '_u[' .. #refs .. ']'
    end

    local ef = bind(encode_field)
    local body = {}
    for i = 1, #fields do
        local f = fields[i]
        local writer = f._writer
        if writer ~= nil then
            local w = bind(writer)
            body[#body + 1] = w .. '(data, out)'
        elseif f.oneof then
            local fb = bind(f)
            body[#body + 1] = string.format(
                "if active and active[%q] == %q then %s(%s, data[%q], out, true) end",
                f.oneof, f.name, ef, fb, f.name)
        else
            local fb = bind(f)
            local force = f.optional and 'true' or 'false'
            body[#body + 1] = string.format(
                "%s(%s, data[%q], out, %s)",
                ef, fb, f.name, force)
        end
    end

    if #body == 0 then
        desc._encode_body = function(_data, _out, _active) end
        return
    end

    local src = "local _u = ...\nreturn function(data, out, active)\n"
        .. table.concat(body, '\n') .. "\nend\n"
    local chunkname = '=pb_encode_body:' .. tostring(desc.name or '?')
    local chunk, err = loadstring(src, chunkname)
    if not chunk then
        error('compile_encode_body: ' .. tostring(err) .. '\n' .. src, 0)
    end
    desc._encode_body = chunk(refs)
end

-- ---------------------------------------------------------------------------
-- Per-field "reader" specialization, mirror of writers above. Each reader
-- has signature `(buf, pos, wt, result) -> new_pos` and bakes in the field
-- name, decode function, packed-detection, repeated-list bookkeeping,
-- nested-message merge rules, and oneof sibling clearing — so the
-- decode_message hot loop is just `pos = reader(buf, pos, wt, result)`.
--
-- Map fields fall through to the existing in-loop dispatch (they decode
-- one entry per wire-encounter, which is awkward to express as a closure
-- without churning the result table); same as on the encoder side.
-- ---------------------------------------------------------------------------

-- build_repeated_reader / build_reader are parameterized by the scalar
-- handler table and the sub-message dispatcher so the same builders can
-- emit either the standard validating readers (scalar_tbl=scalar,
-- decode_msg_fn=decode_msg) or the unsafe readers
-- (scalar_tbl=scalar_unsafe, decode_msg_fn=decode_msg_unsafe). All
-- references that would otherwise tie the closure to the safe path
-- (handler.decode capture, decode_msg, decode_group) flow through the
-- arguments. Compile-time capture: the closures bind these upvalues
-- by value, so a runtime swap on `scalar` afterwards has no effect —
-- that's why the parallel unsafe path exists.
local function build_repeated_reader(f, scalar_tbl, decode_msg_fn, decode_group_fn)
    local fname = f.name
    local kind  = f.kind
    local siblings = f.oneof_siblings  -- nil if not in a oneof

    if kind == 'scalar' then
        local handler = scalar_tbl[f.proto_type]
        if not handler then return nil end
        local decode_value = handler.decode
        local packable = handler.packable and (handler.wire ~= wire.WIRE_LEN)
        local WIRE_LEN = wire.WIRE_LEN
        local decode_len_fn = wire.decode_len
        return function(buf, pos, wt, result, depth)
            local list = result[fname]
            if list == nil then list = {}; result[fname] = list end
            if packable and wt == WIRE_LEN then
                local payload, np = decode_len_fn(buf, pos)
                local p, lim = 1, #payload
                local n = #list
                while p <= lim do
                    local v, np2 = decode_value(payload, p)
                    n = n + 1; list[n] = v
                    p = np2
                end
                return np
            end
            local v, np = decode_value(buf, pos)
            list[#list + 1] = v
            return np
        end
    end

    if kind == 'enum' then
        local WIRE_LEN = wire.WIRE_LEN
        local decode_len_fn = wire.decode_len
        local decode_varint_fn = wire.decode_varint
        local varint_to_int32 = wire.varint_to_int32
        return function(buf, pos, wt, result, depth)
            local list = result[fname]
            if list == nil then list = {}; result[fname] = list end
            if wt == WIRE_LEN then
                local payload, np = decode_len_fn(buf, pos)
                local p, lim = 1, #payload
                local n = #list
                while p <= lim do
                    local u, np2 = decode_varint_fn(payload, p)
                    n = n + 1; list[n] = varint_to_int32(u)
                    p = np2
                end
                return np
            end
            local u, np = decode_varint_fn(buf, pos)
            list[#list + 1] = varint_to_int32(u)
            return np
        end
    end

    if kind == 'message' then
        local sub_desc = f.message
        local decode_len_fn = wire.decode_len
        return function(buf, pos, wt, result, depth)
            local list = result[fname]
            if list == nil then list = {}; result[fname] = list end
            local payload, np = decode_len_fn(buf, pos)
            list[#list + 1] = decode_msg_fn(sub_desc, payload, depth + 1)
            return np
        end
    end

    if kind == 'group' then
        local sub_desc = f.message
        local stop_id  = f.id
        return function(buf, pos, wt, result, depth)
            local list = result[fname]
            if list == nil then list = {}; result[fname] = list end
            local decoded, np = decode_group_fn(sub_desc, buf, pos, stop_id, depth + 1)
            list[#list + 1] = decoded
            return np
        end
    end

    return nil
end

local function build_reader(f, scalar_tbl, decode_msg_fn, decode_group_fn)
    -- Maps stay on the in-loop dispatch path.
    if f.kind == 'map' then return nil end

    local fname = f.name
    local kind  = f.kind
    local siblings = f.oneof_siblings  -- nil if not in a oneof

    if f.repeated then return build_repeated_reader(f, scalar_tbl, decode_msg_fn, decode_group_fn) end

    if kind == 'scalar' then
        local handler = scalar_tbl[f.proto_type]
        if not handler then return nil end
        local decode_value = handler.decode
        if siblings then
            return function(buf, pos, wt, result, depth)
                local v, np = decode_value(buf, pos)
                result[fname] = v
                for i = 1, #siblings do result[siblings[i]] = nil end
                return np
            end
        end
        return function(buf, pos, wt, result, depth)
            local v, np = decode_value(buf, pos)
            result[fname] = v
            return np
        end
    end

    if kind == 'enum' then
        local decode_varint_fn = wire.decode_varint
        local varint_to_int32 = wire.varint_to_int32
        if siblings then
            return function(buf, pos, wt, result, depth)
                local u, np = decode_varint_fn(buf, pos)
                result[fname] = varint_to_int32(u)
                for i = 1, #siblings do result[siblings[i]] = nil end
                return np
            end
        end
        return function(buf, pos, wt, result, depth)
            local u, np = decode_varint_fn(buf, pos)
            result[fname] = varint_to_int32(u)
            return np
        end
    end

    if kind == 'message' then
        local sub_desc = f.message
        local decode_len_fn = wire.decode_len
        local has_custom_decode = sub_desc.decode ~= nil
        -- Per-spec: a repeated occurrence of a singular-message field merges
        -- into the previous value — scalars last-wins, repeated fields
        -- concatenate, sub-messages merge recursively, map fields take
        -- last-wins per key. This applies to oneof branches too; sibling
        -- clearing below enforces oneof exclusivity. WKT (custom decode)
        -- opts out because its decoded value is not a Lua table.
        if has_custom_decode then
            if siblings then
                return function(buf, pos, wt, result, depth)
                    local payload, np = decode_len_fn(buf, pos)
                    result[fname] = decode_msg_fn(sub_desc, payload, depth + 1)
                    for i = 1, #siblings do result[siblings[i]] = nil end
                    return np
                end
            end
            return function(buf, pos, wt, result, depth)
                local payload, np = decode_len_fn(buf, pos)
                result[fname] = decode_msg_fn(sub_desc, payload, depth + 1)
                return np
            end
        end
        if siblings then
            return function(buf, pos, wt, result, depth)
                local payload, np = decode_len_fn(buf, pos)
                local decoded = decode_msg_fn(sub_desc, payload, depth + 1)
                local prev = result[fname]
                if prev == nil then
                    result[fname] = decoded
                else
                    M.merge_message(sub_desc, prev, decoded)
                end
                for i = 1, #siblings do result[siblings[i]] = nil end
                return np
            end
        end
        return function(buf, pos, wt, result, depth)
            local payload, np = decode_len_fn(buf, pos)
            local decoded = decode_msg_fn(sub_desc, payload, depth + 1)
            local prev = result[fname]
            if prev == nil then
                result[fname] = decoded
            else
                M.merge_message(sub_desc, prev, decoded)
            end
            return np
        end
    end

    if kind == 'group' then
        local sub_desc = f.message
        local stop_id  = f.id
        if siblings then
            return function(buf, pos, wt, result, depth)
                local decoded, np = decode_group_fn(sub_desc, buf, pos, stop_id, depth + 1)
                local prev = result[fname]
                if prev == nil then
                    result[fname] = decoded
                else
                    M.merge_message(sub_desc, prev, decoded)
                end
                for i = 1, #siblings do result[siblings[i]] = nil end
                return np
            end
        end
        return function(buf, pos, wt, result, depth)
            local decoded, np = decode_group_fn(sub_desc, buf, pos, stop_id, depth + 1)
            local prev = result[fname]
            if prev == nil then
                result[fname] = decoded
            else
                M.merge_message(sub_desc, prev, decoded)
            end
            return np
        end
    end

    return nil
end

---@param desc pb.Descriptor
function M.compile_readers(desc)
    for _, f in ipairs(desc.fields) do
        f._reader = build_reader(f, scalar, decode_msg, decode_group)
    end
end

-- compile_readers_unsafe builds the parallel f._reader_unsafe set
-- against the swapped scalar table (string -> bytes) and the unsafe
-- sub-message / group dispatchers. Called by pb.finalize_message right
-- after compile_readers so every descriptor carries both reader shapes
-- and pb.decode_unsafe stays at full reader-fastpath speed.
---@param desc pb.Descriptor
function M.compile_readers_unsafe(desc)
    for _, f in ipairs(desc.fields) do
        f._reader_unsafe = build_reader(f, scalar_unsafe,
            decode_msg_unsafe, decode_group_unsafe)
    end
end

---@param desc pb.Descriptor
---@param data table              message contents keyed by proto field name
---@return string                 wire-format bytes (proto3 / proto2)
encode_message = function(desc, data)
    if type(data) ~= 'table' then
        error(("expected table for message %s, got %s"):format(desc.name, type(data)), 0)
    end
    local out = {}

    -- For each oneof, pick the active branch (last set in declaration order).
    -- Iterate via `desc.oneofs_list` (an array) rather than the hash-keyed
    -- `desc.oneofs` so this stays on a single JIT trace — `pairs()` over a
    -- hash compiles to bytecode ISNEXT, which is NYI in LuaJIT 2.1.
    local active  -- {[oneof_name] = field_name} or nil
    local oolist = desc.oneofs_list
    if oolist then
        active = {}
        for i = 1, #oolist do
            local oo = oolist[i]
            local members = oo.members
            for j = 1, #members do
                local fname = members[j]
                if data[fname] ~= nil then active[oo.name] = fname end
            end
        end
    end

    -- Per-field dispatch: prefer the compiled body (one monomorphic call
    -- site per field; emitted by compile_encode_body at finalize-time).
    -- The pre-finalize fallback below covers descriptors that haven't
    -- been through pb.finalize_message yet (defensive — should not hit
    -- on any normal code path).
    local body = desc._encode_body
    if body ~= nil then
        body(data, out, active)
    else
        local fields = desc.fields
        for i = 1, #fields do
            local f = fields[i]
            local writer = f._writer
            if writer ~= nil then
                writer(data, out)
            elseif f.oneof then
                if active and active[f.oneof] == f.name then
                    encode_field(f, data[f.name], out, true)
                end
            else
                encode_field(f, data[f.name], out, f.optional)
            end
        end
    end
    -- Proto2 extensions: data._extensions = { [full_name] = value, ... }.
    -- Walk via the parallel array `extensions_list` rather than `pairs()`
    -- over a hash — pairs() compiles to bytecode ISNEXT, which is NYI in
    -- Tarantool's LuaJIT 2.1 fork (same limitation that gates map encode).
    -- pb.register_extension keeps the array in registration order, which
    -- is also the deterministic on-wire order.
    local exts = data._extensions
    if exts ~= nil then
        local elist = desc.extensions_list
        if elist ~= nil then
            for i = 1, #elist do
                local ext = elist[i]
                local v = exts[ext.full_name]
                if v ~= nil then
                    encode_field(ext, v, out, true)
                end
            end
        end
    end
    -- Preserve unknown fields captured at decode time.
    local uf = data._unknown_fields
    if uf ~= nil and uf ~= '' then out[#out + 1] = uf end
    return table.concat(out)
end
M.encode = encode_message

-- ---------------------------------------------------------------------------
-- Decode
-- ---------------------------------------------------------------------------

local decode_message

-- decode_msg dispatches to a descriptor's custom decode (WKT) when present.
-- Assigned to the forward declaration near the top so reader closures
-- built by compile_readers can capture it.
-- `depth` is the nesting level of the message being decoded (0, or nil,
-- for the top level); it reaches custom decoders too, since Struct /
-- Value / ListValue recurse on their own.
decode_msg = function(desc, buf, depth)
    if desc.decode then return desc.decode(buf, depth) end
    return decode_message(desc, buf, depth)
end

-- decode_one returns (value, new_pos) for a single value based on field kind.
-- scalar_tbl and decode_msg_fn are parameterized so the same helper serves
-- both the validating (decode_message) and unsafe (decode_message_unsafe)
-- map fallback paths.
local function decode_one(field, buf, pos, scalar_tbl, decode_msg_fn, depth)
    local kind = field.kind
    if kind == 'scalar' then
        return scalar_tbl[field.proto_type].decode(buf, pos)
    elseif kind == 'enum' then
        local u, np = wire.decode_varint(buf, pos)
        return wire.varint_to_int32(u), np
    elseif kind == 'message' then
        local payload, np = wire.decode_len(buf, pos)
        return decode_msg_fn(field.message, payload, depth), np
    end
    error("decode_one: unknown kind " .. tostring(kind), 0)
end

-- default_value returns the proto3 zero value for a (sub-)field descriptor.
local function default_value(field)
    local kind = field.kind
    if kind == 'scalar' then
        local pt = field.proto_type
        if pt == 'string' or pt == 'bytes' then return '' end
        if pt == 'bool' then return false end
        return 0
    elseif kind == 'enum' then
        return 0
    elseif kind == 'message' then
        return {}
    end
    error("default_value: unknown kind " .. tostring(kind), 0)
end

local function decode_packed(field, payload)
    local h = scalar[field.proto_type]
    if not h then error("packed unknown scalar " .. tostring(field.proto_type), 0) end
    local out, pos, len = {}, 1, #payload
    local n = 0
    while pos <= len do
        local v, np = h.decode(payload, pos)
        n = n + 1
        out[n] = v
        pos = np
    end
    return out
end

-- decode_group: proto2 group body decoder. Reads tags out of `buf` starting
-- at `pos` until it finds an EGROUP tag whose field id matches `stop_id`.
-- Returns the decoded table and the position immediately past the EGROUP.
-- Mirrors decode_message's per-tag dispatch but stops on EGROUP instead of
-- end-of-buffer. Forward-declared near the top of the file so reader
-- closures built by compile_readers can capture it before this assignment.
decode_group = function(desc, buf, pos, stop_id, depth)
    -- depth is optional for generated modules predating the limit.
    depth = depth or 1
    if depth > RECURSION_LIMIT then wire.recursion_limit_error() end
    local result  = {}
    local fbi     = desc.field_by_id
    local len     = #buf
    local WIRE_EG = wire.WIRE_EGROUP
    local unknown
    while pos <= len do
        local tag_start = pos
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if wt == WIRE_EG then
            if id ~= stop_id then
                error(("EGROUP id %d does not match SGROUP id %d"):
                    format(id, stop_id), 0)
            end
            if unknown ~= nil then
                result._unknown_fields = table.concat(unknown)
            end
            return result, pos
        end
        local f = fbi[id]
        if f == nil then
            pos = wire.skip_field(buf, pos, wt, id)
            if unknown == nil then unknown = {} end
            unknown[#unknown + 1] = buf:sub(tag_start, pos - 1)
        else
            local reader = f._reader
            if reader ~= nil then
                pos = reader(buf, pos, wt, result, depth)
            else
                -- Slow-path map decode mirrors decode_message; groups
                -- containing maps are exotic but we handle them.
                pos = wire.skip_field(buf, pos, wt, id)
            end
        end
    end
    error("group not terminated by EGROUP id " .. tostring(stop_id), 0)
end
M.decode_group = decode_group

-- decode_extension routes wire bytes for a registered proto2 extension into
-- result._extensions[ext.full_name]. Mirrors the in-line decode dispatch on
-- field kind (scalar/enum/message/group, singular/repeated). Returns the
-- new buffer position after the value bytes.
-- Exposed for inline-mode generated code: the per-message decoder calls
-- decode_extension when it sees an unknown tag that matches a registered
-- extension on the descriptor.
local decode_extension
function M.decode_extension(...) return decode_extension(...) end

decode_extension = function(ext, buf, pos, wt, result, depth)
    -- depth is the extendee's level; optional for older generated modules.
    depth = depth or 0
    local exts = result._extensions
    if exts == nil then exts = {}; result._extensions = exts end
    local key = ext.full_name
    local kind = ext.kind

    if ext.repeated then
        local list = exts[key]
        if list == nil then list = {}; exts[key] = list end
        if kind == 'scalar' then
            local h = scalar[ext.proto_type]
            if h.packable and wt == wire.WIRE_LEN and h.wire ~= wire.WIRE_LEN then
                local payload, np = wire.decode_len(buf, pos)
                local items = decode_packed(ext, payload)
                local base = #list
                for i = 1, #items do list[base + i] = items[i] end
                return np
            end
            local v, np = h.decode(buf, pos)
            list[#list + 1] = v
            return np
        elseif kind == 'enum' then
            if wt == wire.WIRE_LEN then
                local payload, np = wire.decode_len(buf, pos)
                local p2, lim = 1, #payload
                while p2 <= lim do
                    local u, np2 = wire.decode_varint(payload, p2)
                    p2 = np2
                    list[#list + 1] = wire.varint_to_int32(u)
                end
                return np
            end
            local u, np = wire.decode_varint(buf, pos)
            list[#list + 1] = wire.varint_to_int32(u)
            return np
        elseif kind == 'message' then
            local payload, np = wire.decode_len(buf, pos)
            list[#list + 1] = decode_msg(ext.message, payload, depth + 1)
            return np
        elseif kind == 'group' then
            local decoded, np = decode_group(ext.message, buf, pos, ext.id, depth + 1)
            list[#list + 1] = decoded
            return np
        end
        error("decode_extension: unknown repeated kind " .. tostring(kind), 0)
    end

    -- Singular: decode and assign (last-wins for scalars/enums; merge for messages).
    if kind == 'scalar' then
        local h = scalar[ext.proto_type]
        local v, np = h.decode(buf, pos)
        exts[key] = v
        return np
    elseif kind == 'enum' then
        local u, np = wire.decode_varint(buf, pos)
        exts[key] = wire.varint_to_int32(u)
        return np
    elseif kind == 'message' then
        local payload, np = wire.decode_len(buf, pos)
        local decoded = decode_msg(ext.message, payload, depth + 1)
        local prev = exts[key]
        if prev == nil then
            exts[key] = decoded
        else
            M.merge_message(ext.message, prev, decoded)
        end
        return np
    elseif kind == 'group' then
        local decoded, np = decode_group(ext.message, buf, pos, ext.id, depth + 1)
        local prev = exts[key]
        if prev == nil then
            exts[key] = decoded
        else
            M.merge_message(ext.message, prev, decoded)
        end
        return np
    end
    error("decode_extension: unknown kind " .. tostring(kind), 0)
end

---@param desc pb.Descriptor
---@param buf  string           wire-format bytes
---@param depth? integer        nesting level of this message; nil at the top
---@return table                decoded message; unknown fields go in `_unknown_fields`, extensions in `_extensions`
decode_message = function(desc, buf, depth)
    if type(buf) ~= 'string' then
        error(("expected string for decode of %s, got %s"):format(desc.name, type(buf)), 0)
    end
    depth = depth or 0
    if depth > RECURSION_LIMIT then wire.recursion_limit_error() end
    local result = {}
    local pos, len = 1, #buf
    local fbi = desc.field_by_id
    local unknown   -- list of raw tag+value byte slices, lazily allocated

    while pos <= len do
        local tag_start = pos
        local id, wt, npos = wire.decode_tag(buf, pos)
        pos = npos
        local f = fbi[id]
        if f == nil then
            -- Tag not in regular fields. Try registered proto2 extensions
            -- before treating the bytes as truly unknown.
            local ext = desc.extensions_by_id and desc.extensions_by_id[id]
            if ext ~= nil then
                pos = decode_extension(ext, buf, pos, wt, result, depth)
            else
                -- Unknown field: capture verbatim for round-trip.
                pos = wire.skip_field(buf, pos, wt, id)
                if unknown == nil then unknown = {} end
                unknown[#unknown + 1] = buf:sub(tag_start, pos - 1)
            end
        else
            local reader = f._reader
            if reader ~= nil then
                pos = reader(buf, pos, wt, result, depth)
            else
                -- Fallthrough for shapes without a specialized reader
                -- (currently only map fields).
            local kind = f.kind
            if kind == 'map' then
                local map_t = result[f.name]
                if map_t == nil then map_t = {}; result[f.name] = map_t end
                local payload, np = wire.decode_len(buf, pos)
                pos = np
                local key, val
                local ep, elim = 1, #payload
                while ep <= elim do
                    local eid, ewt
                    eid, ewt, ep = wire.decode_tag(payload, ep)
                    if eid == 1 then
                        key, ep = decode_one(f.key, payload, ep, scalar, decode_msg, depth + 1)
                    elseif eid == 2 then
                        val, ep = decode_one(f.value, payload, ep, scalar, decode_msg, depth + 1)
                    else
                        ep = wire.skip_field(payload, ep, ewt, eid)
                    end
                end
                if key == nil then key = default_value(f.key) end
                if val == nil then val = default_value(f.value) end
                -- proto3 map "last value wins" duplicate-key semantics.
                -- 64-bit integer keys are LuaJIT `int64_t`/`uint64_t`
                -- cdata; LuaJIT hashes those by pointer rather than
                -- value, so a freshly-allocated cdata from a duplicate
                -- entry lands in a different bucket than the first one
                -- even though `__eq` says they're equal. Walk the
                -- existing keys once and reuse the canonical cdata when
                -- the field's key type is gated as needing dedup
                -- (`f.key_dedup` is precomputed in `pb.finalize_message`
                -- so the hot path stays a single boolean check).
                if f.key_dedup then
                    for k in pairs(map_t) do
                        if k == key then key = k; break end
                    end
                end
                map_t[key] = val
            elseif f.repeated then
                local list = result[f.name]
                if list == nil then list = {}; result[f.name] = list end

                if kind == 'scalar' then
                    local h = scalar[f.proto_type]
                    if h.packable and wt == wire.WIRE_LEN and h.wire ~= wire.WIRE_LEN then
                        -- Packed payload: decode all elements.
                        local payload, np = wire.decode_len(buf, pos)
                        pos = np
                        local items = decode_packed(f, payload)
                        local base = #list
                        for i = 1, #items do list[base + i] = items[i] end
                    else
                        local v, np = h.decode(buf, pos)
                        list[#list + 1] = v
                        pos = np
                    end
                elseif kind == 'enum' then
                    if wt == wire.WIRE_LEN then
                        local payload, np = wire.decode_len(buf, pos)
                        pos = np
                        local p2, lim = 1, #payload
                        while p2 <= lim do
                            local u, np2 = wire.decode_varint(payload, p2)
                            p2 = np2
                            list[#list + 1] = wire.varint_to_int32(u)
                        end
                    else
                        local u, np = wire.decode_varint(buf, pos)
                        list[#list + 1] = wire.varint_to_int32(u)
                        pos = np
                    end
                elseif kind == 'message' then
                    local payload, np = wire.decode_len(buf, pos)
                    pos = np
                    list[#list + 1] = decode_msg(f.message, payload, depth + 1)
                end
            else
                -- Singular
                if kind == 'scalar' then
                    local h = scalar[f.proto_type]
                    local v, np = h.decode(buf, pos)
                    pos = np
                    result[f.name] = v
                elseif kind == 'enum' then
                    local u, np = wire.decode_varint(buf, pos)
                    pos = np
                    result[f.name] = wire.varint_to_int32(u)
                elseif kind == 'message' then
                    local payload, np = wire.decode_len(buf, pos)
                    pos = np
                    local decoded = decode_msg(f.message, payload, depth + 1)
                    -- Per spec: repeated singular message fields merge,
                    -- *unless* this is a oneof branch (exclusive). WKT
                    -- types use custom decode and aren't merged either.
                    local prev = result[f.name]
                    if prev == nil or f.oneof or f.message.decode then
                        result[f.name] = decoded
                    else
                        for k, v in pairs(decoded) do prev[k] = v end
                    end
                end
                -- Oneof: clear sibling branches.
                if f.oneof_siblings then
                    for _, s in ipairs(f.oneof_siblings) do result[s] = nil end
                end
            end
            end  -- end of `if reader ~= nil ... else ... end`
        end
    end
    if unknown ~= nil then result._unknown_fields = table.concat(unknown) end
    return result
end
M.decode = decode_message

-- ---------------------------------------------------------------------------
-- Unsafe-decode twins (opt-out of per-string utf8_len validation)
--
-- Each twin is a literal clone of its safe counterpart with three
-- substitutions:
--   * `f._reader`  → `f._reader_unsafe`  (compiled against scalar_unsafe)
--   * `decode_msg` / `decode_group` / `decode_extension` →
--     `decode_msg_unsafe` / `decode_group_unsafe` / `decode_extension_unsafe`
--   * direct `scalar[...]` accesses in the slow / extension paths →
--     `scalar_unsafe[...]` (so string fields take the bytes handler)
--
-- A factory-pattern refactor would save lines but force the reader
-- access through a string-keyed indirection (`f[reader_key]`) — that
-- regresses the hot dispatch. Literal duplication keeps both paths
-- monomorphic and lets LuaJIT specialize each independently.
--
-- WKT sub-messages keep going through `desc.decode` (no _unsafe twin in
-- pb.wkt); they have no string-validation hot path so the asymmetry is
-- intentional and matches the inline-mode behavior.
-- ---------------------------------------------------------------------------

local decode_extension_unsafe

decode_group_unsafe = function(desc, buf, pos, stop_id, depth)
    depth = depth or 1
    if depth > RECURSION_LIMIT then wire.recursion_limit_error() end
    local result  = {}
    local fbi     = desc.field_by_id
    local len     = #buf
    local WIRE_EG = wire.WIRE_EGROUP
    local unknown
    while pos <= len do
        local tag_start = pos
        local id, wt
        id, wt, pos = wire.decode_tag(buf, pos)
        if wt == WIRE_EG then
            if id ~= stop_id then
                error(("EGROUP id %d does not match SGROUP id %d"):
                    format(id, stop_id), 0)
            end
            if unknown ~= nil then
                result._unknown_fields = table.concat(unknown)
            end
            return result, pos
        end
        local f = fbi[id]
        if f == nil then
            pos = wire.skip_field(buf, pos, wt, id)
            if unknown == nil then unknown = {} end
            unknown[#unknown + 1] = buf:sub(tag_start, pos - 1)
        else
            local reader = f._reader_unsafe
            if reader ~= nil then
                pos = reader(buf, pos, wt, result, depth)
            else
                pos = wire.skip_field(buf, pos, wt, id)
            end
        end
    end
    error("group not terminated by EGROUP id " .. tostring(stop_id), 0)
end

decode_extension_unsafe = function(ext, buf, pos, wt, result, depth)
    depth = depth or 0
    local exts = result._extensions
    if exts == nil then exts = {}; result._extensions = exts end
    local key = ext.full_name
    local kind = ext.kind

    if ext.repeated then
        local list = exts[key]
        if list == nil then list = {}; exts[key] = list end
        if kind == 'scalar' then
            local h = scalar_unsafe[ext.proto_type]
            if h.packable and wt == wire.WIRE_LEN and h.wire ~= wire.WIRE_LEN then
                local payload, np = wire.decode_len(buf, pos)
                local items = decode_packed(ext, payload)
                local base = #list
                for i = 1, #items do list[base + i] = items[i] end
                return np
            end
            local v, np = h.decode(buf, pos)
            list[#list + 1] = v
            return np
        elseif kind == 'enum' then
            if wt == wire.WIRE_LEN then
                local payload, np = wire.decode_len(buf, pos)
                local p2, lim = 1, #payload
                while p2 <= lim do
                    local u, np2 = wire.decode_varint(payload, p2)
                    p2 = np2
                    list[#list + 1] = wire.varint_to_int32(u)
                end
                return np
            end
            local u, np = wire.decode_varint(buf, pos)
            list[#list + 1] = wire.varint_to_int32(u)
            return np
        elseif kind == 'message' then
            local payload, np = wire.decode_len(buf, pos)
            list[#list + 1] = decode_msg_unsafe(ext.message, payload, depth + 1)
            return np
        elseif kind == 'group' then
            local decoded, np = decode_group_unsafe(ext.message, buf, pos, ext.id, depth + 1)
            list[#list + 1] = decoded
            return np
        end
        error("decode_extension_unsafe: unknown repeated kind " .. tostring(kind), 0)
    end

    if kind == 'scalar' then
        local h = scalar_unsafe[ext.proto_type]
        local v, np = h.decode(buf, pos)
        exts[key] = v
        return np
    elseif kind == 'enum' then
        local u, np = wire.decode_varint(buf, pos)
        exts[key] = wire.varint_to_int32(u)
        return np
    elseif kind == 'message' then
        local payload, np = wire.decode_len(buf, pos)
        local decoded = decode_msg_unsafe(ext.message, payload, depth + 1)
        local prev = exts[key]
        if prev == nil then
            exts[key] = decoded
        else
            M.merge_message(ext.message, prev, decoded)
        end
        return np
    elseif kind == 'group' then
        local decoded, np = decode_group_unsafe(ext.message, buf, pos, ext.id, depth + 1)
        local prev = exts[key]
        if prev == nil then
            exts[key] = decoded
        else
            M.merge_message(ext.message, prev, decoded)
        end
        return np
    end
    error("decode_extension_unsafe: unknown kind " .. tostring(kind), 0)
end

local decode_message_unsafe = function(desc, buf, depth)
    if type(buf) ~= 'string' then
        error(("expected string for decode of %s, got %s"):format(desc.name, type(buf)), 0)
    end
    depth = depth or 0
    if depth > RECURSION_LIMIT then wire.recursion_limit_error() end
    local result = {}
    local pos, len = 1, #buf
    local fbi = desc.field_by_id
    local unknown

    while pos <= len do
        local tag_start = pos
        local id, wt, npos = wire.decode_tag(buf, pos)
        pos = npos
        local f = fbi[id]
        if f == nil then
            local ext = desc.extensions_by_id and desc.extensions_by_id[id]
            if ext ~= nil then
                pos = decode_extension_unsafe(ext, buf, pos, wt, result, depth)
            else
                pos = wire.skip_field(buf, pos, wt, id)
                if unknown == nil then unknown = {} end
                unknown[#unknown + 1] = buf:sub(tag_start, pos - 1)
            end
        else
            local reader = f._reader_unsafe
            if reader ~= nil then
                pos = reader(buf, pos, wt, result, depth)
            else
            local kind = f.kind
            if kind == 'map' then
                local map_t = result[f.name]
                if map_t == nil then map_t = {}; result[f.name] = map_t end
                local payload, np = wire.decode_len(buf, pos)
                pos = np
                local key, val
                local ep, elim = 1, #payload
                while ep <= elim do
                    local eid, ewt
                    eid, ewt, ep = wire.decode_tag(payload, ep)
                    if eid == 1 then
                        key, ep = decode_one(f.key, payload, ep, scalar_unsafe, decode_msg_unsafe, depth + 1)
                    elseif eid == 2 then
                        val, ep = decode_one(f.value, payload, ep, scalar_unsafe, decode_msg_unsafe, depth + 1)
                    else
                        ep = wire.skip_field(payload, ep, ewt, eid)
                    end
                end
                if key == nil then key = default_value(f.key) end
                if val == nil then val = default_value(f.value) end
                if f.key_dedup then
                    for k in pairs(map_t) do
                        if k == key then key = k; break end
                    end
                end
                map_t[key] = val
            elseif f.repeated then
                local list = result[f.name]
                if list == nil then list = {}; result[f.name] = list end

                if kind == 'scalar' then
                    local h = scalar_unsafe[f.proto_type]
                    if h.packable and wt == wire.WIRE_LEN and h.wire ~= wire.WIRE_LEN then
                        local payload, np = wire.decode_len(buf, pos)
                        pos = np
                        local items = decode_packed(f, payload)
                        local base = #list
                        for i = 1, #items do list[base + i] = items[i] end
                    else
                        local v, np = h.decode(buf, pos)
                        list[#list + 1] = v
                        pos = np
                    end
                elseif kind == 'enum' then
                    if wt == wire.WIRE_LEN then
                        local payload, np = wire.decode_len(buf, pos)
                        pos = np
                        local p2, lim = 1, #payload
                        while p2 <= lim do
                            local u, np2 = wire.decode_varint(payload, p2)
                            p2 = np2
                            list[#list + 1] = wire.varint_to_int32(u)
                        end
                    else
                        local u, np = wire.decode_varint(buf, pos)
                        list[#list + 1] = wire.varint_to_int32(u)
                        pos = np
                    end
                elseif kind == 'message' then
                    local payload, np = wire.decode_len(buf, pos)
                    pos = np
                    list[#list + 1] = decode_msg_unsafe(f.message, payload, depth + 1)
                end
            else
                if kind == 'scalar' then
                    local h = scalar_unsafe[f.proto_type]
                    local v, np = h.decode(buf, pos)
                    pos = np
                    result[f.name] = v
                elseif kind == 'enum' then
                    local u, np = wire.decode_varint(buf, pos)
                    pos = np
                    result[f.name] = wire.varint_to_int32(u)
                elseif kind == 'message' then
                    local payload, np = wire.decode_len(buf, pos)
                    pos = np
                    local decoded = decode_msg_unsafe(f.message, payload, depth + 1)
                    local prev = result[f.name]
                    if prev == nil or f.oneof or f.message.decode then
                        result[f.name] = decoded
                    else
                        for k, v in pairs(decoded) do prev[k] = v end
                    end
                end
                if f.oneof_siblings then
                    for _, s in ipairs(f.oneof_siblings) do result[s] = nil end
                end
            end
            end
        end
    end
    if unknown ~= nil then result._unknown_fields = table.concat(unknown) end
    return result
end

-- decode_msg_unsafe dispatches WKT custom decoders normally (they have
-- no _unsafe twin and don't run utf8_len) and routes everything else
-- through decode_message_unsafe.
decode_msg_unsafe = function(desc, buf, depth)
    if desc.decode then return desc.decode(buf, depth) end
    return decode_message_unsafe(desc, buf, depth)
end

M.decode_unsafe = decode_msg_unsafe
M.decode_group_unsafe = decode_group_unsafe
M.decode_extension_unsafe = function(...) return decode_extension_unsafe(...) end

return M
