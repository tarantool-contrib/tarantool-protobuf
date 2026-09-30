-- gRPC status codes and status objects (pb.grpc.code, pb.grpc.error, ...)
-- and their propagation through the in-process transports.
--
-- Transport tests are parameterized over both codegen modes: the
-- generated server wrappers differ between full and runtime mode only in
-- their encode/decode call sites, but a status must cross both.

local t     = require('luatest')
local pb    = require('pb')

local grpc = pb.grpc

-- A detail payload: any message packed into google.protobuf.Any.
local REPLY_DESC = require('full.hello.hello_pb').HelloReply_descriptor
local function detail(text)
    return pb.any.pack(REPLY_DESC, {greeting = text})
end

-- ---------------------------------------------------------------------------
-- Codes, names, HTTP mapping
-- ---------------------------------------------------------------------------

local u = t.group('grpc_status')

-- The canonical table from the gRPC spec, with the HTTP status the
-- Google API / grpc-gateway mapping assigns.
local CANONICAL = {
    {'OK',                  0,  200},
    {'CANCELLED',           1,  499},
    {'UNKNOWN',             2,  500},
    {'INVALID_ARGUMENT',    3,  400},
    {'DEADLINE_EXCEEDED',   4,  504},
    {'NOT_FOUND',           5,  404},
    {'ALREADY_EXISTS',      6,  409},
    {'PERMISSION_DENIED',   7,  403},
    {'RESOURCE_EXHAUSTED',  8,  429},
    {'FAILED_PRECONDITION', 9,  400},
    {'ABORTED',             10, 409},
    {'OUT_OF_RANGE',        11, 400},
    {'UNIMPLEMENTED',       12, 501},
    {'INTERNAL',            13, 500},
    {'UNAVAILABLE',         14, 503},
    {'DATA_LOSS',           15, 500},
    {'UNAUTHENTICATED',     16, 401},
}

u.test_codes_names_and_http_status = function()
    local n = 0
    for _, row in ipairs(CANONICAL) do
        local name, num, http = row[1], row[2], row[3]
        t.assert_equals(grpc.code[name], num, name)
        t.assert_equals(grpc.code_name[num], name, name)
        t.assert_equals(grpc.http_status[num], http, name)
        n = n + 1
    end
    t.assert_equals(n, 17)
    local count = 0
    for _ in pairs(grpc.code) do count = count + 1 end
    t.assert_equals(count, 17, 'no codes beyond the canonical 17')
end

u.test_status_object = function()
    local st = grpc.status(grpc.code.NOT_FOUND, 'book 42')
    t.assert(grpc.is_status(st))
    t.assert_equals(st.code, 5)
    t.assert_equals(st.message, 'book 42')
    t.assert_equals(st.details, nil)
    t.assert_equals(tostring(st), 'NOT_FOUND: book 42')
end

u.test_status_accepts_code_name = function()
    local st = grpc.status('PERMISSION_DENIED', 'nope')
    t.assert_equals(st.code, 7)
    t.assert_equals(tostring(grpc.status('INTERNAL')), 'INTERNAL')
end

u.test_status_non_canonical_code = function()
    local st = grpc.status(42, 'custom')
    t.assert_equals(st.code, 42)
    t.assert_equals(tostring(st), 'CODE_42: custom')
end

u.test_status_rejects_bad_codes = function()
    t.assert_error_msg_contains('unknown status code name "NOPE"',
        grpc.status, 'NOPE')
    t.assert_error_msg_contains('code must be', grpc.status, -1)
    t.assert_error_msg_contains('code must be', grpc.status, 1.5)
    t.assert_error_msg_contains('code must be', grpc.status, nil)
    t.assert_error_msg_contains('details must be', grpc.status, 3, 'x', 'bad')
end

u.test_is_status_rejects_lookalikes = function()
    t.assert_not(grpc.is_status({code = 5, message = 'x'}))
    t.assert_not(grpc.is_status('NOT_FOUND: x'))
    t.assert_not(grpc.is_status(nil))
end

u.test_error_raises_status = function()
    local details = {detail('why')}
    local ok, err = pcall(grpc.error, grpc.code.ABORTED, 'retry', details)
    t.assert_not(ok)
    t.assert(grpc.is_status(err))
    t.assert_equals(err.code, grpc.code.ABORTED)
    t.assert_equals(err.message, 'retry')
    t.assert_is(err.details, details)
end

u.test_encode_status_bytes = function()
    -- google.rpc.Status{code: 5, message: "x"}: tag 1 varint, tag 2 LEN.
    local st = grpc.status(5, 'x')
    t.assert_equals(grpc.encode_status(st), '\x08\x05\x12\x01x')
end

u.test_status_round_trip_with_details = function()
    local any = detail('why')
    local st = grpc.status(grpc.code.FAILED_PRECONDITION, 'stale', {any})
    local back = grpc.decode_status(grpc.encode_status(st))
    t.assert(grpc.is_status(back))
    t.assert_equals(back.code, st.code)
    t.assert_equals(back.message, 'stale')
    t.assert_equals(#back.details, 1)
    t.assert_equals(back.details[1].type_url, any.type_url)
    t.assert_equals(back.details[1].value, any.value)
    local unpacked = pb.any.unpack(back.details[1], REPLY_DESC)
    t.assert_equals(unpacked.greeting, 'why')
end

u.test_decode_status_without_details = function()
    local back = grpc.decode_status(grpc.encode_status(grpc.status(0)))
    t.assert_equals(back.code, 0)
    t.assert_equals(back.message, '')
    t.assert_equals(back.details, nil)
end

-- ---------------------------------------------------------------------------
-- Propagation through loopback / multiplex
-- ---------------------------------------------------------------------------

local function check_same_status(got, want)
    t.assert(grpc.is_status(got), 'expected a status object, got ' .. tostring(got))
    t.assert_equals(got.code, want.code)
    t.assert_equals(got.message, want.message)
    t.assert_equals(got.details, want.details)
end

for _, mode in ipairs({'full', 'runtime'}) do
    local hello = require(mode .. '.hello.hello_pb')
    local g = t.group('grpc_status.' .. mode)

    local details = {detail('d')}
    local WANT = grpc.status(grpc.code.NOT_FOUND, 'book 42', details)

    local function raise_want()
        grpc.error(WANT.code, WANT.message, WANT.details)
    end

    local impl = {
        SayHello = function() raise_want() end,
        StreamHellos = function(_, stream)
            stream:send({greeting = 'first'})
            raise_want()
        end,
        CollectHellos = function(stream)
            stream:recv()
            raise_want()
        end,
        Chat = function(stream)
            local req = stream:recv()
            stream:send({greeting = req.name})
            raise_want()
        end,
    }

    local transports = {
        loopback = function() return grpc.loopback(hello.Greeter_server(impl)) end,
        multiplex = function() return grpc.multiplex({hello.Greeter_server(impl)}) end,
    }

    for tname, make in pairs(transports) do
        g['test_unary_status_' .. tname] = function()
            local client = hello.Greeter_client(make())
            local ok, err = pcall(client.SayHello, {name = 'x'}, {})
            t.assert_not(ok)
            check_same_status(err, WANT)
        end

        g['test_server_stream_status_' .. tname] = function()
            local client = hello.Greeter_client(make())
            local stream = client.StreamHellos({name = 'x'}, {})
            t.assert_equals(stream:recv().greeting, 'first')
            local r, err = stream:recv()
            t.assert_equals(r, nil)
            check_same_status(err, WANT)
        end

        g['test_client_stream_status_' .. tname] = function()
            local client = hello.Greeter_client(make())
            local call = client.CollectHellos({})
            call:send({name = 'a'})
            call:close_send()
            local r, err = call:recv()
            t.assert_equals(r, nil)
            check_same_status(err, WANT)
        end

        g['test_bidi_status_' .. tname] = function()
            local client = hello.Greeter_client(make())
            local call = client.Chat({})
            call:send({name = 'ping'})
            t.assert_equals(call:recv().greeting, 'ping')
            local r, err = call:recv()
            t.assert_equals(r, nil)
            check_same_status(err, WANT)
        end
    end

    -- Plain errors keep their pre-status behaviour on the in-process
    -- transports: verbatim for unary, stringified for streams.
    g.test_unary_plain_error_is_verbatim = function()
        local sentinel = {'not a status'}
        local client = hello.Greeter_client(grpc.loopback(hello.Greeter_server({
            SayHello = function() error(sentinel) end,
        })))
        local ok, err = pcall(client.SayHello, {name = 'x'}, {})
        t.assert_not(ok)
        t.assert_is(err, sentinel)
    end

    g.test_stream_plain_error_is_a_string = function()
        local client = hello.Greeter_client(grpc.loopback(hello.Greeter_server({
            StreamHellos = function() error('plain boom', 0) end,
        })))
        local r, err = client.StreamHellos({name = 'x'}, {}):recv()
        t.assert_equals(r, nil)
        t.assert_equals(err, 'plain boom')
    end

    g.test_missing_handler_is_unimplemented = function()
        local client = hello.Greeter_client(grpc.loopback(hello.Greeter_server({})))
        local ok, err = pcall(client.SayHello, {name = 'x'}, {})
        t.assert_not(ok)
        t.assert(grpc.is_status(err))
        t.assert_equals(err.code, grpc.code.UNIMPLEMENTED)
        t.assert_equals(err.message, 'Greeter.SayHello: handler missing')

        local r, serr = client.StreamHellos({name = 'x'}, {}):recv()
        t.assert_equals(r, nil)
        t.assert(grpc.is_status(serr))
        t.assert_equals(serr.code, grpc.code.UNIMPLEMENTED)
    end

    g.test_unknown_method_is_unimplemented = function()
        local transport = grpc.loopback(hello.Greeter_server({}))
        local ok, err = pcall(transport.unary, transport, '/hello.Greeter/Nope', '', {})
        t.assert_not(ok)
        t.assert(grpc.is_status(err))
        t.assert_equals(err.code, grpc.code.UNIMPLEMENTED)
        t.assert_str_contains(err.message, 'unknown unary method')

        ok, err = pcall(transport.bidi, transport, '/hello.Greeter/Nope', {})
        t.assert_not(ok)
        t.assert(grpc.is_status(err))
        t.assert_equals(err.code, grpc.code.UNIMPLEMENTED)
    end
end
