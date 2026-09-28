-- Greeter client example. Loads the server-side from server.lua, builds
-- a loopback transport, and exercises every streaming flavor.
--
-- Run with:
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;" \
--     tarantool examples/grpc/client.lua

local fiber = require('fiber')
local hello = require('full.hello.hello_pb')

-- Builds a transport — see examples/grpc/server.lua.
local transport = dofile('examples/grpc/server.lua')

local client = hello.Greeter_client(transport)

-- 1. Unary
print('--- unary ---')
local reply = client.SayHello({name = 'Alice'}, {})
print(reply.greeting)

-- 2. Server-stream
print('--- server-stream ---')
local s = client.StreamHellos({name = 'Bob'}, {})
while true do
    local msg, err = s:recv()
    if msg == nil then
        if err ~= nil then error(err, 0) end
        break
    end
    print(msg.greeting)
end

-- 3. Client-stream
print('--- client-stream ---')
local c = client.CollectHellos({})
c:send({name = 'Alice'})
c:send({name = 'Bob'})
c:send({name = 'Carol'})
c:close_send()
local final = c:recv()
print(final.greeting)

-- 4. Bidi
print('--- bidi ---')
local b = client.Chat({})

-- Producer fiber pushes a few messages then closes its side.
fiber.create(function()
    for _, name in ipairs({'X', 'Y', 'Z'}) do
        b:send({name = name})
    end
    b:close_send()
end)

while true do
    local msg, err = b:recv()
    if msg == nil then
        if err ~= nil then error(err, 0) end
        break
    end
    print(msg.greeting)
end

os.exit(0)
