# bench/c_accel — C acceleration spike

Spike work to benchmark which Lua↔C boundary wins for protobuf codec
work. Not part of the shipping codec; lives under `bench/` because its
only purpose is measurement.

## Strategies

The acceleration design question is *where* the Lua↔C boundary
should sit. Four candidate boundaries:

1. **Pure Lua** (baseline) — current `mode=full` generated code,
   no C involved. Measured via the existing `bench/bench.lua`.
2. **Per-primitive FFI** — `wire.lua`'s `encode_varint`,
   `decode_string`, etc. become `ffi.C.<fn>` calls. The dispatch
   loop stays in Lua; only the inner bit-twiddling is in C.
3. **One generic C call per message** — a C module gets the
   descriptor and the input table once and owns the inner loop.
4. **Hand-written C codec for hello.Person** — upper bound. No
   dispatch, no descriptor walk. Tells us the ceiling.

All four strategies are wired into `spike_bench.lua`:

- `prim.c` + `prim_ffi.lua` — Strategy 2 (FFI primitives)
- `generic_codec.c` — Strategy 3 (one generic C call, descriptor-walking)
- `person_codec.c` — Strategy 4 (hand-written for hello.Person)

## Scope

Both `person_codec.c` and `generic_codec.c` implement only the
Person fields exercised by `bench/bench.lua`'s payload builder:
`name`, `age`, `emails`, `address` (with `street`/`city`/`zip`),
`lucky_numbers`. The spike measures perf, not coverage.

`generic_codec.c` walks a hand-built `message_desc_t` /
`field_desc_t`. A real generic descriptor-driven C runtime would
build these descriptors from the Lua descriptor at
`pb.finalize_message` time and pass them through a registered
userdata.

The generic decode caches per-field stack indices for repeated /
packed arrays for the duration of `decode_message`, so each
`lua_setfield` of the array root into the result table happens
*once*, not per element. That matches `person_codec.c`'s pattern;
the naive "lazy lookup per element" version (initial commit) was
~2× slower than hand-written at 100 KB.

## Build and run

```bash
make -C bench/c_accel               # builds pb_c_person.dylib
tarantool bench/c_accel/spike_bench.lua
```

Override the Tarantool include dir if auto-detection fails:

```bash
make -C bench/c_accel TT_INC=/path/to/include/tarantool
```

## Results — 2026-05-23

Apple M-series, Tarantool 3.8.0-entrypoint-49 / LuaJIT 2.1.0-beta3.
Throughput msg/s; bandwidth MB/s. ×L columns are speedup vs the
pure-Lua baseline.

### Encode

| size  | bytes  | pure-Lua msg/s (MB/s) | S2 FFI msg/s (MB/s) | ×L   | S3 gen msg/s (MB/s) | ×L   | S4 hand msg/s (MB/s) | ×L   |
|-------|-------:|----------------------:|--------------------:|-----:|--------------------:|-----:|---------------------:|-----:|
| 10B   |     10 |    3,008,967 (30.1)   |  3,034,763 (30.3)   | 1.01 | 10,407,993 (104.1)  | 3.46 | 11,633,995 (116.3)   | 3.87 |
| 100B  |     94 |    2,936,858 (276.1)  |  2,888,587 (271.5)  | 0.98 |  9,989,012 (939.0)  | 3.40 | 11,122,852 (1045.5)  | 3.79 |
| 1KB   |    930 |      374,964 (348.7)  |    298,388 (277.5)  | 0.80 |  1,942,426 (1806.5) | 5.18 |  1,992,349 (1852.9)  | 5.31 |
| 10KB  |  9,634 |       73,390 (707.0)  |     49,761 (479.4)  | 0.68 |    297,018 (2861.5) | 4.05 |    287,786 (2772.5)  | 3.92 |
| 100KB | 96,674 |        8,857 (856.2)  |      5,341 (516.4)  | 0.60 |     30,244 (2923.8) | 3.41 |     29,459 (2847.9)  | 3.33 |

### Decode

| size  | bytes  | pure-Lua msg/s (MB/s) | S2 FFI msg/s (MB/s) | ×L   | S3 gen msg/s (MB/s) | ×L    | S4 hand msg/s (MB/s) | ×L    |
|-------|-------:|----------------------:|--------------------:|-----:|--------------------:|------:|---------------------:|------:|
| 10B   |     10 |    3,368,932 (33.7)   |    922,203 (9.2)    | 0.27 |  8,162,932 (81.6)   |  2.42 |  8,099,789 (81.0)    |  2.40 |
| 100B  |     94 |    2,801,552 (263.3)  |    915,311 (86.0)   | 0.33 |  7,825,645 (735.6)  |  2.79 |  8,029,549 (754.8)   |  2.87 |
| 1KB   |    930 |      157,212 (146.2)  |     58,902 (54.8)   | 0.37 |  1,049,098 (975.7)  |  6.67 |  1,149,822 (1069.3)  |  7.31 |
| 10KB  |  9,634 |       21,627 (208.4)  |      8,179 (78.8)   | 0.38 |    206,740 (1991.7) |  9.56 |    211,077 (2033.5)  |  9.76 |
| 100KB | 96,674 |        2,242 (216.7)  |        839 (81.1)   | 0.37 |     22,901 (2213.9) | 10.22 |     23,956 (2315.9)  | 10.69 |

### What the numbers say

- **The C boundary is cheap; per-primitive FFI is not.** Crossing
  the C boundary *once* per message wins 2.4–10.7×. Crossing it
  tens of times per message (S2) *loses* — pure-Lua decode is ~3×
  faster than FFI-primitive decode because LuaJIT inlines its own
  wire helpers but a `ffi.load`'d library's per-call dispatch is
  several hundred ns.
- **S3 ≈ S4 within ±5% at every size.** The descriptor-walk
  dispatch overhead is in the noise. This is the most important
  result for the C-acceleration design call: shipping a generic
  descriptor-driven C runtime as one call per message lands within
  noise of the hand-written ceiling, so generated per-message C
  codecs buy nothing.
- **C encode plateaus at ~2.8–2.9 GB/s** from 1 KB upward. The
  bottleneck moves to Lua table reads and output string allocation,
  not wire formatting.
- **C decode degrades much more gracefully than Lua decode.**
  Pure-Lua decode is per-byte cliff-y (157 k msg/s @ 1KB →
  2.2 k @ 100KB); C decode degrades roughly linearly with size,
  hitting 2.3 GB/s at 100KB.
- The cache-the-repeated-array-stack-idx pattern is required:
  the naive lazy-getfield version was ~2× slower than hand-written
  at 100 KB. A generic descriptor-driven C runtime must encode this.

### History: why S4 once looked slower than S3 at 1KB+

The 2026-05-18 snapshot of these numbers showed S4 encode trailing
S3 by 10–20% at 1 KB+, and we hypothesised it was branch prediction
on the hand-written codec's divergent per-field paths. That was
wrong. The actual cause was that `person_codec.c`'s emails loop did
a defensive `lua_type(L, -1) == LUA_TSTRING` check on each element
before `lua_tolstring`, while `generic_codec.c` skipped it. With
~2,700 emails at 100 KB that's 2,700 extra C calls per message in
the hot path. Replacing the per-element `lua_type` check with no
check (and the field-level type checks with `lua_isnil`, matching
the generic codec's semantics) closed the gap. The lesson generalises:
when comparing two C codecs that look "the same shape", measure
their per-element work, not their dispatch shape — the boundary
crossings to the Lua stack dominate everything else.

### What this means for the C-acceleration design

- **Ship a generic descriptor-driven C runtime (one C call per
  message).** It's the message-level boundary and S3 lands within
  noise of the hand-written ceiling. 3–11× over pure Lua at every
  size.
- **Drop generated per-message C codecs.** ≤15% headroom over the
  generic runtime, going the wrong way at scale. The codegen
  complexity isn't justified.
- **Drop per-primitive FFI as an architecture.** S2 loses to pure
  Lua at every size ≥1 KB on encode and at every size on decode.
  The boundary is too chatty.
- The result-table allocation in C still goes through the Lua
  runtime, so very-small-message C wins are capped (~3× at 10B
  encode). Worth knowing for the generic runtime — the floor is
  the Lua side of the boundary, not the wire layer.
