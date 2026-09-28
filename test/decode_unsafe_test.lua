-- decode_unsafe: opt-in non-validating decode for trusted producers
-- (re-decoding bytes from own encoder, JSON/text round-trips, in-process
-- typed RPC). Skips per-string utf8_len on every singular/repeated/map
-- string field; sub-message recursion stays on the unsafe path.
--
-- Full mode emits a literal sister <Msg>_decode_unsafe body.
-- Runtime mode wraps pb.decode_unsafe, which dispatches through
-- f._reader_unsafe closures compiled in pb.finalize_message against
-- a swapped scalar table (scalar.string = scalar.bytes) — see
-- codec.compile_readers_unsafe.
--
-- This file runs the same suite against both modes to pin the API
-- contract (one function name, same semantics) regardless of which
-- code path executed.
local t = require('luatest')

local function address_with_street(s)
    return string.char(0x0A, #s) .. s
end

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('decode_unsafe.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    g.test_valid_string_matches_safe_decode = function()
        local addr = {street = 'Pushkina 1', city = 'Moscow', zip = 123456}
        local bytes = hello.Address_encode(addr)
        t.assert_equals(hello.Address_decode_unsafe(bytes),
                        hello.Address_decode(bytes))
    end

    g.test_safe_decode_rejects_invalid_utf8 = function()
        -- 0xC0 0x80 is the classic overlong NUL — rejected by RFC 3629
        -- (also banned in proto3 strings).
        local bytes = address_with_street('\xC0\x80')
        t.assert_error_msg_contains(
            'invalid UTF-8',
            function() hello.Address_decode(bytes) end)
    end

    g.test_unsafe_decode_accepts_invalid_utf8 = function()
        local bytes = address_with_street('\xC0\x80')
        local dec = hello.Address_decode_unsafe(bytes)
        t.assert_equals(dec.street, '\xC0\x80')
    end

    g.test_unsafe_decode_repeated_string = function()
        -- Person.emails is a repeated string; two entries, second invalid.
        local good = 'alice@example.com'
        local bad  = '\xFF\xFE'
        local bytes = string.char(0x1A, #good) .. good
                    .. string.char(0x1A, #bad)  .. bad
        t.assert_error_msg_contains(
            'invalid UTF-8',
            function() hello.Person_decode(bytes) end)
        local dec = hello.Person_decode_unsafe(bytes)
        t.assert_equals(dec.emails, {good, bad})
    end

    g.test_unsafe_decode_recurses_into_sub_messages = function()
        -- Person{address = Address{street = '\xC0\x80'}}.
        -- Pins that the unsafe path threads through sub-messages — a
        -- mistake here would call the safe Address decoder and error.
        local inner = address_with_street('\xC0\x80')
        local bytes = string.char(0x2A, #inner) .. inner

        t.assert_error_msg_contains(
            'invalid UTF-8',
            function() hello.Person_decode(bytes) end)

        local dec = hello.Person_decode_unsafe(bytes)
        t.assert_equals(dec.address.street, '\xC0\x80')
    end

    g.test_unsafe_decode_handles_long_string_fallback = function()
        -- >=128 byte payload exits the 1-byte LEN inline fast path. Full
        -- mode falls through to wire.decode_bytes (codegen swap); runtime
        -- mode lands in the compiled _reader_unsafe scalar handler which
        -- is scalar_unsafe.string (= bytes). Both paths must accept
        -- invalid UTF-8 in the long-string regime.
        local big = string.rep('x', 200) .. '\xFF'  -- 201 bytes, trailing bad
        local bytes = string.char(0x0A) .. string.char(0xC9, 0x01) .. big
        -- 201 in varint = 0xC9 0x01.
        t.assert_error_msg_contains(
            'invalid UTF-8',
            function() hello.Address_decode(bytes) end)
        local dec = hello.Address_decode_unsafe(bytes)
        t.assert_equals(#dec.street, 201)
        t.assert_equals(dec.street:byte(201), 0xFF)
    end

    g.test_unsafe_decode_map_string_value = function()
        -- Person.ages_by_nickname is map<string, int32> — string KEYS go
        -- through the map-fallback decode_one path in runtime mode (no
        -- _reader for map fields). The unsafe twin passes scalar_unsafe
        -- to decode_one so the key's utf8_len is bypassed. In full mode
        -- the inline map decoder routes through wire.decode_bytes.
        -- map<string, int32>: entry message = {1: string key, 2: int32 value}.
        local bad_key = '\xFE'
        local entry = string.char(0x0A, #bad_key) .. bad_key  -- key tag
                    .. string.char(0x10, 7)                    -- value tag + varint 7
        -- Person.ages_by_nickname id is per the .proto — check it.
        -- Use bench/dynamic introspection: look up field id from descriptor.
        local f = nil
        for _, fld in ipairs(hello.Person_descriptor.fields) do
            if fld.name == 'ages_by_nickname' then f = fld; break end
        end
        t.assert_not_equals(f, nil)
        local tag = require('pb.wire').encode_tag(f.id, 2)
        local bytes = tag .. string.char(#entry) .. entry

        t.assert_error_msg_contains(
            'invalid UTF-8',
            function() hello.Person_decode(bytes) end)
        local dec = hello.Person_decode_unsafe(bytes)
        t.assert_equals(dec.ages_by_nickname[bad_key], 7)
    end
end
