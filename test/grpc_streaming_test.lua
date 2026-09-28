-- gRPC streaming over fiber channels: server-streaming, client-streaming,
-- and bidirectional flavors, run end-to-end through the loopback transport.
--
-- Parameterized over both codegen modes since the generated client/server
-- bodies differ between full and runtime mode (different per-message
-- encode/decode call sites).

local t     = require('luatest')
local fiber = require('fiber')
local pb    = require('pb')

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local hello = require(mode .. '.hello.hello_pb')
    local g = t.group('grpc_stream.' .. mode)

    -- ---------------------------------------------------------------------
    -- Server-streaming: one request in, many replies out.
    -- ---------------------------------------------------------------------

    g.test_server_stream_yields_replies_in_order = function()
        local impl = {
            StreamHellos = function(req, stream, _)
                for i = 1, 3 do
                    stream:send({greeting = req.name .. '#' .. tostring(i)})
                end
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))

        local stream = client.StreamHellos({name = 'X'}, {})
        local replies = {}
        while true do
            local r, err = stream:recv()
            if r == nil then
                t.assert_equals(err, nil, 'unexpected stream error: ' .. tostring(err))
                break
            end
            replies[#replies + 1] = r.greeting
        end
        t.assert_equals(replies, {'X#1', 'X#2', 'X#3'})
    end

    g.test_server_stream_handler_can_be_empty = function()
        -- A handler that returns without sending anything is a valid
        -- (empty) stream — recv() must return nil on the first call.
        local impl = {StreamHellos = function(_, _, _) end}
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))
        local stream = client.StreamHellos({name = 'x'}, {})
        local r, err = stream:recv()
        t.assert_equals(r, nil)
        t.assert_equals(err, nil)
    end

    g.test_server_stream_handler_error_surfaces = function()
        local impl = {
            StreamHellos = function(_, stream, _)
                stream:send({greeting = 'first'})
                error('boom from handler')
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))
        local stream = client.StreamHellos({name = 'x'}, {})

        -- First message comes through cleanly.
        local r1 = stream:recv()
        t.assert_equals(r1.greeting, 'first')

        -- Then end-of-stream with the handler's error string.
        local r2, err = stream:recv()
        t.assert_equals(r2, nil)
        t.assert_str_contains(tostring(err), 'boom from handler')
    end

    g.test_missing_streaming_handler_errors = function()
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server({})))
        local stream = client.StreamHellos({name = 'x'}, {})
        local r, err = stream:recv()
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(err), 'StreamHellos: handler missing')
    end

    -- ---------------------------------------------------------------------
    -- Client-streaming: many requests in, one reply out.
    -- ---------------------------------------------------------------------

    g.test_client_stream_collects_and_replies = function()
        local impl = {
            CollectHellos = function(stream, _)
                local names = {}
                while true do
                    local req = stream:recv()
                    if req == nil then break end
                    names[#names + 1] = req.name
                end
                return {greeting = 'collected: ' .. table.concat(names, ',')}
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))

        local call = client.CollectHellos({})
        call:send({name = 'a'})
        call:send({name = 'b'})
        call:send({name = 'c'})
        call:close_send()

        local reply, err = call:recv()
        t.assert_equals(err, nil)
        t.assert_equals(reply.greeting, 'collected: a,b,c')

        -- recv after the response should return nil (stream ended).
        local tail, err2 = call:recv()
        t.assert_equals(tail, nil)
        t.assert_equals(err2, nil)
    end

    g.test_client_stream_empty_is_valid = function()
        local impl = {
            CollectHellos = function(stream, _)
                t.assert_equals(stream:recv(), nil)
                return {greeting = 'empty'}
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))
        local call = client.CollectHellos({})
        call:close_send()
        local reply = call:recv()
        t.assert_equals(reply.greeting, 'empty')
    end

    -- ---------------------------------------------------------------------
    -- Bidirectional streaming: both sides send + recv independently.
    -- ---------------------------------------------------------------------

    g.test_bidi_echo_loop = function()
        -- Server echoes each request back with a "you said: " prefix.
        local impl = {
            Chat = function(stream, _)
                while true do
                    local req = stream:recv()
                    if req == nil then break end
                    stream:send({greeting = 'you said: ' .. req.name})
                end
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))

        local call = client.Chat({})

        -- Drive the client side from a separate fiber so we can interleave
        -- sends and receives without deadlocking.
        local reader_done = fiber.channel(1)
        local received = {}
        fiber.create(function()
            while true do
                local r, err = call:recv()
                if r == nil then
                    reader_done:put(err or false)
                    break
                end
                received[#received + 1] = r.greeting
            end
        end)

        call:send({name = 'foo'})
        call:send({name = 'bar'})
        call:send({name = 'baz'})
        call:close_send()

        local terminal = reader_done:get(5)
        t.assert(terminal == false, 'reader saw error: ' .. tostring(terminal))
        t.assert_equals(received, {
            'you said: foo', 'you said: bar', 'you said: baz',
        })
    end

    g.test_bidi_handler_error_surfaces = function()
        local impl = {
            Chat = function(_, _)
                error('chat exploded')
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))
        local call = client.Chat({})
        call:close_send()
        local r, err = call:recv()
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(err), 'chat exploded')
    end

    g.test_bidi_cancel_stops_further_recv = function()
        -- Server sends forever; client cancels after one message.
        local server_finished = fiber.channel(1)
        local impl = {
            Chat = function(stream, _)
                local i = 0
                while stream:send({greeting = 'tick:' .. tostring(i)}) do
                    i = i + 1
                    if i > 100 then break end -- safety
                    fiber.yield()
                end
                server_finished:put(i)
            end,
        }
        local client = hello.Greeter_client(pb.grpc.loopback(
            hello.Greeter_server(impl)))
        local call = client.Chat({})
        local first = call:recv()
        t.assert_str_contains(first.greeting, 'tick:')
        call:cancel()

        -- Give the server fiber a chance to observe the cancel.
        local final_i = server_finished:get(5)
        t.assert(final_i ~= nil, 'server did not stop after cancel')
        t.assert(final_i <= 100, 'server kept running past safety bound')
    end
end

-- ---------------------------------------------------------------------------
-- pb.grpc.new_stream_pair: unit-level coverage of the primitive itself
-- (independent of generated code).
-- ---------------------------------------------------------------------------

local u = t.group('grpc_stream.primitive')

u.test_send_recv_byte_passthrough = function()
    local client, server = pb.grpc.new_stream_pair()
    fiber.create(function()
        local req = server:recv()
        server:send('reply:' .. req)
        server:_finish(nil)
    end)
    client:send('ping')
    client:close_send()
    local out = client:recv()
    t.assert_equals(out, 'reply:ping')
    t.assert_equals(client:recv(), nil)
end

u.test_finish_with_error_propagates = function()
    local client, server = pb.grpc.new_stream_pair()
    fiber.create(function()
        server:_finish('handler error')
    end)
    local b, err = client:recv()
    t.assert_equals(b, nil)
    t.assert_equals(err, 'handler error')
end

u.test_send_after_close_send_errors = function()
    local client, _ = pb.grpc.new_stream_pair()
    client:close_send()
    t.assert_error(function() client:send('nope') end)
end

-- ---------------------------------------------------------------------------
-- multiplex: streaming methods route correctly across multiple servers.
-- ---------------------------------------------------------------------------

local m = t.group('grpc_stream.multiplex')

m.test_multiplex_routes_streams_to_right_server = function()
    local hello = require('full.hello.hello_pb')
    -- Two independent Greeter servers; multiplex would normally complain
    -- about the duplicate paths, so for this test we keep just one with a
    -- streaming impl and verify routing works via the multiplex transport.
    local impl = {
        StreamHellos = function(req, stream, _)
            stream:send({greeting = 'mp:' .. req.name})
        end,
    }
    local mux = pb.grpc.multiplex({hello.Greeter_server(impl)})
    local client = hello.Greeter_client(mux)
    local s = client.StreamHellos({name = 'X'}, {})
    local r = s:recv()
    t.assert_equals(r.greeting, 'mp:X')
    t.assert_equals(s:recv(), nil)
end

m.test_multiplex_duplicate_streaming_path_errors = function()
    -- Construct two minimal server tables that share a streaming path so
    -- we hit the duplicate-stream branch without also tripping the
    -- duplicate-unary branch.
    local stream_entry = {
        kind = 'server_stream',
        handler = function() end,
    }
    local s1 = {methods = {}, streams = {['/dup/Path'] = stream_entry}}
    local s2 = {methods = {}, streams = {['/dup/Path'] = stream_entry}}
    t.assert_error_msg_contains('duplicate streaming route', function()
        pb.grpc.multiplex({s1, s2})
    end)
end
