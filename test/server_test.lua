-- pb.server: the adapters between generated server tables and the http2
-- rock (no network), option checks, and a smoke test that starts a real
-- server when the http2 rock can be loaded.
--
-- The adapters are exercised with fake http2 streams; the end-to-end
-- behaviour against independent clients (grpc-go, grpcurl, net/http) is
-- checked by test/server-go.

local t     = require('luatest')
local fiber = require('fiber')
local json  = require('json')
local pb    = require('pb')

local grpc   = pb.grpc
local server = require('pb.server')

local HAVE_HTTP2, HTTP2_ERR = pcall(require, 'http2')
local NO_HTTP2 = 'the http2 rock is not available (set TARANTOOL_HTTP2_RUNTIME): '
    .. tostring(HTTP2_ERR)

-- fake_stream(inbound) -> an object with http2's Stream surface.
-- `inbound` items: a string is a client message, {err = ...} a recv
-- failure (e.g. 'timeout', 'cancelled'); past the end, recv reports the
-- client's half-close (nil without an error).
local function fake_stream(inbound)
    local s = {inbound = inbound or {}, pos = 1, sent = {}, timeouts = {},
               cancelled = false}
    function s:recv(timeout)
        self.timeouts[#self.timeouts + 1] = timeout
        local item = self.inbound[self.pos]
        self.pos = self.pos + 1
        if item == nil then return nil end
        if type(item) == 'table' then return nil, item.err end
        return item
    end
    function s:send(bytes)
        if self.send_err ~= nil then return nil, self.send_err end
        self.sent[#self.sent + 1] = bytes
        return true
    end
    function s:is_cancelled() return self.cancelled end
    return s
end

local function fake_ctx(method, cancelled)
    return {
        method = method,
        metadata = {},
        response_metadata = {},
        trailing_metadata = {},
        is_cancelled = function() return cancelled == true end,
    }
end

-- ---------------------------------------------------------------------------
-- Adapters, per codegen mode
-- ---------------------------------------------------------------------------

for _, mode in ipairs({'full', 'runtime'}) do
    local hello = require(mode .. '.hello.hello_pb')
    local g = t.group('server.' .. mode)

    local req = function(name) return hello.HelloRequest_encode({name = name}) end
    local reply = function(bytes) return hello.HelloReply_decode(bytes).greeting end
    local detail = pb.any.pack(hello.HelloReply_descriptor, {greeting = 'why'})

    local impl = {
        SayHello = function(r)
            if r.name == 'missing' then
                grpc.error(grpc.code.NOT_FOUND, 'no ' .. r.name, {detail})
            elseif r.name == 'plain' then
                grpc.error('ABORTED', 'plain status')
            elseif r.name == 'ok-status' then
                grpc.error(grpc.code.OK, 'not an error')
            elseif r.name == 'boom' then
                error('secret text')
            end
            return {greeting = 'Hi ' .. r.name}
        end,
        StreamHellos = function(r, stream)
            for i = 1, 3 do stream:send({greeting = r.name .. i}) end
        end,
        CollectHellos = function(stream)
            local names = {}
            while true do
                local r, err = stream:recv()
                if r == nil then
                    if err ~= nil then error(err, 0) end
                    break
                end
                names[#names + 1] = r.name
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
                if r.name == 'stop' then grpc.error(grpc.code.ABORTED, 'stopped') end
                if stream:send({greeting = 'Echo ' .. r.name}) == false then return end
            end
        end,
    }
    local srv = hello.Greeter_server(impl)
    local function unary(name)
        return server._unary_handler(srv.methods['/hello.Greeter/SayHello'])(
            fake_ctx('/hello.Greeter/SayHello'), req(name))
    end
    local function streaming(method, stream, ctx)
        local path = '/hello.Greeter/' .. method
        return server._stream_handler(srv.streams[path])(ctx or fake_ctx(path), stream)
    end

    g.test_unary_ok = function()
        local resp, code = unary('Ann')
        t.assert_equals(code, nil)
        t.assert_equals(reply(resp), 'Hi Ann')
    end

    g.test_unary_status_with_details = function()
        local resp, code, message, details_bin = unary('missing')
        t.assert_equals(resp, nil)
        t.assert_equals(code, grpc.code.NOT_FOUND)
        t.assert_equals(message, 'no missing')
        -- grpc-status-details-bin: google.rpc.Status with the same code
        -- and message, and the details.
        local st = grpc.decode_status(details_bin)
        t.assert_equals(st.code, grpc.code.NOT_FOUND)
        t.assert_equals(st.message, 'no missing')
        t.assert_equals(#st.details, 1)
        t.assert_equals(st.details[1].type_url, detail.type_url)
        t.assert_equals(reply(st.details[1].value), 'why')
    end

    g.test_unary_status_without_details = function()
        local resp, code, message, details_bin = unary('plain')
        t.assert_equals({resp, code, message, details_bin},
                        {nil, grpc.code.ABORTED, 'plain status', nil})
    end

    g.test_unary_plain_error_is_internal = function()
        local resp, code, message, details_bin = unary('boom')
        t.assert_equals({resp, code, message, details_bin},
                        {nil, grpc.code.INTERNAL, 'internal error', nil})
    end

    g.test_unary_status_ok_is_internal = function()
        local _, code, message = unary('ok-status')
        t.assert_equals({code, message}, {grpc.code.INTERNAL, 'internal error'})
    end

    g.test_server_stream = function()
        local s = fake_stream({req('n')})
        t.assert_equals({streaming('StreamHellos', s)}, {})
        t.assert_equals(#s.sent, 3)
        t.assert_equals(reply(s.sent[1]), 'n1')
        t.assert_equals(reply(s.sent[3]), 'n3')
    end

    g.test_server_stream_without_request = function()
        local _, code = streaming('StreamHellos', fake_stream({}))
        t.assert_equals(code, grpc.code.INTERNAL)
    end

    g.test_client_stream_half_close = function()
        -- A recv slice running out is not the end of the stream.
        local s = fake_stream({req('a'), {err = 'timeout'}, req('b')})
        t.assert_equals({streaming('CollectHellos', s)}, {})
        t.assert_equals(#s.sent, 1)
        t.assert_equals(reply(s.sent[1]), 'a,b')
        t.assert_equals(s.timeouts[1], server.RECV_SLICE)
    end

    g.test_bidi_status_mid_stream = function()
        local s = fake_stream({req('x'), req('stop'), req('never')})
        local _, code, message = streaming('Chat', s)
        t.assert_equals({code, message}, {grpc.code.ABORTED, 'stopped'})
        t.assert_equals(#s.sent, 1)
        t.assert_equals(reply(s.sent[1]), 'Echo x')
    end

    g.test_bidi_cancelled = function()
        -- The handler sees pb.grpc's 'canceled' and re-raises it; the
        -- call is decided already, so the result only needs to be a
        -- failure nobody reads.
        local s = fake_stream({req('x'), {err = 'cancelled'}})
        local ctx = fake_ctx('/hello.Greeter/Chat', true)
        local _, code = streaming('Chat', s, ctx)
        t.assert_equals(code, grpc.code.INTERNAL)
    end

    g.test_send_to_gone_client = function()
        local s = fake_stream({req('x')})
        s.send_err = 'cancelled'
        t.assert_equals({streaming('Chat', s)}, {})
    end

    -- The same handler failure answers the same over gRPC (the adapter)
    -- and over HTTP/JSON (the router pb.server builds): a status keeps
    -- its code, a status claiming OK is an internal error on both.
    g.test_grpc_http_status_parity = function()
        local lib = require(mode .. '.library.library_pb')
        local outcome
        local lsrv = lib.Library_server({
            GetBook = function()
                if outcome.raise then grpc.error(outcome.code, 'raised') end
                return nil
            end,
        })
        -- A hand-written handler returning nil, code instead of raising.
        local returning = {service = lsrv.service, streams = {}, methods = {
            ['/library.Library/GetBook'] = function() return nil, outcome.code, 'returned' end,
        }}
        local path = '/library.Library/GetBook'
        local breq = lib.GetBookRequest_encode({name = 'shelves/1/books/1'})
        local hreq = {method = 'GET', path = '/v1/shelves/1/books/1', headers = {}, body = ''}
        local cases = {
            {code = grpc.code.OK, want = grpc.code.INTERNAL},
            {code = grpc.code.NOT_FOUND, want = grpc.code.NOT_FOUND},
        }
        local n = 0
        for _, c in ipairs(cases) do
            for _, s in ipairs({{srv = lsrv, raise = true}, {srv = returning, raise = false}}) do
                outcome = {code = c.code, raise = s.raise}
                local label = ('code %d, %s'):format(c.code, s.raise and 'raised' or 'returned')
                local _, code = server._unary_handler(s.srv.methods[path])(fake_ctx(path), breq)
                t.assert_equals(code, c.want, 'gRPC: ' .. label)
                local resp = pb.transcode.new({s.srv}):handle(hreq)
                t.assert_equals(resp.status, grpc.http_status[c.want], 'HTTP: ' .. label)
                t.assert_equals(json.decode(resp.body).code, c.want, 'HTTP body: ' .. label)
                n = n + 1
            end
        end
        t.assert_equals(n, 4)
    end

    g.test_send_too_large = function()
        local s = fake_stream({req('x')})
        s.send_err = 'message too large'
        local _, code = streaming('Chat', s)
        t.assert_equals(code, grpc.code.RESOURCE_EXHAUSTED)
    end
end

-- ---------------------------------------------------------------------------
-- The server view alone
-- ---------------------------------------------------------------------------

local v = t.group('server.view')

v.test_recv_errors = function()
    local view = server._stream_view(fake_stream({
        'm', {err = 'cancelled'}, {err = 'call closed'}, {err = 'deadline exceeded'},
    }))
    t.assert_equals({view:recv()}, {'m', nil})
    t.assert_equals({view:recv()}, {nil, 'canceled'})
    t.assert_equals({view:recv()}, {nil, 'canceled'})
    local b, err = view:recv()
    t.assert_equals(b, nil)
    t.assert(grpc.is_status(err))
    t.assert_equals(err.code, grpc.code.DEADLINE_EXCEEDED)
    t.assert_equals({view:recv()}, {nil, nil}, 'half-close')
end

v.test_is_cancelled = function()
    local s = fake_stream()
    local view = server._stream_view(s)
    t.assert_equals(view:is_cancelled(), false)
    s.cancelled = true
    t.assert_equals(view:is_cancelled(), true)
end

-- ---------------------------------------------------------------------------
-- HTTP handler
-- ---------------------------------------------------------------------------

local h = t.group('server.http')

local function library_server()
    local lib = require('full.library.library_pb')
    return lib.Library_server({
        GetBook = function(r)
            if r.name == 'shelves/1/books/1' then return {name = r.name} end
            grpc.error(grpc.code.NOT_FOUND, 'no book ' .. r.name)
        end,
    })
end

local function get(handler, path)
    return handler({method = 'GET', path = path, headers = {}, body = ''})
end

h.test_router_fallback_404 = function()
    local fallback = function(req)
        if req.path == '/fallback' then return {status = 201, body = 'f'} end
    end
    local handler = server._http_handler(pb.transcode.new({library_server()}), fallback)
    local resp = get(handler, '/v1/shelves/1/books/1')
    t.assert_equals(resp.status, 200)
    t.assert_equals(json.decode(resp.body).name, 'shelves/1/books/1')
    t.assert_equals(get(handler, '/fallback').status, 201)
    resp = get(handler, '/nope?x=1')
    t.assert_equals(resp.status, 404)
    t.assert_equals(resp.headers['content-type'], 'application/json')
    t.assert_equals(json.decode(resp.body),
                    {code = 5, message = 'no route for GET /nope', details = {}})
    -- No transcoding: still the google.rpc.Status shape.
    resp = get(server._http_handler(nil, nil), '/')
    t.assert_equals(resp.status, 404)
    t.assert_equals(json.decode(resp.body),
                    {code = 5, message = 'no route for GET /', details = {}})
end

-- The unrouted 404 and a routed 404 (a status raised by the handler)
-- render under the same JSON options, whatever they are.
h.test_404_follows_router_json_options = function()
    local function keys(body)
        local out = {}
        for k in pairs(json.decode(body)) do out[#out + 1] = k end
        table.sort(out)
        return out
    end
    local cases = {
        {opts = nil, want = {'code', 'details', 'message'}},
        {opts = {json = {emit_defaults = false, emit_null_messages = false}},
         want = {'code', 'message'}},
    }
    for i, c in ipairs(cases) do
        local handler = server._http_handler(pb.transcode.new({library_server()}, c.opts), nil)
        local routed = get(handler, '/v1/shelves/1/books/9')
        local unrouted = get(handler, '/nope')
        t.assert_equals({routed.status, unrouted.status}, {404, 404}, 'case ' .. i)
        t.assert_equals(keys(routed.body), c.want, 'routed, case ' .. i)
        t.assert_equals(keys(unrouted.body), c.want, 'unrouted, case ' .. i)
    end
end

-- ---------------------------------------------------------------------------
-- new(): options and services
-- ---------------------------------------------------------------------------

local n = t.group('server.new')

local hello = require('full.hello.hello_pb')
local function greeter() return hello.Greeter_server({}) end

n.test_duplicate_method = function()
    -- Checked before the http2 rock is loaded, so it holds without it.
    t.assert_error_msg_contains('duplicate method /hello.Greeter/',
        server.new, {listen = '127.0.0.1:0', services = {greeter(), greeter()}})
    -- A user copy of the health service collides with the built-in one.
    t.assert_error_msg_contains('duplicate method /grpc.health.v1.Health/',
        server.new, {listen = '127.0.0.1:0', services = {pb.health.new():server()}})
end

n.test_bad_options = function()
    local cases = {
        {{services = {}}, 'a port is required'},
        {{listen = 'nohost', services = {}}, "listen must be 'host:port'"},
        {{listen = '1:2', port = 3, services = {}}, 'either listen or host/port'},
        {{port = 0}, 'services must be an array'},
        {{port = 0, services = {{}}}, 'services[1] is not a generated server table'},
        {{port = 0, services = {}, reflection = 'yes'}, 'reflection must be a boolean'},
        {{port = 0, services = {}, health = 1}, 'health must be a boolean or an options table'},
        {{port = 0, services = {}, http = {}}, 'http must be a function'},
        {{port = 0, services = {}, bogus = true}, 'unknown option "bogus"'},
    }
    for _, c in ipairs(cases) do
        t.assert_error_msg_contains(c[2], server.new, c[1])
    end
end

n.test_without_http2 = function()
    t.skip_if(HAVE_HTTP2, 'the http2 rock is available here')
    t.assert_error_msg_contains('tarantool-http2 rock is required',
        server.new, {listen = '127.0.0.1:0', services = {greeter()}})
end

n.test_pb_server_field = function()
    -- pb.server loads on first access, like pb.reflection and pb.health.
    t.assert_is(pb.server, server)
end

-- ---------------------------------------------------------------------------
-- A real server (needs the http2 rock)
-- ---------------------------------------------------------------------------

local live = t.group('server.live')

live.test_smoke = function()
    t.skip_if(not HAVE_HTTP2, NO_HTTP2)
    local http_client = require('http.client')
    local lib = require('full.library.library_pb')

    local s = server.new({
        listen = '127.0.0.1:0',
        services = {
            hello.Greeter_server({SayHello = function(r) return {greeting = 'Hi ' .. r.name} end}),
            lib.Library_server({GetBook = function(r) return {name = r.name, title = 'T'} end}),
        },
        http = function(req)
            if req.path == '/extra' then return {status = 200, body = 'extra'} end
        end,
    }):start()
    local ok, err = pcall(function()
        local port = s:address().port
        t.assert(port > 0)
        t.assert_equals(s:health():get('hello.Greeter'), 'SERVING')
        t.assert_equals(s:health():get('library.Library'), 'SERVING')
        t.assert_equals(s:health():get(''), 'SERVING')
        t.assert_equals(s:reflection():services(), {
            'grpc.health.v1.Health', 'grpc.reflection.v1.ServerReflection',
            'grpc.reflection.v1alpha.ServerReflection', 'hello.Greeter', 'library.Library',
        })

        local base = ('http://127.0.0.1:%d'):format(port)
        local r = http_client.get(base .. '/v1/shelves/1/books/2', {timeout = 5})
        t.assert_equals(r.status, 200, r.body)
        t.assert_equals(json.decode(r.body).name, 'shelves/1/books/2')
        r = http_client.get(base .. '/extra', {timeout = 5})
        t.assert_equals({r.status, r.body}, {200, 'extra'})
        r = http_client.get(base .. '/missing', {timeout = 5})
        t.assert_equals(r.status, 404)

        t.assert_error_msg_contains('already started', s.start, s)
        s:set_serving_status('hello.Greeter', 'NOT_SERVING')
        t.assert_equals(s:health():get('hello.Greeter'), 'NOT_SERVING')
    end)
    s:stop(1)
    if not ok then error(err, 0) end
    t.assert_equals(s:address(), nil)
    t.assert_equals(s:health():get(''), 'NOT_SERVING', 'stop() shuts health down first')
    t.assert_equals(s:set_serving_status('hello.Greeter', 'SERVING'), false)
    fiber.yield()
end

-- gRPC over the network from Tarantool's own http.client (HTTP/2 with
-- prior knowledge). Whether this http.client can speak it is probed
-- first, on a plain HTTP route that reports the protocol the server saw;
-- only an established lack of that capability skips. Once the probe
-- shows HTTP/2 works, the gRPC calls must succeed as such: a server that
-- answered 415 (or anything else) to gRPC would fail here.
live.test_grpc_over_http_client = function()
    t.skip_if(not HAVE_HTTP2, NO_HTTP2)
    local http_client = require('http.client')

    local s = server.new({
        listen = '127.0.0.1:0',
        services = {
            hello.Greeter_server({SayHello = function(r) return {greeting = 'Hi ' .. r.name} end}),
        },
        http = function(req)
            if req.path == '/version' then return {status = 200, body = req.version} end
        end,
    }):start()
    local base = ('http://127.0.0.1:%d'):format(s:address().port)
    local H2 = {timeout = 5, http_version = '2-prior-knowledge'}

    local ok, err = pcall(function()
        local pok, probe = pcall(http_client.get, base .. '/version', H2)
        t.skip_if(not pok, 'http.client cannot request HTTP/2 with prior knowledge: '
            .. tostring(probe))
        t.skip_if(probe.status == 200 and probe.body ~= 'HTTP/2',
            'http.client sent ' .. tostring(probe.body) .. ' when asked for HTTP/2')
        t.assert_equals({probe.status, probe.body}, {200, 'HTTP/2'}, 'the h2c probe')

        local function call(path, msg)
            local framed = '\0' .. string.char(0, 0, 0, #msg) .. msg
            return http_client.post(base .. path, framed, {
                timeout = 5, http_version = '2-prior-knowledge',
                headers = {['content-type'] = 'application/grpc', te = 'trailers'},
            })
        end

        local r = call('/hello.Greeter/SayHello', hello.HelloRequest_encode({name = 'Zed'}))
        t.assert_equals(r.status, 200)
        t.assert_equals(r.headers['content-type'], 'application/grpc')
        -- A failed call is a trailers-only response: grpc-status in the
        -- headers. A successful one carries it in the trailers, which
        -- http.client does not show.
        t.assert_equals(r.headers['grpc-status'], nil)
        t.assert_equals(r.body:sub(1, 5), '\0' .. string.char(0, 0, 0, #r.body - 5))
        t.assert_equals(hello.HelloReply_decode(r.body:sub(6)).greeting, 'Hi Zed')

        -- The negative control: the status is visible when there is one.
        r = call('/hello.Greeter/Nope', '')
        t.assert_equals(r.status, 200)
        t.assert_equals(r.headers['grpc-status'], tostring(grpc.code.UNIMPLEMENTED))
    end)
    s:stop(1)
    if not ok then error(err, 0) end
end

live.test_bind_failure = function()
    t.skip_if(not HAVE_HTTP2, NO_HTTP2)
    local a = server.new({listen = '127.0.0.1:0', services = {}}):start()
    local port = a:address().port
    local b = server.new({listen = '127.0.0.1:' .. port, services = {},
                          reflection = false, health = false, transcoding = false})
    t.assert_error_msg_contains('cannot listen', b.start, b)
    a:stop(1)
    t.assert_equals(b:health(), nil)
    t.assert_error_msg_contains('health is disabled', b.set_serving_status, b, '', 'SERVING')
end
