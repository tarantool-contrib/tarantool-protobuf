-- Tests for google.protobuf.Any (with type registry) and FieldMask.
local t  = require('luatest')
local pb = require('pb')
local wkt = pb.wkt

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- FieldMask
-- ---------------------------------------------------------------------------
local gf = t.group('fieldmask.wire')

gf.test_empty = function()
    t.assert_equals(wkt.FieldMask_encode({}), '')
    t.assert_equals(#wkt.FieldMask_decode(''), 0)
end

gf.test_paths_round_trip = function()
    local mask = {'user.email', 'user.address.city', 'enabled'}
    local enc = wkt.FieldMask_encode(mask)
    local dec = wkt.FieldMask_decode(enc)
    t.assert_equals(#dec, 3)
    t.assert_equals(dec[1], mask[1])
    t.assert_equals(dec[2], mask[2])
    t.assert_equals(dec[3], mask[3])
end

local gfj = t.group('fieldmask.json')
local hello = require('full.hello.hello_pb')

local function reparse(s) return require('json').decode(s) end

gfj.test_encode_canonical_camelcase = function()
    local enc = pb.json.encode(hello.Event_descriptor, {
        update_mask = {'user_id', 'is_admin', 'created_at'},
    })
    -- snake_case → lowerCamelCase, joined by commas.
    t.assert_equals(reparse(enc).updateMask, 'userId,isAdmin,createdAt')
end

gfj.test_decode_camelcase_to_snakecase = function()
    local back = pb.json.decode(hello.Event_descriptor,
        '{"updateMask": "userId,isAdmin"}')
    t.assert_equals(back.update_mask[1], 'user_id')
    t.assert_equals(back.update_mask[2], 'is_admin')
end

-- ---------------------------------------------------------------------------
-- Any
-- ---------------------------------------------------------------------------
local ga = t.group('any.wire')

ga.test_opaque_round_trip = function()
    local opaque = {
        type_url = 'type.googleapis.com/hello.Address',
        value    = '\x0a\x05hello',
    }
    local enc = wkt.Any_encode(opaque)
    local dec = wkt.Any_decode(enc)
    t.assert_equals(dec.type_url, opaque.type_url)
    t.assert_equals(dec.value, opaque.value)
end

ga.test_pack_unpack_via_registry = function()
    pb.register(hello.Address_descriptor)
    local boxed = pb.any.pack(hello.Address_descriptor,
                              {street = 'Main', city = 'X', zip = 1})
    t.assert_str_contains(boxed.type_url, 'hello.Address')
    -- value is the wire-encoded Address payload.
    local unpacked = pb.any.unpack(boxed)
    t.assert_equals(unpacked.street, 'Main')
    t.assert_equals(unpacked.city,   'X')
    t.assert_equals(unpacked.zip,    1)
end

ga.test_unpack_unregistered_errors = function()
    t.assert_error_msg_contains(
        'no descriptor for',
        function() pb.any.unpack({type_url = 'type.unknown/Foo', value = ''}) end)
end

ga.test_unpack_with_explicit_descriptor_overrides_registry = function()
    -- Even if not registered, an explicit descriptor lets unpack succeed.
    local boxed = pb.any.pack(hello.Address_descriptor, {street = 'S'})
    local unpacked = pb.any.unpack(boxed, hello.Address_descriptor)
    t.assert_equals(unpacked.street, 'S')
end

local gaj = t.group('any.json')

gaj.test_json_round_trip_with_registered_type = function()
    pb.register(hello.Address_descriptor)
    local e = {
        extension = pb.any.pack(hello.Address_descriptor,
                                {street = 'JSON St', zip = 7}),
    }
    local enc = pb.json.encode(hello.Event_descriptor, e)
    local obj = reparse(enc)
    -- Flat form: @type plus the Address fields.
    t.assert_equals(obj.extension['@type'],
                    'type.googleapis.com/hello.Address')
    t.assert_equals(obj.extension.street, 'JSON St')
    t.assert_equals(obj.extension.zip, 7)

    -- Decode reverses.
    local back = pb.json.decode(hello.Event_descriptor, enc)
    t.assert_str_contains(back.extension.type_url, 'hello.Address')
    local inner = pb.any.unpack(back.extension)
    t.assert_equals(inner.street, 'JSON St')
    t.assert_equals(inner.zip, 7)
end

gaj.test_json_opaque_fallback_when_type_unregistered = function()
    -- Untouched: even without registry knowledge the value field survives
    -- through a base64 round-trip.
    local opaque = {type_url = 'type.opaque/Foo', value = '\x01\x02\x03'}
    local enc = pb.json.encode(hello.Event_descriptor, {extension = opaque})
    local obj = reparse(enc)
    t.assert_equals(obj.extension['@type'], 'type.opaque/Foo')
    t.assert(obj.extension.value, 'value field present as base64')
    local back = pb.json.decode(hello.Event_descriptor, enc)
    t.assert_equals(back.extension.type_url, 'type.opaque/Foo')
    t.assert_equals(back.extension.value, '\x01\x02\x03')
end

gaj.test_json_opaque_value_base64_unwrapped = function()
    -- Same canonical-base64 rule as plain bytes fields: the Any opaque
    -- fallback must not emit MIME-style line wraps inside the JSON string.
    local opaque = {type_url = 'type.opaque/Big', value = string.rep('A', 64)}
    local enc = pb.json.encode(hello.Event_descriptor, {extension = opaque})
    t.assert_not_str_contains(enc, '\n')
    t.assert_not_str_contains(enc, '\\n')
    local back = pb.json.decode(hello.Event_descriptor, enc)
    t.assert_equals(back.extension.value, opaque.value)
end

-- ---------------------------------------------------------------------------
-- End-to-end: Event message round-trip with extension + update_mask.
-- ---------------------------------------------------------------------------
for _, mode in ipairs({'full', 'runtime'}) do
    local ge = t.group('any_fieldmask.event.' .. mode)
    local h = require(mode .. '.hello.hello_pb')

    ge.test_event_with_any_and_mask = function()
        pb.register(h.Address_descriptor)
        local e = {
            title       = 'wrapped',
            extension   = pb.any.pack(h.Address_descriptor,
                                      {street = 'A', city = 'B', zip = 5}),
            update_mask = {'title', 'extension'},
        }
        local dec = h.Event_decode(h.Event_encode(e))
        t.assert_equals(dec.title, 'wrapped')
        t.assert_str_contains(dec.extension.type_url, 'hello.Address')
        local inner = pb.any.unpack(dec.extension)
        t.assert_equals(inner.street, 'A')
        t.assert_equals(inner.zip, 5)
        t.assert_equals(#dec.update_mask, 2)
        t.assert_equals(dec.update_mask[1], 'title')
    end
end

local gp = t.group('any_fieldmask.parity')
local hello_full    = require('full.hello.hello_pb')
local hello_runtime = require('runtime.hello.hello_pb')

gp.test_bytes_match_across_modes = function()
    pb.register(hello_full.Address_descriptor)
    local e = {
        extension   = pb.any.pack(hello_full.Address_descriptor,
                                  {street = 'Same', zip = 9}),
        update_mask = {'a', 'b', 'c'},
    }
    t.assert_equals(hex(hello_full.Event_encode(e)),
                    hex(hello_runtime.Event_encode(e)))
end
