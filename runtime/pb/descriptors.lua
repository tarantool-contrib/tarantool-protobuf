-- pb.descriptors: a registry of serialized FileDescriptorProto bytes,
-- keyed by .proto file name — the input server reflection needs.
--
-- Every generated module registers its own file's descriptor when it is
-- loaded (and the descriptors of imported files that were not generated
-- alongside it), so after requiring the generated modules of an
-- application the registry can answer:
--
--   pb.descriptors.file('hello.proto')          -> bytes | nil
--   pb.descriptors.files()                      -> {'google/api/http.proto', ...}
--   pb.descriptors.dependencies('hello.proto')  -> {'google/protobuf/timestamp.proto', ...}
--
-- The descriptors of the well-known types, descriptor.proto, plugin.proto
-- and google/api/{annotations,http}.proto ship with the runtime
-- (pb.descriptors_builtin) and are loaded on first lookup.
--
-- Registration runs once per module load, never on an encode/decode
-- path.
local codec = require('pb.codec')

local M = {}

-- name -> {bytes = <string>, package = <string>, dependencies = {...}}
local registry = {}
local builtins_loaded = false

-- Just the FileDescriptorProto fields the registry indexes; the codec
-- skips the rest.
local HEADER = {
    name = 'google.protobuf.FileDescriptorProto',
    fields = {
        {name = 'name',       id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'package',    id = 2, kind = 'scalar', proto_type = 'string'},
        {name = 'dependency', id = 3, kind = 'scalar', proto_type = 'string',
         repeated = true, packed = false},
    },
}
do
    local fbi, fbn = {}, {}
    for _, f in ipairs(HEADER.fields) do
        fbi[f.id] = f
        fbn[f.name] = f
    end
    HEADER.field_by_id = fbi
    HEADER.field_by_name = fbn
    codec.compile_writers(HEADER)
    codec.compile_readers(HEADER)
end

local function add(bytes)
    if type(bytes) ~= 'string' then
        error('pb.descriptors.register: expected FileDescriptorProto bytes, got '
            .. type(bytes), 3)
    end
    local ok, hdr = pcall(codec.decode, HEADER, bytes)
    if not ok then
        error('pb.descriptors.register: not a FileDescriptorProto: '
            .. tostring(hdr), 3)
    end
    local name = hdr.name
    if name == nil or name == '' then
        error('pb.descriptors.register: FileDescriptorProto has no name', 3)
    end
    local cur = registry[name]
    if cur ~= nil and cur.bytes == bytes then return name end
    -- A different descriptor under a known name replaces the old one:
    -- the latest loaded module wins, which is what a hot code reload
    -- after a schema change needs.
    registry[name] = {
        bytes        = bytes,
        package      = hdr.package or '',
        dependencies = hdr.dependency or {},
    }
    return name
end

local function load_builtins()
    if builtins_loaded then return end
    builtins_loaded = true
    for _, f in ipairs(require('pb.descriptors_builtin')) do
        -- A module registered before the builtins were loaded keeps its
        -- own copy.
        if registry[f.name] == nil then add(f.bytes) end
    end
end

local function entry(name)
    local e = registry[name]
    if e == nil and not builtins_loaded then
        load_builtins()
        e = registry[name]
    end
    return e
end

-- register(bytes) -> file name. Adds a serialized FileDescriptorProto.
-- Registering identical bytes again is a no-op; different bytes under a
-- registered name replace the earlier descriptor.
---@param bytes string   serialized google.protobuf.FileDescriptorProto
---@return string name   the file name it was registered under
function M.register(bytes)
    return add(bytes)
end

-- file(name) -> bytes, or nil when no descriptor is registered for it.
---@param name string    .proto file name as imported, e.g. 'hello.proto'
---@return string?
function M.file(name)
    local e = entry(name)
    return e and e.bytes
end

-- files() -> sorted array of every registered file name, built-ins
-- included.
---@return string[]
function M.files()
    load_builtins()
    local out = {}
    for name in pairs(registry) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- dependencies(name) -> array of the file's direct imports (as written
-- in its `import` statements), or nil when the file is not registered.
---@param name string
---@return string[]?
function M.dependencies(name)
    local e = entry(name)
    if e == nil then return nil end
    local out = {}
    for i, d in ipairs(e.dependencies) do out[i] = d end
    return out
end

-- package(name) -> the file's proto package ('' when none), or nil when
-- the file is not registered.
---@param name string
---@return string?
function M.package(name)
    local e = entry(name)
    return e and e.package
end

return M
