-- pb.health: grpc.health.v1.Health through the in-process transports,
-- driven by the client generated from the upstream health.proto.

local t     = require('luatest')
local fiber = require('fiber')
local pb    = require('pb')

local HEALTH = require('pb.gen.grpc.health.v1.health_pb')
local S = HEALTH.HealthCheckResponse_ServingStatus

local function client(h)
    return HEALTH.Health_client(pb.grpc.loopback(h:server()))
end

-- Watch stream wrapper whose next() gives up after `timeout` seconds
-- (returning nil, 'timeout'), so a test can assert that nothing came.
local function watch(c, service)
    local stream = c.Watch({service = service}, {})
    local ch = fiber.channel(16)
    fiber.create(function()
        while true do
            local msg, err = stream:recv()
            ch:put({msg, err})
            if msg == nil then return end
        end
    end)
    return {
        next = function(_, timeout)
            local item = ch:get(timeout or 1)
            if item == nil then return nil, 'timeout' end
            return item[1], item[2]
        end,
        cancel = function() stream:cancel() end,
    }
end

-- Wait until cond() holds or `timeout` seconds pass.
local function eventually(cond, timeout)
    local deadline = fiber.clock() + (timeout or 1)
    while fiber.clock() < deadline do
        if cond() then return true end
        fiber.sleep(0.005)
    end
    return cond()
end

local g = t.group('health')

g.test_check = function()
    local h = pb.health.new()
    local c = client(h)
    t.assert_equals(c.Check({}), {status = S.SERVING})
    t.assert_equals(c.Check({service = ''}), {status = S.SERVING})

    t.assert(h:set('hello.Greeter', 'NOT_SERVING'))
    t.assert_equals(c.Check({service = 'hello.Greeter'}), {status = S.NOT_SERVING})
    h:set('hello.Greeter', S.SERVING)
    t.assert_equals(c.Check({service = 'hello.Greeter'}), {status = S.SERVING})
    t.assert_equals(h:get('hello.Greeter'), 'SERVING')
    t.assert_equals(h:get('no.Such'), nil)

    local ok, err = pcall(c.Check, {service = 'no.Such'})
    t.assert_not(ok)
    t.assert(pb.grpc.is_status(err), tostring(err))
    t.assert_equals(err.code, pb.grpc.code.NOT_FOUND)
end

g.test_list = function()
    local h = pb.health.new()
    h:set('a.A', 'SERVING')
    h:set('b.B', 'NOT_SERVING')
    t.assert_equals(client(h).List({}), {statuses = {
        [''] = {status = S.SERVING},
        ['a.A'] = {status = S.SERVING},
        ['b.B'] = {status = S.NOT_SERVING},
    }})
    for i = 1, pb.health.MAX_LIST do h:set('svc' .. i, 'SERVING') end
    local ok, err = pcall(client(h).List, {})
    t.assert_not(ok)
    t.assert_equals(err.code, pb.grpc.code.RESOURCE_EXHAUSTED)
end

g.test_watch_sends_current_status_then_changes = function()
    local h = pb.health.new()
    h:set('svc', 'SERVING')
    local w = watch(client(h), 'svc')
    t.assert_equals(w:next(), {status = S.SERVING})

    h:set('svc', 'NOT_SERVING')
    t.assert_equals(w:next(), {status = S.NOT_SERVING})
    -- The same status again is not a change.
    h:set('svc', 'NOT_SERVING')
    h:set('svc', 'SERVING')
    t.assert_equals(w:next(), {status = S.SERVING})
    -- Other services do not wake this watch.
    h:set('other', 'NOT_SERVING')
    t.assert_equals(select(2, w:next(0.05)), 'timeout')
    w:cancel()
end

g.test_watch_unknown_service_stays_open = function()
    local h = pb.health.new()
    local w = watch(client(h), 'later')
    t.assert_equals(w:next(), {status = S.SERVICE_UNKNOWN})
    t.assert_equals(select(2, w:next(0.05)), 'timeout')
    h:set('later', 'SERVING')
    t.assert_equals(w:next(), {status = S.SERVING})
    w:cancel()
end

g.test_watch_overall_status = function()
    local h = pb.health.new()
    local w = watch(client(h), '')
    t.assert_equals(w:next(), {status = S.SERVING})
    h:shutdown()
    t.assert_equals(w:next(), {status = S.NOT_SERVING})
    w:cancel()
end

-- A cancelled watch with no status change ends within the poll interval.
g.test_cancelled_watch_does_not_leak = function()
    local h = pb.health.new({poll_interval = 0.01})
    local watches = {}
    for i = 1, 8 do
        watches[i] = watch(client(h), 'svc')
        t.assert_equals(watches[i]:next(), {status = S.SERVICE_UNKNOWN})
    end
    t.assert_equals(h:watchers('svc'), 8)
    for _, w in ipairs(watches) do w:cancel() end
    t.assert(eventually(function() return h:watchers('svc') == 0 end),
             'watchers left: ' .. h:watchers('svc'))
end

-- A status change after cancel ends the watch at once, however long the
-- poll interval: the send reports the caller is gone.
g.test_cancelled_watch_ends_on_next_change = function()
    local h = pb.health.new({poll_interval = 3600})
    local w = watch(client(h), 'svc')
    t.assert_equals(w:next(), {status = S.SERVICE_UNKNOWN})
    w:cancel()
    t.assert_equals(h:watchers('svc'), 1)
    h:set('svc', 'SERVING')
    t.assert(eventually(function() return h:watchers('svc') == 0 end),
             'watch survived its cancel')
end

g.test_watch_ends_when_ctx_is_cancelled = function()
    local h = pb.health.new({poll_interval = 0.01})
    local srv = h:server()
    local gone = false
    local sent = {}
    local stream = {send = function(_, msg) sent[#sent + 1] = msg.status; return true end}
    local ctx = {is_cancelled = function() return gone end}
    local done = fiber.channel(1)
    fiber.create(function()
        srv.streams['/grpc.health.v1.Health/Watch'].handler(
            HEALTH.HealthCheckRequest_encode({service = 'x'}),
            {send = function(_, b) return stream:send(HEALTH.HealthCheckResponse_decode(b)) end},
            ctx)
        done:put(true)
    end)
    t.assert(eventually(function() return #sent == 1 end))
    t.assert_equals(h:watchers('x'), 1)
    gone = true
    t.assert_equals(done:get(1), true)
    t.assert_equals(h:watchers('x'), 0)
    t.assert_equals(sent, {S.SERVICE_UNKNOWN})
end

-- A transport that reports a gone caller only through send() -> false.
g.test_watch_ends_when_send_fails = function()
    local h = pb.health.new({poll_interval = 3600})
    local srv = h:server()
    local sends = 0
    local view = {send = function() sends = sends + 1; return sends == 1 end}
    local done = fiber.channel(1)
    fiber.create(function()
        srv.streams['/grpc.health.v1.Health/Watch'].handler(
            HEALTH.HealthCheckRequest_encode({service = 'y'}), view, {})
        done:put(true)
    end)
    t.assert(eventually(function() return sends == 1 end))
    h:set('y', 'SERVING')
    t.assert_equals(done:get(1), true)
    t.assert_equals(sends, 2)
    t.assert_equals(h:watchers('y'), 0)
end

-- A change made while send() is blocked goes out as soon as the send
-- returns, not a poll interval later.
g.test_change_during_blocked_send_is_not_lost = function()
    local h = pb.health.new({poll_interval = 3600})
    h:set('z', 'SERVING')
    local srv = h:server()
    local release = fiber.channel(1)
    local sent = fiber.channel(4)
    local n, done = 0, false
    local view = {send = function(_, b)
        n = n + 1
        if n == 1 then release:get() end   -- the first send blocks
        sent:put(HEALTH.HealthCheckResponse_decode(b).status)
        return not done
    end}
    fiber.create(function()
        srv.streams['/grpc.health.v1.Health/Watch'].handler(
            HEALTH.HealthCheckRequest_encode({service = 'z'}), view, {})
    end)
    fiber.yield()
    h:set('z', 'NOT_SERVING')   -- while the first send is blocked
    release:put(true)
    t.assert_equals(sent:get(1), S.SERVING)
    t.assert_equals(sent:get(1), S.NOT_SERVING)
    -- End the watch: the next send reports the caller gone.
    done = true
    h:set('z', 'SERVING')
    t.assert(eventually(function() return h:watchers('z') == 0 end))
end

g.test_shutdown_and_resume = function()
    local h = pb.health.new()
    h:set('a', 'SERVING')
    h:shutdown()
    t.assert_equals(h:get(''), 'NOT_SERVING')
    t.assert_equals(h:get('a'), 'NOT_SERVING')
    -- Ignored while shut down.
    t.assert_equals(h:set('a', 'SERVING'), false)
    t.assert_equals(h:set('b', 'SERVING'), false)
    t.assert_equals(h:get('a'), 'NOT_SERVING')
    t.assert_equals(h:get('b'), nil)
    h:resume()
    t.assert_equals(h:get(''), 'SERVING')
    t.assert_equals(h:get('a'), 'SERVING')
    t.assert(h:set('b', 'NOT_SERVING'))
end

g.test_bad_arguments = function()
    local h = pb.health.new()
    t.assert_error_msg_contains('unknown serving status', h.set, h, 'a', 'UP')
    t.assert_error_msg_contains('unknown serving status', h.set, h, 'a', 42)
    t.assert_error_msg_contains('service must be a string', h.set, h, nil, 'SERVING')
    t.assert_error_msg_contains('poll_interval', pb.health.new, {poll_interval = 0})
end

g.test_server_table_shape = function()
    local srv = pb.health.new():server()
    t.assert_is(srv.service, HEALTH.Health_service)
    t.assert_equals(pb.health.SERVICE, 'grpc.health.v1.Health')
    t.assert_type(srv.methods['/grpc.health.v1.Health/Check'], 'function')
    t.assert_type(srv.methods['/grpc.health.v1.Health/List'], 'function')
    t.assert_equals(srv.streams['/grpc.health.v1.Health/Watch'].kind, 'server_stream')
end

-- Health and reflection side by side, as a server would expose them.
g.test_with_reflection = function()
    local h = pb.health.new()
    local refl = pb.reflection.new({services = {h:server()}})
    local servers = refl:servers()
    table.insert(servers, h:server())
    local tr = pb.grpc.multiplex(servers)
    local V1 = require('pb.gen.grpc.reflection.v1.reflection_pb')
    local call = V1.ServerReflection_client(tr).ServerReflectionInfo({})
    call:send({list_services = ''})
    local resp = call:recv()
    t.assert_equals(resp.list_services_response.service, {
        {name = 'grpc.health.v1.Health'},
        {name = 'grpc.reflection.v1.ServerReflection'},
        {name = 'grpc.reflection.v1alpha.ServerReflection'},
    })
    call:send({file_containing_symbol = 'grpc.health.v1.Health.Watch'})
    resp = call:recv()
    t.assert_equals(#resp.file_descriptor_response.file_descriptor_proto, 1)
    t.assert_equals(resp.file_descriptor_response.file_descriptor_proto[1],
                    HEALTH._file_descriptor)
    call:close_send()
    t.assert_equals(HEALTH.Health_client(tr).Check({}), {status = S.SERVING})
end
