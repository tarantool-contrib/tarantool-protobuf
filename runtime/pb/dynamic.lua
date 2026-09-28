-- Build a runtime module from a parsed .proto AST.
--
-- Output shape mirrors what protoc-gen-tarantool emits in `mode=runtime`:
--   M.<Name>_descriptor   - field descriptors usable by pb.encode/decode
--   M.<Name>_encode(t)    - table -> wire bytes
--   M.<Name>_decode(b)    - wire bytes -> table
--   M.<EnumName>          - alias for by_name table
--   M.<EnumName>_descriptor - the enum descriptor
--
-- Accepts both syntax = "proto2" and syntax = "proto3". For proto2 sources
-- the descriptor surfaces `required=true`, `default_value=…`, and the
-- proto2-spec packing rule (repeated scalars NOT packed by default).
--
-- WKT references (google.protobuf.*) are resolved against pb.wkt so dynamic
-- schemas can interop with the same Timestamp/Duration/wrapper sugar that
-- generated code uses.
local codec = require('pb.codec')
local wire  = require('pb.wire')
local wkt   = require('pb.wkt')

local TYPE_INFO = wire.TYPE_INFO

local M = {}

local function short_name(full)
    -- "pkg.sub.Name" -> "Name" (just the trailing segment)
    return full:match('[^%.]+$') or full
end

local function flat_name(full, pkg)
    -- "pkg.Outer.Inner" with pkg="pkg" -> "Outer_Inner"
    local s = full
    if pkg ~= '' then s = s:gsub('^' .. pkg:gsub('%.', '%%.') .. '%.', '', 1) end
    return s:gsub('%.', '_')
end

local function make_enum_descriptor(name, values)
    local desc = {name = name, by_name = {}, by_value = {}}
    for k, v in pairs(values) do desc.by_name[k] = v; desc.by_value[v] = k end
    return desc
end

-- Pre-build a name->descriptor lookup over the entire AST. Resolution rules:
--   * Try the unqualified name as-is (innermost scope).
--   * Try fully-qualified within the current package.
--   * Try google.protobuf.<Name> via pb.wkt.
--   * Fall back to lookup by full name.
local function build_index(parsed, msg_descs, enum_descs)
    local pkg_prefix = parsed.package ~= '' and (parsed.package .. '.') or ''
    local index = {}  -- {[any-form-of-name] = descriptor}

    for full, desc in pairs(msg_descs) do
        index[full] = desc
        index[short_name(full)] = desc
    end
    for full, desc in pairs(enum_descs) do
        index[full] = desc
        index[short_name(full)] = desc
    end
    return index, pkg_prefix
end

-- Resolve a typename string from a field definition to (kind, descriptor-or-nil).
local function resolve_type(typename, index)
    if TYPE_INFO[typename] then return 'scalar', typename end
    -- Well-known types: accept "google.protobuf.Timestamp" or "Timestamp"-like.
    local wkt_short = typename:match('^google%.protobuf%.(.+)$') or typename
    local wkt_desc = wkt[wkt_short .. '_descriptor']
    if wkt_desc then return 'message', wkt_desc end
    local d = index[typename]
    if d then
        if d.by_name then return 'enum', d end
        return 'message', d
    end
    error("dynamic: cannot resolve type " .. typename, 0)
end

-- Coerce a parser-captured default literal into the runtime form the codec
-- expects (cdata for 64-bit ints, numbers for floats, etc). String/bytes
-- pass through as Lua strings; enums stay as symbolic names.
local function coerce_default(proto_type, v)
    if v == nil then return nil end
    if proto_type == 'int64' or proto_type == 'sint64' or proto_type == 'sfixed64' then
        return require('ffi').cast('int64_t', v)
    end
    if proto_type == 'uint64' or proto_type == 'fixed64' then
        return require('ffi').cast('uint64_t', v)
    end
    if proto_type == 'bool' then
        if type(v) == 'string' then return v == 'true' end
        return v and true or false
    end
    if proto_type == 'float' or proto_type == 'double' then
        if type(v) == 'string' then return tonumber(v) end
        return v
    end
    if proto_type == 'string' or proto_type == 'bytes' then
        return tostring(v)
    end
    -- int32 family, enums: numbers stay numbers, enum symbolic names stay strings.
    if type(v) == 'string' then
        local n = tonumber(v); if n then return n end
        return v
    end
    return v
end

-- Build a field descriptor for an ordinary (non-map) field.
-- `is_proto2` flips presence + packing defaults from the proto3 baseline.
local function build_field(field_ast, index, is_proto2)
    local entry = {name = field_ast.name, id = field_ast.id}
    local kind, ref = resolve_type(field_ast.type, index)
    -- Group fields parse as `kind='group'` in the AST; the parser's
    -- type lookup resolves to the nested message it desugared. Carry
    -- the group flag through so the codec emits SGROUP/EGROUP rather
    -- than a length-prefixed message body.
    if field_ast.kind == 'group' then
        entry.kind = 'group'
        entry.message = ref
    else
        entry.kind = kind
        if kind == 'scalar' then
            entry.proto_type = ref
        elseif kind == 'message' then
            entry.message = ref
        elseif kind == 'enum' then
            entry.enum = ref
        end
    end
    if field_ast.repeated then
        entry.repeated = true
        -- Packing default differs by syntax:
        --   proto3: packed for primitives + enums unless explicitly disabled.
        --   proto2: NOT packed unless explicitly [packed = true].
        if kind ~= 'message' and field_ast.type ~= 'string' and field_ast.type ~= 'bytes' then
            if is_proto2 then
                entry.packed = (field_ast.packed == true)
            else
                entry.packed = (field_ast.packed ~= false)
            end
        end
    end
    if field_ast.oneof then entry.oneof = field_ast.oneof end
    if field_ast.optional then entry.optional = true end
    if field_ast.required then entry.required = true end
    if field_ast.default_value ~= nil then
        entry.default_value = coerce_default(entry.proto_type, field_ast.default_value)
    end
    return entry
end

local function build_map_field(field_ast, index)
    local key_kind, key_ref = resolve_type(field_ast.key_type, index)
    local val_kind, val_ref = resolve_type(field_ast.value_type, index)
    local entry = {name = field_ast.name, id = field_ast.id, kind = 'map'}
    local key_desc = {kind = key_kind}
    if key_kind == 'scalar' then key_desc.proto_type = key_ref end
    local val_desc = {kind = val_kind}
    if val_kind == 'scalar' then val_desc.proto_type = val_ref
    elseif val_kind == 'message' then val_desc.message = val_ref
    elseif val_kind == 'enum' then val_desc.enum = val_ref end
    entry.key = key_desc
    entry.value = val_desc
    return entry
end

-- ---------------------------------------------------------------------------
-- Walk a message AST recursively, returning flat (full_name, ast) pairs for
-- the message itself and every nested message + enum.
-- ---------------------------------------------------------------------------
local function flatten(parsed)
    local msgs = {}   -- declaration-ordered: {full_name=, ast=}
    local enums = {}
    local pkg = parsed.package
    local function full_of(name, scope)
        if scope ~= '' then return scope .. '.' .. name end
        return name
    end
    local function walk_msg(ast, scope)
        local full = full_of(ast.name, scope)
        msgs[#msgs + 1] = {full_name = full, ast = ast}
        for _, e in ipairs(ast.nested_enums) do
            enums[#enums + 1] = {full_name = full_of(e.name, full), ast = e}
        end
        for _, n in ipairs(ast.nested_messages) do
            walk_msg(n, full)
        end
    end
    for _, e in ipairs(parsed.enums) do
        enums[#enums + 1] = {full_name = full_of(e.name, pkg), ast = e}
    end
    for _, m in ipairs(parsed.messages) do walk_msg(m, pkg) end
    return msgs, enums
end

-- ---------------------------------------------------------------------------
-- M.build(parsed) -> module table
-- ---------------------------------------------------------------------------
function M.build(parsed)
    local out = {}
    local msgs, enums = flatten(parsed)
    local pkg = parsed.package
    local is_proto2 = parsed.syntax == 'proto2'

    -- 1) Build enum descriptors.
    local enum_descs = {}
    for _, e in ipairs(enums) do
        local desc = make_enum_descriptor(e.full_name, e.ast.values)
        enum_descs[e.full_name] = desc
        local flat = flat_name(e.full_name, pkg)
        out[flat .. '_descriptor'] = desc
        out[flat] = desc.by_name
    end

    -- 2) Pre-declare message descriptors so cross-references resolve.
    local msg_descs = {}
    for _, m in ipairs(msgs) do
        local desc = {name = m.full_name}
        msg_descs[m.full_name] = desc
        out[flat_name(m.full_name, pkg) .. '_descriptor'] = desc
    end

    local index = build_index(parsed, msg_descs, enum_descs)

    -- 3) Fill in fields[] and oneofs for each message; finalize.
    for _, m in ipairs(msgs) do
        local desc = msg_descs[m.full_name]
        desc.fields = {}
        for _, f in ipairs(m.ast.fields) do
            if f.kind == 'map' then
                desc.fields[#desc.fields + 1] = build_map_field(f, index)
            else
                desc.fields[#desc.fields + 1] = build_field(f, index, is_proto2)
            end
        end
        if #m.ast.oneofs > 0 then
            desc.oneofs = {}
            for _, oo in ipairs(m.ast.oneofs) do
                desc.oneofs[oo.name] = oo.fields
            end
        end
        codec.finalize_message = codec.finalize_message  -- (no-op, just for clarity)
    end

    -- We use the public finalize from init.lua, but it lives in the parent
    -- module — replicate the work here to avoid a circular require.
    local CDATA_KEY_TYPES = {
        int64 = true, uint64 = true, sint64 = true,
        fixed64 = true, sfixed64 = true,
    }
    for _, m in ipairs(msgs) do
        local desc = msg_descs[m.full_name]
        local fbi = {}
        for _, f in ipairs(desc.fields) do
            fbi[f.id] = f
            -- Mirror pb.finalize_message: flag cdata-keyed map fields so
            -- codec.decode can dedupe duplicate int64 keys.
            if f.kind == 'map' and f.key and f.key.kind == 'scalar'
                    and CDATA_KEY_TYPES[f.key.proto_type] then
                f.key_dedup = true
            end
        end
        desc.field_by_id = fbi
        if desc.oneofs then
            -- Build oneofs_list (array form) so the hot encode loop can
            -- iterate with ipairs and stay on a JIT trace. Matches the
            -- shape produced by pb.finalize_message in init.lua.
            local list = {}
            for oname, members in pairs(desc.oneofs) do
                list[#list + 1] = {name = oname, members = members}
                for _, fname in ipairs(members) do
                    for _, f in ipairs(desc.fields) do
                        if f.name == fname then
                            local sibs = {}
                            for _, other in ipairs(members) do
                                if other ~= fname then sibs[#sibs + 1] = other end
                            end
                            f.oneof_siblings = sibs
                            break
                        end
                    end
                end
            end
            desc.oneofs_list = list
        end
        -- Attach the same per-field writers/readers that pb.finalize_message
        -- produces for generated code. Without this, encode_message falls
        -- through to the generic encode_field path which does not enforce
        -- proto2 `required` — required-missing-on-encode would silently
        -- elide instead of erroring.
        codec.compile_writers(desc)
        codec.compile_readers(desc)
    end

    -- 4) Emit wrapper functions per message.
    for _, m in ipairs(msgs) do
        local desc = msg_descs[m.full_name]
        local flat = flat_name(m.full_name, pkg)
        out[flat .. '_new'] = function(t) return t or {} end
        out[flat .. '_encode'] = function(t) return codec.encode(desc, t) end
        out[flat .. '_decode'] = function(b) return codec.decode(desc, b) end
        -- Optional accessors (presence-tracked fields only — same convention
        -- as the build-time codegen).
        for _, f in ipairs(desc.fields) do
            if f.optional then
                out[flat .. '_has_' .. f.name] = function(t) return t[f.name] ~= nil end
                out[flat .. '_clear_' .. f.name] = function(t) t[f.name] = nil end
            end
        end
    end

    return out
end

return M
