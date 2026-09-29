-- Public surface of the protobuf runtime used by generated code.
--
-- Named `pb` (rather than `protobuf`) to avoid colliding with Tarantool's
-- built-in encode-only `require('protobuf')` module.
--
-- Generated `<file>_pb.lua` modules do:
--   local pb = require('pb')
--   ...
--   M.Person_encode = function(t) return pb.encode(M.Person_descriptor, t) end
--   M.Person_decode = function(b) return pb.decode(M.Person_descriptor, b) end
local codec   = require('pb.codec')
local wire    = require('pb.wire')
local wkt     = require('pb.wkt')
local grpc    = require('pb.grpc')
local parser  = require('pb.parser')
local dynamic = require('pb.dynamic')
local fileset = require('pb.fileset')
local pbjson  = require('pb.json')
local pbtext  = require('pb.text')
local lazy    = require('pb.lazy')
local tuple   = require('pb.tuple')

-- C-acceleration opt-in: PB_ENABLE_C=1 and a loadable pb.c_runtime. The
-- decision lives in pb.c_loader, shared with pb.tuple.
local c_runtime = require('pb.c_loader').runtime

-- High-level codec entry points. When the C runtime is loaded, dispatch
-- on desc.c_plan and lazily compile it on first call. Lazy compile is
-- required because compile_plan eagerly chases sub-message refs and
-- codegen forward-declares descriptors (see finalize_message above).
local pb_encode        = codec.encode
local pb_decode        = codec.decode
local pb_decode_unsafe = codec.decode_unsafe
if c_runtime ~= nil then
    local c_encode         = c_runtime.encode
    local c_decode         = c_runtime.decode
    local c_decode_unsafe  = c_runtime.decode_unsafe
    local c_compile        = c_runtime.compile_plan
    local lua_encode        = pb_encode
    local lua_decode        = pb_decode
    local lua_decode_unsafe = pb_decode_unsafe
    pb_encode = function(desc, t)
        local plan = desc.c_plan or c_compile(desc)
        if plan ~= nil then return c_encode(plan, t) end
        return lua_encode(desc, t)
    end
    pb_decode = function(desc, b)
        local plan = desc.c_plan or c_compile(desc)
        if plan ~= nil then return c_decode(plan, b) end
        return lua_decode(desc, b)
    end
    pb_decode_unsafe = function(desc, b)
        local plan = desc.c_plan or c_compile(desc)
        if plan ~= nil then return c_decode_unsafe(plan, b) end
        return lua_decode_unsafe(desc, b)
    end
end

---@type pb.Module
return {
    -- High-level codec
    encode = pb_encode,
    decode = pb_decode,
    -- Opt-in non-validating decode for trusted producers (re-decoding
    -- bytes from our own encoder, JSON/text round-trips, in-process
    -- typed RPC). Skips utf8_len on every string field; sub-message
    -- recursion stays on the unsafe path. When the C runtime is loaded
    -- this dispatches to c_runtime.decode_unsafe, which gates the
    -- is_valid_utf8 call on a dec_ctx.skip_utf8 flag. Generated
    -- runtime-mode wrappers `M.<Name>_decode_unsafe` forward into this;
    -- full-mode codegen inlines a literal sister `_decode_unsafe` body
    -- that itself dispatches to c_runtime.decode_unsafe at the prologue.
    decode_unsafe = pb_decode_unsafe,

    -- Lazy / zero-copy decode view. See runtime/pb/lazy.lua for the
    -- :get / :has / :which / :iter / :names surface on the returned
    -- MessageView (and ArrayView / MapView for repeated and map fields).
    decode_lazy = lazy.build,
    lazy        = lazy,

    -- Wire-format primitives (exposed for advanced users / tests)
    wire   = wire,

    -- Codec internals (exposed for generated inline code, e.g. to share
    -- merge_message with the runtime-mode codec).
    codec  = codec,

    -- Well-known types (google.protobuf.*) — see runtime/pb/wkt.lua.
    wkt    = wkt,

    -- Sentinel for google.protobuf.Value's null_value / JSON null.
    NULL   = wkt.NULL,

    -- Type registry (used by google.protobuf.Any pack/unpack).
    register = wkt.register,
    lookup   = wkt.lookup,
    any = {
        pack   = wkt.any_pack,
        unpack = wkt.any_unpack,
    },

    -- gRPC transport interface + loopback — see runtime/pb/grpc.lua.
    grpc   = grpc,

    -- C-acceleration runtime, or nil when disabled. Non-nil only when
    -- PB_ENABLE_C=1 is set at module load AND require('pb.c_runtime')
    -- succeeded. Exposed for introspection; do not call directly from
    -- user code — the encode/decode wrappers dispatch automatically
    -- via desc.c_plan. See docs/specs/c_accel_compat.md.
    c_runtime = c_runtime,

    -- Runtime .proto parsing: build a module from a .proto source string.
    --
    --   local hello = pb.parse(io.open('hello.proto'):read('*a'))
    --   local bytes = hello.Person_encode({name = 'Alice'})
    --
    -- Output shape mirrors what protoc-gen-tarantool emits in `mode=runtime`.
    parse = function(source) return dynamic.build(parser.parse(source)) end,

    -- Build runtime modules from a binary FileDescriptorSet, the output of
    -- `protoc --descriptor_set_out=...`. Useful for ingesting compiled
    -- artifacts or gRPC reflection responses without shipping .proto source.
    --
    --   local set = pb.from_pb(bytes)
    --   local hello = set.files['hello.proto']
    --   local desc  = set.lookup('hello.Person')
    --
    -- Returns {files = {[name] = module}, order = {names...}, lookup = fn}.
    from_pb = fileset.parse,

    -- Low-level access for advanced use.
    parser  = parser,
    dynamic = dynamic,
    fileset = fileset,

    -- proto3 JSON (canonical mapping). pb.json.encode(desc, t) -> string;
    -- pb.json.decode(desc, s) -> table.
    json = pbjson,

    -- Text format printer. pb.text.encode(desc, t, opts) -> string.
    -- opts: {single_line=bool, indent=string}. Encode-only.
    text = pbtext,

    -- Tuple bridge: bind a message descriptor to a space format.
    -- pb.tuple.bind(desc, space, {columns = {...}, omit = {...}}) -> conv.
    -- See runtime/pb/tuple.lua for the binding rules and the plan.
    tuple = tuple,

    -- Wire type constants
    WIRE_VARINT = wire.WIRE_VARINT,
    WIRE_I64    = wire.WIRE_I64,
    WIRE_LEN    = wire.WIRE_LEN,
    WIRE_I32    = wire.WIRE_I32,

    -- Helpers for working with cdata 64-bit ints from outside.
    to_uint64 = wire.to_uint64,
    to_int64  = wire.to_int64,

    -- Strict field-name constants table. Generated code wraps each
    -- message's `M.<Type>_fields = pb.field_names({...})` so callers
    -- pass typo-checked names to the lazy view: `view:get(F.user_id)`
    -- errors at the read site if the field name is wrong, instead of
    -- the silent `nil` that `view:get('user_di')` returns.
    field_names = function(tbl)
        return setmetatable(tbl, {
            __index = function(_, k)
                error(("unknown field name: %q"):format(tostring(k)), 2)
            end,
            __newindex = function(_, k)
                error(("field_names table is read-only: %q"):format(tostring(k)), 2)
            end,
            __metatable = false,
        })
    end,

    -- Helper for building enum descriptors at codegen time.
    enum = function(name, values)
        local by_name, by_value = {}, {}
        for k, v in pairs(values) do
            by_name[k] = v
            by_value[v] = k
        end
        return {name = name, by_name = by_name, by_value = by_value}
    end,

    -- Helper for finalizing a message descriptor: fills in field_by_id from fields[].
    -- Generated code calls this after constructing the fields table so cross-references
    -- (including self-references) can be patched in before sealing.
    finalize_message = function(desc)
        local fbi, fbn = {}, {}
        local CDATA_KEY_TYPES = {
            int64 = true, uint64 = true, sint64 = true,
            fixed64 = true, sfixed64 = true,
        }
        for _, f in ipairs(desc.fields) do
            fbi[f.id] = f
            fbn[f.name] = f
            -- Maps whose key type yields LuaJIT cdata need pointer-vs-value
            -- dedup on decode. Precompute the flag so the hot path is a
            -- single boolean test — see `runtime/pb/codec.lua` map decode
            -- and `compile_readers` for the gate.
            if f.kind == 'map' and f.key and f.key.kind == 'scalar'
                    and CDATA_KEY_TYPES[f.key.proto_type] then
                f.key_dedup = true
            end
        end
        desc.field_by_id = fbi
        desc.field_by_name = fbn
        -- Pre-compute sibling lists for each oneof field so decode can clear
        -- them in O(k) without rescanning.
        --
        -- Also flatten desc.oneofs (a hash-keyed table) into an array
        -- desc.oneofs_list so the hot encode loop can use ipairs and stay
        -- JIT-compilable. `pairs()` over a hash compiles to bytecode ISNEXT
        -- which is NYI in LuaJIT 2.1.
        if desc.oneofs then
            local list = {}
            for oname, members in pairs(desc.oneofs) do
                list[#list + 1] = {name = oname, members = members}
                for _, fname in ipairs(members) do
                    local f = nil
                    for _, fld in ipairs(desc.fields) do
                        if fld.name == fname then f = fld; break end
                    end
                    if f then
                        local sibs = {}
                        for _, other in ipairs(members) do
                            if other ~= fname then sibs[#sibs + 1] = other end
                        end
                        f.oneof_siblings = sibs
                    end
                end
            end
            desc.oneofs_list = list
        end
        -- Attach a per-field monomorphic writer function for the shapes
        -- the codec can specialize (singular scalar/enum/message and
        -- repeated scalar/enum/message). The encode_message hot loop
        -- calls writer(data, out) per field and avoids the runtime
        -- kind/proto_type dispatch chain inside encode_field.
        codec.compile_writers(desc)
        -- Same idea for the decoder side: per-field readers handle
        -- typed value extraction, list bookkeeping, message-merge
        -- rules, and oneof sibling clearing. Maps fall through to
        -- the existing in-loop dispatch.
        codec.compile_readers(desc)
        -- Parallel reader set for pb.decode_unsafe. Built against
        -- scalar_unsafe (string -> bytes handler) and the unsafe
        -- sub-message dispatchers so the entire decode tree skips
        -- utf8_len when the caller opted in. Per-field cost at module
        -- load is O(fields); negligible at descriptor scale.
        codec.compile_readers_unsafe(desc)
        -- Emit a generated per-descriptor `_encode_body(data, out, active)`
        -- with one monomorphic call site per field. Must follow
        -- compile_writers so it can capture each f._writer as a fixed
        -- upvalue. See compile_encode_body in pb.codec for the rationale
        -- (megamorphic dispatch fragmented runtime-mode trace topology).
        codec.compile_encode_body(desc)
        -- NB: C-acceleration plan compilation is deferred to first
        -- encode/decode call (see dispatch wrappers in pb.encode /
        -- pb.decode and the generated `M.<Type>_{encode,decode}`
        -- prologues). Eager compile here would fail on forward
        -- references — codegen forward-declares all descriptors as
        -- `{name=...}` and only fills `.fields` later, so a top-down
        -- `pb.finalize_message(Result_descriptor)` at module load
        -- runs before `Address_descriptor.fields` exists. Lazy
        -- compile sees a fully-populated module table.
        return desc
    end,

    -- Proto2 extension registration. Generated code emits one call per
    -- `extend Foo { ... }` field, attaching the extension's field shape
    -- to the extendee's descriptor. The codec consults `extensions_by_id`
    -- when decoding an unrecognized tag, walks `extensions_list` (array)
    -- when encoding `data._extensions`, and uses
    -- `extensions_by_full_name` for text/JSON encoder lookups.
    --
    -- `extensions_list` is the JIT-stable iteration source — pairs() over
    -- a hash compiles to bytecode ISNEXT which is NYI in LuaJIT 2.1, so
    -- the hot encode loop iterates the array instead. The hash tables
    -- stay around for O(1) name/id lookups.
    register_extension = function(extendee_desc, ext)
        if extendee_desc.extensions_by_id == nil then
            extendee_desc.extensions_by_id = {}
            extendee_desc.extensions_by_full_name = {}
            extendee_desc.extensions_list = {}
        end
        extendee_desc.extensions_by_id[ext.id] = ext
        extendee_desc.extensions_by_full_name[ext.full_name] = ext
        local list = extendee_desc.extensions_list
        list[#list + 1] = ext
    end,
}
