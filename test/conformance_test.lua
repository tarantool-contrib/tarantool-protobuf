-- Self-test for the conformance runner.
--
-- The Google conformance suite is an external binary
-- (`conformance_test_runner`) we can't reasonably bundle here, so this
-- test stands in for it: drives our runner with crafted
-- `ConformanceRequest` cases and asserts well-formed
-- `ConformanceResponse` output.
--
-- Two layers:
--   1. `core` group — calls `cmd.conformance.core.handle_request` directly.
--      Covers every dispatch arm without paying subprocess cost.
--   2. `subprocess` group — actually pipes framed bytes through
--      `tarantool cmd/conformance-runner.lua`. Covers the length-prefixed
--      framing and the read-until-EOF loop.

local t           = require('luatest')
local fio         = require('fio')
local core        = require('cmd.conformance.core')
local conformance = require('full.conformance.conformance_pb')
local proto3      = require('full.protobuf_test_messages.proto3.test_messages_proto3_pb')

local PROTOBUF = conformance.WireFormat.PROTOBUF
local JSON     = conformance.WireFormat.JSON
local TEXT     = conformance.WireFormat.TEXT_FORMAT

local PROTO3_NAME = 'protobuf_test_messages.proto3.TestAllTypesProto3'
local PROTO3      = proto3.TestAllTypesProto3_descriptor
local pb          = require('pb')

local function encode_req(t_)
    return conformance.ConformanceRequest_encode(t_)
end

local function decode_resp(bytes)
    return conformance.ConformanceResponse_decode(bytes)
end

-- ---------------------------------------------------------------------------
-- 1. Direct dispatch (no subprocess)
-- ---------------------------------------------------------------------------

local core_g = t.group('conformance.core')

core_g.test_failureset_preflight = function()
    -- The conformance runner asks for a FailureSet up front. Empty payload,
    -- empty FailureSet response is the canonical answer.
    local req = encode_req({
        protobuf_payload = '',
        requested_output_format = PROTOBUF,
        message_type = 'conformance.FailureSet',
    })
    local resp = decode_resp(core.handle_request(req))
    t.assert_equals(resp.protobuf_payload, '')
    t.assert_equals(resp.skipped, nil)
    t.assert_equals(resp.parse_error, nil)
    t.assert_equals(resp.runtime_error, nil)
end

core_g.test_pb_to_pb_roundtrip = function()
    -- Encode a TestAllTypesProto3 ourselves, ask the runner to round-trip
    -- it through pb->pb, assert byte-identical output. Since our encoder
    -- is deterministic for non-map fields, the output bytes must match
    -- input bytes exactly.
    local input = proto3.TestAllTypesProto3_encode({
        optional_int32  = 42,
        optional_string = 'hello',
        repeated_int32  = {1, 2, 3, 4},
    })
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_equals(resp.protobuf_payload, input)
end

core_g.test_pb_to_json = function()
    local input = proto3.TestAllTypesProto3_encode({
        optional_int32 = 7,
        optional_string = 'world',
    })
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = JSON,
        message_type = PROTO3_NAME,
    })))
    t.assert_str_contains(resp.json_payload, '"optionalInt32":7')
    t.assert_str_contains(resp.json_payload, '"optionalString":"world"')
end

core_g.test_json_to_pb = function()
    local resp = decode_resp(core.handle_request(encode_req({
        json_payload = [[{"optionalInt32": 9, "optionalString": "abc"}]],
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.runtime_error, resp.runtime_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.optional_int32, 9)
    t.assert_equals(decoded.optional_string, 'abc')
end

core_g.test_parse_error_on_malformed_protobuf = function()
    -- A truncated varint should produce a parse_error, not a crash.
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = '\x08',  -- tag(1, VARINT), no value
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_not_equals(resp.parse_error, nil)
end

core_g.test_parse_error_on_malformed_json = function()
    local resp = decode_resp(core.handle_request(encode_req({
        json_payload = '{not valid json',
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_not_equals(resp.parse_error, nil)
end

core_g.test_unsupported_message_type_skipped = function()
    -- Editions test message types are intentionally unsupported. Proto2
    -- moved into the registry once codegen landed; pick a type that's
    -- explicitly absent so this pin still demonstrates the skip path.
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = '',
        requested_output_format = PROTOBUF,
        message_type = 'protobuf_test_messages.editions.TestAllTypesEdition2023',
    })))
    t.assert_str_contains(resp.skipped or '', 'unsupported message type')
end

core_g.test_pb_to_text = function()
    -- protobuf input + TEXT_FORMAT output runs pb.text.encode on the
    -- decoded Lua table. Result should look like `protoc --decode` output.
    local input = proto3.TestAllTypesProto3_encode({
        optional_int32  = 42,
        optional_string = 'hello',
        repeated_int32  = {1, 2, 3},
    })
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = TEXT,
        message_type = PROTO3_NAME,
    })))
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_not(resp.skipped, resp.skipped)
    t.assert_str_contains(resp.text_payload, 'optional_int32: 42')
    t.assert_str_contains(resp.text_payload, 'optional_string: "hello"')
    -- Repeated fields emit once per element, snake_case, mainline form.
    t.assert_str_contains(resp.text_payload, 'repeated_int32: 1')
    t.assert_str_contains(resp.text_payload, 'repeated_int32: 2')
    t.assert_str_contains(resp.text_payload, 'repeated_int32: 3')
end

core_g.test_json_to_text = function()
    local resp = decode_resp(core.handle_request(encode_req({
        json_payload = [[{"optionalInt32": 7, "optionalString": "abc"}]],
        requested_output_format = TEXT,
        message_type = PROTO3_NAME,
    })))
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_str_contains(resp.text_payload, 'optional_int32: 7')
    t.assert_str_contains(resp.text_payload, 'optional_string: "abc"')
end

core_g.test_empty_message_to_text = function()
    -- Empty proto3 message has no fields to print; text encoder produces
    -- the empty string. The result field is still text_payload (empty
    -- string), not skipped/runtime_error.
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = '',
        requested_output_format = TEXT,
        message_type = PROTO3_NAME,
    })))
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_equals(resp.text_payload, '')
end

-- ---- text-format input -------------------------------------------------
-- Each scenario bucket is pinned with a payload cribbed from the upstream
-- conformance corpus so the inner dev loop catches regressions without
-- running Docker.

local function decode_pb(text)
    local resp = decode_resp(core.handle_request(encode_req({
        text_payload = text,
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    return resp
end

core_g.test_text_input_basic_scalar = function()
    local r = decode_pb('optional_int32: 12345\n')
    -- tag 0xE8 0x07 (field 125, varint) → bytes 0xe8 0x06 ... let pb decode it.
    local m = pb.decode(PROTO3, r.protobuf_payload)
    t.assert_equals(m.optional_int32, 12345)
end

core_g.test_text_input_number_radixes = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_int32: 0x7fffffff\noptional_uint32: 037777777777\n').protobuf_payload)
    t.assert_equals(m.optional_int32, 0x7fffffff)
    t.assert_equals(m.optional_uint32, 0xffffffff)
end

core_g.test_text_input_float_specials = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_double: Infinity\noptional_float: -inf\n').protobuf_payload)
    t.assert_equals(m.optional_double, math.huge)
    t.assert_equals(m.optional_float, -math.huge)
end

core_g.test_text_input_string_escapes = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_string: "a\\tb\\n\\xc3\\x9f"\n').protobuf_payload)
    t.assert_equals(m.optional_string, 'a\tb\n\xc3\x9f')
end

core_g.test_text_input_adjacent_string_literals = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_string: "foo" "bar"\n').protobuf_payload)
    t.assert_equals(m.optional_string, 'foobar')
end

core_g.test_text_input_angle_brackets = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_nested_message < a: 7 >\n').protobuf_payload)
    t.assert_equals(m.optional_nested_message.a, 7)
end

core_g.test_text_input_separators_comma_and_semi = function()
    -- Both `,` and `;` are valid single separators between fields.
    local m = pb.decode(PROTO3, decode_pb(
        'optional_int32: 1,\noptional_int64: 2;\n').protobuf_payload)
    t.assert_equals(m.optional_int32, 1)
    t.assert_equals(tonumber(m.optional_int64), 2)
end

core_g.test_text_input_double_semicolon_rejected = function()
    -- `;;` is two separators; the empty entry between them is rejected.
    -- Pins FieldSeparatorSemi*.
    local resp = decode_resp(core.handle_request(encode_req({
        text_payload = 'optional_int32: 1;;\n',
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_str_contains(resp.parse_error or '', 'field-entry start')
end

core_g.test_text_input_list_shorthand = function()
    local m = pb.decode(PROTO3, decode_pb(
        'repeated_int32: [1, 2, 3]\n').protobuf_payload)
    t.assert_equals(m.repeated_int32, {1, 2, 3})
end

core_g.test_text_input_list_shorthand_separate_appends = function()
    -- `field: [1]` followed by `field: [2]` -> two-element list (don't
    -- collapse). Pins ListSeparatorMissingIsOneValue_*.
    local m = pb.decode(PROTO3, decode_pb(
        'repeated_int32: [1] repeated_int32: [2]\n').protobuf_payload)
    t.assert_equals(m.repeated_int32, {1, 2})
end

core_g.test_text_input_reserved_field_name = function()
    -- `reserved "reserved_field"` declared on TestAllTypesProto3; must be
    -- silently dropped, not error.
    local m = pb.decode(PROTO3, decode_pb(
        'optional_int32: 1\nreserved_field: 999\n').protobuf_payload)
    t.assert_equals(m.optional_int32, 1)
end

core_g.test_text_input_unknown_numeric_id_dropped = function()
    -- Numeric field IDs that don't resolve in the schema are silently
    -- dropped (matches mainline AllowFieldNumber under the harness).
    local m = pb.decode(PROTO3, decode_pb(
        'optional_int32: 1\n9999: 42\n').protobuf_payload)
    t.assert_equals(m.optional_int32, 1)
end

core_g.test_text_input_enum_by_name = function()
    -- BAR (=1) keeps the field present after the proto3 default-elision
    -- pass; FOO (=0) would round-trip to the absence default.
    local m = pb.decode(PROTO3, decode_pb(
        'optional_nested_enum: BAR\n').protobuf_payload)
    t.assert_equals(m.optional_nested_enum, 1)
end

core_g.test_text_input_enum_by_number = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_nested_enum: 2\n').protobuf_payload)
    t.assert_equals(m.optional_nested_enum, 2)
end

core_g.test_text_input_unknown_enum_name_errors = function()
    local resp = decode_resp(core.handle_request(encode_req({
        text_payload = 'optional_nested_enum: BOGUS_NAME\n',
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_str_contains(resp.parse_error or '', 'unknown enum')
end

core_g.test_text_input_map_entry = function()
    local m = pb.decode(PROTO3, decode_pb(
        'map_string_string { key: "k" value: "v" }\n').protobuf_payload)
    t.assert_equals(m.map_string_string, {k = 'v'})
end

core_g.test_text_input_uint64_max = function()
    local m = pb.decode(PROTO3, decode_pb(
        'optional_uint64: 0xFFFFFFFFFFFFFFFF\n').protobuf_payload)
    t.assert_equals(m.optional_uint64, require('ffi').cast('uint64_t', -1))
end

core_g.test_jspb_output_skipped = function()
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = '',
        requested_output_format = conformance.WireFormat.JSPB,
        message_type = PROTO3_NAME,
    })))
    t.assert_str_contains(resp.skipped or '', 'jspb')
end

core_g.test_empty_payload_decodes_as_empty_message = function()
    -- proto3 says empty bytes is a valid empty message.
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = '',
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_equals(resp.protobuf_payload, '')
end

core_g.test_wkt_timestamp_field_roundtrip = function()
    -- Exercise the WKT path: TestAllTypesProto3.optional_timestamp.
    -- We rely on our WKT Timestamp encoder/decoder.
    local input = proto3.TestAllTypesProto3_encode({
        optional_timestamp = require('datetime').new({timestamp = 1700000000}),
    })
    local resp = decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
    t.assert_equals(resp.protobuf_payload, input)
end

-- ---------------------------------------------------------------------------
-- Regression tests for fixes referenced in test/conformance/TRIAGE.md
-- Each test pins one code path against a conformance-shaped request so a
-- future change that re-opens the bug is caught locally without needing the
-- Docker conformance runner. Tests are grouped by fix; multiple tests per
-- fix exist because each fix touches several distinct code paths (per
-- scalar type, per shape — singular/repeated/map).
-- ---------------------------------------------------------------------------

-- Shared helpers for the regression group.
local function pb_roundtrip(input)
    return decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
end

local function json_to_pb(json_str)
    return decode_resp(core.handle_request(encode_req({
        json_payload = json_str,
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })))
end

-- =========================================================================
-- Fix 1: varint truncation to 32 bits — int32/uint32/
-- sint32/enum decode must drop bits above bit 31 and sign-extend signed
-- variants. Distinct code paths: typed scalar decoders (wire.lua) plus
-- enum-via-decode_varint sites (codec.lua + inline.go + lazy.lua).
-- =========================================================================

core_g.test_int32_truncates_high_bits_to_zero = function()
    -- 1<<33: low 32 bits all zero → decode to 0, encode to "" (default elision)
    local resp = pb_roundtrip('\x08\x80\x80\x80\x80\x10')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '')
end

core_g.test_int32_truncates_with_sign_extension = function()
    -- (1<<33)-1: low 32 bits 0xFFFFFFFF → sign-extend to -1 → 10-byte varint
    local resp = pb_roundtrip('\x08\xff\xff\xff\xff\x1f')
    t.assert_not(resp.parse_error, resp.parse_error)
    -- -1 as int32 is encoded as uint64 0xFFFFFFFFFFFFFFFF = 10-byte varint
    t.assert_equals(resp.protobuf_payload,
        '\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01')
end

core_g.test_uint32_truncates_to_low_32_bits = function()
    -- field 3 = optional_uint32. Input (1<<33)-1 → low 32 = UINT32_MAX → 5-byte
    local resp = pb_roundtrip('\x18\xff\xff\xff\xff\x1f')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '\x18\xff\xff\xff\xff\x0f')
end

core_g.test_sint32_zigzag_truncates_to_32_bits = function()
    -- field 5 = optional_sint32. zz64(INT32_MAX+2) = 4294967298 → low 32 = 2
    -- → zigzag_decode(2) = 1 → re-encoded as zz32(1) = varint(2)
    -- zz64(4294967298) varint: 0x82 0x80 0x80 0x80 0x10
    local resp = pb_roundtrip('\x28\x82\x80\x80\x80\x10')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '\x28\x02')  -- field 5, varint(2)
end

core_g.test_enum_singular_truncates_to_int32 = function()
    -- field 21 = optional_nested_enum. Input INT64_MAX varint → low 32 bits
    -- = 0xFFFFFFFF → -1 → 10-byte uint64 form on re-encode.
    -- Tag: (21<<3)|0 = 0xA8 0x01. Varint(INT64_MAX) is 9 bytes 0xFF×8 0x7F.
    local resp = pb_roundtrip(
        '\xa8\x01' .. '\xff\xff\xff\xff\xff\xff\xff\xff\x7f')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload,
        '\xa8\x01' .. '\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01')
end

core_g.test_packed_repeated_int32_truncates_each_element = function()
    -- field 31 = repeated_int32 (packed). Input contains one over-range value
    -- (1<<33) — must decode-then-encode as 0; since 0 is in a packed list it
    -- is still emitted (lists never elide).
    -- Tag: (31<<3)|2 = 0xFA 0x01. Length-prefixed payload of varint(1<<33).
    local payload = '\x80\x80\x80\x80\x10'
    local input = '\xfa\x01' .. string.char(#payload) .. payload
    local resp = pb_roundtrip(input)
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.repeated_int32, {0})
end

core_g.test_repeated_scalar_selects_last_after_truncation = function()
    -- proto3 last-one-wins on singular scalars: send int32 twice, both
    -- over-range, only the second value survives, and it must be truncated.
    -- Input: tag(1,VARINT) + varint(1<<33), tag(1,VARINT) + varint((1<<33)-1)
    local input = '\x08\x80\x80\x80\x80\x10'
                .. '\x08\xff\xff\xff\xff\x1f'
    local resp = pb_roundtrip(input)
    t.assert_not(resp.parse_error, resp.parse_error)
    -- Last value (1<<33)-1 truncates to -1 → 10-byte varint
    t.assert_equals(resp.protobuf_payload,
        '\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01')
end

-- =========================================================================
-- Fix 2: reject illegal wire types 6/7 in decode_tag.
-- The check must fire whether the tag references a known field (typed
-- reader path) or an unknown one (skip_field path).
-- =========================================================================

core_g.test_wire_type_6_known_field_rejected = function()
    -- tag = (1<<3)|6 = 0x0e against optional_int32
    t.assert_not_equals(pb_roundtrip('\x0e\x01').parse_error, nil)
end

core_g.test_wire_type_7_known_field_rejected = function()
    -- tag = (1<<3)|7 = 0x0f against optional_int32
    t.assert_not_equals(pb_roundtrip('\x0f\x01').parse_error, nil)
end

core_g.test_wire_type_6_unknown_field_rejected = function()
    -- tag = (1000<<3)|6, varint encoded. 1000 fits in 2 bytes.
    -- (1000<<3)|6 = 8006 → varint 0xc6 0xbe 0x00. Plus one payload byte.
    -- Actually 8006 = 0x1F46 → varint two-byte: 0xc6 0x3e
    t.assert_not_equals(pb_roundtrip('\xc6\x3e\x01').parse_error, nil)
end

core_g.test_wire_type_6_after_valid_field_rejected = function()
    -- A valid field followed by an illegal one — confirms the check fires
    -- mid-stream, not only on the first tag.
    t.assert_not_equals(pb_roundtrip('\x08\x05' .. '\x0e\x01').parse_error, nil)
end

core_g.test_valid_wire_types_still_accepted = function()
    -- Positive control: wt=0 (VARINT) for known field, wt=2 (LEN) for
    -- string, wt=5 (I32) for float — none should error.
    local input = '\x08\x05'                          -- tag(1,VARINT) int32=5
              .. '\x72\x03foo'                        -- tag(14,LEN) string="foo"
              .. '\x5d\x00\x00\x00\x00'               -- tag(11,I32) float=0
    local resp = pb_roundtrip(input)
    t.assert_not(resp.parse_error, resp.parse_error)
end

-- =========================================================================
-- Fix 3: WKT registry self-registers so json_to_any can
-- resolve @type for any well-known type without manual pb.register calls.
-- =========================================================================

core_g.test_pb_lookup_returns_wkt_descriptors = function()
    local pb = require('pb')
    for _, name in ipairs({
        'google.protobuf.Timestamp',
        'google.protobuf.Duration',
        'google.protobuf.FieldMask',
        'google.protobuf.Empty',
        'google.protobuf.Any',
        'google.protobuf.Struct',
        'google.protobuf.Value',
        'google.protobuf.ListValue',
        'google.protobuf.Int32Value',
        'google.protobuf.StringValue',
        'google.protobuf.BoolValue',
    }) do
        t.assert_not_equals(pb.lookup(name), nil,
            'pb.lookup must resolve ' .. name)
        t.assert_not_equals(pb.lookup('type.googleapis.com/' .. name), nil,
            'pb.lookup must resolve fully-qualified URL for ' .. name)
    end
end

core_g.test_any_with_timestamp_resolves = function()
    local resp = json_to_pb([[{"optionalAny": {
        "@type": "type.googleapis.com/google.protobuf.Timestamp",
        "value": "1970-01-01T00:00:01Z"
    }}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not_equals(resp.protobuf_payload, '')
end

core_g.test_any_with_duration_resolves = function()
    local resp = json_to_pb([[{"optionalAny": {
        "@type": "type.googleapis.com/google.protobuf.Duration",
        "value": "1.5s"
    }}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not_equals(resp.protobuf_payload, '')
end

core_g.test_any_with_int32_wrapper_resolves = function()
    local resp = json_to_pb([[{"optionalAny": {
        "@type": "type.googleapis.com/google.protobuf.Int32Value",
        "value": 42
    }}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not_equals(resp.protobuf_payload, '')
end

core_g.test_any_with_struct_resolves = function()
    local resp = json_to_pb([[{"optionalAny": {
        "@type": "type.googleapis.com/google.protobuf.Struct",
        "value": {"key": "val"}
    }}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not_equals(resp.protobuf_payload, '')
end

core_g.test_any_with_user_type_resolves = function()
    -- core.lua registers TestAllTypesProto3 in the WKT registry so Any
    -- can also embed user types — pin that behavior.
    local resp = json_to_pb(string.format([[{"optionalAny": {
        "@type": "type.googleapis.com/%s",
        "optionalInt32": 7
    }}]], PROTO3_NAME))
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not_equals(resp.protobuf_payload, '')
end

-- =========================================================================
-- Fix 4: skip_field bounds checks. Truncated unknown
-- fields of every wire type must raise a parse_error rather than the
-- outer `while pos <= len` exiting silently.
-- =========================================================================

core_g.test_skip_field_rejects_truncated_i64 = function()
    -- field 105 (unknown), I64, 3 of 8 bytes
    t.assert_not_equals(pb_roundtrip('\xc9\x06\x00\x00\x00').parse_error, nil)
end

core_g.test_skip_field_rejects_truncated_i32 = function()
    -- field 105 (unknown), I32, 2 of 4 bytes
    t.assert_not_equals(pb_roundtrip('\xcd\x06\x00\x00').parse_error, nil)
end

core_g.test_skip_field_rejects_truncated_len_fast_path = function()
    -- field 105 (unknown), LEN; declared length 5, only 2 bytes follow.
    -- Length byte 5 < 0x80 → fast-path bounds check exercised.
    t.assert_not_equals(pb_roundtrip('\xca\x06\x05ab').parse_error, nil)
end

core_g.test_skip_field_rejects_truncated_len_multibyte = function()
    -- field 105 (unknown), LEN; declared length 200 (multi-byte varint),
    -- only 1 byte follows. Slow-path bounds check exercised.
    t.assert_not_equals(pb_roundtrip('\xca\x06\xc8\x01a').parse_error, nil)
end

core_g.test_skip_field_accepts_complete_unknown = function()
    -- Positive control: an unknown field whose payload IS fully present
    -- must round-trip cleanly (and our parser preserves unknowns).
    local input = '\xc9\x06' .. '\x01\x02\x03\x04\x05\x06\x07\x08'
    local resp = pb_roundtrip(input)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, input)
end

-- =========================================================================
-- Unknown enum *names* in JSON input are rejected (proto3 spec; pinned
-- by RejectUnknownEnumStringValueIn{Optional,Repeated,Map}). Unknown
-- enum *integers* are forward-compat and pass through unchanged
-- (see test_unknown_enum_numeric_preserved below).
-- =========================================================================

core_g.test_unknown_enum_string_rejected_in_singular = function()
    local resp = json_to_pb(
        [[{"optionalNestedEnum": "DEFINITELY_NOT_A_VALUE"}]])
    t.assert_str_contains(resp.parse_error or '', 'unknown enum value')
end

core_g.test_unknown_enum_string_rejected_in_repeated = function()
    local resp = json_to_pb(
        [[{"repeatedNestedEnum": ["FOO", "DEFINITELY_NOT_A_VALUE", "BAR"]}]])
    t.assert_str_contains(resp.parse_error or '', 'unknown enum value')
end

core_g.test_unknown_enum_string_rejected_in_map_value = function()
    local resp = json_to_pb([[{"mapStringNestedEnum": {
        "good": "BAR",
        "bad":  "DEFINITELY_NOT_A_VALUE"
    }}]])
    t.assert_str_contains(resp.parse_error or '', 'unknown enum value')
end

core_g.test_unknown_enum_numeric_preserved = function()
    -- proto3 spec: unknown *integer* enum values pass through unchanged.
    -- Only string names that don't resolve get dropped.
    local resp = json_to_pb([[{"optionalNestedEnum": 999}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.optional_nested_enum, 999)
end

core_g.test_unknown_enum_numeric_string_preserved = function()
    -- Numeric strings like "999" should also be preserved as the integer.
    local resp = json_to_pb([[{"optionalNestedEnum": "999"}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.optional_nested_enum, 999)
end

-- =========================================================================
-- Fix 6: oneof + repeated-message merge. Two occurrences of a
-- singular message field — including a oneof branch — must merge per
-- proto3 spec: scalars last-wins, repeated fields concatenate, nested
-- sub-messages merge recursively. Sibling clearing still enforces oneof
-- exclusivity.
-- =========================================================================

local function dup_msg(tag_bytes, sub1, sub2)
    return tag_bytes .. string.char(#sub1) .. sub1
        .. tag_bytes .. string.char(#sub2) .. sub2
end

core_g.test_singular_message_merge_scalar_last_wins = function()
    -- optional_nested_message (id 18, tag 0x92 0x01) appears twice;
    -- scalar `a` must take last-wins.
    local sub1 = proto3.TestAllTypesProto3_NestedMessage_encode({a = 1234})
    local sub2 = proto3.TestAllTypesProto3_NestedMessage_encode({a = 4321})
    local resp = pb_roundtrip(dup_msg('\x92\x01', sub1, sub2))
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.optional_nested_message.a, 4321)
end

core_g.test_oneof_message_merge_not_replace = function()
    -- oneof_nested_message (id 112, tag 0x82 0x07) appears twice. Pre-fix
    -- the second occurrence replaced the first wholesale, losing fields
    -- unique to submsg1. Post-fix, scalar last-wins applies inside the
    -- merged sub-message.
    local sub1 = proto3.TestAllTypesProto3_NestedMessage_encode({a = 1234})
    local sub2 = proto3.TestAllTypesProto3_NestedMessage_encode({a = 4321})
    local resp = pb_roundtrip(dup_msg('\x82\x07', sub1, sub2))
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.oneof_nested_message.a, 4321)
end

core_g.test_message_merge_recurses_into_submessage = function()
    -- NestedMessage.corecursive is itself a TestAllTypesProto3. When two
    -- outer NestedMessage occurrences both have corecursive set with
    -- DIFFERENT scalar fields, the inner messages must merge recursively
    -- (not be replaced).
    local inner1 = proto3.TestAllTypesProto3_decode(
        proto3.TestAllTypesProto3_encode({optional_int32 = 7}))
    local inner2 = proto3.TestAllTypesProto3_decode(
        proto3.TestAllTypesProto3_encode({optional_int64 = 42LL}))
    local sub1 = proto3.TestAllTypesProto3_NestedMessage_encode(
        {corecursive = inner1})
    local sub2 = proto3.TestAllTypesProto3_NestedMessage_encode(
        {corecursive = inner2})
    local resp = pb_roundtrip(dup_msg('\x92\x01', sub1, sub2))
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    local cc = decoded.optional_nested_message.corecursive
    t.assert_equals(cc.optional_int32, 7,
        'inner field from submsg1 must survive recursive merge')
    t.assert_equals(tonumber(cc.optional_int64), 42,
        'inner field from submsg2 must survive recursive merge')
end

core_g.test_message_merge_concatenates_repeated_in_submessage = function()
    -- NestedMessage.corecursive has repeated_int32 = field 31. Two outer
    -- occurrences with corecursive set must concat the inner repeated.
    local inner1 = proto3.TestAllTypesProto3_decode(
        proto3.TestAllTypesProto3_encode({repeated_int32 = {1, 2, 3}}))
    local inner2 = proto3.TestAllTypesProto3_decode(
        proto3.TestAllTypesProto3_encode({repeated_int32 = {4, 5}}))
    local sub1 = proto3.TestAllTypesProto3_NestedMessage_encode(
        {corecursive = inner1})
    local sub2 = proto3.TestAllTypesProto3_NestedMessage_encode(
        {corecursive = inner2})
    local resp = pb_roundtrip(dup_msg('\x92\x01', sub1, sub2))
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.optional_nested_message.corecursive.repeated_int32,
        {1, 2, 3, 4, 5})
end

-- =========================================================================
-- Fix 7: tag validation in decode_tag. Field number 0 is illegal; field
-- numbers > 2^29-1 are illegal; tag varints must be minimally encoded.
-- The uint64-cdata bit ops are required so very high field numbers don't
-- alias back into the valid range after a 32-bit truncation.
-- =========================================================================

core_g.test_field_number_zero_rejected = function()
    -- IllegalZeroFieldNum: tag 0x00 = field 0, wt 0. One trailing byte.
    t.assert_not_equals(pb_roundtrip('\x00\x00').parse_error, nil)
end

core_g.test_field_number_far_too_high_rejected = function()
    -- 7-byte tag varint with bits in the highest byte that would put the
    -- field number > 2^29. tonumber+bit.rshift truncation would have
    -- mis-recovered fn=10 — the uint64 bit ops catch it.
    local input = '\xd2\x80\x80\x80\x80\x80\x0f\xd2\t'
    t.assert_not_equals(pb_roundtrip(input).parse_error, nil)
end

core_g.test_field_number_slightly_too_high_rejected = function()
    -- 5-byte tag with fn = 2^31+1, still > 2^29-1 → reject. The 32-bit
    -- truncation aliased this to fn=1 pre-fix.
    local input = '\x88\x80\x80\x80\x40\xd2\t'
    t.assert_not_equals(pb_roundtrip(input).parse_error, nil)
end

core_g.test_overlong_tag_varint_rejected = function()
    -- Tag 1, wt 0 encoded as 5 bytes (canonical is 1). Trailing byte 0
    -- with byte_count > 1 triggers the overlong check.
    local input = '\x88\x80\x80\x80\x00\x01'
    t.assert_not_equals(pb_roundtrip(input).parse_error, nil)
end

-- =========================================================================
-- Fix 8: UTF-8 validation on proto3 string fields. Singular, repeated,
-- oneof, map key, and map value all share decode_string in wire.lua, so
-- pinning a few distinct shapes is enough.
-- =========================================================================

core_g.test_invalid_utf8_singular_string_rejected = function()
    -- field 14 = optional_string. tag(14, LEN) = 0x72. One-byte payload
    -- 0xff is an isolated start of a 5-byte UTF-8 sequence (illegal).
    t.assert_not_equals(pb_roundtrip('\x72\x01\xff').parse_error, nil)
end

core_g.test_invalid_utf8_repeated_string_rejected = function()
    -- field 44 = repeated_string. Encode three entries, middle invalid.
    -- tag(44, LEN) = (44<<3)|2 = 354 → varint 0xe2 0x02.
    local tag = '\xe2\x02'
    local input = tag .. '\x02ok' .. tag .. '\x01\xff' .. tag .. '\x02ok'
    t.assert_not_equals(pb_roundtrip(input).parse_error, nil)
end

core_g.test_invalid_utf8_oneof_string_rejected = function()
    -- oneof_string id 113, tag (113<<3)|2 = 906 → varint 0x8a 0x07.
    t.assert_not_equals(pb_roundtrip('\x8a\x07\x01\xff').parse_error, nil)
end

core_g.test_invalid_utf8_lone_surrogate_rejected = function()
    -- 0xED 0xA0 0x80 is U+D800 (a UTF-16 surrogate), invalid as a code
    -- point. Pin the surrogate-range branch of is_valid_utf8.
    t.assert_not_equals(pb_roundtrip('\x72\x03\xed\xa0\x80').parse_error, nil)
end

core_g.test_invalid_utf8_above_max_codepoint_rejected = function()
    -- 0xF4 0x90 0x80 0x80 is U+110000, one past Unicode's max. Pin the
    -- > U+10FFFF branch.
    local input = '\x72\x04\xf4\x90\x80\x80'
    t.assert_not_equals(pb_roundtrip(input).parse_error, nil)
end

core_g.test_valid_utf8_singular_string_round_trips = function()
    -- Positive control: a multi-byte UTF-8 string survives unchanged.
    local s = '\xe2\x9c\x85'  -- ✅ U+2705
    local input = '\x72' .. string.char(#s) .. s
    local resp = pb_roundtrip(input)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, input)
end

core_g.test_bytes_field_accepts_arbitrary_bytes = function()
    -- bytes (not string) must NOT validate UTF-8. field 15 = optional_bytes.
    -- tag(15, LEN) = 0x7a.
    local resp = pb_roundtrip('\x7a\x03\xff\xfe\xfd')
    t.assert_not(resp.parse_error, resp.parse_error)
end

-- =========================================================================
-- C decoder strict-decode parity with pure-Lua codec. The Lua
-- decoder already rejected illegal map-key/value UTF-8 and unmatched
-- proto2 SGROUPs (covered indirectly by the wire-type and tag-validation
-- tests above); the C decoder used to accept them silently, which was
-- caught only by the Google conformance harness. The tests below add the
-- coverage that was missing — map-key/value UTF-8 was tested for
-- singular/repeated/oneof shapes but not map, and proto2 group balancing
-- had no `make test` coverage at all.
-- =========================================================================

core_g.test_invalid_utf8_map_key_rejected = function()
    -- map_string_string is field 69 → tag = (69<<3)|2 = 554 →
    -- varint 0xaa 0x04. Inside the entry, key tag is (1<<3)|2 = 0x0a;
    -- value tag is (2<<3)|2 = 0x12. The key payload 0xa0 0xb0 0xc0 0xd0
    -- starts with a lone continuation byte — invalid UTF-8. Bytes
    -- borrowed from RejectInvalidUtf8.String.MapKey.
    t.assert_not_equals(
        pb_roundtrip('\xaa\x04\x0b\x0a\x04\xa0\xb0\xc0\xd0\x12\x03foo').parse_error,
        nil)
end

core_g.test_invalid_utf8_map_value_rejected = function()
    -- Same outer wire shape; key is "foo", value bytes are invalid UTF-8.
    -- Mirrors RejectInvalidUtf8.String.MapValue.
    t.assert_not_equals(
        pb_roundtrip('\xaa\x04\x0b\x0a\x03foo\x12\x04\xa0\xb0\xc0\xd0').parse_error,
        nil)
end

-- =========================================================================
-- Proto2 group dispatch. The proto3 fast path skips SGROUP
-- payloads via dec_skip_with_id, but a proto2 known-field group descends
-- into decode_body with a stop_group_id. Without an EGROUP-seen guard,
-- the loop fell off c->len and returned silently — the Lua codec errors,
-- so the C decoder must too. UnmatchedStartGroup uses the same byte
-- pattern: tag(201, SGROUP) = (201<<3)|3 = 1611 → varint 0xcb 0x0c.
-- =========================================================================

local PROTO2_NAME = 'protobuf_test_messages.proto2.TestAllTypesProto2'

local function pb_roundtrip_proto2(input)
    return decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = PROTOBUF,
        message_type = PROTO2_NAME,
    })))
end

core_g.test_unmatched_start_group_rejected = function()
    -- Field 201 SGROUP with no body and no matching EGROUP.
    t.assert_not_equals(
        pb_roundtrip_proto2('\xcb\x0c').parse_error, nil)
end

core_g.test_unmatched_start_group_nested_rejected = function()
    -- Outer SGROUP for field 201, nested SGROUP for field 202
    -- (tag (202<<3)|3 = 1619 = 0xd3 0x0c), then exactly one EGROUP for
    -- field 201 (tag (201<<3)|4 = 1612 = 0xcc 0x0c). The inner group is
    -- unterminated; SGROUP-recursive skip in the Lua decoder errors, and
    -- the C decoder must match. Mirrors UnmatchedStartGroupNested.
    t.assert_not_equals(
        pb_roundtrip_proto2('\xcb\x0c\xd3\x0c\xcc\x0c').parse_error, nil)
end

-- =========================================================================
-- Fix 9: JSON null on a field is "use default" (drop the field), except
-- for google.protobuf.Value where null is itself a Value (NullValue).
-- Compounded by Tarantool's box.NULL aliasing to nil under __eq, so the
-- decode-side `if dv ~= nil` checks must use rawequal, and the encode-
-- side message field check must accept cdata box.NULL.
-- =========================================================================

core_g.test_null_scalar_fields_treated_as_default = function()
    -- Every primitive type set to null in JSON should produce an empty
    -- protobuf payload (default elision on encode).
    local resp = json_to_pb([[{
        "optionalInt32":  null,
        "optionalInt64":  null,
        "optionalUint32": null,
        "optionalBool":   null,
        "optionalString": null
    }]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '')
end

core_g.test_null_repeated_field_treated_as_empty = function()
    -- A repeated field set to null must not crash on #jv (it isn't an
    -- array). The field stays empty.
    local resp = json_to_pb([[{"repeatedInt32": null}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '')
end

core_g.test_null_map_field_treated_as_empty = function()
    -- A map field set to null must not crash on pairs(jv). Stays empty.
    local resp = json_to_pb([[{"mapStringString": null}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '')
end

core_g.test_null_wrapper_treated_as_absent = function()
    -- proto3 JSON: null in a *Value wrapper field means the wrapper is
    -- absent, NOT a wrapper containing 0/empty/false. Empty payload.
    local resp = json_to_pb([[{"optionalInt32Wrapper": null}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '')
end

core_g.test_null_value_field_emits_null_value_member = function()
    -- google.protobuf.Value is the exception: JSON null IS a value
    -- (NullValue.NULL_VALUE). The field must emit tag(value, LEN) + the
    -- inner Value's bytes ('\x08\x00' = field 1 VARINT 0).
    -- field 306 = optional_value. tag = (306<<3)|2 = 2450 → varint 0x92 0x13.
    local resp = json_to_pb([[{"optionalValue": null}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '\x92\x13\x02\x08\x00')
end

-- =========================================================================
-- Fix 10: lower-camelCase mapping for JSON field names. The proto3 spec
-- collapses runs of underscores (`__`) and drops trailing underscores; a
-- leading underscore causes capitalization of the next letter so the
-- generated JSON name has no leading underscore.
-- =========================================================================

core_g.test_json_decode_camel_case_drops_double_underscore = function()
    -- field 404 = field__name4_ → canonical JSON name "fieldName4".
    -- tag = (404<<3)|0 = 3232 → varint 0xa0 0x19. Plus value varint.
    local resp = json_to_pb([[{"fieldName4": 4}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '\xa0\x19\x04')
end

core_g.test_json_decode_camel_case_leading_underscore_capitalizes = function()
    -- field 403 = _field_name3 → canonical "FieldName3".
    -- tag = (403<<3)|0 = 3224 → varint 0x98 0x19.
    local resp = json_to_pb([[{"FieldName3": 3}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '\x98\x19\x03')
end

core_g.test_json_decode_camel_case_trailing_underscore_drops = function()
    -- field 417 = field_name17__ → canonical "fieldName17".
    -- tag = (417<<3)|0 = 3336 → varint 0x88 0x1a.
    local resp = json_to_pb([[{"fieldName17": 17}]])
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.protobuf_payload, '\x88\x1a\x11')
end

-- =========================================================================
-- Fix 11: google.protobuf.NullValue descriptor exposed so enum fields
-- whose type is NullValue (e.g. oneof_null_value, or Value.null_value)
-- can be decoded from JSON without indexing a nil descriptor.
-- =========================================================================

core_g.test_oneof_null_value_decodes_from_json = function()
    -- oneof_null_value is the singleton enum NullValue (NULL_VALUE=0). With
    -- the descriptor in place, decode_enum can resolve "NULL_VALUE" → 0.
    -- Field 120, tag (120<<3)|0 = 960 → varint 0xc0 0x07. Value 0 elides.
    -- Empty payload is the expected output for a 0-valued enum in a oneof
    -- — except this is a oneof branch with explicit presence, so it WILL
    -- emit. Either way, we want no parse_error.
    local resp = json_to_pb([[{"oneofNullValue": "NULL_VALUE"}]])
    t.assert_not(resp.parse_error, resp.parse_error)
end

core_g.test_oneof_merge_still_clears_sibling_branches = function()
    -- The post-fix merge code must still clear oneof siblings: setting
    -- oneof_uint32 first, then merging two oneof_nested_message entries,
    -- must leave oneof_uint32 cleared in the result.
    local sub1 = proto3.TestAllTypesProto3_NestedMessage_encode({a = 1})
    local sub2 = proto3.TestAllTypesProto3_NestedMessage_encode({a = 2})
    local input = '\xf8\x06\x09'             -- tag(111, VARINT) oneof_uint32 = 9
                .. dup_msg('\x82\x07', sub1, sub2)
    local resp = pb_roundtrip(input)
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.oneof_uint32, nil,
        'oneof sibling must be cleared after the message branch is set')
    t.assert_equals(decoded.oneof_nested_message.a, 2)
end

-- =========================================================================
-- Fix 12: strict JSON scalar validation. proto3 spec rejects every shape
-- of malformed numeric/string scalar input. We pin one example per
-- distinct rejection path (per type, per shape) instead of enumerating
-- the full conformance matrix — the validator code path is shared.
-- =========================================================================

local function pb_to_json(pb_bytes)
    return decode_resp(core.handle_request(encode_req({
        protobuf_payload = pb_bytes,
        requested_output_format = JSON,
        message_type = PROTO3_NAME,
    })))
end

core_g.test_json_int32_rejects_empty_string = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":""}').parse_error, nil)
end

core_g.test_json_int32_rejects_leading_space = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":" 1"}').parse_error, nil)
end

core_g.test_json_int32_rejects_partial_numeric = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":"1abc"}').parse_error, nil)
end

core_g.test_json_int32_rejects_non_integer_number = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":1.5}').parse_error, nil)
end

core_g.test_json_int32_rejects_non_numeric_type = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":true}').parse_error, nil)
end

core_g.test_json_int32_rejects_out_of_range_high = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":2147483648}').parse_error, nil)
end

core_g.test_json_int32_rejects_out_of_range_low = function()
    t.assert_not_equals(json_to_pb('{"optionalInt32":-2147483649}').parse_error, nil)
end

core_g.test_json_int32_accepts_quoted_exponential = function()
    -- "1e5" must decode to 100000 — the JSON spec lets numbers in string
    -- form use exponential notation as long as the value is integer.
    local resp = json_to_pb('{"optionalInt32":"1e5"}')
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.optional_int32, 100000)
end

core_g.test_json_uint32_rejects_negative = function()
    t.assert_not_equals(json_to_pb('{"optionalUint32":-1}').parse_error, nil)
end

core_g.test_json_double_rejects_overflow_number = function()
    -- 1.79769e+309 overflows IEEE 754 → inf, which must be parse_error
    -- (NOT silently coerced to "Infinity").
    t.assert_not_equals(json_to_pb('{"optionalDouble":1.79769e309}').parse_error, nil)
end

core_g.test_json_double_rejects_partial_numeric_string = function()
    t.assert_not_equals(json_to_pb('{"optionalDouble":"1.0abc"}').parse_error, nil)
end

core_g.test_json_bool_rejects_string = function()
    t.assert_not_equals(json_to_pb('{"optionalBool":"true"}').parse_error, nil)
end

core_g.test_json_string_rejects_number = function()
    t.assert_not_equals(json_to_pb('{"optionalString":123}').parse_error, nil)
end

core_g.test_json_repeated_rejects_object = function()
    -- A repeated field must be a JSON array; an object is malformed.
    t.assert_not_equals(json_to_pb(
        '{"repeatedNestedMessage":{"a":1}}').parse_error, nil)
end

core_g.test_json_oneof_rejects_duplicate_branches = function()
    -- Setting two branches of the same oneof in one JSON object is a
    -- parse_error per the proto3 JSON spec.
    t.assert_not_equals(json_to_pb(
        '{"oneofUint32":1,"oneofString":"x"}').parse_error, nil)
end

core_g.test_json_oneof_null_branch_does_not_count = function()
    -- A null-valued oneof branch counts as "absent", so a second non-null
    -- branch in the same object is the only set branch (not a duplicate).
    local resp = json_to_pb(
        '{"oneofUint32":null,"oneofString":"x"}')
    t.assert_not(resp.parse_error, resp.parse_error)
    local decoded = proto3.TestAllTypesProto3_decode(resp.protobuf_payload)
    t.assert_equals(decoded.oneof_string, 'x')
    t.assert_equals(decoded.oneof_uint32, nil)
end

core_g.test_json_top_level_null_rejected_for_messages = function()
    -- Decoding `null` for a regular message is a parse_error. The lone
    -- exception is google.protobuf.Value (covered by json_test.lua).
    local req = encode_req({
        json_payload = 'null',
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })
    t.assert_not_equals(decode_resp(core.handle_request(req)).parse_error, nil)
end

-- =========================================================================
-- Fix 13: strict Timestamp parser + canonical output. Strict format
-- (uppercase T/Z, colon in offset, max 9 frac digits, range check).
-- Output uses a portable epoch_to_ymdhms so years 0001-9999 always pad
-- to 4 digits — glibc's POSIX %Y emits "1" for year 1, which the
-- conformance harness can't parse back.
-- =========================================================================

local function json_round_trip(json_str)
    return decode_resp(core.handle_request(encode_req({
        json_payload = json_str,
        requested_output_format = JSON,
        message_type = PROTO3_NAME,
    })))
end

core_g.test_json_timestamp_rejects_lowercase_t = function()
    t.assert_not_equals(json_to_pb(
        '{"optionalTimestamp":"1970-01-01t00:00:00Z"}').parse_error, nil)
end

core_g.test_json_timestamp_rejects_lowercase_z = function()
    t.assert_not_equals(json_to_pb(
        '{"optionalTimestamp":"1970-01-01T00:00:00z"}').parse_error, nil)
end

core_g.test_json_timestamp_rejects_missing_z_and_offset = function()
    t.assert_not_equals(json_to_pb(
        '{"optionalTimestamp":"1970-01-01T00:00:00"}').parse_error, nil)
end

core_g.test_json_timestamp_rejects_offset_without_colon = function()
    t.assert_not_equals(json_to_pb(
        '{"optionalTimestamp":"1970-01-01T00:00:00+0100"}').parse_error, nil)
end

core_g.test_json_timestamp_min_value_round_trips = function()
    -- Year 0001 must pad to 4 digits ("0001-...") on output. POSIX %Y on
    -- glibc emits just "1" for that year, which would break round-trip.
    local resp = json_round_trip(
        '{"optionalTimestamp":"0001-01-01T00:00:00Z"}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '0001-01-01T00:00:00Z')
end

core_g.test_json_timestamp_normalizes_offset_to_utc = function()
    -- "+01:00" offset must be applied to compute the UTC epoch, then the
    -- output must use "Z" form. 12:00:00+01:00 == 11:00:00 UTC.
    local resp = json_round_trip(
        '{"optionalTimestamp":"2020-01-01T12:00:00+01:00"}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '2020-01-01T11:00:00Z')
end

core_g.test_proto_timestamp_negative_nanos_serialize_error = function()
    -- Binary input with nanos = -1 is a valid wire shape but per spec
    -- the JSON serializer must reject it (Timestamp.nanos >= 0).
    -- optional_timestamp (id 302), tag (302<<3)|2 = 0xf2 0x12.
    -- Inner Timestamp: tag(2, VARINT) nanos=-1 (10-byte int32 form).
    local nanos_field = '\x10' .. '\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01'
    local input = '\xf2\x12' .. string.char(#nanos_field) .. nanos_field
    local resp = pb_to_json(input)
    t.assert_not_equals(resp.serialize_error, nil)
end

-- =========================================================================
-- Fix 14: strict Duration parser + canonical output. Suffix "s" is
-- mandatory; range is ±10000 years; nanos sign must match seconds.
-- Fractional output uses 0/3/6/9 digits.
-- =========================================================================

core_g.test_json_duration_rejects_missing_s_suffix = function()
    t.assert_not_equals(json_to_pb(
        '{"optionalDuration":"1.5"}').parse_error, nil)
end

core_g.test_json_duration_rejects_out_of_range = function()
    -- Spec: seconds within ±315576000000.
    t.assert_not_equals(json_to_pb(
        '{"optionalDuration":"315576000001s"}').parse_error, nil)
end

core_g.test_proto_duration_negative_nanos_canonical_output = function()
    -- Encoded Duration with seconds=0, nanos=-500000000 must serialize
    -- as "-0.500s" with both sign and 3-digit fraction.
    -- optional_duration (id 301), tag (301<<3)|2 = 0xea 0x12.
    -- Inner: tag(2,VARINT)=0x10 + nanos as 10-byte int32 -500000000.
    local nanos_field = '\x10\x80\xb6\xca\x91\xfe\xff\xff\xff\xff\x01'
    local input = '\xea\x12' .. string.char(#nanos_field) .. nanos_field
    local resp = pb_to_json(input)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_str_contains(resp.json_payload, '-0.500s')
end

-- =========================================================================
-- Fix 15: Any JSON output rules.
--   - Empty Any (no @type, no value) → emit `{}`.
--   - URL with no `/` is malformed (AnyWktRepresentationWithBadType).
--   - WKT-typed Any nests payload under "value"; user-typed Any flattens.
--   - Empty WKT inside Any drops the "value" key (reference parser
--     rejects {"value":{}} for Empty).
-- =========================================================================

core_g.test_json_any_empty_round_trips_as_empty_object = function()
    local resp = json_round_trip('{"optionalAny":{}}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '"optionalAny":{}')
end

core_g.test_json_any_with_only_empty_wkt_type_emits_no_value = function()
    -- Round-trip pins the reference-implementation expectation that
    -- {"@type":".../Empty"} stays in that shape (not promoted to
    -- {"@type":".../Empty","value":{}}).
    local resp = json_round_trip(
        '{"optionalAny":{"@type":"type.googleapis.com/google.protobuf.Empty"}}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload,
        '"@type":"type.googleapis.com/google.protobuf.Empty"')
    t.assert_not(resp.json_payload:find('"value"', 1, true),
        'Empty WKT in Any must not emit a "value" key')
end

core_g.test_json_any_rejects_malformed_url = function()
    -- @type without a `/` is malformed (AnyWktRepresentationWithBadType).
    t.assert_not_equals(json_to_pb(
        '{"optionalAny":{"@type":"not_a_url","value":""}}').parse_error, nil)
end

core_g.test_json_any_rejects_empty_type_with_sibling_fields = function()
    t.assert_not_equals(json_to_pb(
        '{"optionalAny":{"@type":"","value":""}}').parse_error, nil)
end

core_g.test_json_any_wkt_struct_nests_under_value = function()
    -- A WKT payload must be wrapped: {"@type":"...Struct","value":{...}}
    -- — flattening the struct fields next to "@type" is wrong because
    -- "@type" would clash with a user "@type" key inside the struct.
    local resp = json_round_trip(
        '{"optionalAny":{"@type":"type.googleapis.com/google.protobuf.Struct","value":{"k":"v"}}}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '"value":{"k":"v"}')
end

-- =========================================================================
-- Fix 16: google.protobuf.Value's number_value cannot represent NaN or
-- ±Infinity (JSON has no such literals). The serializer must reject.
-- =========================================================================

core_g.test_json_value_nan_serialize_error = function()
    -- optional_value (id 306), tag (306<<3)|2 = 0x92 0x13.
    -- Inner Value: tag(2,I64)=0x11 + NaN bytes.
    local value_payload = '\x11\x00\x00\x00\x00\x00\x00\xf8\x7f'
    local input = '\x92\x13' .. string.char(#value_payload) .. value_payload
    local resp = pb_to_json(input)
    t.assert_not_equals(resp.serialize_error, nil)
end

core_g.test_json_value_infinity_serialize_error = function()
    -- Value.number_value = +Infinity (bit pattern 0x7FF0000000000000)
    local value_payload = '\x11\x00\x00\x00\x00\x00\x00\xf0\x7f'
    local input = '\x92\x13' .. string.char(#value_payload) .. value_payload
    local resp = pb_to_json(input)
    t.assert_not_equals(resp.serialize_error, nil)
end

-- =========================================================================
-- Fix 17: ValueAcceptNull round-trips JSON `null` for a Value-typed
-- field. The decode side preserves it as PB_NULL (box.NULL); the encode
-- side must walk past `box.NULL == nil` (rawequal, not `==`).
-- =========================================================================

core_g.test_json_value_accept_null_round_trips = function()
    local resp = json_round_trip('{"optionalValue":null}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '"optionalValue":null')
end

-- =========================================================================
-- Fix 18: LuaJIT NaN-boxing collision. Certain IEEE NaN bit patterns
-- alias internal Lua type tags (nil, function, …) when read through
-- ffi.cast — tonumber returns a non-number for those values. The wire
-- decoder must detect NaN/Inf from the integer bit pattern before
-- touching the float field.
-- =========================================================================

core_g.test_wire_double_nan_box_collision_normalizes_to_nan = function()
    -- 0x7FFBCBA987654321 — the specific bit pattern observed crashing
    -- DoubleFieldNormalizeSignalingNan.JsonOutput in the conformance
    -- suite. Must produce "NaN" without serialize_error.
    local input = '\x61\x21\x43\x65\x87\xa9\xcb\xfb\xff'
    local resp = pb_to_json(input)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_str_contains(resp.json_payload, '"optionalDouble":"NaN"')
end

core_g.test_wire_double_all_ones_normalizes_to_nan = function()
    -- 0xFFFFFFFFFFFFFFFF triggered the NaN-boxing collision pre-fix
    -- (tonumber returned nil → field silently dropped).
    local input = '\x61\xff\xff\xff\xff\xff\xff\xff\xff'
    local resp = pb_to_json(input)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_str_contains(resp.json_payload, '"optionalDouble":"NaN"')
end

core_g.test_wire_double_positive_infinity_decodes = function()
    -- 0x7FF0000000000000 → +Infinity. Bit-pattern detection must
    -- distinguish Inf from NaN.
    local input = '\x61\x00\x00\x00\x00\x00\x00\xf0\x7f'
    local resp = pb_to_json(input)
    t.assert_str_contains(resp.json_payload, '"optionalDouble":"Infinity"')
end

core_g.test_wire_float_sNaN_normalizes_to_nan = function()
    -- 0x7FBFFFFF — classic single-precision signaling NaN.
    local input = '\x5d\xff\xff\xbf\x7f'
    local resp = pb_to_json(input)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_str_contains(resp.json_payload, '"optionalFloat":"NaN"')
end

-- =========================================================================
-- Fix 19: hand-rolled JSON encoder for shortest round-trip doubles.
-- Tarantool's json.encode uses a fixed global precision (14 by default)
-- so doubles like 0.1 don't round-trip; we emit them via a custom
-- precision-escalating formatter. Pin a few specific values.
-- =========================================================================

core_g.test_json_double_shortest_round_trip = function()
    -- 0.1 doesn't have an exact double representation; %.14g would drop
    -- the precision-bearing trailing digit. We need %.17g (or shortest)
    -- so the value survives JSON → proto → JSON.
    local resp = json_round_trip('{"optionalDouble":0.1}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '0.1')
end

core_g.test_json_double_integer_valued_emitted_without_decimal = function()
    -- Integer-valued doubles in safe-int range emit without a decimal
    -- point. (json.encode would write "1" too, but the hand-rolled path
    -- has its own integer fast path — pin it.)
    local resp = json_round_trip('{"optionalDouble":1.0}')
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.json_payload, '"optionalDouble":1')
end

-- =========================================================================
-- Unknown-field text-format regressions.
--
-- Mirrors the eight Recommended.Proto3.ProtobufInput.*UnknownFields_*.
-- TextFormatOutput tests in the Google harness so we can iterate on the
-- runtime without the Docker round-trip. Each test sends the *exact*
-- bytes the conformance suite sends, runs through cmd/conformance/core,
-- and asserts what we produce today plus the target our text encoder
-- should produce once unknown-field rendering / group skipping land.
--
-- Field numbers (from src/google/protobuf/test_messages_proto2.proto
-- `UnknownToTestAllTypes`, used to build the input payloads):
--   1001 optional_int32       1004 OptionalGroup (group)
--   1002 optional_string      1006 optional_bool
--   1003 nested_message (LEN) 1011 repeated_int32 (unpacked)
-- None of these IDs exist in TestAllTypesProto3 so the receiver sees
-- them as unknown fields.
--
-- The Google harness compares semantically via MessageDifferencer after
-- re-parsing our text output with AllowFieldNumber(true). It accepts any
-- text that round-trips to a message with the same field set, so
-- numeric field IDs (e.g. `1001: 123`) are the canonical rendering for
-- types unknown to the testee.
-- =========================================================================

local function pb_to_text(input)
    return decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = TEXT,
        message_type = PROTO3_NAME,
    })))
end

local function pb_to_text_print_unknowns(input)
    return decode_resp(core.handle_request(encode_req({
        protobuf_payload = input,
        requested_output_format = TEXT,
        message_type = PROTO3_NAME,
        print_unknown_fields = true,
    })))
end

-- Payload helpers — same bytes the upstream conformance suite produces.
local SCALAR_UNKNOWN  = '\xc8\x3e\x7b'                       -- field 1001 varint 123
                     .. '\xd2\x3e\x05hello'                  -- field 1002 LEN "hello"
                     .. '\xf0\x3e\x01'                       -- field 1006 varint 1 (bool)
local MESSAGE_UNKNOWN = '\xda\x3e\x02\x08\x6f'               -- field 1003 LEN {1:111}
local GROUP_UNKNOWN   = '\xe3\x3e\x08\xc1\x02\xe4\x3e'       -- field 1004 SGROUP {a:321} EGROUP
-- Repeated builds on Group then appends three repeated_int32 entries.
-- Tag for field 1011 (varint): 1011*8 = 8088 = 24 | (63 << 7) = `\x98\x3f`.
local REPEATED_UNKNOWN = GROUP_UNKNOWN
                      .. '\x98\x3f\x01\x98\x3f\x02\x98\x3f\x03'

core_g.test_scalar_unknown_fields_drop = function()
    -- ProtobufInput.ScalarUnknownFields_Drop.TextFormatOutput
    -- print_unknown_fields=false → unknowns dropped → text empty.
    local resp = pb_to_text(SCALAR_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_equals(resp.text_payload, '')
end

core_g.test_scalar_unknown_fields_print = function()
    -- ProtobufInput.ScalarUnknownFields_Print.TextFormatOutput
    -- Numeric field-ID form; LEN payload that doesn't parse as a
    -- sub-message falls back to byte-string rendering ("hello" here).
    local resp = pb_to_text_print_unknowns(SCALAR_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_not(resp.serialize_error, resp.serialize_error)
    t.assert_str_contains(resp.text_payload, '1001: 123')
    t.assert_str_contains(resp.text_payload, '1002: "hello"')
    t.assert_str_contains(resp.text_payload, '1006: 1')
end

core_g.test_message_unknown_fields_drop = function()
    -- ProtobufInput.MessageUnknownFields_Drop.TextFormatOutput
    local resp = pb_to_text(MESSAGE_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.text_payload, '')
end

core_g.test_message_unknown_fields_print = function()
    -- ProtobufInput.MessageUnknownFields_Print.TextFormatOutput
    -- LEN payload parses cleanly as a sub-message ({c:111}), so the
    -- speculative block-form succeeds: "1003 { 1: 111 }".
    local resp = pb_to_text_print_unknowns(MESSAGE_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.text_payload, '1003 {')
    t.assert_str_contains(resp.text_payload, '1: 111')
end

core_g.test_group_unknown_fields_drop = function()
    -- ProtobufInput.GroupUnknownFields_Drop.TextFormatOutput
    -- Wire 3/4 are proto2 groups; the proto3 decoder must skip them
    -- (wire.skip_field recurses on SGROUP until matching EGROUP).
    local resp = pb_to_text(GROUP_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.text_payload, '')
end

core_g.test_group_unknown_fields_print = function()
    -- ProtobufInput.GroupUnknownFields_Print.TextFormatOutput
    -- Group bytes are captured verbatim (SGROUP..EGROUP); the renderer
    -- recurses through them and emits "1004 { 1: 321 }".
    local resp = pb_to_text_print_unknowns(GROUP_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.text_payload, '1004 {')
    t.assert_str_contains(resp.text_payload, '1: 321')
end

core_g.test_repeated_unknown_fields_drop = function()
    -- ProtobufInput.RepeatedUnknownFields_Drop.TextFormatOutput
    -- Payload starts with the same group bytes; after SGROUP-skip the
    -- repeated_int32 unknowns drop cleanly too.
    local resp = pb_to_text(REPEATED_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_equals(resp.text_payload, '')
end

core_g.test_repeated_unknown_fields_print = function()
    -- ProtobufInput.RepeatedUnknownFields_Print.TextFormatOutput
    -- Group bytes followed by three repeated-int32 entries. Each varint
    -- becomes its own "<id>: <value>" line.
    local resp = pb_to_text_print_unknowns(REPEATED_UNKNOWN)
    t.assert_not(resp.parse_error, resp.parse_error)
    t.assert_str_contains(resp.text_payload, '1004 {')
    t.assert_str_contains(resp.text_payload, '1: 321')
    t.assert_str_contains(resp.text_payload, '1011: 1')
    t.assert_str_contains(resp.text_payload, '1011: 2')
    t.assert_str_contains(resp.text_payload, '1011: 3')
end

-- ---------------------------------------------------------------------------
-- 2. Subprocess: stdin/stdout framing
-- ---------------------------------------------------------------------------
--
-- These tests verify only the framing wrapper in cmd/conformance-runner.lua;
-- the dispatch logic is fully covered by the `core` group above.

local sub_g = t.group('conformance.subprocess')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local RUNNER = fio.pathjoin(REPO_ROOT, 'cmd', 'conformance-runner.lua')

local function le32(n)
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256)
end

local function read_le32(s, off)
    local b1, b2, b3, b4 = s:byte(off, off + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Run the runner with `input_bytes` piped to stdin, return the raw stdout.
local function run_runner(input_bytes)
    local in_path  = os.tmpname()
    local out_path = os.tmpname()
    local err_path = os.tmpname()
    local fin = assert(io.open(in_path, 'wb'))
    fin:write(input_bytes); fin:close()

    local lua_path = os.getenv('LUA_PATH') or ''
    local cmd = string.format(
        'cd %q && LUA_PATH=%q tarantool cmd/conformance-runner.lua < %q > %q 2> %q',
        REPO_ROOT, lua_path, in_path, out_path, err_path)
    local rc = os.execute(cmd)

    local fout = assert(io.open(out_path, 'rb'))
    local out  = fout:read('*a'); fout:close()
    local ferr = io.open(err_path, 'r')
    local err  = ferr and ferr:read('*a') or ''
    if ferr then ferr:close() end
    os.remove(in_path); os.remove(out_path); os.remove(err_path)
    return rc, out, err
end

-- Parse a stream of length-prefixed responses out of `bytes`.
local function parse_framed(bytes)
    local out, off = {}, 1
    while off + 4 <= #bytes + 1 do
        local n = read_le32(bytes, off)
        off = off + 4
        if off + n - 1 > #bytes then break end
        out[#out + 1] = bytes:sub(off, off + n - 1)
        off = off + n
    end
    return out, off
end

sub_g.test_single_request_round_trip = function()
    local req = encode_req({
        protobuf_payload = '',
        requested_output_format = PROTOBUF,
        message_type = 'conformance.FailureSet',
    })
    local framed = le32(#req) .. req
    local rc, out, err = run_runner(framed)
    t.assert_equals(rc, 0, 'runner exited non-zero, stderr=' .. err)
    local resps = parse_framed(out)
    t.assert_equals(#resps, 1, 'expected 1 framed response, stderr=' .. err)
    local resp = decode_resp(resps[1])
    t.assert_equals(resp.protobuf_payload, '')
end

sub_g.test_multiple_requests_in_one_session = function()
    -- The conformance runner sends many requests over a single pipe; the
    -- script must loop until EOF rather than handle one and exit.
    local req1 = encode_req({
        protobuf_payload = '',
        requested_output_format = PROTOBUF,
        message_type = 'conformance.FailureSet',
    })
    local payload = proto3.TestAllTypesProto3_encode({optional_int32 = 17})
    local req2 = encode_req({
        protobuf_payload = payload,
        requested_output_format = PROTOBUF,
        message_type = PROTO3_NAME,
    })
    local req3 = encode_req({
        json_payload = [[{"optionalInt32": 99}]],
        requested_output_format = JSON,
        message_type = PROTO3_NAME,
    })

    local framed = le32(#req1) .. req1
                .. le32(#req2) .. req2
                .. le32(#req3) .. req3
    local rc, out, err = run_runner(framed)
    t.assert_equals(rc, 0, 'runner exited non-zero, stderr=' .. err)
    local resps = parse_framed(out)
    t.assert_equals(#resps, 3, 'expected 3 framed responses, stderr=' .. err)

    local r1 = decode_resp(resps[1])
    local r2 = decode_resp(resps[2])
    local r3 = decode_resp(resps[3])
    t.assert_equals(r1.protobuf_payload, '')
    t.assert_equals(r2.protobuf_payload, payload)
    t.assert_str_contains(r3.json_payload, '"optionalInt32":99')
end

sub_g.test_empty_stdin_clean_exit = function()
    local rc, out, err = run_runner('')
    t.assert_equals(rc, 0, 'runner exited non-zero, stderr=' .. err)
    t.assert_equals(out, '', 'unexpected output on empty stdin')
end
