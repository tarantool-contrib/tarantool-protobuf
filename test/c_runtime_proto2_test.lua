-- Tests for proto2 — required, defaults, groups, extensions.
--
-- The proto2 semantics (required-missing on encode, presence-tracked
-- optionals, SGROUP/EGROUP framing, registered extensions) must match the
-- pure-Lua codec byte-for-byte. We exercise the same fixtures as
-- test/proto2_test.lua but route encode/decode through the C runtime, and
-- compare against the full-mode pure-Lua output for parity.

local t = require('luatest')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_proto2.' .. mode)
    local pb2
    local full

    g.before_all(function()
        skip_if_no_c()
        pb2  = require(mode .. '.proto2_basic.proto2_basic_pb')
        full = require('full.proto2_basic.proto2_basic_pb')
    end)

    g.before_each(skip_if_no_c)

    -- ---------- Required: error on missing, force-emit at zero ----------

    function g.test_required_missing_errors()
        local plan = c_runtime.compile_plan(pb2.Cardinality_descriptor)
        local ok, err = pcall(c_runtime.encode, plan, {})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'required field missing on encode')
        t.assert_str_contains(err, 'proto2_basic.Cardinality.r')
    end

    function g.test_required_zero_emitted_byte_equal()
        local plan = c_runtime.compile_plan(pb2.Cardinality_descriptor)
        local c_bytes = c_runtime.encode(plan, {r = 0})
        -- tag 1 / wire VARINT (0x08) + varint 0.
        t.assert_equals(hex(c_bytes), '0800')
        t.assert_equals(c_bytes, full.Cardinality_encode({r = 0}))
    end

    function g.test_required_set_round_trip()
        local plan = c_runtime.compile_plan(pb2.Cardinality_descriptor)
        local bytes = c_runtime.encode(plan, {r = 7})
        t.assert_equals(bytes, full.Cardinality_encode({r = 7}))
        local dec = c_runtime.decode(plan, bytes)
        t.assert_equals(dec.r, 7)
    end

    function g.test_nested_required_message_missing_errors()
        local plan = c_runtime.compile_plan(pb2.Nested_descriptor)
        local ok, err = pcall(c_runtime.encode, plan, {})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'proto2_basic.Nested.inner')
    end

    function g.test_nested_required_inner_required_errors()
        -- Outer .inner is present (table) but inner.x is missing.
        local plan = c_runtime.compile_plan(pb2.Nested_descriptor)
        local ok, err = pcall(c_runtime.encode, plan, {inner = {}})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'proto2_basic.Nested.Inner.x')
    end

    function g.test_nested_required_filled_round_trips_byte_equal()
        local plan = c_runtime.compile_plan(pb2.Nested_descriptor)
        local val = {inner = {x = 5}, inner_opt = {x = 9}}
        local c_bytes = c_runtime.encode(plan, val)
        t.assert_equals(c_bytes, full.Nested_encode(val))
        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.inner.x, 5)
        t.assert_equals(dec.inner_opt.x, 9)
    end

    -- ---------- Defaults: presence-tracked, not auto-emitted ----------

    function g.test_empty_message_round_trips_to_empty_bytes()
        local plan = c_runtime.compile_plan(pb2.Defaults_descriptor)
        local c_bytes = c_runtime.encode(plan, {})
        t.assert_equals(c_bytes, '', 'no defaults on the wire')
        t.assert_equals(c_runtime.decode(plan, c_bytes), {})
    end

    function g.test_set_to_proto_default_still_serializes()
        local plan = c_runtime.compile_plan(pb2.Defaults_descriptor)
        local c_bytes = c_runtime.encode(plan, {i = 17})
        t.assert_not_equals(c_bytes, '')
        t.assert_equals(c_bytes, full.Defaults_encode({i = 17}))
        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.i, 17)
    end

    function g.test_defaults_set_value_round_trip()
        local plan = c_runtime.compile_plan(pb2.Defaults_descriptor)
        local val = {i = 42, s = 'world', b = false, f = -1.5}
        local c_bytes = c_runtime.encode(plan, val)
        t.assert_equals(c_bytes, full.Defaults_encode(val))
        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.i, 42)
        t.assert_equals(dec.s, 'world')
        t.assert_equals(dec.b, false)
        t.assert_equals(dec.f, -1.5)
        -- Defaults are NOT auto-filled on decode for absent fields.
        t.assert_equals(dec.d, nil)
        t.assert_equals(dec.color, nil)
    end

    -- ---------- Groups: SGROUP/EGROUP framing ----------

    function g.test_group_singular_wire_bytes_byte_equal()
        local plan = c_runtime.compile_plan(pb2.WithGroup_descriptor)
        local val = {singlegroup = {a = 7, s = 'ok'}}
        local c_bytes = c_runtime.encode(plan, val)
        -- field 1 SGROUP (tag 0x0b), a=7 (0x10 0x07), s='ok' (0x1a 0x02 'ok'),
        -- EGROUP (tag 0x0c).
        t.assert_equals(hex(c_bytes),
            '0b' .. '10' .. '07' .. '1a' .. '02' .. '6f' .. '6b' .. '0c')
        t.assert_equals(c_bytes, full.WithGroup_encode(val))
    end

    function g.test_group_round_trip()
        local plan = c_runtime.compile_plan(pb2.WithGroup_descriptor)
        local val = {singlegroup = {a = 7, s = 'ok'}}
        local bytes = c_runtime.encode(plan, val)
        local dec = c_runtime.decode(plan, bytes)
        t.assert_equals(dec.singlegroup.a, 7)
        t.assert_equals(dec.singlegroup.s, 'ok')
    end

    function g.test_repeated_group_byte_equal()
        local plan = c_runtime.compile_plan(pb2.WithGroup_descriptor)
        local val = {repgroup = {{n = 1}, {n = 2}}}
        local c_bytes = c_runtime.encode(plan, val)
        -- Each rep wraps its own SGROUP(4)/EGROUP(4) bracket.
        t.assert_equals(hex(c_bytes),
            '23' .. '28' .. '01' .. '24' ..
            '23' .. '28' .. '02' .. '24')
        t.assert_equals(c_bytes, full.WithGroup_encode(val))

        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(#dec.repgroup, 2)
        t.assert_equals(dec.repgroup[1].n, 1)
        t.assert_equals(dec.repgroup[2].n, 2)
    end

    function g.test_group_decode_of_full_emit_bytes()
        -- Decode wire bytes produced by the pure-Lua encoder (which is the
        -- conformance reference). Catches any SGROUP/EGROUP framing skew.
        local plan = c_runtime.compile_plan(pb2.WithGroup_descriptor)
        local val = {
            singlegroup = {a = 11, s = 'wkt'},
            repgroup = {{n = 100}, {n = 200}, {n = 300}},
        }
        local bytes = full.WithGroup_encode(val)
        local dec = c_runtime.decode(plan, bytes)
        t.assert_equals(dec.singlegroup.a, 11)
        t.assert_equals(dec.singlegroup.s, 'wkt')
        t.assert_equals(dec.repgroup[1].n, 100)
        t.assert_equals(dec.repgroup[2].n, 200)
        t.assert_equals(dec.repgroup[3].n, 300)
    end

    -- ---------- Extensions: registered into extendee._extensions ----------

    function g.test_extension_round_trip_byte_equal()
        local plan = c_runtime.compile_plan(pb2.BenchPayload_descriptor)
        local msg = {
            id = 7,
            _extensions = {
                ['proto2_basic.ext_count'] = 42,
                ['proto2_basic.ext_label'] = 'tag',
            },
        }
        local c_bytes = c_runtime.encode(plan, msg)
        t.assert_equals(c_bytes, full.BenchPayload_encode(msg),
            'C encode of extensions must match full-mode byte-for-byte')
        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.id, 7)
        t.assert_equals(dec._extensions['proto2_basic.ext_count'], 42)
        t.assert_equals(dec._extensions['proto2_basic.ext_label'], 'tag')
    end

    function g.test_extension_absent_emits_nothing()
        local plan = c_runtime.compile_plan(pb2.BenchPayload_descriptor)
        local msg = {id = 1}
        local c_bytes = c_runtime.encode(plan, msg)
        t.assert_equals(c_bytes, full.BenchPayload_encode(msg))
        t.assert_equals(hex(c_bytes), '0801')
    end

    function g.test_extension_decode_from_full_emit_bytes()
        -- Wire bytes for a registered extension must land in _extensions,
        -- not in _unknown_fields, when the extension is registered on the
        -- descriptor at plan-compile time.
        local plan = c_runtime.compile_plan(pb2.BenchPayload_descriptor)
        local msg = {
            id = 9,
            _extensions = {['proto2_basic.ext_count'] = 17},
        }
        local bytes = full.BenchPayload_encode(msg)
        local dec = c_runtime.decode(plan, bytes)
        t.assert_equals(dec.id, 9)
        t.assert_equals(dec._extensions['proto2_basic.ext_count'], 17)
        t.assert_equals(dec._unknown_fields, nil,
            'registered extensions must not fall through to _unknown_fields')
    end

    -- ---------- BenchPayload: combined required + group + extensions ----------

    function g.test_benchpayload_full_round_trip_byte_equal()
        local plan = c_runtime.compile_plan(pb2.BenchPayload_descriptor)
        local val = {
            id = 1,
            name = 'x',
            retries = 5,
            lucky_numbers = {1, 2, 3},
            tags = {'a', 'b'},
            inner = {key = 'k', weight = 9},
            stats = {latency_ns = 1234, attempts = 2},
            _extensions = {
                ['proto2_basic.ext_count'] = 11,
                ['proto2_basic.ext_label'] = 'lbl',
            },
        }
        local c_bytes = c_runtime.encode(plan, val)
        t.assert_equals(c_bytes, full.BenchPayload_encode(val),
            'BenchPayload byte-equality with full mode')

        local dec = c_runtime.decode(plan, c_bytes)
        t.assert_equals(dec.id, 1)
        t.assert_equals(dec.name, 'x')
        t.assert_equals(dec.retries, 5)
        t.assert_equals(dec.lucky_numbers, {1, 2, 3})
        t.assert_equals(dec.tags, {'a', 'b'})
        t.assert_equals(dec.inner.key, 'k')
        t.assert_equals(dec.inner.weight, 9)
        t.assert_equals(dec.stats.latency_ns, 1234)
        t.assert_equals(dec.stats.attempts, 2)
        t.assert_equals(dec._extensions['proto2_basic.ext_count'], 11)
        t.assert_equals(dec._extensions['proto2_basic.ext_label'], 'lbl')
    end

    function g.test_benchpayload_required_missing_errors()
        local plan = c_runtime.compile_plan(pb2.BenchPayload_descriptor)
        local ok, err = pcall(c_runtime.encode, plan, {name = 'no_id'})
        t.assert_equals(ok, false)
        t.assert_str_contains(err, 'proto2_basic.BenchPayload.id')
    end
end
