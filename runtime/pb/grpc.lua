-- gRPC transport interface + reference loopback / multiplex implementations.
--
-- # Transport contract
--
-- Unary:
--   transport:unary(path, req_bytes, ctx) -> resp_bytes
--
-- Streaming (three flavors). Each returns a `client_view` stream object
-- — see "Stream object" below.
--   transport:server_stream(path, req_bytes, ctx) -> stream
--   transport:client_stream(path, ctx)            -> stream
--   transport:bidi(path, ctx)                     -> stream
--
-- # Stream object (client view)
--
-- Methods that may be called by the caller side (the gRPC client):
--   stream:send(bytes)           -- push a message (client_stream, bidi)
--   stream:close_send()          -- signal "no more outgoing messages"
--   stream:recv() -> bytes, err  -- pull next reply; (nil, err_or_nil) ends
--   stream:cancel()              -- abort the call, drop pending messages
--
-- For server_stream, `send` and `close_send` are no-ops (initial request
-- is conveyed via the call's req_bytes argument).
--
-- # Server-side stream view
--
-- Generated server code passes a "server_view" object to the user handler:
--   server_view:send(bytes)           -- push a reply (server_stream, bidi)
--   server_view:recv() -> bytes, err  -- pull next request (client_stream, bidi)
--
-- The handler signals end-of-stream by returning. Errors thrown via
-- `error(...)` propagate to the client as the `err` returned by `recv()`.
--
-- # Real transports
--
-- HTTP/2, net.box-tunneled, IProto — those live in separate packages.
-- This module ships only loopback + multiplex, intended for tests and
-- in-process apps.
local fiber = require('fiber')

local M = {}

-- Default channel buffer size for in-process streams. Senders block when
-- the buffer is full; receivers block when it's empty. 16 messages is a
-- compromise between sender/receiver decoupling and memory footprint for
-- payload backlog. Override per call site via new_stream_pair(buf_size).
local DEFAULT_BUFFER = 16

-- Internal: shared state between the two stream views.
local function new_state()
    return {
        -- Recorded by server-side fiber when handler raises. Surfaced to
        -- client via the `err` return of recv() once the reply channel
        -- drains.
        server_err = nil,
        -- Set by client cancel(); the server side checks this on send and
        -- treats it as an abort signal.
        canceled = false,
    }
end

-- new_stream_pair(buf_size?) -> client_view, server_view, internal_state
--
-- Returns two opposed views of a bidirectional message pipe. Used by
-- loopback to bridge an in-process server fiber with a client caller.
-- The returned `internal_state` is exposed so the transport (not the
-- caller) can flag errors and trigger close.
---@param buf_size? integer       fiber.channel capacity; defaults to DEFAULT_BUFFER
---@return table client            speaks send / close_send / recv / cancel
---@return table server            speaks recv / send / _finish / _force_close_recv
---@return table internal_state    shared {canceled, server_err} accessed by the transport
function M.new_stream_pair(buf_size)
    buf_size = buf_size or DEFAULT_BUFFER
    local c2s = fiber.channel(buf_size)  -- client -> server
    local s2c = fiber.channel(buf_size)  -- server -> client
    local state = new_state()

    -- Client-facing view
    local client = {}

    function client:send(bytes)
        if c2s:is_closed() then
            error('pb.grpc: send after close_send', 0)
        end
        if state.canceled then
            error('pb.grpc: stream canceled', 0)
        end
        c2s:put(bytes)
    end

    function client:close_send()
        if not c2s:is_closed() then c2s:close() end
    end

    function client:recv()
        local b = s2c:get()
        if b == nil then
            -- Either drained naturally or a server-side error closed it.
            return nil, state.server_err
        end
        return b, nil
    end

    function client:cancel()
        state.canceled = true
        if not c2s:is_closed() then c2s:close() end
        -- We deliberately do NOT close s2c here. The handler fiber may
        -- still write to it; closing under their feet would raise. Drain
        -- on the next recv (which will see `canceled`).
    end

    -- Server-facing view (used by the handler running on a worker fiber)
    local server = {}

    function server:recv()
        if state.canceled then return nil, 'canceled' end
        local b = c2s:get()
        if b == nil then return nil, nil end
        return b, nil
    end

    function server:send(bytes)
        if state.canceled then
            -- Caller gave up — silently drop, don't error in the handler.
            return false
        end
        if s2c:is_closed() then return false end
        s2c:put(bytes)
        return true
    end

    -- Internal: invoked by the transport, not by user code.
    function server:_finish(err)
        if err ~= nil then state.server_err = tostring(err) end
        if not s2c:is_closed() then s2c:close() end
    end

    function server:_force_close_recv()
        -- Used by server_stream call where there's no client->server
        -- channel; closing c2s up-front means server:recv() returns nil
        -- immediately if (erroneously) called.
        if not c2s:is_closed() then c2s:close() end
    end

    return client, server, state
end

-- ---------------------------------------------------------------------------
-- Internal helpers used by loopback + multiplex
-- ---------------------------------------------------------------------------

local function dispatch_stream(streams, path, kind, req_bytes, ctx)
    local entry = streams and streams[path]
    if entry == nil then
        error(('pb.grpc: no streaming method registered for %q'):format(path), 0)
    end
    if entry.kind ~= kind then
        error(('pb.grpc: method %q is %s, called as %s')
            :format(path, entry.kind, kind), 0)
    end

    local client_view, server_view = M.new_stream_pair()
    if kind == 'server_stream' then
        -- No client->server messages after the initial request.
        server_view:_force_close_recv()
        client_view:close_send()
    end

    fiber.create(function()
        local ok, err = pcall(entry.handler, req_bytes, server_view, ctx or {})
        if ok then
            server_view:_finish(nil)
        else
            server_view:_finish(err)
        end
    end)

    return client_view
end

local function dispatch_unary(methods, path, req_bytes, ctx)
    local handler = methods and methods[path]
    if handler == nil then
        error(('pb.grpc: unknown unary method %q'):format(path), 0)
    end
    return handler(req_bytes, ctx or {})
end

-- ---------------------------------------------------------------------------
-- Public transports
-- ---------------------------------------------------------------------------

-- loopback(server) bridges an in-process M.<Service>_server(impl) result
-- into the transport contract. Streaming methods run their handler on a
-- worker fiber and communicate via fiber.channel.
---@param server pb.GrpcServer    output of `M.<Service>_server(impl)`
---@return pb.GrpcTransport
function M.loopback(server)
    if type(server) ~= 'table' or type(server.methods) ~= 'table' then
        error("pb.grpc.loopback: expected a server table from M.<Service>_server()", 0)
    end
    local methods = server.methods
    local streams = server.streams or {}
    return {
        unary = function(_, path, req_bytes, ctx)
            return dispatch_unary(methods, path, req_bytes, ctx)
        end,
        server_stream = function(_, path, req_bytes, ctx)
            return dispatch_stream(streams, path, 'server_stream', req_bytes, ctx)
        end,
        client_stream = function(_, path, ctx)
            return dispatch_stream(streams, path, 'client_stream', nil, ctx)
        end,
        bidi = function(_, path, ctx)
            return dispatch_stream(streams, path, 'bidi', nil, ctx)
        end,
    }
end

-- multiplex({server1, server2, ...}) merges several servers' methods +
-- streams under a single transport. Errors on duplicate paths.
---@param servers pb.GrpcServer[]
---@return pb.GrpcTransport
function M.multiplex(servers)
    local methods, streams = {}, {}
    for _, srv in ipairs(servers) do
        for path, handler in pairs(srv.methods or {}) do
            if methods[path] ~= nil then
                error(("pb.grpc.multiplex: duplicate unary route %q"):format(path), 0)
            end
            methods[path] = handler
        end
        for path, entry in pairs(srv.streams or {}) do
            if streams[path] ~= nil then
                error(("pb.grpc.multiplex: duplicate streaming route %q"):format(path), 0)
            end
            streams[path] = entry
        end
    end
    return {
        unary = function(_, path, req_bytes, ctx)
            return dispatch_unary(methods, path, req_bytes, ctx)
        end,
        server_stream = function(_, path, req_bytes, ctx)
            return dispatch_stream(streams, path, 'server_stream', req_bytes, ctx)
        end,
        client_stream = function(_, path, ctx)
            return dispatch_stream(streams, path, 'client_stream', nil, ctx)
        end,
        bidi = function(_, path, ctx)
            return dispatch_stream(streams, path, 'bidi', nil, ctx)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Helpers used by generated client code
-- ---------------------------------------------------------------------------
--
-- These wrap a transport-level (bytes) stream in a typed (decoded
-- messages) facade. Living in pb.grpc keeps the generated code small and
-- means we can refactor the streaming surface without re-running protoc.

-- Wrap a server-streaming call: caller calls stream:recv() until nil.
---@param raw table                                       transport-side stream view (bytes)
---@param output_decode fun(bytes: string): table         per-message decoder for the typed view
---@return table                                          {recv(self): msg?, err?; cancel(self)}
function M.wrap_server_stream(raw, output_decode)
    return {
        recv = function(_)
            local bytes, err = raw:recv()
            if bytes == nil then return nil, err end
            return output_decode(bytes), nil
        end,
        cancel = function(_) raw:cancel() end,
    }
end

-- Wrap a client-streaming or bidi call: caller sends + recvs.
---@param raw table                                       transport-side stream view (bytes)
---@param input_encode  fun(msg: table): string           per-message encoder for the typed view
---@param output_decode fun(bytes: string): table         per-message decoder for the typed view
---@return table                                          {send, close_send, recv, cancel}
function M.wrap_call(raw, input_encode, output_decode)
    return {
        send = function(_, msg)
            raw:send(input_encode(msg))
        end,
        close_send = function(_) raw:close_send() end,
        recv = function(_)
            local bytes, err = raw:recv()
            if bytes == nil then return nil, err end
            return output_decode(bytes), nil
        end,
        cancel = function(_) raw:cancel() end,
    }
end

-- Wrap a server-side stream view for the generated server handler:
-- the user-supplied impl is called with a stream that speaks decoded
-- messages, hiding the per-message encode/decode boundary.
---@param raw table                                              server-side stream view (bytes)
---@param input_decode?  fun(bytes: string): table               decoder for inbound messages (nil ⇒ server_stream: no inbound)
---@param output_encode? fun(msg: table): string                 encoder for outbound messages (nil ⇒ client_stream: no outbound)
---@return table                                                 {recv?, send?, close_send?, cancel}
function M.wrap_server_view(raw, input_decode, output_encode)
    local wrapped = {}
    if input_decode ~= nil then
        function wrapped:recv()
            local bytes, err = raw:recv()
            if bytes == nil then return nil, err end
            return input_decode(bytes), nil
        end
    end
    if output_encode ~= nil then
        function wrapped:send(msg) raw:send(output_encode(msg)) end
    end
    return wrapped
end

return M
