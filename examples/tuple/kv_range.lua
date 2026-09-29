-- Serve an etcd-style Range response straight from space tuples.
--
-- pb.tuple binds a message descriptor to a space format once; after
-- that a tuple converts to wire bytes, and wire bytes to a tuple, in
-- one call. With the C runtime (PB_ENABLE_C=1) that builds no Lua table
-- per row; the default Lua path still allocates per row. Walked through
-- in docs/howto/14-tuples.md.
--
-- Run with:
--   just examples tuple-range
-- or, from the repo root:
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;;" \
--       tarantool examples/tuple/kv_range.lua

local fio = require('fio')

-- Ephemeral instance in a fresh temporary directory, removed on exit.
-- Nothing here has to survive a restart, so there is no WAL to write.
local data_dir = fio.tempdir()
box.cfg{
    memtx_dir = data_dir,
    wal_dir   = data_dir,
    wal_mode  = 'none',
    log       = data_dir .. '/tarantool.log',
}

local pb = require('pb')
local kv = require('full.kv.kv_pb')

-- 1. The space. Column names follow kv.KeyValue except `lease_id`, and
--    `owner` is a column of the store's own that no proto field maps to.
local space = box.schema.space.create('kv', {format = {
    {name = 'key',             type = 'string'},
    {name = 'create_revision', type = 'unsigned'},
    {name = 'mod_revision',    type = 'unsigned'},
    {name = 'version',         type = 'unsigned'},
    {name = 'value',           type = 'any',      is_nullable = true},
    {name = 'lease_id',        type = 'unsigned', is_nullable = true},
    {name = 'owner',           type = 'string',   is_nullable = true},
}})
space:create_index('pk', {parts = {'key'}})

space:replace{'/app/a', 2, 2, 1, 'alpha', box.NULL, box.NULL}
space:replace{'/app/b', 3, 7, 3, 'beta', 42, 'ops'}
space:replace{'/app/c', 4, 4, 1, 'gamma', box.NULL, 'ops'}
space:replace{'/other/x', 5, 5, 1, 'xray', box.NULL, box.NULL}

-- 2. Bind once, at startup. Every descriptor/format mismatch raises here.
local KeyValue = kv.KeyValue_descriptor
local full = pb.tuple.bind(KeyValue, space, {columns = {lease = 'lease_id'}})
local keys_only = pb.tuple.bind(KeyValue, space, {
    columns = {lease = 'lease_id'},
    omit    = {'value'},
})

local ok, err = pcall(pb.tuple.bind, KeyValue, space)
print('bind without the rename: ' .. tostring(ok))
print('  ' .. err)

-- 3. The response. etcd's RangeResponse, trimmed to the fields this
--    example fills. Hand-rolled so that `kvs` can point at the
--    generated KeyValue descriptor.
local RangeResponse = pb.finalize_message({
    name   = 'etcdserverpb.RangeResponse',
    fields = {
        {name = 'kvs', id = 2, kind = 'message', message = KeyValue,
         repeated = true},
        {name = 'more',  id = 3, kind = 'scalar', proto_type = 'bool'},
        {name = 'count', id = 4, kind = 'scalar', proto_type = 'int64'},
    },
})
local KVS = 2  -- RangeResponse.kvs

-- Every key under `prefix`, at most `limit` of them in the response.
-- The rows stay box.tuple values from select to wire bytes.
local function range(conv, prefix, limit)
    local page, count = {}, 0
    for _, t in space:pairs(prefix, {iterator = 'GE'}) do
        if t.key:sub(1, #prefix) ~= prefix then break end
        count = count + 1
        if count <= limit then page[count] = t end
    end
    -- Concatenated protobuf messages decode as one merged message, so
    -- the rows and the scalar fields are encoded separately and joined.
    return conv:encode_repeated(KVS, page)
        .. pb.encode(RangeResponse, {more = count > limit, count = count})
end

-- 4. Decode the response with the ordinary codec, as a client would.
--    The codec leaves a field that is not on the wire nil.
local function show(title, bytes)
    local resp = pb.decode(RangeResponse, bytes)
    print(('%s: %d of %d keys, more = %s, %d bytes'):format(title,
        #resp.kvs, tonumber(resp.count), tostring(resp.more == true),
        #bytes))
    for _, item in ipairs(resp.kvs) do
        if item.value ~= nil then
            print(('  %s = %s (mod_revision %d, lease %d)'):format(item.key,
                item.value, tonumber(item.mod_revision),
                tonumber(item.lease or 0)))
        else
            print('  ' .. item.key)
        end
    end
end

show('range /app/', range(full, '/app/', 10))
show('keys only, limit 2', range(keys_only, '/app/', 2))

-- 5. The other direction: a KeyValue arriving on the wire becomes a row.
local put = kv.KeyValue_encode({
    key = '/app/d', create_revision = 9, mod_revision = 9, version = 1,
    value = 'delta', lease = 7,
})
local row = full:replace(put)
print('stored: ' .. row.key .. ', lease_id ' .. row.lease_id
      .. ', owner ' .. tostring(row.owner))
print('re-encodes to the same bytes: ' .. tostring(full:encode(row) == put))

-- decode builds the tuple without storing it. The tuple carries no
-- space format, so its fields are read by number. Unset fields come
-- back as their proto3 defaults.
local t = full:decode(kv.KeyValue_encode({key = '/app/e'}))
print('decoded: ' .. tostring(t))

-- A value the column cannot hold is refused per value.
ok, err = pcall(full.replace, full, kv.KeyValue_encode({
    key = '/app/f', lease = -1,
}))
print('negative lease: ' .. tostring(ok))
print('  ' .. err)

fio.rmtree(data_dir)
os.exit(0)
