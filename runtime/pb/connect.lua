-- pb.connect: the Connect protocol (https://connectrpc.com/docs/protocol)
-- for generated gRPC server tables, over buffered HTTP requests.
--
--   local h = require('pb.connect').new({greeter_pb.Greeter_server(impl)})
--   local resp = h:handle({method = 'POST', path = '/hello.Greeter/SayHello',
--                          headers = {['content-type'] = 'application/json'},
--                          body = '{"name": "Dave"}'})
--   -- resp = {status = 200, headers = {...}, body = '{"greeting":"Hello, Dave"}'}
--
-- Like pb.transcode it is a function over request/response tables, with
-- no sockets: pb.server calls it from its HTTP handler. It serves
--
--   * unary calls: POST with `application/proto` or `application/json`,
--     and GET (`?encoding=...&message=...`) for methods whose
--     idempotency_level is NO_SIDE_EFFECTS;
--   * streaming calls of all three kinds: POST with
--     `application/connect+proto` or `application/connect+json`, the
--     body a sequence of 5-byte-prefixed envelopes, the response ending
--     with an EndStreamResponse envelope.
--
-- The handlers, ctx and status objects are the ones the gRPC path uses:
-- a generated `methods[path]` / `streams[path]` handler cannot tell
-- which protocol called it (ctx.protocol says, for those who ask).
--
-- The HTTP handler contract of tarantool-http2 hands over a request
-- whose body has fully arrived and takes back a whole response. So a
-- streaming handler here reads envelopes already in memory and its
-- sends are collected into one response: wire-correct, but a
-- server-streaming reply is not delivered incrementally, and a
-- full-duplex bidi call (the client waits for a reply before it ends
-- its request) cannot work. The envelope I/O is kept behind a small
-- object (`buffered_io`) so a streaming transport can replace it
-- without touching the protocol logic.
local clock  = require('clock')
local fiber  = require('fiber')
local log    = require('log')
local json   = require('json')
local digest = require('digest')
local grpc   = require('pb.grpc')
local pbjson = require('pb.json')

local M = {}

local CODE = grpc.code

-- Connect error codes by gRPC code number. Connect has exactly these
-- sixteen; there are no user-defined codes.
M.code_name = {
    [1]  = 'canceled',
    [2]  = 'unknown',
    [3]  = 'invalid_argument',
    [4]  = 'deadline_exceeded',
    [5]  = 'not_found',
    [6]  = 'already_exists',
    [7]  = 'permission_denied',
    [8]  = 'resource_exhausted',
    [9]  = 'failed_precondition',
    [10] = 'aborted',
    [11] = 'out_of_range',
    [12] = 'unimplemented',
    [13] = 'internal',
    [14] = 'unavailable',
    [15] = 'data_loss',
    [16] = 'unauthenticated',
}

-- The HTTP status of a unary error, by gRPC code number: the fixed
-- table of the Connect protocol ("Error Codes"). It happens to equal
-- pb.grpc.http_status (the transcoding mapping) but is the protocol's
-- own, so it lives here.
M.http_status = {
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

-- Default largest request message, as grpc-go's (and the http2
-- registry's) default receive limit.
M.DEFAULT_MAX_RECV_MESSAGE_SIZE = 4 * 1024 * 1024

local ENVELOPE_COMPRESSED = 0x01
local ENVELOPE_END_STREAM = 0x02

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function split(s, sep)
    local out, pos = {}, 1
    while true do
        local i = s:find(sep, pos, true)
        if i == nil then
            out[#out + 1] = s:sub(pos)
            return out
        end
        out[#out + 1] = s:sub(pos, i - 1)
        pos = i + 1
    end
end

-- Query component: '+' is a space, then percent-decoding. nil when a
-- percent-escape is malformed.
local function form_decode(s)
    s = s:gsub('+', ' ')
    if not s:find('%', 1, true) then return s end
    local _, total = s:gsub('%%', '')
    local out, good = s:gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
    end)
    if good ~= total then return nil end
    return out
end

-- Strict base64: standard or URL-safe alphabet, padded or not. The
-- shape is checked first: digest.base64_decode skips junk silently.
local function decode_base64(s)
    local body, pad = s:match('^([%w+/_-]*)(=*)$')
    if body == nil then return nil end
    local rem = #body % 4
    if rem == 1 then return nil end
    if #pad > 0 and (rem == 0 or #pad ~= 4 - rem) then return nil end
    return digest.base64_decode(body)
end
M._decode_base64 = decode_base64

-- Unpadded standard base64, as the protocol asks implementations to
-- emit for binary metadata and error detail values.
local function encode_base64(s)
    return digest.base64_encode(s, {nopad = true, nowrap = true})
end

local function be32(n)
    return string.char(bit.band(bit.rshift(n, 24), 0xff), bit.band(bit.rshift(n, 16), 0xff),
                       bit.band(bit.rshift(n, 8), 0xff), bit.band(n, 0xff))
end

-- envelope(flags, payload) -> the 5-byte prefix and the payload.
function M.envelope(flags, payload)
    return string.char(flags) .. be32(#payload) .. payload
end

-- media_type(ct) -> lowercased type/subtype without parameters.
local function media_type(ct)
    if type(ct) ~= 'string' then return nil end
    return (ct:match('^%s*([^;%s]+)') or ''):lower()
end

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- The type name of an Any's type URL: everything after the last '/'.
local function any_type_name(url)
    return tostring(url or ''):match('([^/]*)$')
end

-- error_table(st) -> the Error object of the protocol as a Lua table
-- ready for json.encode: {code, message?, details?}. A code outside
-- the sixteen (a status pb.grpc accepts but Connect has no name for)
-- goes out as `unknown`.
function M.error_table(st)
    local out = {code = M.code_name[st.code] or 'unknown'}
    if st.message ~= nil and st.message ~= '' then out.message = st.message end
    if st.details ~= nil and #st.details > 0 then
        local details = {}
        for i, d in ipairs(st.details) do
            details[i] = {
                type = any_type_name(d.type_url),
                value = encode_base64(d.value or ''),
            }
        end
        out.details = details
    end
    return out
end

-- error_json(st) -> the Error object as JSON text.
function M.error_json(st)
    return json.encode(M.error_table(st))
end

-- Captures a traceback for plain errors; a status object passes as is.
local function capture(err)
    if grpc.is_status(err) then return err end
    return {plain = err, traceback = debug.traceback(tostring(err), 2)}
end

-- as_status(ctx, err) -> the status object a failure answers with. A
-- status keeps its code (except OK, which claims success without a
-- response: internal); anything else is `internal` with a generic
-- message, the real error going to the log only. The same rules as
-- pb.server applies to gRPC calls.
local function as_status(ctx, err)
    local method = ctx and ctx.method or '?'
    if grpc.is_status(err) then
        if err.code == CODE.OK then
            log.error('pb.connect: %s: a handler raised a status with code OK: %s',
                      method, tostring(err))
            return grpc.status(CODE.INTERNAL, 'internal error')
        end
        return err
    end
    local text = type(err) == 'table' and err.traceback or tostring(err)
    if ctx ~= nil and ctx:is_cancelled() then
        log.verbose('pb.connect: %s failed after the call ended: %s', method, text)
    else
        log.error('pb.connect: %s failed: %s', method, text)
    end
    return grpc.status(CODE.INTERNAL, 'internal error')
end

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------

-- Request headers that belong to the protocol or the transport, not to
-- the call's metadata.
local REQUEST_RESERVED = {
    ['content-type'] = true, ['content-length'] = true,
    ['content-encoding'] = true, ['accept-encoding'] = true,
    connection = true, ['keep-alive'] = true, ['proxy-connection'] = true,
    ['transfer-encoding'] = true, upgrade = true, te = true, trailer = true,
    host = true,
}

-- Response metadata keys a handler may not set.
local RESPONSE_RESERVED = {
    ['content-type'] = true, ['content-length'] = true,
    ['content-encoding'] = true, ['accept-encoding'] = true,
    connection = true, ['keep-alive'] = true, ['proxy-connection'] = true,
    ['transfer-encoding'] = true, upgrade = true, te = true, trailer = true,
    host = true, date = true, server = true,
}

-- request_metadata(headers) -> metadata | nil, status. Keys starting
-- with `connect-` are the protocol's; `-bin` values are base64 (padded
-- or not) and are decoded, each of a repeated key's values on its own
-- (http2 joins repeats with ', ', as for gRPC metadata).
function M.request_metadata(headers)
    local md = {}
    for k, v in pairs(headers or {}) do
        if type(k) == 'string' then
            local lk = k:lower()
            if not REQUEST_RESERVED[lk] and lk:sub(1, 8) ~= 'connect-' then
                if lk:sub(-4) == '-bin' then
                    local parts = {}
                    for i, p in ipairs(split(tostring(v), ',')) do
                        local raw = decode_base64((p:gsub('^%s+', ''):gsub('%s+$', '')))
                        if raw == nil then
                            return nil, grpc.status(CODE.INVALID_ARGUMENT,
                                ('invalid base64 in binary metadata %q'):format(lk))
                        end
                        parts[i] = raw
                    end
                    md[lk] = table.concat(parts, ', ')
                else
                    md[lk] = v
                end
            end
        end
    end
    return md
end

local warned = {}

local function warn_once(key, why)
    if warned[key] then return end
    warned[key] = true
    log.warn('pb.connect: metadata %q dropped: %s', key, why)
end

-- each_metadata(md, fn): fn(key, values) for every key of a response or
-- trailing metadata table the protocol can carry, values an array of
-- wire strings (`-bin` values base64-encoded).
local function each_metadata(md, fn)
    if type(md) ~= 'table' then return end
    for k, v in pairs(md) do
        local key = type(k) == 'string' and k:lower() or nil
        if key == nil or not key:match('^[0-9a-z_.-]+$') then
            warn_once(tostring(k), 'invalid key')
        elseif RESPONSE_RESERVED[key] or key:sub(1, 8) == 'connect-'
                or key:sub(1, 8) == 'trailer-' then
            warn_once(key, 'reserved key')
        else
            local list = type(v) == 'table' and v or {v}
            local out = {}
            local bin = key:sub(-4) == '-bin'
            for _, item in ipairs(list) do
                local s = tostring(item)
                if bin then
                    out[#out + 1] = encode_base64(s)
                elseif s:match('^[\32-\126]*$') then
                    out[#out + 1] = s
                else
                    warn_once(key, 'value is not printable ASCII (use a -bin key)')
                end
            end
            if #out > 0 then fn(key, out) end
        end
    end
end

-- add_headers(headers, md[, prefix]) copies metadata into response
-- headers, a repeated key as an array.
local function add_headers(headers, md, prefix)
    each_metadata(md, function(key, values)
        key = (prefix or '') .. key
        if #values == 1 then
            headers[key] = values[1]
        else
            headers[key] = values
        end
    end)
end
M._add_headers = add_headers

-- end_stream_json(st, trailing) -> the EndStreamResponse JSON text.
function M.end_stream_json(st, trailing)
    local parts = {}
    if st ~= nil then
        parts[#parts + 1] = '"error":' .. M.error_json(st)
    end
    local md = {}
    local any = false
    each_metadata(trailing, function(key, values)
        md[key] = values
        any = true
    end)
    if any then parts[#parts + 1] = '"metadata":' .. json.encode(md) end
    return '{' .. table.concat(parts, ',') .. '}'
end

-- ---------------------------------------------------------------------------
-- Timeouts
-- ---------------------------------------------------------------------------

-- parse_timeout(v) -> milliseconds | nil (absent) | false (malformed).
-- The protocol allows a positive integer of at most 10 digits.
function M.parse_timeout(v)
    if v == nil then return nil end
    v = tostring(v)
    if not v:match('^%d+$') or #v > 10 then return false end
    return tonumber(v)
end

-- ---------------------------------------------------------------------------
-- Codecs
-- ---------------------------------------------------------------------------

-- A codec turns a message on the wire into the protobuf bytes a
-- generated handler takes, and back. `proto` passes bytes through;
-- `json` goes through pb.json and the method's descriptors.
local function proto_decode(_, _, bytes) return bytes end
local function proto_encode(_, _, bytes) return bytes end

local function json_decode(h, desc, text)
    if text:match('^%s*$') then text = '{}' end
    local ok, t = pcall(pbjson.decode, desc, text, {ignore_unknown_fields = true})
    if not ok then
        local msg = tostring(t):gsub('^[^%s:]+:%d+: ', '')
        return nil, grpc.status(CODE.INVALID_ARGUMENT, 'invalid JSON message: ' .. msg)
    end
    local bytes
    ok, bytes = pcall(h._pb.encode, desc, t)
    if not ok then
        return nil, grpc.status(CODE.INVALID_ARGUMENT,
            'cannot encode message: ' .. tostring(bytes))
    end
    return bytes
end

-- A response the handler produced that does not decode is a server
-- bug: it raises, and the caller answers `internal`.
local function json_encode(h, desc, bytes)
    return pbjson.encode(desc, h._pb.decode(desc, bytes), h._json)
end

local CODECS = {
    proto = {name = 'proto', decode = proto_decode, encode = proto_encode},
    json = {name = 'json', decode = json_decode, encode = json_encode, needs_desc = true},
}

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local Handler = {}
Handler.__index = Handler

local JSON_OPTS = {
    use_proto_names = 'boolean',
    emit_defaults = 'boolean',
    always_emit_zero_value = 'boolean',
    emit_null_messages = 'boolean',
    indent = 'string',
}

---@class pb.ConnectOpts
---@field json? pb.JsonEncodeOpts            response JSON options (default: pb.json's defaults)
---@field max_recv_message_size? integer     largest request message in bytes (default 4 MiB)

-- new(servers, opts) -> handler
---@param servers table[]   generated server tables (M.<Svc>_server(impl))
---@param opts? pb.ConnectOpts
function M.new(servers, opts)
    if type(servers) ~= 'table' then
        error('pb.connect.new: servers must be an array of server tables', 2)
    end
    opts = opts or {}
    if type(opts) ~= 'table' then
        error('pb.connect.new: opts must be a table', 2)
    end
    for k in pairs(opts) do
        if k ~= 'json' and k ~= 'max_recv_message_size' then
            error(('pb.connect.new: unknown option %q'):format(tostring(k)), 2)
        end
    end
    local json_opts = {}
    if opts.json ~= nil then
        if type(opts.json) ~= 'table' then
            error('pb.connect.new: opts.json must be a table', 2)
        end
        for k, v in pairs(opts.json) do
            local want = JSON_OPTS[k]
            if want == nil then
                error(('pb.connect.new: unknown opts.json option %q'):format(tostring(k)), 2)
            end
            if type(v) ~= want then
                error(('pb.connect.new: opts.json.%s must be a %s, got %s')
                    :format(k, want, type(v)), 2)
            end
            json_opts[k] = v
        end
    end
    local limit = opts.max_recv_message_size or M.DEFAULT_MAX_RECV_MESSAGE_SIZE
    if type(limit) ~= 'number' or limit < 0 or limit % 1 ~= 0 then
        error('pb.connect.new: max_recv_message_size must be a non-negative integer', 2)
    end

    -- Procedures by path '/pkg.Service/Method'.
    local procs = {}
    for si, server in ipairs(servers) do
        if type(server) ~= 'table' or type(server.service) ~= 'table'
                or type(server.methods) ~= 'table' then
            error(('pb.connect.new: servers[%d] is not a generated server table'):format(si), 2)
        end
        local descs = {}
        for _, m in pairs(server.service.methods or {}) do
            if type(m) == 'table' and m.full_name ~= nil then descs[m.full_name] = m end
        end
        for path, fn in pairs(server.methods) do
            local m = descs[path] or {}
            procs[path] = {
                path = path, kind = 'unary', fn = fn,
                input = m.input, output = m.output,
                get = m.idempotency_level == 'NO_SIDE_EFFECTS',
            }
        end
        for path, entry in pairs(server.streams or {}) do
            local m = descs[path] or {}
            procs[path] = {
                path = path, kind = entry.kind, entry = entry,
                input = m.input, output = m.output,
            }
        end
    end

    return setmetatable({
        _procs = procs,
        _json = json_opts,
        _limit = limit,
        _pb = require('pb'),
    }, Handler)
end

-- ---------------------------------------------------------------------------
-- Request classification
-- ---------------------------------------------------------------------------

local function split_target(raw)
    local hpos = raw:find('#', 1, true)
    if hpos ~= nil then raw = raw:sub(1, hpos - 1) end
    local qpos = raw:find('?', 1, true)
    if qpos == nil then return raw, nil end
    return raw:sub(1, qpos - 1), raw:sub(qpos + 1)
end

-- parse_query(q) -> {name = {value, ...}} | nil (malformed escape).
function M.parse_query(q)
    local out = {}
    if q == nil or q == '' then return out end
    for _, pair in ipairs(split(q, '&')) do
        if pair ~= '' then
            local rk, rv = pair:match('^([^=]*)=(.*)$')
            if rk == nil then rk, rv = pair, '' end
            local k, v = form_decode(rk), form_decode(rv)
            if k == nil or v == nil then return nil end
            local list = out[k]
            if list == nil then list = {}; out[k] = list end
            list[#list + 1] = v
        end
    end
    return out
end

-- match(req) -> call | nil. A call is a request this handler serves:
--
--   call = {proc, mode = 'unary' | 'get' | 'stream', codec, query?,
--           strong = boolean}
--
-- `strong` means the request can only be Connect (a protobuf or
-- enveloped content-type, a Connect-Protocol-Version header, or a
-- `connect=v1` / `encoding=proto` query); a plain JSON POST or a JSON
-- GET without those markers could be meant for an HTTP/JSON route at
-- the same path, so pb.server lets the transcoding router try it first.
function Handler:match(req)
    if type(req) ~= 'table' or type(req.path) ~= 'string' then return nil end
    local path, query = split_target(req.path)
    local proc = self._procs[path]
    if proc == nil then return nil end
    local headers = req.headers or {}
    if req.method == 'POST' then
        local mt = media_type(headers['content-type'])
        if mt == nil then return nil end
        local marker = headers['connect-protocol-version'] ~= nil
        local sub = mt:match('^application/connect%+(.+)$')
        if sub ~= nil then
            local codec = CODECS[sub]
            if codec == nil or proc.kind == 'unary' then return nil end
            if codec.needs_desc and (proc.input == nil or proc.output == nil) then return nil end
            return {proc = proc, mode = 'stream', codec = codec, strong = true}
        end
        local codec = CODECS[mt:match('^application/(.+)$') or '']
        if codec == nil or proc.kind ~= 'unary' then return nil end
        if codec.needs_desc and (proc.input == nil or proc.output == nil) then return nil end
        return {proc = proc, mode = 'unary', codec = codec,
                strong = marker or codec.name ~= 'json'}
    elseif req.method == 'GET' then
        if proc.kind ~= 'unary' or not proc.get or query == nil then return nil end
        local params = M.parse_query(query)
        if params == nil or params.encoding == nil then return nil end
        local codec = CODECS[params.encoding[1]]
        if codec == nil then
            -- An unknown encoding is still a Connect GET: 415.
            return {proc = proc, mode = 'get', codec = nil, query = params, strong = true}
        end
        if codec.needs_desc and (proc.input == nil or proc.output == nil) then return nil end
        return {proc = proc, mode = 'get', codec = codec, query = params,
                strong = params.connect ~= nil or codec.name ~= 'json'}
    end
    return nil
end

-- reject(req) -> the response to a request for a procedure path that
-- is not a Connect call (a wrong method or content-type), or nil when
-- the path is no procedure. pb.server answers with it when nothing
-- else (transcoding, the fallback) took the request, instead of 404.
function Handler:reject(req)
    if type(req) ~= 'table' or type(req.path) ~= 'string' then return nil end
    local path = split_target(req.path)
    local proc = self._procs[path]
    if proc == nil then return nil end
    local get = proc.kind == 'unary' and proc.get
    if req.method == 'POST' or (req.method == 'GET' and get) then
        local accept
        if proc.kind == 'unary' then
            accept = 'application/proto, application/json'
        else
            accept = 'application/connect+proto, application/connect+json'
        end
        return {status = 415, headers = {['accept-post'] = accept}, body = ''}
    end
    return {status = 405, headers = {allow = get and 'GET, POST' or 'POST'}, body = ''}
end

-- not_found(req) -> a 404 in the Connect error shape for a request that
-- is plainly a Connect call (a Connect-Protocol-Version header, a
-- protobuf or enveloped content-type, a `connect=v1` query) to a path
-- that is no procedure; nil for anything else. A Connect client then
-- reads `unimplemented`, as the protocol's HTTP-to-code mapping infers
-- from 404, instead of failing to parse another error shape.
function Handler:not_found(req)
    if type(req) ~= 'table' or type(req.path) ~= 'string' then return nil end
    local headers = req.headers or {}
    local path, query = split_target(req.path)
    local mt = media_type(headers['content-type']) or ''
    local connect = headers['connect-protocol-version'] ~= nil
        or mt == 'application/proto' or mt:match('^application/connect%+') ~= nil
    if not connect and req.method == 'GET' and query ~= nil then
        local params = M.parse_query(query)
        connect = params ~= nil and params.connect ~= nil
    end
    if not connect then return nil end
    return {
        status = 404,
        headers = {['content-type'] = 'application/json'},
        body = M.error_json(grpc.status(CODE.UNIMPLEMENTED,
            ('no procedure %s %s'):format(tostring(req.method), path))),
    }
end

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

-- new_ctx(req, proc, extra) -> the ctx handlers get: the gRPC shape
-- (method, metadata, deadline, peer, response_metadata,
-- trailing_metadata, is_cancelled) plus `protocol = 'connect'` and
-- `connect = {get, codec, query}`.
-- Deadline decisions read a fresh monotonic clock: fiber.clock() is
-- cached per event-loop iteration, so a handler or an encode that burns
-- CPU without yielding would still see the time it started at. Both
-- count from the same origin (CLOCK_MONOTONIC), so ctx.deadline
-- compares with either.
local function now() return clock.monotonic() end

-- expired(state) -> true once the call is cancelled or its deadline has
-- passed; marks it cancelled then.
local function expired(state)
    if state.cancelled then return true end
    if state.deadline ~= nil and now() >= state.deadline then
        state.cancelled = true
        return true
    end
    return false
end

local function deadline_status()
    return grpc.status(CODE.DEADLINE_EXCEEDED, 'deadline exceeded')
end

local function new_ctx(req, proc, state, metadata, deadline, extra)
    return {
        method = proc.path,
        metadata = metadata,
        deadline = deadline,
        peer = req.peer,
        response_metadata = {},
        trailing_metadata = {},
        protocol = 'connect',
        connect = extra,
        is_cancelled = function() return expired(state) end,
    }
end

-- invoke(state, fn, ...) -> xpcall results of fn(...), or false and a
-- DEADLINE_EXCEEDED status when the call has a deadline and it passes
-- first. The handler then runs on in its own fiber (it is never
-- cancelled: it may be inside a box transaction; ctx:is_cancelled()
-- tells it to stop) and whatever it produces is dropped.
local function invoke(state, fn, ...)
    if state.deadline == nil then
        return xpcall(fn, capture, ...)
    end
    local left = state.deadline - now()
    if left <= 0 then
        state.cancelled = true
        return false, deadline_status()
    end
    local ch = fiber.channel(1)
    local args = {n = select('#', ...), ...}
    local f = fiber.new(function()
        local r = {xpcall(fn, capture, unpack(args, 1, args.n))}
        r.n = table.maxn(r)
        ch:put(r, 0)
    end)
    f:name('pb.connect ' .. tostring(state.method), {truncate = true})
    local r = ch:get(left)
    -- A result that arrives once the deadline has passed is dropped as
    -- well: a handler polling ctx:is_cancelled() returns right when the
    -- deadline passes and may wake before this wait does, and a handler
    -- that never yields is done before the wait could time out. (For a
    -- successful unary result the check after encoding would also catch
    -- it; a raised status is decided here alone.)
    if r == nil or expired(state) then
        state.cancelled = true
        return false, deadline_status()
    end
    return unpack(r, 1, r.n)
end

-- Common request checks. Returns state, ctx | nil, status.
function Handler:_begin(call, req, headers, encoding, version_ok)
    local proc = call.proc
    local state = {method = proc.path}
    if not version_ok then
        return nil, grpc.status(CODE.INVALID_ARGUMENT,
            'unsupported Connect protocol version (only 1 is supported)')
    end
    if encoding ~= nil and encoding ~= '' and encoding ~= 'identity' then
        return nil, grpc.status(CODE.UNIMPLEMENTED,
            ('unsupported compression %q: supported encodings are identity'):format(encoding))
    end
    local ms = M.parse_timeout(headers['connect-timeout-ms'])
    if ms == false then
        return nil, grpc.status(CODE.INVALID_ARGUMENT,
            ('invalid connect-timeout-ms %q'):format(tostring(headers['connect-timeout-ms'])))
    end
    if ms ~= nil then state.deadline = now() + ms / 1000 end
    local md, err = M.request_metadata(headers)
    if md == nil then return nil, err end
    local extra = {
        get = call.mode == 'get',
        codec = call.codec and call.codec.name,
        query = call.query,
    }
    return state, new_ctx(req, proc, state, md, state.deadline, extra)
end

-- Unary response for a failed call.
function Handler:_unary_error(st, ctx)
    local headers = {}
    if ctx ~= nil then
        add_headers(headers, ctx.response_metadata)
        add_headers(headers, ctx.trailing_metadata, 'trailer-')
    end
    headers['content-type'] = 'application/json'
    return {status = M.http_status[st.code] or 500, headers = headers, body = M.error_json(st)}
end

-- A unary call: POST with a bare message, or GET with the message in
-- the query.
function Handler:_serve_unary(call, req)
    local headers = req.headers or {}
    local proc, codec = call.proc, call.codec
    local msg, encoding, version_ok
    if call.mode == 'get' then
        if codec == nil then
            return {status = 415, headers = {}, body = ''}
        end
        local q = call.query
        version_ok = q.connect == nil or q.connect[1] == 'v1'
        encoding = q.compression and q.compression[1]
        msg = q.message and q.message[1] or ''
        if q.base64 ~= nil and q.base64[1] == '1' then
            msg = decode_base64(msg)
        end
    else
        local v = headers['connect-protocol-version']
        version_ok = v == nil or v == '1'
        encoding = headers['content-encoding']
        msg = req.body or ''
    end
    local state, ctx = self:_begin(call, req, headers, encoding, version_ok)
    if state == nil then
        -- _begin failed: its second result is the status.
        return self:_unary_error(ctx, nil)
    end
    if msg == nil then
        return self:_unary_error(grpc.status(CODE.INVALID_ARGUMENT,
            'invalid base64 in the message query parameter'), ctx)
    end
    if #msg > self._limit then
        return self:_unary_error(grpc.status(CODE.RESOURCE_EXHAUSTED,
            ('message larger than max (%d vs. %d)'):format(#msg, self._limit)), ctx)
    end
    local req_bytes, err = codec.decode(self, proc.input, msg)
    if req_bytes == nil then return self:_unary_error(err, ctx) end

    local ok, resp, code, message = invoke(state, proc.fn, req_bytes, ctx)
    if not ok then return self:_unary_error(as_status(ctx, resp), ctx) end
    if resp == nil and code ~= nil then
        -- A hand-written handler's `nil, code[, message]`.
        local st = code
        if not grpc.is_status(st) then
            local built
            ok, built = pcall(grpc.status, code, message)
            st = ok and built or as_status(ctx, built)
        end
        return self:_unary_error(as_status(ctx, st), ctx)
    end
    if resp ~= nil and type(resp) ~= 'string' then
        return self:_unary_error(as_status(ctx,
            ('handler returned a %s, expected bytes'):format(type(resp))), ctx)
    end
    local body
    ok, body = pcall(codec.encode, self, proc.output, resp or '')
    if not ok then return self:_unary_error(as_status(ctx, body), ctx) end
    -- Encoding a large response can take long enough to pass the
    -- deadline; the call is decided by the deadline then.
    if expired(state) then return self:_unary_error(deadline_status(), ctx) end
    local out = {}
    add_headers(out, ctx.response_metadata)
    add_headers(out, ctx.trailing_metadata, 'trailer-')
    out['content-type'] = 'application/' .. codec.name
    return {status = 200, headers = out, body = body}
end

-- ---------------------------------------------------------------------------
-- Streaming
-- ---------------------------------------------------------------------------

-- buffered_io(body) -> the envelope I/O of a streaming call over a
-- request body that is already in memory, collecting the response:
--
--   io:read() -> flags, payload | nil (end of input) | nil, err_text
--   io:write_headers(headers)    -- before the first message; once
--   io:write(flags, payload)
--   io:finish() -> response table {status, headers, body}
--
-- A streaming transport would implement the same four methods over the
-- live request and response.
function M.buffered_io(body)
    body = body or ''
    local pos = 1
    local io = {chunks = {}, headers = nil}
    function io:read()
        if pos > #body then return nil end
        if #body - pos + 1 < 5 then
            return nil, ('incomplete envelope: %d bytes'):format(#body - pos + 1)
        end
        local flags, b1, b2, b3, b4 = body:byte(pos, pos + 4)
        local len = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        if #body - pos + 1 - 5 < len then
            return nil, ('promised %d bytes in enveloped message, got %d bytes')
                :format(len, #body - pos + 1 - 5)
        end
        local payload = body:sub(pos + 5, pos + 4 + len)
        pos = pos + 5 + len
        return flags, payload
    end
    function io:write_headers(headers)
        self.headers = headers
    end
    function io:write(flags, payload)
        self.chunks[#self.chunks + 1] = M.envelope(flags, payload)
    end
    function io:finish()
        return {status = 200, headers = self.headers or {}, body = table.concat(self.chunks)}
    end
    return io
end

-- A streaming call: request envelopes in, response envelopes and one
-- EndStreamResponse out.
function Handler:_serve_stream(call, req, io)
    local h = self
    local headers = req.headers or {}
    local proc, codec = call.proc, call.codec
    local v = headers['connect-protocol-version']
    local state, ctx = self:_begin(call, req, headers, headers['connect-content-encoding'],
                                   v == nil or v == '1')
    local sent_headers = false
    local function send_headers()
        if sent_headers then return end
        sent_headers = true
        local out = {}
        if state ~= nil then add_headers(out, ctx.response_metadata) end
        out['content-type'] = 'application/connect+' .. codec.name
        io:write_headers(out)
    end
    local function finish(st)
        send_headers()
        local trailing = state ~= nil and ctx.trailing_metadata or nil
        io:write(ENVELOPE_END_STREAM, M.end_stream_json(st, trailing))
        if state ~= nil then state.done = true end
        return io:finish()
    end
    if state == nil then
        -- _begin failed: its second result is the status.
        return finish(ctx)
    end

    local recv_err
    local limit = self._limit
    local view = {}
    -- view:recv() -> bytes | nil, nil (end of the request stream) |
    -- nil, status. A framing error also fails the call: it is recorded
    -- and ends the stream whatever the handler does next.
    function view:recv()
        if recv_err ~= nil then return nil, recv_err end
        if ctx:is_cancelled() then return nil, deadline_status() end
        local flags, payload = io:read()
        local st
        if flags == nil then
            if payload == nil then return nil, nil end
            st = grpc.status(CODE.INVALID_ARGUMENT, 'protocol error: ' .. payload)
        elseif bit.band(flags, ENVELOPE_COMPRESSED) ~= 0 then
            st = grpc.status(CODE.INTERNAL,
                'protocol error: received a compressed message without a message encoding')
        elseif bit.band(flags, ENVELOPE_END_STREAM) ~= 0 then
            st = grpc.status(CODE.INVALID_ARGUMENT,
                'protocol error: end-stream flag set on a request message')
        elseif #payload > limit then
            st = grpc.status(CODE.RESOURCE_EXHAUSTED,
                ('message larger than max (%d vs. %d)'):format(#payload, limit))
        else
            local bytes, err = codec.decode(h, proc.input, payload)
            if bytes ~= nil then return bytes end
            st = err
        end
        recv_err = st
        return nil, st
    end
    -- view:send(bytes) -> true | false (the call is over).
    function view:send(bytes)
        if state.done or ctx:is_cancelled() then return false end
        send_headers()
        io:write(0, codec.encode(h, proc.output, bytes))
        return true
    end
    function view:is_cancelled()
        return ctx:is_cancelled()
    end

    local req_bytes
    if proc.kind == 'server_stream' then
        local err
        req_bytes, err = view:recv()
        if req_bytes == nil then
            return finish(err or grpc.status(CODE.UNIMPLEMENTED,
                'server-streaming call received no request message'))
        end
        local more
        more, err = view:recv()
        if more ~= nil then
            return finish(grpc.status(CODE.UNIMPLEMENTED,
                'server-streaming call received more than one request message'))
        end
        if err ~= nil then return finish(err) end
    end

    local ok, err = invoke(state, proc.entry.handler, req_bytes, view, ctx)
    local st
    if not ok then
        st = as_status(ctx, err)
    elseif recv_err ~= nil then
        st = recv_err
    elseif expired(state) then
        -- The handler's sends (and their encoding) ran past the deadline.
        st = deadline_status()
    end
    return finish(st)
end

-- serve(call, req) -> response for a call `match` returned.
function Handler:serve(call, req)
    if call.mode == 'stream' then
        return self:_serve_stream(call, req, M.buffered_io(req.body))
    end
    return self:_serve_unary(call, req)
end

-- handle(req) -> response, or nil when the request is not a Connect
-- call (see match and reject).
function Handler:handle(req)
    local call = self:match(req)
    if call == nil then return nil end
    return self:serve(call, req)
end

-- procedures() -> array of {path, kind, get} served, sorted by path.
function Handler:procedures()
    local out = {}
    for path, p in pairs(self._procs) do
        out[#out + 1] = {path = path, kind = p.kind, get = p.get or false}
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

return M
