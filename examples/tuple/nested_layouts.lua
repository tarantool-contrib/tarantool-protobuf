-- One nested message stored three ways: as a map, an array, raw bytes.
--
-- A singular message field takes its tuple layout from its column type.
-- Walked through in docs/howto/14-tuples.md.
--
-- Run with:
--   just examples tuple-layouts
-- or, from the repo root:
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;;" \
--       tarantool examples/tuple/nested_layouts.lua

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
local varbinary = require('varbinary')

-- A message with one nested field, of type
-- kv.Address { string street = 1; string city = 2; uint32 zip = 4; }.
local Contact = pb.finalize_message({
    name   = 'demo.Contact',
    fields = {
        {name = 'id', id = 1, kind = 'scalar', proto_type = 'string'},
        {name = 'address', id = 2, kind = 'message',
         message = kv.Address_descriptor},
    },
})

-- One space per column type for `address`, each with its converter.
local function contacts(column_type)
    local space = box.schema.space.create('contacts_' .. column_type, {
        format = {
            {name = 'id',      type = 'string'},
            {name = 'address', type = column_type, is_nullable = true},
        },
    })
    space:create_index('pk', {parts = {'id'}})
    return space, pb.tuple.bind(Contact, space)
end

local as_map, map_conv = contacts('map')
local as_array, array_conv = contacts('array')
local as_raw, raw_conv = contacts('varbinary')

-- The same address in each layout.
as_map:replace{'c1', {street = 'Main St', city = 'Springfield', zip = 12345}}
as_array:replace{'c1', {'Main St', 'Springfield', box.NULL, 12345}}
local address = kv.Address_encode({
    street = 'Main St', city = 'Springfield', zip = 12345,
})
as_raw:replace{'c1', varbinary.new(address)}

local bytes = map_conv:encode(as_map:get('c1'))
print(('map: %d bytes'):format(#bytes))
print('array, same bytes: '
      .. tostring(array_conv:encode(as_array:get('c1')) == bytes))
print('varbinary, same bytes: '
      .. tostring(raw_conv:encode(as_raw:get('c1')) == bytes))

-- Decoding lays the message out per column type again.
local m = map_conv:decode(bytes)[2]
print(('map decode: street %s, city %s, zip %d'):format(
    m.street, m.city, m.zip))
local a = array_conv:decode(bytes)[2]
print(('array decode: %d positions, [3] is NULL: %s, [4] is %d'):format(
    #a, tostring(a[3] == box.NULL), a[4]))
local r = raw_conv:decode(bytes)[2]
print('varbinary decode, the Address bytes: '
      .. tostring(tostring(r) == address))

fio.rmtree(data_dir)
os.exit(0)
