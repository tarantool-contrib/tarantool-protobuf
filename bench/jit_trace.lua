#!/usr/bin/env tarantool
-- Trace-stability gate for protobuf encode/decode hot paths.
--
-- For each hot encode/decode path, run a few thousand iterations with
-- a `trace` listener attached and assert that no trace aborts in
-- `runtime/pb/*` or `examples/expected/**/*_pb.lua` fall into the
-- "fatal" set — bytecodes/builtins LuaJIT can't compile, blacklists,
-- persistent type instability. Benign aborts (loop boundaries, retry
-- recording, short warmup traces) are ignored; they are normal JIT
-- bookkeeping and don't mean the hot path fell off the JIT.
--
-- Scope: `pairs()` over a hash compiles to bytecode ISNEXT, which is
-- NYI in the LuaJIT 2.1 fork Tarantool ships. That makes map-field
-- encode/decode (the only place we use `pairs` in the hot path)
-- inherently un-stay-on-trace. The last scenario pins that limitation
-- so we notice if upstream ever lifts it.
--
-- Run as a standalone tarantool script — not via luatest. On macOS
-- arm64, luatest's framework load fills the JIT mcode arena before
-- tests run, so traces in the test body fail with "failed to allocate
-- mcode memory" rather than the real reason we're trying to measure.
--
-- Usage:
--   tarantool bench/jit_trace.lua
-- exit 0 = all checks passed; non-zero = a fatal abort was hit or a
-- hot path failed to compile at all.

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

jit.on()
-- macOS arm64 mcode arena hardening: the default sizemcode/maxmcode are too
-- small for our combined hot-path codegen footprint, and the allocator
-- intermittently fails to find an executable page within the signed-32-bit
-- offset window. When that happens the gate reports every check as
-- 'stops=0' with no diagnostic — indistinguishable from a real JIT
-- topology regression. Raising the arena past our peak need eliminates
-- the failure mode and keeps the gate's pass/fail signal load-bearing.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

local vmdef = require('jit.vmdef')

-- Codes from jit.vmdef.traceerr (1-indexed). We treat these as fatal —
-- they mean the JIT genuinely cannot compile the path, not that it's
-- reorganizing traces. See vmdef.traceerr for the full list.
local FATAL = {
    [5]  = true,  -- blacklisted
    [7]  = true,  -- NYI: bytecode %s
    [11] = true,  -- bad argument type
    [15] = true,  -- NYI: unsupported variant of FastFunc %s
    [16] = true,  -- NYI: return to lower frame
    [18] = true,  -- missing metamethod
    [19] = true,  -- looping index lookup
    [20] = true,  -- NYI: mixed sparse/dense table
    [22] = true,  -- NYI: unsupported C type conversion
    [23] = true,  -- NYI: unsupported C function type
    [26] = true,  -- persistent type instability
}

local function is_our_code(src)
    if type(src) ~= 'string' then return false end
    return src:match('runtime/pb/') ~= nil
        or src:match('examples/expected/') ~= nil
end

local function fmt_reason(code, info)
    local msg = vmdef.traceerr[code] or ('?code=' .. tostring(code))
    return (msg:gsub('%%s', tostring(info or '?')))
end

local jutil = require('jit.util')

local function record(fn, warmup_iters, measured_iters)
    for _ = 1, warmup_iters do fn() end
    jit.flush()
    local fatal, stops = {}, 0
    local start_loc, stop_loc = {}, {}  -- trace_no -> {src, line, pc, parent}
    local cb = function(what, tr, func, pc, code, info)
        if what == 'start' and func then
            local di = debug.getinfo(func, 'S')
            -- For side traces: `code` is the parent trace number,
            -- `info` is the parent's exit index. Root traces have code=nil.
            start_loc[tr] = {
                src = di.short_src, line = di.linedefined, pc = pc,
                parent = code,  -- nil for root, traceno for side trace
            }
        elseif what == 'stop' then
            stops = stops + 1
            if func then
                local di = debug.getinfo(func, 'S')
                stop_loc[tr] = {src = di.short_src, line = di.linedefined}
            end
        elseif what == 'abort' and FATAL[code] then
            local di = func and debug.getinfo(func, 'S') or {short_src = '?'}
            if is_our_code(di.short_src) then
                fatal[#fatal + 1] = {
                    src  = di.short_src,
                    line = di.linedefined,
                    code = code,
                    info = info,
                }
            end
        end
    end
    -- Defensive: keep the listener out of the JIT. If the callback ever
    -- becomes hot enough to be traced, recording the cb while recording
    -- the function-under-test races and stop events are dropped (starts
    -- still fire, but most traces never finish recording). The current
    -- cb body branches enough to dodge this organically, but any future
    -- extension (per-event timing, pc context capture, etc.) would
    -- re-trigger it silently. Reproducible in a few lines: a fat cb
    -- that appends event tuples to a table drops Person_encode's stop
    -- count from ~9 to 0 on this codebase.
    jit.off(cb)
    jit.attach(cb, 'trace')
    for _ = 1, measured_iters do fn() end
    jit.attach(cb)
    -- A "bridge" we care about is a SIDE trace (i.e. a child compiled off
    -- a guard exit of some parent trace) whose own natural exit drops to
    -- the interpreter. Pattern: parent runs hot → guard fails → side
    -- trace covers the divergent code → falls back to VM dispatch instead
    -- of stitching to another trace. Each such bridge costs a few hundred
    -- ns of interp dispatch on every hot iteration.
    --
    -- Pure root traces that end in linktype=interpreter are NOT bridges:
    -- they're short JIT'd snippets entered from interpreter and exit back
    -- to it, with no extra dispatch cost beyond normal interp execution
    -- of the surrounding code.
    local bridges = {}
    for tr = 1, 1024 do
        local info = jutil.traceinfo(tr)
        if not info then break end
        if info.linktype == 'interpreter' and info.link == 0 then
            local s = start_loc[tr] or stop_loc[tr]
            if s and is_our_code(s.src) and s.parent then
                bridges[#bridges + 1] = {
                    tr     = tr,
                    src    = s.src,
                    line   = s.line,
                    pc     = s.pc,
                    parent = s.parent,
                }
            end
        end
    end
    return fatal, stops, bridges
end

local failures = 0
local checks   = 0

local function check(label, fn, opts)
    opts = opts or {}
    local fatal, stops, bridges = record(fn, 2000, 5000)
    checks = checks + 1
    if #fatal > 0 and not opts.expect_fatal_in then
        failures = failures + 1
        io.stderr:write(string.format(
            '  [FAIL] %s — %d fatal abort(s) in our code:\n', label, #fatal))
        local seen = {}
        for _, a in ipairs(fatal) do
            local k = a.src .. ':' .. a.line .. '|' .. a.code
            if not seen[k] then
                seen[k] = true
                io.stderr:write(string.format(
                    '         %s:%d  %s\n',
                    a.src, a.line, fmt_reason(a.code, a.info)))
            end
        end
        return
    end
    if opts.expect_fatal_in then
        local saw = false
        for _, a in ipairs(fatal) do
            if a.src:match(opts.expect_fatal_in) then saw = true; break end
        end
        if not saw then
            failures = failures + 1
            io.stderr:write(string.format(
                '  [FAIL] %s — expected a fatal abort in %q (known limitation), got none\n',
                label, opts.expect_fatal_in))
            return
        end
        io.stderr:write(string.format(
            '  [PIN ] %s — expected NYI present (known LuaJIT 2.1 limitation)\n',
            label))
        return
    end
    if stops == 0 then
        failures = failures + 1
        io.stderr:write(string.format(
            '  [FAIL] %s — no trace was compiled (stops=0)\n', label))
        return
    end
    -- Interpreter bridges (side trace -> interp) are real but their
    -- compilation timing is non-deterministic — across 10 runs you'll
    -- see 0–4 in decoder paths (parent trace bakes in the 1-byte varint
    -- fast path, the multi-byte side trace can't self-loop). They're a
    -- topology metric, not a pass/fail signal — report them for
    -- visibility, don't fail the gate.
    io.stderr:write(string.format(
        '  [ OK ] %s  (stops=%d, bridges=%d)\n', label, stops, #bridges))
    if #bridges > 0 then
        for _, b in ipairs(bridges) do
            io.stderr:write(string.format(
                '         info: bridge tr%d  side-of tr%s  %s:%d  pc=%s\n',
                b.tr, tostring(b.parent), b.src, b.line, tostring(b.pc)))
        end
    end
end

-- ---------------------------------------------------------------------------

io.stderr:write('tarantool-protobuf trace-stability gate ('
    .. (jit.version or '?') .. ')\n')

for _, mode in ipairs({'full', 'runtime'}) do
    local hello = require(mode .. '.hello.hello_pb')

    local addr = {street = '1 Main St', city = 'Springfield', zip = 12345}
    local addr_bytes = hello.Address_encode(addr)

    -- Person with repeated string, packed int32, nested message — no
    -- map fields (see top-of-file scope note).
    local person = {
        name    = 'alicia', age = 42,
        address = addr,
        lucky_numbers = {7, 13, 21, 42, 99, 144, 233, 377},
        emails  = {'a@b.c', 'd@e.f', 'g@h.i', 'j@k.l'},
        status  = hello.Status.OK,
    }
    local person_bytes = hello.Person_encode(person)

    local result = {value = 'ok'}
    local result_bytes = hello.Result_encode(result)

    check(mode .. '/Address_encode',
        function() hello.Address_encode(addr) end)
    check(mode .. '/Address_decode',
        function() hello.Address_decode(addr_bytes) end)
    check(mode .. '/Person_encode',
        function() hello.Person_encode(person) end)
    check(mode .. '/Person_decode',
        function() hello.Person_decode(person_bytes) end)
    check(mode .. '/Result_encode (oneof)',
        function() hello.Result_encode(result) end)
    check(mode .. '/Result_decode (oneof)',
        function() hello.Result_decode(result_bytes) end)

    -- Lazy hot paths: index build, sparse :get, untouched :encode
    -- (passthrough). The mutation/encode path (:set + :encode walking
    -- dirty fields) is not gated — it's expected to be slower-and-pairs,
    -- not a tight inner loop. Passthrough is what we promised to stay
    -- on trace, since untouched :encode just returns _bytes verbatim.
    check(mode .. '/Person_decode_lazy (index pass)',
        function() hello.Person_decode_lazy(person_bytes) end)
    check(mode .. '/Person_decode_lazy + :get x2',
        function()
            local v = hello.Person_decode_lazy(person_bytes)
            local _ = v:get('name'); _ = v:get('age')
        end)
    check(mode .. '/Person_decode_lazy + :encode (passthrough)',
        function()
            local _ = hello.Person_decode_lazy(person_bytes):encode()
        end)

    -- Multi-byte varint paths. The default Person fixture has all 1-byte
    -- varints (field IDs 1-15, lengths < 128, packed-int values < 128),
    -- so it only exercises encode_varint's fast path / decode_int32's
    -- inlined 1-byte branch. This fixture forces the 2/3-byte paths:
    --   * `name` is a 200-byte string → 2-byte LEN prefix, exercises
    --     encode_varint_slow's 2-byte branch and decode_string's
    --     2-byte LEN fallback.
    --   * `lucky_numbers` carry multi-byte values → packed payload is
    --     varint-of-varints all hitting the slow path.
    -- If these regress (e.g. encode_varint_slow grows past inline budget
    -- and parent traces stop inlining it), the gate fires.
    local big_person = {
        name = string.rep('x', 200),
        age  = 42,
        lucky_numbers = {150, 200, 1000, 20000, 50000, 100000, 200000, 500000},
    }
    local big_person_bytes = hello.Person_encode(big_person)
    check(mode .. '/Person_encode multi-byte varint',
        function() hello.Person_encode(big_person) end)
    check(mode .. '/Person_decode multi-byte varint',
        function() hello.Person_decode(big_person_bytes) end)
end

-- ---------------------------------------------------------------------------
-- Proto2-specific shapes: required, groups, extensions, closed enums.
--
-- The new code paths share most of their machinery with proto3 message and
-- scalar fields, but introduce three distinct shapes worth pinning:
--
--   1. The `required` writer wraps the regular scalar writer with a missing-
--      value error. Should stay JIT-stable when the value is set.
--   2. Group fields use SGROUP/EGROUP tags and a per-element body without a
--      length prefix. Different wire shape than messages; new writer/reader.
--   3. Extensions are walked at encode time via a `pairs()` over an array
--      view (`extensions_list`), and looked up at decode time via the
--      `extensions_by_id` hash. Both sides need to stay on trace; the
--      hash lookup is one cdata read so should be fine, but the encode
--      walk would abort if we used `pairs()` over a non-array — see the
--      list-view layer in pb.codec.
-- ---------------------------------------------------------------------------

for _, mode in ipairs({'full', 'runtime'}) do
    local p2 = require(mode .. '.proto2_basic.proto2_basic_pb')

    -- Required: encode emits a clear error on missing, but the happy path
    -- where the value is set should compile and stay on trace.
    local card = {r = 7}
    local card_bytes = p2.Cardinality_encode(card)
    check(mode .. '/Cardinality_encode (required)',
        function() p2.Cardinality_encode(card) end)
    check(mode .. '/Cardinality_decode (required)',
        function() p2.Cardinality_decode(card_bytes) end)

    -- Groups: SGROUP/EGROUP framed body, no length prefix. Singular path.
    local with_group = {singlegroup = {a = 7, s = 'ok'}}
    local with_group_bytes = p2.WithGroup_encode(with_group)
    check(mode .. '/WithGroup_encode (group)',
        function() p2.WithGroup_encode(with_group) end)
    check(mode .. '/WithGroup_decode (group)',
        function() p2.WithGroup_decode(with_group_bytes) end)

    -- Repeated groups: same shape, exercises the per-element bracket loop.
    local with_rep = {repgroup = {{n = 1}, {n = 2}, {n = 3}, {n = 4}}}
    local with_rep_bytes = p2.WithGroup_encode(with_rep)
    check(mode .. '/WithGroup_encode (repeated group)',
        function() p2.WithGroup_encode(with_rep) end)
    check(mode .. '/WithGroup_decode (repeated group)',
        function() p2.WithGroup_decode(with_rep_bytes) end)
end

-- Extensions: register a small proto2 fixture inline so the trace gate
-- doesn't depend on the bulky conformance schema. Exercises both encode
-- (walks _extensions and routes through encode_field) and decode (routes
-- an unknown tag through extensions_by_id → decode_extension).
do
    local p2tests = require('full.protobuf_test_messages.proto2.test_messages_proto2_pb')
    local Foo     = p2tests.TestAllTypesProto2_descriptor
    local msg = {
        _extensions = {
            ['protobuf_test_messages.proto2.extension_int32']  = 42,
            ['protobuf_test_messages.proto2.extension_string'] = 'hi',
        },
    }
    -- Encode-prime via the descriptor-driven path; tracing the inline
    -- emitted code wouldn't cover the extension loop (it's in codec.lua).
    local pb = require('pb')
    local ext_bytes = pb.encode(Foo, msg)
    check('full/extension_encode',
        function() pb.encode(Foo, msg) end)
    check('full/extension_decode',
        function() pb.decode(Foo, ext_bytes) end)
end

-- Pin the known map limitation: pairs() over a hash compiles to bytecode
-- ISNEXT, which Tarantool LuaJIT 2.1 can't trace. If this stops triggering,
-- upstream lifted the restriction and our scope claim can broaden.
do
    local hello = require('full.hello.hello_pb')
    local with_map = {
        name = 'alicia', age = 42,
        ages_by_nickname = {alicia = 1, bo = 2, carol = 3},
    }
    check('full/Person_encode with map (known NYI)',
        function() hello.Person_encode(with_map) end,
        {expect_fatal_in = 'hello_pb%.lua'})
end

io.stderr:write(string.format(
    '\n%d/%d checks passed\n', checks - failures, checks))
os.exit(failures > 0 and 1 or 0)
