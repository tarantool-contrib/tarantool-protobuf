-- Regression test for descriptor-option preservation.
--
-- protoc-gen-tarantool used to discard everything in *Options messages.
-- The plugin now walks every populated standard field and extension and
-- surfaces them on the generated descriptor as a plain Lua table named
-- `options`, keyed by proto field name for standard options and by
-- fully-qualified extension name (in bracket-string form) for
-- extensions. Empty options remain absent (the `options` key is not
-- emitted at all), so option-free protos produce byte-identical output
-- to before.
--
-- Coverage:
--   * Message-level options (extension `(opttest_msg_tags)`, repeated).
--   * Field-level options (standard `deprecated`, scalar extensions).
--   * Method-level options (standard `deprecated`, scalar extension,
--     message-valued extension recursing into a oneof + repeated
--     nested-message sub-field — the shape google.api.http uses, the
--     primary real-world consumer of this feature).
--   * Service-level options are exercised on the side too.
--   * Determinism: standard fields sort alphabetically before
--     extensions (which sort alphabetically by full name) — the encoded
--     extension keys land in a predictable order regardless of how
--     protoc ranges them internally.

local t = require('luatest')
local fio = require('fio')

local g = t.group('codegen_options')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local PLUGIN = fio.pathjoin(REPO_ROOT, 'protoc-gen-tarantool')

local PROTO_BODY = [[
syntax = "proto3";
package opttest;
import "google/protobuf/descriptor.proto";

// Message-typed extension mirroring google.api.HttpRule's shape — a
// `pattern` oneof, a `body` scalar, and a repeated self-reference for
// additional bindings. Exercises the recursive option emitter on
// nested-message + oneof + repeated-of-message in one shot, without
// pulling in googleapis.
message HttpRule {
    oneof pattern {
        string get = 1;
        string post = 2;
    }
    string body = 3;
    repeated HttpRule additional_bindings = 4;
}

extend google.protobuf.FieldOptions {
    string opttest_field_doc = 50000;
    bool opttest_field_secret = 50001;
}
extend google.protobuf.MessageOptions {
    repeated string opttest_msg_tags = 50002;
}
extend google.protobuf.ServiceOptions {
    string opttest_svc_owner = 50005;
}
extend google.protobuf.MethodOptions {
    int32 opttest_timeout_ms = 50003;
    HttpRule opttest_http = 50004;
}

message Req {
    option (opttest_msg_tags) = "alpha";
    option (opttest_msg_tags) = "beta";

    string id = 1 [
        (opttest_field_doc) = "primary id",
        (opttest_field_secret) = true,
        deprecated = true
    ];
    string note = 2;
}
message Resp { string out = 1; }

service Demo {
    option (opttest_svc_owner) = "platform";

    rpc Plain(Req) returns (Resp);
    rpc Annotated(Req) returns (Resp) {
        option deprecated = true;
        option (opttest_timeout_ms) = 5000;
        option (opttest_http) = {
            post: "/v1/demo"
            body: "*"
            additional_bindings { post: "/v2/demo" body: "*" }
        };
    }
}
]]

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

local function run_plugin(mode)
    local tmp = fio.tempdir()
    local proto_dir = fio.pathjoin(tmp, 'proto')
    local out_dir = fio.pathjoin(tmp, 'out')
    assert(fio.mkdir(proto_dir))
    assert(fio.mkdir(out_dir))
    spit(fio.pathjoin(proto_dir, 'opttest.proto'), PROTO_BODY)
    local cmd = string.format(
        'protoc --plugin=%q --tarantool_out=%q '
        ..'--tarantool_opt=mode=%s,prefix=opt_%s '
        ..'-I %q -I %q %q',
        PLUGIN, out_dir, mode, mode, proto_dir, OPTIONS_DIR,
        fio.pathjoin(proto_dir, 'opttest.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'plugin failed: ' .. cmd)
    return out_dir, ('opt_%s.opttest.opttest_pb'):format(mode)
end

local function load_module(out, modname)
    package.path = fio.pathjoin(out, '?.lua') .. ';'
                .. fio.pathjoin(out, '?/init.lua') .. ';' .. package.path
    package.loaded[modname] = nil
    return require(modname)
end

g.before_all(function()
    ensure_plugin()
end)

for _, mode in ipairs({'full', 'runtime'}) do
    g['test_message_options_'..mode] = function()
        local out, modname = run_plugin(mode)
        local mod = load_module(out, modname)

        local opts = mod.Req_descriptor.options
        t.assert_type(opts, 'table',
            'Req should carry options from (opttest_msg_tags)')
        local tags = opts['opttest.opttest_msg_tags']
        t.assert_equals(tags, {'alpha', 'beta'},
            'repeated extension preserves declaration order')

        -- Option-free message must NOT carry an options key — keeps
        -- generated output byte-identical for the common case.
        t.assert_equals(mod.Resp_descriptor.options, nil,
            'Resp has no options; the key must be absent')
    end

    g['test_field_options_'..mode] = function()
        local out, modname = run_plugin(mode)
        local mod = load_module(out, modname)

        -- Field id 1 carries deprecated + two custom extensions; field 2 has nothing.
        local id_field = mod.Req_descriptor.field_by_name.id
        local note_field = mod.Req_descriptor.field_by_name.note

        t.assert_type(id_field.options, 'table',
            'id field should carry options')
        t.assert_equals(id_field.options.deprecated, true,
            'standard option `deprecated` surfaces as bare key')
        t.assert_equals(id_field.options['opttest.opttest_field_doc'], 'primary id',
            'string extension preserved verbatim')
        t.assert_equals(id_field.options['opttest.opttest_field_secret'], true,
            'bool extension preserved')

        t.assert_equals(note_field.options, nil,
            'note has no options; the key must be absent')
    end

    g['test_method_options_'..mode] = function()
        local out, modname = run_plugin(mode)
        local mod = load_module(out, modname)

        -- Plain has no options block; Annotated carries three.
        t.assert_equals(mod.Demo_service.methods.Plain.options, nil,
            'Plain has no method options')

        local annotated = mod.Demo_service.methods.Annotated
        t.assert_type(annotated.options, 'table',
            'Annotated should carry method options')
        t.assert_equals(annotated.options.deprecated, true)
        t.assert_equals(annotated.options['opttest.opttest_timeout_ms'], 5000)

        local http = annotated.options['opttest.opttest_http']
        t.assert_type(http, 'table',
            'message-typed extension recurses into a nested Lua table')
        t.assert_equals(http.post, '/v1/demo',
            'oneof branch surfaces as a normal key (last-set wins)')
        t.assert_equals(http.body, '*')
        t.assert_type(http.additional_bindings, 'table')
        t.assert_equals(#http.additional_bindings, 1,
            'repeated nested-message extension yields a Lua array')
        t.assert_equals(http.additional_bindings[1].post, '/v2/demo')
        t.assert_equals(http.additional_bindings[1].body, '*')
    end

    g['test_service_options_'..mode] = function()
        local out, modname = run_plugin(mode)
        local mod = load_module(out, modname)

        t.assert_type(mod.Demo_service.options, 'table')
        t.assert_equals(mod.Demo_service.options['opttest.opttest_svc_owner'],
                        'platform')
    end

    g['test_deterministic_key_order_'..mode] = function()
        -- The walker sorts standard fields alphabetically then extensions
        -- alphabetically by full name. Re-run the plugin twice and assert
        -- the raw file bytes match — independent of protoc's internal
        -- field-range order.
        local out1 = run_plugin(mode)
        local out2 = run_plugin(mode)
        local function slurp(path)
            local f = assert(io.open(path, 'rb'))
            local s = f:read('*a')
            f:close()
            return s
        end
        local rel = fio.pathjoin(('opt_%s'):format(mode),
                                 'opttest', 'opttest_pb.lua')
        t.assert_equals(slurp(fio.pathjoin(out1, rel)),
                        slurp(fio.pathjoin(out2, rel)),
                        'codegen output must be byte-identical across runs')
    end
end
