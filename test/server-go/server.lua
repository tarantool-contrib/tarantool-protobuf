-- The server the Go end-to-end test (server_test.go) talks to: pb.server
-- with Greeter (all four call kinds) and the library service
-- (transcoding), reflection and health left at their defaults.
--
-- Usage: tarantool test/server-go/server.lua
-- LUA_PATH must reach runtime/, examples/expected/ and the http2 rock.
--
-- It listens on 127.0.0.1 on a free port and prints one line to stdout,
-- `LISTENING <port>`, once the listener is bound. It runs until stdin
-- closes or SIGTERM.
--
-- Test hooks, keyed on HelloRequest.name in SayHello:
--   'missing'   -> NOT_FOUND with a HelloReply detail
--   'boom'      -> a plain Lua error (INTERNAL, text not leaked)
--   'sleep:<s>' -> sleeps <s> seconds before answering
-- Every SayHello copies the x-request-id metadata into response
-- (x-response-id) and trailing (x-trailer-id) metadata.
--
-- HTTP fallback (not transcoded):
--   POST /control/serving?service=<name>&status=<STATUS>  -> health:set
local fiber = require('fiber')
local log   = require('log')
local pb    = require('pb')
local hello = require('full.hello.hello_pb')
local lib   = require('full.library.library_pb')

local function detail(text)
    return pb.any.pack(hello.HelloReply_descriptor, {greeting = text})
end

local greeter = hello.Greeter_server({
    SayHello = function(req, ctx)
        local id = ctx.metadata and ctx.metadata['x-request-id']
        if id ~= nil then
            ctx.response_metadata['x-response-id'] = id
            ctx.trailing_metadata['x-trailer-id'] = id
        end
        local name = req.name or ''
        if name == 'missing' then
            pb.grpc.error(pb.grpc.code.NOT_FOUND, 'no such person: missing',
                          {detail('try someone else')})
        elseif name == 'boom' then
            error('secret internal failure text')
        end
        local secs = name:match('^sleep:([%d.]+)$')
        if secs ~= nil then
            local deadline = fiber.clock() + tonumber(secs)
            while fiber.clock() < deadline and not ctx:is_cancelled() do
                fiber.sleep(0.01)
            end
        end
        return {greeting = 'Hello, ' .. name}
    end,

    Echo = function(req) return req end,

    StreamHellos = function(req, stream)
        for i = 1, 3 do
            stream:send({greeting = ('Hello #%d, %s'):format(i, req.name or '')})
        end
    end,

    CollectHellos = function(stream)
        local names = {}
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                break
            end
            names[#names + 1] = req.name
        end
        if #names == 0 then
            pb.grpc.error(pb.grpc.code.INVALID_ARGUMENT, 'no names')
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
            if req.name == 'stop' then
                pb.grpc.error(pb.grpc.code.ABORTED, 'stopped by request')
            end
            stream:send({greeting = 'Echo ' .. (req.name or '')})
        end
    end,
})

-- The library service, as in examples/http/transcode.lua.
local books = {
    ['shelves/1/books/1'] = {name = 'shelves/1/books/1', shelf = '1', title = 'Dune',
                             author = 'Herbert', isbn = '42'},
}
local next_id = 2

local library = lib.Library_server({
    GetBook = function(req)
        local book = books[req.name]
        if book == nil then
            pb.grpc.error(pb.grpc.code.NOT_FOUND, 'no book ' .. tostring(req.name))
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
        local limit = req.page_size or 0
        if limit > 0 and #out > limit then
            for i = #out, limit + 1, -1 do out[i] = nil end
        end
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

local server
server = pb.server.new({
    listen = '127.0.0.1:0',
    services = {greeter, library},
    http = function(req)
        local path, query = req.path:match('^([^?]*)%??(.*)$')
        if req.method == 'POST' and path == '/control/serving' then
            local args = {}
            for k, v in query:gmatch('([^&=]+)=([^&]*)') do args[k] = v end
            server:set_serving_status(args.service or '', args.status)
            return {status = 200, headers = {['content-type'] = 'text/plain'}, body = 'ok'}
        end
    end,
})
server:start()

io.stdout:write(('LISTENING %d\n'):format(server:address().port))
io.stdout:flush()

-- Stop when the parent closes our stdin (the test is over).
fiber.create(function()
    local fio = require('fio')
    local stdin = fio.open('/dev/stdin', {'O_RDONLY'})
    if stdin == nil then return end
    while true do
        local chunk = stdin:read(64)
        if chunk == nil or chunk == '' then break end
    end
    log.info('stdin closed, stopping')
    server:stop(1)
    os.exit(0)
end)
