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
-- # Status errors
--
-- A handler fails a call with a gRPC status by raising a status object:
--   pb.grpc.error(pb.grpc.code.NOT_FOUND, 'book 42')
-- The in-process transports hand the same object to the client: a unary
-- call re-raises it, a stream returns it as the `err` of `recv()`. Plain
-- (non-status) errors keep their pre-status behaviour: a unary call
-- re-raises them verbatim, a stream returns them as a string. Network
-- transports map plain errors to INTERNAL without leaking the text.
--
-- # Real transports
--
-- HTTP/2, net.box-tunneled, IProto — those live in separate packages.
-- This module ships only loopback + multiplex, intended for tests and
-- in-process apps.
local fiber = require('fiber')

local M = {}

-- ---------------------------------------------------------------------------
-- Canonical status codes
-- ---------------------------------------------------------------------------

-- The 17 canonical gRPC status codes, by name.
M.code = {
    OK                  = 0,
    CANCELLED           = 1,
    UNKNOWN             = 2,
    INVALID_ARGUMENT    = 3,
    DEADLINE_EXCEEDED   = 4,
    NOT_FOUND           = 5,
    ALREADY_EXISTS      = 6,
    PERMISSION_DENIED   = 7,
    RESOURCE_EXHAUSTED  = 8,
    FAILED_PRECONDITION = 9,
    ABORTED             = 10,
    OUT_OF_RANGE        = 11,
    UNIMPLEMENTED       = 12,
    INTERNAL            = 13,
    UNAVAILABLE         = 14,
    DATA_LOSS           = 15,
    UNAUTHENTICATED     = 16,
}

-- Reverse lookup: code number -> name.
M.code_name = {}
for name, num in pairs(M.code) do M.code_name[num] = name end

-- HTTP status an HTTP/JSON gateway answers with for each code (the
-- mapping Google APIs and grpc-gateway use). Codes outside the table
-- map to 500 at the call site.
M.http_status = {
    [0]  = 200,
    [1]  = 499,
    [2]  = 500,
    [3]  = 400,
    [4]  = 504,
    [5]  = 404,
    [6]  = 409,
    [7]  = 403,
    [8]  = 429,
    [9]  = 400,
    [10] = 409,
    [11] = 400,
    [12] = 501,
    [13] = 500,
    [14] = 503,
    [15] = 500,
    [16] = 401,
}

local status_mt = {}
status_mt.__index = status_mt

status_mt.__tostring = function(st)
    local name = M.code_name[st.code] or ('CODE_' .. tostring(st.code))
    if st.message == nil or st.message == '' then return name end
    return name .. ': ' .. st.message
end

local function resolve_code(code, fname)
    if type(code) == 'string' then
        local n = M.code[code]
        if n == nil then
            error(('pb.grpc.%s: unknown status code name %q'):format(fname, code), 3)
        end
        return n
    end
    if type(code) ~= 'number' or code < 0 or code % 1 ~= 0 then
        error(('pb.grpc.%s: code must be a non-negative integer or a code name, got %s')
            :format(fname, tostring(code)), 3)
    end
    return code
end

local function new_status(code, message, details, fname)
    code = resolve_code(code, fname)
    if message ~= nil and type(message) ~= 'string' then
        message = tostring(message)
    end
    if details ~= nil and type(details) ~= 'table' then
        error(('pb.grpc.%s: details must be an array of google.protobuf.Any tables')
            :format(fname), 3)
    end
    return setmetatable({
        code = code,
        message = message or '',
        details = details,
    }, status_mt)
end

-- status(code, message?, details?) -> status object, without raising.
--
-- `code` is a number or a name from pb.grpc.code. `details`, when given,
-- is an array of google.protobuf.Any tables `{type_url = ..., value =
-- <encoded bytes>}` — what pb.any.pack returns — the same shape the
-- `details` field of google.rpc.Status carries.
---@param code integer|string
---@param message? string
---@param details? table[]
---@return table status {code, message, details}
function M.status(code, message, details)
    return new_status(code, message, details, 'status')
end

-- error(code, message?, details?) raises a status object. A server
-- handler uses it to fail a call with a specific gRPC status.
---@param code integer|string
---@param message? string
---@param details? table[]
function M.error(code, message, details)
    error(new_status(code, message, details, 'error'))
end

-- is_status(v) -> true when v is a status object built by status/error.
function M.is_status(v)
    return type(v) == 'table' and getmetatable(v) == status_mt
end

-- google.rpc.Status, hand-built against the Any descriptor from pb.wkt.
-- Encoded, it is the value of the `grpc-status-details-bin` trailer.
local status_pb_desc

local function status_descriptor()
    if status_pb_desc ~= nil then return status_pb_desc end
    local wkt = require('pb.wkt')
    local codec = require('pb.codec')
    local desc = {
        name = 'google.rpc.Status',
        fields = {
            {name = 'code', id = 1, kind = 'scalar', proto_type = 'int32'},
            {name = 'message', id = 2, kind = 'scalar', proto_type = 'string'},
            {name = 'details', id = 3, kind = 'message',
             message = wkt.Any_descriptor, repeated = true},
        },
    }
    local fbi, fbn = {}, {}
    for _, f in ipairs(desc.fields) do
        fbi[f.id] = f
        fbn[f.name] = f
    end
    desc.field_by_id = fbi
    desc.field_by_name = fbn
    codec.compile_writers(desc)
    codec.compile_readers(desc)
    status_pb_desc = desc
    return desc
end

-- encode_status(st) -> google.rpc.Status wire bytes.
function M.encode_status(st)
    if not M.is_status(st) then
        error('pb.grpc.encode_status: expected a status object', 2)
    end
    return require('pb.codec').encode(status_descriptor(), {
        code = st.code,
        message = st.message,
        details = st.details,
    })
end

-- decode_status(bytes) -> status object from google.rpc.Status wire bytes.
function M.decode_status(bytes)
    local t = require('pb.codec').decode(status_descriptor(), bytes)
    local details = t.details
    if details ~= nil and #details == 0 then details = nil end
    return new_status(t.code or 0, t.message, details, 'decode_status')
end

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

    -- Internal: invoked by the transport, not by user code. A status
    -- object reaches the client unchanged; any other error value is
    -- stringified, as before status objects existed.
    function server:_finish(err)
        if err ~= nil then
            if M.is_status(err) then
                state.server_err = err
            else
                state.server_err = tostring(err)
            end
        end
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
        M.error(M.code.UNIMPLEMENTED,
            ('pb.grpc: no streaming method registered for %q'):format(path))
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
        M.error(M.code.UNIMPLEMENTED,
            ('pb.grpc: unknown unary method %q'):format(path))
    end
    -- A status object raised by the handler propagates unchanged: the
    -- handler runs on the caller's fiber, and error() keeps the table.
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
