-- prim_ffi.lua -- Strategy 2: per-primitive FFI bindings.
--
-- Dispatch (per-field branch logic) is in Lua. Each wire primitive
-- crosses the FFI boundary into prim.c. Used by spike_bench.lua via
-- require('prim_ffi').

local ffi = require('ffi')
local bit = require('bit')

ffi.cdef[[
    typedef struct ibuf_s {
        uint8_t *data;
        size_t   len;
        size_t   cap;
    } ibuf_t;

    void pb_ibuf_init(ibuf_t *b);
    void pb_ibuf_free(ibuf_t *b);
    void pb_ibuf_reset(ibuf_t *b);

    void pb_write_varint(ibuf_t *b, uint64_t v);
    void pb_write_bytes(ibuf_t *b, const uint8_t *src, size_t n);
    void pb_write_string_field(ibuf_t *b, uint32_t tag,
                               const uint8_t *src, size_t n);
    const uint8_t *pb_read_varint(const uint8_t *p,
                                  const uint8_t *end, uint64_t *out);
]]

local function find_lib()
    local SCRIPT_DIR = (debug.getinfo(1, 'S').source:match('@?(.*/)') or './')
    local UNAME = io.popen('uname -s'):read('*l')
    local ext = (UNAME == 'Darwin') and '.dylib' or '.so'
    return SCRIPT_DIR .. 'libpb_prim' .. ext
end

local C = ffi.load(find_lib())

local outbuf = ffi.new('ibuf_t')
C.pb_ibuf_init(outbuf)
local subbuf = ffi.new('ibuf_t')
C.pb_ibuf_init(subbuf)
local sub2buf = ffi.new('ibuf_t')  -- for one extra level of nesting
C.pb_ibuf_init(sub2buf)

local v_out = ffi.new('uint64_t[1]')

local rshift, band = bit.rshift, bit.band

local M = {}

-- ----------------------------------------------------------------
-- Address (sub-message used by Person.address) encode/decode helpers
-- ----------------------------------------------------------------

local function address_encode_into(buf, t)
    if t.street then
        C.pb_write_string_field(buf, 0x0A, t.street, #t.street)
    end
    if t.city then
        C.pb_write_string_field(buf, 0x12, t.city, #t.city)
    end
    if t.zip then
        C.pb_write_varint(buf, 0x18)
        C.pb_write_varint(buf, t.zip)
    end
end

-- ----------------------------------------------------------------
-- Person encode
-- ----------------------------------------------------------------

function M.Person_encode(t)
    C.pb_ibuf_reset(outbuf)
    if t.name then
        C.pb_write_string_field(outbuf, 0x0A, t.name, #t.name)
    end
    if t.age then
        C.pb_write_varint(outbuf, 0x10)
        C.pb_write_varint(outbuf, t.age)
    end
    if t.emails then
        local emails = t.emails
        for i = 1, #emails do
            local e = emails[i]
            C.pb_write_string_field(outbuf, 0x1A, e, #e)
        end
    end
    if t.address then
        C.pb_ibuf_reset(subbuf)
        address_encode_into(subbuf, t.address)
        C.pb_write_varint(outbuf, 0x2A)
        C.pb_write_varint(outbuf, subbuf.len)
        C.pb_write_bytes(outbuf, subbuf.data, subbuf.len)
    end
    if t.lucky_numbers then
        C.pb_ibuf_reset(subbuf)
        local lucky = t.lucky_numbers
        for i = 1, #lucky do
            C.pb_write_varint(subbuf, lucky[i])
        end
        C.pb_write_varint(outbuf, 0x3A)
        C.pb_write_varint(outbuf, subbuf.len)
        C.pb_write_bytes(outbuf, subbuf.data, subbuf.len)
    end
    return ffi.string(outbuf.data, outbuf.len)
end

-- ----------------------------------------------------------------
-- Person decode
-- ----------------------------------------------------------------

local function decode_address(p, endp)
    local result = {}
    while p < endp do
        p = C.pb_read_varint(p, endp, v_out)
        if p == nil then break end
        local tag = tonumber(v_out[0])
        local field = rshift(tag, 3)
        local wt    = band(tag, 7)
        if wt == 2 then
            p = C.pb_read_varint(p, endp, v_out)
            local slen = tonumber(v_out[0])
            if field == 1 then
                result.street = ffi.string(p, slen)
            elseif field == 2 then
                result.city = ffi.string(p, slen)
            end
            p = p + slen
        elseif wt == 0 then
            p = C.pb_read_varint(p, endp, v_out)
            if field == 3 then
                result.zip = tonumber(v_out[0])
            end
        else
            break
        end
    end
    return result
end

function M.Person_decode(s)
    local p    = ffi.cast('const uint8_t*', s)
    local endp = p + #s
    local result  = {}
    local emails  = nil
    local n_emails = 0
    local lucky   = nil
    local n_lucky = 0

    while p < endp do
        p = C.pb_read_varint(p, endp, v_out)
        if p == nil then break end
        local tag = tonumber(v_out[0])
        local field = rshift(tag, 3)
        local wt    = band(tag, 7)
        if wt == 2 then
            p = C.pb_read_varint(p, endp, v_out)
            local slen = tonumber(v_out[0])
            if field == 1 then
                result.name = ffi.string(p, slen)
                p = p + slen
            elseif field == 3 then
                if emails == nil then emails = {} end
                n_emails = n_emails + 1
                emails[n_emails] = ffi.string(p, slen)
                p = p + slen
            elseif field == 5 then
                result.address = decode_address(p, p + slen)
                p = p + slen
            elseif field == 7 then
                if lucky == nil then lucky = {} end
                local fend = p + slen
                while p < fend do
                    p = C.pb_read_varint(p, fend, v_out)
                    if p == nil then break end
                    n_lucky = n_lucky + 1
                    lucky[n_lucky] = tonumber(v_out[0])
                end
            else
                p = p + slen
            end
        elseif wt == 0 then
            p = C.pb_read_varint(p, endp, v_out)
            if field == 2 then
                result.age = tonumber(v_out[0])
            end
        else
            break
        end
    end

    if emails then result.emails = emails end
    if lucky  then result.lucky_numbers = lucky end
    return result
end

return M
