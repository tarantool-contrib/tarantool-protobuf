# How-to: HTTP/JSON transcoding with `google.api.http`

Annotate a gRPC method with a `google.api.http` rule and the same
handler also answers plain HTTP with JSON:

```proto
rpc GetBook(GetBookRequest) returns (Book) {
  option (google.api.http) = {
    get: "/v1/{name=shelves/*/books/*}"
  };
}
```

`GET /v1/shelves/1/books/2` becomes `GetBook(name: "shelves/1/books/2")`
and the `Book` comes back as proto3 JSON. This is the scheme Google APIs,
grpc-gateway, ESP and Envoy use, specified in
[`google/api/http.proto`](../../options/google/api/http.proto) (its doc
comment) and [AIP-127](https://google.aip.dev/127).

`pb.transcode` is the routing and binding half of it: a pure function
from an HTTP request table to a response table. **The network server
that listens on a port and feeds it requests is not shipped yet**
(see [specs/grpc_transports.md](../specs/grpc_transports.md)); until
then, call `router:handle()` from any HTTP server you already run, as
below.

The runnable version of this page is
[`examples/http/transcode.lua`](../../examples/http/transcode.lua):

```bash
just gen
just examples transcode
```

## 1. Annotate the proto

Import the annotation and add a rule per method.
[`examples/proto/library.proto`](../../examples/proto/library.proto)
has one of every shape:

```proto
import "google/api/annotations.proto";

service Library {
  rpc ListBooks(ListBooksRequest) returns (ListBooksResponse) {
    option (google.api.http) = { get: "/v1/{parent=shelves/*}/books" };
  }
  rpc CreateBook(CreateBookRequest) returns (Book) {
    option (google.api.http) = {
      post: "/v1/{parent=shelves/*}/books"
      body: "book"
    };
  }
  rpc UpdateBook(UpdateBookRequest) returns (Book) {
    option (google.api.http) = {
      patch: "/v1/{book.name=shelves/*/books/*}"
      body: "book"
      additional_bindings { put: "/v1/{book.name=shelves/*/books/*}" body: "*" }
    };
  }
  rpc LookupBook(LookupBookRequest) returns (LookupBookResponse) {
    option (google.api.http) = {
      post: "/v1/books:lookup"
      body: "*"
      response_body: "book"
    };
  }
}
```

Generate as usual; `google/api/annotations.proto` and `http.proto` are
under `options/`, so pass `-I options`. The plugin copies the rules into
the service descriptor (`M.Library_service.methods.GetBook.http`).

## 2. Build a router

```lua
local pb  = require('pb')
local lib = require('library_pb')

local router = pb.transcode.new({
    lib.Library_server(impl),   -- the same server table a gRPC transport takes
})
```

Every template is parsed and checked against the request message here,
so a typo in a pattern or a field name fails at startup with the method
and the pattern in the message, not on the first request.

`router:routes()` lists what is routed, in the order routes are tried.

## 3. Handle requests

```lua
local resp = router:handle({
    method  = 'GET',
    path    = '/v1/shelves/1/books?pageSize=10',   -- query string included
    headers = {['content-type'] = 'application/json'},
    body    = '',
    peer    = '127.0.0.1:40000',
})
-- resp = {status = 200, headers = {['content-type'] = 'application/json'},
--         body = '{"books":[...]}'}
```

`handle` returns `nil` when no route matches, so the HTTP server decides
whether that is a 404 or a fallback to other handlers.

To put it behind an existing HTTP server, register one catch-all route
that copies the method, the path with its query string, the lowercased
headers and the body into such a table, and copies `status`, `headers`
and `body` back (or answers 404 on `nil`).

The example prints, for the library service:

```
GET /v1/shelves/1/books/1
  200 {"isbn":"42","name":"shelves/1/books/1","title":"Dune"}

POST /v1/shelves/1/books {"title": "Hyperion", "isbn": "43"}
  200 {"isbn":"43","name":"shelves/1/books/2","title":"Hyperion"}

GET /v1/shelves/1/books?pageSize=10
  200 {"books":[{"isbn":"42","name":"shelves/1/books/1","title":"Dune"},{"isbn":"43","name":"shelves/1/books/2","title":"Hyperion"}]}

PATCH /v1/shelves/1/books/2 {"name": "shelves/9/books/9", "author": "Simmons"}
  200 {"author":"Simmons","isbn":"43","name":"shelves/1/books/2","title":"Hyperion"}

GET /v1/books:lookup?isbn=43
  200 {"author":"Simmons","isbn":"43","name":"shelves/1/books/2","title":"Hyperion"}

GET /v1/shelves/1/books/404
  404 {"code":5,"message":"no book shelves/1/books/404"}

PATCH /v1/shelves/1/books/2 {"title":
  400 {"code":3,"message":"invalid JSON body: Expected value but found end on line 1 at character 11 here 'title\":  >> '"}

GET /v2/nothing
  no route (the HTTP server answers 404 or falls back)
```

(The example sorts JSON keys before printing; `pb.json` itself emits
them in hash order.)

## How a request becomes a message

- **Path variables** (`{name=shelves/*}`, `{book.name}`) set the fields
  they name, nested ones included. A single-segment variable is fully
  percent-decoded; a multi-segment one keeps `%2F` encoded so a slash
  inside a value stays distinguishable.
- **The body**, when the rule has `body`: `"*"` is the whole message,
  `"book"` is the `book` field. A field bound by the path wins over the
  same field in the body — the `PATCH` above cannot move the book to
  `shelves/9`. A rule without `body` ignores the request body.
- **Query parameters** fill everything else (not with `body: "*"`):
  `?pageSize=10` or `?page_size=10`, `?sub.subfield=x` for nested
  fields, `?tag=a&tag=b` for repeated ones, enum names or numbers,
  64-bit integers as decimal strings, bytes as base64. Unknown
  parameters are ignored; a value that does not fit its field is a 400.

## Errors

Handlers fail a call the gRPC way, and the router turns it into HTTP:

```lua
pb.grpc.error(pb.grpc.code.NOT_FOUND, 'no book ' .. req.name)
-- 404 {"code": 5, "message": "no book shelves/1/books/404", "details": []}
```

The HTTP status comes from `pb.grpc.http_status`, the body is the
`google.rpc.Status` JSON shape. A plain Lua error in a handler becomes
`500 {"code": 13, "message": "internal error"}`; the real message goes
to the Tarantool log, not to the client.

## Options

```lua
pb.transcode.new(servers, {
    unbound = true,                 -- also POST /library.Library/<Method> for methods without rules
    json = {emit_defaults = false}, -- response JSON options; default emits every field
})
```

Only unary methods are routed; rules on streaming methods are skipped
with a warning in the log.

## What's next

- [Reference: runtime API → `pb.transcode`](../reference/runtime-api.md#httpjson-transcoding--pbtranscode)
  — every rule the router follows (template syntax, route priority,
  binding and error mapping).
- [`options/google/api/http.proto`](../../options/google/api/http.proto)
  — the specification the router implements.
- [gRPC with the loopback transport](03-grpc-loopback.md) — the same
  server table, called from Lua.
