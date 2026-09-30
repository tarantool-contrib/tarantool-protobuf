-- pb.connect: the Connect protocol over request/response tables, no
-- network. The live path (pb.server over HTTP/1.1) is in
-- server_test.lua; independent clients (buf curl, connect-go through
-- the connectrpc conformance suite) are in test/server-go and
-- test/connect-conformance.

local t      = require('luatest')
local fiber  = require('fiber')
local json   = require('json')
local digest = require('digest')
local pb     = require('pb')

local grpc    = pb.grpc
local connect = pb.connect

-- envelopes(body) -> array of {flags, payload}; fails on a torn tail.
local function envelopes(body)
    local out, pos = {}, 1
    while pos <= #body do
        t.assert(#body - pos + 1 >= 5, 'torn envelope prefix')
        local flags, b1, b2, b3, b4 = body:byte(pos, pos + 4)
        local len = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        t.assert(#body - pos + 1 - 5 >= len, 'torn envelope payload')
        out[#out + 1] = {flags, body:sub(pos + 5, pos + 4 + len)}
        pos = pos + 5 + len
    end
    return out
end

-- end_stream(body) -> the messages and the decoded EndStreamResponse,
-- asserting the end-stream flag is on the last envelope only.
local function end_stream(body)
    local list = envelopes(body)
    t.assert(#list >= 1, 'no envelopes')
    local msgs = {}
    for i, e in ipairs(list) do
        if i < #list then
            t.assert_equals(e[1], 0, 'flags of message ' .. i)
            msgs[#msgs + 1] = e[2]
        else
            t.assert_equals(e[1], 2, 'flags of the last envelope')
        end
    end
    return msgs, json.decode(list[#list][2])
end

local E = connect.envelope

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

local u = t.group('connect.unit')

-- The table from the protocol's "Error Codes" section, written out here
-- rather than read from the module under test.
local SPEC = {
    {1, 'canceled', 499}, {2, 'unknown', 500}, {3, 'invalid_argument', 400},
    {4, 'deadline_exceeded', 504}, {5, 'not_found', 404}, {6, 'already_exists', 409},
    {7, 'permission_denied', 403}, {8, 'resource_exhausted', 429},
    {9, 'failed_precondition', 400}, {10, 'aborted', 409}, {11, 'out_of_range', 400},
    {12, 'unimplemented', 501}, {13, 'internal', 500}, {14, 'unavailable', 503},
    {15, 'data_loss', 500}, {16, 'unauthenticated', 401},
}

u.test_code_table = function()
    for _, row in ipairs(SPEC) do
        t.assert_equals(connect.code_name[row[1]], row[2], row[2])
        t.assert_equals(connect.http_status[row[1]], row[3], row[2])
    end
end

u.test_error_json = function()
    local st = grpc.status(grpc.code.NOT_FOUND, 'no such book',
        {{type_url = 'type.googleapis.com/google.rpc.RetryInfo', value = '\10\2\8\60'}})
    t.assert_equals(json.decode(connect.error_json(st)), {
        code = 'not_found', message = 'no such book',
        details = {{type = 'google.rpc.RetryInfo', value = 'CgIIPA'}},
    })
    -- An empty message and no details are omitted.
    t.assert_equals(json.decode(connect.error_json(grpc.status('UNAVAILABLE'))),
                    {code = 'unavailable'})
    -- A code Connect has no name for.
    t.assert_equals(json.decode(connect.error_json(grpc.status(42, 'x'))),
                    {code = 'unknown', message = 'x'})
end

u.test_parse_timeout = function()
    t.assert_equals(connect.parse_timeout(nil), nil)
    t.assert_equals(connect.parse_timeout('0'), 0)
    t.assert_equals(connect.parse_timeout('5000'), 5000)
    t.assert_equals(connect.parse_timeout('9999999999'), 9999999999)
    for _, bad in ipairs({'', '12345678901', '-1', '1.5', 'abc', ' 5', '5ms'}) do
        t.assert_equals(connect.parse_timeout(bad), false, bad)
    end
end

u.test_envelope = function()
    t.assert_equals(E(0, 'abc'), '\0\0\0\0\3abc')
    t.assert_equals(E(2, ''), '\2\0\0\0\0')
    t.assert_equals(#E(0, ('x'):rep(70000)), 70005)
    t.assert_equals(E(0, ('x'):rep(70000)):sub(1, 5), '\0\0\1\17\112')
end

u.test_buffered_io_read = function()
    local io = connect.buffered_io(E(0, 'a') .. E(1, 'bc') .. E(0, ''))
    t.assert_equals({io:read()}, {0, 'a'})
    t.assert_equals({io:read()}, {1, 'bc'})
    t.assert_equals({io:read()}, {0, ''})
    t.assert_equals({io:read()}, {})
    local flags, err = connect.buffered_io('\0\0\0'):read()
    t.assert_equals(flags, false)
    t.assert_str_contains(err.message, 'incomplete envelope')
    flags, err = connect.buffered_io('\0\0\0\0\9abc'):read()
    t.assert_equals(flags, false)
    t.assert_str_contains(err.message, 'promised 9 bytes')
    flags, err = connect.buffered_io(E(0, 'abcd')):read(3)
    t.assert_equals({flags, err.code}, {false, grpc.code.RESOURCE_EXHAUSTED})
end

-- fake_st(items) -> an object with tarantool-http2's streaming exchange
-- surface. `items` are what successive reads return: a string is a
-- chunk, {err = ...} a failure, and past the end the body has ended.
local function fake_st(items)
    local st = {items = items, pos = 1, out = {}, reads = 0, timeouts = {}}
    function st:read(timeout)
        self.reads = self.reads + 1
        self.timeouts[#self.timeouts + 1] = timeout
        local item = self.items[self.pos]
        self.pos = self.pos + 1
        if item == nil then return nil end
        if type(item) == 'table' then
            if item.err == 'timeout' then fiber.sleep(math.min(timeout, 0.01)) end
            return nil, item.err
        end
        return item
    end
    function st:write_head(status, headers) self.head = {status, headers} return true end
    function st:write(data) self.out[#self.out + 1] = data return true end
    function st:finish() self.finished = true return true end
    function st:is_cancelled() return self.cancelled == true end
    return st
end

u.test_stream_io_read = function()
    -- Envelopes split across chunks at every place, and two in one chunk.
    local body = E(0, 'hello') .. E(1, '') .. E(0, 'world')
    local st = fake_st({body:sub(1, 2), body:sub(3, 7), body:sub(8, 9), body:sub(10)})
    local io = connect.stream_io(st)
    t.assert_equals({io:read()}, {0, 'hello'})
    t.assert_equals({io:read()}, {1, ''})
    t.assert_equals({io:read()}, {0, 'world'})
    t.assert_equals({io:read()}, {})
    -- A body that ends inside an envelope.
    local flags, err = connect.stream_io(fake_st({E(0, 'abc'):sub(1, 6)})):read()
    t.assert_equals(flags, false)
    t.assert_str_contains(err.message, 'incomplete envelope')
    -- Too large: refused from the length prefix, the payload never read.
    st = fake_st({E(0, 'abcdef'):sub(1, 5), 'abcdef'})
    flags, err = connect.stream_io(st):read(3)
    t.assert_equals({flags, err.code}, {false, grpc.code.RESOURCE_EXHAUSTED})
    t.assert_equals(st.reads, 1)
    -- A slice running out is not the end; the client going away is.
    st = fake_st({{err = 'timeout'}, E(0, 'x')})
    t.assert_equals({connect.stream_io(st):read()}, {0, 'x'})
    flags, err = connect.stream_io(fake_st({{err = 'cancelled'}})):read()
    t.assert_equals({flags, err}, {false, 'canceled'})
    -- The deadline bounds the wait.
    local clock = require('clock')
    st = fake_st({{err = 'timeout'}, {err = 'timeout'}, {err = 'timeout'}})
    flags, err = connect.stream_io(st):read(nil, clock.monotonic() + 0.001)
    t.assert_equals({flags, err.code}, {false, grpc.code.DEADLINE_EXCEEDED})
    t.assert_le(st.timeouts[1], 0.001)
end

u.test_stream_io_write = function()
    local st = fake_st({})
    local io = connect.stream_io(st)
    io:write_headers({['content-type'] = 'application/connect+proto'})
    t.assert_equals(io:write(0, 'a'), true)
    t.assert_equals(st.out, {E(0, 'a')}, 'written at once, not at the end')
    t.assert_equals(io:write(2, '{}'), true)
    t.assert_equals(io:finish(), nil)
    t.assert_equals(st.head, {200, {['content-type'] = 'application/connect+proto'}})
    t.assert_equals(st.out, {E(0, 'a'), E(2, '{}')})
    t.assert(st.finished)
    -- A send that arrives after the EndStreamResponse is refused.
    t.assert_equals(io:write(0, 'late'), false)
    t.assert_equals(io:write(2, '{}'), false)
    t.assert_equals(st.out, {E(0, 'a'), E(2, '{}')})
    -- The same for the buffered I/O.
    local b = connect.buffered_io('')
    t.assert_equals(b:write(0, 'a'), true)
    t.assert_equals(b:write(2, '{}'), true)
    t.assert_equals(b:write(0, 'late'), false)
    t.assert_equals(b:finish().body, E(0, 'a') .. E(2, '{}'))

    st = fake_st({})
    io = connect.stream_io(st)
    st.write = function() return nil, 'cancelled' end
    t.assert_equals(io:write(0, 'b'), false)
    st.cancelled = true
    t.assert_equals(io:is_cancelled(), true)
end

-- race_st(split) -> a fake streaming exchange whose writes yield, as a
-- real one does under backpressure. With `split`, a write puts half its
-- bytes out, yields, then the rest (a partial socket write).
local function race_st(split, request)
    local st = fake_st({request})
    st.bytes = {}
    function st:write(data)
        if split then
            local half = math.floor(#data / 2)
            self.bytes[#self.bytes + 1] = data:sub(1, half)
            fiber.sleep(0.001)
            self.bytes[#self.bytes + 1] = data:sub(half + 1)
        else
            fiber.sleep(0.001)
            self.bytes[#self.bytes + 1] = data
        end
        return true
    end
    return st
end

-- A server stream whose messages come from several fibers that keep
-- sending while the handler returns: the end of the stream races them.
local function racing_stream(split)
    local hello = require('full.hello.hello_pb')
    local h = connect.new({hello.Greeter_server({
        StreamHellos = function(_, stream)
            for f = 1, 8 do
                fiber.create(function()
                    for i = 1, 20 do
                        if not stream:send({greeting = f .. '/' .. i}) then return end
                    end
                end)
            end
            fiber.sleep(0.003)
        end,
    })})
    local head = {method = 'POST', path = '/hello.Greeter/StreamHellos', version = 'HTTP/2',
                  headers = {['content-type'] = 'application/connect+proto'}}
    local st = race_st(split, E(0, hello.HelloRequest_encode({name = 'x'})))
    h:stream_handler(head)(head, st)
    fiber.sleep(0.2) -- let the senders run out
    return st, hello
end

-- Nothing is written after the EndStreamResponse, however the sends
-- and the end of the stream interleave.
u.test_stream_end_is_last = function()
    local st = racing_stream(false)
    local list = envelopes(table.concat(st.bytes))
    local ends = 0
    for i, e in ipairs(list) do
        if e[1] == 2 then
            ends = ends + 1
            t.assert_equals(i, #list, 'the end-stream envelope is the last one')
        end
    end
    t.assert_equals(ends, 1)
    t.assert_gt(#list, 1, 'some messages went out before the end')
end

u.test_end_stream_json = function()
    t.assert_equals(connect.end_stream_json(nil, nil), '{}')
    t.assert_equals(connect.end_stream_json(nil, {}), '{}')
    local got = json.decode(connect.end_stream_json(grpc.status('ABORTED', 'stop'), {
        ['x-a'] = {'1', '2'}, ['x-b-bin'] = '\255\0', ['connect-x'] = 'reserved',
        ['Bad Key'] = 'v', ['x-ctl'] = 'a\nb', ['trailer-t'] = 'kept',
    }))
    t.assert_equals(got, {
        error = {code = 'aborted', message = 'stop'},
        metadata = {['x-a'] = {'1', '2'}, ['x-b-bin'] = {'/wA'}, ['trailer-t'] = {'kept'}},
    })
end

u.test_request_metadata = function()
    local md = connect.request_metadata({
        ['content-type'] = 'application/proto', ['connect-timeout-ms'] = '5',
        ['connect-protocol-version'] = '1', host = 'h', ['x-a'] = 'v',
        ['x-p-bin'] = digest.base64_encode('\1\2\3'),       -- padded
        ['x-u-bin'] = 'AQID',                                -- unpadded
        ['x-r-bin'] = 'AQ, Ag==',                            -- repeated
        ['user-agent'] = 'ua',
    })
    t.assert_equals(md, {['x-a'] = 'v', ['x-p-bin'] = '\1\2\3', ['x-u-bin'] = '\1\2\3',
                         ['x-r-bin'] = '\1, \2', ['user-agent'] = 'ua'})
    local bad, err = connect.request_metadata({['x-bin'] = '!!!'})
    t.assert_equals(bad, nil)
    t.assert_equals(err.code, grpc.code.INVALID_ARGUMENT)
end

u.test_parse_query = function()
    t.assert_equals(connect.parse_query('a=1&b=x+y&a=%2F&c'),
                    {a = {'1', '/'}, b = {'x y'}, c = {''}})
    t.assert_equals(connect.parse_query(''), {})
    t.assert_equals(connect.parse_query('a=%zz'), nil)
end

u.test_decode_base64 = function()
    local d = connect._decode_base64
    t.assert_equals(d('__79_A'), '\255\254\253\252')
    t.assert_equals(d('//79/A=='), '\255\254\253\252')
    t.assert_equals(d('//79/A'), '\255\254\253\252')
    t.assert_equals(d('A'), nil)
    t.assert_equals(d('AB=C'), nil)
    t.assert_equals(d('AB='), nil)
    t.assert_equals(d('A$'), nil)
end

u.test_new_options = function()
    t.assert_error_msg_contains('servers must be an array', connect.new, 1)
    t.assert_error_msg_contains('unknown option "x"', connect.new, {}, {x = 1})
    t.assert_error_msg_contains('opts.json.indent must be a string', connect.new, {},
                                {json = {indent = 1}})
    t.assert_error_msg_contains('servers[1] is not a generated server table',
                                connect.new, {{}})
end

-- ---------------------------------------------------------------------------
-- Calls, per codegen mode
-- ---------------------------------------------------------------------------

for _, mode in ipairs({'full', 'runtime'}) do
    local hello = require(mode .. '.hello.hello_pb')
    local lib = require(mode .. '.library.library_pb')
    local g = t.group('connect.' .. mode)

    local seen = {}
    local detail = pb.any.pack(hello.HelloReply_descriptor, {greeting = 'why'})

    local greeter = hello.Greeter_server({
        SayHello = function(r, ctx)
            seen.ctx = ctx
            r.name = r.name or ''
            ctx.response_metadata['x-head'] = 'h'
            ctx.trailing_metadata['x-tail'] = {'t1', 't2'}
            -- `trailer-` is reserved in response headers only.
            ctx.response_metadata['trailer-sneaky'] = 'no'
            ctx.trailing_metadata['trailer-foo'] = 'tf'
            if r.name == 'missing' then
                grpc.error(grpc.code.NOT_FOUND, 'no ' .. r.name, {detail})
            elseif r.name == 'boom' then
                error('secret text')
            elseif r.name == 'ok-status' then
                grpc.error(grpc.code.OK, 'not an error')
            elseif r.name:match('^sleep') then
                local deadline = fiber.clock() + 1
                while fiber.clock() < deadline and not ctx:is_cancelled() do
                    fiber.sleep(0.005)
                end
                seen.cancelled = ctx:is_cancelled()
            end
            return {greeting = r.name == '' and '' or 'Hi ' .. r.name}
        end,
        StreamHellos = function(r, stream, ctx)
            ctx.response_metadata['x-head'] = 'h'
            ctx.trailing_metadata['x-tail'] = 't'
            ctx.trailing_metadata['trailer-foo'] = 'tf'
            ctx.trailing_metadata['connect-x'] = 'reserved'
            for i = 1, 2 do stream:send({greeting = ('%d %s'):format(i, r.name)}) end
            if r.name == 'fail' then grpc.error('ABORTED', 'after two') end
        end,
        CollectHellos = function(stream)
            local names = {}
            while true do
                local r, err = stream:recv()
                if r == nil then
                    if err ~= nil then error(err, 0) end
                    break
                end
                names[#names + 1] = r.name or ''
            end
            return {greeting = table.concat(names, ',')}
        end,
        Chat = function(stream)
            while true do
                local r, err = stream:recv()
                if r == nil then
                    if err ~= nil then error(err, 0) end
                    return
                end
                stream:send({greeting = 'Echo ' .. r.name})
            end
        end,
    })
    local library = lib.Library_server({
        GetBook = function(r, ctx)
            seen.ctx = ctx
            return {name = r.name, title = 'T'}
        end,
        ListBooks = function() return {} end,
    })
    local h = connect.new({greeter, library})

    local function post(path, ct, body, headers)
        local hdrs = {['content-type'] = ct}
        for k, v in pairs(headers or {}) do hdrs[k] = v end
        return h:handle({method = 'POST', path = path, headers = hdrs, body = body,
                         peer = '127.0.0.1:1'})
    end
    local function get(path)
        return h:handle({method = 'GET', path = path, headers = {}, body = ''})
    end
    local req = function(name) return hello.HelloRequest_encode({name = name}) end

    g.test_unary_json = function()
        local r = post('/hello.Greeter/SayHello', 'application/json; charset=utf-8',
                       '{"name": "Dave", "unknownField": 1}')
        t.assert_equals(r.status, 200, r.body)
        t.assert_equals(r.headers['content-type'], 'application/json')
        t.assert_equals(json.decode(r.body), {greeting = 'Hi Dave'})
        t.assert_equals(r.headers['x-head'], 'h')
        t.assert_equals(r.headers['trailer-x-tail'], {'t1', 't2'})
        t.assert_equals(r.headers['trailer-trailer-foo'], 'tf')
        t.assert_equals(r.headers['trailer-sneaky'], nil)
        -- Defaults are omitted, as protojson does by default.
        r = post('/hello.Greeter/SayHello', 'application/json', '')
        t.assert_equals({r.status, r.body}, {200, '{}'})
    end

    g.test_unary_proto = function()
        local r = post('/hello.Greeter/SayHello', 'application/proto', req('Eve'),
                       {['connect-protocol-version'] = '1', ['x-id'] = '7'})
        t.assert_equals(r.status, 200, r.body)
        t.assert_equals(r.headers['content-type'], 'application/proto')
        t.assert_equals(hello.HelloReply_decode(r.body).greeting, 'Hi Eve')
        local ctx = seen.ctx
        t.assert_equals(ctx.protocol, 'connect')
        t.assert_equals(ctx.method, '/hello.Greeter/SayHello')
        t.assert_equals(ctx.peer, '127.0.0.1:1')
        t.assert_equals(ctx.metadata, {['x-id'] = '7'})
        t.assert_equals(ctx.deadline, nil)
        t.assert_equals(ctx.connect, {get = false, codec = 'proto'})
        t.assert_equals(ctx:is_cancelled(), false)
        -- A zero-length body is an empty message.
        r = post('/hello.Greeter/SayHello', 'application/proto', '')
        t.assert_equals({r.status, r.body}, {200, ''})
    end

    g.test_unary_error = function()
        local r = post('/hello.Greeter/SayHello', 'application/proto', req('missing'))
        t.assert_equals(r.status, 404)
        t.assert_equals(r.headers['content-type'], 'application/json')
        t.assert_equals(r.headers['x-head'], 'h')
        t.assert_equals(r.headers['trailer-x-tail'], {'t1', 't2'})
        t.assert_equals(r.headers['trailer-trailer-foo'], 'tf')
        t.assert_equals(r.headers['trailer-sneaky'], nil)
        local body = json.decode(r.body)
        t.assert_equals(body.code, 'not_found')
        t.assert_equals(body.message, 'no missing')
        t.assert_equals(body.details[1].type, 'hello.HelloReply')
        t.assert_equals(hello.HelloReply_decode(digest.base64_decode(body.details[1].value)),
                        {greeting = 'why'})
        t.assert_not_str_contains(body.details[1].value, '=')
    end

    g.test_unary_internal = function()
        for _, name in ipairs({'boom', 'ok-status'}) do
            local r = post('/hello.Greeter/SayHello', 'application/json',
                           json.encode({name = name}))
            t.assert_equals(r.status, 500, name)
            t.assert_equals(json.decode(r.body), {code = 'internal', message = 'internal error'})
        end
    end

    g.test_unary_protocol_errors = function()
        local cases = {
            {{['content-encoding'] = 'gzip'}, 501, 'unimplemented', 'supported encodings are identity'},
            {{['content-encoding'] = 'identity'}, 200},
            {{['connect-protocol-version'] = '2'}, 400, 'invalid_argument', 'protocol version'},
            {{['connect-timeout-ms'] = '12345678901'}, 400, 'invalid_argument', 'connect-timeout-ms'},
            {{['x-bin'] = '*'}, 400, 'invalid_argument', 'binary metadata'},
        }
        for i, c in ipairs(cases) do
            local r = post('/hello.Greeter/SayHello', 'application/proto', req('x'), c[1])
            t.assert_equals(r.status, c[2], 'case ' .. i)
            if c[3] ~= nil then
                local body = json.decode(r.body)
                t.assert_equals(body.code, c[3], 'case ' .. i)
                t.assert_str_contains(body.message, c[4])
            end
        end
        local r = post('/hello.Greeter/SayHello', 'application/json', '{"name": 5')
        t.assert_equals(r.status, 400)
        t.assert_equals(json.decode(r.body).code, 'invalid_argument')
    end

    g.test_unary_message_limit = function()
        local small = connect.new({greeter}, {max_recv_message_size = 10})
        local r = small:handle({method = 'POST', path = '/hello.Greeter/SayHello',
                                headers = {['content-type'] = 'application/proto'},
                                body = req(('x'):rep(9))})
        t.assert_equals(r.status, 429)
        t.assert_equals(json.decode(r.body).code, 'resource_exhausted')
        r = small:handle({method = 'POST', path = '/hello.Greeter/SayHello',
                          headers = {['content-type'] = 'application/proto'},
                          body = req(('x'):rep(8))})
        t.assert_equals(r.status, 200)
    end

    g.test_unary_deadline = function()
        seen.cancelled = nil
        local t0 = fiber.clock()
        local r = post('/hello.Greeter/SayHello', 'application/json', '{"name": "sleep"}',
                       {['connect-timeout-ms'] = '50'})
        t.assert_lt(fiber.clock() - t0, 0.5)
        t.assert_equals(r.status, 504)
        t.assert_equals(json.decode(r.body).code, 'deadline_exceeded')
        -- The handler runs on, sees the cancellation and stops.
        t.helpers.retrying({timeout = 2}, function() t.assert_equals(seen.cancelled, true) end)
        -- A deadline that is not hit.
        r = post('/hello.Greeter/SayHello', 'application/json', '{"name": "Al"}',
                 {['connect-timeout-ms'] = '5000'})
        t.assert_equals(r.status, 200)
        -- ctx.deadline counts on the monotonic clock (fiber.clock() lags
        -- it by up to one event-loop iteration).
        local left = seen.ctx.deadline - require('clock').monotonic()
        t.assert(left > 4 and left <= 5, left)
    end

    g.test_get = function()
        local msg = '%7B%22name%22%3A%22shelves%2F1%2Fbooks%2F2%22%7D'
        local r = get('/library.Library/GetBook?encoding=json&message=' .. msg .. '&extra=1')
        t.assert_equals(r.status, 200, r.body)
        t.assert_equals(r.headers['content-type'], 'application/json')
        t.assert_equals(json.decode(r.body), {name = 'shelves/1/books/2', title = 'T'})
        t.assert_equals(seen.ctx.connect.get, true)
        t.assert_equals(seen.ctx.connect.query.extra, {'1'})
        -- Parameters in any order; binary message in URL-safe base64.
        local bin = lib.GetBookRequest_encode({name = 'shelves/9/books/???'})
        local b64 = digest.base64_encode(bin, {urlsafe = true, nopad = true, nowrap = true})
        t.assert_str_contains(b64, '_')
        r = get('/library.Library/GetBook?message=' .. b64 .. '&connect=v1&base64=1&encoding=proto')
        t.assert_equals(r.status, 200, r.body)
        t.assert_equals(lib.Book_decode(r.body).name, 'shelves/9/books/???')
        -- No message: an empty request.
        r = get('/library.Library/GetBook?encoding=json')
        t.assert_equals({r.status, r.body}, {200, '{"title":"T"}'})
    end

    g.test_get_errors = function()
        local r = get('/library.Library/GetBook?encoding=proto&base64=1&message=%21')
        t.assert_equals(r.status, 400)
        t.assert_equals(json.decode(r.body).code, 'invalid_argument')
        r = get('/library.Library/GetBook?encoding=proto&compression=gzip&message=')
        t.assert_equals(r.status, 501)
        t.assert_equals(json.decode(r.body).code, 'unimplemented')
        r = get('/library.Library/GetBook?encoding=proto&connect=v2')
        t.assert_equals(r.status, 400)
        r = get('/library.Library/GetBook?encoding=yaml')
        t.assert_equals(r.status, 415)
        -- Not a Connect GET: no encoding, or a method with side effects.
        t.assert_equals(get('/library.Library/GetBook?message=x'), nil)
        t.assert_equals(get('/library.Library/ListBooks?encoding=json'), nil)
        t.assert_equals(get('/hello.Greeter/SayHello?encoding=json'), nil)
    end

    g.test_match = function()
        local function m(method, path, ct, headers)
            local hdrs = {['content-type'] = ct}
            for k, v in pairs(headers or {}) do hdrs[k] = v end
            return h:match({method = method, path = path, headers = hdrs})
        end
        local c = m('POST', '/hello.Greeter/SayHello', 'application/proto')
        t.assert_equals({c.mode, c.codec.name, c.strong}, {'unary', 'proto', true})
        c = m('POST', '/hello.Greeter/SayHello', 'Application/JSON; charset=utf-8')
        t.assert_equals({c.mode, c.codec.name, c.strong}, {'unary', 'json', false})
        c = m('POST', '/hello.Greeter/SayHello', 'application/json',
              {['connect-protocol-version'] = '1'})
        t.assert_equals(c.strong, true)
        c = m('POST', '/hello.Greeter/Chat', 'application/connect+json')
        t.assert_equals({c.mode, c.codec.name, c.strong}, {'stream', 'json', true})
        -- Neither servable nor unambiguously Connect: not matched.
        t.assert_equals(m('POST', '/hello.Greeter/SayHello', 'application/foo'), nil)
        t.assert_equals(m('POST', '/hello.Greeter/SayHello', nil), nil)
        t.assert_equals(m('DELETE', '/hello.Greeter/SayHello', 'application/json'), nil)
        t.assert_equals(m('POST', '/hello.Greeter/Nope', 'application/proto'), nil)
        -- Unambiguously Connect but not servable: matched, with the
        -- protocol's rejection.
        local function rejected(want, ...)
            local call = m(...)
            t.assert_not_equals(call, nil, want)
            t.assert_equals({call.strong, call.reject.status}, {true, want})
        end
        rejected(415, 'POST', '/hello.Greeter/SayHello', 'application/connect+proto')
        rejected(415, 'POST', '/hello.Greeter/Chat', 'application/proto')
        rejected(415, 'POST', '/hello.Greeter/Chat', 'application/connect+yaml')
        rejected(415, 'POST', '/hello.Greeter/SayHello', 'application/yaml',
                 {['connect-protocol-version'] = '1'})
        rejected(415, 'POST', '/hello.Greeter/SayHello', nil, {['connect-protocol-version'] = '1'})
        rejected(405, 'PUT', '/hello.Greeter/SayHello', 'application/proto')
        c = h:match({method = 'GET', path = '/hello.Greeter/SayHello?connect=v1&encoding=json',
                     headers = {}})
        t.assert_equals({c.strong, c.reject.status}, {true, 405})
        c = h:match({method = 'GET', path = '/library.Library/GetBook?connect=v1', headers = {}})
        t.assert_equals({c.strong, c.reject.status}, {true, 415})
        c = h:match({method = 'GET', path = '/library.Library/GetBook?encoding=json', headers = {}})
        t.assert_equals({c.mode, c.strong}, {'get', false})
        c = h:match({method = 'GET', path = '/library.Library/GetBook?encoding=json&connect=v1',
                     headers = {}})
        t.assert_equals(c.strong, true)
    end

    g.test_reject = function()
        local function rj(method, path, ct)
            return h:reject({method = method, path = path, headers = {['content-type'] = ct}})
        end
        local r = rj('POST', '/hello.Greeter/SayHello', 'image/jpeg')
        t.assert_equals({r.status, r.body}, {415, ''})
        t.assert_equals(r.headers['accept-post'], 'application/proto, application/json')
        r = rj('POST', '/hello.Greeter/Chat', 'application/proto')
        t.assert_equals(r.status, 415)
        t.assert_equals(r.headers['accept-post'], 'application/connect+proto, application/connect+json')
        r = rj('DELETE', '/hello.Greeter/SayHello')
        t.assert_equals({r.status, r.headers.allow}, {405, 'POST'})
        r = rj('GET', '/hello.Greeter/SayHello')
        t.assert_equals({r.status, r.headers.allow}, {405, 'POST'})
        r = rj('PUT', '/library.Library/GetBook')
        t.assert_equals({r.status, r.headers.allow}, {405, 'GET, POST'})
        r = rj('GET', '/library.Library/GetBook')
        t.assert_equals(r.status, 415)
        t.assert_equals(rj('POST', '/nope.Svc/M', 'application/proto'), nil)
    end

    g.test_not_found = function()
        local function nf(method, path, headers)
            return h:not_found({method = method, path = path, headers = headers or {}})
        end
        for _, c in ipairs({
            {'POST', '/x.Y/Z', {['content-type'] = 'application/proto'}},
            {'POST', '/x.Y/Z', {['content-type'] = 'application/connect+json'}},
            {'POST', '/x.Y/Z', {['content-type'] = 'application/json',
                                ['connect-protocol-version'] = '1'}},
            {'GET', '/x.Y/Z?connect=v1&encoding=json'},
        }) do
            local r = nf(c[1], c[2], c[3])
            t.assert_equals(r.status, 404, c[2])
            t.assert_equals(json.decode(r.body),
                            {code = 'unimplemented', message = 'no procedure ' .. c[1] .. ' /x.Y/Z'})
        end
        t.assert_equals(nf('POST', '/x.Y/Z', {['content-type'] = 'application/json'}), nil)
        t.assert_equals(nf('GET', '/x.Y/Z?encoding=json'), nil)
        t.assert_equals(nf('GET', '/v1/things'), nil)
    end

    g.test_server_stream = function()
        local r = post('/hello.Greeter/StreamHellos', 'application/connect+json',
                       E(0, '{"name": "Eve"}'))
        t.assert_equals(r.status, 200)
        t.assert_equals(r.headers['content-type'], 'application/connect+json')
        t.assert_equals(r.headers['x-head'], 'h')
        local msgs, tail = end_stream(r.body)
        t.assert_equals(msgs, {'{"greeting":"1 Eve"}', '{"greeting":"2 Eve"}'})
        -- In the EndStreamResponse only `connect-` keys are reserved.
        t.assert_equals(tail, {metadata = {['x-tail'] = {'t'}, ['trailer-foo'] = {'tf'}}})
        -- An error after the messages.
        r = post('/hello.Greeter/StreamHellos', 'application/connect+proto', E(0, req('fail')))
        t.assert_equals(r.status, 200)
        msgs, tail = end_stream(r.body)
        t.assert_equals(#msgs, 2)
        t.assert_equals(hello.HelloReply_decode(msgs[2]).greeting, '2 fail')
        t.assert_equals(tail, {error = {code = 'aborted', message = 'after two'},
                               metadata = {['x-tail'] = {'t'}, ['trailer-foo'] = {'tf'}}})
    end

    g.test_server_stream_request_count = function()
        for _, body in ipairs({'', E(0, req('a')) .. E(0, req('b'))}) do
            local r = post('/hello.Greeter/StreamHellos', 'application/connect+proto', body)
            t.assert_equals(r.status, 200)
            local msgs, tail = end_stream(r.body)
            t.assert_equals(msgs, {})
            t.assert_equals(tail.error.code, 'unimplemented')
        end
    end

    g.test_client_stream = function()
        local r = post('/hello.Greeter/CollectHellos', 'application/connect+proto',
                       E(0, req('a')) .. E(0, '') .. E(0, req('c')))
        t.assert_equals(r.status, 200)
        local msgs, tail = end_stream(r.body)
        t.assert_equals(#msgs, 1)
        t.assert_equals(hello.HelloReply_decode(msgs[1]).greeting, 'a,,c')
        t.assert_equals(tail, {})
        -- No request messages at all.
        r = post('/hello.Greeter/CollectHellos', 'application/connect+json', '')
        msgs, tail = end_stream(r.body)
        t.assert_equals({msgs, tail}, {{'{}'}, {}})
    end

    g.test_bidi_half_duplex = function()
        local r = post('/hello.Greeter/Chat', 'application/connect+json',
                       E(0, '{"name":"a"}') .. E(0, '{"name":"b"}'))
        local msgs, tail = end_stream(r.body)
        t.assert_equals(msgs, {'{"greeting":"Echo a"}', '{"greeting":"Echo b"}'})
        t.assert_equals(tail, {})
    end

    g.test_stream_protocol_errors = function()
        local limited = connect.new({greeter}, {max_recv_message_size = 8})
        local cases = {
            {E(0, req('a')) .. E(1, req('b')), 'internal', 'compressed'},
            {E(2, req('a')), 'invalid_argument', 'end-stream'},
            {E(0, req('a')) .. '\0\0\0', 'invalid_argument', 'incomplete envelope'},
            {'\0\0\0\0\50' .. req('a'), 'invalid_argument', 'promised 50 bytes'},
            {E(0, req(('x'):rep(20))), 'resource_exhausted', 'larger than max', limited},
        }
        for i, c in ipairs(cases) do
            local handler = c[4] or h
            local r = handler:handle({method = 'POST', path = '/hello.Greeter/CollectHellos',
                                      headers = {['content-type'] = 'application/connect+proto'},
                                      body = c[1]})
            t.assert_equals(r.status, 200, 'case ' .. i)
            local msgs, tail = end_stream(r.body)
            t.assert_equals(msgs, {}, 'case ' .. i)
            t.assert_equals(tail.error.code, c[2], 'case ' .. i)
            t.assert_str_contains(tail.error.message, c[3])
        end
        -- JSON that does not parse.
        local r = post('/hello.Greeter/Chat', 'application/connect+json', E(0, '{'))
        local _, tail = end_stream(r.body)
        t.assert_equals(tail.error.code, 'invalid_argument')
        -- Unsupported message encoding, before any handler runs.
        r = post('/hello.Greeter/Chat', 'application/connect+proto', E(0, req('a')),
                 {['connect-content-encoding'] = 'br'})
        local msgs
        msgs, tail = end_stream(r.body)
        t.assert_equals(msgs, {})
        t.assert_equals(tail.error.code, 'unimplemented')
        t.assert_str_contains(tail.error.message, 'identity')
    end

    g.test_stream_deadline = function()
        local slow = connect.new({hello.Greeter_server({
            StreamHellos = function(_, stream)
                stream:send({greeting = 'first'})
                fiber.sleep(0.3)
                seen.late_send = stream:send({greeting = 'late'})
            end,
        })})
        seen.late_send = nil
        local r = slow:handle({method = 'POST', path = '/hello.Greeter/StreamHellos',
                               headers = {['content-type'] = 'application/connect+proto',
                                          ['connect-timeout-ms'] = '50'},
                               body = E(0, req('x'))})
        local msgs, tail = end_stream(r.body)
        t.assert_equals(#msgs, 1)
        t.assert_equals(tail.error.code, 'deadline_exceeded')
        t.helpers.retrying({timeout = 2}, function() t.assert_equals(seen.late_send, false) end)
    end
end

-- ---------------------------------------------------------------------------
-- Deadlines against work that does not yield
-- ---------------------------------------------------------------------------

local d = t.group('connect.deadline')

-- A server table around one unary function, the hello messages as its
-- input and output.
local function raw_server(fn)
    local hello = require('full.hello.hello_pb')
    return {
        service = {name = 't.S', methods = {M = {
            name = 'M', full_name = '/t.S/M',
            input = hello.HelloRequest_descriptor, output = hello.HelloReply_descriptor,
        }}},
        methods = {['/t.S/M'] = fn},
    }
end

-- Burns CPU without yielding until the monotonic clock reaches `until_`.
local function spin(until_)
    local clock = require('clock')
    while clock.monotonic() < until_ do end
end

local function call(h, ms, body)
    return h:handle({method = 'POST', path = '/t.S/M',
                     headers = {['content-type'] = 'application/json',
                                ['connect-timeout-ms'] = tostring(ms)},
                     body = body or '{}'})
end

-- The handler finishes before the deadline, but encoding its 20 MiB
-- JSON response (hundreds of milliseconds, no yield) runs past it: the
-- deadline decides the call, and ctx:is_cancelled() agrees.
d.test_encoding_past_the_deadline = function()
    local hello = require('full.hello.hello_pb')
    local big = hello.HelloReply_encode({greeting = ('x'):rep(20 * 1024 * 1024)})
    local seen = {}
    local h = connect.new({raw_server(function(_, ctx)
        seen.ctx = ctx
        spin(ctx.deadline - 0.03)
        return big
    end)})
    local r = call(h, 100)
    t.assert_equals(r.status, 504)
    t.assert_equals(json.decode(r.body).code, 'deadline_exceeded')
    t.assert_equals(seen.ctx:is_cancelled(), true)
end

-- A handler that never yields cannot lose to the wait's timeout: it
-- puts its result before the wait even starts timing. The status it
-- raises after the deadline must still give way to the deadline. (A
-- successful result would also be caught by the check after encoding;
-- a raised status is decided in invoke alone.)
d.test_non_yielding_handler_past_the_deadline = function()
    local seen = {}
    local h = connect.new({raw_server(function(_, ctx)
        spin(ctx.deadline + 0.02)
        seen.cancelled = ctx:is_cancelled()
        grpc.error(grpc.code.NOT_FOUND, 'late')
    end)})
    local r = call(h, 20)
    t.assert_equals(r.status, 504)
    t.assert_equals(json.decode(r.body).code, 'deadline_exceeded')
    t.assert_equals(seen.cancelled, true, 'is_cancelled reads a fresh clock')
    -- The same handler raising before its deadline keeps its status.
    h = connect.new({raw_server(function() grpc.error(grpc.code.NOT_FOUND, 'on time') end)})
    r = call(h, 5000)
    t.assert_equals({r.status, json.decode(r.body).code}, {404, 'not_found'})
end

-- A server stream whose sends run past the deadline without yielding
-- ends with deadline_exceeded.
d.test_stream_past_the_deadline = function()
    local hello = require('full.hello.hello_pb')
    local h = connect.new({hello.Greeter_server({
        StreamHellos = function(_, stream, ctx)
            stream:send({greeting = 'first'})
            spin(ctx.deadline + 0.02)
        end,
    })})
    local r = h:handle({method = 'POST', path = '/hello.Greeter/StreamHellos',
                        headers = {['content-type'] = 'application/connect+proto',
                                   ['connect-timeout-ms'] = '20'},
                        body = E(0, hello.HelloRequest_encode({name = 'x'}))})
    local msgs, tail = end_stream(r.body)
    t.assert_equals(#msgs, 1)
    t.assert_equals(tail.error.code, 'deadline_exceeded')
end
