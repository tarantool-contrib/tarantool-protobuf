-- Protobuf text-format parser tests.
--
-- Decoder is descriptor-driven, so output is mode-independent; we still
-- run every assertion under both `full` and `runtime` generated modules
-- to confirm parity with the encoder/descriptor codegen.
local t = require('luatest')
local ffi = require('ffi')
local pb = require('pb')

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g = t.group('text_decode.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    -- ---- scalars -------------------------------------------------------

    g.test_basic_scalar = function()
        local m = pb.text.decode(hello.Address_descriptor,
            'street: "Pushkina 1"\ncity: "Moscow"\nzip: 123456\n')
        t.assert_equals(m, {street = 'Pushkina 1', city = 'Moscow', zip = 123456})
    end

    g.test_empty = function()
        t.assert_equals(pb.text.decode(hello.Address_descriptor, ''), {})
    end

    g.test_int64_lossless = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'user_id: 18369917520866213889\n')
        t.assert_equals(m.user_id, ffi.cast('uint64_t', 18369917520866213889ULL))
    end

    g.test_int_radixes = function()
        local m = pb.text.decode(hello.Address_descriptor,
            'zip: 0xff\n')
        t.assert_equals(m.zip, 255)
        m = pb.text.decode(hello.Address_descriptor, 'zip: 010\n')
        t.assert_equals(m.zip, 8)
    end

    g.test_int_negative = function()
        local m = pb.text.decode(hello.Address_descriptor, 'zip: -7\n')
        t.assert_equals(m.zip, -7)
    end

    g.test_float_format = function()
        local m = pb.text.decode(hello.Person_descriptor, 'weight_kg: 72.5\n')
        t.assert_equals(m.weight_kg, 72.5)
    end

    g.test_float_specials = function()
        local m = pb.text.decode(hello.Person_descriptor, 'weight_kg: inf\n')
        t.assert_equals(m.weight_kg, math.huge)
        m = pb.text.decode(hello.Person_descriptor, 'weight_kg: -INFINITY\n')
        t.assert_equals(m.weight_kg, -math.huge)
        m = pb.text.decode(hello.Person_descriptor, 'weight_kg: NaN\n')
        t.assert_not_equals(m.weight_kg, m.weight_kg)  -- NaN ~= NaN
    end

    g.test_float_trailing_f = function()
        local m = pb.text.decode(hello.Person_descriptor, 'weight_kg: 1.5f\n')
        t.assert_equals(m.weight_kg, 1.5)
    end

    g.test_string_escapes = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'name: "a\\"b\\\\c\\nd\\te"\n')
        t.assert_equals(m.name, 'a"b\\c\nd\te')
    end

    g.test_octal_and_hex_escapes = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'avatar: "\\000\\001\\xff"\n')
        t.assert_equals(m.avatar, '\x00\x01\xff')
    end

    g.test_unicode_escape = function()
        -- ሴ is BMP, \U00010437 is supplementary plane.
        local m = pb.text.decode(hello.Person_descriptor,
            'name: "\\u00e9\\U00010437"\n')
        -- U+00E9 -> 0xC3 0xA9; U+10437 -> 0xF0 0x90 0x90 0xB7.
        t.assert_equals(m.name, '\xc3\xa9\xf0\x90\x90\xb7')
    end

    g.test_adjacent_string_concat = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'name: "ab" "cd" "ef"\n')
        t.assert_equals(m.name, 'abcdef')
    end

    g.test_comment_skipped = function()
        local m = pb.text.decode(hello.Address_descriptor,
            '# leading\nstreet: "S"  # trailing\n')
        t.assert_equals(m.street, 'S')
    end

    g.test_separator_semi_and_comma = function()
        local m = pb.text.decode(hello.Address_descriptor,
            'street: "S",\nzip: 1;\n')
        t.assert_equals(m, {street = 'S', zip = 1})
    end

    g.test_double_semicolon_errors = function()
        -- Mainline TextFormat rejects `;;` between fields (treats the
        -- empty entry as a duplicate). Pins FieldSeparatorSemi*.
        local ok, e = pcall(pb.text.decode, hello.Address_descriptor,
            'street: "S";;\n')
        t.assert_not(ok)
        t.assert_str_contains(e, 'field-entry start')
    end

    -- ---- enums ---------------------------------------------------------

    g.test_enum_by_name = function()
        local m = pb.text.decode(hello.Person_descriptor, 'status: ERROR\n')
        t.assert_equals(m.status, hello.Status.ERROR)
    end

    g.test_enum_by_number = function()
        local m = pb.text.decode(hello.Person_descriptor, 'status: 2\n')
        t.assert_equals(m.status, 2)
    end

    g.test_enum_unknown_name_errors = function()
        local ok, err = pcall(pb.text.decode, hello.Person_descriptor,
            'status: NOPE\n')
        t.assert_not(ok)
        t.assert_str_contains(err, 'unknown enum')
    end

    -- ---- repeated ------------------------------------------------------

    g.test_repeated_long_form = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'emails: "a"\nemails: "b"\nemails: "c"\n')
        t.assert_equals(m.emails, {'a', 'b', 'c'})
    end

    g.test_repeated_short_form = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'lucky_numbers: [1, 2, 3]\n')
        t.assert_equals(m.lucky_numbers, {1, 2, 3})
    end

    g.test_repeated_short_empty = function()
        local m = pb.text.decode(hello.Person_descriptor, 'lucky_numbers: []\n')
        t.assert_equals(m.lucky_numbers, {})
    end

    g.test_repeated_short_separate_lists_append = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'lucky_numbers: [1] lucky_numbers: [2, 3]\n')
        t.assert_equals(m.lucky_numbers, {1, 2, 3})
    end

    -- ---- aggregates ----------------------------------------------------

    g.test_nested_message_curly = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'address { street: "S" zip: 1 }\n')
        t.assert_equals(m.address, {street = 'S', zip = 1})
    end

    g.test_nested_message_angle = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'address < street: "S" zip: 1 >\n')
        t.assert_equals(m.address, {street = 'S', zip = 1})
    end

    g.test_nested_message_with_colon = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'address: { street: "S" }\n')
        t.assert_equals(m.address.street, 'S')
    end

    -- ---- maps ----------------------------------------------------------

    g.test_map_entry_single = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'ages_by_nickname { key: "alice" value: 30 }\n')
        t.assert_equals(m.ages_by_nickname, {alice = 30})
    end

    g.test_map_entry_multi = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'ages_by_nickname { key: "a" value: 1 }\n' ..
            'ages_by_nickname { key: "b" value: 2 }\n')
        t.assert_equals(m.ages_by_nickname, {a = 1, b = 2})
    end

    g.test_map_message_value = function()
        local m = pb.text.decode(hello.Person_descriptor,
            'addresses_by_label { key: "home" value { street: "S" zip: 1 } }\n')
        t.assert_equals(m.addresses_by_label.home, {street = 'S', zip = 1})
    end

    -- ---- oneof ---------------------------------------------------------

    g.test_oneof_last_wins = function()
        -- Setting two `outcome` members in sequence keeps only the last;
        -- `id` is outside the oneof so it survives untouched.
        local m = pb.text.decode(hello.Result_descriptor,
            'id: 7\ntext: "first"\ncode: 99\n')
        t.assert_equals(m.id, 7)
        t.assert_equals(m.code, 99)
        t.assert_equals(m.text, nil)
    end

    -- ---- error surface -------------------------------------------------

    g.test_unknown_field_errors_by_default = function()
        local ok, err = pcall(pb.text.decode, hello.Address_descriptor,
            'street: "S"\nbogus: 1\n')
        t.assert_not(ok)
        t.assert_str_contains(err, 'unknown field')
    end

    g.test_unknown_field_dropped_when_allowed = function()
        local m = pb.text.decode(hello.Address_descriptor,
            'street: "S"\nbogus: 1\n', {allow_unknown_fields = true})
        t.assert_equals(m, {street = 'S'})
    end

    g.test_unknown_numeric_id_dropped = function()
        local m = pb.text.decode(hello.Address_descriptor,
            'street: "S"\n9999: 42\n')
        t.assert_equals(m, {street = 'S'})
    end

    -- ---- round-trip with the encoder ----------------------------------

    g.test_round_trip_encode_decode = function()
        local src = {
            name = 'Alice',
            user_id = ffi.cast('uint64_t', 42),
            emails = {'a@x', 'b@x'},
            address = {street = 'Main', city = 'NYC', zip = 10001},
            status = hello.Status.ACTIVE,
            ages_by_nickname = {al = 30},
        }
        local text = pb.text.encode(hello.Person_descriptor, src)
        local decoded = pb.text.decode(hello.Person_descriptor, text)
        -- Compare via re-encode for cdata equality stability.
        t.assert_equals(pb.encode(hello.Person_descriptor, decoded),
                        pb.encode(hello.Person_descriptor, src))
    end
end
