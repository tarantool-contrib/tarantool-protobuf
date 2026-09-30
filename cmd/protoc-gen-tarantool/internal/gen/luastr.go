package gen

import (
	"fmt"
	"strings"
)

// luaStringLiteral renders arbitrary bytes as a double-quoted Lua string
// literal that LuaJIT reads back byte for byte. Printable ASCII passes
// through (except `"` and `\`, which are backslash-escaped); every other
// byte, including newlines and NUL, becomes a fixed-width `\xNN` escape,
// so no escape can swallow a following digit.
func luaStringLiteral(s string) string {
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
