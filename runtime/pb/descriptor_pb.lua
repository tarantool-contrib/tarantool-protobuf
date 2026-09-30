-- Hand-built descriptors for the subset of google.protobuf.descriptor needed
-- to decode FileDescriptorSet wire bytes back into AST form. Used by
-- pb.from_pb (see runtime/pb/fileset.lua).
--
-- We model FieldDescriptorProto.type and .label as int32 scalars instead of
-- enums; the codec returns the wire integer either way and the translator
-- maps it to a proto3 type-name string by hand.
local codec = require('pb.codec')

local M = {}

local function finalize(desc)
    local fbi, fbn = {}, {}
    for _, f in ipairs(desc.fields) do
        fbi[f.id] = f
        fbn[f.name] = f
    end
    desc.field_by_id = fbi
    desc.field_by_name = fbn
    -- Oneof members clear their siblings on decode, so the last member
    -- on the wire wins, as the proto spec requires. The readers capture
    -- oneof_siblings when compiled, so set it first. Same shape as
    -- pb.finalize_message builds: desc.oneofs = {name = {members}}.
    if desc.oneofs then
        local list = {}
        for oname, members in pairs(desc.oneofs) do
            list[#list + 1] = {name = oname, members = members}
            for _, fname in ipairs(members) do
                local sibs = {}
                for _, other in ipairs(members) do
                    if other ~= fname then sibs[#sibs + 1] = other end
                end
                fbn[fname].oneof = oname
                fbn[fname].oneof_siblings = sibs
            end
        end
        desc.oneofs_list = list
    end
    codec.compile_writers(desc)
    codec.compile_readers(desc)
    return desc
end

-- FieldOptions: subset.
M.FieldOptions = {
    name = 'google.protobuf.FieldOptions',
    fields = {
        {name = 'packed', id = 2, kind = 'scalar', proto_type = 'bool'},
    },
}

-- MessageOptions: subset.
M.MessageOptions = {
    name = 'google.protobuf.MessageOptions',
    fields = {
        {name = 'map_entry', id = 7, kind = 'scalar', proto_type = 'bool'},
    },
}

-- FieldDescriptorProto.
M.FieldDescriptorProto = {
    name = 'google.protobuf.FieldDescriptorProto',
    fields = {
        {name = 'name',            id = 1,  kind = 'scalar',  proto_type = 'string'},
        {name = 'extendee',        id = 2,  kind = 'scalar',  proto_type = 'string'},
        {name = 'number',          id = 3,  kind = 'scalar',  proto_type = 'int32'},
        {name = 'label',           id = 4,  kind = 'scalar',  proto_type = 'int32'},
        {name = 'type',            id = 5,  kind = 'scalar',  proto_type = 'int32'},
        {name = 'type_name',       id = 6,  kind = 'scalar',  proto_type = 'string'},
        {name = 'default_value',   id = 7,  kind = 'scalar',  proto_type = 'string'},
        {name = 'options',         id = 8,  kind = 'message', message = M.FieldOptions},
        {name = 'oneof_index',     id = 9,  kind = 'scalar',  proto_type = 'int32'},
        {name = 'json_name',       id = 10, kind = 'scalar',  proto_type = 'string'},
        {name = 'proto3_optional', id = 17, kind = 'scalar',  proto_type = 'bool'},
    },
}

M.OneofDescriptorProto = {
    name = 'google.protobuf.OneofDescriptorProto',
    fields = {
        {name = 'name', id = 1, kind = 'scalar', proto_type = 'string'},
    },
}

M.EnumValueDescriptorProto = {
    name = 'google.protobuf.EnumValueDescriptorProto',
    fields = {
        {name = 'name',   id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'number', id = 2, kind = 'scalar', proto_type = 'int32'},
    },
}

M.EnumDescriptorProto = {
    name = 'google.protobuf.EnumDescriptorProto',
    fields = {
        {name = 'name',  id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'value', id = 2, kind = 'message',
         message = M.EnumValueDescriptorProto, repeated = true},
    },
}

-- google.api.CustomHttpPattern (google/api/http.proto).
M.CustomHttpPattern = {
    name = 'google.api.CustomHttpPattern',
    fields = {
        {name = 'kind', id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'path', id = 2, kind = 'scalar', proto_type = 'string'},
    },
}

-- google.api.HttpRule (google/api/http.proto), with its `pattern` oneof:
-- when several members appear on the wire, the last one wins.
M.HttpRule = {
    name = 'google.api.HttpRule',
    oneofs = {
        pattern = {'get', 'put', 'post', 'delete', 'patch', 'custom'},
    },
}
M.HttpRule.fields = {
    {name = 'selector',            id = 1,  kind = 'scalar',  proto_type = 'string'},
    {name = 'get',                 id = 2,  kind = 'scalar',  proto_type = 'string'},
    {name = 'put',                 id = 3,  kind = 'scalar',  proto_type = 'string'},
    {name = 'post',                id = 4,  kind = 'scalar',  proto_type = 'string'},
    {name = 'delete',              id = 5,  kind = 'scalar',  proto_type = 'string'},
    {name = 'patch',               id = 6,  kind = 'scalar',  proto_type = 'string'},
    {name = 'body',                id = 7,  kind = 'scalar',  proto_type = 'string'},
    {name = 'custom',              id = 8,  kind = 'message', message = M.CustomHttpPattern},
    {name = 'additional_bindings', id = 11, kind = 'message', message = M.HttpRule, repeated = true},
    {name = 'response_body',       id = 12, kind = 'scalar',  proto_type = 'string'},
}

-- MethodOptions: subset — only the google.api.http extension
-- (google/api/annotations.proto), decoded as if it were a plain field.
M.MethodOptions = {
    name = 'google.protobuf.MethodOptions',
    fields = {
        {name = 'http', id = 72295728, kind = 'message', message = M.HttpRule},
    },
}

M.MethodDescriptorProto = {
    name = 'google.protobuf.MethodDescriptorProto',
    fields = {
        {name = 'name',             id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'input_type',       id = 2, kind = 'scalar', proto_type = 'string'},
        {name = 'output_type',      id = 3, kind = 'scalar', proto_type = 'string'},
        {name = 'options',          id = 4, kind = 'message', message = M.MethodOptions},
        {name = 'client_streaming', id = 5, kind = 'scalar', proto_type = 'bool'},
        {name = 'server_streaming', id = 6, kind = 'scalar', proto_type = 'bool'},
    },
}

M.ServiceDescriptorProto = {
    name = 'google.protobuf.ServiceDescriptorProto',
    fields = {
        {name = 'name',   id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'method', id = 2, kind = 'message',
         message = M.MethodDescriptorProto, repeated = true},
    },
}

-- DescriptorProto recurses through nested_type. We pre-declare the table,
-- then patch in the recursive reference.
M.DescriptorProto = {name = 'google.protobuf.DescriptorProto'}
M.DescriptorProto.fields = {
    {name = 'name',        id = 1, kind = 'scalar',  proto_type = 'string'},
    {name = 'field',       id = 2, kind = 'message', message = M.FieldDescriptorProto, repeated = true},
    {name = 'nested_type', id = 3, kind = 'message', message = M.DescriptorProto,       repeated = true},
    {name = 'enum_type',   id = 4, kind = 'message', message = M.EnumDescriptorProto,   repeated = true},
    {name = 'options',     id = 7, kind = 'message', message = M.MessageOptions},
    {name = 'oneof_decl',  id = 8, kind = 'message', message = M.OneofDescriptorProto,  repeated = true},
}

M.FileDescriptorProto = {
    name = 'google.protobuf.FileDescriptorProto',
    fields = {
        {name = 'name',         id = 1,  kind = 'scalar',  proto_type = 'string'},
        {name = 'package',      id = 2,  kind = 'scalar',  proto_type = 'string'},
        {name = 'dependency',   id = 3,  kind = 'scalar',  proto_type = 'string', repeated = true, packed = false},
        {name = 'message_type', id = 4,  kind = 'message', message = M.DescriptorProto,        repeated = true},
        {name = 'enum_type',    id = 5,  kind = 'message', message = M.EnumDescriptorProto,    repeated = true},
        {name = 'service',      id = 6,  kind = 'message', message = M.ServiceDescriptorProto, repeated = true},
        {name = 'syntax',       id = 12, kind = 'scalar',  proto_type = 'string'},
    },
}

M.FileDescriptorSet = {
    name = 'google.protobuf.FileDescriptorSet',
    fields = {
        {name = 'file', id = 1, kind = 'message',
         message = M.FileDescriptorProto, repeated = true},
    },
}

-- Finalize bottom-up. Order matters only in that we should finalize a
-- descriptor before any descriptor that references it as a message field;
-- the codec's compile_readers walks field.message at compile time.
finalize(M.FieldOptions)
finalize(M.MessageOptions)
finalize(M.FieldDescriptorProto)
finalize(M.OneofDescriptorProto)
finalize(M.EnumValueDescriptorProto)
finalize(M.EnumDescriptorProto)
finalize(M.CustomHttpPattern)
finalize(M.HttpRule)
finalize(M.MethodOptions)
finalize(M.MethodDescriptorProto)
finalize(M.ServiceDescriptorProto)
finalize(M.DescriptorProto)
finalize(M.FileDescriptorProto)
finalize(M.FileDescriptorSet)

return M
