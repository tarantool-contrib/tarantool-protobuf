-- google.api.http annotations carried into service descriptors.
--
-- examples/proto/library.proto annotates its methods with the shapes
-- google/api/http.proto documents. The plugin flattens each method's
-- rule (primary first, then additional_bindings) into
-- `M.Library_service.methods.<Method>.http`; pb.from_pb must produce the
-- same field from a FileDescriptorSet of the same file.

local t   = require('luatest')
local fio = require('fio')
local pb  = require('pb')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local PROTO_DIR   = fio.pathjoin(REPO_ROOT, 'examples', 'proto')
local OPTIONS_DIR = fio.pathjoin(REPO_ROOT, 'options')

-- Written out from library.proto by hand, not copied from generated code.
local EXPECTED = {
    GetBook = {
        {method = 'GET', pattern = '/v1/{name=shelves/*/books/*}'},
    },
    ListBooks = {
        {method = 'GET', pattern = '/v1/{parent=shelves/*}/books'},
    },
    CreateBook = {
        {method = 'POST', pattern = '/v1/{parent=shelves/*}/books', body = 'book'},
    },
    UpdateBook = {
        {method = 'PATCH', pattern = '/v1/{book.name=shelves/*/books/*}', body = 'book'},
        {method = 'PUT', pattern = '/v1/{book.name=shelves/*/books/*}', body = '*'},
    },
    DeleteBook = {
        {method = 'DELETE', pattern = '/v1/{name=shelves/*/books/*}'},
    },
    LookupBook = {
        {method = 'POST', pattern = '/v1/books:lookup', body = '*', response_body = 'book'},
        {method = 'GET', pattern = '/v1/books:lookup', response_body = 'book'},
    },
    MoveBook = {
        {method = 'POST', pattern = '/v1/shelves/{book.shelf}/books/{book.name}:move', body = '*'},
    },
    GetMessage = {
        {method = 'GET', pattern = '/v1/messages/{message_id}'},
        {method = 'GET', pattern = '/v1/users/{user_id}/messages/{message_id}'},
        {method = 'GET', pattern = '/v1/messages/{message_id}/revisions/{revision}'},
    },
    GetFile = {
        {method = 'GET', pattern = '/v1/{path=files/**}'},
    },
    CheckBook = {
        {method = 'HEAD', pattern = '/v1/{name=shelves/*/books/*}'},
    },
}

local ANNOTATED = {
    'GetBook', 'ListBooks', 'CreateBook', 'UpdateBook', 'DeleteBook',
    'LookupBook', 'MoveBook', 'GetMessage', 'GetFile', 'CheckBook',
}

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

-- FileDescriptorSet for library.proto, straight from mainline protoc.
local function library_set()
    local out = fio.pathjoin(fio.tempdir(), 'library.descpb')
    local cmd = string.format(
        'protoc --descriptor_set_out=%q -I %q -I %q %q',
        out, PROTO_DIR, OPTIONS_DIR, fio.pathjoin(PROTO_DIR, 'library.proto'))
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, 'protoc --descriptor_set_out failed: ' .. cmd)
    return pb.from_pb(slurp(out))
end

for _, mode in ipairs({'full', 'runtime'}) do
    local lib = require(mode .. '.library.library_pb')
    local g = t.group('http_rules.' .. mode)

    g.test_every_annotated_method_has_its_rules = function()
        local methods = lib.Library_service.methods
        local n = 0
        for _, name in ipairs(ANNOTATED) do
            t.assert_equals(methods[name].http, EXPECTED[name], name)
            n = n + 1
        end
        t.assert_equals(n, 10)
    end

    -- `methods` is keyed by name; method_order keeps the source order.
    g.test_method_order_is_declaration_order = function()
        t.assert_equals(lib.Library_service.method_order, {
            'GetBook', 'ListBooks', 'CreateBook', 'UpdateBook', 'DeleteBook',
            'LookupBook', 'MoveBook', 'GetMessage', 'GetFile', 'CheckBook', 'WatchShelf',
        })
        t.assert_equals(library_set().files['library.proto'].Library_service.method_order,
                        lib.Library_service.method_order)
    end

    g.test_unannotated_method_has_no_http = function()
        local m = lib.Library_service.methods.WatchShelf
        t.assert_type(m, 'table')
        t.assert_equals(m.http, nil)
        t.assert_equals(m.options, nil)
    end

    -- The raw extension stays in `options`, in descriptor shape, next to
    -- the normalised `http` view.
    g.test_raw_extension_stays_in_options = function()
        local m = lib.Library_service.methods.UpdateBook
        local raw = m.options['google.api.http']
        t.assert_equals(raw.patch, '/v1/{book.name=shelves/*/books/*}')
        t.assert_equals(raw.body, 'book')
        t.assert_equals(raw.additional_bindings[1].put,
                        '/v1/{book.name=shelves/*/books/*}')
    end

    -- pb.from_pb over protoc's FileDescriptorSet yields the same tables.
    g.test_from_pb_parity = function()
        local set = library_set()
        local dyn = set.files['library.proto']
        t.assert_type(dyn, 'table')
        local svc = dyn.Library_service
        t.assert_type(svc, 'table')
        t.assert_equals(svc.name, lib.Library_service.name)
        t.assert_equals(svc.full_name, lib.Library_service.full_name)
        local n = 0
        for name, m in pairs(lib.Library_service.methods) do
            local d = svc.methods[name]
            t.assert_type(d, 'table', name)
            t.assert_equals(d.http, m.http, name)
            t.assert_equals(d.full_name, m.full_name, name)
            t.assert_equals(d.client_streaming, m.client_streaming, name)
            t.assert_equals(d.server_streaming, m.server_streaming, name)
            t.assert_equals(d.input.name, m.input.name, name)
            t.assert_equals(d.output.name, m.output.name, name)
            n = n + 1
        end
        t.assert_equals(n, 11)
    end
end

-- ---------------------------------------------------------------------------
-- HttpRule.pattern is a oneof: with two members on the wire, the last one
-- wins (protoc and every conforming parser agree).
-- ---------------------------------------------------------------------------

local wire = pb.wire

local function spit_bytes(path, content)
    local f = assert(io.open(path, 'wb'))
    f:write(content)
    f:close()
end

local function len_field(id, payload)
    return wire.encode_varint(id * 8 + 2) .. wire.encode_varint(#payload) .. payload
end

-- HttpRule{post: "/post"} followed by HttpRule{get: "/get"} on one wire.
local RULE = len_field(4, '/post') .. len_field(2, '/get')

local u = t.group('http_rules.oneof')

u.test_protoc_reads_last_member = function()
    local dir = fio.tempdir()
    local bin = fio.pathjoin(dir, 'rule.bin')
    local txt = fio.pathjoin(dir, 'rule.txt')
    spit_bytes(bin, RULE)
    local cmd = string.format(
        'protoc --decode=google.api.HttpRule -I %q google/api/http.proto < %q > %q',
        OPTIONS_DIR, bin, txt)
    local ok = os.execute(cmd)
    t.assert(ok == 0 or ok == true, cmd)
    local text = slurp(txt)
    t.assert_str_contains(text, 'get: "/get"')
    t.assert_not_str_contains(text, 'post')
end

u.test_from_pb_reads_last_member = function()
    local method_options = len_field(72295728, RULE)
    local method = len_field(1, 'M') .. len_field(2, '.o.Req')
        .. len_field(3, '.o.Req') .. len_field(4, method_options)
    local service = len_field(1, 'S') .. len_field(2, method)
    local file = len_field(1, 'o.proto') .. len_field(2, 'o')
        .. len_field(4, len_field(1, 'Req')) .. len_field(6, service)
        .. len_field(12, 'proto3')
    local set = pb.from_pb(len_field(1, file))
    local m = set.files['o.proto'].S_service.methods.M
    t.assert_equals(m.http, {{method = 'GET', pattern = '/get'}})
end
