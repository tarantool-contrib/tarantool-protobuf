-- Lazy, zero-copy decode view over protobuf wire bytes.
--
-- Built once via pb.decode_lazy(desc, bytes). Indexes the wire bytes at
-- construct time (single pass), then materializes individual fields on
-- access. Nested messages, repeated fields, and maps are themselves
-- returned as lazy sub-views; values are decoded on `:get` / `:at`.
--
-- The underlying Lua string is kept GC-anchored on the view table so
-- substring-based passthrough remains valid for the view's lifetime.
--
-- Storage layout: SoA (struct-of-arrays). Per wire-entry we hold four
-- integer offsets in parallel arrays, not one Lua table per entry.
-- For an emails-heavy message at 100 KB that's 4 tables of 2800 ints
-- instead of 2800 tables of 4 keys — ~5× fewer table allocations on
-- decode_lazy, which is the difference between losing sparse-read 0.6×
-- and breaking even.
--
-- WKT and any descriptor carrying `desc.decode` are eagerly decoded and
-- wrapped in an EagerView with the same getter surface, so callers
-- don't have to special-case Timestamp/Duration/Struct/etc.

---@class pb.MessageView
---@field get fun(self: pb.MessageView, name: string): any
---@field has fun(self: pb.MessageView, name: string): boolean
---@field which fun(self: pb.MessageView, oneof_name: string): string?
---@field iter fun(self: pb.MessageView): fun(): string?, any
---@field names fun(self: pb.MessageView): fun(): string?
---@field set fun(self: pb.MessageView, name: string, value: any)
---@field is_dirty fun(self: pb.MessageView): boolean
---@field totable fun(self: pb.MessageView): table
---@field encode fun(self: pb.MessageView): string
---
---@class pb.ArrayView
---@field len fun(self: pb.ArrayView): integer
---@field at fun(self: pb.ArrayView, i: integer): any
---@field iter fun(self: pb.ArrayView): fun(): integer?, any
---@field tolist fun(self: pb.ArrayView): any[]
---
---@class pb.MapView
---@field get fun(self: pb.MapView, k: any): any
---@field has fun(self: pb.MapView, k: any): boolean
---@field keys fun(self: pb.MapView): any[]
---@field iter fun(self: pb.MapView): fun(): any?, any
---@field totable fun(self: pb.MapView): table

local wire  = require('pb.wire')
local codec = require('pb.codec')

local M = {}

-- Forward decls: views can reference each other.
local build_msg_view
local build_array_view
local build_map_view

-- ---------------------------------------------------------------------------
-- Index build (SoA)
--
-- Single pass over `bytes`. Returns:
--   segs = {
--     n          = <entry count>,
--     id         = {<field id>, ...},     -- 1-based, by entry
--     tag_start  = {...},                  -- 1-based byte offset, tag's first byte
--     val_start  = {...},                  --                    , value's first byte
--     next_start = {...},                  --                    , just past this entry
--   }
--   by_id = { [field_id] = {seg_idx, seg_idx, ...} }   -- indices into segs
--
-- We deliberately don't keep wire_type: consumers know it from the
-- descriptor for known fields, and we never re-decode the tag for
-- unknown fields after the index pass (we only splice their bytes).
-- ---------------------------------------------------------------------------
local function index_bytes(desc, bytes)
    local pos, lim = 1, #bytes
    local s_id, s_tag, s_val, s_next = {}, {}, {}, {}
    local by_id = {}
    local fbi = desc.field_by_id
    local n = 0

    while pos <= lim do
        local tag_start = pos
        local id, wt, npos = wire.decode_tag(bytes, pos)
        local val_start = npos
        local next_start = wire.skip_field(bytes, npos, wt, id)
        n = n + 1
        s_id[n]   = id
        s_tag[n]  = tag_start
        s_val[n]  = val_start
        s_next[n] = next_start
        if fbi[id] ~= nil then
            local list = by_id[id]
            if list == nil then
                by_id[id] = {n}
            else
                list[#list + 1] = n
            end
        end
        pos = next_start
    end
    return {
        n          = n,
        id         = s_id,
        tag_start  = s_tag,
        val_start  = s_val,
        next_start = s_next,
    }, by_id
end

-- ---------------------------------------------------------------------------
-- Per-field materialization
-- ---------------------------------------------------------------------------

-- Decode a single value at `val_start`. For message fields returns a
-- lazy sub-view (or eager value via WKT desc.decode override).
local function read_singular(field, bytes, val_start)
    local kind = field.kind
    if kind == 'scalar' then
        local v = wire.TYPE_INFO[field.proto_type].decode(bytes, val_start)
        return v
    elseif kind == 'enum' then
        local u = wire.decode_varint(bytes, val_start)
        return wire.varint_to_int32(u)
    elseif kind == 'message' then
        local payload = wire.decode_len(bytes, val_start)
        if field.message.decode ~= nil then
            return field.message.decode(payload)
        end
        return build_msg_view(field.message, payload)
    end
    error("read_singular: unknown kind " .. tostring(kind), 0)
end

-- For singular fields, semantics for multiple wire entries with the same id:
--   - scalar/enum: last wins.
--   - message: merged. We delegate to the eager codec by concatenating
--     per-entry payloads. (Multi-entry singular messages are rare; this
--     is the off-fast-path correctness branch.)
local function read_singular_list(field, bytes, segs, idx_list)
    if field.kind ~= 'message' or #idx_list == 1 then
        return read_singular(field, bytes, segs.val_start[idx_list[#idx_list]])
    end
    local parts = {}
    for i = 1, #idx_list do
        local payload = wire.decode_len(bytes, segs.val_start[idx_list[i]])
        parts[i] = payload
    end
    local merged = table.concat(parts)
    if field.message.decode ~= nil then
        return field.message.decode(merged)
    end
    return build_msg_view(field.message, merged)
end

-- ---------------------------------------------------------------------------
-- ArrayView: lazy view over a repeated field.
--
-- Stores a flat int array `_starts` of value offsets (one int per element).
-- For unpacked, those come from the parent's val_start array (subset).
-- For packed, they're scanned out of the packed payload at construct time.
-- :at(i) decodes from bytes[_starts[i]] using the field's known kind.
-- ---------------------------------------------------------------------------

---@class pb.ArrayView
local ArrayView = {}
ArrayView.__index = ArrayView

-- Walk a packed payload, emitting one val_start per element. Cheaper as
-- a one-pass scan than re-walking on every :at — packed payloads are
-- contiguous so each step is just a wire.skip_field with the element's
-- known wire type.
local function expand_packed(field, bytes, val_start)
    local h = field.kind == 'scalar' and wire.TYPE_INFO[field.proto_type] or nil
    local b = bytes:byte(val_start)
    local payload_len, hdr_end
    if b < 0x80 then
        payload_len = b; hdr_end = val_start + 1
    else
        local v, npos = wire.decode_varint(bytes, val_start)
        payload_len = tonumber(v); hdr_end = npos
    end
    local lim = hdr_end + payload_len
    local elem_wire = (field.kind == 'scalar') and h.wire or wire.WIRE_VARINT
    local starts, n = {}, 0
    local p = hdr_end
    while p < lim do
        n = n + 1
        starts[n] = p
        p = wire.skip_field(bytes, p, elem_wire)
    end
    return starts, n
end

local function build_array_view_impl(field, bytes, segs, idx_list)
    -- Detect packed vs unpacked from the wire type of the entries.
    -- For repeated scalars/enums with a single LEN-typed wire entry
    -- when the element type is non-LEN, that's a packed payload.
    local mode, starts, n
    local first_idx = idx_list[1]
    local tag_byte = bytes:byte(segs.tag_start[first_idx])
    local first_wt = tag_byte % 8  -- low 3 bits

    if field.kind == 'message' then
        -- Repeated messages never pack.
        mode = 'unpacked'
        n = #idx_list
        starts = {}
        for i = 1, n do starts[i] = segs.val_start[idx_list[i]] end
    elseif (field.kind == 'scalar' or field.kind == 'enum')
        and #idx_list == 1 and first_wt == wire.WIRE_LEN
        and not (field.kind == 'scalar'
                 and wire.TYPE_INFO[field.proto_type].wire == wire.WIRE_LEN) then
        mode = 'packed'
        starts, n = expand_packed(field, bytes, segs.val_start[first_idx])
    else
        mode = 'unpacked'
        n = #idx_list
        starts = {}
        for i = 1, n do starts[i] = segs.val_start[idx_list[i]] end
    end

    return setmetatable({
        _field  = field,
        _bytes  = bytes,
        _starts = starts,
        _n      = n,
    }, ArrayView)
end

build_array_view = build_array_view_impl

function ArrayView:len() return self._n end

function ArrayView:at(i)
    if i < 1 or i > self._n then return nil end
    local field, bytes = self._field, self._bytes
    local val_start = self._starts[i]
    return read_singular(field, bytes, val_start)
end

function ArrayView:iter()
    local view, i, n = self, 0, self._n
    return function()
        i = i + 1
        if i > n then return nil end
        return i, view:at(i)
    end
end

function ArrayView:tolist()
    local out = {}
    for i = 1, self._n do out[i] = self:at(i) end
    return out
end

-- ---------------------------------------------------------------------------
-- MapView: lazy view over a map<K,V> field.
--
-- Stores a flat int array `_starts` of LEN-prefix offsets — one per map
-- entry. Each entry contains the (key, value) sub-fields and is decoded
-- on first :get/:has/:iter to build a key->value cache.
-- ---------------------------------------------------------------------------

---@class pb.MapView
local MapView = {}
MapView.__index = MapView

local function decode_map_entry(field, bytes, val_start)
    local key_field, val_field = field.key, field.value
    local b = bytes:byte(val_start)
    local payload_len, hdr_end
    if b < 0x80 then
        payload_len = b; hdr_end = val_start + 1
    else
        local v, npos = wire.decode_varint(bytes, val_start)
        payload_len = tonumber(v); hdr_end = npos
    end
    local lim = hdr_end + payload_len
    local key, val
    local p = hdr_end
    while p < lim do
        local eid, ewt, np = wire.decode_tag(bytes, p)
        p = np
        if eid == 1 then
            if key_field.kind == 'scalar' then
                key, p = wire.TYPE_INFO[key_field.proto_type].decode(bytes, p)
            elseif key_field.kind == 'enum' then
                local u; u, p = wire.decode_varint(bytes, p); key = wire.varint_to_int32(u)
            end
        elseif eid == 2 then
            if val_field.kind == 'scalar' then
                val, p = wire.TYPE_INFO[val_field.proto_type].decode(bytes, p)
            elseif val_field.kind == 'enum' then
                local u; u, p = wire.decode_varint(bytes, p); val = wire.varint_to_int32(u)
            elseif val_field.kind == 'message' then
                local payload; payload, p = wire.decode_len(bytes, p)
                if val_field.message.decode ~= nil then
                    val = val_field.message.decode(payload)
                else
                    val = build_msg_view(val_field.message, payload)
                end
            end
        else
            p = wire.skip_field(bytes, p, ewt, eid)
        end
    end
    if key == nil then
        if key_field.kind == 'scalar' then
            local pt = key_field.proto_type
            if pt == 'string' or pt == 'bytes' then key = ''
            elseif pt == 'bool' then key = false
            else key = 0 end
        else key = 0 end
    end
    if val == nil then
        if val_field.kind == 'scalar' then
            local pt = val_field.proto_type
            if pt == 'string' or pt == 'bytes' then val = ''
            elseif pt == 'bool' then val = false
            else val = 0 end
        elseif val_field.kind == 'enum' then val = 0
        elseif val_field.kind == 'message' then val = {} end
    end
    return key, val
end

local function build_map_view_impl(field, bytes, segs, idx_list)
    local n = #idx_list
    local starts = {}
    for i = 1, n do starts[i] = segs.val_start[idx_list[i]] end
    return setmetatable({
        _field  = field,
        _bytes  = bytes,
        _starts = starts,
        _n      = n,
        -- _by_key populated lazily on first :get/:has/:iter call.
    }, MapView)
end

build_map_view = build_map_view_impl

local function map_ensure_index(self)
    if self._by_key ~= nil then return end
    local field, bytes, starts, n = self._field, self._bytes, self._starts, self._n
    local by_key = {}
    local keys = {}
    for i = 1, n do
        local k, v = decode_map_entry(field, bytes, starts[i])
        if by_key[k] == nil then keys[#keys + 1] = k end
        by_key[k] = v  -- duplicate keys: last wins (matches eager decode)
    end
    self._by_key = by_key
    self._keys = keys
end

function MapView:get(k)
    map_ensure_index(self)
    return self._by_key[k]
end

function MapView:has(k)
    map_ensure_index(self)
    return self._by_key[k] ~= nil
end

function MapView:keys()
    map_ensure_index(self)
    local out = {}
    for i = 1, #self._keys do out[i] = self._keys[i] end
    return out
end

function MapView:iter()
    map_ensure_index(self)
    local keys, by_key = self._keys, self._by_key
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k == nil then return nil end
        return k, by_key[k]
    end
end

function MapView:totable()
    map_ensure_index(self)
    local out = {}
    for k, v in pairs(self._by_key) do out[k] = v end
    return out
end

-- ---------------------------------------------------------------------------
-- MessageView (top-level)
-- ---------------------------------------------------------------------------

---@class pb.MessageView
local MessageView = {}
MessageView.__index = MessageView

local function build_msg_view_impl(desc, bytes)
    if desc.decode ~= nil then
        -- WKT / custom-decode descriptor. Eager-wrap so the API stays uniform.
        local materialized = desc.decode(bytes)
        return setmetatable({
            _desc = desc,
            _eager = materialized,
            _eager_only = true,
        }, MessageView)
    end
    local segs, by_id = index_bytes(desc, bytes)
    return setmetatable({
        _desc = desc,
        _bytes = bytes,
        _segs  = segs,
        _by_id = by_id,
        _cache = {},
        -- Parallel array of cached sub-MessageViews so :is_dirty can
        -- ipairs over it instead of pairs(_cache) — `pairs` over a hash
        -- compiles to bytecode ISNEXT, NYI in Tarantool's LuaJIT 2.1.
        _sub_msg_views = {},
    }, MessageView)
end

build_msg_view = build_msg_view_impl
M.build = build_msg_view_impl

-- :get(name) -> decoded value, or nil if not on wire.
function MessageView:get(name)
    if self._eager_only then return self._eager[name] end
    local cache = self._cache
    local v = cache[name]
    if v ~= nil then return v end
    local field = self._desc.field_by_name[name]
    if field == nil then return nil end
    local idx_list = self._by_id[field.id]
    if idx_list == nil then return nil end
    if field.kind == 'map' then
        v = build_map_view(field, self._bytes, self._segs, idx_list)
    elseif field.repeated then
        v = build_array_view(field, self._bytes, self._segs, idx_list)
    else
        v = read_singular_list(field, self._bytes, self._segs, idx_list)
    end
    cache[name] = v
    if type(v) == 'table' and getmetatable(v) == MessageView then
        local s = self._sub_msg_views
        s[#s + 1] = v
    end
    return v
end

-- :has(name) -> was this field present on the wire?
function MessageView:has(name)
    if self._eager_only then return self._eager[name] ~= nil end
    local field = self._desc.field_by_name[name]
    if field == nil then return false end
    return self._by_id[field.id] ~= nil
end

-- :which(oneof_name) -> name of the active branch, or nil.
-- Proto3 last-wins: if multiple branches appeared on the wire, the one
-- whose final entry came last in wire order is active.
function MessageView:which(oneof_name)
    if self._eager_only then
        local oneofs = self._desc.oneofs
        if oneofs == nil then return nil end
        local members = oneofs[oneof_name]
        if members == nil then return nil end
        for i = 1, #members do
            if self._eager[members[i]] ~= nil then return members[i] end
        end
        return nil
    end
    local oneofs = self._desc.oneofs
    if oneofs == nil then return nil end
    local members = oneofs[oneof_name]
    if members == nil then return nil end
    local member_set = {}
    for i = 1, #members do member_set[members[i]] = true end
    local segs = self._segs
    local fbi = self._desc.field_by_id
    local active, active_pos
    for i = 1, segs.n do
        local f = fbi[segs.id[i]]
        if f ~= nil and member_set[f.name] then
            local ts = segs.tag_start[i]
            if active_pos == nil or ts > active_pos then
                active = f.name
                active_pos = ts
            end
        end
    end
    return active
end

-- :names() -> iterator yielding present field names in wire order
-- (deduplicated; each field appears once even when it has multiple wire entries).
function MessageView:names()
    if self._eager_only then
        local fields, i = self._desc.fields, 0
        local eager = self._eager
        return function()
            while true do
                i = i + 1
                local f = fields[i]
                if f == nil then return nil end
                if eager[f.name] ~= nil then return f.name end
            end
        end
    end
    local segs = self._segs
    local fbi = self._desc.field_by_id
    local emitted = {}
    local i = 0
    return function()
        while true do
            i = i + 1
            if i > segs.n then return nil end
            local f = fbi[segs.id[i]]
            if f ~= nil and emitted[f.name] == nil then
                emitted[f.name] = true
                return f.name
            end
        end
    end
end

-- :iter() -> iterator yielding (name, value) for present fields,
-- decoding each value on demand. Order = wire order, deduplicated.
function MessageView:iter()
    if self._eager_only then
        local fields, i = self._desc.fields, 0
        local eager = self._eager
        return function()
            while true do
                i = i + 1
                local f = fields[i]
                if f == nil then return nil end
                local v = eager[f.name]
                if v ~= nil then return f.name, v end
            end
        end
    end
    local segs = self._segs
    local fbi = self._desc.field_by_id
    local emitted = {}
    local view = self
    local i = 0
    return function()
        while true do
            i = i + 1
            if i > segs.n then return nil end
            local f = fbi[segs.id[i]]
            if f ~= nil and emitted[f.name] == nil then
                emitted[f.name] = true
                return f.name, view:get(f.name)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

-- :set(name, value) marks a field dirty. Subsequent :encode() emits the
-- new value via the codec; other fields passthrough their original bytes.
function MessageView:set(name, value)
    if self._eager_only then
        self._eager[name] = value
        self._eager_dirty = true
        return
    end
    local field = self._desc.field_by_name[name]
    if field == nil then
        error("unknown field '" .. tostring(name) .. "' on " .. self._desc.name, 0)
    end
    if self._dirty == nil then self._dirty = {} end
    self._dirty[name] = true
    self._cache[name] = value
end

-- :is_dirty() returns true if this view has had :set called, OR if any
-- cached sub-view has been mutated. Walks _sub_msg_views (flat array)
-- with ipairs to stay JIT-stable.
function MessageView:is_dirty()
    if self._eager_only then return self._eager_dirty == true end
    local d = self._dirty
    if d ~= nil and next(d) ~= nil then return true end
    local subs = self._sub_msg_views
    for i = 1, #subs do
        if subs[i]:is_dirty() then return true end
    end
    return false
end

-- Materialize a possibly-view value so encode_field can consume it.
local function materialize(value)
    if type(value) ~= 'table' then return value end
    local m = getmetatable(value)
    if m == MessageView then
        return value:totable()
    elseif m == ArrayView then
        return value:tolist()
    elseif m == MapView then
        return value:totable()
    end
    return value
end

function MessageView:totable()
    if self._eager_only then return self._eager end
    local out = {}
    for name in self:names() do
        out[name] = materialize(self:get(name))
    end
    -- Preserve unknown fields for round-trip.
    local segs = self._segs
    if segs then
        local unknown = {}
        local fbi = self._desc.field_by_id
        for i = 1, segs.n do
            if fbi[segs.id[i]] == nil then
                unknown[#unknown + 1] =
                    self._bytes:sub(segs.tag_start[i], segs.next_start[i] - 1)
            end
        end
        if #unknown > 0 then out._unknown_fields = table.concat(unknown) end
    end
    return out
end

-- :encode() emits bytes. Three modes:
--   1. WKT eager-wrap: delegate to desc.encode on the materialized table.
--   2. Untouched (no dirty fields, no dirty sub-views): emit the original
--      bytes verbatim — perfect byte-for-byte passthrough.
--   3. Mixed: walk fields in id order, splice clean segments, encode
--      dirty values fresh. Unknown segments are emitted at the end.
function MessageView:encode()
    if self._eager_only then
        return self._desc.encode(self._eager)
    end
    if not self:is_dirty() then
        return self._bytes
    end

    local out = {}
    local fields = self._desc.fields
    local bytes = self._bytes
    local segs = self._segs
    local by_id = self._by_id
    local dirty = self._dirty or {}
    local cache = self._cache

    -- Active-oneof resolution mirrors codec.encode_message: a oneof
    -- field is only emitted if it's the active branch.
    local active
    local oneofs_list = self._desc.oneofs_list
    if oneofs_list then
        active = {}
        for i = 1, #oneofs_list do
            local oo = oneofs_list[i]
            local members = oo.members
            for j = 1, #members do
                local fname = members[j]
                if dirty[fname]
                    or by_id[self._desc.field_by_name[fname].id] then
                    active[oo.name] = fname
                end
            end
        end
    end

    for i = 1, #fields do
        local f = fields[i]
        local fname = f.name
        local is_dirty = dirty[fname] == true
        local is_sub_dirty = false
        if not is_dirty then
            local cached = cache[fname]
            if cached ~= nil and type(cached) == 'table'
                and getmetatable(cached) == MessageView and cached:is_dirty() then
                is_sub_dirty = true
            end
        end

        if f.oneof and active and active[f.oneof] ~= fname then
            -- Inactive oneof branch: skip.
        elseif is_dirty or is_sub_dirty then
            codec.encode_field(f, materialize(cache[fname]), out,
                f.optional or (f.oneof ~= nil))
        elseif by_id[f.id] then
            local idx_list = by_id[f.id]
            for j = 1, #idx_list do
                local idx = idx_list[j]
                out[#out + 1] = bytes:sub(segs.tag_start[idx],
                                          segs.next_start[idx] - 1)
            end
        end
    end

    -- Unknown segments preserved at the end.
    local fbi = self._desc.field_by_id
    for i = 1, segs.n do
        if fbi[segs.id[i]] == nil then
            out[#out + 1] = bytes:sub(segs.tag_start[i], segs.next_start[i] - 1)
        end
    end

    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Public entry
-- ---------------------------------------------------------------------------

M.MessageView = MessageView
M.ArrayView   = ArrayView
M.MapView     = MapView

return M
