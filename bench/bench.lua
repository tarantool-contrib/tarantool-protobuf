#!/usr/bin/env tarantool
-- Microbenchmark harness for protoc-gen-tarantool.
--
-- Measures encode + decode throughput and allocation rate across 5 payload
-- sizes (~10 B, ~100 B, ~1 KB, ~10 KB, ~100 KB) for both codegen modes
-- (full inline / runtime descriptor). Emits a JSON document on stdout that
-- can be compared against `bench/baseline.json`.
--
-- Usage:
--   tarantool bench/bench.lua                  -- run, print JSON
--   tarantool bench/bench.lua --baseline       -- overwrite baseline.json
--   tarantool bench/bench.lua --compare        -- compare vs baseline.json
--                                                 exit nonzero if any
--                                                 throughput regresses >5%

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua for full rationale.
-- Without this the bench can intermittently report interpreter-only throughput.
jit.opt.start('sizemcode=64', 'maxmcode=4096')

-- Extend cpath so `require('pb.c_runtime')` finds runtime/pb/c_runtime.{so,dylib}
-- when PB_ENABLE_C=1. `.dylib` first matches the order in the Justfile (see
-- the comment there for why this matters when both extensions coexist).
package.cpath = './runtime/?.dylib;./runtime/?.so;'
    .. './runtime/?/init.dylib;./runtime/?/init.so;'
    .. package.cpath

local clock = require('clock')
local json  = require('json')
local fio   = require('fio')

local MODES = {'full', 'runtime'}

-- Per-fixture size lists. The proto3 Person fixture sweeps five decades to
-- characterize behavior across allocation regimes; proto2 only needs two
-- sizes (one fits-in-cache, one larger) because its purpose is to gate
-- the proto2-specific shapes (required/group/extension), not to recharacterize
-- alloc scaling — that's already covered by Person.
local PERSON_SIZES = {
    {label = '10B',   target = 10},
    {label = '100B',  target = 100},
    {label = '1KB',   target = 1024},
    {label = '10KB',  target = 10240},
    {label = '100KB', target = 102400},
}
local PROTO2_SIZES = {
    {label = 'min',  target = 0},     -- minimal: required + extension only
    {label = 'mid',  target = 1024},  -- with group + repeated + extension
}

-- Build a `Person` payload whose encoded size is close to `target` bytes.
--
-- Strategy: pick one knob per decade so each size still exercises the
-- full encoder (varints, packed repeated, length-delimited strings,
-- nested messages) — not just one giant byte-string.
local function build_person_payload(target)
    if target <= 10 then
        -- name(6) + age(1) ⇒ 10 bytes encoded.
        return {name = 'alicia', age = 42}
    end
    if target <= 100 then
        -- name (~target-10 bytes string) gives a tight fit (~94 B).
        return {
            name  = string.rep('a', target - 10),
            age   = 42,
        }
    end
    -- For >=1 KB: scale `emails` (length-delimited strings) and add nested
    -- + packed repeated fields so the shape stays representative.
    local per_email   = 36  -- tag(1) + len(1) + 32 bytes content + slack
    local fixed_bytes = 80  -- name + age + address + lucky_numbers + overhead
    local n_emails    = math.max(1, math.floor((target - fixed_bytes) / per_email))
    local p = {
        name = 'alicia',
        age  = 42,
        address = {street = '1 Main St', city = 'Springfield', zip = 12345},
        lucky_numbers = {7, 13, 21, 42, 99},
        emails = {},
    }
    for i = 1, n_emails do
        p.emails[i] = string.rep('e', 28) .. string.format('%04d', i)
    end
    return p
end

-- Build a `BenchPayload` proto2 message. Two sizes:
--   * `min` — required + one extension (~12 bytes): tightest measure of the
--     per-message overhead the new code paths add.
--   * `mid` — required + group + repeated + extension (~1 KB): exercises
--     SGROUP/EGROUP framing, the packed-int32 path under proto2 semantics
--     (NOT packed unless explicitly marked), the `pairs`-free
--     extensions_list walk, and the nested message branch.
local function build_proto2_payload(target)
    if target <= 0 then
        return {
            id = 7,
            _extensions = {
                ['proto2_basic.ext_count'] = 42,
            },
        }
    end
    local n_tags    = 16
    local per_tag   = 30
    local tags      = {}
    for i = 1, n_tags do
        tags[i] = string.rep('t', per_tag - 2) .. string.format('%02d', i)
    end
    local lucky = {}
    for i = 1, 8 do lucky[i] = 1000 + i end
    return {
        id            = 7,
        name          = 'bench',
        retries       = 9,
        lucky_numbers = lucky,
        tags          = tags,
        inner         = {key = string.rep('k', 16), weight = 3},
        stats         = {latency_ns = 1234567, attempts = 4},
        _extensions = {
            ['proto2_basic.ext_count'] = 99,
            ['proto2_basic.ext_label'] = string.rep('x', 32),
        },
    }
end

-- Each fixture binds a schema + payload builder + sizes to bench.
local FIXTURES = {
    {
        name = 'hello.Person',
        module_path = '.hello.hello_pb',
        encode_field = 'Person_encode',
        decode_field = 'Person_decode',
        build_payload = build_person_payload,
        sizes = PERSON_SIZES,
    },
    {
        name = 'proto2_basic.BenchPayload',
        module_path = '.proto2_basic.proto2_basic_pb',
        encode_field = 'BenchPayload_encode',
        decode_field = 'BenchPayload_decode',
        build_payload = build_proto2_payload,
        sizes = PROTO2_SIZES,
    },
}

-- Pick iteration count adaptively: smaller messages need more iters to
-- amortize loop + clock overhead; larger messages need fewer to keep
-- wall time bounded.
local function iter_count(size_bytes)
    if size_bytes <  100   then return 200000 end
    if size_bytes <  2000  then return  50000 end
    if size_bytes <  20000 then return   5000 end
    return 500
end

-- Median + min/max from a small sample. Median rejects single-trace
-- compilation outliers; min is closer to steady-state JIT performance.
local function summarize(samples)
    table.sort(samples)
    local n = #samples
    local median = samples[math.floor((n + 1) / 2)]
    return {
        median = median,
        min    = samples[1],
        max    = samples[n],
    }
end

local function time_loop(fn, n)
    local t0 = clock.monotonic64()
    for _ = 1, n do fn() end
    local t1 = clock.monotonic64()
    return tonumber(t1 - t0) / 1e9  -- seconds
end

local function bench_throughput(fn, n, runs)
    -- Warmup: let the JIT compile.
    for _ = 1, math.min(n, 1000) do fn() end
    local times = {}
    for r = 1, runs do
        collectgarbage('collect')
        times[r] = time_loop(fn, n)
    end
    local s = summarize(times)
    return {
        ns_per_op   = s.median / n * 1e9,
        msgs_per_s  = n / s.median,
        runs        = runs,
        iters       = n,
        time_min_s  = s.min,
        time_med_s  = s.median,
        time_max_s  = s.max,
    }
end

-- Allocation per op. Stop GC, run a small batch, measure delta in KB.
-- Restart GC immediately so the next bench isn't polluted.
--
-- Iteration count is capped so peak retained memory stays under ~64 MB
-- — for 100KB messages 1000 iters would hold 500MB live and trigger OS
-- swap pressure that skews adjacent throughput readings.
local function bench_alloc(fn, expected_bytes)
    local budget   = 64 * 1024 * 1024
    local per_iter = math.max(1, expected_bytes) * 2
    local n        = math.max(100, math.min(2000, math.floor(budget / per_iter)))
    -- prime: ensure any one-shot allocations (descriptor lookups, jit
    -- traces) already happened.
    for _ = 1, 100 do fn() end
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, n do fn() end
    local after = collectgarbage('count')
    collectgarbage('restart')
    collectgarbage('collect')
    return {
        kb_per_op    = (after - before) / n,
        bytes_per_op = (after - before) * 1024 / n,
        iters        = n,
    }
end

local function bench_one(fixture, mode, size)
    local mod    = require(mode .. fixture.module_path)
    local encode = mod[fixture.encode_field]
    local decode = mod[fixture.decode_field]

    local payload = fixture.build_payload(size.target)
    local bytes   = encode(payload)
    local n       = iter_count(#bytes)
    local runs    = 5

    -- Re-decode once so warmup hot path matches.
    local _ = decode(bytes)

    local enc_throughput = bench_throughput(function() encode(payload) end, n, runs)
    local enc_alloc      = bench_alloc(function() encode(payload) end, #bytes)
    enc_throughput.mb_per_s = #bytes * enc_throughput.msgs_per_s / 1e6
    enc_throughput.alloc_kb_per_op    = enc_alloc.kb_per_op
    enc_throughput.alloc_bytes_per_op = enc_alloc.bytes_per_op

    local dec_throughput = bench_throughput(function() decode(bytes) end, n, runs)
    local dec_alloc      = bench_alloc(function() decode(bytes) end, #bytes)
    dec_throughput.mb_per_s = #bytes * dec_throughput.msgs_per_s / 1e6
    dec_throughput.alloc_kb_per_op    = dec_alloc.kb_per_op
    dec_throughput.alloc_bytes_per_op = dec_alloc.bytes_per_op

    return {
        schema     = fixture.name,
        mode       = mode,
        size_label = size.label,
        size_bytes = #bytes,
        encode     = enc_throughput,
        decode     = dec_throughput,
    }
end

local function run_all()
    local schemas = {}
    for _, fixture in ipairs(FIXTURES) do
        io.stderr:write(string.format('schema %s\n', fixture.name))
        local results = {}
        for _, mode in ipairs(MODES) do
            for _, size in ipairs(fixture.sizes) do
                io.stderr:write(string.format('  bench %s/%s ... ', mode, size.label))
                io.stderr:flush()
                local r = bench_one(fixture, mode, size)
                io.stderr:write(string.format(
                    'enc %.0f msgs/s (%.1f MB/s)  dec %.0f msgs/s (%.1f MB/s)\n',
                    r.encode.msgs_per_s, r.encode.mb_per_s,
                    r.decode.msgs_per_s, r.decode.mb_per_s))
                results[#results + 1] = r
            end
        end
        schemas[#schemas + 1] = {schema = fixture.name, results = results}
    end
    return {
        tarantool = _TARANTOOL,
        jit       = jit and jit.version or nil,
        schemas   = schemas,
    }
end

-- Render JSON deterministically: arrays preserve order, but Lua tables
-- iterate in hash order. We control key emission for each level.
local function render_metric(t)
    return string.format(
        '{"ns_per_op": %.1f, "msgs_per_s": %.0f, "mb_per_s": %.3f, '
        .. '"alloc_kb_per_op": %.3f, "alloc_bytes_per_op": %.1f, '
        .. '"iters": %d, "runs": %d, "time_med_s": %.6f, '
        .. '"time_min_s": %.6f, "time_max_s": %.6f}',
        t.ns_per_op, t.msgs_per_s, t.mb_per_s,
        t.alloc_kb_per_op, t.alloc_bytes_per_op,
        t.iters, t.runs, t.time_med_s, t.time_min_s, t.time_max_s)
end

local function render(doc)
    local lines = {}
    lines[#lines + 1] = '{'
    lines[#lines + 1] = string.format('  "tarantool": %s,', json.encode(doc.tarantool))
    lines[#lines + 1] = string.format('  "jit": %s,', json.encode(doc.jit or json.NULL))
    lines[#lines + 1] = '  "schemas": ['
    for si, schema in ipairs(doc.schemas) do
        local schema_sep = (si == #doc.schemas) and '' or ','
        lines[#lines + 1] = '    {'
        lines[#lines + 1] = string.format('      "schema": %s,', json.encode(schema.schema))
        lines[#lines + 1] = '      "results": ['
        for i, r in ipairs(schema.results) do
            local sep = (i == #schema.results) and '' or ','
            lines[#lines + 1] = '        {'
            lines[#lines + 1] = string.format('          "mode": %s,', json.encode(r.mode))
            lines[#lines + 1] = string.format('          "size_label": %s,', json.encode(r.size_label))
            lines[#lines + 1] = string.format('          "size_bytes": %d,', r.size_bytes)
            lines[#lines + 1] = string.format('          "encode": %s,', render_metric(r.encode))
            lines[#lines + 1] = string.format('          "decode": %s', render_metric(r.decode))
            lines[#lines + 1] = '        }' .. sep
        end
        lines[#lines + 1] = '      ]'
        lines[#lines + 1] = '    }' .. schema_sep
    end
    lines[#lines + 1] = '  ]'
    lines[#lines + 1] = '}'
    return table.concat(lines, '\n') .. '\n'
end

-- Hardware-portable baseline: throughput (msgs/s, MB/s) varies with CPU
-- load and is unsuitable for committed baselines. Allocation per op is
-- reproducible to within ~10 bytes regardless of machine — it counts
-- bytes, not time — so that's all we commit. Throughput is in --print
-- output for human inspection only.
local function reduce_for_baseline(doc)
    local out_schemas = {}
    for _, schema in ipairs(doc.schemas) do
        local by_key = {}
        for _, r in ipairs(schema.results) do
            by_key[r.mode .. '/' .. r.size_label] = r
        end
        -- Recover size order from the first mode's run (declaration order).
        local seen, sizes = {}, {}
        for _, r in ipairs(schema.results) do
            if not seen[r.size_label] then
                seen[r.size_label] = true
                sizes[#sizes + 1] = r.size_label
            end
        end
        local results = {}
        for _, label in ipairs(sizes) do
            local full    = by_key['full/'    .. label]
            local runtime = by_key['runtime/' .. label]
            results[#results + 1] = {
                size_label = label,
                size_bytes = full.size_bytes,
                encode = {
                    alloc_kb_per_op_full    = full.encode.alloc_kb_per_op,
                    alloc_kb_per_op_runtime = runtime.encode.alloc_kb_per_op,
                },
                decode = {
                    alloc_kb_per_op_full    = full.decode.alloc_kb_per_op,
                    alloc_kb_per_op_runtime = runtime.decode.alloc_kb_per_op,
                },
            }
        end
        out_schemas[#out_schemas + 1] = {schema = schema.schema, results = results}
    end
    return {schemas = out_schemas}
end

local function render_baseline(reduced)
    local lines = {'{'}
    lines[#lines + 1] = '  "schemas": ['
    for si, schema in ipairs(reduced.schemas) do
        local schema_sep = (si == #reduced.schemas) and '' or ','
        lines[#lines + 1] = '    {'
        lines[#lines + 1] = string.format('      "schema": %s,', json.encode(schema.schema))
        lines[#lines + 1] = '      "results": ['
        for i, r in ipairs(schema.results) do
            local sep = (i == #schema.results) and '' or ','
            lines[#lines + 1] = '        {'
            lines[#lines + 1] = string.format('          "size_label": %s,', json.encode(r.size_label))
            lines[#lines + 1] = string.format('          "size_bytes": %d,', r.size_bytes)
            lines[#lines + 1] = string.format(
                '          "encode": {"alloc_kb_per_op_full": %.3f, '
                .. '"alloc_kb_per_op_runtime": %.3f},',
                r.encode.alloc_kb_per_op_full,
                r.encode.alloc_kb_per_op_runtime)
            lines[#lines + 1] = string.format(
                '          "decode": {"alloc_kb_per_op_full": %.3f, '
                .. '"alloc_kb_per_op_runtime": %.3f}',
                r.decode.alloc_kb_per_op_full,
                r.decode.alloc_kb_per_op_runtime)
            lines[#lines + 1] = '        }' .. sep
        end
        lines[#lines + 1] = '      ]'
        lines[#lines + 1] = '    }' .. schema_sep
    end
    lines[#lines + 1] = '  ]'
    lines[#lines + 1] = '}'
    return table.concat(lines, '\n') .. '\n'
end

-- Compare two reduced baselines, return list of regressions exceeding
-- `tolerance` (fraction, e.g. 0.05 = 5%).
--
-- Allocation per op is the regression gate. It's hardware-independent
-- (counts bytes, not time), reproducible to within ~10 bytes per op,
-- and a direct measure of encoder/decoder efficiency. Throughput
-- ratios swing 30%+ run-to-run on a busy laptop — useless as a gate.
local function compare(current, baseline, tolerance)
    local function index(b)
        local m = {}
        for _, schema in ipairs(b.schemas or {}) do
            for _, r in ipairs(schema.results) do
                m[schema.schema .. '|' .. r.size_label] = r
            end
        end
        return m
    end
    local cur  = index(current)
    local base = index(baseline)
    local regressions = {}
    -- Walk in baseline declaration order so the report is stable.
    for _, schema in ipairs(baseline.schemas or {}) do
        for _, r in ipairs(schema.results) do
            local key = schema.schema .. '|' .. r.size_label
            local c = cur[key]
            local b = base[key]
            if c and b then
                for _, op in ipairs({'encode', 'decode'}) do
                    for _, ak in ipairs({'alloc_kb_per_op_full', 'alloc_kb_per_op_runtime'}) do
                        local bv, cv = b[op][ak], c[op][ak]
                        if bv > 0 and cv > bv * (1 + tolerance) then
                            regressions[#regressions + 1] = string.format(
                                '%s %s/%s %s: %.3f -> %.3f KB/op (+%.1f%%)',
                                schema.schema, r.size_label, op, ak,
                                bv, cv, (cv / bv - 1) * 100)
                        end
                    end
                end
            end
        end
    end
    return regressions
end

local args = {...}
local mode_flag = args[1] or '--print'

local C_ENABLED = (os.getenv('PB_ENABLE_C') == '1') and (require('pb').c_runtime ~= nil)

if C_ENABLED and (mode_flag == '--baseline' or mode_flag == '--compare') then
    -- The alloc-per-op baseline is Lua-only by design. The C codec has a
    -- different allocation shape (C-side scratch + a single Lua-side
    -- result string) that would noise the gate. Re-run without
    -- PB_ENABLE_C=1 for baseline/compare ops.
    io.stderr:write('bench.lua: --baseline and --compare are Lua-only; '
        .. 'unset PB_ENABLE_C and rerun\n')
    os.exit(2)
end

io.stderr:write(string.format('tarantool-protobuf bench (%s)%s\n',
    _TARANTOOL, C_ENABLED and ', C runtime ENABLED' or ''))
local doc = run_all()

-- Relabel runtime-mode results to `c-runtime` when the C dispatch is
-- active. The bench fixture iterates over generated modules from
-- examples/expected/runtime/, which call pb.encode / pb.decode — those
-- dispatch through the C codec when desc.c_plan compiles. Full-mode
-- modules inline wire calls and don't go through pb.encode, so the
-- full-mode column is unchanged from the Lua run.
if C_ENABLED then
    for _, schema in ipairs(doc.schemas) do
        for _, r in ipairs(schema.results) do
            if r.mode == 'runtime' then r.mode = 'c-runtime' end
        end
    end
end

if mode_flag == '--print' then
    io.write(render(doc))
elseif mode_flag == '--baseline' then
    local out = render_baseline(reduce_for_baseline(doc))
    local path = 'bench/baseline.json'
    local f = assert(fio.open(path, {'O_WRONLY', 'O_CREAT', 'O_TRUNC'}, tonumber('644', 8)))
    f:write(out)
    f:close()
    io.stderr:write(string.format('wrote %s\n', path))
    io.write(out)
elseif mode_flag == '--compare' then
    local path = 'bench/baseline.json'
    local f = assert(fio.open(path, {'O_RDONLY'}))
    local baseline = json.decode(f:read())
    f:close()
    local current = reduce_for_baseline(doc)
    local regs = compare(current, baseline, 0.05)
    if #regs == 0 then
        io.stderr:write('no regressions >5% vs baseline\n')
        os.exit(0)
    end
    io.stderr:write(string.format('REGRESSIONS vs baseline (>5%%):\n'))
    for _, r in ipairs(regs) do io.stderr:write('  ' .. r .. '\n') end
    os.exit(1)
else
    io.stderr:write('usage: bench.lua [--print | --baseline | --compare]\n')
    os.exit(2)
end

os.exit(0)
