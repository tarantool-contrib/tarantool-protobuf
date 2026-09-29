-- Smoke test for the descriptor → C plan compiler.
--
-- Only runs when PB_ENABLE_C=1 is set in the environment AND the C
-- runtime module is loadable. Otherwise the group is skipped, which
-- keeps `just test` green on hosts without the C module built.
--
-- Acceptance criteria:
--   (1) pb.c_runtime.compile_plan(desc) returns a userdata
--   (2) plan->n_fields and plan->fields[i].tag are readable
--   (3) Plans for hello.Person and hello.Address build without error

local t = require('luatest')

local pb = require('pb')
local c_runtime = pb.c_runtime

local function skip_if_no_c()
    if c_runtime == nil then
        t.skip('PB_ENABLE_C not set or pb.c_runtime not available')
    end
end

-- `pb` falls back to the Lua codec when `require('pb.c_runtime')` fails,
-- and every C group then skips instead of failing. Under PB_ENABLE_C=1
-- that fallback would turn a broken C build into a green run of the Lua
-- suite, so this group fails loudly with the load error instead.
local g_loaded = t.group('c_runtime_loaded')

function g_loaded.test_loaded_when_enabled()
    if os.getenv('PB_ENABLE_C') ~= '1' then
        t.skip('PB_ENABLE_C not set')
    end
    local ok, err = pcall(require, 'pb.c_runtime')
    t.assert(ok, 'PB_ENABLE_C=1 but pb.c_runtime failed to load: ' ..
        tostring(err))
    t.assert_not_equals(c_runtime, nil,
        'PB_ENABLE_C=1 but pb.c_runtime is nil')
end

-- Run each test against both codegen modes — c_plan is attached to the
-- descriptor regardless of mode, so both pick up the same compile path.
for _, mode in ipairs({'full', 'runtime'}) do
    local g = t.group('c_runtime_plan.' .. mode)
    local hello

    g.before_all(function()
        skip_if_no_c()
        hello = require(mode .. '.hello.hello_pb')
    end)

    g.before_each(skip_if_no_c)

    function g.test_module_surface()
        t.assert_equals(type(c_runtime.compile_plan), 'function')
        t.assert_equals(type(c_runtime._abi_version), 'string')
        t.assert(c_runtime.KIND ~= nil, 'KIND table exposed')
        t.assert(c_runtime.WIRE ~= nil, 'WIRE table exposed')
        t.assert_equals(c_runtime.WIRE.LEN, 2)
        t.assert_equals(c_runtime.WIRE.VARINT, 0)
    end

    function g.test_compile_address_returns_userdata()
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        t.assert_equals(type(plan), 'userdata')
        t.assert_equals(c_runtime.plan_name(plan), 'hello.Address')
        t.assert_equals(c_runtime.plan_n_fields(plan), 4)
    end

    function g.test_address_field_shapes()
        local plan = c_runtime.compile_plan(hello.Address_descriptor)
        -- {name="street", id=1, kind=scalar/string}
        local f1 = c_runtime.plan_field_info(plan, 1)
        t.assert_equals(f1.name, 'street')
        t.assert_equals(f1.field_number, 1)
        t.assert_equals(f1.wire_type, c_runtime.WIRE.LEN)
        t.assert_equals(f1.kind, c_runtime.KIND.STRING)
        t.assert_equals(f1.tag_bytes:byte(1, 1), 0x0A) -- (1<<3)|2
        -- {name="apartment", id=4, kind=scalar/string, optional=true}
        local f4 = c_runtime.plan_field_info(plan, 4)
        t.assert_equals(f4.name, 'apartment')
        t.assert_equals(f4.optional, true)
        t.assert_equals(f4.field_number, 4)
    end

    function g.test_compile_person_returns_userdata()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert_equals(type(plan), 'userdata')
        t.assert_equals(c_runtime.plan_name(plan), 'hello.Person')
        -- Person has 14 fields per examples/proto/hello.proto
        t.assert_equals(c_runtime.plan_n_fields(plan), 14)
    end

    function g.test_person_scalar_fields()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- name = string @1
        local f = c_runtime.plan_field_info(plan, 1)
        t.assert_equals(f.name, 'name')
        t.assert_equals(f.kind, c_runtime.KIND.STRING)
        t.assert_equals(f.wire_type, c_runtime.WIRE.LEN)
        -- age = int32 @2
        f = c_runtime.plan_field_info(plan, 2)
        t.assert_equals(f.name, 'age')
        t.assert_equals(f.kind, c_runtime.KIND.INT32)
        t.assert_equals(f.wire_type, c_runtime.WIRE.VARINT)
        -- user_id = fixed64 @9
        f = c_runtime.plan_field_info(plan, 9)
        t.assert_equals(f.name, 'user_id')
        t.assert_equals(f.kind, c_runtime.KIND.FIXED64)
        t.assert_equals(f.wire_type, c_runtime.WIRE.I64)
        -- balance = sint32 @10
        f = c_runtime.plan_field_info(plan, 10)
        t.assert_equals(f.kind, c_runtime.KIND.SINT32)
        -- weight_kg = double @11
        f = c_runtime.plan_field_info(plan, 11)
        t.assert_equals(f.kind, c_runtime.KIND.DOUBLE)
        t.assert_equals(f.wire_type, c_runtime.WIRE.I64)
    end

    function g.test_person_repeated_packed()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- emails = repeated string @3 (not packed)
        local f = c_runtime.plan_field_info(plan, 3)
        t.assert_equals(f.name, 'emails')
        t.assert_equals(f.repeated, true)
        t.assert_equals(f.packed, false)
        t.assert_equals(f.wire_type, c_runtime.WIRE.LEN)
        -- lucky_numbers = repeated int32, packed @7
        f = c_runtime.plan_field_info(plan, 7)
        t.assert_equals(f.name, 'lucky_numbers')
        t.assert_equals(f.repeated, true)
        t.assert_equals(f.packed, true)
        -- packed flips wire type to LEN regardless of element type
        t.assert_equals(f.wire_type, c_runtime.WIRE.LEN)
        t.assert_equals(f.kind, c_runtime.KIND.INT32)
    end

    function g.test_person_enum_field()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- status = enum @4
        local f = c_runtime.plan_field_info(plan, 4)
        t.assert_equals(f.name, 'status')
        t.assert_equals(f.kind, c_runtime.KIND.ENUM)
        t.assert_equals(f.wire_type, c_runtime.WIRE.VARINT)
    end

    function g.test_person_message_field_resolves_sub_plan()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- address = message Address @5
        local f = c_runtime.plan_field_info(plan, 5)
        t.assert_equals(f.name, 'address')
        t.assert_equals(f.kind, c_runtime.KIND.MESSAGE)
        t.assert(f.sub_plan_idx > 0, 'sub_plan_idx populated')
        local sub = c_runtime.plan_sub_plan(plan, f.sub_plan_idx)
        t.assert_equals(type(sub), 'userdata')
        t.assert_equals(c_runtime.plan_name(sub), 'hello.Address')
    end

    function g.test_self_reference_cycle()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- friends = repeated Person @6 (self-reference)
        local f = c_runtime.plan_field_info(plan, 6)
        t.assert_equals(f.name, 'friends')
        t.assert_equals(f.kind, c_runtime.KIND.MESSAGE)
        t.assert_equals(f.repeated, true)
        t.assert(f.sub_plan_idx > 0)
        local sub = c_runtime.plan_sub_plan(plan, f.sub_plan_idx)
        t.assert_equals(c_runtime.plan_name(sub), 'hello.Person')
        -- Cycle resolves to the same userdata, not a fresh one
        t.assert(sub == plan,
                 'self-reference returns the same plan userdata (cycle broken)')
    end

    function g.test_person_map_field()
        local plan = c_runtime.compile_plan(hello.Person_descriptor)
        -- ages_by_nickname: map<string, int32> @13
        local f = c_runtime.plan_field_info(plan, 12)  -- 12th field
        t.assert_equals(f.name, 'ages_by_nickname')
        t.assert_equals(f.kind, c_runtime.KIND.MAP)
        t.assert_equals(f.map_key_kind, c_runtime.KIND.STRING)
        t.assert_equals(f.map_value_kind, c_runtime.KIND.INT32)
        -- addresses_by_label: map<string, Address> @15
        f = c_runtime.plan_field_info(plan, 14)
        t.assert_equals(f.name, 'addresses_by_label')
        t.assert_equals(f.map_value_kind, c_runtime.KIND.MESSAGE)
        t.assert(f.map_value_sub_plan_idx > 0)
        local sub = c_runtime.plan_sub_plan(plan, f.map_value_sub_plan_idx)
        t.assert_equals(c_runtime.plan_name(sub), 'hello.Address')
    end

    function g.test_idempotent_compile()
        local p1 = c_runtime.compile_plan(hello.Person_descriptor)
        local p2 = c_runtime.compile_plan(hello.Person_descriptor)
        t.assert(p1 == p2, 'second compile returns cached plan')
    end

    function g.test_result_oneof()
        local plan = c_runtime.compile_plan(hello.Result_descriptor)
        t.assert_equals(c_runtime.plan_n_fields(plan), 4)
        t.assert_equals(c_runtime.plan_n_oneofs(plan), 1)
        local o = c_runtime.plan_oneof_info(plan, 1)
        t.assert_equals(o.name, 'outcome')
        t.assert_equals(#o.member_indices, 3)
        -- Members are 0-based indices into plan->fields[]; text/code/details
        -- are fields 2, 3, 4 in Result (id-ordered) → indices 1, 2, 3.
        local idxs = {}
        for _, i in ipairs(o.member_indices) do idxs[i] = true end
        t.assert(idxs[1] and idxs[2] and idxs[3],
                 'oneof members map to text/code/details indices')
        -- Each member field gets oneof_idx = 0 (the only oneof in Result).
        for _, fi in ipairs({2, 3, 4}) do
            local f = c_runtime.plan_field_info(plan, fi)
            t.assert_equals(f.oneof_idx, 0,
                            ('field %d oneof_idx'):format(fi))
        end
        -- id (field 1) is NOT in a oneof.
        local f1 = c_runtime.plan_field_info(plan, 1)
        t.assert_equals(f1.oneof_idx, -1)
    end

    function g.test_wkt_override_detection()
        local wkt = pb.wkt
        local plan = c_runtime.compile_plan(wkt.Timestamp_descriptor)
        t.assert_equals(c_runtime.plan_has_override(plan), true)
        -- has_override means the plan does not walk fields; field count is 0.
        t.assert_equals(c_runtime.plan_n_fields(plan), 0)
    end
end
