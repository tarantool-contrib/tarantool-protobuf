# Spec: msgpack encoding for protobuf schemas

Status: **draft / brainstorm**. This is a design sketch to come back to —
not an approved plan. Open questions are called out explicitly.

## Goal

Use proto3 `.proto` files as the IDL, but encode/decode payloads as
**MsgPack** instead of the protobuf wire format. The bytes are valid
MsgPack consumable by `msgpackffi`, `box.tuple.new`, net.box, IProto,
and anything else in Tarantool's ecosystem — the schema simply happens
to come from a `.proto` file.

This is **not** "encode protobuf wire format and stuff it in `MP_BIN`."
The output is structurally MsgPack throughout — maps, arrays, ints,
strings, ext types — typed by the proto descriptor.

## Non-goals

- Wire-compatible with anything else's "protobuf-over-msgpack" — there
  is no such standard. We define ours.
- Replacing the existing proto wire codec. This is a sibling encoder,
  selected per call. The hot wire codec stays exactly as it is today.
- Schema parsing changes. We reuse the existing descriptor format
  (see [codegen.md → the descriptor table — the contract](../codegen.md#the-descriptor-table--the-contract)).

## Module surface

New module `runtime/pb/msgpack.lua`, mirroring `pb.json`'s shape:

```lua
local pb = require('pb')

local bytes = pb.msgpack.encode(desc, t)            -- table -> msgpack bytes
local t     = pb.msgpack.decode(desc, bytes)        -- msgpack bytes -> table

-- Same `desc` table the wire codec uses. Same input/output Lua shape.
-- Only the wire format on the byte side differs.
```

Implementation rides on `msgpackffi` (the same module net.box and
`box.tuple` use). That gets us cdata `int64_t`/`uint64_t` round-tripping
for free — consistent with the rest of the project (see
[codegen.md → the hot-path rules](../codegen.md#the-hot-path-rules-the-generated-code-observes),
"64-bit integers stay as cdata").

WKT/extension routing reuses `desc.encode` / `desc.decode` overrides;
we add a parallel `desc.msgpack_encode` / `desc.msgpack_decode` pair so
WKTs can plug into both codecs side-by-side.

## Default message layout: msgpack map keyed by field number

```text
message Foo {
  int32  a = 1;
  string b = 2;
  Bar    c = 3;
}

{ a = 7, b = "hi", c = {...} }
  -->  mp_map{ 1: 7, 2: "hi", 3: mp_map{...} }
```

- **Int keys, not string keys.** Field numbers are the proto identity;
  names are cosmetic. Int keys also pack tighter in msgpack
  (1 byte for fields 1–127).
- **Unknown fields survive round-trip.** A decoder that doesn't know
  field 999 keeps the `{999: <opaque mp value>}` entry in a sidecar and
  re-emits it on encode. Mirrors how the proto wire codec preserves
  unknown fields today, except the values are msgpack-typed instead of
  raw wire bytes.
- **Defaults are omitted on encode.** Proto3 zero-values do not appear
  in the map. Decoder fills them in. Explicit `optional` fields encode
  when set, omit when unset — presence = "is the int key present?"

Tradeoff: not human-readable in raw form. Mitigated by a debug helper
that joins the map against the descriptor when printing.

## Scalar mapping

| proto type                                 | msgpack             | notes                                       |
| ------------------------------------------ | ------------------- | ------------------------------------------- |
| `int32`, `sint32`, `sfixed32`              | `mp_int`            | signed                                      |
| `uint32`, `fixed32`                        | `mp_uint`           | unsigned                                    |
| `int64`, `sint64`, `sfixed64`              | `mp_int`            | cdata `int64_t`, no narrowing to double     |
| `uint64`, `fixed64`                        | `mp_uint`           | cdata `uint64_t`                            |
| `float`                                    | `mp_float32`        |                                             |
| `double`                                   | `mp_float64`        |                                             |
| `bool`                                     | `mp_bool`           |                                             |
| `string`                                   | `mp_str`            | UTF-8 validation per proto3 (reuse `utf8.len`) |
| `bytes`                                    | `mp_bin`            |                                             |
| `enum`                                     | `mp_int` (numeric)  | keep numeric so unknown enum values survive |

The "fixed" / "varint" / "zigzag" distinction is wire-encoding-specific
and irrelevant here — every integer goes through the same `mp_int` path.

## Composite mapping

- **`repeated T`** → `mp_array` of T-encoded values. The packed-vs-
  unpacked distinction disappears; every repeated field is an array.
- **`map<K, V>`** → `mp_map` with the actual map keys. Not a list of
  `{key, value}` entries — a real map. K must be a scalar per proto3.
- **Nested message** → nested `mp_map` (embedded, not a bytes blob).
- **`oneof`** → only the active branch's field-number key appears in
  the parent map. Decoder reconstructs which branch is active from
  "which key is present." Setting a new branch on encode drops the
  others (same as the wire codec).

## Field presence summary

| field shape                | encoded when value is... | decoder default            |
| -------------------------- | ------------------------ | -------------------------- |
| proto3 implicit (no `optional`) | non-default            | proto3 zero               |
| proto3 explicit `optional` | set                      | absent (key not in result) |
| `repeated`                 | non-empty                | empty array `{}`           |
| `map`                      | non-empty                | empty map `{}`             |

## Unknown-field preservation

Decoder collects `int_key -> raw mp value (bytes)` for any int key not
in `desc.field_by_id`, stashes them under `t._unknown_fields_msgpack`
(distinct from the wire codec's `t._unknown_fields`, which holds raw
wire bytes). Encoder re-emits the stashed entries verbatim.

Open: do we want bidirectional unknown-field passthrough between the
two codecs (msgpack ↔ wire)? Probably no — the codecs aren't paired.
A wire-format message that hit a msgpack decoder is malformed by
definition; if you want both you write twice or transcode explicitly.

## WKT mapping

| WKT                          | msgpack                              | rationale                                       |
| ---------------------------- | ------------------------------------ | ----------------------------------------------- |
| `google.protobuf.Timestamp`  | `mp_ext`/MP_DATETIME (ext 4)          | Native datetime in Tarantool; box-space friendly |
| `google.protobuf.Duration`   | `mp_ext`/MP_INTERVAL (ext 6)          | Native interval                                 |
| `google.protobuf.Empty`      | empty `mp_map`                       | Trivial                                         |
| `google.protobuf.*Value` wrappers | the raw scalar                  | Presence already captured by "key present in parent" — wrapper layer is redundant |
| `google.protobuf.Struct`     | `mp_map` (string keys, dynamic values) | `Struct` is JSON-shaped by design               |
| `google.protobuf.Value`      | native msgpack of matching shape     | Same                                            |
| `google.protobuf.ListValue`  | `mp_array`                           | Same                                            |
| `google.protobuf.FieldMask`  | `mp_array` of `mp_str` (the paths)   | Just a path list                                |
| `google.protobuf.Any`        | `mp_map{ type_url = mp_str, value = mp_bin }` | Keep `value` as raw protobuf wire bytes — type_url's contract is "value is proto wire of that type" |

### Timestamp ↔ MP_DATETIME loss

`struct datetime` (Tarantool, `src/lib/core/datetime.h:85`):
```c
double  epoch;     int32_t nsec;
int16_t tzoffset;  int16_t tzindex;
```
`google.protobuf.Timestamp` is `(seconds, nanos)` in UTC.

- **proto → mp**: emit datetime ext with `tzoffset = 0, tzindex = 0`.
  Lossless.
- **mp → proto**: drop tz fields, keep the UTC instant. Loses any
  non-UTC presentation hint, preserves the actual instant. Benign for
  the Timestamp contract.

Same shape applies to Duration ↔ MP_INTERVAL (Tarantool's interval
struct also has component breakdown beyond seconds+nanos).

## Tarantool-specific options

New options on `options/tarantool/tarantool.proto`. Sketch — names
subject to change:

```proto
// File or message option.
enum MsgpackLayout {
  MAP        = 0;  // default — mp_map keyed by field number
  ARRAY      = 1;  // mp_array positional by field number, holes filled with mp_nil
}

extend google.protobuf.FileOptions {
  MsgpackLayout msgpack_layout = 60010;
}

extend google.protobuf.MessageOptions {
  MsgpackLayout msgpack_layout = 60011;       // overrides file default
  // Reserved tuple-format id; only honored when msgpack_layout = ARRAY
  // and msgpack_tuple_ext = true.
  uint32 tuple_format_id = 60012;
  bool   msgpack_tuple_ext = 60013;           // emit MP_TUPLE (ext 7) instead of bare mp_array
}
```

### Three target shapes for top-level messages

| option combination                                    | output                                           | use case                          |
| ----------------------------------------------------- | ------------------------------------------------ | --------------------------------- |
| `msgpack_layout = MAP` (default)                      | `mp_map{ 1: ..., 2: ... }`                       | RPC payload, log entry, anything where sparse fields and unknown-field passthrough matter |
| `msgpack_layout = ARRAY`                              | `mp_array{ ..., ..., ... }` padded with `mp_nil` | Drop-in for `box.space:replace{...}` |
| `msgpack_layout = ARRAY` + `msgpack_tuple_ext = true` | `mp_ext`/MP_TUPLE (ext 7), `{format_id, array}`  | Typed tuple, requires a registered `tuple_format_id` |

ARRAY layout caveats:
- Sparse high field numbers waste bytes (lots of `mp_nil` padding).
  Reasonable for messages whose field numbers are dense and stable.
  The author opted in; this is on them.
- Unknown-field passthrough is impossible — any field number past the
  array length is data loss. Encoder must error if the input has
  `_unknown_fields_msgpack` entries.
- MP_TUPLE ext requires you've registered the format somewhere
  reachable to the decoder. Without that registration the bytes are
  inert. Defer the registration story until someone needs it.

## Where things live

```
runtime/pb/msgpack.lua          new — encoder/decoder
options/tarantool/tarantool.proto  extended with msgpack_* options
cmd/protoc-gen-tarantool/internal/gen/options.go  parse new options
test/msgpack_test.lua           new — round-trip + WKT + option matrix
test/interop/fixtures/*.mp      optional — golden bytes per fixture
```

The plugin does **not** generate msgpack-specific helpers per message —
`pb.msgpack.encode(desc, t)` walks the descriptor at runtime, same as
runtime-mode wire codec does today. Full-mode wire codec inlines for
JIT reasons; msgpack codec doesn't need that complexity yet (the
msgpackffi C-level encoder does the heavy lifting on the byte side).

If perf becomes a concern, a follow-up could emit
`M.<Msg>_msgpack_encode` inlined per-message, mirroring the wire codec's
full mode. Out of scope here.

## Tests

- Round-trip: every existing `test/interop/fixtures/*.txtpb` decoded
  via proto wire codec, re-encoded via msgpack codec, decoded via
  msgpack codec, asserted equal to the original Lua table.
- Parity: msgpack-encoded then transcoded back to wire format equals
  the original `.bin` golden. Same parity discipline as the
  full-vs-runtime suite.
- WKT: explicit fixtures for Timestamp/Duration/Struct/Any covering
  the ext-type bridges.
- Layout: a few messages with both `MAP` and `ARRAY` layouts; assert
  shape on the byte side via `msgpackffi.decode_unchecked` introspection.
- Unknown-field passthrough: MAP-layout only; ARRAY-layout errors.

## Open questions (defer)

1. **Does proto-side `repeated` of a WKT survive MP_DATETIME packing?**
   `mp_array{ mp_ext, mp_ext, ... }` should just work. Worth a fixture.
2. **Custom ext types beyond WKTs.** Users may want their own Lua
   types (UUID, decimal) to ride the same ext channel. Probably
   another `(tarantool.msgpack_ext)` field option on `bytes` fields.
   Defer until someone asks.
3. **Schema evolution on ARRAY layout.** Renumbering fields breaks
   ARRAY consumers silently. Should the plugin refuse to compile ARRAY
   messages with gaps, or just warn? Probably refuse.
4. **JSON ↔ msgpack interop.** Existing `pb.json` and proposed
   `pb.msgpack` are both alternate codecs over the same descriptor;
   should they share a "set this Lua table from any codec" entry
   point? Probably yes (`pb.from(desc, bytes, format)`) but not part
   of this slice.
5. **Streaming.** Wire codec is one-shot; msgpack is too. Streaming
   adds complexity disproportionate to current needs. Skip.

## What "later" decisions look like

When picking this back up, the load-bearing calls are:

1. **MAP keyed by int vs by name.** Picking int now; revisit if
   real users find it intolerable to debug. Switching is a one-line
   change in the encoder.
2. **ARRAY + MP_TUPLE story.** Whether to ship at all in v1, or punt
   to a follow-up. ARRAY-as-`mp_array` is enough for `box.space`
   feeders; MP_TUPLE requires a format registry we don't have.
3. **Wrapper unwrapping.** Some users may want `Int32Value` to stay
   as `{value = N}` because their proto-side code treats it as a
   distinct presence-bearing type. Unwrapping is opinionated.

Everything else in this doc is mechanical and follows from those
choices.
