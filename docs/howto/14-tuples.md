# How-to: tuples to protobuf and back with `pb.tuple`

An etcd-compatible store on Tarantool answers etcd's Range with a list
of `KeyValue` messages, one per row it selects. The obvious handler
turns every tuple into a Lua table and hands the list to the encoder:
a table per row, built only to be walked once and thrown away. The
write path does the same in reverse, decoding into a table and
building a tuple from it.

`pb.tuple` removes that table. It binds a message descriptor to a
space format once; after that, a tuple's msgpack converts straight
to wire bytes, and wire bytes straight to a tuple.

The runnable example is `examples/tuple/kv_range.lua`:

```bash
just examples tuple-range
```

## When to use it

- Many rows per request in either direction: range reads, scans,
  bulk writes arriving as protobuf.
- Messages whose top-level fields line up with the columns of a
  space.

For a one-off conversion, build a table and use the ordinary codec:
`bind` does real work (it compiles a plan for the message and the
format), and the bridge saves nothing on a single row.

## Binding

The space from the example has the columns of `kv.KeyValue`
(`examples/proto/kv.proto`), except that the lease is `lease_id`, and
one column of its own that no field maps to:

```lua
local space = box.schema.space.create('kv', {format = {
    {name = 'key',             type = 'string'},
    {name = 'create_revision', type = 'unsigned'},
    {name = 'mod_revision',    type = 'unsigned'},
    {name = 'version',         type = 'unsigned'},
    {name = 'value',           type = 'any',      is_nullable = true},
    {name = 'lease_id',        type = 'unsigned', is_nullable = true},
    {name = 'owner',           type = 'string',   is_nullable = true},
}})
```

Bind once, at startup:

```lua
local KeyValue = kv.KeyValue_descriptor
local full = pb.tuple.bind(KeyValue, space, {columns = {lease = 'lease_id'}})
local keys_only = pb.tuple.bind(KeyValue, space, {
    columns = {lease = 'lease_id'},
    omit    = {'value'},
})
```

The rules:

- Top-level fields bind to columns by name. `columns` renames:
  `{[field name] = column name}`.
- `omit` is a list of fields to leave out. Encode never writes them;
  to decode, their columns are columns without a field (next rule).
  `keys_only` above answers a keys-only Range from the same space
  without reading `value`.
- A column that no field binds to is ignored by encode. Decode writes
  NULL into it if it is nullable, and raises if it is not.
- The descriptor can come from any producer: a generated module,
  `pb.parse`, `pb.from_pb`, or a hand-rolled descriptor.

`bind` checks every descriptor/format question up front. These are
bind errors, raised by `bind` itself:

- the first argument is not a message descriptor, or the second is
  not a space;
- an unknown option, or a malformed `columns` / `omit`: a name the
  message has no field for, an empty column name, a field listed
  twice in `omit`, a field both renamed and omitted;
- a bound field with no column of that name in the space;
- two fields bound to the same column;
- a field type and column type that do not go together (see
  [Types](#types));
- a field with explicit presence in a non-nullable column (see
  [Presence](#presence)), or a `string`/`bytes` field in a
  non-nullable `uuid` column;
- a message too sparse for an `array` column: its largest field
  number is more than four times its field count;
- a repeated field, map, or nested message whose elements or fields
  have no tuple representation, such as
  `repeated google.protobuf.Duration`.

Everything else is a per-value error, raised by the conversion for
the one value that does not fit, naming the field, the message and
the column. The example shows one of each. Binding `KeyValue` without
the rename:

```
bind without the rename: false
  pb.tuple: field 'lease' of kv.KeyValue has no column 'lease' in space 'kv'
```

Storing a `KeyValue` whose lease is negative:

```
negative lease: false
  pb.tuple: field 'lease' of kv.KeyValue (column 'lease_id'): value -1LL does not fit column type unsigned
```

## How a message field is laid out

A singular message field takes its shape from its column type. With
`Address { string street = 1; string city = 2; uint32 zip = 4; }` in
a column named `address`, these three tuple values encode to the
same bytes:

- `map` (or `any`): a map keyed by field name.

  ```lua
  {street = 'Main St', city = 'Springfield', zip = 12345}
  ```

- `array`: an array positioned by field number, NULL in the holes.
  Position 3 has no field, so it must be NULL.

  ```lua
  {'Main St', 'Springfield', box.NULL, 12345}
  ```

- `varbinary`: the message's own wire bytes, written and read
  verbatim.

  ```lua
  varbinary.new(Address_encode({street = 'Main St', city = 'Springfield', zip = 12345}))
  ```

Only the top level chooses. Every deeper level, every element of a
`repeated` message field and every value of a `map<K, V>` is a map
keyed by field name. A repeated field lives in an `array` (or `any`)
column, a `map<K, V>` in a `map` (or `any`) column.

On encode, a map key that names no field is an error, and so is a
key given twice.

## Presence

A field with explicit presence needs a nullable column, because NULL
is how "not set" is stored. Explicit presence means a proto3
`optional` field, a `oneof` member, or a singular message field
(`google.protobuf.Timestamp` included).

Encode:

- NULL, or a column missing from the end of the tuple, is an unset
  field.
- A field without explicit presence that holds its proto3 default
  (0, `''`, `false`) is not written. A field with explicit presence is
  written whenever it is not NULL, default or not.
- Two non-NULL members of one `oneof` are an error.

Decode:

- Defaults of fields without explicit presence are written out, at
  every level: 0, `''`, `false`, an empty array, an empty map.
- An unset field with explicit presence is NULL; in a nested map, the
  key is left out.
- For a `oneof`, the member that comes last on the wire wins and the
  others are NULL.

## Types

Which column types each field type binds to:

| Field type | Column types |
|---|---|
| integer types, `enum` | `unsigned`, `integer`, `scalar`, `any` |
| `double`, `float` | `double`, `number`, `scalar`, `any` |
| `bool` | `boolean`, `scalar`, `any` |
| `string`, `bytes` | `string`, `varbinary`, `uuid`, `scalar`, `any` |
| `google.protobuf.Timestamp` | `datetime`, `any`, `varbinary` (raw) |
| other messages | `map`, `any`, `array`, `varbinary` (raw) |
| other well-known types | `varbinary` (raw) |
| `repeated` | `array`, `any` |
| `map<K, V>` | `map`, `any` |

What the pairs mean:

- `string` and `bytes` have the same wire bytes. A `string` field in a
  `varbinary` column (or `bytes` in `string`) only changes the
  msgpack type the column holds.
- Integers are checked per value. Encode refuses a value outside the
  field type's range, so an `unsigned` column feeding an `int64`
  field refuses anything above 2^63 - 1. Decode refuses a negative
  value for an `unsigned` column. An `integer` column holds
  -2^63 .. 2^64 - 1, so every proto integer fits it.
- `datetime` holds a Timestamp as an instant. The offset of a
  datetime is not carried: decode gives the same instant in UTC. A
  Timestamp outside the datetime range is a decode error.
- A `uuid` column holds a `string` field as the canonical 36-character
  lowercase text, and a `bytes` field as its 16 raw bytes. Decode
  refuses any other text (uppercase included) and any other length.
  The empty value is stored as NULL, which is why the column must be
  nullable.
- A `number` column feeds `double`/`float` from integers and floats.
  It can also hold a decimal, which encode refuses rather than round
  to floating point. `decimal` columns bind to nothing.
- A `double` column always receives a msgpack double on decode, even
  for a whole value.
- In untyped slots (`any`, `scalar`, and everything below the top
  level) the type is checked per value. Decode writes a `bytes` value
  as binary and a `string` value as a string.

Encode reads a `string` or `bytes` field from either msgpack string
or binary, whatever the column type says: it takes any `box.tuple`
laid out per the format, not only one read from the space.

## Building a response by concatenation

The Range response in the example is two encodes joined:

```lua
local function range(conv, prefix, limit)
    local page, count = {}, 0
    for _, t in space:pairs(prefix, {iterator = 'GE'}) do
        if t.key:sub(1, #prefix) ~= prefix then break end
        count = count + 1
        if count <= limit then page[count] = t end
    end
    -- Concatenated protobuf messages decode as one merged message, so
    -- the rows and the scalar fields are encoded separately and joined.
    return conv:encode_repeated(KVS, page)
        .. pb.encode(RangeResponse, {more = count > limit, count = count})
end
```

This is valid protobuf because concatenation is merge: a parser
reading two messages back to back produces one message, with
repeated fields appended, singular scalars taken from the last
occurrence and nested messages merged. `conv:encode_repeated(n,
tuples)` writes, for each tuple, the tag of field `n`, the length and
the encoded row, which is exactly how a `repeated` message field is
encoded. It does not know the enclosing message; getting `n` right is
the caller's job (`kvs` is field 2 of etcd's `RangeResponse`).

Field order is the caller's job too. The fields appear in the order
the pieces are joined, and parsers accept any order, but the bytes
are then not what one encode of the whole message would write. If
response bytes are compared, hashed or cached, join the pieces in
field-number order, as the example does: `kvs` (2) before `more` (3)
and `count` (4). And set each singular field in one piece only; given
twice, the last one silently wins.

A client decodes the result with the ordinary codec:

```
range /app/: 3 of 3 keys, more = false, 72 bytes
  /app/a = alpha (mod_revision 2, lease 0)
  /app/b = beta (mod_revision 7, lease 42)
  /app/c = gamma (mod_revision 4, lease 0)
keys only, limit 2: 2 of 3 keys, more = true, 38 bytes
  /app/a
  /app/b
```

Encode writes the fields of every level in field-number order,
whatever the key order inside the tuple's maps. The entries of a
`map<K, V>` go out in the order of the keys in the tuple's msgpack
map.

## Decoding into tuples

```lua
local put = kv.KeyValue_encode({
    key = '/app/d', create_revision = 9, mod_revision = 9, version = 1,
    value = 'delta', lease = 7,
})
local row = full:replace(put)
print('stored: ' .. row.key .. ', lease_id ' .. row.lease_id
      .. ', owner ' .. tostring(row.owner))
print('re-encodes to the same bytes: ' .. tostring(full:encode(row) == put))

-- decode builds the tuple without storing it. The tuple carries no
-- space format, so its fields are read by number. Unset fields come
-- back as their proto3 defaults.
local t = full:decode(kv.KeyValue_encode({key = '/app/e'}))
print('decoded: ' .. tostring(t))
```

```
stored: /app/d, lease_id 7, owner nil
re-encodes to the same bytes: true
decoded: ['/app/e', 0, 0, 0, !!binary '', 0]
```

- `conv:decode(bytes)` returns a `box.tuple` laid out per the format
  but without the format attached, so read it by field number. It is
  as long as the last bound column; unbound columns before that are
  NULL, and trailing ones are left off (`owner` above).
- `conv:insert(bytes)` and `conv:replace(bytes)` decode, then call
  `space:insert` / `space:replace` and return the stored tuple.
- Unknown wire fields are skipped. Omitted fields are still decoded
  and checked, then dropped.
- A raw (`varbinary`) message column receives the field's payload
  verbatim. A field given more than once receives the payloads
  joined, which is protobuf's merge.

What raises:

- malformed wire bytes, with the codec's own error;
- a per-value error from [Types](#types): a negative value for an
  `unsigned` column, a Timestamp outside the datetime range, a value
  that is not a uuid for a `uuid` column;
- a non-nullable column that no field binds to, on every decode,
  whatever the bytes hold;
- box errors from `insert` / `replace` (a duplicate key, say), as box
  raises them.

## Schema changes

Every converter call first compares the box schema version with the
one its plan was compiled against. When it moved, which happens on
any DDL in the instance, the call rebinds against the space's current
format, so the first call after a DDL pays for one `bind`. A change
the binding survives, such as a new nullable column, goes unnoticed.
The call raises instead when:

- the space was dropped, or its id now belongs to a space with
  another name (a renamed space counts):
  `pb.tuple: space 'kv' no longer exists (id 512)`;
- the new format no longer binds:
  `pb.tuple: the format of space 'kv' changed and no longer binds kv.KeyValue: <the bind error>`.

## The C path

With `PB_ENABLE_C=1` set and the C runtime built (`just build-c`),
`encode`, `encode_repeated`, `decode`, `insert` and `replace` run in
C. `bind` stays in Lua and compiles its plan for the C side as well.
The C runtime needs Tarantool 3.5 or later; see
[c-accel.md](../c-accel.md#tarantool-version).

The results are the same bytes and the same tuples, and the errors
are the same messages: on input it refuses, the C decoder hands the
bytes back to the Lua path, which raises in its own words. The
example prints identical output in both modes.

One thing differs: the order of keys in the maps decode writes. The
C path writes a nested message's keys in ascending field-number order
and a `map<K, V>`'s entries in the order they first appear on the
wire. The Lua path writes them in the order `pairs` yields them, which
is unspecified. The keys and values are the same either way, and
encode does not depend on the order.

## Limits

- Column types `decimal`, `interval` and the fixed-size numeric types
  (`int8` .. `uint64`, `float32`, `float64`) bind to no field type.
- Other than Timestamp, well-known types (Any, Duration, Struct,
  Value, ListValue, FieldMask, the wrappers, Empty) bind only to a
  top-level `varbinary` column, as raw bytes. They cannot be elements
  of a repeated field, values of a map, or fields of a message laid
  out as a map or an array.
- On the Lua path the key order of the maps decode writes is
  unspecified (see above).
- Decoding into a binary slot needs the `varbinary` module, so
  Tarantool 3.0 or later.
- Messages nested deeper than 100 levels are refused.

## What's next

- [Reference: runtime API → `pb.tuple`](../reference/runtime-api.md#tuple-bridge--pbtuple)
  — signatures, return values and errors.
- `runtime/pb/tuple.lua` — the header comment is the full contract:
  the binding rules, the plan the converters execute, and every
  conversion rule.
- [C acceleration](../c-accel.md) — enabling and building the C
  runtime.
