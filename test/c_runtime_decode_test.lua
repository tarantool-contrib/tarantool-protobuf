-- C-side scalar decode.
--
-- Only runs when PB_ENABLE_C=1 is set in the environment AND the C
-- runtime module is loadable. Otherwise the group is skipped, mirroring
-- the gate on c_runtime_encode_test.lua.
--
-- Acceptance criteria:
--   Person decode round-trip works for the bytes produced by C-side
--   encode; the decoded table is shape-identical to pure-Lua decode for
--   the same input bytes (both codegen modes).

local t = require('luatest')
local ffi = require('ffi')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

-- mode=full is the byte-equal reference for both encode and decode.
local full_hello

for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_decode.' .. mode)
    local hello

    g.before_all(function()
        skip_if_no_c()
        hello = require(mode .. '.hello.hello_pb')
        full_hello = require('full.hello.hello_pb')
    end)

    g.before_each(skip_if_no_c)

    -- ---------- Acceptance ----------

    function g.test_acceptance_person_round_trip_from_3b_bytes()
        local msg = {
            name = 'x',
            age = 42,
            balance = -7,
            user_id = 0xDEADBEEFCAFEBABEULL,
            weight_kg = 3.14,
        }
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = c_runtime.encode(plan, msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        local lua_decoded = full_hello.Person_decode(bytes)
        t.assert_equals(c_decoded, lua_decoded,
            'C decode matches mode=full pure-Lua decode shape-for-shape')
    end

    -- ---------- Per-kind coverage ----------

    function g.test_empty_input_produces_empty_table()
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        t.assert_equals(c_runtime.decode(plan, ''), {})
    end

    function g.test_address_strings_and_int32()
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        local msg = {street = 'Main', city = 'Springfield', zip = 12345}
        local bytes = full_hello.Address_encode(msg)
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_hello.Address_decode(bytes))
    end

    function g.test_proto3_optional_empty_string_present()
        -- Address.apartment is proto3-optional; presence beats default.
        -- 3b emits the tag for apartment='' (optional bypasses suppression),
        -- so decode must surface the empty string in the result table.
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        local bytes = full_hello.Address_encode({apartment = ''})
        local lua_decoded = full_hello.Address_decode(bytes)
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded, lua_decoded)
        t.assert_equals(c_decoded.apartment, '')
    end

    function g.test_double_negative_zero_decodes()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- LuaJIT constant-folds the literal -0.0 to +0.0, so build the
        -- sign-bit-set zero at runtime via a cdata round-trip. Bytes
        -- encoded from this value must round-trip to a value whose 1/x
        -- is -inf — the only way to distinguish -0.0 from +0.0 in Lua.
        local neg_zero = ffi.new('double[1]', 0)[0] * -1
        local bytes = full_hello.Person_encode({weight_kg = neg_zero})
        t.assert(#bytes > 0, '-0.0 should not be zero-suppressed')
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(1 / c_decoded.weight_kg, -math.huge)
    end

    function g.test_enum_as_number_value()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = full_hello.Person_encode({status = 2})  -- ERROR
        local c_decoded = c_runtime.decode(plan, bytes)
        local lua_decoded = full_hello.Person_decode(bytes)
        t.assert_equals(c_decoded, lua_decoded)
        t.assert_equals(c_decoded.status, 2)
    end

    function g.test_fixed64_returns_uint64_cdata()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {user_id = ffi.new('uint64_t', 0x123456789ABCDEF0)}
        local bytes = full_hello.Person_encode(msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(type(c_decoded.user_id), 'cdata')
        t.assert_equals(c_decoded.user_id, msg.user_id)
    end

    function g.test_sint32_negative_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = full_hello.Person_encode({balance = -1})
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_hello.Person_decode(bytes))
        bytes = full_hello.Person_encode({balance = 0x7fffffff})
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_hello.Person_decode(bytes))
    end

    function g.test_bytes_field_preserves_high_bytes()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = full_hello.Person_encode({avatar = '\x00\x01\xff\xfe'})
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.avatar, '\x00\x01\xff\xfe')
    end

    -- ---------- Map decode ----------

    function g.test_map_string_to_int32_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {ages_by_nickname = {alice = 30, bob = 25, carol = 40}}
        local bytes = full_hello.Person_encode(msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.ages_by_nickname, msg.ages_by_nickname)
    end

    function g.test_map_int32_to_string_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {nickname_by_age = {[30] = 'alice', [25] = 'bob'}}
        local bytes = full_hello.Person_encode(msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.nickname_by_age, msg.nickname_by_age)
    end

    function g.test_map_string_to_message_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {addresses_by_label = {
            home = {street = 'Main', city = 'X', zip = 1},
            work = {street = '5th',  city = 'Y', zip = 2},
        }}
        local bytes = full_hello.Person_encode(msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.addresses_by_label.home.street, 'Main')
        t.assert_equals(c_decoded.addresses_by_label.home.zip, 1)
        t.assert_equals(c_decoded.addresses_by_label.work.street, '5th')
        t.assert_equals(c_decoded.addresses_by_label.work.city, 'Y')
    end

    function g.test_map_defaults_decode_as_proto3_zeros()
        -- mode=full encodes {[''] = 0} as a single-entry map with both
        -- key and value bytes elided. C decoder must surface the proto3
        -- defaults from the (otherwise empty) entry payload.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = full_hello.Person_encode({ages_by_nickname = {[''] = 0}})
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.ages_by_nickname[''], 0)
    end

    function g.test_map_skips_unknown_entry_ids()
        -- Synthetic Entry must tolerate unknown inner field ids (per the
        -- proto wire spec for map<,>). Hand-craft an entry payload with a
        -- spurious id=3 between key and value.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local entry = '\x0a\x05alice'   -- tag(1, LEN) + len(5) + "alice"
                   .. '\x18\x07'         -- tag(3, VARINT) + value 7 (spurious)
                   .. '\x10\x1e'         -- tag(2, VARINT) + 30
        local bytes = '\x6a'             -- tag(13, LEN): outer map field
                   .. string.char(#entry)
                   .. entry
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.ages_by_nickname.alice, 30)
    end

    function g.test_map_mixed_with_other_fields()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local rich = {
            name = 'x',
            emails = {'a@b'},
            address = {street = 'Main'},
            lucky_numbers = {1, 2, 3},
            ages_by_nickname = {alice = 30, bob = 25},
        }
        local bytes = full_hello.Person_encode(rich)
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.name, 'x')
        t.assert_equals(c_decoded.emails, {'a@b'})
        t.assert_equals(c_decoded.address.street, 'Main')
        t.assert_equals(c_decoded.lucky_numbers, {1, 2, 3})
        t.assert_equals(c_decoded.ages_by_nickname, rich.ages_by_nickname)
    end

    -- ---------- Sub-message decode ----------

    function g.test_singular_submessage_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {
            name = 'x',
            address = {street = 'Main', city = 'Springfield', zip = 100},
        }
        local bytes = full_hello.Person_encode(msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        local lua_decoded = full_hello.Person_decode(bytes)
        t.assert_equals(c_decoded, lua_decoded)
        t.assert_equals(c_decoded.address.zip, 100)
    end

    function g.test_empty_submessage_decodes_to_empty_table()
        -- The Lua codec emits tag + length(0) for an empty sub-message
        -- table; the C decoder must surface it as {} (not nil).
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = full_hello.Person_encode({address = {}})
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(type(c_decoded.address), 'table')
        t.assert_equals(c_decoded.address, {})
    end

    function g.test_submessage_with_proto3_optional()
        -- Address.apartment='' must survive the round trip.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local bytes = full_hello.Person_encode({address = {apartment = ''}})
        local c_decoded = c_runtime.decode(plan, bytes)
        t.assert_equals(c_decoded.address.apartment, '')
    end

    function g.test_nested_5_levels()
        local cn = require(mode .. '.c_nested.c_nested_pb')
        local full_cn = require('full.c_nested.c_nested_pb')
        local msg = {
            v = 1,
            next = {v = 2, next = {v = 3, next = {v = 4,
                next = {v = 5}}}},
        }
        local plan = c_runtime.compile_plan(cn.L1_descriptor)
        local bytes = full_cn.L1_encode(msg)
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_cn.L1_decode(bytes))
    end

    function g.test_truncated_submessage_errors()
        -- Tag for address (field 5, wire 2 = 0x2a), length-prefix=10,
        -- but actual body shorter than advertised.
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_error_msg_contains('truncated', function()
            c_runtime.decode(plan, '\x2a\x0a\x0a\x03')
        end)
    end

    function g.test_skips_unknown_field_tags()
        -- Append a synthetic unknown-field tag (id=999, wire varint=0)
        -- to a valid encoding. The decoder captures the raw bytes into
        -- _unknown_fields rather than dropping them; the known field
        -- stays parsed. Full coverage of the round-trip semantics lives
        -- in test/c_runtime_unknown_test.lua.
        local good = full_hello.Person_encode({name = 'x'})
        -- field 999, wire 0 => tag varint = (999<<3) | 0 = 7992 => 0xF8 0x3E
        local unknown_tag = '\xf8\x3e\x05'   -- tag + varint value 5
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local c_decoded = c_runtime.decode(plan, good .. unknown_tag)
        t.assert_equals(c_decoded,
            {name = 'x', _unknown_fields = unknown_tag})
    end

    function g.test_wkt_override_passthrough()
        -- has_override plans dispatch to desc.decode(buf).
        local plan = c_runtime.compile_plan(pb.wkt.Timestamp_descriptor)
        local bytes = pb.wkt.Timestamp_encode({seconds = 1700000000, nanos = 42})
        t.assert_equals(c_runtime.decode(plan, bytes),
                        pb.wkt.Timestamp_decode(bytes))
    end

    function g.test_truncated_input_errors()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- Tag for field 1 (string) followed by length-prefix without the
        -- string bytes that the length claims.
        t.assert_error_msg_contains('truncated', function()
            c_runtime.decode(plan, '\x0a\x05ab')
        end)
    end

    -- ---------- Repeated + packed decode ----------

    function g.test_acceptance_lucky_numbers_packed_int32_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {lucky_numbers = {1, 2, 3, 4, 5, -1, 0x7fffffff}}
        local bytes = full_hello.Person_encode(msg)
        local c_decoded = c_runtime.decode(plan, bytes)
        local lua_decoded = full_hello.Person_decode(bytes)
        t.assert_equals(c_decoded, lua_decoded)
        t.assert_equals(c_decoded.lucky_numbers, {1, 2, 3, 4, 5, -1, 0x7fffffff})
    end

    function g.test_repeated_string_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {emails = {'a@b', 'c@d', '', 'last'}}
        local bytes = full_hello.Person_encode(msg)
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_hello.Person_decode(bytes))
    end

    function g.test_repeated_message_self_reference_round_trip()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local msg = {
            name = 'root',
            friends = {
                {name = 'alice', age = 30},
                {name = 'bob', friends = {{name = 'carol'}}},
                {},
            },
        }
        local bytes = full_hello.Person_encode(msg)
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_hello.Person_decode(bytes))
    end

    function g.test_packed_payload_accepted_for_unpacked_schema()
        -- Wire-format invariant: proto3 decoders accept a packed payload
        -- for ANY packable scalar, regardless of the schema's packed flag.
        -- Build a synthetic packed payload for Holder.unpacked_int32 and
        -- confirm the C decoder concatenates its elements correctly.
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local wire = require('pb.wire')
        -- field 20, wire LEN: tag = (20<<3)|2 = 162 = 0xA2 0x01
        local payload = wire.encode_varint(1) .. wire.encode_varint(2)
                     .. wire.encode_varint(3)
        local bytes = '\xa2\x01' .. wire.encode_varint(#payload) .. payload
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        local c_decoded = c_runtime.decode(plan, bytes)
        local lua_decoded = full_cr.Holder_decode(bytes)
        t.assert_equals(c_decoded, lua_decoded)
        t.assert_equals(c_decoded.unpacked_int32, {1, 2, 3})
    end

    function g.test_unpacked_payload_accepted_for_packed_schema()
        -- Symmetric: a per-element-tagged stream for Holder.packed_int32
        -- must also concatenate. Build it by hand.
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local wire = require('pb.wire')
        -- field 1, wire VARINT: tag = (1<<3)|0 = 8 = 0x08
        local elem = function(v)
            return '\x08' .. wire.encode_varint(v)
        end
        local bytes = elem(7) .. elem(8) .. elem(9)
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        local c_decoded = c_runtime.decode(plan, bytes)
        local lua_decoded = full_cr.Holder_decode(bytes)
        t.assert_equals(c_decoded, lua_decoded)
        t.assert_equals(c_decoded.packed_int32, {7, 8, 9})
    end

    local function counts() return {10, 100, 1000} end

    function g.test_fixture_packed_int32_round_trip_at_counts()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        for _, n in ipairs(counts()) do
            local arr = {}
            for i = 1, n do arr[i] = i end
            local bytes = full_cr.Holder_encode({packed_int32 = arr})
            t.assert_equals(c_runtime.decode(plan, bytes),
                            full_cr.Holder_decode(bytes),
                            ('packed_int32 n=%d'):format(n))
        end
    end

    function g.test_fixture_unpacked_scalars_round_trip_at_counts()
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
            local bytes = full_cr.Holder_encode({
                unpacked_int32 = i32,
                unpacked_sint32 = sx,
                unpacked_fixed64 = fx,
            })
            t.assert_equals(c_runtime.decode(plan, bytes),
                            full_cr.Holder_decode(bytes),
                            ('unpacked scalars n=%d'):format(n))
        end
    end

    function g.test_fixture_repeated_messages_round_trip_at_counts()
        local cr = require(mode .. '.c_repeated.c_repeated_pb')
        local full_cr = require('full.c_repeated.c_repeated_pb')
        local plan = c_runtime.compile_plan(cr.Holder_descriptor)
        for _, n in ipairs(counts()) do
            local arr = {}
            for i = 1, n do arr[i] = {v = i, s = 'name' .. i} end
            local bytes = full_cr.Holder_encode({messages = arr})
            t.assert_equals(c_runtime.decode(plan, bytes),
                            full_cr.Holder_decode(bytes),
                            ('messages n=%d'):format(n))
        end
    end

    -- ---------- Acceptance ----------
    --
    -- Decode-side mirror of c_runtime_encode_test's acceptance: the
    -- cached-stack-idx repeated dispatch (decode_body's per-field
    -- list_stack_idx[]) must round-trip Person.emails and Person.
    -- friends byte-equal to mode=full at 1KB, 10KB, 100KB. This
    -- exercises the lazy-create + cached-idx + lua_rawseti loop at
    -- counts where the spike measured naive lazy-getfield at 2x
    -- slower.

    function g.test_acceptance_repeated_strings_round_trip_at_sizes()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        for _, c in ipairs({{n=50}, {n=500}, {n=5000}}) do
            local emails = {}
            for i = 1, c.n do
                emails[i] = string.rep('e', 16)
                          .. string.format('%02d', i % 100)
            end
            local bytes = full_hello.Person_encode({emails = emails})
            t.assert_equals(c_runtime.decode(plan, bytes),
                            full_hello.Person_decode(bytes),
                            ('emails round-trip n=%d'):format(c.n))
        end
    end

    function g.test_acceptance_repeated_messages_round_trip_at_sizes()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        local pad = 'xxxxxxx'
        for _, c in ipairs({{n=56}, {n=560}, {n=5600}}) do
            local friends = {}
            for i = 1, c.n do
                friends[i] = {
                    name = pad .. string.format('f%04d', i),
                    age = i,
                }
            end
            local bytes = full_hello.Person_encode({friends = friends})
            t.assert_equals(c_runtime.decode(plan, bytes),
                            full_hello.Person_decode(bytes),
                            ('friends round-trip n=%d'):format(c.n))
        end
    end

    function g.test_fixture_mixed_round_trip()
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
        local bytes = full_cr.Holder_encode({
            packed_int32 = p,
            unpacked_int32 = u,
            strings = s,
            messages = m,
        })
        t.assert_equals(c_runtime.decode(plan, bytes),
                        full_cr.Holder_decode(bytes))
    end
end
