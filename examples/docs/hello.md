# hello.proto

**Package:** `hello`

**Imports:**

- `google/protobuf/timestamp.proto`
- `google/protobuf/duration.proto`
- `google/protobuf/empty.proto`
- `google/protobuf/wrappers.proto`
- `google/protobuf/struct.proto`
- `google/protobuf/any.proto`
- `google/protobuf/field_mask.proto`

## Messages

### `hello.Result`

Demo message for oneof handling.

| # | Field | Type | Label | Description |
|---|-------|------|-------|-------------|
| 1 | `id` | `int32` | — | — |
| 2 | `text` | `string` | oneof `outcome` | — |
| 3 | `code` | `int32` | oneof `outcome` | — |
| 4 | `details` | `hello.Address` | oneof `outcome` | — |

### `hello.HelloRequest`

gRPC service demo. Covers unary + all three streaming flavors so the loopback transport exercises every codegen branch.

| # | Field | Type | Label | Description |
|---|-------|------|-------|-------------|
| 1 | `name` | `string` | — | — |

### `hello.HelloReply`

| # | Field | Type | Label | Description |
|---|-------|------|-------|-------------|
| 1 | `greeting` | `string` | — | — |

### `hello.Event`

Demo message exercising well-known types.

| # | Field | Type | Label | Description |
|---|-------|------|-------|-------------|
| 1 | `title` | `string` | — | — |
| 2 | `created_at` | `google.protobuf.Timestamp` | — | — |
| 3 | `duration` | `google.protobuf.Duration` | — | — |
| 4 | `ack` | `google.protobuf.Empty` | — | — |
| 5 | `retry_count` | `google.protobuf.Int32Value` | — | — |
| 6 | `note` | `google.protobuf.StringValue` | — | — |
| 7 | `is_admin` | `google.protobuf.BoolValue` | — | — |
| 8 | `payload` | `google.protobuf.Struct` | — | — |
| 9 | `attribute` | `google.protobuf.Value` | — | — |
| 10 | `tags` | `google.protobuf.ListValue` | — | — |
| 11 | `extension` | `google.protobuf.Any` | — | — |
| 12 | `update_mask` | `google.protobuf.FieldMask` | — | — |

### `hello.Address`

| # | Field | Type | Label | Description |
|---|-------|------|-------|-------------|
| 1 | `street` | `string` | — | — |
| 2 | `city` | `string` | — | — |
| 3 | `zip` | `int32` | — | — |
| 4 | `apartment` | `string` | optional | Explicit-optional: presence is meaningful (distinct from default). |

### `hello.Person`

| # | Field | Type | Label | Description |
|---|-------|------|-------|-------------|
| 1 | `name` | `string` | — | — |
| 2 | `age` | `int32` | — | — |
| 3 | `emails` | `string` | repeated | — |
| 4 | `status` | `hello.Status` | — | — |
| 5 | `address` | `hello.Address` | — | — |
| 6 | `friends` | `hello.Person` | repeated | — |
| 7 | `lucky_numbers` | `int32` | repeated | — |
| 8 | `avatar` | `bytes` | — | — |
| 9 | `user_id` | `fixed64` | — | — |
| 10 | `balance` | `sint32` | — | — |
| 11 | `weight_kg` | `double` | — | — |
| 13 | `ages_by_nickname` | `map<string, int32>` | — | Map fields |
| 14 | `nickname_by_age` | `map<int32, string>` | — | — |
| 15 | `addresses_by_label` | `map<string, hello.Address>` | — | — |

## Enums

### `hello.Status`

| Value | Name | Description |
|-------|------|-------------|
| 0 | `UNKNOWN` | — |
| 1 | `OK` | — |
| 2 | `ERROR` | — |

## Services

### `hello.Greeter`

| Method | Request | Response | Streaming | Description |
|--------|---------|----------|-----------|-------------|
| `SayHello` | `hello.HelloRequest` | `hello.HelloReply` | unary | — |
| `Echo` | `hello.HelloRequest` | `hello.HelloRequest` | unary | — |
| `StreamHellos` | `hello.HelloRequest` | `hello.HelloReply` | server | Server-streaming: one request, server pushes N replies. |
| `CollectHellos` | `hello.HelloRequest` | `hello.HelloReply` | client | Client-streaming: client pushes N requests, server returns one reply. |
| `Chat` | `hello.HelloRequest` | `hello.HelloReply` | bidi | Bidirectional: both sides push and pull independently. |


