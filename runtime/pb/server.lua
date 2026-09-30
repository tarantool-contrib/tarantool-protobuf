-- pb.server: a gRPC + HTTP/JSON server over the tarantool-http2 rock.
--
--   local server = require('pb.server').new({
--       listen   = '0.0.0.0:8080',
--       services = {greeter_pb.Greeter_server(impl)},
--   }):start()
--
-- One listener serves:
--
--   * gRPC over HTTP/2 (h2c, prior knowledge) for every generated server
--     table in `services`, all four call kinds;
--   * gRPC server reflection (v1 and v1alpha) and grpc.health.v1.Health,
--     unless disabled;
--   * HTTP/JSON transcoding of the services' google.api.http rules
--     (pb.transcode) over HTTP/1.1 and HTTP/2, unless disabled;
--   * the Connect protocol (pb.connect) for every service, over
--     HTTP/1.1 and HTTP/2, unless disabled;
--   * an optional fallback HTTP handler for requests nothing routed.
--
-- The socket, HTTP/2 and gRPC framing live in the `http2` rock
-- (tarantool-http2, over the system libnghttp2). It is required only
-- when a server is built, so require('pb') keeps working without it.
--
-- This module is the glue: it adapts the generated server tables
-- (`methods[path](req_bytes, ctx)`, `streams[path] = {kind, handler}`)
-- to http2's registry (`handler(ctx, req_bytes)`, `handler(ctx,
-- stream)`) and maps pb.grpc status objects raised by handlers to gRPC
-- statuses. See docs/reference/runtime-api.md (pb.server).
local fiber = require('fiber')
local log   = require('log')
local grpc  = require('pb.grpc')

local M = {}

local CODE = grpc.code

-- A streaming handler waits for the next client message in slices of
-- this many seconds; a slice ending is not an error (http2's recv
-- reports it as 'timeout'), the wait just goes on. The call's deadline
-- and a client reset end the wait at once.
M.RECV_SLICE = 3600

-- Keys of `limits` that belong to the gRPC registry
-- (http2.grpc.new); every other key goes to http2.server.new.
local REGISTRY_LIMITS = {
    max_recv_message_size = true,
    max_send_message_size = true,
    recv_buffer_size = true,
    max_recv_buffer_size = true,
    send_buffer_size = true,
}

-- ---------------------------------------------------------------------------
-- Status mapping
-- ---------------------------------------------------------------------------

-- Captures a traceback for plain errors; a status object passes as is.
local function capture(err)
    if grpc.is_status(err) then return err end
    return {plain = err, traceback = debug.traceback(tostring(err), 2)}
end

-- status_result(st) -> nil, code, message, details_bin: what an http2
-- handler returns to fail the call with the status object `st`.
-- `details_bin` (the grpc-status-details-bin trailer) is a
-- google.rpc.Status carrying the same code and message, as gRPC clients
-- expect; it is sent only when the status has details.
local function status_result(st)
    local code, message = st.code, st.message
    if code == CODE.OK then
        -- A failure that claims success: a client would read OK with no
        -- response message. grpc-go treats an OK status error the same.
        log.error('pb.server: a handler raised a status with code OK: %s', tostring(st))
        return nil, CODE.INTERNAL, 'internal error'
    end
    local details_bin
    if st.details ~= nil and #st.details > 0 then
        local ok, bin = pcall(grpc.encode_status, st)
        if ok then
            details_bin = bin
        else
            log.error('pb.server: cannot encode the details of %s: %s',
                      tostring(st), tostring(bin))
        end
    end
    return nil, code, message, details_bin
end
M._status_result = status_result

-- failure(ctx, err) -> nil, code, message[, details_bin] for an error
-- raised by a handler (as caught by `capture`). A status object keeps
-- its code; anything else is INTERNAL with a generic message, the real
-- error going to the log only.
local function failure(ctx, err)
    if grpc.is_status(err) then return status_result(err) end
    local method = type(ctx) == 'table' and ctx.method or '?'
    local text = type(err) == 'table' and err.traceback or tostring(err)
    if type(ctx) == 'table' and type(ctx.is_cancelled) == 'function'
            and ctx:is_cancelled() then
        -- The call is decided (client reset, deadline): nothing reaches
        -- the client any more, and a handler failing because its stream
        -- went away is expected.
        log.verbose('pb.server: %s failed after the call ended: %s', method, text)
    else
        log.error('pb.server: %s failed: %s', method, text)
    end
    return nil, CODE.INTERNAL, 'internal error'
end
M._failure = failure

-- ---------------------------------------------------------------------------
-- Handler adapters
-- ---------------------------------------------------------------------------

-- unary_handler(fn) -> http2 unary handler over a generated
-- `methods[path]` function (req_bytes, ctx) -> resp_bytes. Like
-- pb.transcode, it also accepts a hand-written function that returns
-- `nil, code[, message]` instead of raising.
function M._unary_handler(fn)
    return function(ctx, req_bytes)
        if type(ctx) == 'table' then ctx.protocol = 'grpc' end
        local ok, resp, code, message = xpcall(fn, capture, req_bytes, ctx)
        if not ok then return failure(ctx, resp) end
        if resp == nil and code ~= nil then
            local st = code
            if not grpc.is_status(st) then
                local built
                ok, built = pcall(grpc.status, code, message)
                if not ok then return failure(ctx, built) end
                st = built
            end
            return status_result(st)
        end
        if resp ~= nil and type(resp) ~= 'string' then
            return failure(ctx, ('handler returned a %s, expected bytes'):format(type(resp)))
        end
        return resp
    end
end

-- http2 reports why a stream ended with its own strings; the server view
-- speaks pb.grpc's: 'canceled' as the in-process transports say it (a
-- handler such as pb.reflection ends quietly on it) and a
-- DEADLINE_EXCEEDED status object for a passed deadline.
local function view_error(err)
    if err == 'deadline exceeded' then
        return grpc.status(CODE.DEADLINE_EXCEEDED, 'deadline exceeded')
    end
    if err == 'cancelled' or err == 'call closed' then return 'canceled' end
    return err
end

-- stream_view(stream) -> the raw server-side stream the generated
-- streaming wrappers expect (pb.grpc.wrap_server_view), over an http2
-- Stream:
--
--   view:recv() -> bytes | nil, nil (client half-closed) | nil, err
--   view:send(bytes) -> true | false (the call is gone)
--   view:is_cancelled() -> boolean
function M._stream_view(stream)
    local view = {}
    function view:recv()
        while true do
            local bytes, err = stream:recv(M.RECV_SLICE)
            if bytes ~= nil then return bytes, nil end
            if err == nil then return nil, nil end
            if err ~= 'timeout' then return nil, view_error(err) end
        end
    end
    function view:send(bytes)
        local ok, err = stream:send(bytes)
        if ok then return true end
        if err == 'message too large' then
            -- The call is still open: fail it the way grpc-go's SendMsg
            -- does, through the handler.
            grpc.error(CODE.RESOURCE_EXHAUSTED,
                ('trying to send message larger than max (%d bytes)'):format(#bytes))
        end
        return false
    end
    function view:is_cancelled()
        return stream:is_cancelled()
    end
    return view
end

-- stream_handler(entry) -> http2 streaming handler over a generated
-- `streams[path]` entry {kind, handler(req_bytes, view, ctx)}. A
-- server-streaming call reads its one request message and the client's
-- half-close first: another number of messages is a cardinality
-- violation, UNIMPLEMENTED by the gRPC status code table. The handler
-- returning ends the call with OK (http2 closes the stream); a raised
-- status object ends it with that status.
function M._stream_handler(entry)
    local kind, handler = entry.kind, entry.handler
    return function(ctx, stream)
        if type(ctx) == 'table' then ctx.protocol = 'grpc' end
        local view = M._stream_view(stream)
        local req_bytes
        if kind == 'server_stream' then
            local err
            req_bytes, err = view:recv()
            if req_bytes == nil then
                if err == nil then
                    return nil, CODE.UNIMPLEMENTED,
                        'server-streaming call received no request message'
                end
                return -- the call already ended (reset, deadline)
            end
            local more
            more, err = view:recv()
            if more ~= nil then
                return nil, CODE.UNIMPLEMENTED,
                    'server-streaming call received more than one request message'
            end
            if err ~= nil then return end -- the call already ended
        end
        local ok, err = xpcall(handler, capture, req_bytes, view, ctx)
        if ok then return end
        return failure(ctx, err)
    end
end

-- ---------------------------------------------------------------------------
-- Services
-- ---------------------------------------------------------------------------

local function check_server(srv, where)
    if type(srv) ~= 'table' or type(srv.service) ~= 'table'
            or type(srv.service.name) ~= 'string' or type(srv.methods) ~= 'table' then
        error(('pb.server.new: %s is not a generated server table '
            .. '(the result of M.<Service>_server(impl))'):format(where), 3)
    end
end

local function split_path(path, where)
    local service, method = tostring(path):match('^/([^/]+)/([^/]+)$')
    if service == nil then
        error(('pb.server.new: %s: malformed method path %q'):format(where, tostring(path)), 3)
    end
    return service, method
end

-- collect(servers) -> unary, streaming: http2 handler tables keyed by
-- service full name, then method name. Paths come from the server
-- tables' own keys ('/pkg.Service/Method'). A path served twice is an
-- error.
function M._collect(servers)
    local unary, streaming, owner = {}, {}, {}
    local function claim(path, i)
        if owner[path] ~= nil then
            error(('pb.server.new: duplicate method %s (services[%d] and services[%d])')
                :format(path, owner[path], i), 3)
        end
        owner[path] = i
    end
    for i, srv in ipairs(servers) do
        local where = ('services[%d]'):format(i)
        check_server(srv, where)
        for path, fn in pairs(srv.methods) do
            local service, method = split_path(path, where)
            claim(path, i)
            unary[service] = unary[service] or {}
            unary[service][method] = M._unary_handler(fn)
        end
        for path, entry in pairs(srv.streams or {}) do
            local service, method = split_path(path, where)
            if type(entry) ~= 'table' or type(entry.handler) ~= 'function' then
                error(('pb.server.new: %s: streaming entry %s has no handler')
                    :format(where, path), 3)
            end
            claim(path, i)
            streaming[service] = streaming[service] or {}
            streaming[service][method] = M._stream_handler(entry)
        end
    end
    return unary, streaming
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

-- http_handler(router, fallback, connect) -> http2 HTTP handler. In
-- order:
--
--   1. a request that can only be Connect (pb.connect's `strong`
--      match: a protobuf or enveloped content-type, a
--      Connect-Protocol-Version header, a `connect` query), served or
--      rejected by Connect (415/405 when it cannot serve it), never
--      passed on;
--   2. the transcoding router;
--   3. any other Connect call (a plain JSON POST or GET to a procedure
--      path, which an HTTP/JSON rule for the same path takes first);
--   4. the user's fallback;
--   5. for a procedure path, the Connect rejection (415 for a wrong
--      content-type, 405 for a wrong method);
--   6. a 404: in the Connect error shape for a request that is plainly
--      Connect, in the google.rpc.Status JSON shape otherwise.
--
-- Transcoded calls get the ctx pb.transcode builds from the request
-- (metadata from its headers, its peer, no deadline); Connect calls the
-- one pb.connect builds (with Connect-Timeout-Ms as the deadline).
--
-- The 404 is rendered by the router itself, so it follows the same JSON
-- options as the router's own errors (`details: []` under the defaults,
-- omitted with emit_defaults = false). Without transcoding, a router
-- with no routes and default options renders it.
function M._http_handler(router, fallback, connect)
    local renderer = router or require('pb.transcode').new({})
    local function not_found(req)
        local path = tostring(req.path or ''):match('^[^?#]*')
        return renderer:status_response(grpc.status(CODE.NOT_FOUND,
            ('no route for %s %s'):format(tostring(req.method), path)))
    end
    return function(req)
        local call = connect ~= nil and connect:match(req) or nil
        if call ~= nil and call.strong then return connect:serve(call, req) end
        if router ~= nil then
            local resp = router:handle(req)
            if resp ~= nil then return resp end
        end
        if call ~= nil then return connect:serve(call, req) end
        if fallback ~= nil then
            local resp = fallback(req)
            if resp ~= nil then return resp end
        end
        if connect ~= nil then
            local resp = connect:reject(req) or connect:not_found(req)
            if resp ~= nil then return resp end
        end
        return not_found(req)
    end
end

-- ---------------------------------------------------------------------------
-- The server
-- ---------------------------------------------------------------------------

local OPTIONS = {
    listen = true, host = true, port = true, services = true,
    reflection = true, health = true, transcoding = true, connect = true,
    http = true, limits = true,
}

local function parse_listen(opts)
    local host, port = opts.host, opts.port
    local listen = opts.listen
    if listen ~= nil then
        if host ~= nil or port ~= nil then
            error('pb.server.new: give either listen or host/port, not both', 3)
        end
        if type(listen) == 'number' then
            port = listen
        elseif type(listen) == 'string' then
            local h, p = listen:match('^%[(.*)%]:(%d+)$')
            if h == nil then h, p = listen:match('^(.*):(%d+)$') end
            if h == nil then
                error(("pb.server.new: listen must be 'host:port', got %q"):format(listen), 3)
            end
            host, port = h, tonumber(p)
        else
            error('pb.server.new: listen must be a string or a port number', 3)
        end
    end
    if host == nil or host == '' then host = '0.0.0.0' end
    if type(host) ~= 'string' then
        error('pb.server.new: host must be a string', 3)
    end
    if type(port) ~= 'number' or port < 0 or port > 65535 or port % 1 ~= 0 then
        error('pb.server.new: a port is required (listen = \'host:port\' or port = n; 0 picks a free one)', 3)
    end
    return host, port
end

local function load_http2()
    local ok, http2 = pcall(require, 'http2')
    if not ok then
        error('pb.server: the tarantool-http2 rock is required to serve gRPC and '
            .. 'HTTP (it needs the system libnghttp2 library); require(\'http2\') '
            .. 'failed: ' .. tostring(http2), 3)
    end
    return http2
end

local Server = {}
Server.__index = Server

---@class pb.ServerOpts
---@field listen?      string|integer  'host:port' ('[::1]:port' for IPv6) or a port
---@field host?        string          instead of listen; default '0.0.0.0'
---@field port?        integer         instead of listen; 0 picks a free port
---@field services     table[]         generated server tables (M.<Svc>_server(impl))
---@field reflection?  boolean         serve grpc.reflection v1 + v1alpha (default true)
---@field health?      boolean|table   serve grpc.health.v1 (default true); a table is pb.health.new's opts
---@field transcoding? boolean|table   google.api.http routes (default true); a table is pb.transcode.new's opts
---@field connect?     boolean|table   the Connect protocol (default true); a table is pb.connect.new's opts
---@field http?        fun(req: table): table?  fallback for HTTP requests nothing routed
---@field limits?      table           http2 limits: registry keys to http2.grpc.new, the rest to http2.server.new

-- new(opts) -> server (not listening yet; see start()).
---@param opts pb.ServerOpts
function M.new(opts)
    if type(opts) ~= 'table' then
        error('pb.server.new: opts must be a table', 2)
    end
    for k in pairs(opts) do
        if not OPTIONS[k] then
            error(('pb.server.new: unknown option %q'):format(tostring(k)), 2)
        end
    end
    local host, port = parse_listen(opts)
    if type(opts.services) ~= 'table' then
        error('pb.server.new: services must be an array of generated server tables', 2)
    end
    for _, k in ipairs({'reflection'}) do
        if opts[k] ~= nil and type(opts[k]) ~= 'boolean' then
            error(('pb.server.new: %s must be a boolean'):format(k), 2)
        end
    end
    for _, k in ipairs({'health', 'transcoding', 'connect'}) do
        local v = opts[k]
        if v ~= nil and type(v) ~= 'boolean' and type(v) ~= 'table' then
            error(('pb.server.new: %s must be a boolean or an options table'):format(k), 2)
        end
    end
    if opts.http ~= nil and type(opts.http) ~= 'function' then
        error('pb.server.new: http must be a function(req) -> resp', 2)
    end
    if opts.limits ~= nil and type(opts.limits) ~= 'table' then
        error('pb.server.new: limits must be a table', 2)
    end

    local user = {}
    for i, srv in ipairs(opts.services) do
        check_server(srv, ('services[%d]'):format(i))
        user[i] = srv
    end

    local self = setmetatable({_host = host, _port = port, _user = user}, Server)
    local all = {}
    for i, srv in ipairs(user) do all[i] = srv end

    if opts.health ~= false then
        local hopts = type(opts.health) == 'table' and opts.health or nil
        self._health = require('pb.health').new(hopts)
        all[#all + 1] = self._health:server()
    end
    if opts.reflection ~= false then
        -- A function, so list_services reads the final list, the
        -- reflection services themselves included.
        local refl = require('pb.reflection').new({services = function() return all end})
        for _, srv in ipairs(refl:servers()) do all[#all + 1] = srv end
        self._reflection = refl
    end
    self._services = all

    local unary, streaming = M._collect(all)

    if self._health ~= nil then
        for _, srv in ipairs(user) do self._health:set(srv.service.name, 'SERVING') end
    end

    local router
    if opts.transcoding ~= false then
        local topts = type(opts.transcoding) == 'table' and opts.transcoding or nil
        router = require('pb.transcode').new(user, topts)
    end
    self._router = router

    -- Connect serves every service the gRPC registry does, reflection
    -- and health included, with the registry's receive limit.
    local connect
    if opts.connect ~= false then
        local copts = {}
        if type(opts.connect) == 'table' then
            for k, v in pairs(opts.connect) do copts[k] = v end
        end
        if copts.max_recv_message_size == nil and opts.limits ~= nil then
            copts.max_recv_message_size = opts.limits.max_recv_message_size
        end
        connect = require('pb.connect').new(all, copts)
    end
    self._connect = connect

    local http2 = load_http2()
    local reg_limits, srv_limits = {}, {}
    for k, v in pairs(opts.limits or {}) do
        if REGISTRY_LIMITS[k] then reg_limits[k] = v else srv_limits[k] = v end
    end
    local registry = http2.grpc.new(reg_limits)
    for service, handlers in pairs(unary) do
        registry:register_service(service, handlers)
    end
    for service, handlers in pairs(streaming) do
        registry:register_streaming_service(service, handlers)
    end
    self._registry = registry
    self._http2 = http2.server.new({
        grpc = registry,
        http = M._http_handler(router, opts.http, connect),
        -- Connect streaming calls take the streaming handler contract:
        -- messages are read as they arrive and each reply goes out as
        -- it is sent, full duplex on HTTP/2. Everything else (unary
        -- Connect, transcoding, the fallback) stays on `http`, buffered.
        http_stream = connect ~= nil and function(head)
            return connect:stream_handler(head)
        end or nil,
        limits = srv_limits,
    })
    return self
end

-- start() binds the listener and starts serving; raises when the
-- address cannot be bound. Returns the server.
function Server:start()
    if self._http2:address() ~= nil then
        error('pb.server: already started', 2)
    end
    if self._health ~= nil and self._stopped then self._health:resume() end
    local ok, err = pcall(self._http2.listen, self._http2, self._host, self._port)
    if not ok then error(err, 2) end
    self._stopped = false
    return self
end

-- address() -> {host = ..., port = ...} of the listener, nil when not
-- started. With port 0 this is where the chosen port shows.
function Server:address()
    return self._http2:address()
end

-- health() -> the pb.health instance, nil when health is disabled.
function Server:health()
    return self._health
end

-- reflection() -> the pb.reflection instance, nil when disabled.
function Server:reflection()
    return self._reflection
end

-- router() -> the pb.transcode router, nil when transcoding is disabled.
function Server:router()
    return self._router
end

-- connect() -> the pb.connect handler, nil when Connect is disabled.
function Server:connect()
    return self._connect
end

-- set_serving_status(service, status) sets the health status of a
-- service ('' for the whole server): 'SERVING', 'NOT_SERVING', ...
-- Returns false after stop() (pb.health ignores changes while shut down).
function Server:set_serving_status(service, status)
    if self._health == nil then
        error('pb.server: health is disabled', 2)
    end
    return self._health:set(service, status)
end

-- stop(timeout) marks every service NOT_SERVING, so Watch callers hear
-- it before the server goes, then stops http2: no new connections,
-- GOAWAY, in-flight calls get up to `timeout` seconds (default 5).
function Server:stop(timeout)
    if self._health ~= nil then
        self._health:shutdown()
        -- Let the Watch fibers woken by shutdown() queue NOT_SERVING
        -- before the GOAWAY.
        fiber.yield()
    end
    self._stopped = true
    self._http2:stop(timeout)
end

return M
