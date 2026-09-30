-- pb.health: the gRPC health service (grpc.health.v1.Health).
--
--   local h = pb.health.new()
--   h:set('hello.Greeter', 'SERVING')
--   local transport = pb.grpc.multiplex({greeter_srv, h:server()})
--
-- Semantics follow grpc-go's health server
-- (google.golang.org/grpc/health):
--
--   * The overall server status is the empty service name '', SERVING
--     from the start.
--   * Check answers the stored status, or fails with NOT_FOUND for a
--     service never set.
--   * List answers every stored status; more than MAX_LIST services
--     fail with RESOURCE_EXHAUSTED.
--   * Watch sends the current status at once (SERVICE_UNKNOWN for a
--     service never set, without failing the call), then every change,
--     until the caller cancels. Repeated identical statuses are sent
--     once.
--   * shutdown() sets every service NOT_SERVING and ignores later set()
--     calls until resume(), which sets every service SERVING.
--
-- Each Watch call waits on its own fiber.cond, signalled by set(). It
-- also wakes every `poll_interval` seconds to notice a caller that went
-- away while nothing changed, so a cancelled watch never outlives the
-- interval.
local fiber = require('fiber')
local grpc  = require('pb.grpc')
local gen   = require('pb.gen.grpc.health.v1.health_pb')

local M = {}

M.SERVICE = gen.Health_service.name
M.MAX_LIST = 100
M.DEFAULT_POLL_INTERVAL = 1

-- name -> number and number -> name for HealthCheckResponse.ServingStatus.
M.status = {}
local STATUS_NAME = {}
for name, num in pairs(gen.HealthCheckResponse_ServingStatus) do
    M.status[name] = num
    STATUS_NAME[num] = name
end

local SERVING         = M.status.SERVING
local NOT_SERVING     = M.status.NOT_SERVING
local SERVICE_UNKNOWN = M.status.SERVICE_UNKNOWN

local function to_status(v, fname)
    if type(v) == 'string' then
        local n = M.status[v]
        if n ~= nil then return n end
    elseif type(v) == 'number' and STATUS_NAME[v] ~= nil then
        return v
    end
    error(('pb.health.%s: unknown serving status %s (expected one of '
        .. 'SERVING, NOT_SERVING, SERVICE_UNKNOWN, UNKNOWN)')
        :format(fname, tostring(v)), 3)
end

local function check_service(service, fname)
    if type(service) ~= 'string' then
        error(('pb.health.%s: service must be a string, got %s')
            :format(fname, type(service)), 3)
    end
end

local Health = {}
Health.__index = Health

function Health:_store(service, status)
    self._status[service] = status
    local watchers = self._watchers[service]
    if watchers ~= nil then
        for cond in pairs(watchers) do cond:broadcast() end
    end
end

-- set(service, status) -> true, or false when ignored after shutdown().
-- `service` '' is the whole server; `status` is a ServingStatus name
-- ('SERVING', 'NOT_SERVING', 'SERVICE_UNKNOWN', 'UNKNOWN') or number.
---@param service string
---@param status string|integer
---@return boolean
function Health:set(service, status)
    check_service(service, 'set')
    status = to_status(status, 'set')
    if self._shutdown then return false end
    self:_store(service, status)
    return true
end

-- get(service) -> status name, or nil for a service never set.
---@param service string
---@return string?
function Health:get(service)
    check_service(service, 'get')
    local st = self._status[service]
    return st and STATUS_NAME[st]
end

-- shutdown() marks every service NOT_SERVING and ignores set() until
-- resume(); for draining a server before it stops.
function Health:shutdown()
    self._shutdown = true
    for service in pairs(self._status) do self:_store(service, NOT_SERVING) end
end

-- resume() undoes shutdown(): every service SERVING, set() works again.
function Health:resume()
    self._shutdown = false
    for service in pairs(self._status) do self:_store(service, SERVING) end
end

-- watchers(service) -> number of Watch calls currently open for it.
---@param service string
---@return integer
function Health:watchers(service)
    local n = 0
    for _ in pairs(self._watchers[service] or {}) do n = n + 1 end
    return n
end

local function cancelled(stream, ctx)
    if type(ctx) == 'table' and type(ctx.is_cancelled) == 'function'
            and ctx:is_cancelled() then
        return true
    end
    return stream.is_cancelled ~= nil and stream:is_cancelled()
end

function Health:_watch_loop(service, cond, stream, ctx)
    local last
    while true do
        local st = self._status[service] or SERVICE_UNKNOWN
        if st ~= last then
            -- false: the transport knows the caller is gone. On the
            -- loopback cancelled() below says the same; a transport
            -- that only reports it through send() relies on this.
            if stream:send({status = st}) == false then return end
            last = st
        end
        if cancelled(stream, ctx) then return end
        -- A set() while send() yielded broadcast to nobody: fiber.cond
        -- has no memory. Wait only when nothing changed since the last
        -- send, so such a change goes out now, not a poll interval later.
        if (self._status[service] or SERVICE_UNKNOWN) == last then
            cond:wait(self._poll_interval)
            fiber.testcancel()
        end
    end
end

function Health:_watch(req, stream, ctx)
    local service = req.service or ''
    local cond = fiber.cond()
    local watchers = self._watchers[service]
    if watchers == nil then
        watchers = {}
        self._watchers[service] = watchers
    end
    watchers[cond] = true
    local ok, err = pcall(self._watch_loop, self, service, cond, stream, ctx)
    watchers[cond] = nil
    if next(watchers) == nil and self._watchers[service] == watchers then
        self._watchers[service] = nil
    end
    if not ok then error(err, 0) end
end

function Health:_check(req)
    local st = self._status[req.service or '']
    if st == nil then grpc.error(grpc.code.NOT_FOUND, 'unknown service') end
    return {status = st}
end

function Health:_list()
    local statuses, n = {}, 0
    for service, st in pairs(self._status) do
        statuses[service] = {status = st}
        n = n + 1
    end
    if n > M.MAX_LIST then
        grpc.error(grpc.code.RESOURCE_EXHAUSTED,
            ('server health list exceeds maximum capacity: %d'):format(M.MAX_LIST))
    end
    return {statuses = statuses}
end

-- server() -> a server table (the shape M.<Service>_server returns) for
-- grpc.health.v1.Health, backed by this instance.
---@return table
function Health:server()
    return gen.Health_server({
        Check = function(req) return self:_check(req) end,
        List  = function() return self:_list() end,
        Watch = function(req, stream, ctx) return self:_watch(req, stream, ctx) end,
    })
end

-- new(opts?) -> health instance with the whole server ('') SERVING.
--
-- opts.poll_interval: seconds a Watch call waits between checks that its
-- caller is still there when no status changes (default 1).
---@param opts? {poll_interval?: number}
function M.new(opts)
    opts = opts or {}
    local poll = opts.poll_interval or M.DEFAULT_POLL_INTERVAL
    if type(poll) ~= 'number' or poll <= 0 then
        error('pb.health.new: opts.poll_interval must be a positive number', 2)
    end
    return setmetatable({
        _status = {[''] = SERVING},
        _watchers = {},
        _shutdown = false,
        _poll_interval = poll,
    }, Health)
end

return M
