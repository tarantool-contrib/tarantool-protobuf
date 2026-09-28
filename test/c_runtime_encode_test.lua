-- C-side scalar encode.
--
-- Only runs when PB_ENABLE_C=1 is set in the environment AND the C
-- runtime module is loadable. Otherwise the group is skipped, which
-- keeps `just test` green on hosts without the C module built.
--
-- Acceptance criteria:
--   Person encode for {name='x', age=42, balance=-7, user_id=...,
--   weight_kg=3.14} byte-equal to mode=full pure-Lua output.

local t = require('luatest')
local ffi = require('ffi')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

-- The mode=full reference is the byte-equality target; the test runs
-- against both codegen modes' descriptors (the C plan is mode-agnostic).
local full_hello

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_encode.' .. mode)
    local hello

    g.before_all(function()
        skip_if_no_c()
        hello = require(mode .. '.hello.hello_pb')
        full_hello = require('full.hello.hello_pb')
    end)

    g.before_each(skip_if_no_c)

    -- ---------- Acceptance ----------

    function g.test_acceptance_person_scalar_subset()
        local msg = {
            name = 'x',
            age = 42,
            balance = -7,
            user_id = 0xDEADBEEFCAFEBABEULL,
            weight_kg = 3.14,
        }
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local c_bytes = c_runtime.encode(plan, msg)
        local lua_bytes = full_hello.Person_encode(msg)
        t.assert_equals(c_bytes, lua_bytes,
            'C encode matches mode=full pure-Lua encode byte-for-byte')
    end

    -- ---------- Per-kind coverage ----------

    function g.test_empty_message_produces_empty_string()
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        t.assert_equals(c_runtime.encode(plan, {}), '')
    end

    function g.test_address_strings_and_int32()
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        local msg = {street = 'Main', city = 'Springfield', zip = 12345}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Address_encode(msg))
    end

    function g.test_proto3_optional_emits_empty_string()
        -- Address.apartment is proto3-optional; presence beats default.
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        local msg = {apartment = ''}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Address_encode(msg))
    end

    function g.test_double_negative_zero_emits()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- +0.0 -> skip; -0.0 -> emit (sign bit preserved by wire spec).
        local m_pos = {weight_kg = 0.0}
        local m_neg = {weight_kg = -0.0}
        t.assert_equals(c_runtime.encode(plan, m_pos),
                        full_hello.Person_encode(m_pos))
        t.assert_equals(c_runtime.encode(plan, m_neg),
                        full_hello.Person_encode(m_neg))
    end

    function g.test_enum_as_number()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {status = 2}  -- ERROR
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_enum_as_string_lookup()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {status = 'OK'}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_enum_zero_value_suppressed()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {status = 'UNKNOWN'}  -- = 0; default-suppressed
        t.assert_equals(c_runtime.encode(plan, msg), '')
    end

    function g.test_enum_unknown_string_errors()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_error_msg_contains("unknown enum value 'NOPE'", function()
            c_runtime.encode(plan, {status = 'NOPE'})
        end)
    end

    function g.test_fixed64_cdata_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {user_id = ffi.new('uint64_t', 0x123456789ABCDEF0)}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_sint32_negative_and_zero()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_equals(c_runtime.encode(plan, {balance = 0}), '')
        t.assert_equals(
            c_runtime.encode(plan, {balance = -1}),
            full_hello.Person_encode({balance = -1}))
        t.assert_equals(
            c_runtime.encode(plan, {balance = 0x7fffffff}),
            full_hello.Person_encode({balance = 0x7fffffff}))
    end

    function g.test_int32_zero_suppressed()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_equals(c_runtime.encode(plan, {age = 0}), '')
    end

    function g.test_bytes_field()
        -- Person.avatar is bytes @8
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {avatar = '\x00\x01\xff\xfe'}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    -- ---------- Map encode ----------

    function g.test_map_string_to_int32_single_key()
        -- Single-key fixtures lock down byte-for-byte equality. Multi-key
        -- map encode order is hash-determined per Lua's pairs() and won't
        -- match mode=full's pairs() order in general, so we exercise
        -- multi-key behavior via round-trip below.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {ages_by_nickname = {alice = 30}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_map_int32_to_string_single_key()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {nickname_by_age = {[30] = 'alice'}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_map_string_to_message_single_key()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {addresses_by_label = {
            home = {street = 'Main', city = 'X', zip = 1},
        }}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_map_empty_emits_nothing()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_equals(c_runtime.encode(plan, {ages_by_nickname = {}}), '')
    end

    function g.test_map_default_key_and_value_round_trip()
        -- Empty-string key + zero value: per proto3 wire spec both bytes
        -- are elided but the entry itself is still emitted (presence of
        -- the key/value pair is meaningful even when both default).
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {ages_by_nickname = {[''] = 0}}
        local c_bytes = c_runtime.encode(plan, msg)
        t.assert_equals(c_bytes, full_hello.Person_encode(msg))
        local dec = full_hello.Person_decode(c_bytes)
        t.assert_equals(dec.ages_by_nickname[''], 0)
    end

    function g.test_map_multi_key_round_trip()
        -- Multi-key encode byte order is hash-determined; we only assert
        -- that mode=full can decode our bytes back to the same table.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {ages_by_nickname = {alice = 30, bob = 25, carol = 40}}
        local dec = full_hello.Person_decode(c_runtime.encode(plan, msg))
        t.assert_equals(dec.ages_by_nickname, msg.ages_by_nickname)
    end

    function g.test_map_message_value_with_other_fields()
        -- Ensure map<,message> sub-plan resolution doesn't disturb the
        -- enclosing message's field-walk.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {
            name = 'x',
            addresses_by_label = {home = {street = 'Main', zip = 7}},
            emails = {'a@b'},
        }
        local dec = full_hello.Person_decode(c_runtime.encode(plan, msg))
        t.assert_equals(dec.name, 'x')
        t.assert_equals(dec.emails, {'a@b'})
        t.assert_equals(dec.addresses_by_label.home.street, 'Main')
        t.assert_equals(dec.addresses_by_label.home.zip, 7)
    end

    -- ---------- Sub-message encode ----------

    function g.test_singular_submessage_round_trip()
        -- Person.address (one-level singular sub-message) round-trip.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {
            name = 'x',
            address = {street = 'Main', city = 'Springfield', zip = 100},
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_empty_submessage_emits_tag_with_zero_length()
        -- Singular sub-message with an empty table — proto3 presence
        -- semantics require emitting tag + length(0). The Lua codec
        -- does this; the C codec must match.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {name = 'x', address = {}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_submessage_with_proto3_optional_field()
        -- Address.apartment is proto3-optional. Encode through the
        -- sub-message must surface the empty string just like the
        -- top-level Address codec does.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {address = {apartment = ''}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_submessage_non_table_value_errors()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_error_msg_contains('table', function()
            c_runtime.encode(plan, {address = 'not a table'})
        end)
    end

    function g.test_nested_5_levels()
        -- 5-level chain of singular sub-messages. Exercises the
        -- recursion depth and the cycle-breaking c_plan stash.
        local cn = require(mode .. '.c_nested.c_nested_pb')
        local full_cn = require('full.c_nested.c_nested_pb')
        local msg = {
            v = 1,
            next = {v = 2, next = {v = 3, next = {v = 4,
                next = {v = 5}}}},
        }
        local plan = c_runtime.compile_plan(cn.L1_descriptor)
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_cn.L1_encode(msg))
    end

    function g.test_large_submessage_triggers_parent_grow()
        -- Parent buffer starts at 4KB stack-backed; force a parent
        -- regrow path during the post-recursion ebuf_reserve by
        -- packing a >4KB string into the sub-message.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {
            name = 'x',
            address = {street = string.rep('s', 8192)},
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_long_string_grows_buffer()
        -- Stack buffer is 4KB; force the heap-promotion path with a
        -- string that pushes past it.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {name = string.rep('a', 8192)}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_wkt_override_passthrough()
        -- has_override plans dispatch to desc.encode(value) and return
        -- its bytes verbatim.
        local plan = c_runtime.compile_plan(pb.wkt.Timestamp_descriptor)
        local v = {seconds = 1, nanos = 2}
        t.assert_equals(c_runtime.encode(plan, v),
                        pb.wkt.Timestamp_encode(v))
    end

    -- ---------- Repeated + packed ----------

    -- Acceptance: Person.lucky_numbers (packed int32) round-trips
    -- byte-equal, and a fixture mixing packed + unpacked at 10/100/1000
    -- elements matches mode=full byte-for-byte.

    function g.test_acceptance_lucky_numbers_packed_int32()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {lucky_numbers = {1, 2, 3, 4, 5, -1, 0x7fffffff}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_repeated_empty_array_omits_field()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- Empty repeated must be wire-equivalent to absent.
        t.assert_equals(c_runtime.encode(plan, {lucky_numbers = {}}), '')
        t.assert_equals(c_runtime.encode(plan, {emails = {}}), '')
    end

    function g.test_repeated_emits_zero_elements_no_suppression()
        -- Unlike singular scalars, repeated elements are NOT zero-
        -- suppressed — every element reaches the wire.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {lucky_numbers = {0, 0, 0}}
        local bytes = c_runtime.encode(plan, msg)
        t.assert_equals(bytes, full_hello.Person_encode(msg))
        t.assert(#bytes > 0, 'zero elements still emit')
    end

    function g.test_repeated_string_per_element_tag()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {emails = {'a@b', 'c@d', '', 'long' .. string.rep('x', 200)}}
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_repeated_message_self_reference()
        -- Person.friends is `repeated Person` — a self-referencing
        -- sub-message exercising recursive plan dispatch via the
        -- c_plan stash for cycle-breaking.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {
            name = 'root',
            friends = {
                {name = 'alice', age = 30},
                {name = 'bob', friends = {{name = 'carol'}}},
                {},  -- empty friend → tag + len(0) per proto3 presence
            },
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_hello.Person_encode(msg))
    end

    function g.test_repeated_non_table_value_errors()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_error_msg_contains('repeated', function()
            c_runtime.encode(plan, {lucky_numbers = 'not an array'})
        end)
    end

    -- ---------- c_repeated fixture: every dispatch branch ----------

    local function counts() return {10, 100, 1000} end

    function g.test_fixture_packed_int32_at_counts()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        for _, n in ipairs(counts()) do
            local arr = {}
            for i = 1, n do arr[i] = i end
            local msg = {packed_int32 = arr}
            t.assert_equals(c_runtime.encode(plan, msg),
                            full_cr.Holder_encode(msg),
                            ('packed_int32 n=%d'):format(n))
        end
    end

    function g.test_fixture_packed_all_numeric_kinds()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        local msg = {
            packed_int32   = {1, -1, 0x7fffffff},
            packed_int64   = {ffi.new('int64_t', 1), ffi.new('int64_t', -1)},
            packed_sint32  = {-3, 0, 3},
            packed_uint32  = {7, 8, 9},
            packed_fixed32 = {100, 200},
            packed_fixed64 = {ffi.new('uint64_t', 0x1234567890ABCDEFULL)},
            packed_double  = {1.5, -2.25, 0},
            packed_float   = {0.5, -0.25},
            packed_bool    = {true, false, true, true, false},
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_cr.Holder_encode(msg))
    end

    function g.test_fixture_unpacked_scalars_at_counts()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        for _, n in ipairs(counts()) do
            local i32, sx, fx = {}, {}, {}
            for i = 1, n do
                i32[i] = i
                sx[i] = -i
                fx[i] = ffi.new('uint64_t', i)
            end
            local msg = {
                unpacked_int32 = i32,
                unpacked_sint32 = sx,
                unpacked_fixed64 = fx,
            }
            t.assert_equals(c_runtime.encode(plan, msg),
                            full_cr.Holder_encode(msg),
                            ('unpacked scalars n=%d'):format(n))
        end
    end

    function g.test_fixture_repeated_strings_and_bytes()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        for _, n in ipairs(counts()) do
            local s, b = {}, {}
            for i = 1, n do
                s[i] = 'str' .. tostring(i)
                b[i] = string.char(i % 256) .. '\0\xff'
            end
            local msg = {strings = s, blobs = b}
            t.assert_equals(c_runtime.encode(plan, msg),
                            full_cr.Holder_encode(msg),
                            ('strings/blobs n=%d'):format(n))
        end
    end

    function g.test_fixture_repeated_messages_at_counts()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        for _, n in ipairs(counts()) do
            local arr = {}
            for i = 1, n do arr[i] = {v = i, s = 'name' .. i} end
            local msg = {messages = arr}
            t.assert_equals(c_runtime.encode(plan, msg),
                            full_cr.Holder_encode(msg),
                            ('messages n=%d'):format(n))
        end
    end

    -- ---------- Acceptance ----------
    --
    -- Person.emails (repeated string) and Person.friends (repeated
    -- Person, self-reference) round-trip byte-equal to mode=full at
    -- 1KB, 10KB, 100KB wire sizes. encode_repeated_field handles
    -- MESSAGE + string/bytes branches alongside the scalars; this
    -- acceptance pins it under the cached-stack-idx pattern at scale.
    --
    -- Sizing chosen to hit the named targets without per-test math
    -- in the loop:
    --   emails  @  50 elements ≈   1KB,  ≈ 10KB,  ≈ 100KB
    --   friends @  60 elements ≈   1KB,  ≈ 10KB,  ≈ 100KB
    --
    -- Bytes are checked at runtime against the named target band so
    -- a future schema or encoding shift surfaces as a test failure
    -- rather than silently moving off-target.

    local function size_band(actual, target)
        -- Accept anything within 30% of the named size — generous
        -- enough to survive small wire-format shifts, tight enough
        -- to flag a regression to the wrong order of magnitude.
        return actual >= target * 0.7 and actual <= target * 1.3
    end

    function g.test_acceptance_repeated_strings_at_size_targets()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local cases = {
            {label = '1KB',   n =   50, elem_len = 18, target = 1024},
            {label = '10KB',  n =  500, elem_len = 18, target = 10240},
            {label = '100KB', n = 5000, elem_len = 18, target = 102400},
        }
        for _, c in ipairs(cases) do
            local emails = {}
            for i = 1, c.n do
                emails[i] = string.rep('e', c.elem_len - 2)
                          .. string.format('%02d', i % 100)
            end
            local msg = {emails = emails}
            local c_bytes = c_runtime.encode(plan, msg)
            local lua_bytes = full_hello.Person_encode(msg)
            t.assert_equals(c_bytes, lua_bytes,
                ('emails %s byte-equal'):format(c.label))
            t.assert(size_band(#c_bytes, c.target),
                ('emails %s actual=%dB target=%dB'):format(
                    c.label, #c_bytes, c.target))
        end
    end

    function g.test_acceptance_repeated_messages_self_ref_at_size_targets()
        -- Friend payload shape: {name = '<12-char>', age = N}. Each
        -- emitted friend is around 18 bytes: parent tag (1) + body
        -- length varint (1) + inner name tag (1) + name len (1) +
        -- 12 chars + age tag (1) + age varint (1-2). 56 → ~1KB,
        -- 560 → ~10KB, 5600 → ~100KB.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local cases = {
            {label = '1KB',   n =   56, target = 1024},
            {label = '10KB',  n =  560, target = 10240},
            {label = '100KB', n = 5600, target = 102400},
        }
        local pad = 'xxxxxxx'  -- 7 chars; combined with 'fNNNN' → 12
        for _, c in ipairs(cases) do
            local friends = {}
            for i = 1, c.n do
                friends[i] = {
                    name = pad .. string.format('f%04d', i),
                    age = i,
                }
            end
            local msg = {friends = friends}
            local c_bytes = c_runtime.encode(plan, msg)
            local lua_bytes = full_hello.Person_encode(msg)
            t.assert_equals(c_bytes, lua_bytes,
                ('friends %s byte-equal'):format(c.label))
            t.assert(size_band(#c_bytes, c.target),
                ('friends %s actual=%dB target=%dB'):format(
                    c.label, #c_bytes, c.target))
        end
    end

    function g.test_fixture_mixed_packed_and_unpacked()
        -- All branches simultaneously: packed + unpacked + string/bytes
        -- + message, on the same message instance.
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        local p, u, s, m = {}, {}, {}, {}
        for i = 1, 100 do
            p[i] = i
            u[i] = -i
            s[i] = 'k' .. i
            m[i] = {v = i, s = 's' .. i}
        end
        local msg = {
            packed_int32 = p,
            unpacked_int32 = u,
            strings = s,
            messages = m,
        }
        t.assert_equals(c_runtime.encode(plan, msg),
                        full_cr.Holder_encode(msg))
    end
end
