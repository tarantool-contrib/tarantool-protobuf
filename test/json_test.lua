-- proto3 JSON mapping tests.
local t = require('luatest')
local ffi = require('ffi')
local pb = require('pb')
local json = require('json')
local hello = require('full.hello.hello_pb')

local function reparse(s) return json.decode(s) end

local g = t.group('json.scalars')

g.test_basic_round_trip = function()
    local p = {name = 'Alice', age = 30}
    local enc = pb.json.encode(hello.Person_descriptor, p)
    local obj = reparse(enc)
    t.assert_equals(obj.name, 'Alice')
    t.assert_equals(obj.age, 30)
end

g.test_proto3_default_elision = function()
    -- Defaults are elided from JSON output unless presence is meaningful.
    local enc = pb.json.encode(hello.Person_descriptor, {age = 0, name = ''})
    t.assert_equals(reparse(enc), setmetatable({}, getmetatable(reparse('{}'))))
end

g.test_camel_case_field_names = function()
    local enc = pb.json.encode(hello.Person_descriptor, {user_id = ffi.cast('uint64_t', 1234567890123)})
    t.assert_str_contains(enc, '"userId"', 'field emitted in camelCase')
end

g.test_int64_as_string = function()
    local p = {user_id = ffi.cast('uint64_t', 12345678901234567890ULL)}
    local obj = reparse(pb.json.encode(hello.Person_descriptor, p))
    t.assert_equals(obj.userId, '12345678901234567890', 'uint64 stringified per spec')
end

g.test_bytes_base64 = function()
    local p = {avatar = '\x00\x01\xff'}
    local obj = reparse(pb.json.encode(hello.Person_descriptor, p))
    t.assert_equals(obj.avatar, 'AAH/')
    -- Round-trip
    local p2 = pb.json.decode(hello.Person_descriptor, pb.json.encode(hello.Person_descriptor, p))
    t.assert_equals(p2.avatar, p.avatar)
end

g.test_bytes_base64_unwrapped_long_payload = function()
    -- Canonical proto3 JSON requires RFC 4648 base64 with no line wrapping.
    -- Tarantool's digest.base64_encode defaults to MIME-style 76-char wrap,
    -- so any payload past ~57 bytes used to emit a `\n` inside the JSON
    -- string and break grpc-gateway / protojson consumers.
    local p = {avatar = string.rep('A', 64)}
    local enc = pb.json.encode(hello.Person_descriptor, p)
    t.assert_not_str_contains(enc, '\n', 'no raw newline anywhere in JSON output')
    t.assert_not_str_contains(enc, '\\n', 'no escaped newline in base64 token')
    local obj = reparse(enc)
    t.assert_not_str_contains(obj.avatar, '\n', 'base64 token is a single line')
    local p2 = pb.json.decode(hello.Person_descriptor, enc)
    t.assert_equals(p2.avatar, p.avatar)
end

g.test_repeated_packed_scalar = function()
    local p = {lucky_numbers = {1, 2, 3}}
    local obj = reparse(pb.json.encode(hello.Person_descriptor, p))
    t.assert_equals(obj.luckyNumbers, {1, 2, 3})
end

g.test_repeated_string = function()
    local p = {emails = {'a@x', 'b@x'}}
    local obj = reparse(pb.json.encode(hello.Person_descriptor, p))
    t.assert_equals(obj.emails, {'a@x', 'b@x'})
end

g.test_enum_as_name = function()
    local enc = pb.json.encode(hello.Person_descriptor, {status = hello.Status.ERROR})
    t.assert_str_contains(enc, '"status":"ERROR"')
end

g.test_enum_string_input_accepted_on_decode = function()
    local p = pb.json.decode(hello.Person_descriptor, '{"status":"OK"}')
    t.assert_equals(p.status, hello.Status.OK)
end

g.test_snake_case_input_also_accepted = function()
    local p = pb.json.decode(hello.Person_descriptor, '{"user_id":"99"}')
    t.assert_equals(tonumber(p.user_id), 99)
end

g.test_nested_message_round_trip = function()
    local p = {name = 'P', address = {street = 'X', zip = 1}}
    local enc = pb.json.encode(hello.Person_descriptor, p)
    local back = pb.json.decode(hello.Person_descriptor, enc)
    t.assert_equals(back.name, 'P')
    t.assert_equals(back.address.street, 'X')
    t.assert_equals(back.address.zip, 1)
end

g.test_map_round_trip = function()
    local p = {ages_by_nickname = {alice = 30, bob = 25}}
    local back = pb.json.decode(hello.Person_descriptor,
        pb.json.encode(hello.Person_descriptor, p))
    t.assert_equals(back.ages_by_nickname.alice, 30)
    t.assert_equals(back.ages_by_nickname.bob, 25)
end

-- ---------------------------------------------------------------------------
-- WKT
-- ---------------------------------------------------------------------------
local gwkt = t.group('json.wkt')

gwkt.test_timestamp_iso_8601 = function()
    local datetime = require('datetime')
    local dt = datetime.new({timestamp = 1700000000, nsec = 123456789})
    local enc = pb.json.encode(hello.Event_descriptor, {created_at = dt})
    local obj = reparse(enc)
    -- Tarantool's datetime tostring is ISO 8601: "2023-11-14T22:13:20.123456789Z"
    t.assert_str_matches(obj.createdAt, '^%d%d%d%d%-%d%d%-%d%dT.+Z$')
    local back = pb.json.decode(hello.Event_descriptor, enc)
    t.assert(datetime.is_datetime(back.created_at))
    t.assert_equals(back.created_at.epoch, 1700000000)
    t.assert_equals(back.created_at.nsec, 123456789)
end

gwkt.test_duration_string = function()
    local enc = pb.json.encode(hello.Event_descriptor, {duration = {seconds = 5, nanos = 0}})
    local obj = reparse(enc)
    t.assert_equals(obj.duration, '5s')

    local enc2 = pb.json.encode(hello.Event_descriptor, {duration = {seconds = 5, nanos = 1}})
    t.assert_equals(reparse(enc2).duration, '5.000000001s')

    local back = pb.json.decode(hello.Event_descriptor, enc2)
    t.assert_equals(tonumber(back.duration.seconds), 5)
    t.assert_equals(back.duration.nanos, 1)
end

gwkt.test_empty = function()
    local enc = pb.json.encode(hello.Event_descriptor, {ack = {}})
    local obj = reparse(enc)
    t.assert_equals(type(obj.ack), 'table')
end

gwkt.test_wrappers_unwrap = function()
    local enc = pb.json.encode(hello.Event_descriptor, {
        retry_count = 5,
        note = 'remember',
        is_admin = true,
    })
    local obj = reparse(enc)
    t.assert_equals(obj.retryCount, 5,    'Int32Value unwrapped on encode')
    t.assert_equals(obj.note,       'remember', 'StringValue unwrapped')
    t.assert_equals(obj.isAdmin,    true, 'BoolValue unwrapped')

    -- Zero-value wrappers preserve presence: round-trip through JSON.
    local enc0 = pb.json.encode(hello.Event_descriptor, {retry_count = 0})
    t.assert_equals(reparse(enc0).retryCount, 0)

    local back = pb.json.decode(hello.Event_descriptor, enc)
    t.assert_equals(back.retry_count, 5)
    t.assert_equals(back.note, 'remember')
    t.assert_equals(back.is_admin, true)
end

-- ---------------------------------------------------------------------------
-- Struct / Value / ListValue
-- ---------------------------------------------------------------------------
local gsv = t.group('json.struct_value')

gsv.test_struct_field_emits_object = function()
    local enc = pb.json.encode(hello.Event_descriptor, {
        payload = pb.wkt.struct({k = 'v', n = 42, on = true}),
    })
    local obj = reparse(enc)
    t.assert_equals(type(obj.payload), 'table')
    t.assert_equals(obj.payload.k, 'v')
    t.assert_equals(obj.payload.n, 42)
    t.assert_equals(obj.payload.on, true)
end

gsv.test_value_field_dispatches_on_lua_type = function()
    local cases = {
        {input = 'hello',  expect = 'hello'},
        {input = 42,       expect = 42},
        {input = true,     expect = true},
        {input = pb.NULL,  expect = box.NULL},
    }
    for _, c in ipairs(cases) do
        local enc = pb.json.encode(hello.Event_descriptor, {attribute = c.input})
        local obj = reparse(enc)
        t.assert_equals(obj.attribute, c.expect)
    end
end

gsv.test_list_value_field_emits_array = function()
    local enc = pb.json.encode(hello.Event_descriptor, {
        tags = pb.wkt.list({'alpha', 7, false, pb.NULL}),
    })
    local obj = reparse(enc)
    t.assert_equals(#obj.tags, 4)
    t.assert_equals(obj.tags[1], 'alpha')
    t.assert_equals(obj.tags[2], 7)
    t.assert_equals(obj.tags[3], false)
    t.assert_equals(obj.tags[4], box.NULL)
end

gsv.test_struct_value_json_round_trip = function()
    local e = {
        payload   = pb.wkt.struct({nested = pb.wkt.struct({k = 1})}),
        attribute = pb.wkt.list({'a', 'b'}),
        tags      = pb.wkt.list({pb.NULL, true, 'x'}),
    }
    local enc = pb.json.encode(hello.Event_descriptor, e)
    local back = pb.json.decode(hello.Event_descriptor, enc)
    t.assert_equals(back.payload.nested.k, 1)
    t.assert_equals(back.attribute[1], 'a')
    t.assert_equals(back.attribute[2], 'b')
    t.assert_equals(back.tags[1], pb.NULL)
    t.assert_equals(back.tags[2], true)
    t.assert_equals(back.tags[3], 'x')
end

gsv.test_decode_json_null_is_pb_null_in_value = function()
    -- Top-level Value: decode a literal JSON null.
    local v = pb.json.decode(pb.wkt.Value_descriptor, 'null')
    t.assert_equals(v, pb.NULL)
end

-- ---------------------------------------------------------------------------
-- Oneof
-- ---------------------------------------------------------------------------
local gone = t.group('json.oneof')

gone.test_oneof_branch_emitted = function()
    local enc = pb.json.encode(hello.Result_descriptor, {id = 7, text = 'hi'})
    local obj = reparse(enc)
    t.assert_equals(obj.id, 7)
    t.assert_equals(obj.text, 'hi')
    t.assert_equals(obj.code, nil)
    t.assert_equals(obj.details, nil)
end

gone.test_oneof_default_value_branch = function()
    -- text='' is the proto3 default for string but presence is meaningful
    -- inside an oneof: it must survive JSON round-trip.
    local enc = pb.json.encode(hello.Result_descriptor, {text = ''})
    t.assert_str_contains(enc, '"text"')
    local back = pb.json.decode(hello.Result_descriptor, enc)
    t.assert_equals(back.text, '')
end

-- ---------------------------------------------------------------------------
-- Strict validation (regression tests pinning the proto3 conformance pass)
-- ---------------------------------------------------------------------------
local gstrict = t.group('json.strict')
local proto3 = require('full.protobuf_test_messages.proto3.test_messages_proto3_pb')
local P3 = proto3.TestAllTypesProto3_descriptor

gstrict.test_duplicate_literal_keys_rejected = function()
    -- Tarantool's json.decode silently keeps the last value of a duplicate
    -- key; the find_duplicate_json_keys pre-scan in M.decode catches them.
    -- Pins Recommended.Proto3.JsonInput.FieldNameDuplicate.
    local ok, err = pcall(pb.json.decode, P3,
        '{"optionalInt32": 1, "optionalInt32": 2}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'duplicate JSON key')
end

gstrict.test_duplicate_camel_snake_aliases_rejected = function()
    -- Both `optional_nested_message` (snake) and `optionalNestedMessage`
    -- (camel) refer to the same proto field. Mainline rejects, even
    -- though Lua's hash sees them as distinct keys.
    local ok, err = pcall(pb.json.decode, P3, [[{
        "optional_nested_message": {"a": 1},
        "optionalNestedMessage":   {"a": 2}
    }]])
    t.assert_not(ok)
    t.assert_str_contains(err, 'duplicate field')
end

gstrict.test_duplicate_keys_in_nested_object_rejected = function()
    -- The pre-scan tracks per-object frames; duplicate inside a nested
    -- object must trigger even if the outer keys are unique.
    local ok, err = pcall(pb.json.decode, P3,
        '{"optionalNestedMessage": {"a": 1, "a": 2}}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'duplicate JSON key')
end

gstrict.test_repeated_primitive_element_null_rejected = function()
    local ok, err = pcall(pb.json.decode, P3,
        '{"repeatedInt32": [1, null, 2]}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'JSON null')
end

gstrict.test_repeated_message_element_null_rejected = function()
    local ok, err = pcall(pb.json.decode, P3,
        '{"repeatedNestedMessage": [{"a":1}, null]}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'JSON null')
end

gstrict.test_map_value_null_rejected = function()
    local ok, err = pcall(pb.json.decode, P3,
        '{"mapInt32Int32": {"0": null}}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'JSON null')
end

gstrict.test_unknown_enum_name_rejected_singular = function()
    local ok, err = pcall(pb.json.decode, P3,
        '{"optionalNestedEnum": "DEFINITELY_NOT_A_VALUE"}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'unknown enum value')
end

gstrict.test_unknown_enum_name_rejected_in_repeated = function()
    local ok, err = pcall(pb.json.decode, P3,
        '{"repeatedNestedEnum": ["FOO", "NOPE"]}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'unknown enum value')
end

gstrict.test_unknown_enum_name_rejected_in_map_value = function()
    local ok, err = pcall(pb.json.decode, P3,
        '{"mapStringNestedEnum": {"k": "NOPE"}}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'unknown enum value')
end

gstrict.test_unknown_enum_name_silently_dropped_with_ignore = function()
    -- Under the `ignore_unknown_fields` opt (conformance category
    -- JSON_IGNORE_UNKNOWN_PARSING_TEST), unknown enum names are dropped
    -- from the result rather than raising — and other valid fields
    -- come through intact.
    local m = pb.json.decode(P3,
        '{"repeatedNestedEnum": ["FOO", "NOPE", "BAR"]}',
        {ignore_unknown_fields = true})
    t.assert_equals(m.repeated_nested_enum, {0, 1})
end

gstrict.test_unknown_enum_integer_passes_through = function()
    -- Unknown enum *integers* are forward-compat per proto3 — never
    -- rejected, never dropped, no flag needed.
    local m = pb.json.decode(P3, '{"optionalNestedEnum": 999}')
    t.assert_equals(m.optional_nested_enum, 999)
end

gstrict.test_null_value_oneof_set_by_json_null = function()
    -- NullValue-typed oneof member: input JSON `null` MUST mark the
    -- oneof as active (set to NULL_VALUE = 0). Mainline pins this via
    -- NullValueInOtherOneofNewFormat.Validator.
    local m = pb.json.decode(P3, '{"oneofNullValue": null}')
    t.assert_equals(m.oneof_null_value, 0)
end

gstrict.test_null_value_oneof_emits_json_null = function()
    -- Encode side: NullValue's JSON form is the literal null, not the
    -- enum string "NULL_VALUE". Pins NullValueInOtherOneofOldFormat.
    local enc = pb.json.encode(P3, {oneof_null_value = 0})
    t.assert_str_contains(enc, '"oneofNullValue":null')
end

gstrict.test_fieldmask_strict_paths_round_trip = function()
    -- snake_case input that round-trips cleanly through camelCase
    -- (lowercase letters + underscores before lowercase letters only).
    local enc = pb.json.encode(P3,
        {optional_field_mask = {'foo_bar', 'baz'}})
    t.assert_str_contains(enc, '"optionalFieldMask":"fooBar,baz"')
end

gstrict.test_fieldmask_rejects_uppercase_in_path = function()
    -- Path that's not already snake_case is malformed; would lose info
    -- on the round-trip. Pins FieldMaskPathsDontRoundTrip.
    local ok, err = pcall(pb.json.encode, P3,
        {optional_field_mask = {'fooBar'}})
    t.assert_not(ok)
    t.assert_str_contains(err, 'snake_case')
end

gstrict.test_fieldmask_rejects_double_underscore = function()
    -- "foo__bar" → "fooBar" → "foo_bar" — loses one underscore.
    -- Pins FieldMaskTooManyUnderscore.
    local ok, err = pcall(pb.json.encode, P3,
        {optional_field_mask = {'foo__bar'}})
    t.assert_not(ok)
    t.assert_str_contains(err, 'consecutive underscores')
end

gstrict.test_fieldmask_rejects_underscore_before_digit = function()
    -- "foo_3_bar" → "foo3Bar" → "foo3_bar" — irreversible.
    -- Pins FieldMaskNumbersDontRoundTrip.
    local ok, err = pcall(pb.json.encode, P3,
        {optional_field_mask = {'foo_3_bar'}})
    t.assert_not(ok)
    t.assert_str_contains(err, 'non-letter')
end

gstrict.test_fieldmask_rejects_underscore_in_json_input = function()
    -- JSON form must be lowerCamelCase; underscores are illegal in
    -- input. Pins FieldMaskInvalidCharacter.
    local ok, err = pcall(pb.json.decode, P3,
        '{"optionalFieldMask": "foo,bar_bar"}')
    t.assert_not(ok)
    t.assert_str_contains(err, 'underscore')
end

-- ---------------------------------------------------------------------------
-- M.encode(desc, t, opts): canonical proto3 JSON options
--   * use_proto_names  -> snake_case field names
--   * emit_defaults    -> zero scalars + empty containers preserved
--   * indent           -> pretty-printed output
--
-- Parameterized over both codegen modes. JSON encoding is driven by the
-- descriptor table, which is mode-independent by contract — running each
-- assertion against both `full` and `runtime` descriptors pins that
-- "one shape, four producers" guarantee for this surface.
-- ---------------------------------------------------------------------------
local MODES = {
    full    = require('full.hello.hello_pb'),
    runtime = require('runtime.hello.hello_pb'),
}

for mode, mod in pairs(MODES) do
    local gopts = t.group('json.encode_opts.' .. mode)
    local PERSON = mod.Person_descriptor

    gopts.test_use_proto_names_emits_snake_case = function()
        local enc = pb.json.encode(PERSON,
            {user_id = ffi.cast('uint64_t', 7), lucky_numbers = {1, 2}},
            {use_proto_names = true})
        t.assert_str_contains(enc, '"user_id"')
        t.assert_str_contains(enc, '"lucky_numbers"')
        t.assert_not_str_contains(enc, '"userId"')
        t.assert_not_str_contains(enc, '"luckyNumbers"')
    end

    gopts.test_use_proto_names_round_trips_via_decoder = function()
        -- The decoder accepts both spellings; this verifies that the
        -- snake_case output we just produced decodes back to the same shape.
        local original = {name = 'Bob', user_id = ffi.cast('uint64_t', 42)}
        local enc = pb.json.encode(PERSON, original, {use_proto_names = true})
        local p = pb.json.decode(PERSON, enc)
        t.assert_equals(p.name, 'Bob')
        t.assert_equals(p.user_id, ffi.cast('uint64_t', 42))
    end

    gopts.test_emit_defaults_keeps_zero_scalar_present_in_input = function()
        -- name = '' is the canonical regression: today this is silently
        -- dropped, breaking parity with grpc-gateway / etcd Status responses
        -- that explicitly carry a zero-valued field on the wire.
        local enc = pb.json.encode(PERSON,
            {name = '', age = 0}, {emit_defaults = true})
        local obj = reparse(enc)
        t.assert_equals(obj.name, '')
        t.assert_equals(obj.age, 0)
    end

    gopts.test_emit_defaults_synthesizes_absent_implicit_fields = function()
        -- Empty input table — every implicit-presence scalar gets a zero,
        -- every repeated becomes [], every map becomes {}. Optional/oneof
        -- fields stay absent (presence semantics).
        local enc = pb.json.encode(PERSON, {}, {emit_defaults = true})
        local obj = reparse(enc)
        t.assert_equals(obj.name, '')
        t.assert_equals(obj.age, 0)
        t.assert_equals(obj.emails, {})
        t.assert_equals(obj.luckyNumbers, {})
        -- Map fields emit as objects, not arrays.
        t.assert_equals(type(obj.agesByNickname), 'table')
        t.assert_equals(next(obj.agesByNickname), nil)
    end

    gopts.test_emit_defaults_alias_always_emit_zero_value = function()
        -- protojson v2 renamed the flag; accept both spellings.
        local enc = pb.json.encode(PERSON, {name = ''},
            {always_emit_zero_value = true})
        t.assert_str_contains(enc, '"name":""')
    end

    gopts.test_emit_defaults_skips_message_field = function()
        -- Singular message fields always have presence semantics in proto3;
        -- emit_defaults must not synthesize an empty object for them.
        local enc = pb.json.encode(PERSON, {}, {emit_defaults = true})
        t.assert_not_str_contains(enc, '"address"')
    end

    gopts.test_indent_pretty_prints = function()
        local enc = pb.json.encode(PERSON,
            {name = 'Alice', emails = {'a@x', 'b@x'}}, {indent = '  '})
        t.assert_str_contains(enc, '\n  "')
        -- Object keys land on their own indented lines.
        t.assert_str_contains(enc, '  "name": "Alice"')
        -- Round-trips through the JSON parser.
        t.assert_equals(reparse(enc).name, 'Alice')
        t.assert_equals(reparse(enc).emails, {'a@x', 'b@x'})
    end

    gopts.test_indent_empty_containers_stay_compact = function()
        local enc = pb.json.encode(PERSON,
            {emails = {}}, {emit_defaults = true, indent = '  '})
        t.assert_str_contains(enc, '"emails": []')
    end

    gopts.test_unknown_opts_key_is_ignored = function()
        -- Forward-compat: extra option keys must not error.
        local enc = pb.json.encode(PERSON, {name = 'Alice'},
            {some_future_option = true})
        t.assert_equals(reparse(enc).name, 'Alice')
    end

    gopts.test_opts_rejects_non_table = function()
        local ok, err = pcall(pb.json.encode, PERSON, {}, 'oops')
        t.assert_not(ok)
        t.assert_str_contains(err, 'opts must be a table')
    end
end

-- Direct cross-mode parity: identical input + opts must produce
-- byte-identical JSON regardless of which generator emitted the
-- descriptor. Catches a future divergence in the descriptor contract
-- that today's per-mode groups would mask (each runs in isolation).
local gparity = t.group('json.encode_opts.parity_full_vs_runtime')

local function assert_parity(input, opts)
    local a = pb.json.encode(MODES.full.Person_descriptor, input, opts)
    local b = pb.json.encode(MODES.runtime.Person_descriptor, input, opts)
    t.assert_equals(a, b, 'full vs runtime JSON diverged for opts='
                          .. require('json').encode(opts or {}))
end

gparity.test_use_proto_names = function()
    assert_parity({user_id = ffi.cast('uint64_t', 7), lucky_numbers = {1, 2}},
                  {use_proto_names = true})
end

gparity.test_emit_defaults_on_absent = function()
    assert_parity({}, {emit_defaults = true})
end

gparity.test_emit_defaults_on_present_zero = function()
    assert_parity({name = '', age = 0}, {emit_defaults = true})
end

gparity.test_indent = function()
    -- Indented output has stable formatting; the only nondeterminism in
    -- the encoder is `pairs` iteration order over the output object,
    -- which is keyed off Lua's hash. Both modes share the same hash, so
    -- the byte output stays equal.
    assert_parity({name = 'Alice', emails = {'a@x'}}, {indent = '  '})
end

-- encode_field / decode_field: one top-level field as a JSON document
-- (what HTTP transcoding needs for `response_body` and `body: "<field>"`).
local gfield = t.group('json.field')
local library = require('runtime.library.library_pb')

gfield.test_encode_field_message = function()
    local s = pb.json.encode_field(library.LookupBookResponse_descriptor,
        {book = {isbn = '42', title = 'T'}}, 'book')
    t.assert_equals(reparse(s), {isbn = '42', title = 'T'})
end

gfield.test_encode_field_repeated_and_defaults = function()
    local d = library.ListBooksResponse_descriptor
    local s = pb.json.encode_field(d, {books = {{name = 'a'}, {name = 'b'}}}, 'books')
    t.assert_equals(reparse(s), {{name = 'a'}, {name = 'b'}})
    t.assert_equals(pb.json.encode_field(d, {}, 'books'), '[]')
    t.assert_equals(pb.json.encode_field(d, {}, 'next_page_token'), '""')
    t.assert_equals(pb.json.encode_field(library.LookupBookResponse_descriptor, {}, 'book'), 'null')
end

-- An unset message field is null, including well-known types whose Lua
-- value is not a field table; set ones use their JSON form.
gfield.test_encode_field_unset_well_known_types = function()
    local m = pb.parse([[
        syntax = "proto3"; package jf;
        import "google/protobuf/wrappers.proto";
        import "google/protobuf/timestamp.proto";
        message R {
          google.protobuf.Int64Value count = 1;
          google.protobuf.StringValue label = 2;
          google.protobuf.Timestamp at = 3;
        }
    ]])
    local d = m.R_descriptor
    for _, name in ipairs({'count', 'label', 'at'}) do
        t.assert_equals(pb.json.encode_field(d, {}, name), 'null', name)
        t.assert_equals(pb.json.encode_field(d, {}, name, {emit_defaults = true}), 'null', name)
    end
    t.assert_equals(pb.json.encode_field(d, {count = 5LL}, 'count'), '"5"')
    t.assert_equals(pb.json.encode_field(d, {label = 'x'}, 'label'), '"x"')
    t.assert_equals(pb.json.encode_field(d, {label = ''}, 'label'), '""')
end

gfield.test_encode_field_honours_opts = function()
    local s = pb.json.encode_field(library.MoveBookRequest_descriptor,
        {destination_shelf = 'x'}, 'destination_shelf', {emit_defaults = true})
    t.assert_equals(s, '"x"')
    s = pb.json.encode_field(library.ListBooksResponse_descriptor,
        {books = {{}}}, 'books', {emit_defaults = true, use_proto_names = true})
    t.assert_equals(reparse(s)[1].name, '')
end

gfield.test_encode_field_unknown_field = function()
    t.assert_error_msg_contains('has no field "nope"', pb.json.encode_field,
        library.Book_descriptor, {}, 'nope')
end

gfield.test_decode_field = function()
    local d = library.CreateBookRequest_descriptor
    t.assert_equals(pb.json.decode_field(d, 'book', '{"title":"T","isbn":"1"}'),
                    {title = 'T', isbn = '1'})
    t.assert_equals(pb.json.decode_field(d, 'parent', '"shelves/1"'), 'shelves/1')
    t.assert_equals(pb.json.decode_field(d, 'book', 'null'), nil)
    t.assert_equals(pb.json.decode_field(library.ListBooksResponse_descriptor,
        'books', '[{"name":"a"}]'), {{name = 'a'}})
end

gfield.test_decode_field_rejects_bad_input = function()
    local d = library.CreateBookRequest_descriptor
    t.assert_error_msg_contains('duplicate JSON key', pb.json.decode_field,
        d, 'book', '{"title":"a","title":"b"}')
    t.assert_error_msg_contains('expected JSON object', pb.json.decode_field,
        d, 'book', '"str"')
    t.assert_error_msg_contains('has no field', pb.json.decode_field, d, 'nope', '{}')
end

-- emit_null_messages: an unset singular message field is `null`; oneof
-- members, proto3 `optional` and repeated fields are not affected.
gfield.test_emit_null_messages = function()
    local m = pb.parse([[
        syntax = "proto3"; package jn;
        import "google/protobuf/timestamp.proto";
        message Inner { string s = 1; }
        message Outer {
          Inner inner = 1;
          repeated Inner inners = 2;
          oneof o { Inner a = 3; string b = 4; }
          optional Inner opt = 5;
          google.protobuf.Timestamp at = 6;
          string name = 7;
        }
    ]])
    local d = m.Outer_descriptor
    t.assert_equals(reparse(pb.json.encode(d, {}, {emit_null_messages = true})),
                    {inner = box.NULL, at = box.NULL})
    local got = reparse(pb.json.encode(d, {}, {emit_null_messages = true, emit_defaults = true}))
    t.assert_equals(got, {inner = box.NULL, at = box.NULL, inners = {}, name = ''})
    t.assert_equals(reparse(pb.json.encode(d, {inner = {s = 'x'}}, {emit_null_messages = true})),
                    {inner = {s = 'x'}, at = box.NULL})
    -- Off by default, and emit_defaults alone keeps unset messages absent.
    t.assert_equals(pb.json.encode(d, {}), '{}')
    t.assert_equals(reparse(pb.json.encode(d, {}, {emit_defaults = true})),
                    {inners = {}, name = ''})
end

gfield.test_json_name = function()
    t.assert_equals(pb.json.json_name('destination_shelf'), 'destinationShelf')
    t.assert_equals(pb.json.json_name('name'), 'name')
end
