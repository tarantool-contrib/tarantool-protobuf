-- Regression test for Lua-keyword proto field names.
--
-- protoc-gen-tarantool used to emit bare-identifier table keys and
-- `t.<field>` / `result.<field>` accesses for every field. When a field
-- name happened to be a Lua reserved word (the in-the-wild hit is
-- pprof's `repeated Function function = 5`) the generated `*_pb.lua`
-- failed to load with `'(' expected near '<keyword>'`.
--
-- Coverage: emit a .proto where every Lua keyword is used as a field
-- name, run the plugin in both codegen modes, and assert:
--   * The generated module loads without error.
--   * Each `M.<Type>_fields[<keyword>]` resolves to the same name string
--     (covers the field_names table emit site).
--   * Encoding `{[<keyword>] = ...}` and decoding the bytes round-trips
--     (covers the inline-encoder `v = t.<name>` and inline-decoder
--     `result.<name> =` sites).

local t = require('luatest')
local fio = require('fio')

local g = t.group('codegen_lua_keywords')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local PLUGIN = fio.pathjoin(REPO_ROOT, 'protoc-gen-tarantool')

local LUA_KEYWORDS = {
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
    'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or',
    'repeat', 'return', 'then', 'true', 'until', 'while',
}

local function spit(path, content)
    local f = assert(io.open(path, 'wb'))
    f:write(content)
    f:close()
end

local function ensure_plugin()
    if fio.path.exists(PLUGIN) then return end
    local cmd = string.format('cd %q && go build -o %s ./cmd/protoc-gen-tarantool',
                              REPO_ROOT, fio.basename(PLUGIN))
    assert(os.execute(cmd) == 0 or os.execute(cmd) == true,
           'failed to build plugin: ' .. cmd)
end

-- Build a .proto whose every field name is a Lua keyword.
local function build_proto()
    local lines = {
        'syntax = "proto3";',
        'package keywords_test;',
        'message Inner { int32 x = 1; }',
        'message Outer {',
    }
    -- Field id 1: nested message named `function` (the pprof shape).
    table.insert(lines, '  Inner function = 1;')
    -- Subsequent ids: int32 scalars named after every other Lua keyword.
    local id = 2
    for _, kw in ipairs(LUA_KEYWORDS) do
        if kw ~= 'function' then
            table.insert(lines, string.format('  int32 %s = %d;', kw, id))
            id = id + 1
        end
    end
    table.insert(lines, '}')
    return table.concat(lines, '\n') .. '\n'
end

local function run_plugin(mode)
    local tmp = fio.tempdir()
    local proto_dir = fio.pathjoin(tmp, 'proto')
    local out_dir = fio.pathjoin(tmp, 'out')
    assert(fio.mkdir(proto_dir))
    assert(fio.mkdir(out_dir))
    spit(fio.pathjoin(proto_dir, 'kw.proto'), build_proto())

    local cmd = string.format(
        'protoc --plugin=%q --tarantool_out=%q '
        ..'--tarantool_opt=mode=%s,prefix=kw_%s '
        ..'-I %q -I %q %q',
        PLUGIN, out_dir, mode, mode, proto_dir, OPTIONS_DIR,
        fio.pathjoin(proto_dir, 'kw.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'plugin failed: ' .. cmd)
    return out_dir, ('kw_%s.keywords_test.kw_pb'):format(mode)
end

g.before_all(function()
    ensure_plugin()
end)

for _, mode in ipairs({'full', 'runtime'}) do
    g['test_module_loads_with_keyword_fields_'..mode] = function()
        local out, modname = run_plugin(mode)
        local prev = package.path
        package.path = fio.pathjoin(out, '?.lua') .. ';'
                    .. fio.pathjoin(out, '?/init.lua') .. ';' .. prev
        package.loaded[modname] = nil
        local ok, mod = pcall(require, modname)
        package.path = prev
        t.assert(ok, 'module failed to load: ' .. tostring(mod))
        t.assert_type(mod.Outer_encode, 'function')
        t.assert_type(mod.Outer_decode, 'function')
        t.assert_type(mod.Outer_fields, 'table')
    end

    g['test_field_names_table_carries_keyword_keys_'..mode] = function()
        local out, modname = run_plugin(mode)
        local prev = package.path
        package.path = fio.pathjoin(out, '?.lua') .. ';'
                    .. fio.pathjoin(out, '?/init.lua') .. ';' .. prev
        package.loaded[modname] = nil
        local mod = require(modname)
        package.path = prev
        for _, kw in ipairs(LUA_KEYWORDS) do
            t.assert_equals(mod.Outer_fields[kw], kw,
                'M.Outer_fields["' .. kw .. '"] must round-trip the keyword')
        end
    end

    g['test_round_trip_keyword_fields_'..mode] = function()
        local out, modname = run_plugin(mode)
        local prev = package.path
        package.path = fio.pathjoin(out, '?.lua') .. ';'
                    .. fio.pathjoin(out, '?/init.lua') .. ';' .. prev
        package.loaded[modname] = nil
        local mod = require(modname)
        package.path = prev

        -- Populate every keyword-named field.
        local input = { [ 'function' ] = { x = 42 } }
        local n = 1
        for _, kw in ipairs(LUA_KEYWORDS) do
            if kw ~= 'function' then
                input[kw] = n
                n = n + 1
            end
        end

        local bytes = mod.Outer_encode(input)
        local decoded = mod.Outer_decode(bytes)
        t.assert_equals(decoded['function'].x, 42)
        for k, v in pairs(input) do
            if k ~= 'function' then
                t.assert_equals(decoded[k], v,
                    'round-trip failed for keyword field "' .. k .. '"')
            end
        end
    end
end
