-- Standalone Greeter server example.
--
-- Run via the matching client:
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;" \
--     tarantool examples/grpc/client.lua
--
-- This file is required by client.lua, not run directly. It returns a
-- transport that the client wraps with the generated stub.

local pb = require('pb')
local hello = require('full.hello.hello_pb')

local impl = {
    -- Unary
    SayHello = function(req, _ctx)
        return {greeting = 'Hi ' .. req.name}
    end,

    -- Unary: echo the request as the reply (any HelloRequest works).
    Echo = function(req, _ctx)
        return req
    end,

    -- Server-stream: push N replies, then close by returning.
    StreamHellos = function(req, stream, _ctx)
        for i = 1, 3 do
            stream:send({greeting = ('Hi #%d %s'):format(i, req.name)})
        end
    end,

    -- Client-stream: collect N requests into one reply.
    CollectHellos = function(stream, _ctx)
        local names = {}
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                break
            end
            names[#names + 1] = req.name
        end
        return {greeting = 'Hi ' .. table.concat(names, ', ')}
    end,

    -- Bidi: echo each incoming, close when peer closes.
    Chat = function(stream, _ctx)
        while true do
            local req, err = stream:recv()
            if req == nil then
                if err ~= nil then error(err, 0) end
                return
            end
            stream:send({greeting = 'Echo ' .. req.name})
        end
    end,
}

local server = hello.Greeter_server(impl)
return pb.grpc.loopback(server)
