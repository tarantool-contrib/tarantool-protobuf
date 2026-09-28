-- net.box gRPC tunnel — STUB / illustrative.
--
-- This file shows the *shape* of a custom transport. It's not a
-- production net.box transport; the real one needs error mapping,
-- deadline enforcement, metadata round-tripping, and proper
-- streaming. This stub is intentionally minimal — under 80 lines so
-- you can read it top-to-bottom.
--
-- Pattern:
--   client side: transport:unary(path, req_bytes, ctx)
--                -> conn:call('grpc_dispatch', {path, req_bytes})
--                -> {ok, resp_bytes} | {err, msg}
--   server side: function grpc_dispatch(path, req_bytes)
--                -> route to the right M.<Service>_server method
--                -> return {true, resp_bytes} | {false, err_msg}

local fiber  = require('fiber')

local M = {}

-- Server-side: register a stored function that dispatches into a
-- gRPC server table (the result of M.<Service>_server(impl)).
function M.register_server(server, func_name)
    func_name = func_name or 'grpc_dispatch'

    -- box.session.push is the streaming primitive in net.box; this
    -- stub doesn't use it. Streaming would need separate functions
    -- or a stateful session.
    rawset(_G, func_name, function(path, req_bytes)
        local handler = server.methods[path]
        if handler == nil then
            return {false, 'unknown method: ' .. path}
        end
        local ok, resp = pcall(handler, req_bytes, {})
        if not ok then return {false, tostring(resp)} end
        return {true, resp}
    end)
end

-- Client-side: returns a transport object implementing the contract.
-- conn is a net.box connection (require('net.box').connect(...)).
function M.client(conn, func_name)
    func_name = func_name or 'grpc_dispatch'

    return {
        unary = function(_, path, req_bytes, _ctx)
            local result = conn:call(func_name, {path, req_bytes})
            if not result[1] then
                error('grpc: ' .. tostring(result[2]), 0)
            end
            return result[2]
        end,

        -- Streaming methods: error explicitly. A real transport
        -- would set up box.session.push or a dedicated stream
        -- function on the server side.
        server_stream = function() error('streaming not supported in stub', 0) end,
        client_stream = function() error('streaming not supported in stub', 0) end,
        bidi          = function() error('streaming not supported in stub', 0) end,
    }
end

return M
