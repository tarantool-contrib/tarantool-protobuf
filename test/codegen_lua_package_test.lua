-- Regression test for (tarantool.lua_package) file option.
--
-- The option lives on FileOptions as extension field 53301 and overrides
-- the default `<pkg>.<file>_pb` Lua require path. The plugin parses the
-- extension via protoreflect/protoregistry, so this test guards against
-- the option silently becoming a no-op when the extension is not
-- registered in the global type registry (the failure mode is that
-- proto.GetExtension returns "" and the override is lost).
--
-- Coverage:
--   * The on-disk output path follows `lua_package`, not `<pkg>/<file>_pb`.
--   * Cross-file `import "other.proto"` rewrites to `require("<lua_package>")`.

local t = require('luatest')
local fio = require('fio')

local g = t.group('codegen_lua_package')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local PLUGIN = fio.pathjoin(REPO_ROOT, 'protoc-gen-tarantool')

local function spit(path, content)
    local f = assert(io.open(path, 'wb'))
    f:write(content)
    f:close()
end

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

local function ensure_plugin()
    if fio.path.exists(PLUGIN) then return end
    local cmd = string.format('cd %q && go build -o %s ./cmd/protoc-gen-tarantool',
                              REPO_ROOT, fio.basename(PLUGIN))
    assert(os.execute(cmd) == 0 or os.execute(cmd) == true,
           'failed to build plugin: ' .. cmd)
end

local SAMPLE_PROTO = [[
syntax = "proto3";
package sample;
import "tarantool/tarantool.proto";
option (tarantool.lua_package) = "myapp.proto.sample";
message Foo { int32 x = 1; }
]]

local OTHER_PROTO = [[
syntax = "proto3";
package other;
import "tarantool/tarantool.proto";
import "sample.proto";
option (tarantool.lua_package) = "myapp.proto.other";
message Bar { sample.Foo foo = 1; }
]]

local function run_plugin(mode)
    local tmp = fio.tempdir()
    local proto_dir = fio.pathjoin(tmp, 'proto')
    local out_dir = fio.pathjoin(tmp, 'out')
    assert(fio.mkdir(proto_dir))
    assert(fio.mkdir(out_dir))
    spit(fio.pathjoin(proto_dir, 'sample.proto'), SAMPLE_PROTO)
    spit(fio.pathjoin(proto_dir, 'other.proto'), OTHER_PROTO)

    local cmd = string.format(
        'protoc --plugin=%q --tarantool_out=%q --tarantool_opt=mode=%s '
        ..'-I %q -I %q %q %q',
        PLUGIN, out_dir, mode, proto_dir, OPTIONS_DIR,
        fio.pathjoin(proto_dir, 'sample.proto'),
        fio.pathjoin(proto_dir, 'other.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'plugin failed: ' .. cmd)
    return out_dir
end

g.before_all(function()
    ensure_plugin()
end)

for _, mode in ipairs({'full', 'runtime'}) do
    g['test_output_path_honors_lua_package_'..mode] = function()
        local out = run_plugin(mode)
        t.assert(fio.path.exists(fio.pathjoin(out, 'myapp', 'proto', 'sample.lua')),
                 'expected sample.lua under lua_package path, got: '
                 .. table.concat(fio.glob(fio.pathjoin(out, '**', '*.lua')) or {}, ', '))
        t.assert(fio.path.exists(fio.pathjoin(out, 'myapp', 'proto', 'other.lua')),
                 'expected other.lua under lua_package path')
        -- Default `<pkg>/<file>_pb.lua` layout must NOT be present —
        -- that's the regression signature (extension dropped, fallback used).
        t.assert_not(fio.path.exists(fio.pathjoin(out, 'sample', 'sample_pb.lua')),
                     'fallback path was emitted — lua_package option was ignored')
    end

    g['test_cross_file_require_honors_lua_package_'..mode] = function()
        local out = run_plugin(mode)
        local body = slurp(fio.pathjoin(out, 'myapp', 'proto', 'other.lua'))
        t.assert_str_contains(body, 'require("myapp.proto.sample")', false,
            'cross-file import should resolve via lua_package, not the default path')
        t.assert_not(string.find(body, 'require("sample.sample_pb")', 1, true),
                     'default require path leaked into cross-file import')
    end
end
