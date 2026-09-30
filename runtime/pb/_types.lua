---@meta
--
-- Type declarations consumed by lua-language-server (sumneko/LuaLS) so
-- editors and LLM assistants get parameter / return types for the pb
-- runtime. The @meta directive prevents this file from being loaded at
-- run time; only the LSP reads it.
--
-- The descriptor shape mirrors docs/codegen.md § "The descriptor table".
-- Keep them aligned -- if you add a field there, add it here too.

---@class pb.FieldKey
---@field kind 'scalar'
---@field proto_type 'int32'|'uint32'|'sint32'|'fixed32'|'sfixed32'|'int64'|'uint64'|'sint64'|'fixed64'|'sfixed64'|'bool'|'string'|'bytes'|'float'|'double'

---@class pb.FieldValue
---@field kind 'scalar'|'message'|'enum'
---@field proto_type? string
---@field message?   pb.Descriptor
---@field enum?      pb.EnumDescriptor

---@class pb.Field
---@field name        string
---@field id          integer
---@field kind        'scalar'|'message'|'enum'|'map'|'group'
---@field proto_type? string                   # set when kind == 'scalar'
---@field message?    pb.Descriptor            # set when kind == 'message' or 'group'
---@field enum?       pb.EnumDescriptor        # set when kind == 'enum'
---@field key?        pb.FieldKey              # set when kind == 'map'
---@field value?      pb.FieldValue            # set when kind == 'map'
---@field repeated?   boolean
---@field packed?     boolean
---@field optional?   boolean                  # proto3 explicit-optional
---@field required?   boolean                  # proto2 only
---@field oneof?      string                   # name of the containing oneof, if any
---@field oneof_siblings? string[]             # filled by pb.finalize_message
---@field default_value? any                   # proto2 only
---@field key_dedup?  boolean                  # filled by pb.finalize_message for cdata-keyed maps

---@class pb.EnumDescriptor
---@field name     string
---@field by_name  table<string, integer>
---@field by_value table<integer, string>

---@class pb.OneofDescriptor
---@field name    string
---@field members string[]

---@class pb.Descriptor
---@field name            string
---@field fields          pb.Field[]
---@field field_by_id?    table<integer, pb.Field>           # filled by pb.finalize_message
---@field field_by_name?  table<string,  pb.Field>           # filled by pb.finalize_message
---@field oneofs?         table<string,  string[]>           # raw form; flattened to oneofs_list
---@field oneofs_list?    pb.OneofDescriptor[]               # filled by pb.finalize_message
---@field reserved_names? table<string, boolean>
---@field encode?         fun(t: table): string              # WKT override
---@field decode?         fun(b: string, depth?: integer): table # WKT override
---@field message_set?    boolean                            # extensions use the MessageSet item format
---@field text?           fun(t: table, opts?: pb.TextOpts): string
---@field json_encode?    fun(t: table): any
---@field json_decode?    fun(v: any): table
---@field c_plan?         table                              # internal: C-accel dispatch
---@field extensions_by_id?        table<integer, pb.Field>
---@field extensions_by_full_name? table<string,  pb.Field>
---@field extensions_list?         pb.Field[]

---@class pb.TextOpts
---@field single_line? boolean
---@field indent?      string

---@class pb.FileSet
---@field files  table<string, table>                        # filename -> generated-shaped module
---@field order  string[]                                    # filenames in declaration order
---@field lookup fun(full_name: string): pb.Descriptor?

---@class pb.Module
---@field encode      fun(desc: pb.Descriptor, t: table): string
---@field decode      fun(desc: pb.Descriptor, b: string): table
---@field decode_lazy fun(desc: pb.Descriptor, b: string): pb.MessageView
---@field lazy        pb.Lazy
---@field wire        pb.Wire
---@field codec       table                                  # internal: shared with generated code
---@field wkt         pb.Wkt
---@field NULL        userdata                               # google.protobuf.Value null sentinel
---@field register    fun(desc: pb.Descriptor): pb.Descriptor
---@field lookup      fun(name_or_url: string): pb.Descriptor?
---@field any         pb.Any
---@field grpc        pb.Grpc
---@field transcode   pb.Transcode
---@field c_runtime?  table                                  # set when PB_ENABLE_C=1 and load succeeds
---@field parse       fun(source: string): table             # AST -> runtime module
---@field from_pb     fun(bytes: string): pb.FileSet
---@field parser      table
---@field dynamic     table
---@field fileset     table
---@field json        pb.Json
---@field text        pb.Text
---@field tuple       pb.Tuple
---@field WIRE_VARINT integer
---@field WIRE_I64    integer
---@field WIRE_LEN    integer
---@field WIRE_I32    integer
---@field to_uint64   fun(v: any): ffi.cdata*
---@field to_int64    fun(v: any): ffi.cdata*
---@field field_names fun(tbl: table<string, string>): table
---@field enum        fun(name: string, values: table<string, integer>): pb.EnumDescriptor
---@field finalize_message fun(desc: pb.Descriptor): pb.Descriptor
---@field register_extension fun(extendee_desc: pb.Descriptor, ext: pb.Field)

---@class pb.AnyMessage
---@field type_url string
---@field value    string

---@class pb.Any
---@field pack   fun(desc: pb.Descriptor, t: table, type_url_prefix?: string): pb.AnyMessage
---@field unpack fun(any_msg: pb.AnyMessage, desc_override?: pb.Descriptor): table

---@class pb.Wkt
---@field NULL        userdata
---@field register    fun(desc: pb.Descriptor): pb.Descriptor    # key is desc.name; also indexes the default type.googleapis.com/ URL
---@field lookup      fun(name_or_url: string): pb.Descriptor?
---@field any_pack    fun(desc: pb.Descriptor, t: table, type_url_prefix?: string): pb.AnyMessage
---@field any_unpack  fun(any_msg: pb.AnyMessage, desc_override?: pb.Descriptor): table

---@class pb.JsonEncodeOpts
---@field use_proto_names?       boolean    emit snake_case field names instead of camelCase
---@field emit_defaults?         boolean    emit fields equal to proto3 defaults (alias: always_emit_zero_value)
---@field always_emit_zero_value? boolean   deprecated alias of emit_defaults
---@field emit_null_messages?    boolean    emit unset singular message fields (not oneof/optional) as null
---@field indent?                string     non-empty string ⇒ pretty-print with that indent unit

---@class pb.JsonDecodeOpts
---@field ignore_unknown_fields? boolean   silently drop unknown JSON fields instead of erroring

---@class pb.Json
---@field encode fun(desc: pb.Descriptor, t: table, opts?: pb.JsonEncodeOpts): string
---@field decode fun(desc: pb.Descriptor, s: string, opts?: pb.JsonDecodeOpts): table
---@field encode_field fun(desc: pb.Descriptor, t: table, field_name: string, opts?: pb.JsonEncodeOpts): string
---@field decode_field fun(desc: pb.Descriptor, field_name: string, s: string, opts?: pb.JsonDecodeOpts): any
---@field json_name fun(name: string): string

---@class pb.HttpRequest
---@field method  string
---@field path    string                 path with the query string, as received
---@field headers? table<string, string>  lowercased names
---@field body?    string
---@field version? string
---@field peer?    string

---@class pb.HttpResponse
---@field status  integer
---@field headers table<string, string>
---@field body    string

---@class pb.TranscodeRoute
---@field method  string
---@field pattern string
---@field path    string                 '/pkg.Service/Method'
---@field body?   string
---@field response_body? string

---@class pb.TranscodeRouter
---@field handle fun(self: pb.TranscodeRouter, req: pb.HttpRequest, ctx?: table): pb.HttpResponse?
---@field routes fun(self: pb.TranscodeRouter): pb.TranscodeRoute[]

---@class pb.Transcode
---@field new fun(servers: table[], opts?: pb.TranscodeOpts): pb.TranscodeRouter

---@class pb.Text
---@field encode fun(desc: pb.Descriptor, t: table, opts?: pb.TextOpts): string

---@class pb.TupleBindOpts
---@field columns? table<string, string>   proto field name -> column name
---@field omit?    string[]                proto fields left out of the projection

-- Converter between the tuples of one space and one message type; see
-- runtime/pb/tuple.lua for the binding and conversion rules.
---@class pb.TupleConverter
---@field plan            table                         the compiled plan (internal)
---@field schema_version  integer
---@field encode          fun(self: pb.TupleConverter, tuple: box.tuple): string
---@field encode_repeated fun(self: pb.TupleConverter, field_no: integer, tuples: box.tuple[]): string
---@field decode          fun(self: pb.TupleConverter, bytes: string): box.tuple
---@field insert          fun(self: pb.TupleConverter, bytes: string): box.tuple
---@field replace         fun(self: pb.TupleConverter, bytes: string): box.tuple

---@class pb.Tuple
---@field bind fun(desc: pb.Descriptor, space: table, opts?: pb.TupleBindOpts): pb.TupleConverter

---@class pb.Wire
---@field WIRE_VARINT     integer
---@field WIRE_I64        integer
---@field WIRE_LEN        integer
---@field WIRE_I32        integer
---@field encode_varint   fun(n: integer|ffi.cdata*): string
---@field decode_varint   fun(b: string, pos: integer): integer|ffi.cdata*, integer
---@field encode_tag      fun(field_id: integer, wire_type: integer): string
---@field decode_tag      fun(b: string, pos: integer): integer, integer, integer
---@field encode_string   fun(s: string): string
---@field decode_string   fun(b: string, pos: integer): string, integer
---@field encode_double   fun(v: number): string
---@field decode_double   fun(b: string, pos: integer): number, integer
---@field encode_float    fun(v: number): string
---@field decode_float    fun(b: string, pos: integer): number, integer
---@field to_uint64       fun(v: any): ffi.cdata*
---@field to_int64        fun(v: any): ffi.cdata*
---@field skip_field      fun(b: string, pos: integer, wire_type: integer, field_id: integer): integer

---@class pb.Lazy
---@field build       fun(desc: pb.Descriptor, b: string): pb.MessageView
---@field MessageView pb.MessageView
---@field ArrayView   pb.ArrayView
---@field MapView     pb.MapView

-- MessageView: zero-copy lazy decode of a single protobuf message.
-- `:get(name)` decodes the named field on demand; untouched fields
-- stay as raw bytes and are passed through verbatim on :encode().
-- Field names passed to :get / :has / :set / :which should be sourced
-- from the strict M.<Type>_fields table emitted by the codegen --
-- typos error at the read site instead of returning silent nil.
-- See docs/api-modes.md.
--
-- Method bodies live in runtime/pb/lazy.lua; the @class block there
-- merges with this one. Same shape for ArrayView and MapView.
---@class pb.MessageView
---@field get       fun(self: pb.MessageView, name: string): any
---@field has       fun(self: pb.MessageView, name: string): boolean
---@field which     fun(self: pb.MessageView, oneof_name: string): string|nil
---@field iter      fun(self: pb.MessageView): fun(): string|nil, any
---@field names     fun(self: pb.MessageView): string[]
---@field set       fun(self: pb.MessageView, name: string, value: any)
---@field is_dirty  fun(self: pb.MessageView): boolean
---@field totable   fun(self: pb.MessageView): table
---@field encode    fun(self: pb.MessageView): string

---@class pb.ArrayView
---@field len     fun(self: pb.ArrayView): integer
---@field at      fun(self: pb.ArrayView, i: integer): any
---@field iter    fun(self: pb.ArrayView): fun(): integer|nil, any
---@field tolist  fun(self: pb.ArrayView): any[]

---@class pb.MapView
---@field get      fun(self: pb.MapView, k: any): any
---@field has      fun(self: pb.MapView, k: any): boolean
---@field keys     fun(self: pb.MapView): any[]
---@field iter     fun(self: pb.MapView): fun(): any, any
---@field totable  fun(self: pb.MapView): table

---@class pb.Grpc
---@field loopback   fun(server: pb.GrpcServer): pb.GrpcTransport
---@field multiplex  fun(servers: table<string, pb.GrpcServer>): pb.GrpcTransport
---@field grpc_error fun(code: integer, message?: string, details?: table): pb.GrpcError

---@class pb.GrpcServer
---@field service pb.ServiceDescriptor
---@field methods table<string, fun(req: any, ctx?: table): any>

---@class pb.ServiceDescriptor
---@field name    string
---@field methods pb.MethodDescriptor[]

---@class pb.MethodDescriptor
---@field name             string
---@field path             string
---@field input            pb.Descriptor
---@field output           pb.Descriptor
---@field client_streaming boolean
---@field server_streaming boolean

-- Transport contract. Each method takes a path (string), a request
-- (bytes or a stream) and an optional context table, and returns a
-- response (bytes or a stream). Custom transports (HTTP/2, iproto,
-- etc.) implement this interface.
---@class pb.GrpcTransport
---@field unary             fun(self: pb.GrpcTransport, path: string, req: string, ctx?: table): string
---@field client_streaming  fun(self: pb.GrpcTransport, path: string, req_iter: fun():string|nil, ctx?: table): string
---@field server_streaming  fun(self: pb.GrpcTransport, path: string, req: string, ctx?: table): fun():string|nil
---@field bidi_streaming    fun(self: pb.GrpcTransport, path: string, req_iter: fun():string|nil, ctx?: table): fun():string|nil

---@class pb.GrpcError
---@field code    integer
---@field message string
---@field details? table

return {}
