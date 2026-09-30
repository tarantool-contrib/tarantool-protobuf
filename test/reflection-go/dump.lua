-- Drives the reflection service over raw bytes and writes every
-- ServerReflectionResponse it returns into a directory, for the Go
-- check next to this file (reflection_test.go) to decode with grpc-go's
-- own types and link with protodesc.
--
-- Usage: tarantool test/reflection-go/dump.lua <out_dir>
-- LUA_PATH must reach runtime/ and examples/expected/ (see Justfile).
--
-- <out_dir>/manifest.tsv lists one response per line:
--   <kind>\t<subject>\t<file>
-- kind: list_services, file (file_by_filename), symbol
-- (file_containing_symbol), dedup (successive requests on one stream),
-- v1alpha_list_services, v1alpha_file.
local fio = require('fio')
local pb  = require('pb')

local V1      = require('pb.gen.grpc.reflection.v1.reflection_pb')
local V1ALPHA = require('pb.gen.grpc.reflection.v1alpha.reflection_pb')

local out = arg[1]
assert(out, 'usage: dump.lua <out_dir>')
assert(fio.mkdir(out) or fio.path.is_dir(out), 'cannot create ' .. out)

-- Load every generated full-mode module: each registers its descriptor.
local ROOT = 'examples/expected/full'
local modules = {}
local function walk(dir, prefix)
    for _, name in ipairs(fio.listdir(dir)) do
        local path = fio.pathjoin(dir, name)
        if fio.path.is_dir(path) then
            walk(path, prefix .. name .. '.')
        elseif name:match('%.lua$') then
            modules[#modules + 1] = prefix .. name:gsub('%.lua$', '')
        end
    end
end
walk(ROOT, 'full.')
table.sort(modules)
assert(#modules > 0, 'no generated modules under ' .. ROOT)

local servers = {}
for _, modname in ipairs(modules) do
    local m = require(modname)
    local names = {}
    for k in pairs(m) do
        if type(k) == 'string' and k:match('_server$') then names[#names + 1] = k end
    end
    table.sort(names)
    for _, k in ipairs(names) do servers[#servers + 1] = m[k]({}) end
end

local health = pb.health.new()
servers[#servers + 1] = health:server()
local refl = pb.reflection.new({services = servers})
local all = {}
for _, s in ipairs(servers) do all[#all + 1] = s end
for _, s in ipairs(refl:servers()) do all[#all + 1] = s end
local transport = pb.grpc.multiplex(all)

local PATH = {
    [V1] = '/grpc.reflection.v1.ServerReflection/ServerReflectionInfo',
    [V1ALPHA] = '/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo',
}

-- A raw (bytes in, bytes out) reflection stream.
local function stream(mod)
    local raw = transport:bidi(PATH[mod], {})
    return function(req)
        raw:send(mod.ServerReflectionRequest_encode(req))
        local b, err = raw:recv()
        assert(b ~= nil, 'no response: ' .. tostring(err))
        return b
    end
end

local manifest = {}
local count = 0
local function save(kind, subject, bytes)
    count = count + 1
    local file = ('%04d.bin'):format(count)
    local f = assert(io.open(fio.pathjoin(out, file), 'wb'))
    f:write(bytes)
    f:close()
    manifest[#manifest + 1] = table.concat({kind, subject, file}, '\t')
end

save('list_services', '', stream(V1)({list_services = '*'}))
save('v1alpha_list_services', '', stream(V1ALPHA)({list_services = '*'}))

-- Every registered file, each on a fresh stream, so the response
-- carries the whole import closure.
for _, name in ipairs(pb.descriptors.files()) do
    save('file', name, stream(V1)({file_by_filename = name}))
end
save('v1alpha_file', 'hello.proto', stream(V1ALPHA)({file_by_filename = 'hello.proto'}))

-- Every service and every method by symbol.
for _, name in ipairs(refl:services()) do
    save('symbol', name, stream(V1)({file_containing_symbol = name}))
end
for _, s in ipairs(all) do
    local svc = s.service
    local methods = {}
    for mname in pairs(svc.methods) do methods[#methods + 1] = mname end
    table.sort(methods)
    for _, mname in ipairs(methods) do
        local sym = svc.name .. '.' .. mname
        save('symbol', sym, stream(V1)({file_containing_symbol = sym}))
    end
end

-- Several requests on one stream: later responses skip what earlier
-- ones sent.
local ask = stream(V1)
for _, name in ipairs({'library.proto', 'hello.proto', 'kv.proto',
                       'grpc/health/v1/health.proto'}) do
    save('dedup', name, ask({file_by_filename = name}))
end

local f = assert(io.open(fio.pathjoin(out, 'manifest.tsv'), 'wb'))
f:write(table.concat(manifest, '\n'), '\n')
f:close()
os.exit(0)
