-- Regression coverage for the 64-bit zigzag helpers under the JIT.
--
-- The arm64 backend of LuaJIT before upstream commit 90742d91 ("ARM64:
-- Don't fuse sign extensions into logical operands", LuaJIT#1076) folds the
-- sign extension of an int into the operand of a logical instruction, so a
-- compiled `bit.bnot` of a sign-extended value computes `x << 48` instead of
-- `~x`. Tarantool's LuaJIT predates that fix. The zigzag helpers used
-- `bit.bnot` for the negative branch, so `encode_sint64(-5)` produced a
-- 10-byte varint instead of 0x09 once the encoding loop was compiled.
-- x86_64 is not affected. Each check below runs one helper, with values read
-- from a table so they are not constants, through a call site shared with
-- other kinds as a descriptor-driven field walk does, long enough for the
-- loop to be compiled, and asserts every result.
local t = require('luatest')
local ffi = require('ffi')
local wire = require('pb.wire')

local g = t.group('wire.zigzag_jit')

local INT64 = ffi.typeof('int64_t')
local T = wire.TYPE_INFO
local ROUNDS = 3000

-- Run `fn(kind, value)` over `cases` ({kind, value, want}) ROUNDS times from
-- a single call site and return the mismatches for kinds in `check`.
local function drive(fn, cases, check)
    local bad = {}
    for round = 1, ROUNDS do
        for j = 1, #cases do
            local c = cases[j]
            local got = fn(c[1], c[2])
            if check[c[1]] and got ~= c[3] then
                bad[#bad + 1] = string.format('round %d: %s(%s) = %s, want %s',
                    round, c[1], tostring(c[2]), tostring(got), tostring(c[3]))
                if #bad >= 3 then return bad end
            end
        end
    end
    return bad
end

g.before_all(function()
    -- The miscompile only exists in compiled traces.
    t.skip_if(not jit.status(), 'the JIT is off')
end)

g.test_sint64_encode_through_a_shared_call_site = function()
    local function encode(kind, v) return T[kind].encode(v) end
    local bad = drive(encode, {
        {'int32', 2, '\2'},
        {'double', 1.5, wire.encode_double(1.5)},
        {'sint64', -5, '\9'},
        {'sint64', -1, '\1'},
        {'sint64', INT64(-300), '\215\4'},
    }, {sint64 = true})
    t.assert_equals(bad, {})
end

-- The int64_t-taking variant generated full-mode code calls.
g.test_zigzag_encode64_i_through_a_shared_call_site = function()
    local E = {
        int32  = T.int32.encode,
        double = T.double.encode,
        zz     = function(n)
            return wire.encode_varint(wire.zigzag_encode64_i(INT64(n)))
        end,
    }
    local function encode(kind, v) return E[kind](v) end
    local bad = drive(encode, {
        {'int32', 2, '\2'},
        {'double', 1.5, wire.encode_double(1.5)},
        {'zz', -5, '\9'},
        {'zz', -1, '\1'},
        {'zz', -300, '\215\4'},
    }, {zz = true})
    t.assert_equals(bad, {})
end

-- zigzag_decode64 had a `bit.bnot` too, but its operand is a shifted
-- uint64, not a sign extension, so the miscompile does not reach it; this
-- pins the exact results through the same kind of site.
g.test_sint64_decode_through_a_shared_call_site = function()
    local function decode(kind, b) return (T[kind].decode(b, 1)) end
    local bad = drive(decode, {
        {'int32', '\2', 2},
        {'double', wire.encode_double(1.5), 1.5},
        {'sint64', '\9', -5LL},
        {'sint64', '\1', -1LL},
        {'sint64', '\215\4', -300LL},
    }, {sint64 = true})
    t.assert_equals(bad, {})
end
