-- JSON-over-HTTP server example using tarantool/http.
--
-- Pattern:
--   POST /v1/users
--     Content-Type: application/json
--     Body:        proto3 JSON for hello.Person
--   Response:
--     200 OK
--     Content-Type: application/json
--     Body:        same shape, plus the generated user_id
--
-- Run with:
--   LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;" \
--     tarantool examples/http/json_api.lua
--
-- Then:
--   curl -X POST http://127.0.0.1:8080/v1/users \
--        -H 'Content-Type: application/json' \
--        -d '{"name":"Alice","age":30,"emails":["a@x"]}'

local pb = require('pb')
local hello = require('full.hello.hello_pb')

-- tarantool-http is installed via `tt rocks install http`; without it,
-- swap in your project's preferred HTTP framework.
local httpd_ok, http = pcall(require, 'http.server')
if not httpd_ok then
    error('this example needs the `http.server` rock: tt rocks install http')
end

local httpd = http.new('127.0.0.1', 8080)

httpd:route({path = '/v1/users', method = 'POST'}, function(req)
    -- Parse the request body as proto3 JSON.
    local body = req:read_cached()
    local ok, person = pcall(pb.json.decode, hello.Person_descriptor, body, {
        -- Accept (and ignore) keys the schema doesn't know — handy for
        -- forward-compat clients that send extras.
        ignore_unknown_fields = true,
    })
    if not ok then
        return {status = 400, headers = {['content-type'] = 'application/json'},
                body = pb.json.encode(hello.HelloReply_descriptor,
                                      {greeting = 'bad request: ' .. person})}
    end

    -- (Pretend) business logic: assign a user_id.
    person.user_id = pb.to_uint64(42)

    return {
        status = 200,
        headers = {['content-type'] = 'application/json'},
        body = pb.json.encode(hello.Person_descriptor, person),
    }
end)

httpd:start()
print('listening on http://127.0.0.1:8080')
require('fiber').sleep(math.huge)  -- block; Ctrl-C to stop
