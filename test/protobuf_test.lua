-- Round-trip + parity tests for both codegen modes.
-- Run via `make test` (which sets LUA_PATH and invokes .rocks/bin/luatest).
local t = require('luatest')
local ffi = require('ffi')

local function eq_uint64(a, b)
    return ffi.cast('uint64_t', a) == ffi.cast('uint64_t', b)
end

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- One luatest group per mode, each running the same suite.
-- ---------------------------------------------------------------------------

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g = t.group('hello.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    g.test_empty_address_round_trips_to_empty = function()
        local enc = hello.Address_encode({})
        t.assert_equals(#enc, 0, 'proto3 default-elision: empty message -> 0 bytes')
        t.assert_equals(hello.Address_decode(enc), {})
    end

    g.test_address_scalars = function()
        local addr = {street = 'Pushkina 1', city = 'Moscow', zip = 123456}
        local dec = hello.Address_decode(hello.Address_encode(addr))
        t.assert_equals(dec.street, addr.street)
        t.assert_equals(dec.city, addr.city)
        t.assert_equals(dec.zip, addr.zip)
    end

    g.test_person_basic_round_trip = function()
        local p = {
            name    = 'Alice',
            age     = 30,
            emails  = {'a@example.com', 'b@example.com'},
            status  = hello.Status.OK,
            address = {street = 'Main St', city = 'Springfield', zip = 100},
        }
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(dec.name, 'Alice')
        t.assert_equals(dec.age, 30)
        t.assert_equals(#dec.emails, 2)
        t.assert_equals(dec.emails[1], 'a@example.com')
        t.assert_equals(dec.emails[2], 'b@example.com')
        t.assert_equals(dec.status, hello.Status.OK)
        t.assert_equals(dec.address.street, 'Main St')
        t.assert_equals(dec.address.zip, 100)
    end

    g.test_self_reference_repeated_message = function()
        local p = {
            name = 'Root',
            friends = {
                {name = 'Alice', age = 25},
                {name = 'Bob',   age = 31, friends = {{name = 'Carol'}}},
            },
        }
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(#dec.friends, 2)
        t.assert_equals(dec.friends[1].name, 'Alice')
        t.assert_equals(dec.friends[2].name, 'Bob')
        t.assert_equals(dec.friends[2].friends[1].name, 'Carol')
    end

    g.test_packed_repeated_int32 = function()
        local p = {lucky_numbers = {1, 2, 3, -7, 4, 1024}}
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(#dec.lucky_numbers, 6)
        t.assert_equals(dec.lucky_numbers[4], -7)
        t.assert_equals(dec.lucky_numbers[6], 1024)
    end

    g.test_bytes_sint32_fixed64_double = function()
        local p = {
            avatar    = '\x00\x01\x02\xff',
            balance   = -12345,
            user_id   = ffi.cast('uint64_t', 0xfeedface00000001ULL),
            weight_kg = 72.5,
        }
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(dec.avatar, p.avatar)
        t.assert_equals(dec.balance, -12345)
        t.assert(eq_uint64(dec.user_id, p.user_id), 'fixed64 round-trips losslessly')
        t.assert_almost_equals(dec.weight_kg, 72.5, 1e-9)
    end

    g.test_known_good_wire_bytes_alice30 = function()
        -- Byte-for-byte conformance with mainline protoc.
        --   field 1 (string, LEN): tag 0x0a, len 5, "Alice" = 41 6c 69 63 65
        --   field 2 (int32, VARINT): tag 0x10, value 30 = 0x1e
        local enc = hello.Person_encode({name = 'Alice', age = 30})
        t.assert_equals(hex(enc), '0a05416c696365101e')
    end

    g.test_enum_string_input_resolved_to_int = function()
        local p = hello.Person_decode(hello.Person_encode({name = 'X', status = 'ERROR'}))
        t.assert_equals(p.status, hello.Status.ERROR)
    end

    g.test_enum_unknown_string_errors = function()
        t.assert_error(function() hello.Person_encode({status = 'NOT_A_VALUE'}) end)
    end

    g.test_proto3_default_value_elision = function()
        t.assert_equals(#hello.Person_encode({age = 0}), 0)
        t.assert_equals(#hello.Person_encode({name = ''}), 0)
        t.assert_equals(#hello.Person_encode({status = hello.Status.UNKNOWN}), 0)
        t.assert_equals(#hello.Person_encode({weight_kg = 0.0}), 0)
        t.assert_equals(#hello.Person_encode({avatar = ''}), 0)
    end

    g.test_unknown_field_is_skipped = function()
        -- Manually craft bytes with an unknown field 12 (VARINT, single-byte tag),
        -- then a known field 1 (name = "hi"). Decoder must skip the unknown.
        local raw = string.char(12 * 8 + 0) .. '\x05'  -- field 12 varint = 5
                  .. '\x0a\x02hi'                       -- field 1 LEN = "hi"
        local dec = hello.Person_decode(raw)
        t.assert_equals(dec.name, 'hi')
    end

    g.test_empty_repeated_field_omitted = function()
        -- An empty Lua array shouldn't emit a packed empty payload.
        t.assert_equals(#hello.Person_encode({lucky_numbers = {}}), 0)
    end

    g.test_map_string_to_int32 = function()
        local p = {ages_by_nickname = {alice = 30, bob = 25}}
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(dec.ages_by_nickname.alice, 30)
        t.assert_equals(dec.ages_by_nickname.bob, 25)
    end

    g.test_map_int32_to_string = function()
        local p = {nickname_by_age = {[30] = 'alice', [25] = 'bob'}}
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(dec.nickname_by_age[30], 'alice')
        t.assert_equals(dec.nickname_by_age[25], 'bob')
    end

    g.test_map_string_to_message = function()
        local p = {addresses_by_label = {
            home = {street = 'Main', city = 'X', zip = 1},
            work = {street = '5th',  city = 'Y', zip = 2},
        }}
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(dec.addresses_by_label.home.street, 'Main')
        t.assert_equals(dec.addresses_by_label.home.zip, 1)
        t.assert_equals(dec.addresses_by_label.work.street, '5th')
        t.assert_equals(dec.addresses_by_label.work.zip, 2)
    end

    g.test_map_empty_is_elided = function()
        t.assert_equals(#hello.Person_encode({ages_by_nickname = {}}), 0)
    end

    g.test_map_defaults_round_trip = function()
        -- Empty string key + zero value should survive the round trip.
        local p = {ages_by_nickname = {[''] = 0}}
        local dec = hello.Person_decode(hello.Person_encode(p))
        t.assert_equals(dec.ages_by_nickname[''], 0)
    end

    g.test_wkt_timestamp_round_trip = function()
        local datetime = require('datetime')
        local dt = datetime.new({timestamp = 1700000000, nsec = 123456789})
        local e = {title = 'hi', created_at = dt}
        local dec = hello.Event_decode(hello.Event_encode(e))
        t.assert_equals(dec.title, 'hi')
        t.assert(datetime.is_datetime(dec.created_at))
        t.assert_equals(dec.created_at.epoch, 1700000000)
        t.assert_equals(dec.created_at.nsec, 123456789)
    end

    g.test_wkt_timestamp_table_input = function()
        local datetime = require('datetime')
        local dec = hello.Event_decode(hello.Event_encode({
            created_at = {seconds = 42, nanos = 500},
        }))
        t.assert(datetime.is_datetime(dec.created_at))
        t.assert_equals(dec.created_at.epoch, 42)
        t.assert_equals(dec.created_at.nsec, 500)
    end

    g.test_wkt_duration = function()
        local dec = hello.Event_decode(hello.Event_encode({
            duration = {seconds = 7200, nanos = 0},
        }))
        t.assert_equals(tonumber(dec.duration.seconds), 7200)
        t.assert_equals(dec.duration.nanos, 0)
    end

    g.test_wkt_empty = function()
        local dec = hello.Event_decode(hello.Event_encode({ack = {}}))
        t.assert_equals(type(dec.ack), 'table')
        t.assert_equals(next(dec.ack), nil)
    end

    g.test_wkt_int32value_wrapper = function()
        -- Wrapper auto-wraps: user passes the unwrapped value, no nesting.
        local dec = hello.Event_decode(hello.Event_encode({retry_count = 5}))
        t.assert_equals(dec.retry_count, 5)

        -- nil means "not set" — wrapper field omitted entirely.
        local dec_nil = hello.Event_decode(hello.Event_encode({}))
        t.assert_equals(dec_nil.retry_count, nil)

        -- Zero is the point of wrappers — presence preserved even at default.
        local dec0 = hello.Event_decode(hello.Event_encode({retry_count = 0}))
        t.assert_equals(dec0.retry_count, 0,
            'zero round-trips through a wrapper (presence is meaningful)')
    end

    g.test_wkt_stringvalue_wrapper = function()
        local dec = hello.Event_decode(hello.Event_encode({note = 'remember'}))
        t.assert_equals(dec.note, 'remember')
    end

    g.test_wkt_boolvalue_wrapper = function()
        local dec = hello.Event_decode(hello.Event_encode({is_admin = true}))
        t.assert_equals(dec.is_admin, true)
    end

    g.test_explicit_optional_default_value_round_trips = function()
        -- Explicit `optional string apartment = 4`. Setting it to '' must
        -- survive the round trip — presence is meaningful.
        local enc = hello.Address_encode({apartment = ''})
        t.assert_equals(#enc, 2, 'apartment="" emits tag 0x22 + len 0')
        local dec = hello.Address_decode(enc)
        t.assert_equals(dec.apartment, '')
        t.assert(hello.Address_has_apartment(dec))
    end

    g.test_explicit_optional_unset_omitted = function()
        -- nil means "not set"; encoder emits nothing.
        local enc = hello.Address_encode({})
        t.assert_equals(#enc, 0)
        local dec = hello.Address_decode(enc)
        t.assert_equals(dec.apartment, nil)
        t.assert(not hello.Address_has_apartment(dec))
    end

    g.test_explicit_optional_set_value = function()
        local enc = hello.Address_encode({apartment = '5B'})
        local dec = hello.Address_decode(enc)
        t.assert_equals(dec.apartment, '5B')
        t.assert(hello.Address_has_apartment(dec))
    end

    g.test_explicit_optional_clear_helper = function()
        local addr = {street = 'X', apartment = '5B'}
        hello.Address_clear_apartment(addr)
        t.assert_equals(addr.apartment, nil)
        t.assert(not hello.Address_has_apartment(addr))
    end

    g.test_oneof_text_branch = function()
        local r = {id = 1, text = 'hello'}
        local dec = hello.Result_decode(hello.Result_encode(r))
        t.assert_equals(dec.id, 1)
        t.assert_equals(dec.text, 'hello')
        t.assert_equals(dec.code, nil)
        t.assert_equals(dec.details, nil)
    end

    g.test_oneof_code_branch = function()
        local r = {id = 2, code = 42}
        local dec = hello.Result_decode(hello.Result_encode(r))
        t.assert_equals(dec.id, 2)
        t.assert_equals(dec.code, 42)
        t.assert_equals(dec.text, nil)
        t.assert_equals(dec.details, nil)
    end

    g.test_oneof_message_branch = function()
        local r = {id = 3, details = {street = 'X', zip = 99}}
        local dec = hello.Result_decode(hello.Result_encode(r))
        t.assert_equals(dec.details.street, 'X')
        t.assert_equals(dec.details.zip, 99)
        t.assert_equals(dec.text, nil)
        t.assert_equals(dec.code, nil)
    end

    g.test_oneof_emits_default_value_when_active = function()
        -- text='' is the proto3 default for string, but presence is meaningful
        -- inside an oneof. The encoder must emit the field anyway.
        local enc = hello.Result_encode({text = ''})
        -- Expect: tag for field 2 + len 0 = "\x12\x00" (no field 1 since id=0).
        t.assert_equals(#enc, 2)
        local dec = hello.Result_decode(enc)
        t.assert_equals(dec.text, '')
    end

    g.test_oneof_decode_clears_siblings = function()
        -- Manually craft bytes setting first text, then code. Decoder must
        -- end up with code set and text cleared (last branch wins per spec).
        local raw = '\x12\x03foo'  -- field 2 (text) LEN=3, "foo"
                  .. '\x18\x07'    -- field 3 (code) varint 7
        local dec = hello.Result_decode(raw)
        t.assert_equals(dec.code, 7)
        t.assert_equals(dec.text, nil)
    end

    g.test_oneof_last_set_wins_on_encode = function()
        -- Caller sets multiple branches; encoder picks the LAST in declaration order.
        local enc = hello.Result_encode({text = 'first', code = 9, details = {street = 'last'}})
        local dec = hello.Result_decode(enc)
        t.assert_equals(dec.details.street, 'last')
        t.assert_equals(dec.text, nil)
        t.assert_equals(dec.code, nil)
    end

    g.test_repeated_string_non_packed = function()
        -- Strings are LEN-typed and never packable. Each element gets its own tag.
        local enc = hello.Person_encode({emails = {'a', 'b', 'c'}})
        -- 3 occurrences of: tag(field=3, LEN)=0x1a, len=1, ascii.
        t.assert_equals(hex(enc), '1a01611a01621a0163')
    end

    g.test_negative_zero_float_preserved = function()
        -- Proto3 default-elision treats `v == 0` as default, but IEEE
        -- `-0.0 == 0.0`. The codec must not drop -0.0 — the wire bytes
        -- differ (high bit set) and the TextFormatInput conformance
        -- suite pins this. Both float and double paths apply.
        --
        -- Compute -0.0 at runtime (`-0.0 * 1` or `0/-math.huge`); the
        -- literal `-0.0` can be constant-folded to integer 0 by the
        -- LuaJIT parser in some load paths, which would hide the bug.
        local neg_zero = 0 / -math.huge
        local enc = hello.Person_encode({weight_kg = neg_zero})
        t.assert(#enc > 0, 'expected -0.0 to be emitted, got empty payload')
        local dec = hello.Person_decode(enc)
        t.assert_equals(dec.weight_kg, 0)
        t.assert_equals(1 / dec.weight_kg, -math.huge,
            'expected sign bit preserved through round-trip')
    end

    g.test_positive_zero_float_still_elided = function()
        -- +0.0 IS the proto3 default — the codec should drop it (only the
        -- sign-bit-set case earns presence).
        local enc = hello.Person_encode({weight_kg = 0.0})
        t.assert_equals(#enc, 0)
    end
end

-- ---------------------------------------------------------------------------
-- gRPC: per-mode service round-trip via the loopback transport.
-- ---------------------------------------------------------------------------

for _, mode in ipairs(MODES) do
    local g = t.group('grpc.' .. mode)
    local pb = require('pb')
    local hello = require(mode .. '.hello.hello_pb')

    g.test_service_descriptor = function()
        local svc = hello.Greeter_service
        t.assert_equals(svc.name, 'hello.Greeter')
        t.assert_equals(svc.methods.SayHello.full_name, '/hello.Greeter/SayHello')
        t.assert_equals(svc.methods.SayHello.input, hello.HelloRequest_descriptor)
        t.assert_equals(svc.methods.SayHello.output, hello.HelloReply_descriptor)
        t.assert_equals(svc.methods.StreamHellos.server_streaming, true)
    end

    g.test_unary_round_trip_via_loopback = function()
        local impl = {
            SayHello = function(req, _)
                return {greeting = 'Hello, ' .. req.name}
            end,
            Echo = function(req, _)
                return req
            end,
        }
        local server = hello.Greeter_server(impl)
        local client = hello.Greeter_client(pb.grpc.loopback(server))

        local reply = client.SayHello({name = 'World'}, {})
        t.assert_equals(reply.greeting, 'Hello, World')

        local echoed = client.Echo({name = 'ping'}, {})
        t.assert_equals(echoed.name, 'ping')
    end

    g.test_missing_handler_errors_clearly = function()
        local server = hello.Greeter_server({})  -- no implementations
        local client = hello.Greeter_client(pb.grpc.loopback(server))
        local ok, err = pcall(client.SayHello, {name = 'x'}, {})
        t.assert(not ok)
        t.assert_str_contains(tostring(err), 'SayHello: handler missing')
    end

    g.test_client_requires_transport = function()
        t.assert_error(function() hello.Greeter_client(nil) end)
    end

    g.test_server_requires_impl_table = function()
        t.assert_error(function() hello.Greeter_server(nil) end)
    end
end

-- ---------------------------------------------------------------------------
-- Cross-mode parity: any silent divergence between full and runtime trips here.
-- ---------------------------------------------------------------------------
local g_parity = t.group('parity.full_vs_runtime')
local hello_full    = require('full.hello.hello_pb')
local hello_runtime = require('runtime.hello.hello_pb')

g_parity.test_address_byte_equality = function()
    local samples = {
        {},
        {street = 'X'},
        {street = 'X', city = 'Y', zip = 42},
        {zip = -1},
    }
    for i, s in ipairs(samples) do
        t.assert_equals(
            hex(hello_full.Address_encode(s)),
            hex(hello_runtime.Address_encode(s)),
            ('Address sample #%d diverges'):format(i))
    end
end

g_parity.test_person_byte_equality = function()
    local samples = {
        {},
        {name = 'A'},
        {name = 'A', age = 7},
        {emails = {'a', 'b'}},
        {lucky_numbers = {1, 2, 3, -7, 4}},
        {friends = {{name = 'F1'}, {name = 'F2', age = 9}}},
        {avatar = '\x00\x01\xff', user_id = ffi.cast('uint64_t', 1234567890123ULL)},
        {balance = -99999, weight_kg = 3.14159},
    }
    for i, s in ipairs(samples) do
        t.assert_equals(
            hex(hello_full.Person_encode(s)),
            hex(hello_runtime.Person_encode(s)),
            ('Person sample #%d diverges'):format(i))
    end
end

g_parity.test_decode_round_trips_through_either_module = function()
    -- Encode with full, decode with runtime, and vice versa.
    local p = {name = 'P', age = 5, emails = {'a'}, status = hello_full.Status.OK,
               friends = {{name = 'F'}}, lucky_numbers = {10, 20}}
    local enc = hello_full.Person_encode(p)
    local dec = hello_runtime.Person_decode(enc)
    t.assert_equals(dec.name, 'P')
    t.assert_equals(dec.age, 5)
    t.assert_equals(dec.emails[1], 'a')
    t.assert_equals(dec.status, hello_full.Status.OK)
    t.assert_equals(dec.friends[1].name, 'F')
    t.assert_equals(#dec.lucky_numbers, 2)

    local enc2 = hello_runtime.Person_encode(p)
    t.assert_equals(hex(enc), hex(enc2))
end
