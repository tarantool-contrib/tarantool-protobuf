-- pb.transcode: google.api.http path templates, binding and the router.
--
-- The `http_proto` group turns every example of the doc comment in
-- options/google/api/http.proto (an HTTP request and the gRPC call it
-- becomes) into a test. The schemas are parsed at runtime and served by
-- a recording fake server, so the assertion is on the request message
-- the handler actually decoded from the wire.

local t    = require('luatest')
local ffi  = require('ffi')
local json = require('json')
local pb   = require('pb')

local tc = pb.transcode

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function shallow_copy(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

-- fake_server(svc, rules, respond) -> server, calls
--
-- A server table in the generated shape over a pb.parse service
-- descriptor. `rules` sets `http` per method name. Each call decodes the
-- request bytes, records {method, req, ctx}, and answers with
-- respond(name, req, ctx) (default: an empty response message).
local function fake_server(svc, rules, respond)
    local calls = {}
    local service = {name = svc.name, full_name = svc.full_name, methods = {}}
    local methods = {}
    for name, m in pairs(svc.methods) do
        local mm = shallow_copy(m)
        mm.http = rules and rules[name] or nil
        service.methods[name] = mm
        if not (m.client_streaming or m.server_streaming) then
            methods[m.full_name] = function(req_bytes, ctx)
                local req = pb.decode(m.input, req_bytes)
                calls[#calls + 1] = {method = name, req = req, ctx = ctx}
                local resp = respond and respond(name, req, ctx) or {}
                return pb.encode(m.output, resp)
            end
        end
    end
    return {service = service, methods = methods, streams = {}}, calls
end

local function request(method, path, body, headers)
    return {method = method, path = path, headers = headers or {}, body = body or '',
            version = 'HTTP/1.1', peer = '127.0.0.1:5000'}
end

local function call(router, calls, method, path, body)
    local before = #calls
    local resp = router:handle(request(method, path, body))
    t.assert_not_equals(resp, nil, method .. ' ' .. path .. ' did not match')
    t.assert_equals(resp.status, 200, resp.body)
    t.assert_equals(#calls, before + 1)
    return calls[#calls].req, resp
end

local function i64(s) return ffi.cast('int64_t', tonumber64(s)) end
local function u64(s) return ffi.cast('uint64_t', tonumber64(s)) end

-- ---------------------------------------------------------------------------
-- Template parser
-- ---------------------------------------------------------------------------

local gp = t.group('transcode.template')

local function kinds(tmpl)
    local out = {}
    for i, s in ipairs(tmpl.segs) do
        out[i] = s.kind == 0 and s.lit or (s.kind == 1 and '*' or '**')
    end
    return out
end

gp.test_valid_templates = function()
    local cases = {
        {'/v1/messages/{message_id}', {'v1', 'messages', '*'}, nil,
         {{'message_id', 3, 3, false}}},
        {'/v1/{name=messages/*}', {'v1', 'messages', '*'}, nil,
         {{'name', 2, 3, true}}},
        {'/v1/{name=shelves/*/books/*}', {'v1', 'shelves', '*', 'books', '*'}, nil,
         {{'name', 2, 5, true}}},
        {'/v1/{path=files/**}', {'v1', 'files', '**'}, nil, {{'path', 2, 3, true}}},
        {'/v1/{path=**}', {'v1', '**'}, nil, {{'path', 2, 2, true}}},
        {'/v1/books:lookup', {'v1', 'books'}, 'lookup', {}},
        {'/v1/shelves/{book.shelf}/books/{book.name}:move',
         {'v1', 'shelves', '*', 'books', '*'}, 'move',
         {{'book.shelf', 3, 3, false}, {'book.name', 5, 5, false}}},
        {'/v1/{name=projects/*}:undelete', {'v1', 'projects', '*'}, 'undelete',
         {{'name', 2, 3, true}}},
        {'/v1/*/x/**', {'v1', '*', 'x', '**'}, nil, {}},
        {'/library.Library/GetBook', {'library.Library', 'GetBook'}, nil, {}},
        {'/v1/a%20b', {'v1', 'a%20b'}, nil, {}},
        {'/v1/{var=*}', {'v1', '*'}, nil, {{'var', 2, 2, false}}},
    }
    for _, c in ipairs(cases) do
        local tmpl, err = tc._parse_template(c[1])
        t.assert_not_equals(tmpl, nil, c[1] .. ': ' .. tostring(err))
        t.assert_equals(kinds(tmpl), c[2], c[1])
        t.assert_equals(tmpl.verb, c[3], c[1])
        local vars = {}
        for i, v in ipairs(tmpl.vars) do vars[i] = {v.name, v.first, v.last, v.multi} end
        t.assert_equals(vars, c[4], c[1])
    end
    t.assert_equals(tc._parse_template('/v1/a%20b').segs[2].lit_dec, 'a b')
end

gp.test_invalid_templates = function()
    local cases = {
        {'v1/books', 'must start with "/"'},
        {'/', 'empty path'},
        {'/:verb', 'empty path'},
        {'/v1//books', 'empty segment'},
        {'/v1/books/', 'empty segment'},
        {'/v1/{name', 'unbalanced "{"'},
        {'/v1/name}', 'unbalanced "}"'},
        {'/v1/{a={b}}', 'must not contain another variable'},
        {'/v1/**/books', '"**" must be the last segment'},
        {'/v1/{name=**}/books', '"**" must be the last segment'},
        {'/v1/{na-me}', 'invalid field path'},
        {'/v1/{1name}', 'invalid field path'},
        {'/v1/{a..b}', 'invalid field path'},
        {'/v1/{name=}', 'empty segments'},
        {'/v1/{name=a//b}', 'empty segment'},
        {'/v1/x{name}', 'must be a whole segment'},
        {'/v1/{name}x', 'must be a whole segment'},
        {'/v1/{id}/{id}', 'bound twice'},
        {'/v1/books:', 'invalid verb'},
        {'/v1/books:a*b', 'invalid verb'},
        {'/v1/bo*oks', 'invalid literal'},
        {'/v1/a%zz', 'malformed percent-escape'},
    }
    for _, c in ipairs(cases) do
        local tmpl, err = tc._parse_template(c[1])
        t.assert_equals(tmpl, nil, c[1])
        t.assert_str_contains(err, c[2], false, c[1])
    end
end

-- ---------------------------------------------------------------------------
-- Matcher
-- ---------------------------------------------------------------------------

local gm = t.group('transcode.match')

-- match_path(pattern, path) -> {var = raw capture} or nil, verb applied
-- the way the router applies it.
local function match_path(pattern, path)
    local tmpl = assert(tc._parse_template(pattern))
    local segs = {}
    for s in (path:sub(2) .. '/'):gmatch('([^/]*)/') do segs[#segs + 1] = s end
    local n = #segs
    local last = segs[n]
    if tmpl.verb then
        local suf = ':' .. tmpl.verb
        if last:sub(-#suf) ~= suf then return nil end
        last = last:sub(1, #last - #suf)
    end
    if not tc._match(tmpl, segs, n, last) then return nil end
    local out = {}
    for _, v in ipairs(tmpl.vars) do
        out[v.name] = tc._pct_decode(tc._capture(tmpl, v, segs, n, last), v.multi)
    end
    return out
end

gm.test_matches = function()
    local cases = {
        {'/v1/{name=messages/*}', '/v1/messages/123456', {name = 'messages/123456'}},
        {'/v1/messages/{message_id}', '/v1/messages/123456', {message_id = '123456'}},
        {'/v1/messages/{message_id}', '/v1/messages', nil},
        {'/v1/messages/{message_id}', '/v1/messages/1/2', nil},
        {'/v1/messages/{message_id}', '/v1/messages/', nil},
        {'/v1/messages/{message_id}', '/v2/messages/1', nil},
        {'/v1/{path=files/**}', '/v1/files/a/b/c.txt', {path = 'files/a/b/c.txt'}},
        {'/v1/{path=files/**}', '/v1/files', {path = 'files'}},
        {'/v1/{path=**}', '/v1/a/b', {path = 'a/b'}},
        {'/v1/books:lookup', '/v1/books:lookup', {}},
        {'/v1/books:lookup', '/v1/books', nil},
        {'/v1/books:lookup', '/v1/books:other', nil},
        {'/v1/shelves/{book.shelf}/books/{book.name}:move', '/v1/shelves/s1/books/b2:move',
         {['book.shelf'] = 's1', ['book.name'] = 'b2'}},
        -- Without a verb in the template the colon stays in the value.
        {'/v1/{name=shelves/*}', '/v1/shelves/1:x', {name = 'shelves/1:x'}},
        -- Literal segments match their percent-decoded form too.
        {'/v1/a%20b', '/v1/a%20b', {}},
        {'/v1/a%20b', '/v1/a b', {}},
        {'/v1/ab', '/v1/%61b', {}},
    }
    for _, c in ipairs(cases) do
        t.assert_equals(match_path(c[1], c[2]), c[3], c[1] .. ' vs ' .. c[2])
    end
end

-- http.proto: single-segment variables are fully percent-decoded;
-- multi-segment ones too, except %2F / %2f stay encoded.
gm.test_percent_decoding = function()
    local cases = {
        {'/v1/{id}', '/v1/a%20b', {id = 'a b'}},
        {'/v1/{id}', '/v1/a%2Fb', {id = 'a/b'}},
        {'/v1/{id}', '/v1/a%2fb', {id = 'a/b'}},
        {'/v1/{id}', '/v1/%E2%9C%93', {id = '\xE2\x9C\x93'}},
        {'/v1/{id=*}', '/v1/x%3Ay', {id = 'x:y'}},
        {'/v1/{path=**}', '/v1/a%2Fb/c%20d', {path = 'a%2Fb/c d'}},
        {'/v1/{path=**}', '/v1/a%2fb', {path = 'a%2fb'}},
        {'/v1/{name=shelves/*}', '/v1/shelves/x%2Fy', {name = 'shelves/x%2Fy'}},
        {'/v1/{id}', '/v1/bad%zz', {}},   -- decode fails: capture is nil
    }
    for _, c in ipairs(cases) do
        t.assert_equals(match_path(c[1], c[2]), c[3], c[1] .. ' vs ' .. c[2])
    end
end

-- ---------------------------------------------------------------------------
-- Every example of the http.proto doc comment
-- ---------------------------------------------------------------------------

local gh = t.group('transcode.http_proto')

gh.test_get_message_name_pattern = function()
    -- get: "/v1/{name=messages/*}"
    local m = pb.parse([[
        syntax = "proto3"; package example.v1;
        service Messaging { rpc GetMessage(GetMessageRequest) returns (Message); }
        message GetMessageRequest { string name = 1; }
        message Message { string text = 1; }
    ]])
    local srv, calls = fake_server(m.Messaging_service, {
        GetMessage = {{method = 'GET', pattern = '/v1/{name=messages/*}'}},
    }, function() return {text = 'hello'} end)
    local router = tc.new({srv})
    local req, resp = call(router, calls, 'GET', '/v1/messages/123456')
    t.assert_equals(req, {name = 'messages/123456'})
    t.assert_equals(json.decode(resp.body), {text = 'hello'})
end

local GET_MESSAGE_WITH_SUB = [[
    syntax = "proto3"; package example.v1;
    service Messaging { rpc GetMessage(GetMessageRequest) returns (Message); }
    message GetMessageRequest {
      message SubMessage { string subfield = 1; }
      string message_id = 1;
      int64 revision = 2;
      SubMessage sub = 3;
    }
    message Message { string text = 1; }
]]

gh.test_get_message_query_parameters = function()
    -- get:"/v1/messages/{message_id}"; unbound fields become query params.
    local m = pb.parse(GET_MESSAGE_WITH_SUB)
    local srv, calls = fake_server(m.Messaging_service, {
        GetMessage = {{method = 'GET', pattern = '/v1/messages/{message_id}'}},
    })
    local router = tc.new({srv})
    local req = call(router, calls, 'GET', '/v1/messages/123456?revision=2&sub.subfield=foo')
    t.assert_equals(req.message_id, '123456')
    t.assert_equals(req.revision, i64('2'))
    t.assert_equals(req.sub, {subfield = 'foo'})
end

gh.test_service_config_nested_path_variable = function()
    -- get: /v1/messages/{message_id}/{sub.subfield}
    local m = pb.parse(GET_MESSAGE_WITH_SUB)
    local srv, calls = fake_server(m.Messaging_service, {
        GetMessage = {{method = 'GET', pattern = '/v1/messages/{message_id}/{sub.subfield}'}},
    })
    local router = tc.new({srv})
    local req = call(router, calls, 'GET', '/v1/messages/123456/foo')
    t.assert_equals(req, {message_id = '123456', sub = {subfield = 'foo'}})
end

gh.test_update_message_body_field = function()
    -- patch: "/v1/messages/{message_id}" body: "message"
    local m = pb.parse([[
        syntax = "proto3"; package example.v1;
        service Messaging { rpc UpdateMessage(UpdateMessageRequest) returns (Message); }
        message UpdateMessageRequest { string message_id = 1; Message message = 2; }
        message Message { string text = 1; }
    ]])
    local srv, calls = fake_server(m.Messaging_service, {
        UpdateMessage = {{method = 'PATCH', pattern = '/v1/messages/{message_id}',
                          body = 'message'}},
    })
    local router = tc.new({srv})
    local req = call(router, calls, 'PATCH', '/v1/messages/123456', '{ "text": "Hi!" }')
    t.assert_equals(req, {message_id = '123456', message = {text = 'Hi!'}})
end

gh.test_update_message_body_star = function()
    -- patch: "/v1/messages/{message_id}" body: "*"
    local m = pb.parse([[
        syntax = "proto3"; package example.v1;
        service Messaging { rpc UpdateMessage(Message) returns (Message); }
        message Message { string message_id = 1; string text = 2; }
    ]])
    local srv, calls = fake_server(m.Messaging_service, {
        UpdateMessage = {{method = 'PATCH', pattern = '/v1/messages/{message_id}', body = '*'}},
    })
    local router = tc.new({srv})
    local req = call(router, calls, 'PATCH', '/v1/messages/123456', '{ "text": "Hi!" }')
    t.assert_equals(req, {message_id = '123456', text = 'Hi!'})
    -- With body "*" there are no query parameters.
    req = call(router, calls, 'PATCH', '/v1/messages/1?text=fromquery', '{}')
    t.assert_equals(req, {message_id = '1'})
    -- A field bound by the path is not taken from the body.
    req = call(router, calls, 'PATCH', '/v1/messages/1', '{"messageId": "2", "text": "x"}')
    t.assert_equals(req, {message_id = '1', text = 'x'})
end

gh.test_additional_bindings = function()
    -- get: "/v1/messages/{message_id}"
    -- additional_bindings { get: "/v1/users/{user_id}/messages/{message_id}" }
    local m = pb.parse([[
        syntax = "proto3"; package example.v1;
        service Messaging { rpc GetMessage(GetMessageRequest) returns (Message); }
        message GetMessageRequest { string message_id = 1; string user_id = 2; }
        message Message { string text = 1; }
    ]])
    local srv, calls = fake_server(m.Messaging_service, {
        GetMessage = {
            {method = 'GET', pattern = '/v1/messages/{message_id}'},
            {method = 'GET', pattern = '/v1/users/{user_id}/messages/{message_id}'},
        },
    })
    local router = tc.new({srv})
    t.assert_equals(call(router, calls, 'GET', '/v1/messages/123456'),
                    {message_id = '123456'})
    t.assert_equals(call(router, calls, 'GET', '/v1/users/me/messages/123456'),
                    {user_id = 'me', message_id = '123456'})
end

-- ---------------------------------------------------------------------------
-- Query binding and value conversion
-- ---------------------------------------------------------------------------

local gq = t.group('transcode.query')

local QUERY_SCHEMA = [[
    syntax = "proto3"; package q;
    import "google/protobuf/timestamp.proto";
    import "google/protobuf/duration.proto";
    import "google/protobuf/wrappers.proto";
    enum Color { COLOR_UNSPECIFIED = 0; RED = 1; GREEN = 2; }
    message Inner { string s = 1; int32 n = 2; Deep deep = 3; }
    message Deep { bool flag = 1; }
    message Req {
      string id = 1;
      repeated string tags = 2;
      repeated int32 nums = 3;
      Color color = 4;
      repeated Color colors = 5;
      int64 big = 6;
      uint64 ubig = 7;
      bool on = 8;
      bytes blob = 9;
      double ratio = 10;
      float f = 11;
      int32 small = 12;
      uint32 usmall = 13;
      sint64 sbig = 14;
      Inner inner = 15;
      repeated Inner inners = 16;
      map<string, string> labels = 17;
      oneof choice { string a = 18; string b = 19; }
      google.protobuf.Timestamp at = 20;
      google.protobuf.Duration ttl = 21;
      google.protobuf.Int64Value wbig = 22;
      google.protobuf.BoolValue wbool = 23;
      string page_token = 24;
    }
    message Resp { string id = 1; }
    service Q { rpc Get(Req) returns (Resp); }
]]

local function query_router()
    local m = pb.parse(QUERY_SCHEMA)
    local srv, calls = fake_server(m.Q_service, {
        Get = {{method = 'GET', pattern = '/v1/items/{id}'}},
    })
    return tc.new({srv}), calls, m
end

local function bad_request(router, path, needle)
    local resp = router:handle(request('GET', path))
    t.assert_not_equals(resp, nil, path)
    t.assert_equals(resp.status, 400, path .. ': ' .. tostring(resp.body))
    local body = json.decode(resp.body)
    t.assert_equals(body.code, 3, path)
    t.assert_str_contains(body.message, needle, false, path)
end

gq.test_scalars = function()
    local router, calls = query_router()
    local req = call(router, calls, 'GET',
        '/v1/items/x?big=-9223372036854775808&ubig=18446744073709551615' ..
        '&on=true&ratio=0.5&f=-1.5e2&small=-7&usmall=4294967295&sbig=42')
    t.assert_equals(req.big, i64('-9223372036854775808'))
    t.assert_equals(req.ubig, u64('18446744073709551615'))
    t.assert_equals(req.on, true)
    t.assert_equals(req.ratio, 0.5)
    t.assert_equals(req.f, -150)
    t.assert_equals(req.small, -7)
    t.assert_equals(req.usmall, 4294967295)
    t.assert_equals(req.sbig, i64('42'))
end

gq.test_bools = function()
    local router, calls = query_router()
    for _, s in ipairs({'true', 'True', 'TRUE', 't', '1'}) do
        t.assert_equals(call(router, calls, 'GET', '/v1/items/x?on=' .. s).on, true, s)
    end
    for _, s in ipairs({'false', 'f', '0'}) do
        -- false is the proto3 default: encoded as absent.
        t.assert_equals(call(router, calls, 'GET', '/v1/items/x?on=' .. s).on, nil, s)
    end
end

gq.test_bytes_base64 = function()
    local router, calls = query_router()
    -- Standard alphabet (percent-encoded), URL-safe alphabet, no padding.
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?blob=AAH%2F').blob, '\x00\x01\xff')
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?blob=AAH_').blob, '\x00\x01\xff')
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?blob=aGk').blob, 'hi')
end

gq.test_enums_by_name_and_number = function()
    local router, calls = query_router()
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?color=RED').color, 1)
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?color=2').color, 2)
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?colors=RED&colors=2&colors=GREEN').colors,
                    {1, 2, 2})
end

gq.test_repeated_via_repeated_keys = function()
    local router, calls = query_router()
    local req = call(router, calls, 'GET', '/v1/items/x?tags=a&nums=1&tags=b&nums=-2&tags=')
    t.assert_equals(req.tags, {'a', 'b', ''})
    t.assert_equals(req.nums, {1, -2})
end

gq.test_nested_via_dotted_names = function()
    local router, calls = query_router()
    local req = call(router, calls, 'GET', '/v1/items/x?inner.s=hi&inner.n=3&inner.deep.flag=true')
    t.assert_equals(req.inner, {s = 'hi', n = 3, deep = {flag = true}})
end

gq.test_json_and_proto_names = function()
    local router, calls = query_router()
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?pageToken=p1').page_token, 'p1')
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?page_token=p2').page_token, 'p2')
end

gq.test_form_decoding = function()
    local router, calls = query_router()
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?tags=a+b&tags=c%26d&tags=%E2%9C%93').tags,
                    {'a b', 'c&d', '\xE2\x9C\x93'})
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?tags=noeq&tags').tags, {'noeq', ''})
end

gq.test_unknown_parameters_are_ignored = function()
    local router, calls = query_router()
    local req = call(router, calls, 'GET', '/v1/items/x?nope=1&inner.nope=2&id2=3&small=4')
    t.assert_equals(req, {id = 'x', small = 4})
end

gq.test_path_bound_field_not_overridden_by_query = function()
    local router, calls = query_router()
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?id=y').id, 'x')
end

gq.test_well_known_types = function()
    local router, calls = query_router()
    local req = call(router, calls, 'GET',
        '/v1/items/x?at=2024-01-02T03:04:05Z&ttl=1.5s&wbig=-5&wbool=true')
    t.assert_equals(req.ttl, {seconds = i64('1'), nanos = 500000000})
    t.assert_equals(req.wbig, i64('-5'))
    t.assert_equals(req.wbool, true)
    t.assert_equals(req.at.epoch, 1704164645)
end

-- Two members of one oneof from path/query/body: 400, the RPC is not
-- called (grpc-gateway rejects it too). The same member set by the
-- body and then by the path is not a conflict.
gq.test_oneof_conflicts_are_rejected = function()
    local router, calls = query_router()
    t.assert_equals(call(router, calls, 'GET', '/v1/items/x?a=1').a, '1')
    local before = #calls
    bad_request(router, '/v1/items/x?a=1&b=2', 'oneof "choice"')
    bad_request(router, '/v1/items/x?b=2&a=1', 'oneof "choice"')
    t.assert_equals(#calls, before)

    local m = pb.parse(QUERY_SCHEMA)
    local srv, pcalls = fake_server(m.Q_service, {
        Get = {{method = 'GET', pattern = '/v1/ab/{a}/{b}'},
               {method = 'PATCH', pattern = '/v1/a/{a}', body = '*'},
               {method = 'GET', pattern = '/v1/a/{a}'}},
    })
    local prouter = tc.new({srv})
    bad_request(prouter, '/v1/ab/1/2', 'oneof "choice"')
    bad_request(prouter, '/v1/a/1?b=2', 'oneof "choice"')
    t.assert_equals(#pcalls, 0)

    local resp = prouter:handle(request('PATCH', '/v1/a/1', '{"b": "x"}'))
    t.assert_equals(resp.status, 400, resp.body)
    t.assert_str_contains(json.decode(resp.body).message, 'oneof "choice"')
    t.assert_equals(#pcalls, 0)

    t.assert_equals(call(prouter, pcalls, 'PATCH', '/v1/a/1', '{"a": "x"}'), {a = '1'})
end

gq.test_rejected_values = function()
    local router = query_router()
    bad_request(router, '/v1/items/x?big=9223372036854775808', 'invalid value "9223372036854775808"')
    bad_request(router, '/v1/items/x?ubig=-1', '"ubig" (uint64)')
    bad_request(router, '/v1/items/x?small=2147483648', '"small"')
    bad_request(router, '/v1/items/x?small=1.5', '"small"')
    bad_request(router, '/v1/items/x?usmall=-1', '"usmall"')
    bad_request(router, '/v1/items/x?on=yes', '"on" (bool)')
    bad_request(router, '/v1/items/x?ratio=0x10', '"ratio"')
    bad_request(router, '/v1/items/x?color=BLUE', 'invalid value "BLUE"')
    bad_request(router, '/v1/items/x?blob=a!b', '"blob"')
    bad_request(router, '/v1/items/x?at=yesterday', '"at"')
    bad_request(router, '/v1/items/x?tags=%FF', '"tags" (string)')
    bad_request(router, '/v1/items/x?tags=%zz', 'malformed percent-encoding')
    bad_request(router, '/v1/items/x?small=1&small=2', 'more than once')
    bad_request(router, '/v1/items/x?inner=1', 'message field "inner"')
    bad_request(router, '/v1/items/x?labels=1', 'map field "labels"')
    bad_request(router, '/v1/items/x?inners.s=1', 'repeated message field "inners"')
end

gq.test_rejected_path_values = function()
    local m = pb.parse(QUERY_SCHEMA)
    local srv = fake_server(m.Q_service, {
        Get = {{method = 'GET', pattern = '/v1/items/{small}/{color}'}},
    })
    local router = tc.new({srv})
    bad_request(router, '/v1/items/abc/RED', 'path variable "small"')
    bad_request(router, '/v1/items/1/BLUE', 'path variable "color"')
    bad_request(router, '/v1/items/1%zz/RED', 'malformed percent-encoding in path')
end

-- ---------------------------------------------------------------------------
-- Route priority
-- ---------------------------------------------------------------------------

local gr = t.group('transcode.priority')

local PRIORITY_SCHEMA = [[
    syntax = "proto3"; package p;
    message Req { string name = 1; string id = 2; }
    message Resp { string text = 1; }
    service P {
      rpc A(Req) returns (Resp);
      rpc B(Req) returns (Resp);
      rpc C(Req) returns (Resp);
      rpc D(Req) returns (Resp);
      rpc E(Req) returns (Resp);
    }
]]

local function priority_router(rules)
    local m = pb.parse(PRIORITY_SCHEMA)
    local srv, calls = fake_server(m.P_service, rules)
    return tc.new({srv}), calls
end

local function winner(router, calls, method, path)
    local resp = router:handle(request(method, path))
    if resp == nil then return nil end
    t.assert_equals(resp.status, 200, resp.body)
    return calls[#calls].method
end

gr.test_literal_beats_variable_beats_double_star = function()
    local router, calls = priority_router({
        A = {{method = 'GET', pattern = '/v1/{name=**}'}},
        B = {{method = 'GET', pattern = '/v1/{name}'}},
        C = {{method = 'GET', pattern = '/v1/books'}},
        D = {{method = 'GET', pattern = '/v1/{name}/x'}},
        E = {{method = 'GET', pattern = '/v1/books/{id}'}},
    })
    t.assert_equals(winner(router, calls, 'GET', '/v1/books'), 'C')
    t.assert_equals(winner(router, calls, 'GET', '/v1/shelves'), 'B')
    t.assert_equals(winner(router, calls, 'GET', '/v1/a/b/c'), 'A')
    t.assert_equals(winner(router, calls, 'GET', '/v1/a/x'), 'D')
    -- Leftmost difference decides: literal "books" at position 2 wins
    -- over a variable there, whatever comes after.
    t.assert_equals(winner(router, calls, 'GET', '/v1/books/x'), 'E')
    t.assert_equals(winner(router, calls, 'GET', '/v1'), 'A')
end

gr.test_exact_end_beats_trailing_double_star = function()
    local router, calls = priority_router({
        A = {{method = 'GET', pattern = '/v1/{name=files/**}'}},
        B = {{method = 'GET', pattern = '/v1/files'}},
    })
    t.assert_equals(winner(router, calls, 'GET', '/v1/files'), 'B')
    t.assert_equals(winner(router, calls, 'GET', '/v1/files/a'), 'A')
end

gr.test_verb_beats_no_verb_and_declaration_order_breaks_ties = function()
    local router, calls = priority_router({
        A = {{method = 'POST', pattern = '/v1/{name}'}},
        B = {{method = 'POST', pattern = '/v1/{name}:run'}},
        C = {{method = 'GET', pattern = '/v1/{id}'}},
        D = {{method = 'GET', pattern = '/v1/{name}'}},
    })
    t.assert_equals(winner(router, calls, 'POST', '/v1/job:run'), 'B')
    t.assert_equals(winner(router, calls, 'POST', '/v1/job'), 'A')
    -- C and D have the same shape: declaration order (method name
    -- within a service) decides.
    t.assert_equals(winner(router, calls, 'GET', '/v1/x'), 'C')
end

gr.test_http_method_must_match = function()
    local router, calls = priority_router({
        A = {{method = 'GET', pattern = '/v1/{name}'}},
        B = {{method = 'DELETE', pattern = '/v1/{name}'}},
        C = {{method = '*', pattern = '/v1/any/{name}'}},
    })
    t.assert_equals(winner(router, calls, 'GET', '/v1/x'), 'A')
    t.assert_equals(winner(router, calls, 'DELETE', '/v1/x'), 'B')
    t.assert_equals(winner(router, calls, 'POST', '/v1/x'), nil)
    -- custom { kind: "*" } accepts any method.
    t.assert_equals(winner(router, calls, 'OPTIONS', '/v1/any/x'), 'C')
    t.assert_equals(winner(router, calls, 'GET', '/v1/any/x'), 'C')
end

gr.test_routes_introspection_in_priority_order = function()
    local router = priority_router({
        A = {{method = 'GET', pattern = '/v1/{name=**}'}},
        B = {{method = 'GET', pattern = '/v1/{name}'}, {method = 'POST', pattern = '/v1/x:go',
                                                        body = '*'}},
        C = {{method = 'GET', pattern = '/v1/books'}},
    })
    -- Same segment ranks: the template with a verb comes first.
    t.assert_equals(router:routes(), {
        {method = 'POST', pattern = '/v1/x:go', path = '/p.P/B', body = '*'},
        {method = 'GET', pattern = '/v1/books', path = '/p.P/C'},
        {method = 'GET', pattern = '/v1/{name}', path = '/p.P/B'},
        {method = 'GET', pattern = '/v1/{name=**}', path = '/p.P/A'},
    })
end

-- ---------------------------------------------------------------------------
-- new(): rules that are rejected or skipped
-- ---------------------------------------------------------------------------

local gn = t.group('transcode.new')

local NEW_SCHEMA = [[
    syntax = "proto3"; package n;
    message Inner { string s = 1; }
    message Req { string name = 1; repeated string tags = 2; Inner inner = 3;
                  map<string, string> labels = 4; repeated Inner inners = 5; }
    message Resp { string text = 1; }
    service N {
      rpc Get(Req) returns (Resp);
      rpc Watch(Req) returns (stream Resp);
      rpc Plain(Req) returns (Resp);
    }
]]

gn.test_rejected_rules = function()
    local m = pb.parse(NEW_SCHEMA)
    local cases = {
        {{method = 'GET', pattern = '/v1/{name'}, 'unbalanced "{"'},
        {{method = 'GET', pattern = '/v1/**/x'}, '"**" must be the last segment'},
        {{method = 'GET', pattern = '/v1/{nope}'}, 'n.Req has no field "nope"'},
        {{method = 'GET', pattern = '/v1/{inner.nope}'}, 'n.Inner has no field "nope"'},
        {{method = 'GET', pattern = '/v1/{tags}'}, 'field "tags" of n.Req must be a singular'},
        {{method = 'GET', pattern = '/v1/{inner}'}, 'field "inner" of n.Req must be a singular'},
        {{method = 'GET', pattern = '/v1/{labels}'}, 'field "labels"'},
        {{method = 'GET', pattern = '/v1/{inners.s}'}, 'field "inners" of n.Req is not a singular message'},
        {{method = 'GET', pattern = '/v1/{name.x}'}, 'field "name" of n.Req is not a singular message'},
        {{method = 'POST', pattern = '/v1/x', body = 'nope'}, 'body field "nope"'},
        {{method = 'GET', pattern = '/v1/x', response_body = 'nope'}, 'response_body field "nope"'},
    }
    for _, c in ipairs(cases) do
        local srv = fake_server(m.N_service, {Get = {c[1]}})
        local ok, err = pcall(tc.new, {srv})
        t.assert_not(ok, c[1].pattern)
        err = tostring(err)
        t.assert_str_contains(err, '/n.N/Get', false, c[1].pattern)
        t.assert_str_contains(err, c[1].pattern, false, c[1].pattern)
        t.assert_str_contains(err, c[2], false, c[1].pattern)
    end
end

gn.test_bad_arguments = function()
    t.assert_error_msg_contains('servers must be an array', tc.new, 'x')
    t.assert_error_msg_contains('servers[1] is not a generated server table', tc.new, {{}})
    t.assert_error_msg_contains('opts.json must be a table', tc.new, {}, {json = 1})
end

gn.test_streaming_rules_are_skipped = function()
    local m = pb.parse(NEW_SCHEMA)
    local srv, calls = fake_server(m.N_service, {
        Watch = {{method = 'GET', pattern = '/v1/watch/{name}'}},
        Get = {{method = 'GET', pattern = '/v1/get/{name}'}},
    })
    local router = tc.new({srv})
    t.assert_equals(#router:routes(), 1)
    t.assert_equals(router:handle(request('GET', '/v1/watch/x')), nil)
    t.assert_equals(winner(router, calls, 'GET', '/v1/get/x'), 'Get')
end

-- A hand-written methods[path] function may answer nil, code, message.
gn.test_transport_style_failure = function()
    local m = pb.parse(NEW_SCHEMA)
    local srv = fake_server(m.N_service, {Get = {{method = 'GET', pattern = '/v1/get/{name}'}}})
    srv.methods['/n.N/Get'] = function() return nil, pb.grpc.code.PERMISSION_DENIED, 'nope' end
    local resp = tc.new({srv}):handle(request('GET', '/v1/get/x'))
    t.assert_equals(resp.status, 403)
    t.assert_equals(json.decode(resp.body), {code = 7, message = 'nope', details = {}})
    srv.methods['/n.N/Get'] = function() return nil end
    resp = tc.new({srv}):handle(request('GET', '/v1/get/x'))
    t.assert_equals(resp.status, 500)
end

gn.test_unbound_methods = function()
    local m = pb.parse(NEW_SCHEMA)
    local srv, calls = fake_server(m.N_service, {
        Get = {{method = 'GET', pattern = '/v1/get/{name}'}},
    }, function(_, req) return {text = 'got ' .. (req.name or '')} end)
    t.assert_equals(tc.new({srv}):handle(request('POST', '/n.N/Plain', '{}')), nil)

    local router = tc.new({srv}, {unbound = true})
    -- Two literals that end beat two literals followed by a variable.
    t.assert_equals(router:routes(), {
        {method = 'POST', pattern = '/n.N/Plain', path = '/n.N/Plain', body = '*'},
        {method = 'GET', pattern = '/v1/get/{name}', path = '/n.N/Get'},
    })
    local resp = router:handle(request('POST', '/n.N/Plain', '{"name": "x", "tags": ["a"]}'))
    t.assert_equals(resp.status, 200)
    t.assert_equals(json.decode(resp.body), {text = 'got x'})
    t.assert_equals(calls[#calls].req, {name = 'x', tags = {'a'}})
    -- Annotated and streaming methods get no unbound route.
    t.assert_equals(router:handle(request('POST', '/n.N/Get', '{}')), nil)
    t.assert_equals(router:handle(request('POST', '/n.N/Watch', '{}')), nil)
end

-- ---------------------------------------------------------------------------
-- End to end against the generated library example, both codegen modes
-- ---------------------------------------------------------------------------

for _, mode in ipairs({'full', 'runtime'}) do
    local lib = require(mode .. '.library.library_pb')
    local g = t.group('transcode.library.' .. mode)

    local function new_router(impl, opts)
        local seen = {}
        local wrapped = {}
        for name, fn in pairs(impl) do
            wrapped[name] = function(req, ctx)
                seen[#seen + 1] = {method = name, req = req, ctx = ctx}
                return fn(req, ctx)
            end
        end
        return tc.new({lib.Library_server(wrapped)}, opts), seen
    end

    local function handle(router, method, path, body, headers)
        return router:handle(request(method, path, body, headers))
    end

    g.test_get_book = function()
        local router, seen = new_router({
            GetBook = function(req) return {name = req.name, title = 'Dune'} end,
        })
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 200)
        t.assert_equals(resp.headers['content-type'], 'application/json')
        -- Defaults are emitted (grpc-gateway convention), camelCase names.
        t.assert_equals(json.decode(resp.body),
            {name = 'shelves/1/books/2', title = 'Dune', shelf = '', author = '', isbn = ''})
        t.assert_equals(seen[1].req, {name = 'shelves/1/books/2'})
    end

    g.test_json_options_pass_through = function()
        local router = new_router({
            ListBooks = function() return {next_page_token = 'n'} end,
        }, {json = {emit_defaults = false, use_proto_names = true}})
        local resp = handle(router, 'GET', '/v1/shelves/1/books')
        t.assert_equals(json.decode(resp.body), {next_page_token = 'n'})
    end

    g.test_list_books_query = function()
        local router, seen = new_router({
            ListBooks = function() return {books = {{name = 'a'}}, next_page_token = 'n'} end,
        })
        local resp = handle(router, 'GET', '/v1/shelves/7/books?pageSize=10&page_token=t&x=1')
        t.assert_equals(resp.status, 200)
        t.assert_equals(seen[1].req, {parent = 'shelves/7', page_size = 10, page_token = 't'})
        local body = json.decode(resp.body)
        t.assert_equals(body.nextPageToken, 'n')
        t.assert_equals(body.books[1].name, 'a')
    end

    g.test_create_book_body_field = function()
        local router, seen = new_router({
            CreateBook = function(req) return req.book or {} end,
        })
        -- Query parameters under the body field are not bound.
        local resp = handle(router, 'POST', '/v1/shelves/1/books?book.title=q',
                            '{"title": "T", "isbn": "1"}')
        t.assert_equals(resp.status, 200, resp.body)
        t.assert_equals(seen[1].req, {parent = 'shelves/1', book = {title = 'T', isbn = '1'}})
        -- An empty body is an empty body field.
        resp = handle(router, 'POST', '/v1/shelves/1/books', '')
        t.assert_equals(resp.status, 200, resp.body)
        t.assert_equals(seen[2].req, {parent = 'shelves/1'})
    end

    -- http.proto: fields bound by the path are not taken from the body.
    g.test_update_book_path_wins_over_body = function()
        local router, seen = new_router({
            UpdateBook = function(req) return req.book end,
        })
        local resp = handle(router, 'PATCH', '/v1/shelves/1/books/2',
                            '{"name": "shelves/9/books/9", "title": "T"}')
        t.assert_equals(resp.status, 200, resp.body)
        t.assert_equals(seen[1].req.book, {name = 'shelves/1/books/2', title = 'T'})

        resp = handle(router, 'PUT', '/v1/shelves/1/books/2',
                      '{"book": {"name": "shelves/9/books/9", "author": "A"}}')
        t.assert_equals(resp.status, 200, resp.body)
        t.assert_equals(seen[2].req.book, {name = 'shelves/1/books/2', author = 'A'})
    end

    g.test_lookup_response_body = function()
        local router, seen = new_router({
            LookupBook = function(req) return {book = {isbn = req.isbn, title = 'T'}} end,
        })
        local resp = handle(router, 'GET', '/v1/books:lookup?isbn=42')
        t.assert_equals(resp.status, 200, resp.body)
        local body = json.decode(resp.body)
        t.assert_equals(body.isbn, '42')
        t.assert_equals(body.title, 'T')
        t.assert_equals(body.book, nil)
        resp = handle(router, 'POST', '/v1/books:lookup', '{"isbn": "43"}')
        t.assert_equals(json.decode(resp.body).isbn, '43')
        t.assert_equals(#seen, 2)
    end

    g.test_move_book_verb = function()
        local router, seen = new_router({
            MoveBook = function(req) return req.book end,
        })
        local resp = handle(router, 'POST', '/v1/shelves/s1/books/b2:move',
                            '{"destinationShelf": "s3"}')
        t.assert_equals(resp.status, 200, resp.body)
        t.assert_equals(seen[1].req, {book = {shelf = 's1', name = 'b2'}, destination_shelf = 's3'})
        t.assert_equals(handle(router, 'POST', '/v1/shelves/s1/books/b2', '{}'), nil)
    end

    g.test_get_message_bindings = function()
        local router, seen = new_router({
            GetMessage = function() return {text = 'ok'} end,
        })
        t.assert_equals(handle(router, 'GET', '/v1/messages/1?revision=2&sub.subfield=foo').status, 200)
        t.assert_equals(seen[1].req.revision, i64('2'))
        t.assert_equals(seen[1].req.sub, {subfield = 'foo'})
        t.assert_equals(handle(router, 'GET', '/v1/users/me/messages/1').status, 200)
        t.assert_equals(seen[2].req, {user_id = 'me', message_id = '1'})
        t.assert_equals(handle(router, 'GET', '/v1/messages/1/revisions/9223372036854775807').status, 200)
        t.assert_equals(seen[3].req.revision, i64('9223372036854775807'))
    end

    g.test_get_file_double_star = function()
        local router, seen = new_router({
            GetFile = function(req) return {path = req.path, content = 'x'} end,
        })
        local resp = handle(router, 'GET', '/v1/files/a/b%2Fc/d%20e.txt')
        t.assert_equals(resp.status, 200)
        t.assert_equals(seen[1].req.path, 'files/a/b%2Fc/d e.txt')
        t.assert_equals(json.decode(resp.body).content, 'eA==')
    end

    g.test_check_book_head_has_no_body = function()
        local router, seen = new_router({CheckBook = function() return {} end})
        local resp = handle(router, 'HEAD', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 200)
        t.assert_equals(resp.body, '')
        t.assert_equals(seen[1].req, {name = 'shelves/1/books/2'})
    end

    g.test_delete_book_empty_response = function()
        local router = new_router({DeleteBook = function() return {} end})
        local resp = handle(router, 'DELETE', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 200)
        t.assert_equals(resp.body, '{}')
    end

    g.test_no_route = function()
        local router = new_router({})
        t.assert_equals(handle(router, 'GET', '/v2/shelves/1/books/2'), nil)
        t.assert_equals(handle(router, 'POST', '/v1/shelves/1/books/2'), nil)
        t.assert_equals(handle(router, 'GET', 'relative'), nil)
        t.assert_equals(handle(router, 'GET', '/v1/shelves/1/books/2/'), nil)
    end

    g.test_status_error = function()
        local router = new_router({
            GetBook = function(req, ctx)
                ctx.response_metadata['x-reason'] = 'gone'
                pb.grpc.error(pb.grpc.code.NOT_FOUND, 'no ' .. req.name)
            end,
        })
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 404)
        t.assert_equals(resp.headers['content-type'], 'application/json')
        t.assert_equals(resp.headers['x-reason'], 'gone')
        t.assert_equals(json.decode(resp.body),
                        {code = 5, message = 'no shelves/1/books/2', details = {}})
    end

    g.test_status_details = function()
        local packed = pb.any.pack(lib.Book_descriptor, {name = 'b'})
        pb.register(lib.Book_descriptor)
        local router = new_router({
            GetBook = function()
                pb.grpc.error('FAILED_PRECONDITION', 'locked', {packed,
                    {type_url = 'type.googleapis.com/x.Unknown', value = '\x08\x01'}})
            end,
        })
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 400)
        local body = json.decode(resp.body)
        t.assert_equals(body.code, 9)
        -- A registered type renders as its JSON (defaults emitted too).
        t.assert_equals(body.details[1]['@type'], packed.type_url)
        t.assert_equals(body.details[1].name, 'b')
        t.assert_equals(body.details[1].title, '')
        -- Unregistered types fall back to base64 of the payload.
        t.assert_equals(body.details[2], {['@type'] = 'type.googleapis.com/x.Unknown',
                                          value = 'CAE='})
    end

    g.test_plain_error_is_internal_without_leaking = function()
        local router = new_router({
            GetBook = function() error('secret database password') end,
        })
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 500)
        t.assert_equals(json.decode(resp.body), {code = 13, message = 'internal error', details = {}})
        t.assert_not_str_contains(resp.body, 'secret')
    end

    g.test_missing_handler_is_unimplemented = function()
        local router = new_router({})
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2')
        t.assert_equals(resp.status, 501)
        t.assert_equals(json.decode(resp.body).code, 12)
    end

    g.test_bad_json_body = function()
        local router, seen = new_router({UpdateBook = function(req) return req.book end})
        for _, body in ipairs({'{bad', '[1]', '{"title": 5}', '{"title": "a", "title": "b"}'}) do
            local resp = handle(router, 'PATCH', '/v1/shelves/1/books/2', body)
            t.assert_equals(resp.status, 400, body)
            local st = json.decode(resp.body)
            t.assert_equals(st.code, 3, body)
            t.assert_str_contains(st.message, 'invalid JSON body', false, body)
            t.assert_not_str_contains(st.message, '.lua:', false, body)
        end
        t.assert_equals(#seen, 0)
    end

    g.test_body_ignored_without_body_rule = function()
        local router, seen = new_router({GetBook = function() return {} end})
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2', '{"name": "other"}')
        t.assert_equals(resp.status, 200)
        t.assert_equals(seen[1].req, {name = 'shelves/1/books/2'})
    end

    g.test_ctx_built_from_request = function()
        local router, seen = new_router({
            GetBook = function(_, ctx)
                ctx.response_metadata['x-trace'] = 'abc'
                ctx.response_metadata['x-multi'] = {'a', 'b'}
                return {}
            end,
        })
        local resp = handle(router, 'GET', '/v1/shelves/1/books/2', '', {
            ['authorization'] = 'Bearer x', ['connection'] = 'keep-alive',
            ['content-length'] = '0', ['transfer-encoding'] = 'chunked', ['x-custom'] = '1',
        })
        local ctx = seen[1].ctx
        t.assert_equals(ctx.method, '/library.Library/GetBook')
        t.assert_equals(ctx.peer, '127.0.0.1:5000')
        t.assert_equals(ctx.metadata, {authorization = 'Bearer x', ['x-custom'] = '1'})
        t.assert_equals(ctx:is_cancelled(), false)
        t.assert_equals(resp.headers['x-trace'], 'abc')
        t.assert_equals(resp.headers['x-multi'], 'a, b')
    end

    g.test_ctx_passed_through = function()
        local router, seen = new_router({GetBook = function() return {} end})
        local ctx = {method = 'given', metadata = {a = '1'}}
        local resp = router:handle(request('GET', '/v1/shelves/1/books/2'), ctx)
        t.assert_equals(resp.status, 200)
        t.assert_is(seen[1].ctx, ctx)
        t.assert_equals(ctx.response_metadata, {})
    end

    g.test_query_after_fragment_and_path_encoding = function()
        local router, seen = new_router({GetBook = function() return {} end})
        t.assert_equals(handle(router, 'GET', '/v1/shelves/a%20b/books/2#frag').status, 200)
        t.assert_equals(seen[1].req.name, 'shelves/a b/books/2')
    end
end
