#!/usr/bin/env tarantool
-- Tuple bridge (pb.tuple) versus per-row Lua tables.
--
-- The workload is the read and write path of an etcd-compatible
-- key-value store kept in a memtx space:
--
--   kv: key string, create_revision unsigned, mod_revision unsigned,
--       version unsigned, value any (nullable), lease_id unsigned
--       (nullable), storage_flags unsigned (nullable)
--
-- Sections:
--
--   Range   a Range request: `index:select(key, {iterator = 'GE',
--           limit = n})`, then a RangeResponse (header, repeated KeyValue
--           kvs, count, more) on the wire.
--             A     per row: tuple:unpack(), NULL lease -> 0, NULL value
--                   -> '', a KeyValue table; then one pb.encode of the
--                   whole response.
--             cand  pb.encode of the response without kvs, concatenated
--                   with conv:encode_repeated(2, tuples).
--           `select` times the index:select alone, so the share of the
--           loop the encode can still win back is visible.
--   Put     one KeyValue message per row into the space.
--             B     pb.decode -> table -> space:replace{...} in column
--                   order; decode-only: pb.decode alone, and pb.decode +
--                   box.tuple.new.
--             cand  conv:replace(bytes); decode-only: conv:decode(bytes).
--   Nested  kv.Record's `address` (kv.Address) held in a `map` column
--           (keyed by field name), an `array` column (positioned by field
--           number) and a `varbinary` column (the wire bytes verbatim):
--           the cost of matching nested keys by name.
--
-- Both Range and Put run twice: with small revisions (1-byte varints)
-- and with revisions above 2^32 (5-byte varints).
--
-- Before any timing, every candidate is checked against its baseline:
-- both outputs are decoded (pb.decode, or read back from the tuple) and
-- compared field by field. A fast path that produces the wrong answer
-- stops the bench instead of posting a number.
--
-- Harness: box runs in a temporary directory with wal_mode = 'none', so
-- replace measures memtx and the conversion, not the WAL write. The JIT
-- is switched on explicitly. Every figure is the median of REPS timed
-- repetitions after a warm-up; `spread` is (max - min) / median across
-- them. GC B/op is the growth of misc.getmetrics().gc_allocated over one
-- pass: Lua heap only, tuple memory (memtx arena, box.tuple.new) is not
-- counted.
--
-- Run:  tarantool bench/tuple_bench.lua                  (Lua codecs)
--       PB_ENABLE_C=1 tarantool bench/tuple_bench.lua    (C codecs)
-- With PB_ENABLE_C=1 the baselines' pb.encode / pb.decode run through
-- the C codec as well: that is the comparison a store enabling the C
-- runtime would see.

package.path = './runtime/?.lua;./runtime/?/init.lua;'
    .. './examples/expected/?.lua;./examples/expected/?/init.lua;'
    .. package.path
package.cpath = './runtime/?.dylib;./runtime/?.so;'
    .. './runtime/?/init.dylib;./runtime/?/init.so;'
    .. package.cpath

-- macOS arm64 mcode arena hardening; see bench/jit_trace.lua.
jit.opt.start('sizemcode=64', 'maxmcode=4096')
jit.on()

local clock = require('clock')
local fio = require('fio')
local varbinary = require('varbinary')
local pb = require('pb')

local C_REQUESTED = os.getenv('PB_ENABLE_C') == '1'
if C_REQUESTED and pb.c_runtime == nil then
    error('PB_ENABLE_C=1 but pb.c_runtime did not load; build it with '
          .. '`just build-c`')
end
local MODE = C_REQUESTED and 'c' or 'lua'

if misc == nil or misc.getmetrics == nil then
    error('misc.getmetrics() is not available in this Tarantool')
end

local NULL = box.NULL
local REPS = 7
local N_ROWS = 10000        -- rows in each kv space
local SIZES = {10, 100, 1000}
local PUT_ROWS = 1000       -- distinct messages in the Put working set
local NESTED_ROWS = 1000
local VALUE = string.rep('v', 64)

-- The bench never yields; lift the fiber slice limit that would
-- otherwise abort a long timed loop.
require('fiber').set_max_slice(3600)

local DATA_DIR = fio.tempdir()
box.cfg{
    memtx_dir = DATA_DIR,
    wal_dir   = DATA_DIR,
    log       = fio.pathjoin(DATA_DIR, 'tarantool.log'),
    wal_mode  = 'none',
}

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- KeyValue as in examples/proto/kv.proto, with the response that carries
-- it (etcd's RangeResponse and ResponseHeader, field for field).
local schema = pb.parse([[
syntax = "proto3";
package benchkv;

message KeyValue {
  bytes key = 1;
  int64 create_revision = 2;
  int64 mod_revision = 3;
  int64 version = 4;
  bytes value = 5;
  int64 lease = 6;
}

message ResponseHeader {
  uint64 cluster_id = 1;
  uint64 member_id = 2;
  int64 revision = 3;
  uint64 raft_term = 4;
}

message RangeResponse {
  ResponseHeader header = 1;
  repeated KeyValue kvs = 2;
  bool more = 3;
  int64 count = 4;
}
]])
local KeyValue = schema.KeyValue_descriptor
local RangeResponse = schema.RangeResponse_descriptor
local KVS_FIELD = 2

local kvpb = require('runtime.kv.kv_pb')
local Record = kvpb.Record_descriptor
local Address = kvpb.Address_descriptor

local KV_FORMAT = {
    {name = 'key',             type = 'string'},
    {name = 'create_revision', type = 'unsigned'},
    {name = 'mod_revision',    type = 'unsigned'},
    {name = 'version',         type = 'unsigned'},
    {name = 'value',           type = 'any',      is_nullable = true},
    {name = 'lease_id',        type = 'unsigned', is_nullable = true},
    {name = 'storage_flags',   type = 'unsigned', is_nullable = true},
}
local KV_OPTS = {columns = {lease = 'lease_id'}}

local function make_space(name, format)
    local s = box.schema.space.create(name, {format = format})
    s:create_index('primary', {parts = {1}})
    return s
end

local function key_of(i)
    return string.format('bench/range/%05d', i)
end

-- Row i of a kv space. Every fourth row has a lease, every 97th has a
-- NULL value (a tombstone-shaped row), storage_flags is NULL throughout.
local function kv_row(i, base)
    local lease = NULL
    if i % 4 == 0 then lease = base + 1000 + i end
    local value = VALUE
    if i % 97 == 0 then value = NULL end
    return {key_of(i), base + 1 + i % 100, base + 8 + i % 100, 1 + i % 5,
            value, lease, NULL}
end

local function fill(space, base)
    box.begin()
    for i = 1, N_ROWS do space:insert(kv_row(i, base)) end
    box.commit()
end

-- Revision bases: small keeps every revision under 128 (1-byte varints);
-- large puts every revision above 2^32.
local VARIANTS = {
    {label = 'small revisions (1-byte varints)', base = 0},
    {label = 'large revisions (> 2^32)',         base = 2 ^ 32 + 12345},
}

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local function median_spread(samples)
    table.sort(samples)
    local n = #samples
    local med = samples[math.floor((n + 1) / 2)]
    return med, (samples[n] - samples[1]) / med
end

-- fn(i) is one op. Returns median ns/op, spread and GC bytes/op.
local function measure(fn, iters)
    local warm = math.max(math.floor(iters / 4), 10)
    for i = 1, warm do fn(i) end
    local samples = {}
    for r = 1, REPS do
        collectgarbage('collect')
        local t0 = clock.monotonic64()
        for i = 1, iters do fn(i) end
        samples[r] = tonumber(clock.monotonic64() - t0) / iters
    end
    local med, spread = median_spread(samples)
    collectgarbage('collect')
    local before = misc.getmetrics().gc_allocated
    for i = 1, iters do fn(i) end
    local gc = (misc.getmetrics().gc_allocated - before) / iters
    return {ns = med, spread = spread, gc = gc}
end

-- A value as read back from a decoded message or a tuple, in a form
-- that compares across representations: integers (number or int64
-- cdata) and varbinary become strings, NULL becomes nil.
local function norm(v)
    if v == nil then return nil end
    if varbinary.is(v) then return tostring(v) end
    if type(v) == 'cdata' then
        local s = tostring(v)
        return (s:gsub('U?LL$', ''))
    end
    if type(v) == 'number' then
        return string.format('%.0f', v)
    end
    return v
end

local function check_eq(what, got, want)
    if norm(got) ~= norm(want) then
        error(string.format('self-check failed: %s: got %s, want %s', what,
                            tostring(got), tostring(want)), 2)
    end
end

local function fmt_ns(ns)
    if ns >= 1e6 then return string.format('%.2fms', ns / 1e6) end
    if ns >= 1e4 then return string.format('%.1fus', ns / 1e3) end
    return string.format('%.0fns', ns)
end

local function fmt_spread(m)
    return string.format('%s±%.0f%%', fmt_ns(m.ns), m.spread * 100)
end

-- ---------------------------------------------------------------------------
-- Range
-- ---------------------------------------------------------------------------

local function header(base)
    return {cluster_id = 14841639068965178418ULL,
            member_id = 10276657743932975437ULL,
            revision = base + 20000, raft_term = 7}
end

-- The request start keys an op cycles through, so the loop does not read
-- the same few index pages every time.
local function start_keys(limit)
    local keys = {}
    for j = 1, 256 do
        keys[j] = key_of((j * 7919) % (N_ROWS - limit) + 1)
    end
    return keys
end

local function range_ops(space, conv, base, limit)
    local index = space.index.primary
    local keys = start_keys(limit)
    local opts = {iterator = 'GE', limit = limit}

    local function select_only(i)
        return index:select(keys[i % 256 + 1], opts)
    end

    -- The store's per-row Range loop, verbatim in shape.
    local function kv_tables(tuples)
        local kvs = {}
        for j = 1, #tuples do
            local k, cr, mr, ver, val, lease, flags = tuples[j]:unpack()
            local _ = flags
            if lease == nil then lease = 0 end
            if val == nil then val = '' end
            kvs[j] = {key = k, create_revision = cr, mod_revision = mr,
                      version = ver, value = val, lease = lease}
        end
        return kvs
    end

    -- The store encodes the whole response in one pb.encode.
    local function baseline(i)
        local tuples = index:select(keys[i % 256 + 1], opts)
        local kvs = kv_tables(tuples)
        return pb.encode(RangeResponse, {header = header(base), kvs = kvs,
                                         count = #kvs, more = false})
    end

    local function candidate(i)
        local tuples = index:select(keys[i % 256 + 1], opts)
        return pb.encode(RangeResponse, {header = header(base),
                                         count = #tuples, more = false})
            .. conv:encode_repeated(KVS_FIELD, tuples)
    end

    return select_only, baseline, candidate
end

local function check_range(baseline, candidate, limit)
    for _, i in ipairs({0, 1, 77, 255}) do
        local a = pb.decode(RangeResponse, baseline(i))
        local c = pb.decode(RangeResponse, candidate(i))
        if #a.kvs ~= limit or #c.kvs ~= limit then
            error(string.format('self-check failed: %d rows wanted, '
                                .. 'baseline %d, candidate %d', limit,
                                #a.kvs, #c.kvs))
        end
        for _, f in ipairs({'cluster_id', 'member_id', 'revision',
                            'raft_term'}) do
            check_eq('header.' .. f, c.header[f], a.header[f])
        end
        check_eq('count', c.count, a.count)
        check_eq('more', tostring(c.more), tostring(a.more))
        for j = 1, limit do
            for _, f in ipairs({'key', 'create_revision', 'mod_revision',
                                'version', 'value', 'lease'}) do
                check_eq(string.format('kvs[%d].%s', j, f),
                         c.kvs[j][f], a.kvs[j][f])
            end
        end
    end
end

local function bench_range(space, conv, base)
    print(string.format('  %5s  %9s  %12s  %12s  %8s  %8s  %6s  %6s  %7s  '
                        .. '%7s  %8s  %8s',
                        'rows', 'select', 'A', 'cand', 'A/row', 'cand/row',
                        'A/cand', 'excl', 'sel%A', 'sel%cand', 'A B/op',
                        'cand B/op'))
    for _, limit in ipairs(SIZES) do
        local select_only, baseline, candidate =
            range_ops(space, conv, base, limit)
        check_range(baseline, candidate, limit)
        local iters = math.floor(200000 / limit)
        local s = measure(select_only, iters)
        local a = measure(baseline, iters)
        local c = measure(candidate, iters)
        print(string.format('  %5d  %9s  %12s  %12s  %8s  %8s  %5.2fx  '
                            .. '%5.2fx  %6.0f%%  %7.0f%%  %8.0f  %8.0f',
                            limit, fmt_ns(s.ns), fmt_spread(a),
                            fmt_spread(c), fmt_ns(a.ns / limit),
                            fmt_ns(c.ns / limit), a.ns / c.ns,
                            (a.ns - s.ns) / (c.ns - s.ns),
                            100 * s.ns / a.ns, 100 * s.ns / c.ns,
                            a.gc, c.gc))
    end
end

-- ---------------------------------------------------------------------------
-- Put
-- ---------------------------------------------------------------------------

-- The Put working set: one KeyValue message per row, encoded from the
-- row the way the Range baseline builds it.
local function put_messages(base)
    local msgs = {}
    for i = 1, PUT_ROWS do
        local r = kv_row(i, base)
        local lease = r[6]
        if lease == nil then lease = 0 end
        local value = r[5]
        if value == nil then value = '' end
        msgs[i] = pb.encode(KeyValue, {key = r[1], create_revision = r[2],
                                       mod_revision = r[3], version = r[4],
                                       value = value, lease = lease})
    end
    return msgs
end

-- The row a decoded KeyValue becomes, in column order. pb.decode leaves
-- a field holding its proto3 default out of the table; the row spells
-- the default out, as the converter does, so both write the same tuple.
local function kv_tuple_row(m)
    local lease = m.lease
    if lease == nil then lease = 0 end
    local value = m.value
    if value == nil then value = '' end
    return {m.key, m.create_revision, m.mod_revision, m.version, value,
            lease, NULL}
end

local function put_ops(space, conv, msgs)
    local n = #msgs

    local function decode_only(i)
        return pb.decode(KeyValue, msgs[i % n + 1])
    end

    local function decode_tuple(i)
        return box.tuple.new(kv_tuple_row(pb.decode(KeyValue,
                                                    msgs[i % n + 1])))
    end

    local function decode_replace(i)
        return space:replace(kv_tuple_row(pb.decode(KeyValue,
                                                    msgs[i % n + 1])))
    end

    local function conv_decode(i)
        return conv:decode(msgs[i % n + 1])
    end

    local function conv_replace(i)
        return conv:replace(msgs[i % n + 1])
    end

    return decode_only, decode_tuple, decode_replace, conv_decode,
           conv_replace
end

local function check_tuple(what, got, want)
    for f = 1, #KV_FORMAT do
        check_eq(string.format('%s field %d', what, f), got[f], want[f])
    end
end

local function check_put(space, msgs, decode_tuple, decode_replace,
                         conv_decode, conv_replace)
    for i = 0, #msgs - 1 do
        local want = decode_tuple(i)
        check_tuple('conv:decode', conv_decode(i), want)
        decode_replace(i)
        check_tuple('space:replace', space:get(want[1]), want)
        local got = conv_replace(i)
        check_tuple('conv:replace result', got, want)
        check_tuple('conv:replace stored', space:get(want[1]), want)
    end
end

local function bench_put(space, conv, base)
    local msgs = put_messages(base)
    local decode_only, decode_tuple, decode_replace, conv_decode,
          conv_replace = put_ops(space, conv, msgs)
    check_put(space, msgs, decode_tuple, decode_replace, conv_decode,
              conv_replace)
    local iters = 100000
    local rows = {
        {'pb.decode (table only)',         measure(decode_only, iters)},
        {'pb.decode + box.tuple.new',      measure(decode_tuple, iters)},
        {'conv:decode',                    measure(conv_decode, iters)},
        {'pb.decode + space:replace (B)',  measure(decode_replace, iters)},
        {'conv:replace',                   measure(conv_replace, iters)},
    }
    print(string.format('  %-31s  %12s  %11s  %8s', 'op (per row)', 'ns/row',
                        'rows/s', 'B/row'))
    for _, r in ipairs(rows) do
        print(string.format('  %-31s  %12s  %11.0f  %8.0f', r[1],
                            fmt_spread(r[2]), 1e9 / r[2].ns, r[2].gc))
    end
    print(string.format('  pb.decode+box.tuple.new / conv:decode = %.2fx; '
                        .. 'B / conv:replace = %.2fx',
                        rows[2][2].ns / rows[3][2].ns,
                        rows[4][2].ns / rows[5][2].ns))
end

-- ---------------------------------------------------------------------------
-- Nested: name matching in a map column
-- ---------------------------------------------------------------------------

-- Every Record field but id, name and address is left out of the binding.
local function record_omit()
    local omit = {}
    for _, f in ipairs(Record.fields) do
        if f.name ~= 'id' and f.name ~= 'name' and f.name ~= 'address' then
            omit[#omit + 1] = f.name
        end
    end
    return omit
end

local function address_of(i)
    return {street = string.format('%d Main Street', i),
            city = 'Springfield', zip = 10000 + i}
end

local NESTED_REPRS = {
    {name = 'map', column = 'map', value = function(a) return a end},
    {name = 'array', column = 'array', value = function(a)
        return {a.street, a.city, NULL, a.zip}
    end},
    {name = 'varbinary (raw)', column = 'varbinary', value = function(a)
        return varbinary.new(pb.encode(Address, a))
    end},
}

local function bench_nested()
    local omit = record_omit()
    local want = {}
    local msgs = {}
    for i = 1, NESTED_ROWS do
        local m = pb.encode(Record, {id = i, name = 'user' .. i,
                                     address = address_of(i)})
        msgs[i] = m
        want[i] = '\x0a' .. pb.wire.encode_varint(#m) .. m
    end
    local want_bytes = table.concat(want)

    print(string.format('  %-16s  %12s  %8s  %12s  %8s', 'address column',
                        'encode/row', 'B/row', 'decode/row', 'B/row'))
    local results = {}
    for k, r in ipairs(NESTED_REPRS) do
        local space = make_space('nested_' .. k, {
            {name = 'id',      type = 'unsigned'},
            {name = 'name',    type = 'string'},
            {name = 'address', type = r.column, is_nullable = true},
        })
        box.begin()
        for i = 1, NESTED_ROWS do
            space:insert({i, 'user' .. i, r.value(address_of(i))})
        end
        box.commit()
        local conv = pb.tuple.bind(Record, space, {omit = omit})
        local tuples = space:select({}, {limit = NESTED_ROWS})

        -- Self-check: the encoded rows are the reference bytes, and each
        -- decoded tuple re-encodes to its message.
        local got = conv:encode_repeated(1, tuples)
        if got ~= want_bytes then
            error('self-check failed: nested ' .. r.name
                  .. ' encode differs from pb.encode')
        end
        for i = 1, NESTED_ROWS do
            if conv:encode(conv:decode(msgs[i])) ~= msgs[i] then
                error('self-check failed: nested ' .. r.name
                      .. ' decode of row ' .. i)
            end
            local d = pb.decode(Record, conv:encode(tuples[i]))
            local a = address_of(i)
            check_eq('nested address.street', d.address.street, a.street)
            check_eq('nested address.zip', d.address.zip, a.zip)
        end

        local enc = measure(function()
            return conv:encode_repeated(1, tuples)
        end, 200)
        local dec = measure(function(i)
            return conv:decode(msgs[i % NESTED_ROWS + 1])
        end, 200000)
        enc.ns = enc.ns / NESTED_ROWS
        enc.gc = enc.gc / NESTED_ROWS
        results[k] = {enc = enc, dec = dec}
        print(string.format('  %-16s  %12s  %8.0f  %12s  %8.0f', r.name,
                            fmt_spread(enc), enc.gc, fmt_spread(dec),
                            dec.gc))
    end
    local map, arr, raw = results[1], results[2], results[3]
    print(string.format('  map - raw: encode %+.0fns/row, decode %+.0fns/row;'
                        .. ' map - array (name matching): encode %+.0fns/row,'
                        .. ' decode %+.0fns/row',
                        map.enc.ns - raw.enc.ns, map.dec.ns - raw.dec.ns,
                        map.enc.ns - arr.enc.ns, map.dec.ns - arr.dec.ns))
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
    print(string.format('pb.tuple bench: Tarantool %s, %s codecs, jit %s, '
                        .. 'wal_mode=none, median of %d reps (±spread)',
                        _TARANTOOL, MODE, jit.status() and 'on' or 'off',
                        REPS))

    for v, variant in ipairs(VARIANTS) do
        local space = make_space('kv_' .. v, KV_FORMAT)
        fill(space, variant.base)
        local conv = pb.tuple.bind(KeyValue, space, KV_OPTS)
        if C_REQUESTED and conv._tplan == nil then
            error('PB_ENABLE_C=1 but the converter has no C plan')
        end
        print(string.format('\nRange, %s, %d-row space', variant.label,
                            N_ROWS))
        bench_range(space, conv, variant.base)

        local put_space = make_space('kv_put_' .. v, KV_FORMAT)
        fill(put_space, variant.base)
        local put_conv = pb.tuple.bind(KeyValue, put_space, KV_OPTS)
        print(string.format('\nPut, %s, %d distinct messages', variant.label,
                            PUT_ROWS))
        bench_put(put_space, put_conv, variant.base)
    end

    print(string.format('\nNested kv.Record.address, %d rows', NESTED_ROWS))
    bench_nested()

    print('\nRange columns: A = per-row tables + pb.encode;'
          .. ' cand = conv:encode_repeated;\n'
          .. '  excl = A/cand with the select time taken out of both;'
          .. ' sel% = share of the op spent in index:select;\n'
          .. '  B/op, B/row = Lua GC bytes allocated')
end

-- box.cfg sent the log to DATA_DIR, where an uncaught error would land
-- unseen: report it on stderr and exit non-zero instead.
local ok, err = xpcall(main, debug.traceback)
fio.rmtree(DATA_DIR)
if not ok then
    io.stderr:write(tostring(err), '\n')
    os.exit(1)
end
os.exit(0)
