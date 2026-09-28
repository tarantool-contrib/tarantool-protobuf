-- C-side oneof encode/decode.
--
-- Acceptance criteria:
--   hello.Result (oneof outcome { string text=2; int32 code=3;
--   Address details=4; }) round-trips byte-equal across all three
--   branches; decoded table includes the active branch and excludes
--   the others. Mirrors test/protobuf_test.lua g.test_oneof_* but
--   drives encode/decode through pb.c_runtime.
--
-- Gated on PB_ENABLE_C=1 + a loadable c_runtime module, same as the
-- sibling c_runtime_*_test.lua files.

local t = require('luatest')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

local full_hello

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_oneof.' .. mode)
    local hello
    local plan

    g.before_all(function()
        skip_if_no_c()
        hello = require(mode .. '.hello.hello_pb')
        full_hello = require('full.hello.hello_pb')
        plan = c_runtime.compile_plan(hello.Result_descriptor)
    end)

    g.before_each(skip_if_no_c)

    function g.test_oneof_text_branch_encode_byte_equal()
        local msg = {id = 1, text = 'hello'}
        local c_bytes = c_runtime.encode(plan, msg)
        local lua_bytes = full_hello.Result_encode(msg)
        t.assert_equals(c_bytes, lua_bytes)
    end

    function g.test_oneof_code_branch_encode_byte_equal()
        local msg = {id = 2, code = 42}
        local c_bytes = c_runtime.encode(plan, msg)
        local lua_bytes = full_hello.Result_encode(msg)
        t.assert_equals(c_bytes, lua_bytes)
    end

    function g.test_oneof_message_branch_encode_byte_equal()
        local msg = {id = 3, details = {street = 'X', zip = 99}}
        local c_bytes = c_runtime.encode(plan, msg)
        local lua_bytes = full_hello.Result_encode(msg)
        t.assert_equals(c_bytes, lua_bytes)
    end

    function g.test_oneof_text_branch_round_trip()
        local msg = {id = 1, text = 'hello'}
        local dec = c_runtime.decode(plan, c_runtime.encode(plan, msg))
        t.assert_equals(dec.id, 1)
        t.assert_equals(dec.text, 'hello')
        t.assert_equals(dec.code, nil)
        t.assert_equals(dec.details, nil)
    end

    function g.test_oneof_code_branch_round_trip()
        local msg = {id = 2, code = 42}
        local dec = c_runtime.decode(plan, c_runtime.encode(plan, msg))
        t.assert_equals(dec.id, 2)
        t.assert_equals(dec.code, 42)
        t.assert_equals(dec.text, nil)
        t.assert_equals(dec.details, nil)
    end

    function g.test_oneof_message_branch_round_trip()
        local msg = {id = 3, details = {street = 'X', zip = 99}}
        local dec = c_runtime.decode(plan, c_runtime.encode(plan, msg))
        t.assert_equals(dec.id, 3)
        t.assert_equals(dec.details.street, 'X')
        t.assert_equals(dec.details.zip, 99)
        t.assert_equals(dec.text, nil)
        t.assert_equals(dec.code, nil)
    end

    function g.test_oneof_emits_default_value_when_active()
        -- text='' is the proto3 string default. Outside a oneof it would
        -- elide; inside, presence is meaningful. Active branch must emit.
        local c_bytes = c_runtime.encode(plan, {text = ''})
        t.assert_equals(c_bytes, '\x12\x00')
        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.text, '')
    end

    function g.test_oneof_decode_clears_siblings()
        -- Wire bytes carry text first, then code. Decoder must end with
        -- code set and text cleared (last-wins per spec).
        local raw = '\x12\x03foo'  -- field 2 (text) LEN=3, "foo"
                  .. '\x18\x07'    -- field 3 (code) varint 7
        local dec = c_runtime.decode(plan, raw)
        t.assert_equals(dec.code, 7)
        t.assert_equals(dec.text, nil)
    end

    function g.test_oneof_last_set_wins_on_encode()
        -- Caller sets multiple branches; encoder picks the last in
        -- declaration order (details = field 4).
        local msg = {text = 'first', code = 9, details = {street = 'last'}}
        local c_bytes = c_runtime.encode(plan, msg)
        -- Byte-equal to Lua reference encode, which also resolves to
        -- details-only.
        local lua_bytes = full_hello.Result_encode(msg)
        t.assert_equals(c_bytes, lua_bytes)
        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.details.street, 'last')
        t.assert_equals(dec.text, nil)
        t.assert_equals(dec.code, nil)
    end

    function g.test_oneof_message_branch_decode_clears_scalar_sibling()
        -- Sibling-clear must also fire when the active branch is a
        -- sub-message (exercises the PB_KIND_MESSAGE arm of the
        -- singular dispatch).
        local raw = '\x18\x07'                  -- code = 7
                  .. '\x22\x03\x0a\x01X'        -- details {street="X"}
        local dec = c_runtime.decode(plan, raw)
        t.assert_equals(dec.details.street, 'X')
        t.assert_equals(dec.code, nil)
        t.assert_equals(dec.text, nil)
    end
end
