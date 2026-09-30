-- A real gRPC + HTTP/JSON server: Greeter (all four call kinds) and the
-- library service, with server reflection, health and google.api.http
-- transcoding, all on one port.
--
-- Needs the tarantool-http2 rock (and the system libnghttp2).
--
--   tarantool examples/grpc/network_server.lua [port]   -- serve until Ctrl-C
--   tarantool examples/grpc/network_server.lua --self-check
--
-- The port comes from the argument, else PB_SERVER_PORT, else 8080.
-- --self-check listens on a free port, calls the server over the network
-- with Tarantool's http.client and stops. See `just examples network-server`
-- and docs/howto/16-network-server.md.
local fiber = require('fiber')
local json  = require('json')
local pb    = require('pb')
local hello = require('full.hello.hello_pb')
local lib   = require('full.library.library_pb')

-- Greeter: one handler per call kind.
local greeter = hello.Greeter_server({
    SayHello = function(req, ctx)
        -- ctx.metadata holds the request metadata; handlers may add
        -- response (header) and trailing metadata.
        ctx.response_metadata['x-served-by'] = 'tarantool'
        if req.name == '' then
            pb.grpc.error(pb.grpc.code.INVALID_ARGUMENT, 'name is required')
        end
        return {greeting = 'Hello, ' .. req.name}
    end,

    Echo = function(req) return req end,

    StreamHellos = function(req, stream)
        for i = 1, 3 do
            if stream:send({greeting = ('Hello #%d, %s'):format(i, req.name)}) == false then
                return -- the client went away
            end
        end
    end,

    CollectHellos = function(stream)
        local names = {}
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                break -- the client half-closed
            end
            names[#names + 1] = req.name
        end
        return {greeting = 'Hello, ' .. table.concat(names, ', ')}
    end,

    Chat = function(stream)
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                return
            end
            stream:send({greeting = 'Echo ' .. req.name})
        end
    end,
})

-- The library service: an in-memory shelf behind its google.api.http
-- routes (examples/proto/library.proto).
local books = {
    ['shelves/1/books/1'] = {name = 'shelves/1/books/1', title = 'Dune', isbn = '42'},
}
local next_id = 2

local library = lib.Library_server({
    GetBook = function(req)
        local book = books[req.name]
        if book == nil then
            pb.grpc.error(pb.grpc.code.NOT_FOUND, 'no book ' .. req.name)
        end
        return book
    end,
    ListBooks = function(req)
        local out = {}
        for name, book in pairs(books) do
            if name:sub(1, #req.parent + 1) == req.parent .. '/' then
                out[#out + 1] = book
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return {books = out}
    end,
    CreateBook = function(req)
        local book = req.book or {}
        book.name = ('%s/books/%d'):format(req.parent, next_id)
        next_id = next_id + 1
        books[book.name] = book
        return book
    end,
})

local self_check = arg[1] == '--self-check'
local port = self_check and 0 or tonumber(arg[1] or os.getenv('PB_SERVER_PORT') or 8080)

local server = pb.server.new({
    listen = '127.0.0.1:' .. port,
    services = {greeter, library},
    -- reflection, health and transcoding are on by default.
    transcoding = {json = {emit_defaults = false, emit_null_messages = false}},
    http = function(req)
        if req.path == '/' then
            return {status = 200, headers = {['content-type'] = 'text/plain'},
                    body = 'gRPC and HTTP/JSON on one port\n'}
        end
    end,
}):start()
local addr = server:address()
print(('listening on %s:%d'):format(addr.host, addr.port))

if not self_check then
    print(('try:  grpcurl -plaintext %s:%d list'):format(addr.host, addr.port))
    print(('      grpcurl -plaintext -d \'{"name": "Ann"}\' %s:%d hello.Greeter/SayHello')
        :format(addr.host, addr.port))
    print(('      curl http://%s:%d/v1/shelves/1/books/1'):format(addr.host, addr.port))
    return -- the event loop keeps serving
end

-- --self-check: talk to the server over the network, from this process.
local http = require('http.client')
local base = ('http://%s:%d'):format(addr.host, addr.port)

-- Print a JSON body with sorted keys, so the output is stable.
local function canonical(v)
    if type(v) ~= 'table' then return json.encode(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = json.encode(k) .. ':' .. canonical(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

local function show(method, path, resp)
    print(('%s %s -> %d %s'):format(method, path, resp.status, canonical(json.decode(resp.body))))
end

-- HTTP/JSON over HTTP/1.1, routed by google.api.http.
local r = http.get(base .. '/v1/shelves/1/books/1', {timeout = 5})
show('GET', '/v1/shelves/1/books/1', r)
assert(r.status == 200 and json.decode(r.body).title == 'Dune')

r = http.post(base .. '/v1/shelves/1/books', '{"title": "Hyperion"}',
              {timeout = 5, headers = {['content-type'] = 'application/json'}})
show('POST', '/v1/shelves/1/books', r)
assert(r.status == 200 and json.decode(r.body).name == 'shelves/1/books/2')

r = http.get(base .. '/v1/shelves/1/books/9', {timeout = 5})
show('GET', '/v1/shelves/1/books/9', r)
assert(r.status == 404 and json.decode(r.body).code == pb.grpc.code.NOT_FOUND)

-- gRPC over HTTP/2 (prior knowledge): one length-prefixed message in,
-- one out. The status travels in trailers, which http.client does not
-- expose; a real client (grpc-go, grpcurl) reads them.
local function grpc_call(path, bytes)
    local framed = '\0' .. string.char(0, 0, 0, #bytes) .. bytes
    local ok, resp = pcall(http.post, base .. path, framed, {
        timeout = 5, http_version = '2-prior-knowledge',
        headers = {['content-type'] = 'application/grpc', te = 'trailers'},
    })
    if not ok or resp.status ~= 200 then return nil end
    return resp.body:sub(6)
end

local reply = grpc_call('/hello.Greeter/SayHello', hello.HelloRequest_encode({name = 'Ann'}))
if reply == nil then
    print('gRPC: skipped (this http.client cannot speak HTTP/2 with prior knowledge)')
else
    print('gRPC SayHello -> ' .. hello.HelloReply_decode(reply).greeting)
    local health_pb = require('pb.gen.grpc.health.v1.health_pb')
    local check = grpc_call('/grpc.health.v1.Health/Check',
        health_pb.HealthCheckRequest_encode({service = 'hello.Greeter'}))
    local status = health_pb.HealthCheckResponse_decode(check).status
    print('gRPC Health.Check(hello.Greeter) -> '
        .. health_pb.HealthCheckResponse_ServingStatus_descriptor.by_value[status])
end

-- Stopping marks every service NOT_SERVING first, then drains.
fiber.create(function()
    server:stop(1)
    print('stopped; overall health: ' .. server:health():get(''))
    os.exit(0)
end)
