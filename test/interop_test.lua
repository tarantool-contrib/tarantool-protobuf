-- Cross-implementation interop: assert our codec is byte-for-byte equivalent
-- to mainline protoc.
--
-- For each fixture <name>.bin (the output of `protoc --encode=Type` against
-- the matching .txtpb), this suite:
--   (a) decodes the golden bytes with our decoder
--   (b) re-encodes the resulting Lua table with our encoder
--   (c) asserts the round-tripped bytes match the golden byte-for-byte
--
-- Step (c) is the strong claim: we don't just round-trip ourselves, we
-- agree on the wire with the canonical implementation.
local t = require('luatest')
local fio = require('fio')

local FIXTURES_DIR = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), 'interop', 'fixtures'))

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format('%02x', s:byte(i)) end
    return table.concat(out)
end

-- Read the `# type: <FullName>` annotation from the matching .txtpb file
-- to learn which Lua message type to decode/encode with.
local function read_type(txtpb_path)
    for line in io.lines(txtpb_path) do
        local m = line:match('^# type:%s*(%S+)')
        if m then return m end
    end
    error('no `# type:` annotation in ' .. txtpb_path, 0)
end

local function lua_type_funcs(hello, full_name)
    -- "hello.Person" -> ("Person_encode", "Person_decode")
    local short = full_name:gsub('^hello%.', '')
    return hello[short .. '_encode'], hello[short .. '_decode']
end

-- Discover all fixtures once.
local function list_fixtures()
    local entries = fio.listdir(FIXTURES_DIR)
    table.sort(entries)
    local fixtures = {}
    for _, name in ipairs(entries) do
        if name:match('%.bin$') then
            local base = name:sub(1, -5)
            local bin_path = fio.pathjoin(FIXTURES_DIR, name)
            local txt_path = fio.pathjoin(FIXTURES_DIR, base .. '.txtpb')
            fixtures[#fixtures + 1] = {
                name = base,
                bin_path = bin_path,
                txt_path = txt_path,
                full_name = read_type(txt_path),
            }
        end
    end
    return fixtures
end

local FIXTURES = list_fixtures()

for _, mode in ipairs({'full', 'runtime'}) do
    local hello = require(mode .. '.hello.hello_pb')
    local g = t.group('interop.' .. mode)

    for _, fx in ipairs(FIXTURES) do
        g['test_' .. fx.name] = function()
            local golden = slurp(fx.bin_path)
            local encode_fn, decode_fn = lua_type_funcs(hello, fx.full_name)
            t.assert(encode_fn, 'no encoder for ' .. fx.full_name)
            t.assert(decode_fn, 'no decoder for ' .. fx.full_name)

            local decoded = decode_fn(golden)
            local reencoded = encode_fn(decoded)

            t.assert_equals(hex(reencoded), hex(golden),
                ('byte-for-byte mismatch with protoc on %s'):format(fx.name))
        end
    end
end

-- Lazy passthrough: decode_lazy then :encode() must produce bytes
-- byte-identical to the golden. This is the strongest claim for the
-- read-only zero-copy path — untouched views skip re-emission entirely.
for _, mode in ipairs({'full', 'runtime'}) do
    local hello = require(mode .. '.hello.hello_pb')
    local g = t.group('interop_lazy.' .. mode)

    for _, fx in ipairs(FIXTURES) do
        g['test_' .. fx.name] = function()
            local golden = slurp(fx.bin_path)
            local short = fx.full_name:gsub('^hello%.', '')
            local decode_lazy_fn = hello[short .. '_decode_lazy']
            t.assert(decode_lazy_fn, 'no decode_lazy for ' .. fx.full_name)

            local v = decode_lazy_fn(golden)
            t.assert_equals(hex(v:encode()), hex(golden),
                ('lazy passthrough mismatch on %s'):format(fx.name))
        end
    end
end
