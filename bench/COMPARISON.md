# Lua vs Go: cross-runtime protobuf benchmark

Side-by-side numbers from `just bench` (Lua `full` mode) and `just
bench-go` (Go apiv2 + vtproto). Same proto definitions, same payload
shapes, single-threaded on both sides.

- **Host:** Apple M4 Pro, darwin/arm64, GOMAXPROCS=14 (Go iter loop is
  serial regardless; GOMAXPROCS only affects GC threads)
- **Tarantool:** 3.x with LuaJIT 2.1 fork
- **Go:** 1.26.3, `google.golang.org/protobuf` v1.36.11,
  `planetscale/vtprotobuf` v0.6.0
- **Benchtime:** Go `-benchtime=1s`; Lua adaptive (50k–200k iters)
- **Lua mode shown:** `full` (codegen-inlined; the fast path). `runtime`
  mode is 0–35 % slower depending on payload size (smaller payloads bear
  more per-field dispatch overhead) — see `bench/baseline.json` if you
  want both. The numerical tables below predate a later
  dispatch-fragmentation fix; runtime-mode encode of small Person
  payloads is now ~40 % faster than what the tables show.
- **Columns:** MB/s (higher is better), B/op (allocator bytes per
  operation, lower is better)

Numbers will drift run-to-run by 5–10 % on a busy laptop. Treat ratios,
not absolutes, as load-bearing.

## hello.Person — encode

| Size   | Lua full MB/s | Lua run MB/s | apiv2 MB/s | vtproto MB/s | apiv2/Lua-full | vtproto/Lua-full |
| ------ | ------------: | -----------: | ---------: | -----------: | -------------: | ---------------: |
| 10 B   |         31.14 |        16.09 |     161.88 |       599.94 |         5.2 ×  |          19.3 ×  |
| 100 B  |        281.29 |       148.41 |    1416.79 |      4330.00 |         5.0 ×  |          15.4 ×  |
| 1 KB   |        310.70 |       252.11 |    2090.37 |      5626.07 |         6.7 ×  |          18.1 ×  |
| 10 KB  |        582.82 |       546.06 |    2783.52 |      7494.49 |         4.8 ×  |          12.9 ×  |
| 100 KB |        582.94 |       593.19 |    2742.85 |      7851.05 |         4.7 ×  |          13.5 ×  |

## hello.Person — decode

| Size   | Lua full MB/s | Lua run MB/s | apiv2 MB/s | vtproto MB/s | apiv2/Lua-full | vtproto/Lua-full |
| ------ | ------------: | -----------: | ---------: | -----------: | -------------: | ---------------: |
| 10 B   |         32.71 |        27.84 |     131.47 |       774.64 |         4.0 ×  |          23.7 ×  |
| 100 B  |        259.38 |       231.39 |    1099.02 |      4853.53 |         4.2 ×  |          18.7 ×  |
| 1 KB   |        136.40 |       129.43 |     966.14 |      1524.65 |         7.1 ×  |          11.2 ×  |
| 10 KB  |        192.72 |       175.65 |    1263.84 |      2084.66 |         6.6 ×  |          10.8 ×  |
| 100 KB |        187.85 |       171.28 |    1105.49 |      1966.28 |         5.9 ×  |          10.5 ×  |

## proto2_basic.BenchPayload — encode

vtproto skipped here: `MarshalVT` drops proto2 extensions, so its
output bytes would not match apiv2/Lua. apiv2 is the only fair
Go-side comparison for this fixture.

| Size | Lua full MB/s | Lua run MB/s | apiv2 MB/s | apiv2/Lua-full |
| ---- | ------------: | -----------: | ---------: | -------------: |
| min  |         10.67 |         7.71 |      36.27 |         3.4 ×  |
| mid  |        157.95 |       141.29 |    1486.45 |         9.4 ×  |

## proto2_basic.BenchPayload — decode

| Size | Lua full MB/s | Lua run MB/s | apiv2 MB/s | apiv2/Lua-full |
| ---- | ------------: | -----------: | ---------: | -------------: |
| min  |          6.03 |         6.35 |      19.23 |         3.2 ×  |
| mid  |         56.48 |        55.81 |     678.35 |        12.0 ×  |

## Allocations per op (Person)

Worth a separate look because the picture changes between encode and
decode. Encode is a single output buffer in all three runtimes; decode
allocates per-field-instance in Go but reuses interned strings in
LuaJIT.

| Size   | Op     | Lua full B/op | Lua run B/op | apiv2 B/op | apiv2 allocs | vtproto B/op | vtproto allocs |
| ------ | ------ | ------------: | -----------: | ---------: | -----------: | -----------: | -------------: |
| 10 B   | encode |         136.0 |        136.0 |         16 |            1 |           16 |              1 |
| 100 B  | encode |         136.0 |        136.0 |         96 |            1 |           96 |              1 |
| 1 KB   | encode |        1368.3 |       1368.3 |       1024 |            1 |         1024 |              1 |
| 10 KB  | encode |        8540.2 |       8540.2 |       9728 |            1 |         9728 |              1 |
| 100 KB | encode |      131605.2 |     131605.2 |      98304 |            1 |        98304 |              1 |
| 10 B   | decode |         112.0 |        112.0 |        216 |            2 |            8 |              1 |
| 100 B  | decode |         112.0 |        112.0 |        304 |            2 |           96 |              1 |
| 1 KB   | decode |        1000.0 |       1000.0 |       2200 |           38 |         1992 |             37 |
| 10 KB  | decode |        4840.0 |       4840.0 |      18712 |          297 |        18504 |            296 |
| 100 KB | decode |       33512.2 |      33512.2 |     249368 |         2862 |       249160 |           2861 |

The decode comparison flips above ~1 KB: Lua decodes a 100 KB Person
with **7.4 ×** less allocator pressure than either Go marshaler. The
repeated-string-emails workload allocates one `string` header per
element in Go, but lands in LuaJIT's string-intern table where
identical or short strings reuse storage. This is a real workload
characteristic for chat/log streams, not a microbench artifact.

## Reading the numbers

- **Encode ceiling** is set by code-gen marshalers + low-level
  bytes-pushing: vtproto wins by 10–24 × over us. Our `mode=full`
  inlines the same way, but LuaJIT pays for table iteration,
  type-tag dispatch, and string allocation that AOT-compiled Go
  doesn't.
- **vs. apiv2** (Go's default reflective path) the gap narrows to
  4–7 ×. apiv2 walks `protoreflect.MessageDescriptor` per call; we
  walk our own descriptor in `mode=runtime` and inline it in
  `mode=full`. apiv2 still wins because it's compiled.
- **Big-payload decode** is where LuaJIT's string interning pays
  off and the alloc gap inverts (33 KB Lua vs 249 KB Go for a 100 KB
  Person). Throughput is still Go-favorable, but per-op GC pressure
  is not.
- **proto2 fixture** numbers (10–60 MB/s for the `min` size) are
  dominated by per-message overhead — extensions, defaults — and
  not representative of bulk throughput. The `mid` line is the one
  to compare for steady-state cost.

## Reproducing

```bash
just bench         # Lua: writes JSON to stdout (this doc used --print output)
just bench-go      # Go:  standard go test -bench output

# Quick narrowed view:
cd bench/go && go test -bench=Person -benchtime=2s ./...
```
