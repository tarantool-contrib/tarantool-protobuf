/*
 * prim.c -- per-primitive wire helpers exposed via plain C ABI.
 *
 * Strategy 2 of the C-acceleration spike. Lua-side dispatch stays in
 * Lua (read t.name, t.age, ... via t-table accesses), but each
 * wire-format primitive crosses the FFI boundary.
 *
 * Compile as a shared lib loaded by ffi.load() -- not luaopen_*.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

/* ibuf shape mirrors the FFI cdef in prim_ffi.lua. */
typedef struct ibuf_s {
	uint8_t *data;
	size_t   len;
	size_t   cap;
} ibuf_t;

EXPORT void
pb_ibuf_init(ibuf_t *b)
{
	b->cap = 4096;
	b->data = (uint8_t *)malloc(b->cap);
	b->len = 0;
}

EXPORT void
pb_ibuf_free(ibuf_t *b)
{
	free(b->data);
	b->data = NULL;
	b->cap = 0;
	b->len = 0;
}

EXPORT void
pb_ibuf_reset(ibuf_t *b)
{
	b->len = 0;
}

static void
pb_ibuf_grow(ibuf_t *b, size_t need)
{
	size_t nc = b->cap;
	while (nc < b->len + need)
		nc *= 2;
	b->data = (uint8_t *)realloc(b->data, nc);
	b->cap = nc;
}

static inline void
pb_ibuf_reserve(ibuf_t *b, size_t need)
{
	if (b->len + need > b->cap)
		pb_ibuf_grow(b, need);
}

/* ---------------------------------------------------------------- *
 *  Primitives.                                                     *
 * ---------------------------------------------------------------- */

EXPORT void
pb_write_varint(ibuf_t *b, uint64_t v)
{
	pb_ibuf_reserve(b, 10);
	while (v >= 0x80) {
		b->data[b->len++] = (uint8_t)(v | 0x80);
		v >>= 7;
	}
	b->data[b->len++] = (uint8_t)v;
}

EXPORT void
pb_write_bytes(ibuf_t *b, const uint8_t *src, size_t n)
{
	pb_ibuf_reserve(b, n);
	memcpy(b->data + b->len, src, n);
	b->len += n;
}

/* Combined "string field": tag + length + payload. Three primitives
 * fused into one to lower FFI call count for the most common field
 * shape; honesty note in README. */
EXPORT void
pb_write_string_field(ibuf_t *b, uint32_t tag, const uint8_t *src,
                      size_t n)
{
	pb_write_varint(b, tag);
	pb_write_varint(b, n);
	pb_write_bytes(b, src, n);
}

/* Returns a pointer past the varint, or NULL on truncation. */
EXPORT const uint8_t *
pb_read_varint(const uint8_t *p, const uint8_t *end, uint64_t *out)
{
	uint64_t v = 0;
	int shift = 0;
	while (p < end) {
		uint8_t c = *p++;
		v |= (uint64_t)(c & 0x7f) << shift;
		if (!(c & 0x80)) {
			*out = v;
			return p;
		}
		shift += 7;
		if (shift >= 64)
			return NULL;
	}
	return NULL;
}
