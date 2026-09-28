-- Verifies that leading `//` comments in a .proto file propagate into
-- the generated _pb.lua module as LuaLS-friendly `---` doc lines and
-- as plain `--` lines inside table literals where LuaLS attachment
-- doesn't apply.
--
-- Strategy mirrors test/doc_test.lua: write a small fixture proto into a
-- tempdir, invoke the plugin via protoc, then grep the output. We run
-- the plugin in both `full` and `runtime` modes — the doc emission is
-- mode-independent, but covering both prevents a regression that wires
-- comments into only one path.

local t = require('luatest')
local fio = require('fio')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local PLUGIN = fio.pathjoin(REPO_ROOT, 'protoc-gen-tarantool')

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

local function ensure_plugin()
    if fio.path.exists(PLUGIN) then return end
    local cmd = string.format('cd %q && go build -o %s ./cmd/protoc-gen-tarantool',
                              REPO_ROOT, fio.basename(PLUGIN))
    assert(os.execute(cmd) == 0 or os.execute(cmd) == true,
           'failed to build plugin: ' .. cmd)
end

-- A purpose-built proto exercising every comment-bearing surface:
-- enum, enum value, message, field, oneof field, repeated field,
-- map field, service, RPC method (unary + streaming flavors).
local FIXTURE_PROTO = [[
syntax = "proto3";

package docs;

// Status describes the outcome of an operation.
// Multi-line description for hover docs.
enum Status {
  // Sentinel zero value.
  UNKNOWN = 0;
  // Operation succeeded normally.
  OK = 1;
  // Operation failed; see Result.code for detail.
  ERROR = 2;
}

// Result is the outcome envelope returned from every RPC.
message Result {
  // Unique identifier for this result row.
  int32 id = 1;
  // Effective status of the operation.
  Status status = 2;
  // Either a human-readable text or a numeric code, never both.
  oneof outcome {
    // Free-form success text.
    string text = 3;
    // Machine-readable error code.
    int32 code = 4;
  }
  // Labels collected during processing.
  repeated string labels = 5;
  // Per-key counters captured by the handler.
  map<string, int32> counters = 6;
}

message Probe {
  string id = 1;
}

// Pinger drives a single liveness probe and an open-ended stream.
service Pinger {
  // Ping issues a single round-trip probe.
  rpc Ping(Probe) returns (Result);
  // Watch streams results until the client cancels.
  rpc Watch(Probe) returns (stream Result);
}
]]

local function generate(mode, prefix)
    local tmp = fio.tempdir()
    local proto_dir = fio.pathjoin(tmp, 'proto')
    local out_dir = fio.pathjoin(tmp, 'out')
    assert(fio.mkdir(proto_dir))
    assert(fio.mkdir(out_dir))
    spit(fio.pathjoin(proto_dir, 'comments.proto'), FIXTURE_PROTO)

    local cmd = string.format(
        'protoc --plugin=%q --tarantool_out=%q --tarantool_opt=%s -I %q -I %q %q',
        PLUGIN, out_dir,
        string.format('mode=%s,prefix=%s', mode, prefix),
        proto_dir, OPTIONS_DIR,
        fio.pathjoin(proto_dir, 'comments.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'plugin failed: ' .. cmd)

    return slurp(fio.pathjoin(out_dir, prefix, 'docs', 'comments_pb.lua'))
end

ensure_plugin()
local LUA_FULL = generate('full', 'full')
local LUA_RUNTIME = generate('runtime', 'runtime')

-- Each modes-parameterized group runs the same assertions against both
-- modes, matching the pattern used elsewhere in the suite.
local function make_group(name, lua)
    local g = t.group('codegen_doc_comments.' .. name)

    g.test_message_leading_comment = function()
        -- The message description should appear as a `---` block
        -- immediately above its `---@class` declaration so LuaLS picks
        -- it up as the type's hover docstring.
        t.assert_str_contains(lua,
            '--- Result is the outcome envelope returned from every RPC.\n'
            .. '---@class docs.Result')
    end

    g.test_enum_leading_comment_multiline = function()
        -- Multi-line proto comments should produce one `--- line` per
        -- source line, preserving the user's wording in order.
        t.assert_str_contains(lua,
            '--- Status describes the outcome of an operation.\n'
            .. '--- Multi-line description for hover docs.\n'
            .. '---@alias docs.Status')
    end

    g.test_field_trailing_description = function()
        -- Field comments collapse to a single trailing `@ description`
        -- on the `---@field` line so LuaLS shows them on hover/complete.
        t.assert_str_contains(lua,
            '---@field id integer @ Unique identifier for this result row.')
        t.assert_str_contains(lua,
            '---@field status docs.Status @ Effective status of the operation.')
        t.assert_str_contains(lua,
            '---@field labels string[] @ Labels collected during processing.')
        t.assert_str_contains(lua,
            '---@field counters table<string, integer> '
            .. '@ Per-key counters captured by the handler.')
    end

    g.test_oneof_field_descriptions = function()
        -- Oneof branches are marked optional and should still carry the
        -- per-field description.
        t.assert_str_contains(lua,
            '---@field text? string @ Free-form success text.')
        t.assert_str_contains(lua,
            '---@field code? integer @ Machine-readable error code.')
    end

    g.test_enum_value_inline_comment = function()
        -- Inside the `pb.enum(...)` table, value comments survive as
        -- regular Lua comments — they're not LSP-attachable but readers
        -- of the generated module should still see them.
        t.assert_str_contains(lua,
            '    -- Sentinel zero value.\n'
            .. '    UNKNOWN = 0,')
        t.assert_str_contains(lua,
            '    -- Operation succeeded normally.\n'
            .. '    OK = 1,')
        t.assert_str_contains(lua,
            '    -- Operation failed; see Result.code for detail.\n'
            .. '    ERROR = 2,')
    end

    g.test_service_leading_comment = function()
        -- Service-level comment lands as a `---` block above the
        -- `-- Service:` banner so LuaLS can attach it to the descriptor.
        t.assert_str_contains(lua,
            '--- Pinger drives a single liveness probe and an open-ended stream.\n'
            .. '-- Service: docs.Pinger\n'
            .. 'M.Pinger_service')
    end

    g.test_method_descriptor_comment = function()
        -- Each method entry inside `methods = { ... }` gets its leading
        -- comment indented to match the table position.
        t.assert_str_contains(lua,
            '        -- Ping issues a single round-trip probe.\n'
            .. '        Ping = {')
        t.assert_str_contains(lua,
            '        -- Watch streams results until the client cancels.\n'
            .. '        Watch = {')
    end

    g.test_method_client_function_comment = function()
        -- Client functions also carry the per-method comment so users
        -- reading the client stubs see the proto context inline.
        t.assert_str_contains(lua,
            '        -- Ping issues a single round-trip probe.\n'
            .. '        Ping = function(req, ctx)')
        t.assert_str_contains(lua,
            '        -- Watch streams results until the client cancels.\n'
            .. '        Watch = function(req, ctx)')
    end

    g.test_method_server_handler_comment = function()
        -- Server handlers get the same treatment — the unary handler is
        -- in `methods`, streaming handlers are in `streams`.
        t.assert_str_contains(lua,
            '            -- Ping issues a single round-trip probe.\n'
            .. '            ["/docs.Pinger/Ping"]')
        t.assert_str_contains(lua,
            '            -- Watch streams results until the client cancels.\n'
            .. '            ["/docs.Pinger/Watch"]')
    end

    g.test_no_comment_means_no_doc_line = function()
        -- The `Probe` message has no leading comment. Make sure we
        -- haven't started inventing one — its class declaration should
        -- be preceded only by a blank line, not a stray `---`.
        t.assert_str_contains(lua, '\n---@class docs.Probe\n')
        -- And the single field has no description suffix.
        t.assert_str_contains(lua, '\n---@field id string\n')
    end
end

make_group('full', LUA_FULL)
make_group('runtime', LUA_RUNTIME)
