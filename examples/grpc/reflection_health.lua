-- Server reflection and health next to an application service.
--
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;" \
--     tarantool examples/grpc/reflection_health.lua
--
-- Drives both services with the clients generated from their upstream
-- .proto files, the way grpcurl and a health probe would over a network.

local pb = require('pb')
local hello = require('full.hello.hello_pb')
local reflection_pb = require('pb.gen.grpc.reflection.v1.reflection_pb')
local health_pb = require('pb.gen.grpc.health.v1.health_pb')

local greeter = hello.Greeter_server({
    SayHello = function(req) return {greeting = 'Hi ' .. req.name} end,
})

-- Health: the whole server ('') starts SERVING; add per-service entries.
local health = pb.health.new()
health:set('hello.Greeter', 'SERVING')

-- Reflection lists the services it is told about, plus itself.
local refl = pb.reflection.new({services = {greeter, health:server()}})

local servers = {greeter, health:server()}
for _, s in ipairs(refl:servers()) do table.insert(servers, s) end
local transport = pb.grpc.multiplex(servers)

-- What `grpcurl list` asks.
local info = reflection_pb.ServerReflection_client(transport).ServerReflectionInfo({})
info:send({list_services = ''})
for _, s in ipairs(info:recv().list_services_response.service) do
    print('service', s.name)
end

-- What `grpcurl describe hello.Greeter.SayHello` asks: the file that
-- defines the symbol, then its imports not sent on this stream yet.
info:send({file_containing_symbol = 'hello.Greeter.SayHello'})
local files = info:recv().file_descriptor_response.file_descriptor_proto
print('files for hello.Greeter.SayHello:', #files)

-- Unknown names answer NOT_FOUND and leave the stream open.
info:send({file_containing_symbol = 'hello.Nope'})
local err = info:recv().error_response
print('hello.Nope:', pb.grpc.code_name[err.error_code])
info:close_send()

-- Health checks.
local hc = health_pb.Health_client(transport)
local status = health_pb.HealthCheckResponse_ServingStatus_descriptor.by_value
print('hello.Greeter:', status[hc.Check({service = 'hello.Greeter'}).status])

local watch = hc.Watch({service = 'hello.Greeter'})
print('watch:', status[watch:recv().status])
health:set('hello.Greeter', 'NOT_SERVING')
print('watch:', status[watch:recv().status])
watch:cancel()

-- Draining: everything NOT_SERVING.
health:shutdown()
print('overall after shutdown:', status[hc.Check({}).status])

os.exit(0)
