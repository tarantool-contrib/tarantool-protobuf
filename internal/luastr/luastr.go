// Package luastr renders Go strings as Lua source literals.
package luastr

import (
	"fmt"
	"strings"
)

// Literal renders arbitrary bytes as a double-quoted Lua string literal
// that LuaJIT reads back byte for byte. Printable ASCII passes through
// (except `"` and `\`, which are backslash-escaped); every other byte,
// including newlines and NUL, becomes a fixed-width `\xNN` escape, so
// no escape can swallow a following digit.
func Literal(s string) string {
	var sb strings.Builder
	sb.Grow(len(s) + 2)
	sb.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			sb.WriteByte('\\')
			sb.WriteByte(c)
		case c >= 0x20 && c <= 0x7e:
			sb.WriteByte(c)
		default:
			fmt.Fprintf(&sb, "\\x%02x", c)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

// ChunkSize is how many raw bytes Chunks puts into one literal.
const ChunkSize = 48

// Chunks splits b into ChunkSize-byte pieces and renders each as a
// Literal. Splitting the raw bytes (not the escaped text) keeps every
// escape sequence whole; concatenated back in order, the pieces are b.
func Chunks(b []byte) []string {
	var out []string
	for len(b) > 0 {
		n := ChunkSize
		if n > len(b) {
			n = len(b)
		}
		out = append(out, Literal(string(b[:n])))
		b = b[n:]
	}
	return out
}
