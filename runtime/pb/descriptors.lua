-- pb.descriptors: a registry of serialized FileDescriptorProto bytes,
-- keyed by .proto file name — the input server reflection needs.
--
-- Every generated module registers its own file's descriptor when it is
-- loaded (authoritative), plus snapshots of its non-builtin imports, so
-- after requiring the generated modules of an application the registry
-- can answer:
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
-- Bumped on every change to the registry; lets consumers that derive
-- indexes from it (pb.reflection's symbol table) know when to rebuild.
local generation = 0

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

-- Names already warned about for conflicting snapshots (warn once each).
local warned = {}

-- Internal: where conflict warnings go. A field so tests can observe it.
function M._warn(msg)
    require('log').warn(msg)
end

local function add(bytes, snapshot)
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
    -- Two ranks. A module's own file is authoritative; a copy of an
    -- import embedded in another module is a snapshot, possibly older
    -- than the imported file's own module.
    --   snapshot over authoritative: ignored;
    --   authoritative over anything: replaces (hot code reload);
    --   snapshot over a different snapshot: the first stays, warn once.
    local cur = registry[name]
    if cur ~= nil then
        if cur.bytes == bytes then
            if not snapshot then cur.snapshot = false end
            return name
        end
        if snapshot then
            if cur.snapshot and not warned[name] then
                warned[name] = true
                M._warn(('pb.descriptors: conflicting snapshots of %q '
                    .. 'embedded by different modules; keeping the first'):format(name))
            end
            return name
        end
    end
    registry[name] = {
        bytes        = bytes,
        package      = hdr.package or '',
        dependencies = hdr.dependency or {},
        snapshot     = snapshot and true or false,
    }
    generation = generation + 1
    return name
end

local function load_builtins()
    if builtins_loaded then return end
    builtins_loaded = true
    for _, f in ipairs(require('pb.descriptors_builtin')) do
        -- A module registered before the builtins were loaded keeps its
        -- own copy.
        if registry[f.name] == nil then add(f.bytes, false) end
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

-- register(bytes[, opts]) -> file name. Adds a serialized
-- FileDescriptorProto.
--
-- By default the entry is authoritative (a module registering its own
-- file): it replaces whatever is registered under that name, so the
-- latest loaded module wins, as a hot code reload needs. With
-- `opts.snapshot = true` it is a snapshot (a module registering a copy
-- of one of its imports): it fills a missing entry but never replaces
-- an existing one; two different snapshots of one file keep the first
-- and log a warning once. Identical bytes are always a no-op (an
-- authoritative registration of snapshot bytes promotes the entry).
---@param bytes string   serialized google.protobuf.FileDescriptorProto
---@param opts? {snapshot?: boolean}
---@return string name   the file name it was registered under
function M.register(bytes, opts)
    if opts ~= nil and type(opts) ~= 'table' then
        error('pb.descriptors.register: opts must be a table', 2)
    end
    return add(bytes, opts ~= nil and opts.snapshot == true)
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

-- generation() -> integer that changes whenever a file is added or
-- replaced (built-ins included). Anything derived from the registry
-- can cache against it: equal numbers mean an unchanged registry.
---@return integer
function M.generation()
    return generation
end

return M
