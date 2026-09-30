-- The idempotency_level method option in service descriptors: the
-- codegen (both modes), pb.parse and pb.from_pb all expose it as
-- `methods[name].idempotency_level`, the enum name, nil when unknown.
local t = require('luatest')
local fio = require('fio')
local pb = require('pb')

local g = t.group('idempotency')

local SRC = [[
syntax = "proto3";
package idem;
message M { string a = 1; }
service S {
  rpc Get(M) returns (M) { option idempotency_level = NO_SIDE_EFFECTS; }
  rpc Put(M) returns (M) {
    option idempotency_level = IDEMPOTENT;
  }
  rpc Unknown(M) returns (M) { option idempotency_level = IDEMPOTENCY_UNKNOWN; }
  rpc Plain(M) returns (M);
  rpc Nested(M) returns (M) {
    option deprecated = true;
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}
]]

local function check(methods)
    t.assert_equals(methods.Get.idempotency_level, 'NO_SIDE_EFFECTS')
    t.assert_equals(methods.Put.idempotency_level, 'IDEMPOTENT')
    t.assert_equals(methods.Unknown.idempotency_level, nil)
    t.assert_equals(methods.Plain.idempotency_level, nil)
    t.assert_equals(methods.Nested.idempotency_level, 'NO_SIDE_EFFECTS')
end

for _, mode in ipairs({'full', 'runtime'}) do
    g['test_codegen_' .. mode] = function()
        local lib = require(mode .. '.library.library_pb')
        local methods = lib.Library_service.methods
        t.assert_equals(methods.GetBook.idempotency_level, 'NO_SIDE_EFFECTS')
        t.assert_equals(methods.ListBooks.idempotency_level, nil)
    end
end

g.test_parse = function()
    check(pb.parse(SRC).S_service.methods)
end

g.test_from_pb = function()
    local dir = fio.tempdir()
    local src = fio.pathjoin(dir, 'idem.proto')
    local f = assert(io.open(src, 'wb'))
    f:write(SRC)
    f:close()
    local out = fio.pathjoin(dir, 'set.pb')
    local cmd = ('protoc --descriptor_set_out=%q -I %q %q'):format(out, dir, src)
    local ok = os.execute(cmd)
    t.assert(ok == 0 or ok == true, cmd)
    f = assert(io.open(out, 'rb'))
    local bytes = f:read('*a')
    f:close()
    local set = pb.from_pb(bytes)
    check(set.files['idem.proto'].S_service.methods)
end

-- An aggregate option with nested braces before the level must not
-- end the method body early.
g.test_parse_aggregate_option = function()
    local mod = pb.parse([[
syntax = "proto3";
package agg;
message M { string a = 1; }
service S {
  rpc Get(M) returns (M) {
    option (foo.bar) = { a: { b: 1 } };
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  rpc Next(M) returns (M);
}
]])
    local methods = mod.S_service.methods
    t.assert_equals(methods.Get.idempotency_level, 'NO_SIDE_EFFECTS')
    t.assert_equals(methods.Next.name, 'Next')
end
