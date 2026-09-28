-- Runtime parsing: load hello.proto at runtime and assert encode/decode
-- parity with the build-time generated module across the interop corpus.
local t = require('luatest')
local fio = require('fio')
local pb = require('pb')

local REPO_ROOT = fio.abspath(fio.pathjoin(
    fio.dirname(debug.getinfo(1, 'S').source:sub(2)), '..'))
local PROTO_PATH = fio.pathjoin(REPO_ROOT, 'examples', 'proto', 'hello.proto')
local FIXTURES_DIR = fio.pathjoin(REPO_ROOT, 'test', 'interop', 'fixtures')

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

local g_unit = t.group('parser.unit')

g_unit.test_parser_handles_full_schema = function()
    local source = slurp(PROTO_PATH)
    local ast = pb.parser.parse(source)
    t.assert_equals(ast.syntax, 'proto3')
    t.assert_equals(ast.package, 'hello')
    t.assert(#ast.messages > 0)
    -- Look up Person AST in flat list.
    local person
    for _, m in ipairs(ast.messages) do
        if m.name == 'Person' then person = m; break end
    end
    t.assert(person, 'Person message found')
    -- Locate `optional string apartment = 4;` on Address
    local address
    for _, m in ipairs(ast.messages) do
        if m.name == 'Address' then address = m; break end
    end
    t.assert(address)
    local apt
    for _, f in ipairs(address.fields) do
        if f.name == 'apartment' then apt = f; break end
    end
    t.assert(apt and apt.optional, 'apartment is optional')
end

g_unit.test_parser_handles_oneof_and_map = function()
    local source = slurp(PROTO_PATH)
    local ast = pb.parser.parse(source)
    -- Find Result; should have a oneof.
    local result
    for _, m in ipairs(ast.messages) do
        if m.name == 'Result' then result = m; break end
    end
    t.assert(result and #result.oneofs > 0)
    t.assert_equals(result.oneofs[1].name, 'outcome')
    -- Find Person; should have map fields.
    local person
    for _, m in ipairs(ast.messages) do
        if m.name == 'Person' then person = m; break end
    end
    local map_field
    for _, f in ipairs(person.fields) do
        if f.kind == 'map' then map_field = f; break end
    end
    t.assert(map_field, 'at least one map field')
end

-- ---------------------------------------------------------------------------
-- Interop: dynamic module must produce identical bytes to the generated
-- module for every fixture in the corpus.
-- ---------------------------------------------------------------------------

local hello_dynamic = pb.parse(slurp(PROTO_PATH))
local hello_static  = require('full.hello.hello_pb')

local function fixtures()
    local entries = fio.listdir(FIXTURES_DIR)
    table.sort(entries)
    local out = {}
    for _, name in ipairs(entries) do
        if name:match('%.bin$') then
            local base = name:sub(1, -5)
            local bin = fio.pathjoin(FIXTURES_DIR, name)
            local txt = fio.pathjoin(FIXTURES_DIR, base .. '.txtpb')
            local type_full
            for line in io.lines(txt) do
                local m = line:match('^# type:%s*(%S+)')
                if m then type_full = m; break end
            end
            out[#out + 1] = {base = base, bin = bin, full = type_full}
        end
    end
    return out
end

local g = t.group('parser.interop')
for _, fx in ipairs(fixtures()) do
    g['test_' .. fx.base] = function()
        local short = fx.full:gsub('^hello%.', '')
        local enc = hello_dynamic[short .. '_encode']
        local dec = hello_dynamic[short .. '_decode']
        t.assert(enc and dec, 'dynamic module has ' .. short)

        local golden = slurp(fx.bin)
        local decoded = dec(golden)
        local reencoded = enc(decoded)

        t.assert_equals(hex(reencoded), hex(golden),
            'dynamic round-trip diverges from golden for ' .. fx.base)
    end
end

-- ---------------------------------------------------------------------------
-- Cross-module: dynamic-decoded message can be re-encoded via the
-- generated module byte-for-byte, and vice versa.
-- ---------------------------------------------------------------------------
local g_cross = t.group('parser.cross_module')
g_cross.test_cross_module_byte_equality = function()
    for _, fx in ipairs(fixtures()) do
        local short = fx.full:gsub('^hello%.', '')
        local golden = slurp(fx.bin)
        local from_dyn  = hello_dynamic[short .. '_decode'](golden)
        local from_stat = hello_static[short .. '_decode'](golden)
        t.assert_equals(
            hex(hello_static[short .. '_encode'](from_dyn)),
            hex(hello_dynamic[short .. '_encode'](from_stat)),
            'cross-module mismatch on ' .. fx.base)
    end
end
