# Go comparison bench

Apples-to-apples microbenchmarks against `bench/bench.lua` so the LuaJIT
runtime can be compared to mainstream Go protobuf implementations.

## What it measures

Same fixtures and size sweep as the Lua bench:

- `hello.Person` at five payload sizes (10 B, 100 B, 1 KB, 10 KB, 100 KB)
- `proto2_basic.BenchPayload` at two sizes (min, mid)

For each fixture × size, both encode and decode under two Go
implementations:

- **apiv2** — `google.golang.org/protobuf/proto.Marshal/Unmarshal`. The
  default reflective marshaler everyone gets out of the box.
- **vtproto** — `planetscale/vtprotobuf` generated `MarshalVT/UnmarshalVT`.
  Code-gen'd, no reflection. Conceptually equivalent to our `mode=full`
  Lua codegen.

Single-threaded: Go's `testing.B` runs serially unless `RunParallel` is
called. `-cpu=1` is not needed — GOMAXPROCS only affects GC parallelism,
not bench iterations.

## Running

```bash
just bench-go                          # full sweep, default benchtime=1s
cd bench/go && go test -bench=Person -benchtime=3s ./...
```

`go test` reports ns/op, MB/s (via `b.SetBytes`), B/op, allocs/op.

## Comparing to the Lua bench

`bench/bench.lua --print` emits ns/op + msgs/s + MB/s + bytes/op per
mode × size. Run both, pick the same size, compare directly. The
encoded byte lengths should match within a byte or two for the same
target size since both use the same proto definitions and equivalent
payload builders.

## proto2 caveats

- **Extensions skipped by vtproto.** `MarshalVT` does not serialize
  proto2 extensions, so the BenchPayload fixture (which carries
  `ext_count` + `ext_label`) would produce shorter bytes than the
  apiv2 path. The vtproto proto2 cases are intentionally omitted to
  avoid publishing misleading throughput numbers.
- Groups are supported by both `protoc-gen-go` and vtproto.

## Layout

```
bench/go/
├── go.mod
├── proto/                  # .proto sources (subset of repo protos with go_package set)
├── pb/{hellopb,proto2pb}/  # generated *.pb.go + *_vtproto.pb.go
├── fixtures.go             # payload builders mirroring bench/bench.lua
└── bench_test.go           # `go test -bench` entry points
```

## Generated .pb.go files

`*.pb.go` is gitignored repo-wide, so `bench/go/pb/` is **not**
committed — regenerate locally before running the bench:

```bash
just gen-go      # runs protoc with both plugins; bench-go depends on it
```

Requires `protoc-gen-go` and `protoc-gen-go-vtproto` on `$PATH`:

```bash
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install github.com/planetscale/vtprotobuf/cmd/protoc-gen-go-vtproto@latest
```
