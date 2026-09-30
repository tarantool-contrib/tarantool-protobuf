-- Tests for the lazy / zero-copy decode view (runtime/pb/lazy.lua).
-- Parameterized over both codegen modes — the generated _decode_lazy
-- shim is identical in both, but the descriptor shape it consumes
-- comes from each mode's emitted module.
--
-- Field-name arguments to :get / :has / :set / :clear / :which are
-- routed through the codegen-emitted M.<Type>_fields and
-- M.<Type>_oneofs constants tables. See docs/api-modes.md for the
-- documented contract. Map keys and repeated indices stay as raw
-- values — those aren't field names.

local t = require('luatest')
local ffi = require('ffi')

local MODES = {'full', 'runtime'}

for _, mode in ipairs(MODES) do
    local g = t.group('lazy.' .. mode)
    local hello = require(mode .. '.hello.hello_pb')

    -- Local aliases keep the assertions short without losing the
    -- typo-strict lookup.
    local AF = hello.Address_fields
    local PF = hello.Person_fields
    local RF = hello.Result_fields
    local EF = hello.Event_fields
    local RO = hello.Result_oneofs

    -- ---- Basic scalar access ----

    g.test_singular_scalars_decode_on_demand = function()
        local enc = hello.Address_encode({street = 'Main St', city = 'SF', zip = 42})
        local v = hello.Address_decode_lazy(enc)
        t.assert_equals(v:get(AF.street), 'Main St')
        t.assert_equals(v:get(AF.city), 'SF')
        t.assert_equals(v:get(AF.zip), 42)
        t.assert_equals(v:get(AF.apartment), nil, 'absent optional')
    end

    g.test_has_reports_wire_presence = function()
        local enc = hello.Address_encode({street = 'X'})
        local v = hello.Address_decode_lazy(enc)
        t.assert_equals(v:has(AF.street), true)
        t.assert_equals(v:has(AF.city), false)
        t.assert_equals(v:has(AF.zip), false)
    end

    g.test_get_caches_repeated_calls = function()
        local enc = hello.Address_encode({street = 'Main'})
        local v = hello.Address_decode_lazy(enc)
        local a = v:get(AF.street)
        local b = v:get(AF.street)
        t.assert_is(a, b, 'string values are interned but cache should hit')
    end

    -- ---- Repeated fields ----

    g.test_unpacked_repeated_string = function()
        local enc = hello.Person_encode({emails = {'a@x', 'b@x', 'c@x'}})
        local v = hello.Person_decode_lazy(enc)
        local arr = v:get(PF.emails)
        t.assert_not_equals(arr, nil)
        t.assert_equals(arr:len(), 3)
        t.assert_equals(arr:at(1), 'a@x')
        t.assert_equals(arr:at(2), 'b@x')
        t.assert_equals(arr:at(3), 'c@x')
        local seen = {}
        for i, s in arr:iter() do seen[i] = s end
        t.assert_equals(seen, {'a@x', 'b@x', 'c@x'})
    end

    g.test_packed_repeated_int32 = function()
        local enc = hello.Person_encode({lucky_numbers = {7, 13, 42}})
        local v = hello.Person_decode_lazy(enc)
        local arr = v:get(PF.lucky_numbers)
        t.assert_equals(arr:len(), 3)
        t.assert_equals(arr:at(1), 7)
        t.assert_equals(arr:at(2), 13)
        t.assert_equals(arr:at(3), 42)
    end

    g.test_repeated_message_returns_subviews = function()
        local enc = hello.Person_encode({
            friends = {
                {name = 'Bob', age = 20},
                {name = 'Carol', age = 30},
            },
        })
        local v = hello.Person_decode_lazy(enc)
        local fr = v:get(PF.friends)
        t.assert_equals(fr:len(), 2)
        t.assert_equals(fr:at(1):get(PF.name), 'Bob')
        t.assert_equals(fr:at(1):get(PF.age), 20)
        t.assert_equals(fr:at(2):get(PF.name), 'Carol')
    end

    g.test_absent_repeated_is_nil = function()
        local enc = hello.Person_encode({name = 'X'})
        local v = hello.Person_decode_lazy(enc)
        t.assert_equals(v:get(PF.emails), nil)
        t.assert_equals(v:has(PF.emails), false)
    end

    -- ---- Nested singular message ----

    g.test_nested_message_subview = function()
        local enc = hello.Person_encode({
            name = 'Alice',
            address = {street = 'Main', city = 'Springfield'},
        })
        local v = hello.Person_decode_lazy(enc)
        local addr = v:get(PF.address)
        t.assert_equals(addr:get(AF.street), 'Main')
        t.assert_equals(addr:get(AF.city), 'Springfield')
    end

    -- ---- Map fields ----

    g.test_map_get_and_has = function()
        local enc = hello.Person_encode({ages_by_nickname = {alice = 30, bob = 25}})
        local v = hello.Person_decode_lazy(enc)
        local m = v:get(PF.ages_by_nickname)
        t.assert_equals(m:get('alice'), 30)
        t.assert_equals(m:get('bob'), 25)
        t.assert_equals(m:has('alice'), true)
        t.assert_equals(m:has('zzz'), false)
        t.assert_equals(m:get('zzz'), nil)
    end

    g.test_map_keys_and_iter = function()
        local enc = hello.Person_encode({ages_by_nickname = {alice = 30}})
        local v = hello.Person_decode_lazy(enc)
        local m = v:get(PF.ages_by_nickname)
        t.assert_equals(m:keys(), {'alice'})
        local seen = {}
        for k, val in m:iter() do seen[k] = val end
        t.assert_equals(seen, {alice = 30})
    end

    g.test_map_message_values_are_subviews = function()
        local enc = hello.Person_encode({
            addresses_by_label = {home = {street = 'Main', city = 'SF'}},
        })
        local v = hello.Person_decode_lazy(enc)
        local m = v:get(PF.addresses_by_label)
        local home = m:get('home')
        t.assert_equals(home:get(AF.street), 'Main')
        t.assert_equals(home:get(AF.city), 'SF')
    end

    -- ---- Oneof ----

    g.test_oneof_which_text_branch = function()
        local enc = hello.Result_encode({id = 1, text = 'ok'})
        local v = hello.Result_decode_lazy(enc)
        t.assert_equals(v:which(RO.outcome), 'text')
        t.assert_equals(v:get(RF.text), 'ok')
        -- Inactive branches: not on the wire, so :has is false.
        t.assert_equals(v:has(RF.code), false)
        t.assert_equals(v:has(RF.details), false)
    end

    g.test_oneof_which_message_branch = function()
        local enc = hello.Result_encode({details = {street = 'Main'}})
        local v = hello.Result_decode_lazy(enc)
        t.assert_equals(v:which(RO.outcome), 'details')
        local d = v:get(RF.details)
        t.assert_equals(d:get(AF.street), 'Main')
    end

    g.test_oneof_no_branch_set = function()
        local enc = hello.Result_encode({id = 1})
        local v = hello.Result_decode_lazy(enc)
        t.assert_equals(v:which(RO.outcome), nil)
    end

    -- ---- iter / names ----

    g.test_iter_yields_present_fields_in_wire_order = function()
        local enc = hello.Address_encode({street = 'A', city = 'B', zip = 7})
        local v = hello.Address_decode_lazy(enc)
        local seen = {}
        for name, val in v:iter() do seen[#seen + 1] = {name, val} end
        t.assert_equals(seen, {{'street', 'A'}, {'city', 'B'}, {'zip', 7}})
    end

    g.test_names_yields_present_fields_only = function()
        local enc = hello.Address_encode({street = 'A', zip = 7})
        local v = hello.Address_decode_lazy(enc)
        local names = {}
        for name in v:names() do names[#names + 1] = name end
        t.assert_equals(names, {'street', 'zip'})
    end

    g.test_iter_skips_unknown_fields = function()
        -- Hand-craft bytes with an extra unknown field id.
        local known = hello.Address_encode({street = 'X'})
        local extra = string.char(0x68, 0x05)  -- tag (id=13, varint), value=5
        local v = hello.Address_decode_lazy(known .. extra)
        local names = {}
        for name in v:names() do names[#names + 1] = name end
        t.assert_equals(names, {'street'})
        t.assert_equals(v:get(AF.street), 'X')
    end

    -- ---- WKT eager-wrap ----

    g.test_wkt_timestamp_eager_wrapped = function()
        local datetime = require('datetime')
        local dt = datetime.new({timestamp = 1700000000, nsec = 0})
        local enc = hello.Event_encode({title = 'launch', created_at = dt})
        local v = hello.Event_decode_lazy(enc)
        t.assert_equals(v:get(EF.title), 'launch')
        local ts = v:get(EF.created_at)
        -- WKT descriptors carry desc.decode; lazy delegates to it,
        -- producing whatever the eager codec produces — for Timestamp,
        -- a datetime cdata equal to the original.
        t.assert_equals(ts, dt)
    end

    -- ---- 64-bit cdata correctness ----

    g.test_fixed64_uint64_cdata = function()
        local big = ffi.cast('uint64_t', 0xdeadbeefcafebabeULL)
        local enc = hello.Person_encode({user_id = big})
        local v = hello.Person_decode_lazy(enc)
        local got = v:get(PF.user_id)
        t.assert_equals(ffi.cast('uint64_t', got), big)
    end

    -- ---- Phase 2: mutation + passthrough re-encode ----

    g.test_untouched_view_round_trips_bytes_verbatim = function()
        local orig = hello.Person_encode({
            name = 'Alice', age = 30,
            emails = {'a@x', 'b@x'},
            address = {street = 'Main', city = 'SF', zip = 100},
        })
        local v = hello.Person_decode_lazy(orig)
        t.assert_equals(v:encode(), orig, 'untouched lazy view -> identical bytes')
    end

    g.test_set_singular_scalar_round_trips_via_eager = function()
        local orig = hello.Address_encode({street = 'A', city = 'B', zip = 1})
        local v = hello.Address_decode_lazy(orig)
        v:set(AF.city, 'C')
        local out = v:encode()
        local eager = hello.Address_decode(out)
        t.assert_equals(eager.street, 'A')
        t.assert_equals(eager.city, 'C')
        t.assert_equals(eager.zip, 1)
    end

    g.test_set_repeated_replaces_entire_field = function()
        local orig = hello.Person_encode({emails = {'a@x', 'b@x'}})
        local v = hello.Person_decode_lazy(orig)
        v:set(PF.emails, {'new@x'})
        local eager = hello.Person_decode(v:encode())
        t.assert_equals(eager.emails, {'new@x'})
    end

    g.test_set_singular_message_passthrough_for_others = function()
        local orig = hello.Person_encode({
            name = 'Alice', age = 30,
            emails = {'a@x'},
            address = {street = 'Old', city = 'X'},
        })
        local v = hello.Person_decode_lazy(orig)
        v:set(PF.address, {street = 'New', city = 'Y'})
        local eager = hello.Person_decode(v:encode())
        t.assert_equals(eager.name, 'Alice')
        t.assert_equals(eager.age, 30)
        t.assert_equals(eager.emails, {'a@x'})
        t.assert_equals(eager.address.street, 'New')
        t.assert_equals(eager.address.city, 'Y')
    end

    g.test_unknown_fields_preserved_through_set = function()
        local known = hello.Address_encode({street = 'X'})
        local extra = string.char(0x68, 0x05)  -- id=13, varint, value=5
        local v = hello.Address_decode_lazy(known .. extra)
        v:set(AF.zip, 99)
        local out = v:encode()
        -- Unknown field bytes should still be present in the output.
        t.assert(out:find(extra, 1, true) ~= nil, 'unknown bytes preserved')
        local eager = hello.Address_decode(out)
        t.assert_equals(eager.street, 'X')
        t.assert_equals(eager.zip, 99)
    end

    g.test_oneof_set_clears_other_branches = function()
        local orig = hello.Result_encode({id = 1, text = 'hello'})
        local v = hello.Result_decode_lazy(orig)
        v:set(RF.code, 42)
        v:set(RF.text, nil)  -- explicit clear
        local eager = hello.Result_decode(v:encode())
        t.assert_equals(eager.id, 1)
        t.assert_equals(eager.code, 42)
        t.assert_equals(eager.text, nil)
    end

    g.test_sub_view_mutation_propagates_to_parent_encode = function()
        local orig = hello.Person_encode({
            name = 'Alice',
            address = {street = 'Old', city = 'X', zip = 1},
        })
        local v = hello.Person_decode_lazy(orig)
        local addr = v:get(PF.address)
        addr:set(AF.street, 'New')
        local eager = hello.Person_decode(v:encode())
        t.assert_equals(eager.name, 'Alice')
        t.assert_equals(eager.address.street, 'New')
        t.assert_equals(eager.address.city, 'X')
    end

    -- ---- :get matches eager :decode ----

    g.test_lazy_get_matches_eager_decode = function()
        local p = {
            name    = 'Alice',
            age     = 30,
            emails  = {'a@x', 'b@x'},
            status  = hello.Status.OK,
            address = {street = 'Main', city = 'SF', zip = 100},
            lucky_numbers = {1, 2, 3},
            ages_by_nickname = {alice = 30},
        }
        local enc = hello.Person_encode(p)
        local eager = hello.Person_decode(enc)
        local v = hello.Person_decode_lazy(enc)
        t.assert_equals(v:get(PF.name), eager.name)
        t.assert_equals(v:get(PF.age), eager.age)
        t.assert_equals(v:get(PF.status), eager.status)
        t.assert_equals(v:get(PF.emails):tolist(), eager.emails)
        t.assert_equals(v:get(PF.lucky_numbers):tolist(), eager.lucky_numbers)
        t.assert_equals(v:get(PF.ages_by_nickname):totable(), eager.ages_by_nickname)
        local addr = v:get(PF.address)
        t.assert_equals(addr:get(AF.street), eager.address.street)
        t.assert_equals(addr:get(AF.zip), eager.address.zip)
    end

    -- ---- Field-name constants table contract ----

    g.test_field_names_table_errors_on_typo = function()
        t.assert_error_msg_contains(
            'unknown field name: "steet"',
            function() return hello.Address_fields.steet end)
    end

    g.test_field_names_table_is_read_only = function()
        t.assert_error_msg_contains(
            'field_names table is read-only',
            function() hello.Address_fields.new_key = 'x' end)
    end

    g.test_oneof_names_table_errors_on_typo = function()
        t.assert_error_msg_contains(
            'unknown field name: "outcom"',
            function() return hello.Result_oneofs.outcom end)
    end
end
