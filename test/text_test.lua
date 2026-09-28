-- Protobuf text-format printer tests.
local t = require('luatest')
local ffi = require('ffi')
local pb = require('pb')
local datetime = require('datetime')

-- Both codegen modes share the same descriptors; the printer walks
-- descriptors only, so the output is mode-independent. Exercise both
-- to confirm parity.
local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g = t.group('text.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    -- ---- scalars -------------------------------------------------------

    g.test_empty_message = function()
        t.assert_equals(pb.text.encode(hello.Address_descriptor, {}), '')
    end

    g.test_basic_scalars = function()
        local s = pb.text.encode(hello.Address_descriptor,
            {street = 'Pushkina 1', city = 'Moscow', zip = 123456})
        t.assert_equals(s, 'street: "Pushkina 1"\ncity: "Moscow"\nzip: 123456\n')
    end

    g.test_proto3_default_elision = function()
        -- Defaults on non-optional fields are elided like protoc --decode.
        local s = pb.text.encode(hello.Address_descriptor,
            {street = '', city = '', zip = 0})
        t.assert_equals(s, '')
    end

    g.test_optional_field_emits_default = function()
        -- `apartment` is proto3 explicit-optional; explicit empty must
        -- round-trip even though it equals the scalar default.
        local s = pb.text.encode(hello.Address_descriptor,
            {street = 'Main', zip = 1, apartment = ''})
        t.assert_equals(s, 'street: "Main"\nzip: 1\napartment: ""\n')
    end

    g.test_int64_lossless = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {user_id = ffi.cast('uint64_t', 18369917520866213889ULL)})
        t.assert_str_contains(s, 'user_id: 18369917520866213889')
    end

    g.test_bytes_octal_escape = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {avatar = '\x00\x01\x02\xff'})
        t.assert_str_contains(s, 'avatar: "\\000\\001\\002\\377"')
    end

    g.test_string_escapes = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {name = 'a"b\\c\nd\te'})
        t.assert_str_contains(s, 'name: "a\\"b\\\\c\\nd\\te"')
    end

    g.test_enum_as_name = function()
        local s = pb.text.encode(hello.Person_descriptor, {status = hello.Status.ERROR})
        t.assert_str_contains(s, 'status: ERROR')
    end

    g.test_enum_unknown_as_number = function()
        local s = pb.text.encode(hello.Person_descriptor, {status = 42})
        t.assert_str_contains(s, 'status: 42')
    end

    g.test_float_formats = function()
        local s = pb.text.encode(hello.Person_descriptor, {weight_kg = 72.5})
        t.assert_str_contains(s, 'weight_kg: 72.5')
    end

    g.test_float_specials = function()
        local s = pb.text.encode(hello.Person_descriptor, {weight_kg = 0/0})
        t.assert_str_contains(s, 'weight_kg: nan')
        s = pb.text.encode(hello.Person_descriptor, {weight_kg = math.huge})
        t.assert_str_contains(s, 'weight_kg: inf')
        s = pb.text.encode(hello.Person_descriptor, {weight_kg = -math.huge})
        t.assert_str_contains(s, 'weight_kg: -inf')
    end

    -- ---- repeated ------------------------------------------------------

    g.test_repeated_scalar = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {lucky_numbers = {1, 2, 3}})
        t.assert_equals(s, 'lucky_numbers: 1\nlucky_numbers: 2\nlucky_numbers: 3\n')
    end

    g.test_repeated_string = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {emails = {'a@x', 'b@x'}})
        t.assert_equals(s, 'emails: "a@x"\nemails: "b@x"\n')
    end

    -- ---- nested message + oneof ---------------------------------------

    g.test_nested_message = function()
        local s = pb.text.encode(hello.Person_descriptor, {
            name = 'P',
            address = {street = 'Main', city = 'X', zip = 1},
        })
        t.assert_equals(s,
            'name: "P"\naddress {\n  street: "Main"\n  city: "X"\n  zip: 1\n}\n')
    end

    g.test_oneof_scalar = function()
        local s = pb.text.encode(hello.Result_descriptor, {id = 7, text = 'hi'})
        t.assert_equals(s, 'id: 7\ntext: "hi"\n')
    end

    g.test_oneof_message = function()
        local s = pb.text.encode(hello.Result_descriptor,
            {id = 3, details = {street = 'X', zip = 99}})
        t.assert_equals(s, 'id: 3\ndetails {\n  street: "X"\n  zip: 99\n}\n')
    end

    -- ---- map -----------------------------------------------------------

    g.test_map_single_entry = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {ages_by_nickname = {alice = 30}})
        t.assert_equals(s,
            'ages_by_nickname {\n  key: "alice"\n  value: 30\n}\n')
    end

    g.test_map_message_value = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {addresses_by_label = {home = {street = 'Main', zip = 1}}})
        t.assert_str_contains(s, 'addresses_by_label {')
        t.assert_str_contains(s, 'key: "home"')
        t.assert_str_contains(s, 'value {')
        t.assert_str_contains(s, 'street: "Main"')
    end

    -- ---- single-line --------------------------------------------------

    g.test_single_line = function()
        local s = pb.text.encode(hello.Address_descriptor,
            {street = 'X', zip = 1},
            {single_line = true})
        t.assert_equals(s, 'street: "X" zip: 1')
    end

    g.test_single_line_nested = function()
        local s = pb.text.encode(hello.Person_descriptor,
            {name = 'P', address = {street = 'X', zip = 1}},
            {single_line = true})
        t.assert_equals(s, 'name: "P" address { street: "X" zip: 1 }')
    end

    -- ---- WKT ----------------------------------------------------------

    g.test_wkt_empty = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {title = 'x', ack = {}})
        t.assert_equals(s, 'title: "x"\nack {}\n')
    end

    g.test_wkt_timestamp_from_table = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {created_at = {seconds = 1700000000, nanos = 123}})
        t.assert_str_contains(s, 'created_at {')
        t.assert_str_contains(s, 'seconds: 1700000000')
        t.assert_str_contains(s, 'nanos: 123')
    end

    g.test_wkt_timestamp_from_datetime = function()
        local dt = datetime.new({timestamp = 1700000000})
        local s = pb.text.encode(hello.Event_descriptor, {created_at = dt})
        t.assert_str_contains(s, 'seconds: 1700000000')
    end

    g.test_wkt_duration = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {duration = {seconds = 5}})
        t.assert_str_contains(s, 'duration {')
        t.assert_str_contains(s, 'seconds: 5')
    end

    g.test_wkt_wrapper_int32 = function()
        local s = pb.text.encode(hello.Event_descriptor, {retry_count = 7})
        t.assert_str_contains(s, 'retry_count {')
        t.assert_str_contains(s, 'value: 7')
    end

    g.test_wkt_wrapper_string = function()
        local s = pb.text.encode(hello.Event_descriptor, {note = 'hello'})
        t.assert_str_contains(s, 'note {')
        t.assert_str_contains(s, 'value: "hello"')
    end

    g.test_wkt_wrapper_bool = function()
        local s = pb.text.encode(hello.Event_descriptor, {is_admin = true})
        t.assert_str_contains(s, 'is_admin {')
        t.assert_str_contains(s, 'value: true')
    end

    g.test_wkt_fieldmask = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {update_mask = {'title', 'extension'}})
        t.assert_str_contains(s, 'update_mask {')
        t.assert_str_contains(s, 'paths: "title"')
        t.assert_str_contains(s, 'paths: "extension"')
    end

    g.test_wkt_any_opaque = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {extension = {type_url = 'type.googleapis.com/X', value = '\x01\x02'}})
        t.assert_str_contains(s, 'extension {')
        t.assert_str_contains(s, 'type_url: "type.googleapis.com/X"')
        t.assert_str_contains(s, 'value: "\\001\\002"')
    end

    g.test_wkt_struct = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {payload = {region = 'us-east-1'}})
        t.assert_str_contains(s, 'payload {')
        t.assert_str_contains(s, 'fields {')
        t.assert_str_contains(s, 'key: "region"')
        t.assert_str_contains(s, 'string_value: "us-east-1"')
    end

    g.test_wkt_value_scalar = function()
        local s = pb.text.encode(hello.Event_descriptor, {attribute = 'hi'})
        t.assert_str_contains(s, 'attribute {')
        t.assert_str_contains(s, 'string_value: "hi"')
    end

    g.test_wkt_value_null = function()
        local s = pb.text.encode(hello.Event_descriptor, {attribute = pb.NULL})
        t.assert_str_contains(s, 'null_value: NULL_VALUE')
    end

    g.test_wkt_listvalue = function()
        local s = pb.text.encode(hello.Event_descriptor,
            {tags = pb.wkt.list({1, 'two', true})})
        t.assert_str_contains(s, 'tags {')
        t.assert_str_contains(s, 'values {')
        t.assert_str_contains(s, 'number_value: 1.0')
        t.assert_str_contains(s, 'string_value: "two"')
        t.assert_str_contains(s, 'bool_value: true')
    end

    -- ---- top-level WKT (descriptor itself is a WKT) -------------------

    g.test_top_level_timestamp = function()
        local s = pb.text.encode(pb.wkt.Timestamp_descriptor,
            {seconds = 100, nanos = 1})
        t.assert_equals(s, 'seconds: 100\nnanos: 1\n')
    end

    g.test_top_level_fieldmask = function()
        local s = pb.text.encode(pb.wkt.FieldMask_descriptor, {'a', 'b'})
        t.assert_equals(s, 'paths: "a"\npaths: "b"\n')
    end

    g.test_top_level_empty = function()
        local s = pb.text.encode(pb.wkt.Empty_descriptor, {})
        t.assert_equals(s, '')
    end

    -- ---- generated codegen wrapper ------------------------------------

    g.test_generated_text_wrapper = function()
        local s = hello.Address_text({street = 'X', zip = 1})
        t.assert_equals(s, 'street: "X"\nzip: 1\n')
        s = hello.Address_text({street = 'X', zip = 1}, {single_line = true})
        t.assert_equals(s, 'street: "X" zip: 1')
    end
end
