-- pb.transcode: HTTP/JSON transcoding driven by google.api.http rules.
--
-- The router maps plain HTTP requests onto the unary methods of
-- generated gRPC servers, following google/api/http.proto (vendored at
-- options/google/api/http.proto; its long doc comment is the spec) and
-- AIP-127. It is a pure function over request/response tables — no
-- sockets — so an HTTP server hands it a request and sends back what it
-- returns:
--
--   local router = pb.transcode.new({lib.Library_server(impl)})
--   local resp = router:handle({method = 'GET', path = '/v1/shelves/1/books/2',
--                               headers = {}, body = ''})
--   -- resp = {status = 200, headers = {...}, body = '{"name": ...}'}
--
-- Rules come from the `http` array of each method descriptor (the
-- plugin and pb.from_pb normalise `google.api.http` into it). Every
-- template is parsed and checked against the request message at new()
-- time; handle() only splits the path, walks precomputed arrays and
-- binds values.
local log    = require('log')
local ffi    = require('ffi')
local digest = require('digest')
local pbjson = require('pb.json')
local grpc   = require('pb.grpc')
local wire   = require('pb.wire')

local M = {}

-- ---------------------------------------------------------------------------
-- Percent-decoding
-- ---------------------------------------------------------------------------

-- pct_decode(s, keep_slash) -> decoded string, or nil when s carries a
-- malformed escape. keep_slash leaves %2F / %2f encoded: http.proto
-- asks for that on multi-segment variables, so a captured value can
-- still tell an encoded slash from a segment separator.
local function pct_decode(s, keep_slash)
    if not s:find('%', 1, true) then return s end
    local _, total = s:gsub('%%', '')
    local out, good = s:gsub('%%(%x%x)', function(h)
        if keep_slash and (h == '2F' or h == '2f') then return nil end
        return string.char(tonumber(h, 16))
    end)
    if good ~= total then return nil end
    return out
end

-- Query-string component: '+' is a space, then percent-decoding.
local function form_decode(s)
    return pct_decode((s:gsub('+', ' ')), false)
end

-- ---------------------------------------------------------------------------
-- Path templates
--
--   Template = "/" Segments [ Verb ] ;
--   Segments = Segment { "/" Segment } ;
--   Segment  = "*" | "**" | LITERAL | Variable ;
--   Variable = "{" FieldPath [ "=" Segments ] "}" ;
--   FieldPath = IDENT { "." IDENT } ;
--   Verb     = ":" LITERAL ;
--
-- A parsed template is flattened: variables contribute their own
-- segments to one array, and remember which slice of it they capture.
-- ---------------------------------------------------------------------------

local SEG_LIT, SEG_STAR, SEG_DSTAR = 0, 1, 2

-- RFC 3986 pchar minus ':' (which starts the verb) plus '%' escapes.
local LITERAL_RE = "^[%w%-%._~!$&'()+,;=@%%]+$"
local IDENT_RE = '^[%a_][%w_]*$'

local function split(s, sep)
    local out, n, pos = {}, 0, 1
    while true do
        local i = s:find(sep, pos, true)
        n = n + 1
        if i == nil then
            out[n] = s:sub(pos)
            return out, n
        end
        out[n] = s:sub(pos, i - 1)
        pos = i + 1
    end
end

local function parse_literal(tok)
    if not tok:match(LITERAL_RE) then
        return nil, ('invalid literal segment %q'):format(tok)
    end
    local dec = pct_decode(tok, false)
    if dec == nil then
        return nil, ('malformed percent-escape in %q'):format(tok)
    end
    return {kind = SEG_LIT, lit = tok, lit_dec = dec}
end

local function parse_plain_segment(tok)
    if tok == '' then return nil, 'empty segment' end
    if tok == '*' then return {kind = SEG_STAR} end
    if tok == '**' then return {kind = SEG_DSTAR} end
    return parse_literal(tok)
end

-- parse_template(pattern) -> template | nil, err
--
-- template = {
--   pattern = <string>,
--   segs    = {{kind = SEG_*, lit = ?, lit_dec = ?}, ...},
--   vars    = {{path = {'book', 'name'}, name = 'book.name',
--               first = i, last = j, multi = bool}, ...},
--   verb    = <string> | nil,
--   dstar   = true when the last segment is `**`,
-- }
local function parse_template(pattern)
    if type(pattern) ~= 'string' or pattern:sub(1, 1) ~= '/' then
        return nil, 'must start with "/"'
    end
    -- Locate the verb: a ':' outside braces after the last top-level '/'.
    local depth, verb_pos = 0, nil
    for i = 2, #pattern do
        local c = pattern:sub(i, i)
        if c == '{' then
            depth = depth + 1
            if depth > 1 then return nil, 'a variable must not contain another variable' end
        elseif c == '}' then
            depth = depth - 1
            if depth < 0 then return nil, 'unbalanced "}"' end
        elseif depth == 0 then
            if c == '/' then
                verb_pos = nil
            elseif c == ':' and verb_pos == nil then
                verb_pos = i
            end
        end
    end
    if depth ~= 0 then return nil, 'unbalanced "{"' end

    local body, verb = pattern:sub(2), nil
    if verb_pos ~= nil then
        verb = pattern:sub(verb_pos + 1)
        body = pattern:sub(2, verb_pos - 1)
        if verb == '' or not verb:match(LITERAL_RE) then
            return nil, ('invalid verb %q'):format(verb)
        end
    end
    if body == '' then return nil, 'empty path' end

    -- Split the body at top-level slashes.
    local toks, ntok, start = {}, 0, 1
    depth = 0
    for i = 1, #body + 1 do
        local c = body:sub(i, i)
        if c == '{' then
            depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
        elseif (c == '/' and depth == 0) or c == '' then
            ntok = ntok + 1
            toks[ntok] = body:sub(start, i - 1)
            start = i + 1
        end
    end

    local segs, vars, seen = {}, {}, {}
    for _, tok in ipairs(toks) do
        if tok:sub(1, 1) == '{' then
            if tok:sub(-1) ~= '}' then
                return nil, ('variable %q must be a whole segment'):format(tok)
            end
            local inner = tok:sub(2, -2)
            local fpath, sub = inner:match('^([^=]*)=(.*)$')
            if fpath == nil then fpath, sub = inner, '*' end
            local names = split(fpath, '.')
            for _, id in ipairs(names) do
                if not id:match(IDENT_RE) then
                    return nil, ('invalid field path %q'):format(fpath)
                end
            end
            if seen[fpath] then
                return nil, ('field %q bound twice'):format(fpath)
            end
            seen[fpath] = true
            if sub == '' then return nil, ('empty segments in %q'):format(tok) end
            local first = #segs + 1
            for _, st in ipairs((split(sub, '/'))) do
                local seg, err = parse_plain_segment(st)
                if seg == nil then return nil, err .. ' in ' .. tok end
                segs[#segs + 1] = seg
            end
            local last = #segs
            vars[#vars + 1] = {
                path = names, name = fpath, first = first, last = last,
                multi = last > first or segs[last].kind == SEG_DSTAR,
            }
        else
            if tok:find('[{}]') then
                return nil, ('variable %q must be a whole segment'):format(tok)
            end
            local seg, err = parse_plain_segment(tok)
            if seg == nil then return nil, err end
            segs[#segs + 1] = seg
        end
    end
    for i = 1, #segs - 1 do
        if segs[i].kind == SEG_DSTAR then
            return nil, '"**" must be the last segment'
        end
    end
    return {
        pattern = pattern, segs = segs, vars = vars, verb = verb,
        dstar = segs[#segs].kind == SEG_DSTAR,
    }
end

M._parse_template = parse_template

-- match(tmpl, segs, n, last) -> true when the request segments match.
-- `last` stands in for segs[n] (the last segment with the verb removed).
local function match(tmpl, segs, n, last)
    local ts = tmpl.segs
    local tn = #ts
    local fixed = tn
    if tmpl.dstar then
        fixed = tn - 1
        if n < fixed then return false end
    elseif n ~= tn then
        return false
    end
    for i = 1, fixed do
        local s = segs[i]
        if i == n then s = last end
        local t = ts[i]
        if t.kind == SEG_LIT then
            if s ~= t.lit then
                local d = pct_decode(s, false)
                if d == nil or d ~= t.lit_dec then return false end
            end
        elseif s == '' then
            return false
        end
    end
    return true
end

-- capture(tmpl, var, segs, n, last) -> raw captured text (still encoded).
local function capture(tmpl, var, segs, n, last)
    local hi = var.last
    if tmpl.dstar and hi == #tmpl.segs then hi = n end
    local parts = {}
    for i = var.first, hi do
        local s = segs[i]
        if i == n then s = last end
        parts[#parts + 1] = s
    end
    return table.concat(parts, '/')
end

-- Ordering between templates. Segment by segment from the left, a
-- literal beats `*` which beats `**`; a template that has already ended
-- beats one that continues with `**` (so `/a` wins over `/a/**` for
-- `/a`); then a template with a verb beats one without.
local function rank_less(a, b)
    local sa, sb = a.tmpl.segs, b.tmpl.segs
    local n = math.max(#sa, #sb)
    for i = 1, n do
        local ka = sa[i] and sa[i].kind or -1
        local kb = sb[i] and sb[i].kind or -1
        if ka ~= kb then return ka < kb end
    end
    local va, vb = a.tmpl.verb ~= nil, b.tmpl.verb ~= nil
    if va ~= vb then return va end
    return a.decl < b.decl
end

-- ---------------------------------------------------------------------------
-- Field lookup and value conversion
-- ---------------------------------------------------------------------------

-- desc -> {[proto_name] = field}. Built here because only
-- pb.finalize_message sets field_by_name; runtime-built descriptors
-- (pb.parse, pb.from_pb) do not.
local PROTO_INDEX = setmetatable({}, {__mode = 'k'})

local function proto_field(desc, name)
    local idx = PROTO_INDEX[desc]
    if idx == nil then
        idx = {}
        for _, f in ipairs(desc.fields or {}) do idx[f.name] = f end
        PROTO_INDEX[desc] = idx
    end
    return idx[name]
end

-- desc -> {[proto_name] = field, [jsonName] = field}: query keys take
-- either spelling.
local NAME_INDEX = setmetatable({}, {__mode = 'k'})

local function field_index(desc)
    local idx = NAME_INDEX[desc]
    if idx == nil then
        idx = {}
        for _, f in ipairs(desc.fields or {}) do
            idx[f.name] = f
            local jn = pbjson.json_name(f.name)
            if idx[jn] == nil then idx[jn] = f end
        end
        NAME_INDEX[desc] = idx
    end
    return idx
end

local INT32_T  = {int32 = true, sint32 = true, sfixed32 = true}
local UINT32_T = {uint32 = true, fixed32 = true}
local INT64_T  = {int64 = true, sint64 = true, sfixed64 = true}
local UINT64_T = {uint64 = true, fixed64 = true}

local INT64_CT  = ffi.typeof('int64_t')
local UINT64_CT = ffi.typeof('uint64_t')

local BOOLS = {
    ['true'] = true, ['True'] = true, ['TRUE'] = true, t = true, T = true, ['1'] = true,
    ['false'] = false, ['False'] = false, ['FALSE'] = false, f = false, F = false, ['0'] = false,
}

-- Compare two unsigned decimal digit strings without leading zeros.
local function digits_le(a, b)
    if #a ~= #b then return #a < #b end
    return a <= b
end

local function parse_int(s, lo_neg, hi)
    local neg, digits = s:match('^(%-?)(%d+)$')
    if digits == nil then return nil end
    digits = digits:gsub('^0+(%d)', '%1')
    if neg == '-' then
        if lo_neg == nil or not digits_le(digits, lo_neg) then return nil end
    elseif not digits_le(digits, hi) then
        return nil
    end
    return neg .. digits
end

-- Strict base64: the standard or the URL-safe alphabet, padded or not,
-- but the length must be one base64 can produce and padding, when
-- present, must complete the last quantum exactly. digest.base64_decode
-- alone skips junk silently, so the shape is checked first.
local function decode_base64(s)
    local b64 = s:gsub('-', '+'):gsub('_', '/')
    local body, pad = b64:match('^([%w+/]*)(=*)$')
    if body == nil then return nil end
    local rem = #body % 4
    if rem == 1 then return nil end
    if #pad > 0 and (#pad ~= (4 - rem) % 4 or rem == 0) then return nil end
    return digest.base64_decode(body)
end

-- Smallest magnitude that rounds to infinity as a float32: FLT_MAX plus
-- half an ULP, (2^24 - 0.5) * 2^104. Anything below rounds to a finite
-- float (3.4028235e38, FLT_MAX as printed, is accepted, as in Go).
local FLT_OVERFLOW = (2 ^ 24 - 0.5) * 2 ^ 104

-- Scalar Lua value for proto type `pt` from the text `s`, or nil.
local function convert_scalar(pt, s)
    if pt == 'string' then
        if not wire.is_valid_utf8(s) then return nil end
        return s
    end
    if pt == 'bool' then return BOOLS[s] end
    if INT32_T[pt] then
        local v = parse_int(s, '2147483648', '2147483647')
        return v and tonumber(v)
    end
    if UINT32_T[pt] then
        local v = parse_int(s, nil, '4294967295')
        return v and tonumber(v)
    end
    if INT64_T[pt] then
        local v = parse_int(s, '9223372036854775808', '9223372036854775807')
        return v and ffi.cast(INT64_CT, tonumber64(v))
    end
    if UINT64_T[pt] then
        local v = parse_int(s, nil, '18446744073709551615')
        return v and ffi.cast(UINT64_CT, tonumber64(v))
    end
    if pt == 'float' or pt == 'double' then
        if s == 'NaN' then return 0 / 0 end
        if s == 'Infinity' then return math.huge end
        if s == '-Infinity' then return -math.huge end
        if not (s:match('^%-?%d*%.?%d*$') or s:match('^%-?%d*%.?%d*[eE][-+]?%d+$')) then
            return nil
        end
        local v = tonumber(s)
        -- A finite literal that overflows the type is an error, not
        -- Infinity; only the explicit spellings above give infinities.
        if v == nil or v == math.huge or v == -math.huge then return nil end
        if pt == 'float' and (v >= FLT_OVERFLOW or v <= -FLT_OVERFLOW) then return nil end
        return v
    end
    if pt == 'bytes' then return decode_base64(s) end
    return nil
end

local WRAPPED = {
    ['google.protobuf.DoubleValue'] = 'double',
    ['google.protobuf.FloatValue']  = 'float',
    ['google.protobuf.Int64Value']  = 'int64',
    ['google.protobuf.UInt64Value'] = 'uint64',
    ['google.protobuf.Int32Value']  = 'int32',
    ['google.protobuf.UInt32Value'] = 'uint32',
    ['google.protobuf.BoolValue']   = 'bool',
    ['google.protobuf.StringValue'] = 'string',
    ['google.protobuf.BytesValue']  = 'bytes',
}

-- Well-known types whose JSON form is a single string.
local STRING_WKT = {
    ['google.protobuf.Timestamp'] = true,
    ['google.protobuf.Duration']  = true,
    ['google.protobuf.FieldMask'] = true,
}

-- True when a field can take its value from one path or query string.
local function is_single_value_field(f)
    if f.kind == 'scalar' or f.kind == 'enum' then return true end
    if f.kind == 'message' and f.message then
        local name = f.message.name
        return WRAPPED[name] ~= nil or STRING_WKT[name] ~= nil
    end
    return false
end

local function invalid(fmt, ...)
    grpc.error(grpc.code.INVALID_ARGUMENT, fmt:format(...))
end

-- convert(field, s, where) -> Lua value for one element of `field`.
-- Raises INVALID_ARGUMENT naming the field on a bad value.
local function convert(f, s, where)
    local v
    if f.kind == 'scalar' then
        v = convert_scalar(f.proto_type, s)
    elseif f.kind == 'enum' then
        v = f.enum.by_name[s]
        if v == nil then
            local num = parse_int(s, '2147483648', '2147483647')
            v = num and tonumber(num)
        end
    else
        local name = f.message.name
        local pt = WRAPPED[name]
        if pt ~= nil then
            v = convert_scalar(pt, s)
        elseif STRING_WKT[name] then
            local ok, res = pcall(pbjson.from_json_value, f.message, s)
            if ok then v = res end
        end
    end
    if v == nil then
        local ty = f.proto_type or (f.enum and f.enum.name)
                   or (f.message and f.message.name) or f.kind
        invalid('invalid value %q for %s "%s" (%s)', s, where, f.name, ty)
    end
    return v
end

-- set_leaf(t, chain, value, append): walk (creating) the messages
-- along `chain` and store value at its last field. Setting a oneof
-- member while another member of the same oneof is already set (by the
-- body, the path or an earlier query parameter) is a conflict and
-- raises INVALID_ARGUMENT, as grpc-gateway does; setting the same
-- member again is allowed. Synthetic oneofs of proto3 `optional`
-- fields carry no siblings, so they never conflict.
local function set_leaf(t, chain, value, append)
    local n = #chain
    for i = 1, n do
        local f = chain[i]
        if f.oneof_siblings then
            for _, sib in ipairs(f.oneof_siblings) do
                if t[sib] ~= nil then
                    invalid('oneof "%s": field "%s" conflicts with "%s", which is already set',
                            tostring(f.oneof), f.name, sib)
                end
            end
        end
        if i == n then
            if append then
                local arr = t[f.name]
                if arr == nil then arr = {}; t[f.name] = arr end
                arr[#arr + 1] = value
            else
                t[f.name] = value
            end
        else
            local sub = t[f.name]
            if type(sub) ~= 'table' then sub = {}; t[f.name] = sub end
            t = sub
        end
    end
end

-- ---------------------------------------------------------------------------
-- Router construction
-- ---------------------------------------------------------------------------

local HOP_BY_HOP = {
    connection = true, ['keep-alive'] = true, ['proxy-connection'] = true,
    ['transfer-encoding'] = true, upgrade = true, te = true, trailer = true,
    ['content-length'] = true,
}

local status_desc

local function status_descriptor(pb)
    if status_desc == nil then
        status_desc = pb.finalize_message({
            name = 'google.rpc.Status',
            fields = {
                {name = 'code', id = 1, kind = 'scalar', proto_type = 'int32'},
                {name = 'message', id = 2, kind = 'scalar', proto_type = 'string'},
                {name = 'details', id = 3, kind = 'message',
                 message = pb.wkt.Any_descriptor, repeated = true},
            },
        })
    end
    return status_desc
end

-- Resolve a template variable's field path against the request message.
local function resolve_path_var(input, names)
    local chain, desc = {}, input
    for i, id in ipairs(names) do
        local f = proto_field(desc, id)
        if f == nil then
            return nil, ('%s has no field "%s"'):format(desc.name, id)
        end
        chain[i] = f
        if i < #names then
            if f.kind ~= 'message' or f.repeated or f.message.fields == nil then
                return nil, ('field "%s" of %s is not a singular message'):format(id, desc.name)
            end
            desc = f.message
        elseif f.repeated or f.kind == 'map' or not is_single_value_field(f) then
            return nil, ('field "%s" of %s must be a singular scalar, enum or '
                         .. 'string-valued well-known type'):format(id, desc.name)
        end
    end
    return chain
end

local function new_route(method_desc, handler, rule, decl)
    local tmpl, err = parse_template(rule.pattern)
    local where = ('%s: pattern %q'):format(method_desc.full_name, tostring(rule.pattern))
    if tmpl == nil then
        error(('pb.transcode.new: %s: %s'):format(where, err), 0)
    end
    local input, output = method_desc.input, method_desc.output
    local bound = {}
    for _, var in ipairs(tmpl.vars) do
        local chain, verr = resolve_path_var(input, var.path)
        if chain == nil then
            error(('pb.transcode.new: %s: %s'):format(where, verr), 0)
        end
        var.chain = chain
        bound[var.name] = true
    end
    local body = rule.body
    if body == '' then body = nil end
    if body ~= nil and body ~= '*' then
        if proto_field(input, body) == nil then
            error(('pb.transcode.new: %s: body field "%s" is not a field of %s')
                :format(where, body, input.name), 0)
        end
    end
    local response_body = rule.response_body
    if response_body == '' then response_body = nil end
    if response_body ~= nil and proto_field(output, response_body) == nil then
        error(('pb.transcode.new: %s: response_body field "%s" is not a field of %s')
            :format(where, response_body, output.name), 0)
    end
    return {
        method = rule.method,
        pattern = rule.pattern,
        path = method_desc.full_name,
        tmpl = tmpl,
        verb_suffix = tmpl.verb and (':' .. tmpl.verb) or nil,
        body = body,
        response_body = response_body,
        input = input,
        output = output,
        handler = handler,
        bound = bound,
        decl = decl,
    }
end

local Router = {}
Router.__index = Router

---@class pb.TranscodeOpts
---@field unbound? boolean   expose unannotated unary methods as POST /pkg.Service/Method
---@field json?    pb.JsonEncodeOpts  response JSON options (default {emit_defaults = true})

-- new(servers, opts) -> router
---@param servers table[]   generated server tables (M.<Svc>_server(impl))
---@param opts? pb.TranscodeOpts
function M.new(servers, opts)
    local pb = require('pb')
    if type(servers) ~= 'table' then
        error('pb.transcode.new: servers must be an array of server tables', 2)
    end
    opts = opts or {}
    if type(opts) ~= 'table' then
        error('pb.transcode.new: opts must be a table', 2)
    end
    local json_opts = {emit_defaults = true}
    if opts.json ~= nil then
        if type(opts.json) ~= 'table' then
            error('pb.transcode.new: opts.json must be a table', 2)
        end
        for k, v in pairs(opts.json) do json_opts[k] = v end
    end

    local routes, decl = {}, 0
    for si, server in ipairs(servers) do
        if type(server) ~= 'table' or type(server.service) ~= 'table'
                or type(server.methods) ~= 'table' then
            error(('pb.transcode.new: servers[%d] is not a generated server table'):format(si), 2)
        end
        -- Method order within a service is not recorded in the
        -- descriptor (methods is keyed by name), so sort by name for a
        -- deterministic declaration order.
        local names = {}
        for name in pairs(server.service.methods) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local m = server.service.methods[name]
            local streaming = m.client_streaming or m.server_streaming
            local handler = server.methods[m.full_name]
            if m.http ~= nil and #m.http > 0 then
                if streaming then
                    log.warn('pb.transcode: %s is a streaming method; its HTTP rules are not routed',
                             m.full_name)
                elseif handler == nil then
                    log.warn('pb.transcode: %s has HTTP rules but no unary handler; not routed',
                             m.full_name)
                else
                    for _, rule in ipairs(m.http) do
                        decl = decl + 1
                        routes[#routes + 1] = new_route(m, handler, rule, decl)
                    end
                end
            elseif opts.unbound and not streaming and handler ~= nil then
                decl = decl + 1
                routes[#routes + 1] = new_route(m, handler,
                    {method = 'POST', pattern = m.full_name, body = '*'}, decl)
            end
        end
    end
    table.sort(routes, rank_less)

    -- Per-HTTP-method route lists in priority order; `*` (custom rule
    -- with any method) routes join every list.
    local by_method, any = {}, {}
    for _, r in ipairs(routes) do
        if r.method ~= '*' and by_method[r.method] == nil then by_method[r.method] = {} end
    end
    for _, r in ipairs(routes) do
        if r.method == '*' then
            any[#any + 1] = r
            for _, list in pairs(by_method) do list[#list + 1] = r end
        else
            local list = by_method[r.method]
            list[#list + 1] = r
        end
    end

    return setmetatable({
        _routes = routes,
        _by_method = by_method,
        _any = any,
        _json = json_opts,
        _pb = pb,
        _status_desc = status_descriptor(pb),
    }, Router)
end

-- routes() -> array of {method, pattern, path} in match-priority order.
function Router:routes()
    local out = {}
    for i, r in ipairs(self._routes) do
        out[i] = {method = r.method, pattern = r.pattern, path = r.path,
                  body = r.body, response_body = r.response_body}
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Request handling
-- ---------------------------------------------------------------------------

local function is_blank(s)
    return s == nil or s:match('^%s*$') ~= nil
end

-- Build the request message table from path, body and query.
local function bind(r, segs, n, last, query, body_text)
    local t = {}
    -- Body first; path variables are written after it so a field bound
    -- by the path wins over the same field in a `*` or field body
    -- (http.proto: `*` maps "every field not bound by the path").
    if r.body ~= nil and not is_blank(body_text) then
        local ok, res
        if r.body == '*' then
            ok, res = pcall(pbjson.decode, r.input, body_text)
            if ok then t = res end
        else
            ok, res = pcall(pbjson.decode_field, r.input, r.body, body_text)
            if ok then t[r.body] = res end
        end
        if not ok then
            -- json.decode errors carry a "file:line: " prefix; drop it.
            local msg = tostring(res):gsub('^[^%s:]+:%d+: ', '')
            invalid('invalid JSON body: %s', msg)
        end
    end

    local tmpl = r.tmpl
    for _, var in ipairs(tmpl.vars) do
        local raw = capture(tmpl, var, segs, n, last)
        local text = pct_decode(raw, var.multi)
        if text == nil then
            invalid('malformed percent-encoding in path for "%s"', var.name)
        end
        local leaf = var.chain[#var.chain]
        set_leaf(t, var.chain, convert(leaf, text, 'path variable'), false)
    end

    -- Query parameters bind whatever path and body left, unless the
    -- body is `*` (http.proto rule 2: no query parameters then).
    if query == nil or query == '' or r.body == '*' then return t end
    local seen = {}
    for _, pair in ipairs((split(query, '&'))) do
        if pair ~= '' then
            local rk, rv = pair:match('^([^=]*)=(.*)$')
            if rk == nil then rk, rv = pair, '' end
            local key, val = form_decode(rk), form_decode(rv)
            if key == nil or val == nil then
                invalid('malformed percent-encoding in query parameter %q', rk)
            end
            -- Resolve the dotted key; unknown names are ignored.
            local chain, desc, canon = {}, r.input, {}
            for i, id in ipairs((split(key, '.'))) do
                local f = desc and field_index(desc)[id]
                if f == nil then chain = nil; break end
                chain[i] = f
                canon[i] = f.name
                -- Descend into repeated messages too, so the check
                -- below can reject them by name instead of ignoring
                -- the key as unknown.
                if f.kind == 'message' and f.message.fields ~= nil then
                    desc = f.message
                else
                    desc = nil
                end
            end
            local name = chain and table.concat(canon, '.')
            -- Skip fields already bound by the path or carried in the body.
            if chain ~= nil and #chain > 0 and not r.bound[name]
                    and not (r.body ~= nil and canon[1] == r.body) then
                local leaf = chain[#chain]
                if leaf.kind == 'map' then
                    invalid('map field "%s" cannot be bound from a query parameter', name)
                elseif not is_single_value_field(leaf) then
                    invalid('message field "%s" cannot be bound from a query parameter; '
                            .. 'set its fields with dotted names', name)
                else
                    for i = 1, #chain - 1 do
                        if chain[i].repeated then
                            invalid('repeated message field "%s" cannot be bound from '
                                    .. 'a query parameter', canon[i])
                        end
                    end
                    if leaf.repeated then
                        set_leaf(t, chain, convert(leaf, val, 'query parameter'), true)
                    else
                        if seen[name] then
                            invalid('query parameter "%s" given more than once for a '
                                    .. 'non-repeated field', name)
                        end
                        seen[name] = true
                        set_leaf(t, chain, convert(leaf, val, 'query parameter'), false)
                    end
                end
            end
        end
    end
    return t
end

local function copy_metadata(dst, md)
    if type(md) ~= 'table' then return end
    for k, v in pairs(md) do
        if type(v) == 'table' then
            dst[k] = table.concat(v, ', ')
        else
            dst[k] = tostring(v)
        end
    end
end

function Router:_status_response(st, ctx)
    local code = st.code
    local headers = {}
    if ctx ~= nil then copy_metadata(headers, ctx.response_metadata) end
    headers['content-type'] = 'application/json'
    local ok, body = pcall(pbjson.encode, self._status_desc, {
        code = code, message = st.message, details = st.details,
    }, self._json)
    if not ok then
        log.error('pb.transcode: cannot encode status details: %s', tostring(body))
        body = pbjson.encode(self._status_desc, {code = code, message = st.message},
                             self._json)
    end
    return {status = grpc.http_status[code] or 500, headers = headers, body = body}
end

function Router:_internal(ctx, path, err)
    log.error('pb.transcode: %s: %s', path, tostring(err))
    return self:_status_response(grpc.status(grpc.code.INTERNAL, 'internal error'), ctx)
end

local function new_ctx(r, req)
    local md = {}
    if type(req.headers) == 'table' then
        for k, v in pairs(req.headers) do
            local lk = type(k) == 'string' and k:lower() or k
            if not HOP_BY_HOP[lk] then md[lk] = v end
        end
    end
    return {
        method = r.path,
        metadata = md,
        peer = req.peer,
        response_metadata = {},
        trailing_metadata = {},
        is_cancelled = function() return false end,
    }
end

function Router:_call(r, req, segs, n, last, query, ctx)
    if ctx == nil then ctx = new_ctx(r, req) end
    if ctx.response_metadata == nil then ctx.response_metadata = {} end

    local ok, t = pcall(bind, r, segs, n, last, query, req.body)
    if not ok then
        if grpc.is_status(t) then return self:_status_response(t, ctx) end
        return self:_internal(ctx, r.path, t)
    end

    local pb = self._pb
    local req_bytes
    ok, req_bytes = pcall(pb.encode, r.input, t)
    if not ok then
        return self:_status_response(grpc.status(grpc.code.INVALID_ARGUMENT,
            'cannot encode request: ' .. tostring(req_bytes)), ctx)
    end

    -- The request goes through its wire bytes and the generated server
    -- wrapper, which decodes it again. That costs an encode and a
    -- decode per call, but keeps one code path for handlers, status
    -- objects and ctx, identical to what a gRPC client gets.
    local resp_bytes, st, msg
    ok, resp_bytes, st, msg = pcall(r.handler, req_bytes, ctx)
    if not ok then
        if grpc.is_status(resp_bytes) then return self:_status_response(resp_bytes, ctx) end
        return self:_internal(ctx, r.path, resp_bytes)
    end
    if resp_bytes == nil then
        -- Transport-style failure: nil, status[, message].
        if st ~= nil then
            if not grpc.is_status(st) then st = grpc.status(st, msg) end
            return self:_status_response(st, ctx)
        end
        return self:_internal(ctx, r.path, 'handler returned no response')
    end

    local resp
    ok, resp = pcall(pb.decode, r.output, resp_bytes)
    if not ok then return self:_internal(ctx, r.path, resp) end

    local body
    if r.response_body ~= nil then
        ok, body = pcall(pbjson.encode_field, r.output, resp, r.response_body, self._json)
    else
        ok, body = pcall(pbjson.encode, r.output, resp, self._json)
    end
    if not ok then return self:_internal(ctx, r.path, body) end

    local headers = {}
    copy_metadata(headers, ctx.response_metadata)
    headers['content-type'] = 'application/json'
    if req.method == 'HEAD' then body = '' end
    return {status = 200, headers = headers, body = body}
end

-- handle(req[, ctx]) -> resp, or nil when no route matches the path
-- and method.
function Router:handle(req, ctx)
    local raw = req.path
    if type(raw) ~= 'string' then return nil end
    local qpos = raw:find('?', 1, true)
    local path, query = raw, nil
    if qpos ~= nil then
        path, query = raw:sub(1, qpos - 1), raw:sub(qpos + 1)
    end
    local hpos = (query or path):find('#', 1, true)
    if hpos ~= nil then
        if query ~= nil then query = query:sub(1, hpos - 1) else path = path:sub(1, hpos - 1) end
    end
    if path:sub(1, 1) ~= '/' then return nil end
    local segs, n = split(path:sub(2), '/')
    local list = self._by_method[req.method] or self._any
    for i = 1, #list do
        local r = list[i]
        local last = segs[n]
        local suffix = r.verb_suffix
        local ok = true
        if suffix ~= nil then
            if #last >= #suffix and last:sub(-#suffix) == suffix then
                last = last:sub(1, #last - #suffix)
            else
                ok = false
            end
        end
        if ok and match(r.tmpl, segs, n, last) then
            return self:_call(r, req, segs, n, last, query, ctx)
        end
    end
    return nil
end

M._match = match
M._capture = capture
M._pct_decode = pct_decode

return M
