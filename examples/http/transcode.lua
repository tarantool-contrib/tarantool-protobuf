-- HTTP/JSON transcoding of the library example service.
--
-- examples/proto/library.proto annotates its methods with
-- google.api.http rules. pb.transcode turns them into a router: give it
-- an HTTP request table, get back a response table. There is no socket
-- here; an HTTP server hands each request to router:handle() and sends
-- the result.
--
-- Run: `just examples transcode`.
local json = require('json')
local pb = require('pb')
local lib = require('full.library.library_pb')

-- An in-memory shelf; a real service would use a space.
local books = {
    ['shelves/1/books/1'] = {name = 'shelves/1/books/1', title = 'Dune', isbn = '42'},
}

local impl = {}

function impl.GetBook(req)
    local book = books[req.name]
    if book == nil then
        pb.grpc.error(pb.grpc.code.NOT_FOUND, 'no book ' .. req.name)
    end
    return book
end

function impl.ListBooks(req)
    local out = {}
    for name, book in pairs(books) do
        if name:sub(1, #req.parent + 1) == req.parent .. '/' then
            out[#out + 1] = book
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    local limit = req.page_size or 0
    if limit > 0 and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return {books = out}
end

local next_id = 2

function impl.CreateBook(req)
    local book = req.book or {}
    book.name = ('%s/books/%d'):format(req.parent, next_id)
    next_id = next_id + 1
    books[book.name] = book
    return book
end

function impl.UpdateBook(req)
    -- The path binds book.name; the body cannot redirect the update.
    local book = books[req.book.name]
    if book == nil then pb.grpc.error('NOT_FOUND', 'no book ' .. req.book.name) end
    for k, v in pairs(req.book) do book[k] = v end
    return book
end

function impl.LookupBook(req)
    for _, book in pairs(books) do
        if book.isbn == req.isbn then return {book = book} end
    end
    pb.grpc.error('NOT_FOUND', 'no book with isbn ' .. tostring(req.isbn))
end

local router = pb.transcode.new({lib.Library_server(impl)}, {
    -- proto3's elided form keeps the output short; the default emits
    -- every field, as grpc-gateway does.
    json = {emit_defaults = false},
})

print('routes:')
for _, r in ipairs(router:routes()) do
    print(('  %-6s %-48s -> %s'):format(r.method, r.pattern, r.path))
end

-- Print a response body with sorted keys, so the output is stable.
local function canonical(v)
    if type(v) ~= 'table' then return json.encode(v) end
    if v[1] ~= nil then
        local parts = {}
        for i, x in ipairs(v) do parts[i] = canonical(x) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = json.encode(k) .. ':' .. canonical(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

local function send(method, path, body)
    local resp = router:handle({
        method = method, path = path, headers = {['content-type'] = 'application/json'},
        body = body or '', version = 'HTTP/1.1', peer = '127.0.0.1:40000',
    })
    print()
    print(('%s %s%s'):format(method, path, body and (' ' .. body) or ''))
    if resp == nil then
        print('  no route (the HTTP server answers 404 or falls back)')
        return
    end
    print(('  %d %s'):format(resp.status, canonical(json.decode(resp.body))))
end

send('GET', '/v1/shelves/1/books/1')
send('POST', '/v1/shelves/1/books', '{"title": "Hyperion", "isbn": "43"}')
send('GET', '/v1/shelves/1/books?pageSize=10')
send('PATCH', '/v1/shelves/1/books/2', '{"name": "shelves/9/books/9", "author": "Simmons"}')
send('GET', '/v1/books:lookup?isbn=43')
send('GET', '/v1/shelves/1/books/404')
send('PATCH', '/v1/shelves/1/books/2', '{"title": ')
send('GET', '/v2/nothing')

os.exit(0)
