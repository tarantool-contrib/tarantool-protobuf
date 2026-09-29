# Performance optimization log

Baseline numbers for tarantool-protobuf's encode/decode hot paths, used
as the reference point when comparing later optimization work. Decoder,
encoder, and the proto2 `BenchPayload` schemas are tracked separately
because optimizations rarely move all three uniformly.

## Schemas tracked

- **hello.Person** at 10B / 100B / 1KB / 10KB / 100KB.
  Real-world-shaped: string fields, nested messages, repeated emails. Both
  `full` (inlined codegen) and `runtime` (descriptor dispatch) modes.
- **proto2_basic.BenchPayload** at `min` / `mid`. Pins proto2 extension and
  default-value paths.

## Baseline — 2026-05-18

Pre-optimization snapshot. Tarantool 3.7.0-0-g1f1ec9fdf, LuaJIT 2.1.0-beta3,
macOS arm64.

### hello.Person — encode

| mode    | size   | msgs/s    | MB/s   | alloc B/op |
|---------|--------|-----------|--------|------------|
| full    | 10B    | 2,250,858 | 22.5   | 136        |
| full    | 100B   | 2,215,919 | 208.3  | 136        |
| full    | 1KB    | 240,381   | 223.6  | 1368       |
| full    | 10KB   | 43,240    | 416.6  | 8540       |
| full    | 100KB  | 4,920     | 475.7  | 131605     |
| runtime | 10B    | 1,098,666 | 11.0   | 136        |
| runtime | 100B   | 1,089,811 | 102.4  | 136        |
| runtime | 1KB    | 186,459   | 173.4  | 1368       |
| runtime | 10KB   | 39,600    | 381.5  | 8540       |
| runtime | 100KB  | 4,433     | 428.5  | 131605     |

### hello.Person — decode

| mode    | size   | msgs/s    | MB/s   | alloc B/op |
|---------|--------|-----------|--------|------------|
| full    | 10B    | 2,476,811 | 24.8   | 112        |
| full    | 100B   | 2,091,875 | 196.6  | 112        |
| full    | 1KB    | 109,479   | 101.8  | 1000       |
| full    | 10KB   | 14,961    | 144.1  | 4840       |
| full    | 100KB  | 1,461     | 141.3  | 33512      |
| runtime | 10B    | 2,103,514 | 21.0   | 112        |
| runtime | 100B   | 1,843,624 | 173.3  | 112        |
| runtime | 1KB    | 103,503   | 96.3   | 1000       |
| runtime | 10KB   | 13,710    | 132.1  | 4840       |
| runtime | 100KB  | 1,336     | 129.1  | 33512      |

### proto2_basic.BenchPayload

| mode    | size | enc msgs/s | enc MB/s | dec msgs/s | dec MB/s |
|---------|------|------------|----------|------------|----------|
| full    | min  | 1,485,112  | 7.4      | 846,439    | 4.2      |
| full    | mid  | 181,413    | 110.5    | 73,650     | 44.9     |
| runtime | min  | 1,163,210  | 5.8      | 982,154    | 4.9      |
| runtime | mid  | 162,481    | 99.0     | 73,952     | 45.0     |

## Tuple bridge (pb.tuple) — 2026-09-29

`bench/tuple_bench.lua` (`just bench-tuple`, `just bench-tuple-c`): the
tuple bridge against per-row Lua tables, on the read and write paths of
an etcd-compatible key-value store. Linux x86_64 VM (AMD Ryzen 7 3700X,
6 vCPU), Tarantool 3.8.0, JIT on, memtx with `wal_mode = 'none'` (the
WAL write is kept out of `space:replace`).

Space `kv`: key string (`bench/range/%05d`, 17 bytes), three unsigned
revisions, nullable `any` value (64 bytes; NULL on every 97th row),
nullable `lease_id` (set on every 4th row), nullable `storage_flags`
(NULL). 10,000 rows. Small revisions fit a 1-byte varint; large ones
are above 2^32 (5-byte varints). The converter binds `KeyValue` with
`{columns = {lease = 'lease_id'}}`.

- **Range**: `index:select(key, {iterator = 'GE', limit = n})`, then a
  RangeResponse (header, repeated KeyValue kvs, count, more). A: per
  row `tuple:unpack()` -> KeyValue table -> `pb.encode`; cand:
  `conv:encode_repeated(2, tuples)`. Both encode the response without
  kvs with one `pb.encode` and append the kvs: the C codec's
  `pb.encode` refuses the whole response once it passes about 8 KiB
  (`message field requires a table value`, a message field followed by
  a large repeated message field), so A encodes in the same two parts
  as the candidate. `select` is `index:select` alone.
- **Put**: 1,000 distinct KeyValue messages, one row per op. B:
  `pb.decode` -> table -> `space:replace{...}`; cand: `conv:replace`.
  Decode-only: `pb.decode` alone, `pb.decode` + `box.tuple.new`,
  `conv:decode`.
- **Nested**: kv.Record's `address` in a `map`, an `array` and a
  `varbinary` column; 1,000 rows, encode via `encode_repeated`, decode
  via `conv:decode`.

Every candidate is decoded and compared with its baseline before timing.
Each figure is the median of three runs (each run is itself the median
of 7 timed repetitions); brackets give the lowest and highest of the
three runs. GC bytes count the Lua heap only (tuple memory is not
included).

### Range, C codecs (`PB_ENABLE_C=1`)

| revisions | rows | select | A | cand | A/cand | A/cand, select excluded | select share of cand | GC B/op A / cand |
|-------|------|------------------|---------------------|------------------|------------------|------------------|--------------|-------------|
| small | 10   | 5.6µs [5.5–5.8]  | 44.8µs [36.1–45.1]  | 10.1µs [9.7–12.0] | 3.76x [3.57–4.61] | 6.71x [6.36–9.34] | 55% [48–57] | 26.8K / 10.6K |
| small | 100  | 26µs [23–36]     | 309µs [305–345]     | 68µs [67–71]     | 4.62x [4.31–5.10] | 7.20x [6.91–7.78] | 39% [34–51] | 128K / 63K |
| small | 1000 | 207µs [205–373]  | 3.12ms [3.10–3.54]  | 615µs [607–660]  | 5.07x [4.70–5.83] | 8.32x [7.10–9.52] | 34% [33–57] | 1.26M / 567K |
| large | 10   | 5.1µs [4.0–5.6]  | 38.1µs [37.7–41.5]  | 10.7µs [10.0–10.8] | 3.53x [3.52–4.14] | 6.20x [5.86–6.22] | 48% [40–51] | 26.9K / 10.7K |
| large | 100  | 23µs [23–35]     | 319µs [310–356]     | 69µs [68–75]     | 4.49x [4.28–5.22] | 7.23x [6.26–7.39] | 34% [34–47] | 130K / 65K |
| large | 1000 | 210µs [203–387]  | 3.21ms [3.17–3.67]  | 639µs [639–688]  | 4.95x [4.66–5.74] | 7.94x [6.89–9.37] | 33% [32–56] | 1.27M / 580K |

### Range, Lua codecs

| revisions | rows | A | cand | A/cand | A/cand, select excluded | select share of cand |
|-------|------|--------------------|--------------------|-------------------|-------------------|-------------|
| small | 10   | 43.7µs [43.7–54.1] | 33.5µs [33.4–39.1] | 1.31x [1.31–1.38] | 1.37x [1.36–1.45] | 15% [15–17] |
| small | 100  | 367µs [351–419]    | 267µs [264–324]    | 1.33x [1.30–1.37] | 1.37x [1.32–1.46] | 9% [8–19] |
| small | 1000 | 3.81ms [3.67–4.33] | 3.09ms [3.00–3.14] | 1.23x [1.23–1.38] | 1.27x [1.24–1.41] | 8% [7–13] |
| large | 10   | 50.3µs [48.6–58.1] | 42.4µs [37.1–45.4] | 1.31x [1.11–1.37] | 1.36x [1.12–1.45] | 14% [12–18] |
| large | 100  | 407µs [398–463]    | 298µs [285–333]    | 1.39x [1.23–1.56] | 1.43x [1.24–1.66] | 8% [8–16] |
| large | 1000 | 4.28ms [4.07–4.52] | 3.46ms [3.28–3.82] | 1.24x [1.18–1.24] | 1.26x [1.19–1.27] | 6% [6–12] |

### Put, ns per row

| codecs | revisions | pb.decode | pb.decode + box.tuple.new | conv:decode | ratio | B (pb.decode + replace) | conv:replace | ratio |
|-----|-------|-----------------|--------------------|------------------|-------------------|--------------------|------------------|-------------------|
| C   | small | 452 [449–493]   | 1621 [1604–1633]   | 653 [652–673]    | 2.46x [2.43–2.49] | 2382 [2335–2391]   | 1505 [1488–1539] | 1.57x [1.55–1.58] |
| C   | large | 480 [472–492]   | 1729 [1653–1730]   | 685 [677–690]    | 2.51x [2.44–2.52] | 2432 [2386–2441]   | 1534 [1503–1548] | 1.58x [1.56–1.62] |
| Lua | small | 681 [598–697]   | 1870 [1860–1905]   | 2559 [2534–2627] | 0.73x [0.73–0.74] | 2750 [2693–2794]   | 3407 [3373–3775] | 0.79x [0.74–0.82] |
| Lua | large | 1482 [1259–1508] | 2834 [2744–3097]  | 3460 [3348–3534] | 0.82x [0.82–0.88] | 3585 [3460–3903]   | 4284 [4281–4418] | 0.84x [0.81–0.88] |

GC bytes per row, C: 225 (pb.decode), ~410 (pb.decode + tuple or
replace), 79 (conv:decode, conv:replace). Lua: 428–600, 602–783,
755–942.

### Nested kv.Address, ns per row

| codecs | column | encode | decode |
|-----|-----------|------------------|------------------|
| C   | map       | 230 [229–233]    | 807 [793–810]    |
| C   | array     | 202 [200–208]    | 797 [780–824]    |
| C   | varbinary | 133 [128–136]    | 762 [749–786]    |
| Lua | map       | 2981 [2254–3289] | 3813 [3631–3824] |
| Lua | array     | 2837 [2308–3201] | 3690 [3519–4082] |
| Lua | varbinary | 1769 [1486–1839] | 3872 [3624–4372] |

### Reading

- With the C runtime, `encode_repeated` is 3.5–5.1x faster than the
  per-row-table loop over the whole Range op, 6–8x on the encode part
  alone, at every size and both varint widths, and allocates less than
  half the Lua heap. `conv:decode` is 2.5x faster than `pb.decode` +
  `box.tuple.new`, `conv:replace` 1.6x faster than `pb.decode` +
  `space:replace`, with 79 instead of ~410 GC bytes per row. A bare
  `pb.decode` into a table (450–480 ns) is still cheaper than
  `conv:decode` (650–690 ns): what the bridge saves is building the
  tuple out of a table.
- Once the encode runs in C, `index:select` becomes a third of the
  Range op at 100 and 1,000 rows and about half at 10 rows (against
  7–14% of the per-row-table loop). Further encoder work has at most
  the remaining two thirds to win.
- Name matching in a nested map costs about 28 ns per row for
  kv.Address's three keys in C (map versus array); a nested message
  held as its wire bytes saves another ~70 ns per row on encode by
  copying instead of walking the msgpack. On decode the three columns
  are within run-to-run noise of each other.
- The Lua path encodes 1.2–1.4x faster than per-row tables but decodes
  0.73–0.84x as fast: it runs the descriptor codec into a table first
  and then lays the table out as a tuple, so it cannot beat
  `pb.decode` + `box.tuple.new`.
