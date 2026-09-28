-- Load .proto schemas from a Tarantool space at runtime.
--
-- Pattern: store the .proto source text in a space, parse it on demand,
-- cache the resulting module. Schema updates land in the space; readers
-- pick them up after a cache invalidation.
--
-- Run with:
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;;" tarantool examples/dynamic/load_from_space.lua

-- Ephemeral instance; state in /tmp so the example doesn't litter the
-- working directory with .snap / .xlog files.
local data_dir = '/tmp/tarantool-protobuf-dynamic-example'
os.execute('mkdir -p ' .. data_dir)
box.cfg{
    listen      = nil,
    memtx_dir   = data_dir,
    wal_dir     = data_dir,
    log         = data_dir .. '/tarantool.log',
}

local pb = require('pb')

-- 1. Bootstrap a space that holds proto schemas keyed by name.
box.once('init_schemas', function()
    box.schema.space.create('proto_schemas')
    box.space.proto_schemas:format({
        {name = 'name',    type = 'string'},
        {name = 'version', type = 'unsigned'},
        {name = 'source',  type = 'string'},
    })
    box.space.proto_schemas:create_index('pk', {parts = {'name'}})
end)

-- 2. Insert a schema. In production this lands via your app's
--    admin / migration path; here we just write it inline.
box.space.proto_schemas:replace{'demo.user.v1', 1, [[
syntax = "proto3";
package demo.user.v1;

message User {
    int32 id = 1;
    string name = 2;
    repeated string tags = 3;
}
]]}

-- 3. Cache parsed modules by (schema_name, version). Invalidate by
--    bumping the version row when you update the source.
local cache = {}

local function get_module(name)
    local row = box.space.proto_schemas:get(name)
    if row == nil then
        error(("schema %q not found"):format(name), 0)
    end
    local key = name .. '@' .. tostring(row.version)
    local mod = cache[key]
    if mod == nil then
        mod = pb.parse(row.source)
        cache[key] = mod
    end
    return mod
end

-- 4. Use it like any generated module.
local demo = get_module('demo.user.v1')

local bytes = demo.User_encode({
    id = 42,
    name = 'Alice',
    tags = {'admin', 'active'},
})
print(('encoded %d bytes'):format(#bytes))

local user = demo.User_decode(bytes)
print(('decoded: id=%d name=%s tags=%s,%s'):format(
    user.id, user.name, user.tags[1], user.tags[2]))

-- 5. Schema upgrade: bump version + source, next get_module rebuilds.
box.space.proto_schemas:replace{'demo.user.v1', 2, [[
syntax = "proto3";
package demo.user.v1;

message User {
    int32 id = 1;
    string name = 2;
    repeated string tags = 3;
    string email = 4;
}
]]}

local demo_v2 = get_module('demo.user.v1')

-- v1-encoded bytes still decode (new field absent).
local user_v1 = demo_v2.User_decode(bytes)
print(('v2 reads v1 bytes: email=%s'):format(tostring(user_v1.email)))

-- v2-encoded bytes carry the new field.
local bytes_v2 = demo_v2.User_encode({
    id = 42, name = 'Alice', tags = {'admin'}, email = 'alice@x',
})
print(('v2 encoded %d bytes; email round-trips: %s')
    :format(#bytes_v2, demo_v2.User_decode(bytes_v2).email))

os.exit(0)
