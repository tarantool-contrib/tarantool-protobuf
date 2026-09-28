-- pb.from_pb: build runtime modules from a binary FileDescriptorSet.
--
-- Complements pb.parse (which consumes .proto source text) by accepting the
-- output of `protoc --descriptor_set_out=...`. The pipeline:
--   bytes  -> FileDescriptorSet decoded via descriptor.proto descriptors
--          -> per-file AST (same shape as pb.parser produces)
--          -> per-file module via pb.dynamic.build
--
-- Returns:
--   {
--     files   = {[file_name] = module, ...},   -- one entry per FileDescriptorProto
--     order   = {file_name, ...},              -- declaration order
--     lookup  = function(full_name) -> descriptor | nil,
--   }
local codec   = require('pb.codec')
local dynamic = require('pb.dynamic')
local descpb  = require('pb.descriptor_pb')

local M = {}

-- FieldDescriptorProto.Type wire values -> proto3 type-name strings.
local TYPE_NAMES = {
    [1]  = 'double',
    [2]  = 'float',
    [3]  = 'int64',
    [4]  = 'uint64',
    [5]  = 'int32',
    [6]  = 'fixed64',
    [7]  = 'fixed32',
    [8]  = 'bool',
    [9]  = 'string',
    -- 10 = TYPE_GROUP (proto2 only; not supported)
    [11] = 'message',
    [12] = 'bytes',
    [13] = 'uint32',
    [14] = 'enum',
    [15] = 'sfixed32',
    [16] = 'sfixed64',
    [17] = 'sint32',
    [18] = 'sint64',
}

local LABEL_REPEATED = 3

local function strip_dot(name)
    if name == nil then return nil end
    return (name:gsub('^%.', ''))
end

-- Collect the full names of nested map-entry messages so the parent
-- translator knows which TYPE_MESSAGE fields are really map fields. Returns
-- {[full_name] = {key_type=, value_type=}, ...}.
local function collect_map_entries(msg_proto, scope, out)
    out = out or {}
    local full = scope == '' and msg_proto.name or (scope .. '.' .. msg_proto.name)
    if msg_proto.options and msg_proto.options.map_entry then
        local key_t, val_t
        local key_typename, val_typename
        for _, f in ipairs(msg_proto.field or {}) do
            local tn = TYPE_NAMES[f.type]
            if f.name == 'key' then
                if tn == 'message' or tn == 'enum' then
                    key_typename = strip_dot(f.type_name)
                else
                    key_t = tn
                end
            elseif f.name == 'value' then
                if tn == 'message' or tn == 'enum' then
                    val_typename = strip_dot(f.type_name)
                else
                    val_t = tn
                end
            end
        end
        out[full] = {
            key_type   = key_t or key_typename,
            value_type = val_t or val_typename,
        }
    end
    for _, nested in ipairs(msg_proto.nested_type or {}) do
        collect_map_entries(nested, full, out)
    end
    return out
end

-- Translate a FieldDescriptorProto into an AST field.
local function translate_field(f, oneofs_decl, map_entries)
    local type_id  = f.type
    local typename = TYPE_NAMES[type_id]
    local repeated = (f.label == LABEL_REPEATED)

    -- Map fields are represented as repeated synthetic-entry messages.
    if repeated and typename == 'message' then
        local entry_full = strip_dot(f.type_name)
        local map_info = entry_full and map_entries[entry_full]
        if map_info then
            return {
                name       = f.name,
                id         = f.number,
                kind       = 'map',
                key_type   = map_info.key_type,
                value_type = map_info.value_type,
            }, true  -- second return signals "skip the entry message"
        end
    end

    -- Resolve the type string the AST consumer expects.
    local ast_type
    if typename == 'message' or typename == 'enum' then
        ast_type = strip_dot(f.type_name)
    else
        ast_type = typename
    end

    local entry = {
        name = f.name,
        id   = f.number,
        type = ast_type,
    }
    if repeated then
        entry.repeated = true
        if f.options and f.options.packed ~= nil then
            entry.packed = f.options.packed
        end
    end
    if f.proto3_optional then
        entry.optional = true
    elseif f.oneof_index ~= nil then
        -- oneof_index references oneof_decl[]. It is zero-based in
        -- descriptor.proto wire form, but we get Lua-decoded plain ints.
        local decl = oneofs_decl[f.oneof_index + 1]
        if decl then entry.oneof = decl.name end
    end
    return entry, false
end

-- Translate a DescriptorProto into the AST message shape produced by
-- pb.parser. Returns {name=, fields=, nested_messages=, nested_enums=, oneofs=}.
local function translate_message(msg_proto, scope, map_entries)
    local full = scope == '' and msg_proto.name or (scope .. '.' .. msg_proto.name)
    map_entries = map_entries or collect_map_entries(msg_proto, scope)

    local ast = {
        name            = msg_proto.name,
        fields          = {},
        nested_messages = {},
        nested_enums    = {},
        oneofs          = {},
    }

    local oneofs_decl = msg_proto.oneof_decl or {}

    -- Group oneof field names by oneof_decl index, excluding proto3_optional
    -- synthetic oneofs.
    local oneof_groups = {}  -- {[idx] = {field_names...}}
    for _, f in ipairs(msg_proto.field or {}) do
        if f.oneof_index ~= nil and not f.proto3_optional then
            local idx = f.oneof_index + 1
            oneof_groups[idx] = oneof_groups[idx] or {}
            table.insert(oneof_groups[idx], f.name)
        end
    end

    for _, f in ipairs(msg_proto.field or {}) do
        local entry, _ = translate_field(f, oneofs_decl, map_entries)
        table.insert(ast.fields, entry)
    end

    -- Emit oneofs in oneof_decl order.
    for i, decl in ipairs(oneofs_decl) do
        local names = oneof_groups[i]
        if names and #names > 0 then
            table.insert(ast.oneofs, {name = decl.name, fields = names})
        end
    end

    -- Nested types — skip map-entry synthetic messages.
    for _, nested in ipairs(msg_proto.nested_type or {}) do
        local nested_full = full .. '.' .. nested.name
        if not map_entries[nested_full] then
            table.insert(ast.nested_messages,
                         translate_message(nested, full, map_entries))
        end
    end

    for _, en in ipairs(msg_proto.enum_type or {}) do
        local values = {}
        for _, v in ipairs(en.value or {}) do values[v.name] = v.number or 0 end
        table.insert(ast.nested_enums, {name = en.name, values = values})
    end

    return ast
end

-- Translate a FileDescriptorProto into the AST shape pb.dynamic.build expects.
local function translate_file(file_proto)
    local ast = {
        syntax   = file_proto.syntax ~= '' and file_proto.syntax or 'proto3',
        package  = file_proto.package or '',
        imports  = {},
        messages = {},
        enums    = {},
        services = {},
    }
    for _, dep in ipairs(file_proto.dependency or {}) do
        table.insert(ast.imports, dep)
    end

    -- Gather top-level map entries (none, by construction — map entries are
    -- always nested — but we keep the recursion uniform).
    for _, msg in ipairs(file_proto.message_type or {}) do
        table.insert(ast.messages, translate_message(msg, ast.package))
    end

    for _, en in ipairs(file_proto.enum_type or {}) do
        local values = {}
        for _, v in ipairs(en.value or {}) do values[v.name] = v.number or 0 end
        table.insert(ast.enums, {name = en.name, values = values})
    end

    for _, svc in ipairs(file_proto.service or {}) do
        local methods = {}
        for _, m in ipairs(svc.method or {}) do
            table.insert(methods, {
                name              = m.name,
                input             = strip_dot(m.input_type),
                output            = strip_dot(m.output_type),
                client_streaming  = m.client_streaming or false,
                server_streaming  = m.server_streaming or false,
            })
        end
        table.insert(ast.services, {name = svc.name, methods = methods})
    end

    return ast
end

-- Build a name-lookup that walks every module and exposes _descriptor
-- entries by their proto full name.
local function build_lookup(files, order)
    local by_full = {}
    for _, fname in ipairs(order) do
        local module = files[fname]
        -- Re-create the descriptor index by iterating over the module's
        -- _descriptor entries. The descriptor's .name field is the proto
        -- full name (e.g., "pkg.sub.Foo").
        for k, v in pairs(module) do
            if type(k) == 'string' and k:match('_descriptor$') and type(v) == 'table' then
                if v.name then by_full[v.name] = v end
            end
        end
    end
    return function(full_name) return by_full[full_name] end
end

-- Public entry.
function M.parse(bytes)
    local set = codec.decode(descpb.FileDescriptorSet, bytes)
    local files = {}
    local order = {}
    for _, f in ipairs(set.file or {}) do
        local ast = translate_file(f)
        local module = dynamic.build(ast)
        local name = f.name ~= '' and f.name or ('file_' .. tostring(#order + 1))
        files[name] = module
        table.insert(order, name)
    end
    return {
        files  = files,
        order  = order,
        lookup = build_lookup(files, order),
    }
end

return M
