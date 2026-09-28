-- Smoke test for protoc-gen-tarantool-doc.
--
-- Builds the doc plugin (if not already built), runs it against
-- examples/proto/hello.proto, and asserts the expected Markdown sections
-- and entries appear in the output.
local t = require('luatest')
local fio = require('fio')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local PROTO_DIR = fio.pathjoin(REPO_ROOT, 'examples', 'proto')
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')
local PLUGIN = fio.pathjoin(REPO_ROOT, 'protoc-gen-tarantool-doc')

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

local function ensure_plugin()
    if fio.path.exists(PLUGIN) then return end
    local cmd = string.format('cd %q && go build -o %s ./cmd/protoc-gen-tarantool-doc',
                              REPO_ROOT, fio.basename(PLUGIN))
    assert(os.execute(cmd) == 0 or os.execute(cmd) == true,
           'failed to build doc plugin: ' .. cmd)
end

local OUT_DIR = fio.tempdir()
local OUT_FILE = fio.pathjoin(OUT_DIR, 'hello.md')

do
    ensure_plugin()
    local cmd = string.format(
        'protoc --plugin=%q --tarantool-doc_out=%q -I %q -I %q %q',
        PLUGIN, OUT_DIR, PROTO_DIR, OPTIONS_DIR,
        fio.pathjoin(PROTO_DIR, 'hello.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'doc plugin failed: ' .. cmd)
end

local g = t.group('doc')

g.test_header = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '# hello.proto')
    t.assert_str_contains(md, '**Package:** `hello`')
end

g.test_imports_listed = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '**Imports:**')
    t.assert_str_contains(md, '`google/protobuf/timestamp.proto`')
end

g.test_message_section = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '## Messages')
    t.assert_str_contains(md, '### `hello.Person`')
    t.assert_str_contains(md, '### `hello.Address`')
end

g.test_field_table = function()
    local md = slurp(OUT_FILE)
    -- Header row.
    t.assert_str_contains(md, '| # | Field | Type | Label | Description |')
    -- A scalar field.
    t.assert_str_contains(md, '| 1 | `name` | `string` |')
    -- An enum reference.
    t.assert_str_contains(md, '`hello.Status`')
    -- A WKT reference.
    t.assert_str_contains(md, '`google.protobuf.Timestamp`')
end

g.test_optional_label = function()
    local md = slurp(OUT_FILE)
    -- apartment is explicit-optional.
    t.assert_str_contains(md, '| 4 | `apartment` | `string` | optional |')
end

g.test_repeated_label = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '`lucky_numbers` | `int32` | repeated |')
end

g.test_oneof_label = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, 'oneof `outcome`')
end

g.test_map_field_type = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '`map<string, int32>`')
    t.assert_str_contains(md, '`map<string, hello.Address>`')
end

g.test_no_map_entry_message = function()
    -- Synthetic map entry messages must not appear as their own section.
    local md = slurp(OUT_FILE)
    t.assert_equals(md:find('AgesByNicknameEntry'), nil)
end

g.test_enum_table = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '## Enums')
    t.assert_str_contains(md, '### `hello.Status`')
    t.assert_str_contains(md, '| 0 | `UNKNOWN`')
    t.assert_str_contains(md, '| 2 | `ERROR`')
end

g.test_service_table = function()
    local md = slurp(OUT_FILE)
    t.assert_str_contains(md, '## Services')
    t.assert_str_contains(md, '### `hello.Greeter`')
    t.assert_str_contains(md, '| `SayHello` | `hello.HelloRequest` | `hello.HelloReply` | unary |')
    t.assert_str_contains(md, '| `Chat` | `hello.HelloRequest` | `hello.HelloReply` | bidi |')
    t.assert_str_contains(md, '| `StreamHellos` | `hello.HelloRequest` | `hello.HelloReply` | server |')
    t.assert_str_contains(md, '| `CollectHellos` | `hello.HelloRequest` | `hello.HelloReply` | client |')
end

g.test_leading_comment_preserved = function()
    local md = slurp(OUT_FILE)
    -- The leading comment on `apartment` should appear in the table row.
    t.assert_str_contains(md, 'Explicit-optional: presence is meaningful')
end
