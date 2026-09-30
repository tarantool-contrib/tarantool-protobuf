-- pb.descriptors: every generated module embeds its file's serialized
-- FileDescriptorProto and registers it on load; the runtime ships the
-- well-known types and google/api/{annotations,http}.proto.

local t     = require('luatest')
local fio   = require('fio')
local pb    = require('pb')
local codec = require('pb.codec')
local descpb = require('pb.descriptor_pb')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local PROTO_DIR   = fio.pathjoin(REPO_ROOT, 'examples', 'proto')
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local PLUGIN      = fio.pathjoin(REPO_ROOT, 'protoc-gen-tarantool')

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

local function spit(path, content)
    local f = assert(io.open(path, 'wb'))
    f:write(content)
    f:close()
end

local function sh(cmd)
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'command failed: ' .. cmd)
end

local function decode_file(bytes)
    return codec.decode(descpb.FileDescriptorProto, bytes)
end

-- The single file of a FileDescriptorSet produced for one .proto.
local function only_file_of_set(set)
    assert(set:byte(1) == 0x0a, 'FileDescriptorSet.file tag expected')
    local n, shift, pos = 0, 0, 2
    while true do
        local b = set:byte(pos)
        pos = pos + 1
        n = n + bit.lshift(bit.band(b, 0x7f), shift)
        shift = shift + 7
        if b < 0x80 then break end
    end
    assert(pos + n - 1 == #set, 'expected exactly one file in the set')
    return set:sub(pos, pos + n - 1)
end

local function protoc_descriptor(proto)
    local out = fio.pathjoin(fio.tempdir(), 'set.pb')
    sh(string.format('protoc --descriptor_set_out=%q -I %q -I %q %q',
        out, PROTO_DIR, OPTIONS_DIR, fio.pathjoin(PROTO_DIR, proto)))
    return only_file_of_set(slurp(out))
end

-- Every .proto `just gen` generates, with the module path suffix, the
-- package, and the services it declares.
local GENERATED = {
    {'hello.proto', 'hello.hello_pb', 'hello', {'Greeter'}},
    {'kv.proto', 'kv.kv_pb', 'kv', {}},
    {'quickstart.proto', 'quickstart.quickstart_pb', 'quickstart', {}},
    {'library.proto', 'library.library_pb', 'library', {'Library'}},
    {'proto2_basic.proto', 'proto2_basic.proto2_basic_pb', 'proto2_basic', {}},
    {'c_grow.proto', 'c_grow.c_grow_pb', 'c_grow', {}},
    {'c_grow_proto2.proto', 'c_grow_proto2.c_grow_proto2_pb', 'c_grow_proto2', {}},
    {'c_int64.proto', 'c_int64.c_int64_pb', 'c_int64', {}},
    {'c_nested.proto', 'c_nested.c_nested_pb', 'c_nested', {}},
    {'c_repeated.proto', 'c_repeated.c_repeated_pb', 'c_repeated', {}},
    {'conformance.proto', 'conformance.conformance_pb', 'conformance', {}},
    {'test_messages_proto3.proto',
     'protobuf_test_messages.proto3.test_messages_proto3_pb',
     'protobuf_test_messages.proto3', {}},
    {'test_messages_proto2.proto',
     'protobuf_test_messages.proto2.test_messages_proto2_pb',
     'protobuf_test_messages.proto2', {}},
}

local BUILTIN = {
    {'google/protobuf/descriptor.proto', 'google.protobuf'},
    {'google/protobuf/any.proto', 'google.protobuf'},
    {'google/protobuf/api.proto', 'google.protobuf'},
    {'google/protobuf/duration.proto', 'google.protobuf'},
    {'google/protobuf/empty.proto', 'google.protobuf'},
    {'google/protobuf/field_mask.proto', 'google.protobuf'},
    {'google/protobuf/source_context.proto', 'google.protobuf'},
    {'google/protobuf/struct.proto', 'google.protobuf'},
    {'google/protobuf/timestamp.proto', 'google.protobuf'},
    {'google/protobuf/type.proto', 'google.protobuf'},
    {'google/protobuf/wrappers.proto', 'google.protobuf'},
    {'google/protobuf/compiler/plugin.proto', 'google.protobuf.compiler'},
    {'google/api/annotations.proto', 'google.api'},
    {'google/api/http.proto', 'google.api'},
}

-- Every dependency of every registered file must itself be registered:
-- that is what a reflection client needs to rebuild the files.
local function assert_import_graph_closed()
    local checked = 0
    for _, name in ipairs(pb.descriptors.files()) do
        for _, dep in ipairs(pb.descriptors.dependencies(name)) do
            t.assert(pb.descriptors.file(dep) ~= nil,
                     name .. ' imports unregistered ' .. dep)
            checked = checked + 1
        end
    end
    return checked
end

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('descriptors.' .. mode)

    g.test_generated_modules_register_their_file = function()
        local n = 0
        for _, row in ipairs(GENERATED) do
            local fname, suffix, package, services = unpack(row)
            local m = require(mode .. '.' .. suffix)
            t.assert_type(m._file_descriptor, 'string', fname)
            t.assert_equals(pb.descriptors.file(fname), m._file_descriptor, fname)
            t.assert_equals(pb.descriptors.package(fname), package, fname)

            local fdp = decode_file(m._file_descriptor)
            t.assert_equals(fdp.name, fname)
            t.assert_equals(fdp.package, package)
            local got = {}
            for _, svc in ipairs(fdp.service or {}) do
                got[#got + 1] = svc.name
                t.assert_type(m[svc.name .. '_service'], 'table', svc.name)
            end
            t.assert_equals(got, services, fname)
            n = n + 1
        end
        t.assert_equals(n, #GENERATED)
    end

    g.test_import_graph_is_closed = function()
        require(mode .. '.hello.hello_pb')
        require(mode .. '.library.library_pb')
        t.assert_equals(pb.descriptors.dependencies('library.proto'),
            {'google/api/annotations.proto', 'google/protobuf/empty.proto'})
        t.assert(assert_import_graph_closed() > 0)
    end
end

local g = t.group('descriptors')

-- The embedded bytes are what protoc itself serializes for the file.
g.test_embedded_bytes_match_protoc = function()
    local hello = require('full.hello.hello_pb')
    t.assert_equals(hello._file_descriptor, protoc_descriptor('hello.proto'))
    local kv = require('full.kv.kv_pb')
    t.assert_equals(kv._file_descriptor, protoc_descriptor('kv.proto'))
end

-- With extension-carrying options the field order of a re-serialized
-- descriptor may differ from protoc's; the content must not.
g.test_embedded_library_matches_protoc_decoded = function()
    local lib = require('full.library.library_pb')
    local ours = decode_file(lib._file_descriptor)
    local theirs = decode_file(protoc_descriptor('library.proto'))
    t.assert_equals(ours, theirs)
    t.assert_equals(ours.service[1].method[1].options.http.get,
                    '/v1/{name=shelves/*/books/*}')
end

-- An embedded descriptor feeds pb.from_pb like protoc's own output.
g.test_embedded_descriptor_through_from_pb = function()
    local hello = require('full.hello.hello_pb')
    local b = hello._file_descriptor
    local set = '\x0a' .. pb.wire.encode_varint(#b) .. b
    local mod = pb.from_pb(set).files['hello.proto']
    t.assert_type(mod.Greeter_service, 'table')
    local req = {name = 'x'}
    t.assert_equals(mod.HelloRequest_encode(req), hello.HelloRequest_encode(req))
end

g.test_builtins = function()
    local files = {}
    for _, name in ipairs(pb.descriptors.files()) do files[name] = true end
    for _, row in ipairs(BUILTIN) do
        local name, package = row[1], row[2]
        t.assert(files[name], name .. ' missing from files()')
        local fdp = decode_file(pb.descriptors.file(name))
        t.assert_equals(fdp.name, name)
        t.assert_equals(fdp.package, package)
    end
    t.assert_equals(pb.descriptors.dependencies('google/api/annotations.proto'),
        {'google/api/http.proto', 'google/protobuf/descriptor.proto'})
    local http = decode_file(pb.descriptors.file('google/api/http.proto'))
    local names = {}
    for _, m in ipairs(http.message_type) do names[#names + 1] = m.name end
    t.assert_equals(names, {'Http', 'HttpRule', 'CustomHttpPattern'})
end

g.test_files_is_sorted = function()
    local files = pb.descriptors.files()
    t.assert(#files >= #BUILTIN)
    for i = 2, #files do t.assert(files[i - 1] < files[i]) end
end

g.test_unknown_file = function()
    t.assert_equals(pb.descriptors.file('no/such.proto'), nil)
    t.assert_equals(pb.descriptors.dependencies('no/such.proto'), nil)
    t.assert_equals(pb.descriptors.package('no/such.proto'), nil)
end

-- FileDescriptorProto{name: <name>, package: <pkg>}.
local function tiny_fdp(name, pkg)
    return '\x0a' .. string.char(#name) .. name .. '\x12' .. string.char(#pkg) .. pkg
end

g.test_register_semantics = function()
    local a = tiny_fdp('reg/x.proto', 'one')
    t.assert_equals(pb.descriptors.register(a), 'reg/x.proto')
    t.assert_equals(pb.descriptors.file('reg/x.proto'), a)
    -- Identical bytes: no-op.
    t.assert_equals(pb.descriptors.register(a), 'reg/x.proto')
    -- Different bytes under the same name: the later one wins.
    local b = tiny_fdp('reg/x.proto', 'two')
    pb.descriptors.register(b)
    t.assert_equals(pb.descriptors.file('reg/x.proto'), b)
    t.assert_equals(pb.descriptors.package('reg/x.proto'), 'two')
    t.assert_equals(pb.descriptors.dependencies('reg/x.proto'), {})
end

g.test_register_rejects_bad_input = function()
    t.assert_error_msg_contains('expected FileDescriptorProto bytes',
        pb.descriptors.register, 42)
    t.assert_error_msg_contains('has no name',
        pb.descriptors.register, '\x12\x03pkg')
    t.assert_error_msg_contains('not a FileDescriptorProto',
        pb.descriptors.register, '\x0a\x05ab')
end

-- ---------------------------------------------------------------------------
-- Generated on the fly: imports not generated alongside a file, imports
-- generated but not referenced, and exact escaping of every byte value.
-- ---------------------------------------------------------------------------

local ALL_BYTES
do
    local parts = {}
    for i = 0, 255 do parts[#parts + 1] = string.char(i) end
    ALL_BYTES = table.concat(parts)
end

local function proto_escape(s)
    return (s:gsub('.', function(c) return ('\\x%02x'):format(c:byte()) end))
end

local MAIN_PROTO = [[
syntax = "proto3";
package emb;
import "google/protobuf/descriptor.proto";
import "tarantool/tarantool.proto";
import "emb/side.proto";
import "emb/lib.proto";

extend google.protobuf.MessageOptions {
  bytes emb_blob = 50100;
}

message Main {
  option (emb_blob) = "]] .. proto_escape(ALL_BYTES) .. [[";
  string id = 1;
}
]]

local SIDE_PROTO = [[
syntax = "proto3";
package emb;
message Side { string x = 1; }
]]

local LIB_PROTO = [[
syntax = "proto3";
package emb;
import "emb/base.proto";
message Lib { emb.Base base = 1; }
]]

local BASE_PROTO = [[
syntax = "proto3";
package emb;
message Base { string y = 1; }
]]

local function generate(mode)
    local tmp = fio.tempdir()
    local src = fio.pathjoin(tmp, 'proto')
    local out = fio.pathjoin(tmp, 'out')
    assert(fio.mkdir(src))
    assert(fio.mkdir(fio.pathjoin(src, 'emb')))
    assert(fio.mkdir(out))
    spit(fio.pathjoin(src, 'emb', 'main.proto'), MAIN_PROTO)
    spit(fio.pathjoin(src, 'emb', 'side.proto'), SIDE_PROTO)
    spit(fio.pathjoin(src, 'emb', 'lib.proto'), LIB_PROTO)
    spit(fio.pathjoin(src, 'emb', 'base.proto'), BASE_PROTO)
    -- Only main and side are generated; lib and base are on -I only.
    sh(string.format(
        'protoc --plugin=%q --tarantool_out=%q --tarantool_opt=mode=%s,prefix=emb_%s '
        .. '-I %q -I %q %q %q 2>/dev/null',
        PLUGIN, out, mode, mode, src, OPTIONS_DIR,
        fio.pathjoin(src, 'emb', 'main.proto'),
        fio.pathjoin(src, 'emb', 'side.proto')))
    return out
end

local function load(out, modname)
    package.path = fio.pathjoin(out, '?.lua') .. ';' .. package.path
    package.loaded[modname] = nil
    return require(modname)
end

for _, mode in ipairs({'full', 'runtime'}) do
    local ge = t.group('descriptors_generated.' .. mode)

    ge.test_import_graph_registered = function()
        local out = generate(mode)
        local main = load(out, ('emb_%s.emb.main_pb'):format(mode))
        t.assert_equals(pb.descriptors.file('emb/main.proto'), main._file_descriptor)

        -- Generated alongside but unreferenced: required, so it
        -- registered itself.
        t.assert_type(package.loaded[('emb_%s.emb.side_pb'):format(mode)], 'table')
        t.assert_equals(pb.descriptors.file('emb/side.proto'),
            package.loaded[('emb_%s.emb.side_pb'):format(mode)]._file_descriptor)

        -- Not generated: embedded into main, transitively.
        for _, name in ipairs({'emb/lib.proto', 'emb/base.proto',
                               'tarantool/tarantool.proto'}) do
            local b = pb.descriptors.file(name)
            t.assert_type(b, 'string', name)
            t.assert_equals(decode_file(b).name, name)
        end

        -- Side is not embedded into main: its own module carries it.
        local src = slurp(fio.pathjoin(out, ('emb_%s'):format(mode), 'emb', 'main_pb.lua'))
        t.assert_not_str_contains(src, '-- emb/side.proto')
        t.assert_str_contains(src, '-- emb/lib.proto')

        t.assert(assert_import_graph_closed() > 0)
    end

    -- Every byte value 0..255 survives the Lua string literal verbatim.
    ge.test_every_byte_value_round_trips = function()
        local out = generate(mode)
        local main = load(out, ('emb_%s.emb.main_pb'):format(mode))
        t.assert(main._file_descriptor:find(ALL_BYTES, 1, true) ~= nil,
                 'the 256-byte option value must appear verbatim')
        t.assert_equals(main.Main_descriptor.options['emb.emb_blob'], ALL_BYTES)
    end
end
