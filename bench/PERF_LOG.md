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
