-- Tests for WKT override-hook passthrough.
--
-- A plan whose descriptor carries desc.encode / desc.decode dispatches
-- straight to those overrides instead of walking fields. The Event
-- message exercises every WKT shape we ship — Timestamp, Duration,
-- Empty, the <T>Value wrappers, Struct, Value, ListValue, Any,
-- FieldMask — so byte-equality with mode=full proves the override is
-- live at both the top level and when nested as a sub-message field.
--
-- Acceptance: hello.Event with WKT sub-messages round-trips byte-equal
-- to mode=full pure-Lua, runtime/pb/wkt.lua is unmodified.

local t = require('luatest')
local datetime = require('datetime')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

local full_hello

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_wkt.' .. mode)
    local hello

    g.before_all(function()
        skip_if_no_c()
        hello = require(mode .. '.hello.hello_pb')
        full_hello = require('full.hello.hello_pb')
    end)

    g.before_each(skip_if_no_c)

    -- ---------- Top-level override dispatch ----------

    function g.test_timestamp_top_level_encode_decode()
        local plan = c_runtime.compile_plan(pb.wkt.Timestamp_descriptor)
        local dt = datetime.new({timestamp = 1700000000, nsec = 123})
        local c_bytes = c_runtime.encode(plan, dt)
        t.assert_equals(c_bytes, pb.wkt.Timestamp_encode(dt))
        local out = c_runtime.decode(plan, c_bytes)
        t.assert(datetime.is_datetime(out))
        t.assert_equals(out.epoch, 1700000000)
        t.assert_equals(out.nsec, 123)
    end

    function g.test_duration_top_level_round_trip()
        local plan = c_runtime.compile_plan(pb.wkt.Duration_descriptor)
        local v = {seconds = 7200, nanos = 500}
        local c_bytes = c_runtime.encode(plan, v)
        t.assert_equals(c_bytes, pb.wkt.Duration_encode(v))
        t.assert_equals(c_runtime.decode(plan, c_bytes),
                        pb.wkt.Duration_decode(c_bytes))
    end

    function g.test_empty_top_level_encode_is_zero_bytes()
        local plan = c_runtime.compile_plan(pb.wkt.Empty_descriptor)
        t.assert_equals(c_runtime.encode(plan, {}), '')
    end

    function g.test_int32value_wrapper_top_level()
        local plan = c_runtime.compile_plan(pb.wkt.Int32Value_descriptor)
        -- The wrapper accepts the bare scalar; presence is meaningful.
        t.assert_equals(c_runtime.encode(plan, 42),
                        pb.wkt.Int32Value_encode(42))
    end

    -- ---------- Nested override dispatch (sub-message field) ----------

    function g.test_event_with_timestamp_byte_equal()
        local plan = c_runtime.compile_plan(hello.Event_descriptor)
        local msg = {
            title = 'hi',
            created_at = datetime.new(
                {timestamp = 1700000000, nsec = 123456789}),
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Event_encode(msg))
    end

    function g.test_event_with_duration_and_empty_byte_equal()
        local plan = c_runtime.compile_plan(hello.Event_descriptor)
        local msg = {
            title = 'hi',
            duration = {seconds = 60, nanos = 0},
            ack = {},
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Event_encode(msg))
    end

    function g.test_event_with_wrappers_byte_equal()
        local plan = c_runtime.compile_plan(hello.Event_descriptor)
        local msg = {
            retry_count = 5,
            note = 'remember',
            is_admin = true,
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Event_encode(msg))
    end

    function g.test_event_with_wrapper_zero_preserved()
        local plan = c_runtime.compile_plan(hello.Event_descriptor)
        -- Wrappers preserve presence at zero — the override must still
        -- emit tag + len(0). A naive "skip default" path would lose it.
        local msg = {retry_count = 0}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Event_encode(msg))
    end

    function g.test_event_with_fieldmask_byte_equal()
        local plan = c_runtime.compile_plan(hello.Event_descriptor)
        local msg = {update_mask = {paths = {'foo', 'bar.baz'}}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Event_encode(msg))
    end

    -- ---------- Round-trip parity through the C path ----------
    --
    -- Encode in C, decode in C, compare against mode=full's decode of
    -- the same wire bytes. Asserts the override decode wrapper hands
    -- back the same Lua representation the pure-Lua codec does.

    function g.test_event_round_trip_through_c()
        local plan = c_runtime.compile_plan(hello.Event_descriptor)
        local dt = datetime.new({timestamp = 42, nsec = 500})
        local msg = {
            title = 'x',
            created_at = dt,
            duration = {seconds = 1, nanos = 2},
            ack = {},
            retry_count = 7,
            note = 'hello',
            update_mask = {paths = {'a', 'b'}},
        }
        local bytes = c_runtime.encode(plan, msg)
        local c_dec = c_runtime.decode(plan, bytes)
        local lua_dec = full_hello.Event_decode(bytes)

        t.assert_equals(c_dec.title, lua_dec.title)
        t.assert(datetime.is_datetime(c_dec.created_at))
        t.assert_equals(c_dec.created_at.epoch, lua_dec.created_at.epoch)
        t.assert_equals(c_dec.created_at.nsec,  lua_dec.created_at.nsec)
        t.assert_equals(tonumber(c_dec.duration.seconds),
                        tonumber(lua_dec.duration.seconds))
        t.assert_equals(c_dec.duration.nanos, lua_dec.duration.nanos)
        t.assert_equals(type(c_dec.ack), 'table')
        t.assert_equals(c_dec.retry_count, lua_dec.retry_count)
        t.assert_equals(c_dec.note, lua_dec.note)
        t.assert_equals(c_dec.update_mask.paths, lua_dec.update_mask.paths)
    end
end
