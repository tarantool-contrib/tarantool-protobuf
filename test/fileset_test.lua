-- pb.from_pb: build runtime modules from a binary FileDescriptorSet.
--
-- We shell out to mainline `protoc --descriptor_set_out` at test start to
-- produce a fresh descriptor set for examples/proto/hello.proto, then
-- assert that the module pb.from_pb returns produces wire-compatible bytes
-- when matched against the statically-generated module.
local t = require('luatest')
local fio = require('fio')
local pb = require('pb')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local PROTO_DIR = fio.pathjoin(REPO_ROOT, 'examples', 'proto')
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local FIXTURE_PATH = fio.pathjoin(fio.tempdir(), 'hello.descpb')

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

-- Materialize once for all tests in this file.
local SET_BYTES
do
    local cmd = string.format(
        'protoc --descriptor_set_out=%q -I %q -I %q %q',
        FIXTURE_PATH, PROTO_DIR, OPTIONS_DIR,
        fio.pathjoin(PROTO_DIR, 'hello.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true,
           'protoc --descriptor_set_out failed: ' .. cmd)
    SET_BYTES = slurp(FIXTURE_PATH)
end

local g = t.group('fileset')

-- ---- structure ---------------------------------------------------------

g.test_set_top_level_shape = function()
    local set = pb.from_pb(SET_BYTES)
    t.assert_type(set.files, 'table')
    t.assert_type(set.order, 'table')
    t.assert_type(set.lookup, 'function')
    t.assert_equals(#set.order, 1)
    -- protoc encodes paths relative to the -I argument that matched.
    t.assert_str_contains(set.order[1], 'hello.proto')
end

g.test_module_has_expected_descriptors = function()
    local set = pb.from_pb(SET_BYTES)
    local m = set.files[set.order[1]]
    t.assert_type(m.Person_descriptor, 'table')
    t.assert_type(m.Address_descriptor, 'table')
    t.assert_type(m.Result_descriptor,  'table')
    t.assert_type(m.Event_descriptor,   'table')
    t.assert_type(m.Status_descriptor,  'table')
    t.assert_type(m.Person_encode,      'function')
    t.assert_type(m.Person_decode,      'function')
end

g.test_lookup_by_full_name = function()
    local set = pb.from_pb(SET_BYTES)
    local desc = set.lookup('hello.Person')
    t.assert_type(desc, 'table')
    t.assert_equals(desc.name, 'hello.Person')
    t.assert_equals(set.lookup('does.not.Exist'), nil)
end

-- ---- parity with the statically-generated module ----------------------

local function static() return require('full.hello.hello_pb') end
local function dyn()
    local set = pb.from_pb(SET_BYTES)
    return set.files[set.order[1]]
end

g.test_parity_scalars = function()
    local input = {street = 'Pushkina 1', city = 'Moscow', zip = 123456}
    t.assert_equals(dyn().Address_encode(input), static().Address_encode(input))
end

g.test_parity_repeated_packed = function()
    local input = {name = 'P', lucky_numbers = {1, 2, 3, 4, 5}}
    t.assert_equals(dyn().Person_encode(input), static().Person_encode(input))
end

g.test_parity_optional_field_presence = function()
    -- Empty `apartment` is meaningful and must round-trip.
    local input = {street = 'Main', apartment = ''}
    t.assert_equals(dyn().Address_encode(input), static().Address_encode(input))
end

g.test_parity_oneof = function()
    local input = {id = 7, text = 'hi'}
    t.assert_equals(dyn().Result_encode(input), static().Result_encode(input))
end

g.test_parity_oneof_message = function()
    local input = {id = 3, details = {street = 'X', zip = 99}}
    t.assert_equals(dyn().Result_encode(input), static().Result_encode(input))
end

g.test_parity_map_scalar = function()
    -- Single-key map; multi-key encode order follows Lua's pairs() hash
    -- order and won't match protoc's output, so use one entry.
    local input = {name = 'P', ages_by_nickname = {alice = 30}}
    t.assert_equals(dyn().Person_encode(input), static().Person_encode(input))
end

g.test_parity_map_message_value = function()
    local input = {name = 'P', addresses_by_label = {home = {street = 'Main', zip = 1}}}
    t.assert_equals(dyn().Person_encode(input), static().Person_encode(input))
end

g.test_parity_self_reference = function()
    local input = {
        name = 'P',
        friends = {{name = 'A'}, {name = 'B', age = 30}},
    }
    t.assert_equals(dyn().Person_encode(input), static().Person_encode(input))
end

g.test_parity_enum_by_name = function()
    local s = static()
    local input = {name = 'P', status = s.Status.ERROR}
    t.assert_equals(dyn().Person_encode(input), s.Person_encode(input))
end

-- ---- WKT references resolved through pb.wkt ----------------------------

g.test_parity_wkt_timestamp_table = function()
    local input = {title = 'x', created_at = {seconds = 1700000000, nanos = 5}}
    t.assert_equals(dyn().Event_encode(input), static().Event_encode(input))
end

g.test_parity_wkt_wrappers = function()
    local input = {title = 'x', retry_count = 7, note = 'hello', is_admin = true}
    t.assert_equals(dyn().Event_encode(input), static().Event_encode(input))
end

g.test_parity_wkt_fieldmask = function()
    local input = {title = 'x', update_mask = {'a', 'b', 'c'}}
    t.assert_equals(dyn().Event_encode(input), static().Event_encode(input))
end

g.test_parity_wkt_empty = function()
    local input = {title = 'x', ack = {}}
    t.assert_equals(dyn().Event_encode(input), static().Event_encode(input))
end

-- ---- round-trip via dynamic decode then static decode ------------------

g.test_round_trip_through_dynamic = function()
    -- Encode with the static module, decode with the dynamic one, re-encode
    -- with the dynamic one; check the bytes match.
    local s = static()
    local input = {
        name = 'P', age = 33, emails = {'a@x', 'b@y'},
        status = s.Status.OK,
        address = {street = 'Main', city = 'X', zip = 1},
        lucky_numbers = {1, 2, 3},
    }
    local bytes = s.Person_encode(input)
    local decoded = dyn().Person_decode(bytes)
    t.assert_equals(dyn().Person_encode(decoded), bytes)
end

-- An rpc whose types live in another file of the set resolves across it.
g.test_service_types_resolve_across_files = function()
    local src = fio.pathjoin(fio.tempdir(), 'proto')
    assert(fio.mktree(fio.pathjoin(src, 'xf')))
    local function write(rel, body)
        local f = assert(io.open(fio.pathjoin(src, rel), 'wb'))
        f:write(body)
        f:close()
    end
    write('xf/types.proto', 'syntax = "proto3";\npackage xf;\n'
        .. 'message In { string x = 1; }\nmessage Out { int32 y = 1; }\n')
    write('xf/svc.proto', 'syntax = "proto3";\npackage xf;\n'
        .. 'import "xf/types.proto";\n'
        .. 'service S { rpc M(xf.In) returns (xf.Out); }\n')
    local out = fio.pathjoin(fio.tempdir(), 'set.pb')
    local cmd = string.format(
        'protoc --include_imports --descriptor_set_out=%q -I %q %q',
        out, src, fio.pathjoin(src, 'xf', 'svc.proto'))
    local ok = os.execute(cmd)
    t.assert(ok == 0 or ok == true, cmd)
    local set = pb.from_pb(slurp(out))
    local m = set.files['xf/svc.proto'].S_service.methods.M
    t.assert_is(m.input, set.lookup('xf.In'))
    t.assert_is(m.output, set.lookup('xf.Out'))
end
