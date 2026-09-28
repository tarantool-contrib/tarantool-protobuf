# How-to: text format for debugging

Mainline `protoc --decode` produces a readable, line-oriented text
representation of any proto message. The `pb` runtime emits the
same shape via `pb.text.encode` and parses it via `pb.text.decode`.

Use it for:

- **Log lines** — set `single_line = true` and you get a one-liner
  that grep / jq won't choke on.
- **Test fixtures** — `.txtpb` files round-trip into bytes via
  mainline `protoc --encode` and into Lua tables via
  `pb.text.decode`; the conformance suite uses this pattern for the
  10-fixture interop corpus.
- **Debugging** — when a JSON dump elides 64-bit precision or you
  want to *see* the field IDs, the text form is more faithful.

## Encode

Generated codegen emits a `M.<Type>_text` wrapper:

```lua
local hello = require('full.hello.hello_pb')

print(hello.Person_text({name = 'Alice', age = 30, emails = {'a@x'}}))
-- name: "Alice"
-- age: 30
-- emails: "a@x"

-- Compact, one-line form:
print(hello.Person_text({name = 'Alice', age = 30}, {single_line = true}))
-- name: "Alice" age: 30

-- Custom indent:
print(hello.Person_text(t, {indent = '    '}))
```

Options:

| Key | Default | Meaning |
|---|---|---|
| `single_line` | `false` | Collapse to a single space-separated line — log-friendly. |
| `indent` | `'  '` (two spaces) | Per-nesting-level indent. Ignored when `single_line = true`. |

## Decode

There's no per-message `_text_decode` wrapper — call
`pb.text.decode(desc, text)` directly. (The wrapper was deliberately
not generated; it's used in a few places like the conformance
runner, and didn't warrant codegen surface.)

```lua
local pb = require('pb')

local t = pb.text.decode(hello.Person_descriptor, [[
    name: "Alice"
    age: 30
    emails: "a@x"
    emails: "b@x"
]])

print(t.name, t.age, t.emails[1])
```

The parser handles every grammar bucket the proto3 conformance text
suite exercises:

- Integer literals: decimal, `0x` hex, `0`-prefix octal.
- Float specials: `inf` / `infinity` / `nan` (any case), oversize
  exponents saturating to ±inf, underflow to ±0.
- C-style escapes (`\n`, `\xFF`, `\377`) and `\u`/`\U` escapes with
  adjacent-literal concat.
- Aggregate `{ ... }` and `< ... >` bodies for sub-messages.
- Repeated short-form `field: [a, b, c]`.
- Map entries: `field { key: K value: V }`.
- Inline `Any`: `field [type.googleapis.com/Foo] { ... }`.
- Enums by name (`status: OK`) or number (`status: 1`).
- Reserved-name fields are silently dropped.
- Numeric field IDs tolerated: `42: "value"` works alongside
  `name: "value"`.

## Round-tripping via mainline `protoc`

The interop suite leans on this:

```bash
# Encode a .txtpb fixture to wire bytes via mainline protoc.
protoc --encode=hello.Person hello.proto < person.txtpb > person.bin

# Decode it back via pb.
local bytes = io.open('person.bin', 'rb'):read('*a')
local p = hello.Person_decode(bytes)
print(hello.Person_text(p))
```

The text form is what makes the fixtures human-readable in
`test/interop/fixtures/*.txtpb` while the wire-equality check runs
against the matching `.bin` files.

## Limitations

- The text form is mainline-protoc-compatible, not stable across
  versions. Don't use it as a persistence format.
- Comments aren't preserved by the parser (they're stripped to
  whitespace, like in JSON).
- Float printing uses Lua's `%.*g` formatting — bit-exact
  round-trip is guaranteed (the codec picks precision to hit
  IEEE-754 exact reconstruction), but adjacent-fixture *byte*
  equality vs mainline `protoc` can differ in non-significant
  digits.

## What's next

- [Reference: runtime API → pb.text](../reference/runtime-api.md#pbtext)
  — full signatures.
- [How-to: JSON over HTTP](06-json-http.md) — the structurally-
  parsed alternative when humans aren't reading the bytes.
