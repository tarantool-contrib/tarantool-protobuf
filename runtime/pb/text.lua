-- Protobuf text-format encoder.
--
-- Output matches the form produced by `protoc --decode=<msg>`:
--   * one field per line, 2-space indent
--   * `name: value` for scalars / enums
--   * `name { ... }` for sub-messages and map entries (no `:`)
--   * repeated fields emit the field once per element
--   * map<K,V> emits as repeated synthetic `key:` / `value:` entries
--   * field names use the original snake_case (mainline convention)
--
-- A single-line variant is available via `opts.single_line = true` — fields
-- are space-separated and message bodies stay on one line. Useful for
-- compact debug logging and inline goldens.
--
-- WKT extension hook: a descriptor with a `desc.text(t, buf, depth)`
-- function takes over body emission (used by pb.wkt to format Timestamp /
-- Duration / Struct / etc. from their idiomatic Lua shapes).
--
-- Decoder lives at the bottom of the file (see "Text-format parser"). It
-- shares the WKT extension hook: a descriptor with `desc.text_decode(text,
-- opts)` takes over body parsing, mirroring the encode-side `desc.text`.
local bit      = require('bit')
local ffi      = require('ffi')
local datetime = require('datetime')
local pbwkt    = require('pb.wkt')
local wire     = require('pb.wire')

local M = {}

local INT64_FAMILY = {int64=true, uint64=true, sint64=true, fixed64=true, sfixed64=true}
local UINT_FAMILY  = {uint32=true, uint64=true, fixed32=true, fixed64=true}
local UINT64       = ffi.typeof('uint64_t')
local INT64        = ffi.typeof('int64_t')
local FLOAT32      = ffi.typeof('float[1]')
local INT64_ZERO   = ffi.cast('int64_t', 0)
local UINT64_ZERO  = ffi.cast('uint64_t', 0)

-- ---------------------------------------------------------------------------
-- Primitives
-- ---------------------------------------------------------------------------

local function int_to_string(v)
    if type(v) == 'cdata' then
        return tostring(v):gsub('U?LL$', '')
    end
    return tostring(v)
end

local function escape_string(s)
    local out = {'"'}
    local n = 1
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0x5c then       n = n + 1; out[n] = '\\\\'
        elseif b == 0x22 then   n = n + 1; out[n] = '\\"'
        elseif b == 0x27 then   n = n + 1; out[n] = "\\'"
        elseif b == 0x0a then   n = n + 1; out[n] = '\\n'
        elseif b == 0x0d then   n = n + 1; out[n] = '\\r'
        elseif b == 0x09 then   n = n + 1; out[n] = '\\t'
        elseif b >= 0x20 and b < 0x7f then
            n = n + 1; out[n] = string.char(b)
        else
            n = n + 1; out[n] = string.format('\\%03o', b)
        end
    end
    n = n + 1; out[n] = '"'
    return table.concat(out)
end

local function format_float(v)
    if v ~= v then return 'nan' end
    if v == math.huge then return 'inf' end
    if v == -math.huge then return '-inf' end
    if v == math.floor(v) and math.abs(v) < 1e16 then
        return string.format('%.1f', v)
    end
    return tostring(v)
end

local function scalar_token(proto_type, v)
    if INT64_FAMILY[proto_type] then return int_to_string(v) end
    if UINT_FAMILY[proto_type] then return int_to_string(v) end
    if proto_type == 'float' or proto_type == 'double' then
        if type(v) ~= 'number' then v = tonumber(v) end
        return format_float(v)
    end
    if proto_type == 'bool' then return v and 'true' or 'false' end
    if proto_type == 'bytes' or proto_type == 'string' then
        return escape_string(v)
    end
    return tostring(v)  -- int32 / sint32 / sfixed32
end

local function enum_token(enum_desc, v)
    if type(v) == 'string' then return v end
    local name = enum_desc.by_value[tonumber(v)]
    if name ~= nil then return name end
    return tostring(v)
end

local function is_proto3_default(f, v)
    -- Skip elision for any presence-tracked field — proto3 explicit
    -- `optional`, oneof branches, and proto2 `optional`/`required` all
    -- carry observable absence-vs-set-to-default distinctions.
    if f.optional or f.oneof or f.required then return false end
    if f.kind == 'scalar' then
        local pt = f.proto_type
        if pt == 'string' or pt == 'bytes' then return v == '' end
        if pt == 'bool' then return v == false end
        if pt == 'float' or pt == 'double' then
            -- -0.0 == 0.0 in IEEE but proto3 only elides *positive* zero
            -- (the wire bytes for -0 differ and the conformance suite
            -- pins it). `1/v == math.huge` is the sign-bit probe.
            return v == 0 and 1 / v == math.huge
        end
        if type(v) == 'cdata' then
            return v == INT64_ZERO or v == UINT64_ZERO
        end
        return v == 0
    elseif f.kind == 'enum' then
        return v == 0 or v == f.enum.by_value[0]
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Buffer + emit primitives
-- ---------------------------------------------------------------------------

local function new_buf(opts)
    return {
        chunks = {}, n = 0,
        single_line = opts.single_line and true or false,
        indent_unit = opts.indent or '  ',
        print_unknown_fields = opts.print_unknown_fields and true or false,
    }
end

local function push(buf, s)
    buf.n = buf.n + 1
    buf.chunks[buf.n] = s
end

-- newline writes a field separator: newline+indent in pretty mode, single
-- space in single-line mode. At the start of an otherwise-empty buffer it
-- writes nothing so the encode output doesn't lead with whitespace.
local function newline(buf, depth)
    if buf.n == 0 then return end
    if buf.single_line then
        push(buf, ' ')
        return
    end
    push(buf, '\n')
    if depth > 0 then push(buf, string.rep(buf.indent_unit, depth)) end
end

local emit_message  -- forward
local emit_extension_entry  -- forward
local emit_field    -- forward

-- emit_block writes `prefix {`, then calls body_fn(buf, depth+1) to fill
-- the body. If the body emits nothing, output collapses to `prefix {}`.
local function emit_block(buf, prefix, depth, body_fn)
    push(buf, prefix); push(buf, ' {')
    local pre_n = buf.n
    body_fn(buf, depth + 1)
    if buf.n == pre_n then
        push(buf, '}')
        return
    end
    newline(buf, depth)
    push(buf, '}')
end

-- ---------------------------------------------------------------------------
-- Field emission
-- ---------------------------------------------------------------------------

-- Group fields print under the capitalized submessage name rather than
-- the lowercased field name (proto2 legacy convention; mainline protoc's
-- text encoder does the same).
local function group_label(f)
    local n = f.message and f.message.name or f.name
    return n:match('[^%.]+$') or n
end

local function emit_one(buf, f, v, depth)
    local kind = f.kind
    if kind == 'scalar' then
        push(buf, f.name); push(buf, ': ')
        push(buf, scalar_token(f.proto_type, v))
    elseif kind == 'enum' then
        push(buf, f.name); push(buf, ': ')
        push(buf, enum_token(f.enum, v))
    elseif kind == 'message' then
        emit_block(buf, f.name, depth, function(b, d)
            emit_message(b, f.message, v, d)
        end)
    elseif kind == 'group' then
        emit_block(buf, group_label(f), depth, function(b, d)
            emit_message(b, f.message, v, d)
        end)
    else
        error('text.encode: unknown field kind ' .. tostring(kind), 0)
    end
end

local function emit_map_entry(buf, f, k, v, depth)
    local kf, vf = f.key, f.value
    emit_block(buf, f.name, depth, function(b, d)
        newline(b, d)
        emit_one(b, {name='key',   kind=kf.kind, proto_type=kf.proto_type,
                     enum=kf.enum, message=kf.message}, k, d)
        newline(b, d)
        emit_one(b, {name='value', kind=vf.kind, proto_type=vf.proto_type,
                     enum=vf.enum, message=vf.message}, v, d)
    end)
end

emit_field = function(buf, f, v, depth)
    if f.kind == 'map' then
        for k, mv in pairs(v) do
            newline(buf, depth)
            emit_map_entry(buf, f, k, mv, depth)
        end
    elseif f.repeated then
        for i = 1, #v do
            newline(buf, depth)
            emit_one(buf, f, v[i], depth)
        end
    else
        if is_proto3_default(f, v) then return end
        newline(buf, depth)
        emit_one(buf, f, v, depth)
    end
end

local WKT_TEXT  -- forward (filled below)

-- ---------------------------------------------------------------------------
-- Unknown-field rendering (drives `_Print` conformance tests).
--
-- Walks the captured _unknown_fields byte stream (tag+value chunks the
-- decoder stashed for round-trip) and emits each entry in TextFormat
-- numeric-field form so the conformance harness's TextFormat::Parser can
-- round-trip the output back under AllowFieldNumber:
--   VARINT  -> "<id>: <uint64>"
--   I64     -> "<id>: 0x<16-hex>"
--   LEN     -> "<id> { <walk> }" if the payload parses as a sub-message,
--              else "<id>: <byte-string>"
--   I32     -> "<id>: 0x<8-hex>"
--   SGROUP  -> "<id> { <walk> }" (recurses until matching EGROUP)
local walk_unknown  -- forward; recurses through SGROUP + LEN(message)

walk_unknown = function(buf, raw, pos, lim, depth, end_field_id)
    while pos <= lim do
        local id, wt, npos = wire.decode_tag(raw, pos)
        pos = npos
        if wt == wire.WIRE_VARINT then
            local v
            v, pos = wire.decode_varint(raw, pos)
            newline(buf, depth)
            push(buf, tostring(id)); push(buf, ': '); push(buf, int_to_string(v))
        elseif wt == wire.WIRE_I64 then
            if pos + 7 > lim then error("truncated I64 in unknown", 0) end
            local lo = raw:byte(pos)     +
                       raw:byte(pos + 1) * 0x100 +
                       raw:byte(pos + 2) * 0x10000 +
                       raw:byte(pos + 3) * 0x1000000
            local hi = raw:byte(pos + 4) +
                       raw:byte(pos + 5) * 0x100 +
                       raw:byte(pos + 6) * 0x10000 +
                       raw:byte(pos + 7) * 0x1000000
            newline(buf, depth)
            push(buf, tostring(id)); push(buf, ': ')
            push(buf, string.format('0x%08x%08x', hi, lo))
            pos = pos + 8
        elseif wt == wire.WIRE_LEN then
            local payload
            payload, pos = wire.decode_len(raw, pos)
            -- Speculative: render as `<id> { ... }`. Roll back to byte
            -- form if the payload doesn't parse as a clean sub-message.
            local n_before = buf.n
            local ok = pcall(function()
                emit_block(buf, tostring(id), depth, function(b, d)
                    walk_unknown(b, payload, 1, #payload, d, nil)
                end)
            end)
            if not ok then
                buf.n = n_before
                newline(buf, depth)
                push(buf, tostring(id)); push(buf, ': ')
                push(buf, escape_string(payload))
            end
        elseif wt == wire.WIRE_I32 then
            if pos + 3 > lim then error("truncated I32 in unknown", 0) end
            local v = raw:byte(pos)     +
                      raw:byte(pos + 1) * 0x100 +
                      raw:byte(pos + 2) * 0x10000 +
                      raw:byte(pos + 3) * 0x1000000
            newline(buf, depth)
            push(buf, tostring(id)); push(buf, ': ')
            push(buf, string.format('0x%08x', v))
            pos = pos + 4
        elseif wt == wire.WIRE_SGROUP then
            -- Recurse into the body; the closure mutates `pos` so the
            -- outer loop continues past the matching EGROUP.
            emit_block(buf, tostring(id), depth, function(b, d)
                pos = walk_unknown(b, raw, pos, lim, d, id)
            end)
        elseif wt == wire.WIRE_EGROUP then
            if end_field_id == nil then
                error("unexpected EGROUP in unknown stream", 0)
            end
            if id ~= end_field_id then
                error(("EGROUP id %d does not match SGROUP id %d"):
                    format(id, end_field_id), 0)
            end
            return pos
        else
            error("unknown wire type " .. tostring(wt), 0)
        end
    end
    if end_field_id ~= nil then
        error("missing EGROUP for field " .. tostring(end_field_id), 0)
    end
    return pos
end

-- emit_extension_entry prints one proto2 extension as `[full.name]: value`
-- (or `[full.name] { … }` for messages/groups). Wraps the existing
-- emit_one logic, swapping the field-name label for the bracket form.
emit_extension_entry = function(buf, ext, full_name, v, depth)
    newline(buf, depth)
    local kind = ext.kind
    if kind == 'scalar' then
        push(buf, '['); push(buf, full_name); push(buf, ']: ')
        push(buf, scalar_token(ext.proto_type, v))
    elseif kind == 'enum' then
        push(buf, '['); push(buf, full_name); push(buf, ']: ')
        push(buf, enum_token(ext.enum, v))
    elseif kind == 'message' or kind == 'group' then
        emit_block(buf, '[' .. full_name .. ']', depth, function(b, d)
            emit_message(b, ext.message, v, d)
        end)
    else
        error('text.encode: unknown extension kind ' .. tostring(kind), 0)
    end
end

emit_message = function(buf, desc, t, depth)
    -- Use type() rather than == nil so box.NULL (a nil-equal cdata used as
    -- the Value WKT's null_value sentinel) survives the guard.
    if type(t) == 'nil' then return end
    local wkt_fn = WKT_TEXT[desc.name]
    if wkt_fn ~= nil then
        wkt_fn(buf, t, depth)
        return
    end
    if desc.text ~= nil then
        desc.text(t, buf, depth)
        return
    end
    for _, f in ipairs(desc.fields) do
        local v = t[f.name]
        -- `box.NULL == nil` via cdata __eq metamethod, so a `v ~= nil`
        -- guard would silently drop a NULL Value WKT. Compare on type.
        if type(v) ~= 'nil' then
            emit_field(buf, f, v, depth)
        end
    end
    -- Proto2 extensions: emit each set entry as `[full.name]: value` in
    -- registration order via the array view (`extensions_list`). Same
    -- ISNEXT-NYI reasoning as the wire encoder — walk the array, not the
    -- hash. Repeated extensions emit one entry per element to keep the
    -- round-trip lossless.
    local exts = t._extensions
    local elist = exts ~= nil and desc.extensions_list or nil
    if elist ~= nil then
        for i = 1, #elist do
            local ext = elist[i]
            local v = exts[ext.full_name]
            if v ~= nil then
                if ext.repeated then
                    for j = 1, #v do
                        emit_extension_entry(buf, ext, ext.full_name, v[j], depth)
                    end
                else
                    emit_extension_entry(buf, ext, ext.full_name, v, depth)
                end
            end
        end
    end
    -- Captured unknown bytes go last, mirroring the codec's re-encode
    -- order. Gated by `opts.print_unknown_fields` to match the protoc
    -- TextFormat::Printer default (off).
    if buf.print_unknown_fields then
        local raw = t._unknown_fields
        if type(raw) == 'string' and #raw > 0 then
            walk_unknown(buf, raw, 1, #raw, depth, nil)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Well-known type text emitters
-- ---------------------------------------------------------------------------
--
-- Each takes (buf, value, depth) and emits the message body — i.e. what
-- would go between `{` and `}` if this WKT appeared as a field value. For
-- the top-level form (`pb.text.encode(M.Timestamp_descriptor, dt)`) this
-- is the entire output.
--
-- The WKT entries below mirror our Lua representations (datetime cdata for
-- Timestamp, unwrapped scalars for wrappers, hash table for Struct, etc.)
-- so the user can hand a real Lua value to the printer without first
-- converting it back to the proto message shape.

local function emit_seconds_nanos(buf, t, depth)
    local seconds, nanos
    if type(t) == 'table' then
        seconds = t.seconds or 0
        nanos   = t.nanos or 0
    elseif type(t) == 'cdata' and datetime.is_datetime(t) then
        seconds = tonumber(t.epoch)
        nanos   = t.nsec
    elseif type(t) == 'number' then
        seconds = math.floor(t)
        nanos   = math.floor((t - seconds) * 1e9 + 0.5)
    else
        error('Timestamp/Duration text: unsupported value type ' .. type(t), 0)
    end
    if seconds ~= 0 and seconds ~= ffi.cast('int64_t', 0) then
        newline(buf, depth)
        push(buf, 'seconds: '); push(buf, int_to_string(seconds))
    end
    if nanos ~= 0 then
        newline(buf, depth)
        push(buf, 'nanos: '); push(buf, tostring(nanos))
    end
end

local WRAPPER_PROTO = {
    DoubleValue = 'double', FloatValue = 'float',
    Int64Value  = 'int64',  UInt64Value = 'uint64',
    Int32Value  = 'int32',  UInt32Value = 'uint32',
    BoolValue   = 'bool',
    StringValue = 'string', BytesValue  = 'bytes',
}

local function make_wrapper_text(proto_type)
    return function(buf, v, depth)
        -- Wrappers print their unwrapped value as `value: <token>` so the
        -- output mirrors mainline protoc's wrapper rendering.
        newline(buf, depth)
        push(buf, 'value: ')
        push(buf, scalar_token(proto_type, v))
    end
end

local function emit_value_oneof(buf, v, depth)
    local field_name, token
    if v == nil or v == pbwkt.NULL then
        field_name, token = 'null_value', 'NULL_VALUE'
    elseif type(v) == 'boolean' then
        field_name, token = 'bool_value', v and 'true' or 'false'
    elseif type(v) == 'number' then
        field_name, token = 'number_value', format_float(v)
    elseif type(v) == 'cdata' then
        field_name, token = 'number_value', format_float(tonumber(v))
    elseif type(v) == 'string' then
        field_name, token = 'string_value', escape_string(v)
    elseif type(v) == 'table' then
        local mt = getmetatable(v)
        local is_list = (mt and mt.__pb_kind == 'list') or (mt == nil and v[1] ~= nil)
        if is_list then
            emit_block(buf, 'list_value', depth, function(b, d)
                M.emit_list_value(b, v, d)
            end)
        else
            emit_block(buf, 'struct_value', depth, function(b, d)
                M.emit_struct(b, v, d)
            end)
        end
        return
    else
        error('Value text: unsupported Lua type ' .. type(v), 0)
    end
    newline(buf, depth)
    push(buf, field_name); push(buf, ': '); push(buf, token)
end

local function emit_struct(buf, t, depth)
    for k, v in pairs(t) do
        newline(buf, depth)
        emit_block(buf, 'fields', depth, function(b, d)
            newline(b, d)
            push(b, 'key: '); push(b, escape_string(tostring(k)))
            -- The map value is a Value WKT. Wrap it in `value { ... }`.
            newline(b, d)
            emit_block(b, 'value', d, function(b2, d2)
                emit_value_oneof(b2, v, d2)
            end)
        end)
    end
end

local function emit_list_value(buf, t, depth)
    for i = 1, #t do
        newline(buf, depth)
        emit_block(buf, 'values', depth, function(b, d)
            emit_value_oneof(b, t[i], d)
        end)
    end
end

local function emit_fieldmask(buf, t, depth)
    if type(t) ~= 'table' then return end
    for i = 1, #t do
        newline(buf, depth)
        push(buf, 'paths: '); push(buf, escape_string(t[i]))
    end
end

local function emit_any(buf, t, depth)
    if type(t) ~= 'table' then return end
    local type_url = t.type_url
    local value    = t.value
    if type_url ~= nil and type_url ~= '' then
        newline(buf, depth)
        push(buf, 'type_url: '); push(buf, escape_string(type_url))
    end
    if value ~= nil and value ~= '' then
        newline(buf, depth)
        push(buf, 'value: '); push(buf, escape_string(value))
    end
end

WKT_TEXT = {
    ['google.protobuf.Empty']     = function() end,
    ['google.protobuf.Timestamp'] = emit_seconds_nanos,
    ['google.protobuf.Duration']  = emit_seconds_nanos,
    ['google.protobuf.Struct']    = emit_struct,
    ['google.protobuf.ListValue'] = emit_list_value,
    ['google.protobuf.Value']     = emit_value_oneof,
    ['google.protobuf.FieldMask'] = emit_fieldmask,
    ['google.protobuf.Any']       = emit_any,
}
for short, pt in pairs(WRAPPER_PROTO) do
    WKT_TEXT['google.protobuf.' .. short] = make_wrapper_text(pt)
end

-- Exposed so the Value override can recurse through Struct / ListValue
-- without re-resolving the WKT table.
M.emit_struct     = emit_struct
M.emit_list_value = emit_list_value

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.encode(desc, t, opts)
    local buf = new_buf(opts or {})
    emit_message(buf, desc, t, 0)
    if not buf.single_line and buf.n > 0 then push(buf, '\n') end
    return table.concat(buf.chunks, '', 1, buf.n)
end

-- Exposed for pb.wkt's text overrides.
M.scalar_token  = scalar_token
M.enum_token    = enum_token
M.escape_string = escape_string
M.int_to_string = int_to_string
M.format_float  = format_float
M.push          = push
M.newline       = newline
M.emit_block    = emit_block
M.emit_message  = emit_message
M.emit_one      = emit_one

-- ===========================================================================
-- Text-format parser (decode side).
--
-- Recursive descent over a single string. Mirrors the encoder's grammar
-- buckets (numbers in all radixes, float specials, string/bytes literals
-- with escapes + adjacent concat, aggregate `{}` / `<>` bodies, repeated
-- short-form lists, map entries, Any inline `[type.url] { ... }`, and
-- enum-by-name-or-number). Silently drops `reserved` field names and
-- numeric field IDs that don't resolve in the schema, mirroring mainline
-- protoc's `AllowFieldNumber` behavior under the conformance harness.
--
-- The output is the same Lua-table shape `pb.decode` produces, so
-- downstream encode / JSON / text passes work without conversion.
-- ===========================================================================

local DEFAULT_DEPTH_LIMIT = 100

-- ---- lexer / cursor -------------------------------------------------------

local function err(S, msg)
    -- 0 disables the file:line prefix from error() so the message lands
    -- intact in the conformance harness's parse_error response body.
    error(('text.decode: %s at offset %d'):format(msg, S.pos), 0)
end

local function skip_ws(S)
    local src, pos, len = S.src, S.pos, S.len
    while pos <= len do
        local c = src:byte(pos)
        if c == 0x20 or c == 0x09 or c == 0x0a or c == 0x0d then
            pos = pos + 1
        elseif c == 0x23 then  -- '#' line comment
            local nl = src:find('\n', pos + 1, true)
            pos = nl and (nl + 1) or (len + 1)
        else
            break
        end
    end
    S.pos = pos
end

-- Token kinds populated by advance():
--   'eof'    value=nil
--   'punct'  value=single-char string from { : { } < > [ ] , ; - + / }
--   'ident'  value=identifier (with dots allowed, for fully-qualified names)
--   'number' value=raw lexeme (digits, possibly 0x/0..7 prefixes, decimal,
--                              exponent, trailing f/F). NO sign — `-` and
--                              `+` come through as separate punct tokens.
--   'string' value=already-decoded string body (escapes applied, adjacent
--                  literals concatenated)
local advance  -- forward

local function is_ident_start(c)
    return (c >= 0x41 and c <= 0x5a) or (c >= 0x61 and c <= 0x7a) or c == 0x5f
end
local function is_ident_cont(c)
    return is_ident_start(c) or (c >= 0x30 and c <= 0x39) or c == 0x2e
end
local function is_digit(c) return c ~= nil and c >= 0x30 and c <= 0x39 end

local function read_string_literal(S)
    -- Consumes one "..." or '...' literal, applying C-style escapes.
    -- Adjacent string literal concatenation is handled by the caller via
    -- a loop in advance().
    local src, len = S.src, S.len
    local quote = src:byte(S.pos)
    local p = S.pos + 1
    local out, n = {}, 0
    while p <= len do
        local c = src:byte(p)
        if c == quote then
            S.pos = p + 1
            return table.concat(out, '', 1, n)
        end
        if c == 0x0a or c == 0x0d then
            S.pos = p; err(S, 'unescaped newline in string literal')
        end
        if c ~= 0x5c then  -- '\\'
            n = n + 1; out[n] = string.char(c)
            p = p + 1
        else
            -- escape: consume backslash, then look at next byte
            p = p + 1
            if p > len then S.pos = p; err(S, 'unterminated escape') end
            local e = src:byte(p)
            if     e == 0x61 then n = n + 1; out[n] = '\a'; p = p + 1
            elseif e == 0x62 then n = n + 1; out[n] = '\b'; p = p + 1
            elseif e == 0x66 then n = n + 1; out[n] = '\f'; p = p + 1
            elseif e == 0x6e then n = n + 1; out[n] = '\n'; p = p + 1
            elseif e == 0x72 then n = n + 1; out[n] = '\r'; p = p + 1
            elseif e == 0x74 then n = n + 1; out[n] = '\t'; p = p + 1
            elseif e == 0x76 then n = n + 1; out[n] = '\v'; p = p + 1
            elseif e == 0x3f then n = n + 1; out[n] = '?';  p = p + 1
            elseif e == 0x27 or e == 0x22 or e == 0x5c then
                n = n + 1; out[n] = string.char(e); p = p + 1
            elseif e == 0x78 or e == 0x58 then        -- \xHH (1..2 hex)
                p = p + 1
                local h1 = src:byte(p)
                if h1 == nil or not (
                    (h1 >= 0x30 and h1 <= 0x39) or
                    (h1 >= 0x41 and h1 <= 0x46) or
                    (h1 >= 0x61 and h1 <= 0x66)) then
                    S.pos = p; err(S, "bad \\x escape")
                end
                local val = (h1 <= 0x39 and (h1 - 0x30)
                          or (h1 >= 0x61 and (h1 - 0x57) or (h1 - 0x37)))
                p = p + 1
                local h2 = src:byte(p)
                if h2 ~= nil and (
                        (h2 >= 0x30 and h2 <= 0x39) or
                        (h2 >= 0x41 and h2 <= 0x46) or
                        (h2 >= 0x61 and h2 <= 0x66)) then
                    val = val * 16 + (h2 <= 0x39 and (h2 - 0x30)
                                   or (h2 >= 0x61 and (h2 - 0x57) or (h2 - 0x37)))
                    p = p + 1
                end
                n = n + 1; out[n] = string.char(val)
            elseif e >= 0x30 and e <= 0x37 then       -- \NNN octal (1..3)
                local val = e - 0x30
                p = p + 1
                local d2 = src:byte(p)
                if d2 ~= nil and d2 >= 0x30 and d2 <= 0x37 then
                    val = val * 8 + (d2 - 0x30); p = p + 1
                    local d3 = src:byte(p)
                    if d3 ~= nil and d3 >= 0x30 and d3 <= 0x37
                            and val * 8 + (d3 - 0x30) < 0x100 then
                        val = val * 8 + (d3 - 0x30); p = p + 1
                    end
                end
                n = n + 1; out[n] = string.char(val)
            elseif e == 0x75 or e == 0x55 then        -- \uHHHH or \UHHHHHHHH
                local digits = (e == 0x75) and 4 or 8
                p = p + 1
                if p + digits - 1 > len then
                    S.pos = p; err(S, "bad \\u/\\U escape")
                end
                local cp = 0
                for i = 0, digits - 1 do
                    local h = src:byte(p + i)
                    local d
                    if     h >= 0x30 and h <= 0x39 then d = h - 0x30
                    elseif h >= 0x41 and h <= 0x46 then d = h - 0x37
                    elseif h >= 0x61 and h <= 0x66 then d = h - 0x57
                    else S.pos = p; err(S, "bad \\u/\\U hex digit")
                    end
                    cp = cp * 16 + d
                end
                p = p + digits
                -- Surrogate code points are invalid in textproto \u/\U
                -- escapes regardless of target field type (string vs
                -- bytes). Mainline's TextFormat parser rejects them as
                -- "Invalid escape sequence: <pair>".
                if cp >= 0xd800 and cp <= 0xdfff then
                    S.pos = p; err(S, 'surrogate code point in unicode escape')
                end
                -- Encode as UTF-8.
                if cp < 0x80 then
                    n = n + 1; out[n] = string.char(cp)
                elseif cp < 0x800 then
                    n = n + 1; out[n] = string.char(
                        0xc0 + bit.rshift(cp, 6),
                        0x80 + bit.band(cp, 0x3f))
                elseif cp < 0x10000 then
                    n = n + 1; out[n] = string.char(
                        0xe0 + bit.rshift(cp, 12),
                        0x80 + bit.band(bit.rshift(cp, 6), 0x3f),
                        0x80 + bit.band(cp, 0x3f))
                elseif cp <= 0x10ffff then
                    n = n + 1; out[n] = string.char(
                        0xf0 + bit.rshift(cp, 18),
                        0x80 + bit.band(bit.rshift(cp, 12), 0x3f),
                        0x80 + bit.band(bit.rshift(cp, 6), 0x3f),
                        0x80 + bit.band(cp, 0x3f))
                else
                    S.pos = p; err(S, "code point out of range")
                end
            else
                S.pos = p; err(S, 'unknown escape \\' .. string.char(e))
            end
        end
    end
    S.pos = p
    err(S, 'unterminated string literal')
end

advance = function(S)
    skip_ws(S)
    local src, pos, len = S.src, S.pos, S.len
    if pos > len then
        S.tok_kind, S.tok_value = 'eof', nil
        return
    end
    local c = src:byte(pos)
    -- single-char punct
    if c == 0x3a or c == 0x7b or c == 0x7d or c == 0x3c or c == 0x3e
            or c == 0x5b or c == 0x5d or c == 0x2c or c == 0x3b
            or c == 0x2d or c == 0x2b or c == 0x2f then
        S.tok_kind, S.tok_value = 'punct', string.char(c)
        S.pos = pos + 1
        return
    end
    -- string literal (handles adjacent concat)
    if c == 0x22 or c == 0x27 then
        local s = read_string_literal(S)
        -- Concatenate adjacent string literals: `"a" "b"` -> "ab".
        while true do
            skip_ws(S)
            if S.pos > S.len then break end
            local b = S.src:byte(S.pos)
            if b ~= 0x22 and b ~= 0x27 then break end
            s = s .. read_string_literal(S)
        end
        S.tok_kind, S.tok_value = 'string', s
        return
    end
    -- number (no sign — sign is a separate punct token)
    if is_digit(c) or c == 0x2e then
        local start = pos
        -- Hex: 0x...
        if c == 0x30 and pos + 1 <= len then
            local n2 = src:byte(pos + 1)
            if n2 == 0x78 or n2 == 0x58 then
                pos = pos + 2
                while pos <= len do
                    local b = src:byte(pos)
                    if (b >= 0x30 and b <= 0x39) or
                       (b >= 0x41 and b <= 0x46) or
                       (b >= 0x61 and b <= 0x66) then
                        pos = pos + 1
                    else break end
                end
                S.tok_kind, S.tok_value = 'number', src:sub(start, pos - 1)
                S.pos = pos
                return
            end
        end
        -- Decimal / float / octal: digits[.digits][eE±digits][fF]
        while pos <= len and is_digit(src:byte(pos)) do pos = pos + 1 end
        if pos <= len and src:byte(pos) == 0x2e then         -- '.'
            pos = pos + 1
            while pos <= len and is_digit(src:byte(pos)) do pos = pos + 1 end
        end
        if pos <= len then
            local b = src:byte(pos)
            if b == 0x65 or b == 0x45 then                   -- 'e'/'E'
                pos = pos + 1
                if pos <= len then
                    local s = src:byte(pos)
                    if s == 0x2b or s == 0x2d then pos = pos + 1 end
                end
                while pos <= len and is_digit(src:byte(pos)) do pos = pos + 1 end
            end
        end
        if pos <= len then
            local b = src:byte(pos)
            if b == 0x66 or b == 0x46 then pos = pos + 1 end   -- 'f'/'F'
        end
        S.tok_kind, S.tok_value = 'number', src:sub(start, pos - 1)
        S.pos = pos
        return
    end
    if is_ident_start(c) then
        local p = pos + 1
        while p <= len and is_ident_cont(src:byte(p)) do p = p + 1 end
        S.tok_kind, S.tok_value = 'ident', src:sub(pos, p - 1)
        S.pos = p
        return
    end
    err(S, ('unexpected character %q'):format(string.char(c)))
end

local function expect_punct(S, ch)
    if S.tok_kind ~= 'punct' or S.tok_value ~= ch then
        err(S, ('expected %q, got %s %q'):format(
            ch, S.tok_kind, tostring(S.tok_value)))
    end
    advance(S)
end

local function accept_punct(S, ch)
    if S.tok_kind == 'punct' and S.tok_value == ch then
        advance(S); return true
    end
    return false
end

-- ---- numeric literal parsing ----------------------------------------------

-- digits_to_u64 returns (u64, overflowed?). Overflow is detected via the
-- LuaJIT uint64 wrap rule: `u*b + d` wraps modulo 2^64, so a multiplication
-- that decreases the value or whose round-trip through division loses
-- precision is conclusive. Cheap enough for 20-ish digits per integer.
local function digits_to_u64(s, base)
    local u = UINT64_ZERO
    local b = UINT64(base)
    for i = 1, #s do
        local c = s:byte(i)
        local d
        if c >= 0x30 and c <= 0x39 then d = c - 0x30
        elseif c >= 0x41 and c <= 0x46 then d = c - 0x37
        elseif c >= 0x61 and c <= 0x66 then d = c - 0x57
        else return nil
        end
        if d >= base then return nil end
        local nu = u * b
        if u ~= UINT64_ZERO and nu / b ~= u then return nil, true end
        local r = nu + UINT64(d)
        if r < nu then return nil, true end
        u = r
    end
    return u, false
end

-- Parse a numeric lexeme into a uint64 cdata representing the magnitude.
-- Returns (u64, status) where status is nil on success, 'invalid' when the
-- lexeme isn't an integer-shape (caller routes to float path), or
-- 'overflow' when the magnitude exceeds 2^64-1.
local function parse_int_lexeme(lex)
    -- Hex
    if lex:sub(1, 2) == '0x' or lex:sub(1, 2) == '0X' then
        local digits = lex:sub(3)
        if #digits == 0 then return nil, 'invalid' end
        local u, ov = digits_to_u64(digits, 16)
        if ov then return nil, 'overflow' end
        return u
    end
    -- Floaty?
    if lex:find('[.eEfF]') then return nil, 'invalid' end
    -- Octal: leading 0 with more digits, and all digits in 0..7.
    if #lex >= 2 and lex:byte(1) == 0x30 then
        local digits = lex:sub(2)
        if digits:find('[^0-7]') then return nil, 'invalid' end
        local u, ov = digits_to_u64(digits, 8)
        if ov then return nil, 'overflow' end
        return u
    end
    -- Decimal
    if lex:find('[^0-9]') then return nil, 'invalid' end
    local u, ov = digits_to_u64(lex, 10)
    if ov then return nil, 'overflow' end
    return u
end

-- inf / infinity / nan, any case.
local function classify_inf_nan(ident)
    local low = ident:lower()
    if low == 'inf' or low == 'infinity' then return 'inf' end
    if low == 'nan' then return 'nan' end
    return nil
end

local function parse_float_lexeme(lex)
    -- Strip trailing f/F (C-style) — tonumber doesn't accept it.
    if lex:byte(-1) == 0x66 or lex:byte(-1) == 0x46 then
        lex = lex:sub(1, -2)
    end
    -- Hex and octal int literals are NOT valid in float fields. Reject
    -- (mainline's FloatField{No,NoNegative}{Hex,Octal} tests pin this).
    if lex:sub(1, 2) == '0x' or lex:sub(1, 2) == '0X' then return nil, 'hex' end
    if #lex >= 2 and lex:byte(1) == 0x30
            and not lex:find('[.eE]') then
        return nil, 'octal'
    end
    local v = tonumber(lex)
    if v ~= nil then return v end
    -- tonumber returns nil for exponents so huge they fall outside its
    -- exponent parser's range (typically ~1e308 for doubles). Saturate
    -- to ±inf if the exponent is positive, 0 if negative — matches
    -- mainline's Float/DoubleField{Overflow,LargeNegativeExp} cases.
    local _, expsign = lex:find('[eE]([+-]?)')
    -- Lua's :find returns positions; use :match to capture.
    local sign_chr = lex:match('[eE]([+-]?)')
    if sign_chr == nil then return nil, 'invalid' end
    if sign_chr == '-' then return 0.0 end
    return math.huge
end

-- ---- value parsers --------------------------------------------------------

local SCALAR_NUMERIC = {
    int32=true, int64=true, uint32=true, uint64=true,
    sint32=true, sint64=true, fixed32=true, fixed64=true,
    sfixed32=true, sfixed64=true,
    float=true, double=true,
}

local INT_TYPES = {
    int32=true, int64=true, uint32=true, uint64=true,
    sint32=true, sint64=true, fixed32=true, fixed64=true,
    sfixed32=true, sfixed64=true,
}

-- Magnitude limits (positive sign) for 32-bit ints. Range-check is done on
-- the parsed uint64 magnitude before applying the sign so negative values
-- can use a different limit (e.g. int32 magnitude is 0x80000000 negative
-- but only 0x7fffffff positive).
local INT32_MAX_U    = UINT64(0x7fffffff)
local INT32_MIN_MAG  = UINT64(0x80000000)
local UINT32_MAX_U   = UINT64(0xffffffff)
local INT64_MAX_U    = 0x7fffffffffffffffULL
local INT64_MIN_MAG  = 0x8000000000000000ULL

-- Consume an optional sign punct. Returns true if value should be negated.
local function consume_sign(S)
    if S.tok_kind == 'punct' then
        if S.tok_value == '-' then advance(S); return true end
        if S.tok_value == '+' then advance(S); return false end
    end
    return false
end

local function parse_int_value(S, proto_type)
    local neg = consume_sign(S)
    if S.tok_kind ~= 'number' then
        err(S, ('expected integer for %s, got %s %q'):format(
            proto_type, S.tok_kind, tostring(S.tok_value)))
    end
    local lex = S.tok_value
    advance(S)
    local u, status = parse_int_lexeme(lex)
    if u == nil then
        if status == 'overflow' then
            err(S, ('integer literal %q exceeds 64-bit range'):format(lex))
        end
        err(S, ('invalid integer literal %q for %s'):format(lex, proto_type))
    end
    if proto_type == 'int64' or proto_type == 'sint64' or proto_type == 'sfixed64' then
        if neg then
            if u > INT64_MIN_MAG then
                err(S, ('integer %s out of range for %s'):format('-' .. lex, proto_type))
            end
            -- u == INT64_MIN_MAG: -u wraps back to INT64_MIN, which is the
            -- exact value we want (the only valid representation).
            return -INT64(u)
        end
        if u > INT64_MAX_U then
            err(S, ('integer %s out of range for %s'):format(lex, proto_type))
        end
        return INT64(u)
    end
    if proto_type == 'uint64' or proto_type == 'fixed64' then
        if neg and u ~= UINT64_ZERO then
            err(S, ('negative value %s for %s'):format('-' .. lex, proto_type))
        end
        return u  -- range already verified by parse_int_lexeme (≤ 2^64-1)
    end
    -- 32-bit Lua-number return.
    if proto_type == 'int32' or proto_type == 'sint32' or proto_type == 'sfixed32' then
        if neg then
            if u > INT32_MIN_MAG then
                err(S, ('integer %s out of range for %s'):format('-' .. lex, proto_type))
            end
            if u == INT32_MIN_MAG then return -0x80000000 end
            return -tonumber(u)
        end
        if u > INT32_MAX_U then
            err(S, ('integer %s out of range for %s'):format(lex, proto_type))
        end
        return tonumber(u)
    end
    -- uint32 / fixed32
    if neg and u ~= UINT64_ZERO then
        err(S, ('negative value %s for %s'):format('-' .. lex, proto_type))
    end
    if u > UINT32_MAX_U then
        err(S, ('integer %s out of range for %s'):format(lex, proto_type))
    end
    return tonumber(u)
end

local function parse_float_value(S, proto_type)
    local neg = consume_sign(S)
    local raw
    if S.tok_kind == 'ident' then
        local cls = classify_inf_nan(S.tok_value)
        if cls == 'inf' then
            advance(S)
            return neg and -math.huge or math.huge
        end
        if cls == 'nan' then advance(S); return 0/0 end
        err(S, ('expected number for %s, got ident %q'):format(
            proto_type, S.tok_value))
    end
    if S.tok_kind ~= 'number' then
        err(S, ('expected number for %s, got %s'):format(proto_type, S.tok_kind))
    end
    raw = S.tok_value
    advance(S)
    local v, why = parse_float_lexeme(raw)
    if v == nil then
        if why == 'hex' or why == 'octal' then
            err(S, ('%s integer literal not allowed in float field'):format(why))
        end
        err(S, ('invalid float literal %q'):format(raw))
    end
    if neg then v = -v end
    -- float (32-bit) rounds through IEEE 754 single. Lets `-1e-50` underflow
    -- to `-0.0` and oversize values saturate to ±inf per the spec.
    if proto_type == 'float' then
        local buf = FLOAT32(v)
        v = tonumber(buf[0])
    end
    return v
end

local BOOL_TRUE  = {['true']=true, True=true, ['t']=true, ['1']=true}
local BOOL_FALSE = {['false']=true, False=true, ['f']=true, ['0']=true}

local function parse_bool_value(S)
    if S.tok_kind == 'ident' then
        local v = S.tok_value
        if BOOL_TRUE[v]  then advance(S); return true  end
        if BOOL_FALSE[v] then advance(S); return false end
        err(S, ('expected bool, got ident %q'):format(v))
    elseif S.tok_kind == 'number' then
        local v = S.tok_value
        if v == '1' then advance(S); return true  end
        if v == '0' then advance(S); return false end
        err(S, ('expected bool, got number %q'):format(v))
    end
    err(S, ('expected bool, got %s'):format(S.tok_kind))
end

local function parse_string_value(S, validate_utf8)
    if S.tok_kind ~= 'string' then
        err(S, ('expected string, got %s'):format(S.tok_kind))
    end
    local v = S.tok_value
    advance(S)
    if validate_utf8 and not wire.is_valid_utf8(v) then
        err(S, 'invalid UTF-8 in string field')
    end
    return v
end

local function parse_enum_value(S, enum_desc)
    if S.tok_kind == 'ident' then
        local name = S.tok_value
        local num = enum_desc.by_name[name]
        if num == nil then
            err(S, ('unknown enum name %q for %s'):format(name, enum_desc.name))
        end
        advance(S)
        return num
    end
    -- Numeric enum value: signed int32-shape. Closed enums (proto2) reject
    -- numbers that don't map to a declared value; open enums (proto3) accept
    -- any int32 to preserve forward-compatibility on the wire.
    local n = parse_int_value(S, 'int32')
    if enum_desc.closed and enum_desc.by_value[n] == nil then
        err(S, ('unknown enum number %d for closed enum %s'):
            format(n, enum_desc.name))
    end
    return n
end

local function parse_scalar_value(S, proto_type)
    if proto_type == 'bool'   then return parse_bool_value(S) end
    if proto_type == 'string' then return parse_string_value(S, true) end
    if proto_type == 'bytes'  then return parse_string_value(S, false) end
    if proto_type == 'float' or proto_type == 'double' then
        return parse_float_value(S, proto_type)
    end
    if INT_TYPES[proto_type] then return parse_int_value(S, proto_type) end
    err(S, 'unhandled scalar proto_type: ' .. tostring(proto_type))
end

-- Forward decls so message/list/map parsers can call into one another.
local parse_message_body
local skip_value
local skip_field_entry

-- Skip the value following a `:` (or message body) for an unknown / reserved
-- field. Tolerates every shape the grammar emits: scalar (token), aggregate,
-- and list-shorthand. Used to silently drop unknown numeric IDs and
-- `reserved "..."` field names. Mirrors the value-position grammar so a
-- well-formed input is still parsed cleanly.
skip_value = function(S, depth)
    if S.tok_kind == 'punct' then
        local v = S.tok_value
        if v == '{' or v == '<' then
            local closer = (v == '{') and '}' or '>'
            advance(S)
            while not (S.tok_kind == 'punct' and S.tok_value == closer) do
                if S.tok_kind == 'eof' then
                    err(S, 'unterminated unknown message body')
                end
                skip_field_entry(S, depth + 1, nil, nil)
            end
            advance(S)
            return
        end
        if v == '[' then
            advance(S)
            if not accept_punct(S, ']') then
                while true do
                    skip_value(S, depth)
                    if accept_punct(S, ']') then break end
                    expect_punct(S, ',')
                end
            end
            return
        end
        if v == '-' or v == '+' then
            advance(S)
            -- expect a number/ident next (caught by recursive call)
            skip_value(S, depth); return
        end
    end
    if S.tok_kind == 'number' or S.tok_kind == 'string'
            or S.tok_kind == 'ident' then
        advance(S); return
    end
    err(S, ('unexpected token in skipped value: %s'):format(S.tok_kind))
end

-- ---- message body ---------------------------------------------------------

-- Append a value to a repeated-field list on the result table.
local function repeated_append(result, fname, v)
    local list = result[fname]
    if list == nil then list = {}; result[fname] = list end
    list[#list + 1] = v
end

-- Clear oneof siblings when a oneof field is set (last-set-wins).
local function clear_oneof_siblings(result, f)
    local sibs = f.oneof_siblings
    if sibs == nil then return end
    for i = 1, #sibs do result[sibs[i]] = nil end
end

local parse_value_for_field  -- forward

-- Parse the body of a map entry (key + value sub-fields) into a synthetic
-- result table {key=K, value=V}. Map "fields" in text-format are spelled
-- as nested `key:` / `value:` aggregates.
local function parse_map_entry(S, f, depth)
    local entry = {}
    -- Synthesize per-direction descriptors so the inner field loop can
    -- reuse parse_value_for_field without re-deriving kind/proto_type.
    local key_f = {name='key',   kind=f.key.kind,
                   proto_type=f.key.proto_type, enum=f.key.enum,
                   message=f.key.message}
    local val_f = {name='value', kind=f.value.kind,
                   proto_type=f.value.proto_type, enum=f.value.enum,
                   message=f.value.message}
    while S.tok_kind ~= 'eof' do
        if S.tok_kind == 'punct' and (S.tok_value == '}' or S.tok_value == '>') then
            break
        end
        if S.tok_kind ~= 'ident' then
            err(S, 'expected key/value in map entry')
        end
        local name = S.tok_value
        advance(S)
        accept_punct(S, ':')
        if name == 'key' then
            entry.key = parse_value_for_field(S, key_f, depth + 1)
        elseif name == 'value' then
            entry.value = parse_value_for_field(S, val_f, depth + 1)
        else
            err(S, ('unknown field %q in map entry'):format(name))
        end
        if not accept_punct(S, ',') then accept_punct(S, ';') end
    end
    return entry
end

-- Resolve a message-typed field's value. Used both for singular and inside
-- list-shorthand. Handles WKT desc.text_decode overrides + Any inline form.
local parse_message_field_value  -- forward

-- Parse one value into the field-appropriate Lua shape. Does NOT handle
-- list-shorthand or repeated bookkeeping; the caller decides.
parse_value_for_field = function(S, f, depth)
    if f.kind == 'scalar' then
        return parse_scalar_value(S, f.proto_type)
    end
    if f.kind == 'enum' then
        return parse_enum_value(S, f.enum)
    end
    if f.kind == 'message' or f.kind == 'group' then
        return parse_message_field_value(S, f.message, depth)
    end
    if f.kind == 'map' then
        local opener = S.tok_value
        if S.tok_kind ~= 'punct' or (opener ~= '{' and opener ~= '<') then
            err(S, 'expected { for map entry')
        end
        advance(S)
        local entry = parse_map_entry(S, f, depth)
        expect_punct(S, opener == '{' and '}' or '>')
        return entry
    end
    err(S, 'unhandled field kind: ' .. tostring(f.kind))
end

-- ---- Any inline form ------------------------------------------------------

local function parse_any_url_brackets(S)
    -- assumes current token is `[`
    expect_punct(S, '[')
    -- Concatenate identifier and `/` segments into the full URL.
    local parts, n = {}, 0
    while not (S.tok_kind == 'punct' and S.tok_value == ']') do
        if S.tok_kind == 'ident' then
            n = n + 1; parts[n] = S.tok_value
            advance(S)
        elseif S.tok_kind == 'punct' and S.tok_value == '/' then
            n = n + 1; parts[n] = '/'
            advance(S)
        else
            err(S, 'unexpected token inside [type.url]')
        end
    end
    expect_punct(S, ']')
    return table.concat(parts)
end

-- ---- message body parser --------------------------------------------------

parse_message_body = function(S, desc, result, depth)
    if depth > DEFAULT_DEPTH_LIMIT then
        err(S, 'nesting depth limit exceeded')
    end
    -- `seen` tracks singular scalar/enum field occurrences within this
    -- message body so we can reject `field: A; field: B` per spec. Each
    -- message body gets its own `seen` — nested messages don't inherit.
    local seen = {}
    while S.tok_kind ~= 'eof' do
        if S.tok_kind == 'punct' and (S.tok_value == '}' or S.tok_value == '>') then
            return
        end
        skip_field_entry(S, depth, desc, result, seen)
    end
end

skip_field_entry = function(S, depth, desc, result, seen)
    -- desc/result may be nil when skipping inside an unknown sub-message body.
    if S.tok_kind == 'punct' and S.tok_value == '[' then
        -- Bracket form covers two distinct grammars:
        --   - google.protobuf.Any:  [type.url] { … }
        --   - proto2 extensions:    [pkg.ext_name] : value     (singular)
        --                           [pkg.ext_name] { … }       (message/group)
        local url = parse_any_url_brackets(S)
        local is_any_target = desc ~= nil and desc.name == 'google.protobuf.Any'
        local ext = (not is_any_target) and desc ~= nil
            and desc.extensions_by_full_name and desc.extensions_by_full_name[url]
        accept_punct(S, ':')
        if is_any_target then
            -- Resolve the inner type from the registry and serialize.
            local inner_desc = pbwkt.lookup(url)
            if inner_desc == nil then
                err(S, ('no descriptor for Any type %q'):format(url))
            end
            local opener = S.tok_value
            if S.tok_kind ~= 'punct' or (opener ~= '{' and opener ~= '<') then
                err(S, 'expected { for Any body')
            end
            advance(S)
            local inner = {}
            if inner_desc.text_decode ~= nil then
                -- WKT overrides: re-tokenize would be expensive; instead
                -- parse the body fields into a temp table via the codec
                -- descriptor view if available. Fall back to body parse.
                parse_message_body(S, inner_desc, inner, depth + 1)
            else
                parse_message_body(S, inner_desc, inner, depth + 1)
            end
            expect_punct(S, opener == '{' and '}' or '>')
            local enc = inner_desc.encode and inner_desc.encode(inner)
                      or require('pb.codec').encode(inner_desc, inner)
            result.type_url = url
            result.value    = enc
        elseif ext then
            -- Proto2 extension: parse the value through the extension's
            -- field shape and stash under result._extensions[full_name].
            -- The bracket name is the extension's fully-qualified field
            -- name (lowercase); using the type name (CamelCase) is a
            -- text-format parse error per the spec.
            local v = parse_value_for_field(S, ext, depth)
            local exts = result._extensions
            if exts == nil then exts = {}; result._extensions = exts end
            if ext.repeated then
                local list = exts[ext.full_name]
                if list == nil then list = {}; exts[ext.full_name] = list end
                list[#list + 1] = v
            else
                exts[ext.full_name] = v
            end
        elseif desc ~= nil then
            -- Bracket name resolved neither as Any nor as a known
            -- extension. Per text-format spec this is a parse error
            -- (so e.g. `[pkg.GroupField]` instead of `[pkg.groupfield]`
            -- gets rejected even when the type exists).
            err(S, ('unknown extension or Any URL %q in %s'):
                format(url, desc.name))
        else
            -- desc is nil (skipping inside an unknown body): swallow.
            skip_value(S, depth)
        end
        if not accept_punct(S, ',') then accept_punct(S, ';') end
        return
    end

    -- Field name (ident) or numeric ID (number).
    local field_name, numeric_id
    if S.tok_kind == 'ident' then
        field_name = S.tok_value
        advance(S)
    elseif S.tok_kind == 'number' then
        local u = parse_int_lexeme(S.tok_value)
        if u == nil then err(S, 'expected field name or number') end
        numeric_id = tonumber(u)
        advance(S)
    else
        err(S, ('unexpected token at field-entry start: %s %q'):format(
            S.tok_kind, tostring(S.tok_value)))
    end

    local field = nil
    if desc ~= nil then
        if field_name ~= nil then
            field = desc.field_by_name and desc.field_by_name[field_name]
            if field == nil then
                -- Proto2 group reference: text format uses the group's
                -- submessage simple name (e.g. `Data` or `MultiWordGroupField`)
                -- or its lowercase ASCII fold instead of the field name.
                -- The submessage name lookup is rare enough to do a linear
                -- sweep over fields rather than precomputing an index.
                local lc = field_name:lower()
                for _, gf in ipairs(desc.fields) do
                    if gf.kind == 'group' then
                        local label = gf.message and gf.message.name or ''
                        label = label:match('[^%.]+$') or label
                        if field_name == label or lc == label:lower() then
                            field = gf
                            break
                        end
                    end
                end
            end
        elseif numeric_id ~= nil then
            field = desc.field_by_id and desc.field_by_id[numeric_id]
        end
    end

    -- Unknown / reserved handling.
    if field == nil then
        local is_reserved = desc ~= nil and field_name ~= nil
            and desc.reserved_names ~= nil
            and desc.reserved_names[field_name]
        if field_name ~= nil and not is_reserved and numeric_id == nil
                and not (S.opts and S.opts.allow_unknown_fields)
                and desc ~= nil then
            -- Unknown text field name in a known message: error per spec
            -- (mainline protoc rejects). Numeric IDs are tolerated since
            -- the harness emits round-tripped unknown-field text in that form.
            err(S, ('unknown field %q in %s'):format(field_name, desc.name))
        end
        -- Skip the value (optionally preceded by `:`).
        accept_punct(S, ':')
        skip_value(S, depth)
        if not accept_punct(S, ',') then accept_punct(S, ';') end
        return
    end

    -- Map / message / list / scalar handling.
    local kind = field.kind
    -- `:` is required before scalar/enum, optional before message/map.
    if kind == 'message' or kind == 'map' or kind == 'group' then
        accept_punct(S, ':')
    else
        expect_punct(S, ':')
    end

    -- List shorthand: `field: [a, b, c]`. Each entry is appended to the
    -- repeated list. Disallowed for non-repeated / non-map fields.
    if S.tok_kind == 'punct' and S.tok_value == '[' then
        if not field.repeated and kind ~= 'map' then
            err(S, ('list shorthand not allowed on non-repeated field %q'):
                format(field.name))
        end
        advance(S)
        -- Empty list still materializes the field as `{}` (mainline
        -- protoc treats `field: []` as "set to empty list", not "absent").
        if result[field.name] == nil then result[field.name] = {} end
        if not accept_punct(S, ']') then
            while true do
                local v = parse_value_for_field(S, field, depth)
                repeated_append(result, field.name,
                    kind == 'map' and v or v)
                if accept_punct(S, ']') then break end
                expect_punct(S, ',')
            end
        end
        -- map<K,V> elements parsed via list-shorthand: rebuild the hash.
        if kind == 'map' then
            local list = result[field.name]
            local m = {}
            for i = 1, #list do m[list[i].key] = list[i].value end
            result[field.name] = m
        end
        if not accept_punct(S, ',') then accept_punct(S, ';') end
        return
    end

    if kind == 'map' then
        local entry = parse_value_for_field(S, field, depth)
        local m = result[field.name]
        if m == nil then m = {}; result[field.name] = m end
        m[entry.key] = entry.value
    elseif field.repeated then
        local v = parse_value_for_field(S, field, depth)
        repeated_append(result, field.name, v)
    else
        -- Singular scalar / enum: duplicate occurrence is a parse error
        -- per the text-format spec ("non-repeated field set more than
        -- once"). Singular sub-messages instead MERGE (their fields are
        -- shallow-merged into the existing value).
        if seen ~= nil and (kind == 'scalar' or kind == 'enum')
                and seen[field.name] then
            err(S, ('non-repeated field %q set more than once'):
                format(field.name))
        end
        local v = parse_value_for_field(S, field, depth)
        clear_oneof_siblings(result, field)
        if (kind == 'message' or kind == 'group') and result[field.name] ~= nil then
            -- text-format spec: repeated singular sub-messages merge. We
            -- approximate by shallow-merging fields; sufficient for the
            -- conformance corpus shapes.
            local prev = result[field.name]
            for k, nv in pairs(v) do prev[k] = nv end
        else
            result[field.name] = v
        end
        if seen ~= nil then seen[field.name] = true end
    end
    if not accept_punct(S, ',') then accept_punct(S, ';') end
end

parse_message_field_value = function(S, msg_desc, depth)
    local opener
    if S.tok_kind ~= 'punct' or (S.tok_value ~= '{' and S.tok_value ~= '<') then
        err(S, ('expected { for message field, got %s %q'):format(
            S.tok_kind, tostring(S.tok_value)))
    end
    opener = S.tok_value
    advance(S)
    local closer = (opener == '{') and '}' or '>'
    -- WKT decode override: gives the WKT type total control over body parse.
    if msg_desc.text_decode ~= nil then
        local v = msg_desc.text_decode(S, depth + 1)
        expect_punct(S, closer)
        return v
    end
    local inner = {}
    parse_message_body(S, msg_desc, inner, depth + 1)
    expect_punct(S, closer)
    return inner
end

-- ---- WKT decode overrides -------------------------------------------------
--
-- Most WKTs naturally parse via the generic body walker: Empty, FieldMask,
-- Timestamp/Duration (when given as `seconds: N nanos: M`), wrappers
-- (when given as `value: V`). The cases that need an override are the
-- ones where the text shape differs from the message field shape:
--
--   * Struct / ListValue / Value — these have heavy generated descriptors
--     in pb.wkt that the text printer bypasses. We let the body walker
--     populate the standard message shape (fields: list of {key,value}
--     entries for Struct, etc.), then mainline encoders pick it up.
--
-- The conformance harness's Struct/Value text inputs use the *generated*
-- message shape (e.g. `fields { key: "k" value { string_value: "v" } }`)
-- rather than the inline JSON-ish form, so our generic walker works as-is.
-- We do NOT register WKT-specific text_decode overrides; the WKT
-- descriptors in pb.wkt carry `desc.encode`/`desc.decode` and the existing
-- field-by-name lookup against descriptor.proto handles parsing.

-- ---- public API -----------------------------------------------------------

function M.decode(desc, text, opts)
    if type(text) ~= 'string' then
        error('pb.text.decode: text must be a string', 0)
    end
    opts = opts or {}
    if opts.allow_unknown_fields == nil then
        opts.allow_unknown_fields = false
    end
    local S = {
        src = text, pos = 1, len = #text, opts = opts,
        tok_kind = nil, tok_value = nil,
    }
    advance(S)
    local result = {}
    -- WKT-level override (currently unused — see comment above).
    if desc.text_decode ~= nil then
        result = desc.text_decode(S, 0) or result
    else
        parse_message_body(S, desc, result, 0)
    end
    if S.tok_kind ~= 'eof' then
        err(S, ('trailing data at end of input (%s)'):format(S.tok_kind))
    end
    return result
end

return M
