-- pb.reflection: gRPC server reflection (grpc.reflection.v1 and
-- grpc.reflection.v1alpha ServerReflection), answered from the
-- FileDescriptorProto bytes in pb.descriptors.
--
--   local refl = pb.reflection.new({services = {greeter_srv, health_srv}})
--   local transport = pb.grpc.multiplex({greeter_srv, health_srv,
--                                        unpack(refl:servers())})
--
-- The behaviour follows grpc-go's reflection service
-- (google.golang.org/grpc/reflection):
--
--   * list_services: the sorted names of the exposed services, the
--     reflection services this instance built included.
--   * file_by_filename / file_containing_symbol /
--     file_containing_extension: the file plus its transitive imports,
--     breadth first. Files already sent on the same stream are skipped,
--     except the requested file itself, which is always sent. Imports
--     missing from the registry are skipped silently.
--   * all_extension_numbers_of_type: the sorted extension numbers of a
--     known type (empty when it has none).
--   * anything not found: an error_response with NOT_FOUND; the stream
--     goes on. A request with no message_request set fails the stream
--     with INVALID_ARGUMENT.
--
-- Symbols are resolved as protoregistry.Files.FindDescriptorByName does:
-- messages (nested included), enums, enum values (in the scope enclosing
-- their enum), fields, oneofs, extensions, services and methods. The
-- symbol index is built from the registered descriptor bytes on first
-- use and rebuilt whenever pb.descriptors changes. Files are indexed in
-- registration order; a file declaring a name an earlier file declares
-- is left out whole (with a warning), as protobuf-go's registry refuses
-- it.
local codec       = require('pb.codec')
local descriptors = require('pb.descriptors')
local grpc        = require('pb.grpc')

local v1      = require('pb.gen.grpc.reflection.v1.reflection_pb')
local v1alpha = require('pb.gen.grpc.reflection.v1alpha.reflection_pb')

local M = {}

M.VERSIONS = {
    v1      = {module = v1,      service = 'grpc.reflection.v1.ServerReflection'},
    v1alpha = {module = v1alpha, service = 'grpc.reflection.v1alpha.ServerReflection'},
}

-- ---------------------------------------------------------------------------
-- Symbol index
-- ---------------------------------------------------------------------------

-- Just the parts of descriptor.proto that name things; the codec skips
-- the rest (options, types, locations) as unknown fields.
local function msg(name, fields)
    return {name = 'google.protobuf.' .. name, fields = fields}
end

local Named = msg('Named', {
    {name = 'name', id = 1, kind = 'scalar', proto_type = 'string'},
})
local Enum = msg('EnumDescriptorProto', {
    {name = 'name',  id = 1, kind = 'scalar',  proto_type = 'string'},
    {name = 'value', id = 2, kind = 'message', message = Named, repeated = true},
})
local Field = msg('FieldDescriptorProto', {
    {name = 'name',     id = 1, kind = 'scalar', proto_type = 'string'},
    {name = 'extendee', id = 2, kind = 'scalar', proto_type = 'string'},
    {name = 'number',   id = 3, kind = 'scalar', proto_type = 'int32'},
})
local Service = msg('ServiceDescriptorProto', {
    {name = 'name',   id = 1, kind = 'scalar',  proto_type = 'string'},
    {name = 'method', id = 2, kind = 'message', message = Named, repeated = true},
})
local Message = msg('DescriptorProto', {})
Message.fields = {
    {name = 'name',        id = 1, kind = 'scalar',  proto_type = 'string'},
    {name = 'field',       id = 2, kind = 'message', message = Field,   repeated = true},
    {name = 'nested_type', id = 3, kind = 'message', message = Message, repeated = true},
    {name = 'enum_type',   id = 4, kind = 'message', message = Enum,    repeated = true},
    {name = 'extension',   id = 6, kind = 'message', message = Field,   repeated = true},
    {name = 'oneof_decl',  id = 8, kind = 'message', message = Named,   repeated = true},
}
local File = msg('FileDescriptorProto', {
    {name = 'name',         id = 1, kind = 'scalar',  proto_type = 'string'},
    {name = 'package',      id = 2, kind = 'scalar',  proto_type = 'string'},
    {name = 'message_type', id = 4, kind = 'message', message = Message, repeated = true},
    {name = 'enum_type',    id = 5, kind = 'message', message = Enum,    repeated = true},
    {name = 'service',      id = 6, kind = 'message', message = Service, repeated = true},
    {name = 'extension',    id = 7, kind = 'message', message = Field,   repeated = true},
})

for _, d in ipairs({Named, Enum, Field, Service, Message, File}) do
    local fbi, fbn = {}, {}
    for _, f in ipairs(d.fields) do
        fbi[f.id] = f
        fbn[f.name] = f
    end
    d.field_by_id = fbi
    d.field_by_name = fbn
end
for _, d in ipairs({Named, Enum, Field, Service, Message, File}) do
    codec.compile_writers(d)
    codec.compile_readers(d)
end

-- The index is shared by every reflection instance: it depends only on
-- the registry. symbols: full name -> file name; extensions: extendee
-- full name -> {[number] = file name}.
local index = {generation = nil, symbols = {}, extensions = {}}

local function join(scope, name)
    if scope == '' then return name end
    return scope .. '.' .. name
end

-- file_symbols(fdp) -> array of the full names a file declares, array
-- of its extensions {extendee, number}.
local function file_symbols(fdp)
    local names, exts = {}, {}
    local function add_extension(ext, full)
        names[#names + 1] = full
        local extendee = ext.extendee or ''
        if extendee:sub(1, 1) == '.' then extendee = extendee:sub(2) end
        if ext.number ~= nil then exts[#exts + 1] = {extendee, ext.number} end
    end
    local function add_enum(e, scope)
        names[#names + 1] = join(scope, e.name)
        -- Enum values are siblings of their enum (C++ scoping rules).
        for _, v in ipairs(e.value or {}) do names[#names + 1] = join(scope, v.name) end
    end
    local function add_message(m, scope)
        local full = join(scope, m.name)
        names[#names + 1] = full
        for _, f in ipairs(m.field or {}) do names[#names + 1] = join(full, f.name) end
        for _, o in ipairs(m.oneof_decl or {}) do names[#names + 1] = join(full, o.name) end
        for _, e in ipairs(m.enum_type or {}) do add_enum(e, full) end
        for _, x in ipairs(m.extension or {}) do add_extension(x, join(full, x.name)) end
        for _, n in ipairs(m.nested_type or {}) do add_message(n, full) end
    end
    local pkg = fdp.package or ''
    for _, e in ipairs(fdp.enum_type or {}) do add_enum(e, pkg) end
    for _, m in ipairs(fdp.message_type or {}) do add_message(m, pkg) end
    for _, x in ipairs(fdp.extension or {}) do add_extension(x, join(pkg, x.name)) end
    for _, s in ipairs(fdp.service or {}) do
        local full = join(pkg, s.name)
        names[#names + 1] = full
        for _, meth in ipairs(s.method or {}) do names[#names + 1] = join(full, meth.name) end
    end
    return names, exts
end

-- Files already warned about for a symbol conflict (warn once each).
local warned = {}

-- Internal: where conflict warnings go. A field so tests can observe it.
function M._warn(msg)
    require('log').warn(msg)
end

-- Files are indexed in registration order. A file declaring a name an
-- earlier file already declares is left out as a whole, as protobuf-go's
-- registry refuses it ("name conflict"): mixing two files' symbols would
-- hand a client two files that define the same type and cannot link.
local function build_index()
    local symbols, extensions = {}, {}
    for _, name in ipairs(descriptors.registration_order()) do
        local ok, fdp = pcall(codec.decode, File, descriptors.file(name))
        if ok then
            local names, exts = file_symbols(fdp)
            local conflict
            for _, full in ipairs(names) do
                if symbols[full] ~= nil then
                    conflict = full
                    break
                end
            end
            if conflict ~= nil then
                if not warned[name] then
                    warned[name] = true
                    M._warn(('pb.reflection: %q declares %q, already declared by %q; '
                        .. 'its symbols are not served'):format(name, conflict, symbols[conflict]))
                end
            else
                for _, full in ipairs(names) do symbols[full] = name end
                for _, x in ipairs(exts) do
                    local by_number = extensions[x[1]]
                    if by_number == nil then
                        by_number = {}
                        extensions[x[1]] = by_number
                    end
                    if by_number[x[2]] == nil then by_number[x[2]] = name end
                end
            end
        end
    end
    return symbols, extensions
end

local function current_index()
    if index.generation ~= descriptors.generation() then
        local symbols, extensions = build_index()
        -- build_index may load the built-in descriptors, which bumps the
        -- generation: read it afterwards.
        index.generation = descriptors.generation()
        index.symbols = symbols
        index.extensions = extensions
    end
    return index
end

-- file_containing_symbol(name) -> file name or nil. Exposed for tests
-- and for tooling built on the registry.
---@param name string   fully-qualified symbol, e.g. 'hello.Greeter.SayHello'
---@return string?
function M.file_containing_symbol(name)
    return current_index().symbols[name]
end

-- file_containing_extension(extendee, number) -> file name or nil.
---@param extendee string   fully-qualified message name
---@param number integer
---@return string?
function M.file_containing_extension(extendee, number)
    local by_number = current_index().extensions[extendee]
    return by_number and by_number[number]
end

-- extension_numbers(extendee) -> sorted numbers, or nil when the type is
-- not known at all.
---@param extendee string
---@return integer[]?
function M.extension_numbers(extendee)
    local idx = current_index()
    local out = {}
    for number in pairs(idx.extensions[extendee] or {}) do out[#out + 1] = number end
    table.sort(out)
    if #out == 0 and idx.symbols[extendee] == nil then return nil end
    return out
end

-- file_with_dependencies(name, sent) -> array of FileDescriptorProto
-- bytes, or nil when the file is not registered.
--
-- Breadth-first over the imports. `sent` (file name -> true) is the
-- per-stream memory of files already delivered: they are skipped, except
-- the requested file, which is always included.
---@param name string
---@param sent table<string, boolean>
---@return string[]?
function M.file_with_dependencies(name, sent)
    if descriptors.file(name) == nil then return nil end
    local out = {}
    local queue, head = {name}, 1
    local visited = {[name] = true}
    while head <= #queue do
        local cur = queue[head]
        head = head + 1
        local bytes = descriptors.file(cur)
        if bytes ~= nil then
            if #out == 0 or not sent[cur] then
                sent[cur] = true
                out[#out + 1] = bytes
            end
            for _, dep in ipairs(descriptors.dependencies(cur)) do
                if not visited[dep] then
                    visited[dep] = true
                    queue[#queue + 1] = dep
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The service
-- ---------------------------------------------------------------------------

local NOT_FOUND = grpc.code.NOT_FOUND

local function not_found(message)
    return {error_code = NOT_FOUND, error_message = message}
end

local function files_response(files)
    return {file_descriptor_proto = files}
end

-- service_name(entry) -> name of a service given as a generated server
-- table, a service descriptor, or a plain name.
local function service_name(entry)
    if type(entry) == 'string' then return entry end
    if type(entry) == 'table' then
        if type(entry.service) == 'table' and type(entry.service.name) == 'string' then
            return entry.service.name
        end
        if type(entry.name) == 'string' then return entry.name end
    end
    error('pb.reflection: a service is a server table from M.<Service>_server(), '
        .. 'a service descriptor or a full name, got ' .. tostring(entry), 3)
end

local Reflection = {}
Reflection.__index = Reflection

-- services() -> sorted, de-duplicated names of the exposed services,
-- including the reflection services handed out by server()/servers().
---@return string[]
function Reflection:services()
    local list = self._services
    if type(list) == 'function' then list = list() end
    local seen, out = {}, {}
    local function push(name)
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for _, entry in ipairs(list or {}) do push(service_name(entry)) end
    for name in pairs(self._own) do push(name) end
    table.sort(out)
    return out
end

-- add(service) exposes one more service in list_services. Only for an
-- instance built with a services array.
function Reflection:add(entry)
    if type(self._services) ~= 'table' then
        error('pb.reflection: add() needs an instance built with a services array', 2)
    end
    service_name(entry)
    table.insert(self._services, entry)
    return self
end

-- One request -> one ServerReflectionResponse table. `sent` is the
-- per-stream set of files already delivered.
function Reflection:_answer(req, sent)
    local resp = {valid_host = req.host, original_request = req}
    if req.file_by_filename ~= nil then
        local files = M.file_with_dependencies(req.file_by_filename, sent)
        if files == nil then
            resp.error_response = not_found('file not found: ' .. req.file_by_filename)
        else
            resp.file_descriptor_response = files_response(files)
        end
    elseif req.file_containing_symbol ~= nil then
        local file = M.file_containing_symbol(req.file_containing_symbol)
        local files = file and M.file_with_dependencies(file, sent)
        if files == nil then
            resp.error_response = not_found('symbol not found: ' .. req.file_containing_symbol)
        else
            resp.file_descriptor_response = files_response(files)
        end
    elseif req.file_containing_extension ~= nil then
        local ext = req.file_containing_extension
        local extendee, number = ext.containing_type or '', ext.extension_number or 0
        local file = M.file_containing_extension(extendee, number)
        local files = file and M.file_with_dependencies(file, sent)
        if files == nil then
            resp.error_response = not_found(('extension not found: %s(%d)')
                :format(extendee, number))
        else
            resp.file_descriptor_response = files_response(files)
        end
    elseif req.all_extension_numbers_of_type ~= nil then
        local name = req.all_extension_numbers_of_type
        local numbers = M.extension_numbers(name)
        if numbers == nil then
            resp.error_response = not_found('type not found: ' .. name)
        else
            resp.all_extension_numbers_response = {
                base_type_name = name,
                extension_number = numbers,
            }
        end
    elseif req.list_services ~= nil then
        local services = {}
        for i, name in ipairs(self:services()) do services[i] = {name = name} end
        resp.list_services_response = {service = services}
    else
        grpc.error(grpc.code.INVALID_ARGUMENT,
            'pb.reflection: invalid MessageRequest: no request field set')
    end
    return resp
end

function Reflection:_info(stream, _)
    local sent = {}
    while true do
        local req, err = stream:recv()
        if req == nil then
            if err ~= nil and err ~= 'canceled' then error(err, 0) end
            return
        end
        if stream:send(self:_answer(req, sent)) == false then return end
    end
end

-- server(version?) -> a server table (the shape M.<Service>_server
-- returns) for 'v1' (default) or 'v1alpha'.
---@param version? 'v1'|'v1alpha'
---@return table
function Reflection:server(version)
    version = version or 'v1'
    local v = M.VERSIONS[version]
    if v == nil then
        error(("pb.reflection: unknown version %q (expected 'v1' or 'v1alpha')")
            :format(tostring(version)), 2)
    end
    self._own[v.service] = true
    return v.module.ServerReflection_server({
        ServerReflectionInfo = function(stream, ctx) return self:_info(stream, ctx) end,
    })
end

-- servers() -> {v1_server, v1alpha_server}: both versions, as grpc-go's
-- reflection.Register installs them (older clients speak only v1alpha).
---@return table[]
function Reflection:servers()
    return {self:server('v1'), self:server('v1alpha')}
end

-- new(opts?) -> reflection instance.
--
-- opts.services: the services list_services reports, either an array
-- (generated server tables, service descriptors or full names) or a
-- function returning such an array on every call. The reflection
-- services built by this instance are always listed too.
---@param opts? {services?: table|fun(): table}
function M.new(opts)
    opts = opts or {}
    local services = opts.services
    if services ~= nil and type(services) ~= 'table' and type(services) ~= 'function' then
        error('pb.reflection.new: opts.services must be an array or a function', 2)
    end
    if type(services) == 'table' then
        local copy = {}
        for i, entry in ipairs(services) do
            service_name(entry)
            copy[i] = entry
        end
        services = copy
    end
    return setmetatable({_services = services or {}, _own = {}}, Reflection)
end

-- servers(opts?) -> new(opts):servers().
function M.servers(opts)
    return M.new(opts):servers()
end

return M
