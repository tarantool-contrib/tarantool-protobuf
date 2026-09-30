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

local function protoc_descriptor(proto, dir)
    dir = dir or PROTO_DIR
    local out = fio.pathjoin(fio.tempdir(), 'set.pb')
    sh(string.format('protoc --descriptor_set_out=%q -I %q -I %q %q',
        out, dir, OPTIONS_DIR, fio.pathjoin(dir, proto)))
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

-- The embedded bytes are exactly what protoc itself serializes for the
-- file, for every generated .proto (library.proto carries extension
-- options, whose field order a re-marshal would not preserve).
local PROTO_DIRS = {
    fio.pathjoin(REPO_ROOT, 'examples', 'proto'),
    fio.pathjoin(REPO_ROOT, 'test', 'proto'),
    fio.pathjoin(REPO_ROOT, 'test', 'conformance', 'proto'),
}

g.test_embedded_bytes_match_protoc = function()
    local n = 0
    for _, row in ipairs(GENERATED) do
        local fname, suffix = row[1], row[2]
        local dir
        for _, d in ipairs(PROTO_DIRS) do
            if fio.path.exists(fio.pathjoin(d, fname)) then dir = d end
        end
        t.assert(dir, fname)
        local m = require('full.' .. suffix)
        t.assert_equals(m._file_descriptor, protoc_descriptor(fname, dir), fname)
        n = n + 1
    end
    t.assert_equals(n, #GENERATED)
    local lib = decode_file(require('full.library.library_pb')._file_descriptor)
    t.assert_equals(lib.service[1].method[1].options.http.get,
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

-- The shipped built-ins are what the host protoc serializes for the same
-- files (`just gen` regenerates them from it), descriptor.proto included
-- with its current FeatureSet / Edition data.
g.test_builtins_match_protoc = function()
    local out = fio.pathjoin(fio.tempdir(), 'builtin.pb')
    local names = {}
    for _, row in ipairs(BUILTIN) do names[#names + 1] = ('%q'):format(row[1]) end
    sh(string.format('protoc --include_imports --descriptor_set_out=%q -I %q %s',
        out, OPTIONS_DIR, table.concat(names, ' ')))
    local SET = {
        name = 'google.protobuf.FileDescriptorSet',
        fields = {{name = 'file', id = 1, kind = 'scalar', proto_type = 'bytes',
                   repeated = true, packed = false}},
    }
    SET.field_by_id = {[1] = SET.fields[1]}
    SET.field_by_name = {file = SET.fields[1]}
    codec.compile_writers(SET)
    codec.compile_readers(SET)
    local n = 0
    for _, b in ipairs(codec.decode(SET, slurp(out)).file) do
        local name = decode_file(b).name
        t.assert_equals(pb.descriptors.file(name), b, name)
        n = n + 1
    end
    t.assert_equals(n, #BUILTIN)
    local desc = decode_file(pb.descriptors.file('google/protobuf/descriptor.proto'))
    local has_edition = false
    for _, e in ipairs(desc.enum_type) do
        if e.name == 'Edition' then has_edition = true end
    end
    t.assert(has_edition, 'descriptor.proto carries the Edition enum')
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

local SNAP = {snapshot = true}

g.test_register_authoritative_replaces_authoritative = function()
    local a = tiny_fdp('reg/aa.proto', 'one')
    t.assert_equals(pb.descriptors.register(a), 'reg/aa.proto')
    t.assert_equals(pb.descriptors.file('reg/aa.proto'), a)
    -- Identical bytes: no-op.
    t.assert_equals(pb.descriptors.register(a), 'reg/aa.proto')
    -- A newer own-file registration wins (hot reload).
    local b = tiny_fdp('reg/aa.proto', 'two')
    pb.descriptors.register(b)
    t.assert_equals(pb.descriptors.file('reg/aa.proto'), b)
    t.assert_equals(pb.descriptors.package('reg/aa.proto'), 'two')
    t.assert_equals(pb.descriptors.dependencies('reg/aa.proto'), {})
end

g.test_register_snapshot_never_replaces_authoritative = function()
    local own = tiny_fdp('reg/as.proto', 'own')
    pb.descriptors.register(own)
    pb.descriptors.register(tiny_fdp('reg/as.proto', 'stale'), SNAP)
    t.assert_equals(pb.descriptors.file('reg/as.proto'), own)
end

g.test_register_authoritative_replaces_snapshot = function()
    pb.descriptors.register(tiny_fdp('reg/sa.proto', 'stale'), SNAP)
    t.assert_equals(pb.descriptors.package('reg/sa.proto'), 'stale')
    local own = tiny_fdp('reg/sa.proto', 'own')
    pb.descriptors.register(own)
    t.assert_equals(pb.descriptors.file('reg/sa.proto'), own)
    -- ...and is not displaced by a later snapshot either.
    pb.descriptors.register(tiny_fdp('reg/sa.proto', 'late'), SNAP)
    t.assert_equals(pb.descriptors.file('reg/sa.proto'), own)
end

g.test_register_snapshot_conflict_keeps_first_and_warns_once = function()
    local orig = pb.descriptors._warn
    local warnings = {}
    pb.descriptors._warn = function(msg) warnings[#warnings + 1] = msg end
    local ok, err = pcall(function()
        local first = tiny_fdp('reg/ss.proto', 'first')
        pb.descriptors.register(first, SNAP)
        pb.descriptors.register(first, SNAP)          -- identical: silent
        pb.descriptors.register(tiny_fdp('reg/ss.proto', 'second'), SNAP)
        pb.descriptors.register(tiny_fdp('reg/ss.proto', 'third'), SNAP)
        t.assert_equals(pb.descriptors.file('reg/ss.proto'), first)
    end)
    pb.descriptors._warn = orig
    if not ok then error(err, 0) end
    t.assert_equals(#warnings, 1)
    t.assert_str_contains(warnings[1], 'reg/ss.proto')
end

-- Identical bytes registered by the file's own module promote a
-- snapshot, so a later different snapshot cannot replace it.
g.test_register_identical_promotes_snapshot = function()
    local b = tiny_fdp('reg/pr.proto', 'same')
    pb.descriptors.register(b, SNAP)
    pb.descriptors.register(b)
    pb.descriptors.register(tiny_fdp('reg/pr.proto', 'other'), SNAP)
    t.assert_equals(pb.descriptors.file('reg/pr.proto'), b)
end

g.test_register_rejects_bad_input = function()
    t.assert_error_msg_contains('expected FileDescriptorProto bytes',
        pb.descriptors.register, 42)
    t.assert_error_msg_contains('has no name',
        pb.descriptors.register, '\x12\x03pkg')
    t.assert_error_msg_contains('not a FileDescriptorProto',
        pb.descriptors.register, '\x0a\x05ab')
    t.assert_error_msg_contains('opts must be a table',
        pb.descriptors.register, tiny_fdp('reg/bad.proto', 'x'), true)
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

-- Write `files` ({relative path = source}) under a fresh proto root.
local function proto_tree(files)
    local src = fio.pathjoin(fio.tempdir(), 'proto')
    for rel, body in pairs(files) do
        local path = fio.pathjoin(src, rel)
        assert(fio.mktree(fio.dirname(path)))
        spit(path, body)
    end
    return src
end

-- One protoc run generating `inputs` (paths relative to src) into out.
local function protoc_gen(src, out, mode, prefix, inputs)
    assert(fio.mktree(out))
    local args = {}
    for _, rel in ipairs(inputs) do
        args[#args + 1] = ('%q'):format(fio.pathjoin(src, rel))
    end
    sh(string.format(
        'protoc --plugin=%q --tarantool_out=%q --tarantool_opt=mode=%s,prefix=%s '
        .. '-I %q -I %q %s 2>/dev/null',
        PLUGIN, out, mode, prefix, src, OPTIONS_DIR, table.concat(args, ' ')))
    return out
end

local EMB_TREE = {
    ['emb/main.proto'] = MAIN_PROTO,
    ['emb/side.proto'] = SIDE_PROTO,
    ['emb/lib.proto']  = LIB_PROTO,
    ['emb/base.proto'] = BASE_PROTO,
}

-- main and side generated in one run; lib and base are on -I only.
local function generate(mode)
    local src = proto_tree(EMB_TREE)
    return protoc_gen(src, fio.pathjoin(fio.tempdir(), 'out'), mode,
        'emb_' .. mode, {'emb/main.proto', 'emb/side.proto'})
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

        -- An import no field references is not required...
        t.assert_equals(package.loaded[('emb_%s.emb.side_pb'):format(mode)], nil)

        -- ...every non-builtin import, direct or transitive, generated
        -- in the same run or not, is registered from a snapshot.
        for _, name in ipairs({'emb/side.proto', 'emb/lib.proto',
                               'emb/base.proto', 'tarantool/tarantool.proto'}) do
            local b = pb.descriptors.file(name)
            t.assert_type(b, 'string', name)
            t.assert_equals(decode_file(b).name, name)
        end

        -- Built-ins are not embedded.
        local src = slurp(fio.pathjoin(out, ('emb_%s'):format(mode), 'emb', 'main_pb.lua'))
        t.assert_not_str_contains(src, '-- google/protobuf/descriptor.proto')
        t.assert_str_contains(src, '-- emb/side.proto')

        t.assert(assert_import_graph_closed() > 0)
    end

    -- Generated code must not depend on how protoc was invoked: all files
    -- in one run, or one run per file, produce the same modules.
    ge.test_output_independent_of_invocation_shape = function()
        local src = proto_tree(EMB_TREE)
        local prefix = 'shape_' .. mode
        local together = protoc_gen(src, fio.pathjoin(fio.tempdir(), 'out'),
            mode, prefix, {'emb/main.proto', 'emb/side.proto'})
        local separate = fio.pathjoin(fio.tempdir(), 'out')
        protoc_gen(src, separate, mode, prefix, {'emb/main.proto'})
        protoc_gen(src, separate, mode, prefix, {'emb/side.proto'})
        local n = 0
        for _, f in ipairs({'main_pb.lua', 'side_pb.lua'}) do
            local rel = fio.pathjoin(prefix, 'emb', f)
            t.assert_equals(slurp(fio.pathjoin(separate, rel)),
                            slurp(fio.pathjoin(together, rel)), f)
            n = n + 1
        end
        t.assert_equals(n, 2)
    end

    -- An older, independently generated parent carries a snapshot of
    -- its import from before the import changed. Whichever order the
    -- modules load in, the import's own (newer) descriptor ends up in
    -- the registry. Each mode uses its own file names, since the
    -- registry is process-wide.
    ge.test_stale_parent_snapshot_never_wins = function()
        for _, order in ipairs({'dep_first', 'parent_first'}) do
            local dir = ('stale_%s_%s'):format(mode, order)
            local dep = dir .. '/dep.proto'
            local parent_src = ([[
syntax = "proto3";
package %s;
import "%s";
message Parent { string p = 1; }
]]):format(dir, dep)
            local dep_v1 = ('syntax = "proto3";\npackage %s;\n'
                .. 'message Dep { string a = 1; }\n'):format(dir)
            local dep_v2 = ('syntax = "proto3";\npackage %s;\n'
                .. 'message Dep { string a = 1; int64 b = 2; }\n'):format(dir)

            local old_src = proto_tree({[dep] = dep_v1, [dir .. '/parent.proto'] = parent_src})
            local old_out = protoc_gen(old_src, fio.pathjoin(fio.tempdir(), 'out'),
                mode, 'old', {dir .. '/parent.proto'})
            local new_src = proto_tree({[dep] = dep_v2})
            local new_out = protoc_gen(new_src, fio.pathjoin(fio.tempdir(), 'out'),
                mode, 'new', {dep})

            local function load_parent()
                return load(old_out, ('old.%s.parent_pb'):format(dir))
            end
            local function load_dep()
                return load(new_out, ('new.%s.dep_pb'):format(dir))
            end

            local new_dep
            if order == 'dep_first' then
                new_dep = load_dep()
                load_parent()
            else
                load_parent()
                -- The snapshot fills the gap until the import's module loads.
                local snap = decode_file(pb.descriptors.file(dep))
                t.assert_equals(#snap.message_type[1].field, 1, order)
                new_dep = load_dep()
            end
            t.assert_equals(pb.descriptors.file(dep), new_dep._file_descriptor, order)
            t.assert_equals(#decode_file(pb.descriptors.file(dep)).message_type[1].field,
                            2, order)
        end
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
