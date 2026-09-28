/*
 * person_codec.c -- hand-written C codec for hello.Person.
 *
 * Strategy 4 of the C-acceleration spike: upper-bound measurement.
 *
 * Scope: ONLY the fields exercised by bench/bench.lua's Person payloads:
 *   name (string, 1), age (int32, 2), emails (repeated string, 3),
 *   address (Address message, 5), lucky_numbers (packed int32, 7).
 *
 * Other Person fields (status, friends, avatar, user_id, balance,
 * weight_kg, maps) are intentionally absent. The spike measures the
 * upper bound of C boundary perf for the bench shapes, not full
 * codec coverage.
 *
 * Type-check parity with generic_codec.c: field presence is via
 * lua_isnil, with no per-element lua_type check inside repeated
 * loops. The original (2026-05-18) version did defensive lua_type
 * checks per element, which added ~2700 extra C calls per message
 * at 100KB and made S4 look slower than S3 at 1KB+. Don't add them
 * back without re-measuring; see README for the post-correction
 * numbers.
 */

#include <module.h>
#include <lauxlib.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- *
 *  Growable byte buffer with a 4 KiB stack-backed initial region.  *
 * ---------------------------------------------------------------- */

typedef struct {
	uint8_t *data;
	size_t len;
	size_t cap;
	uint8_t stack[4096];
} buf_t;

static inline void
buf_init(buf_t *b)
{
	b->data = b->stack;
	b->len = 0;
	b->cap = sizeof(b->stack);
}

static inline void
buf_free(buf_t *b)
{
	if (b->data != b->stack)
		free(b->data);
}

static void
buf_grow(buf_t *b, size_t need)
{
	size_t nc = b->cap ? b->cap * 2 : 64;
	while (nc < b->len + need)
		nc *= 2;
	uint8_t *nd = (uint8_t *)malloc(nc);
	memcpy(nd, b->data, b->len);
	if (b->data != b->stack)
		free(b->data);
	b->data = nd;
	b->cap = nc;
}

static inline void
buf_reserve(buf_t *b, size_t need)
{
	if (b->len + need > b->cap)
		buf_grow(b, need);
}

/* ---------------------------------------------------------------- *
 *  Wire primitives.                                                *
 * ---------------------------------------------------------------- */

static inline void
write_varint(buf_t *b, uint64_t v)
{
	buf_reserve(b, 10);
	while (v >= 0x80) {
		b->data[b->len++] = (uint8_t)(v | 0x80);
		v >>= 7;
	}
	b->data[b->len++] = (uint8_t)v;
}

static inline void
write_bytes(buf_t *b, const void *src, size_t n)
{
	buf_reserve(b, n);
	memcpy(b->data + b->len, src, n);
	b->len += n;
}

static inline void
write_string_field(buf_t *b, uint32_t tag, const char *s, size_t n)
{
	write_varint(b, tag);
	write_varint(b, (uint64_t)n);
	write_bytes(b, s, n);
}

/* Read a varint. Returns new pointer on success, NULL on truncation. */
static const uint8_t *
read_varint(const uint8_t *p, const uint8_t *end, uint64_t *out)
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

/* ---------------------------------------------------------------- *
 *  Address encode/decode helpers (sub-message, fields used in       *
 *  bench payloads: street/1, city/2, zip/3).                        *
 * ---------------------------------------------------------------- */

static void
encode_address_body(buf_t *b, lua_State *L, int t)
{
	lua_getfield(L, t, "street");
	if (!lua_isnil(L, -1)) {
		size_t n;
		const char *s = lua_tolstring(L, -1, &n);
		write_string_field(b, (1 << 3) | 2, s, n);
	}
	lua_pop(L, 1);

	lua_getfield(L, t, "city");
	if (!lua_isnil(L, -1)) {
		size_t n;
		const char *s = lua_tolstring(L, -1, &n);
		write_string_field(b, (2 << 3) | 2, s, n);
	}
	lua_pop(L, 1);

	lua_getfield(L, t, "zip");
	if (!lua_isnil(L, -1)) {
		write_varint(b, (3 << 3) | 0);
		write_varint(b, (uint64_t)(int64_t)lua_tointeger(L, -1));
	}
	lua_pop(L, 1);
}

static const uint8_t *
decode_address(lua_State *L, const uint8_t *p, const uint8_t *end)
{
	lua_createtable(L, 0, 3);
	while (p < end) {
		uint64_t tag;
		p = read_varint(p, end, &tag);
		if (!p)
			return NULL;
		int field = (int)(tag >> 3);
		int wt = (int)(tag & 7);
		if (wt == 2) {
			uint64_t slen;
			p = read_varint(p, end, &slen);
			if (!p || (size_t)(end - p) < slen)
				return NULL;
			if (field == 1) {
				lua_pushlstring(L, (const char *)p, (size_t)slen);
				lua_setfield(L, -2, "street");
			} else if (field == 2) {
				lua_pushlstring(L, (const char *)p, (size_t)slen);
				lua_setfield(L, -2, "city");
			}
			p += slen;
		} else if (wt == 0) {
			uint64_t v;
			p = read_varint(p, end, &v);
			if (!p)
				return NULL;
			if (field == 3) {
				lua_pushinteger(L, (lua_Integer)(int32_t)v);
				lua_setfield(L, -2, "zip");
			}
		} else {
			/* Unknown wire types ignored in spike. */
			return NULL;
		}
	}
	return p;
}

/* ---------------------------------------------------------------- *
 *  Person_encode(tbl) -> string                                    *
 * ---------------------------------------------------------------- */

static int
Person_encode(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	const int t = 1;
	buf_t b;
	buf_init(&b);

	/* name (1, string) */
	lua_getfield(L, t, "name");
	if (!lua_isnil(L, -1)) {
		size_t n;
		const char *s = lua_tolstring(L, -1, &n);
		write_string_field(&b, (1 << 3) | 2, s, n);
	}
	lua_pop(L, 1);

	/* age (2, int32) */
	lua_getfield(L, t, "age");
	if (!lua_isnil(L, -1)) {
		write_varint(&b, (2 << 3) | 0);
		write_varint(&b, (uint64_t)(int64_t)lua_tointeger(L, -1));
	}
	lua_pop(L, 1);

	/* emails (3, repeated string) */
	lua_getfield(L, t, "emails");
	if (!lua_isnil(L, -1)) {
		int idx = lua_gettop(L);
		int n_emails = (int)lua_objlen(L, idx);
		for (int i = 1; i <= n_emails; i++) {
			lua_rawgeti(L, idx, i);
			size_t n;
			const char *s = lua_tolstring(L, -1, &n);
			write_string_field(&b, (3 << 3) | 2, s, n);
			lua_pop(L, 1);
		}
	}
	lua_pop(L, 1);

	/* address (5, sub-message) */
	lua_getfield(L, t, "address");
	if (!lua_isnil(L, -1)) {
		int addr_idx = lua_gettop(L);
		buf_t sub;
		buf_init(&sub);
		encode_address_body(&sub, L, addr_idx);
		write_varint(&b, (5 << 3) | 2);
		write_varint(&b, (uint64_t)sub.len);
		write_bytes(&b, sub.data, sub.len);
		buf_free(&sub);
	}
	lua_pop(L, 1);

	/* lucky_numbers (7, packed int32) */
	lua_getfield(L, t, "lucky_numbers");
	if (!lua_isnil(L, -1)) {
		int idx = lua_gettop(L);
		int n = (int)lua_objlen(L, idx);
		buf_t sub;
		buf_init(&sub);
		for (int i = 1; i <= n; i++) {
			lua_rawgeti(L, idx, i);
			write_varint(&sub, (uint64_t)(int64_t)lua_tointeger(L, -1));
			lua_pop(L, 1);
		}
		write_varint(&b, (7 << 3) | 2);
		write_varint(&b, (uint64_t)sub.len);
		write_bytes(&b, sub.data, sub.len);
		buf_free(&sub);
	}
	lua_pop(L, 1);

	lua_pushlstring(L, (const char *)b.data, b.len);
	buf_free(&b);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  Person_decode(string) -> tbl                                    *
 * ---------------------------------------------------------------- */

static int
Person_decode(lua_State *L)
{
	size_t len;
	const char *buf = luaL_checklstring(L, 1, &len);
	const uint8_t *p = (const uint8_t *)buf;
	const uint8_t *end = p + len;

	lua_createtable(L, 0, 5);
	const int result_idx = lua_gettop(L);

	/* Lazy arrays: stash stack index of the array table once created. */
	int emails_stkidx = 0;
	int n_emails = 0;
	int lucky_stkidx = 0;
	int n_lucky = 0;

	while (p < end) {
		uint64_t tag;
		p = read_varint(p, end, &tag);
		if (!p)
			break;
		int field = (int)(tag >> 3);
		int wt = (int)(tag & 7);

		if (wt == 2) {
			uint64_t slen;
			p = read_varint(p, end, &slen);
			if (!p || (size_t)(end - p) < slen)
				break;
			const uint8_t *fend = p + slen;

			switch (field) {
			case 1: /* name */
				lua_pushlstring(L, (const char *)p, (size_t)slen);
				lua_setfield(L, result_idx, "name");
				break;
			case 3: /* emails (repeated string) */
				if (emails_stkidx == 0) {
					lua_createtable(L, 4, 0);
					emails_stkidx = lua_gettop(L);
				}
				lua_pushlstring(L, (const char *)p, (size_t)slen);
				lua_rawseti(L, emails_stkidx, ++n_emails);
				break;
			case 5: /* address (sub-message) */
				if (decode_address(L, p, fend) == NULL)
					goto done;
				lua_setfield(L, result_idx, "address");
				break;
			case 7: { /* lucky_numbers (packed int32) */
				if (lucky_stkidx == 0) {
					lua_createtable(L, 8, 0);
					lucky_stkidx = lua_gettop(L);
				}
				const uint8_t *q = p;
				while (q < fend) {
					uint64_t v;
					q = read_varint(q, fend, &v);
					if (!q)
						break;
					lua_pushinteger(L,
					    (lua_Integer)(int32_t)v);
					lua_rawseti(L, lucky_stkidx,
					    ++n_lucky);
				}
				break;
			}
			default:
				/* Unknown LEN field -- skip silently. */
				break;
			}
			p = fend;
		} else if (wt == 0) {
			uint64_t v;
			p = read_varint(p, end, &v);
			if (!p)
				break;
			if (field == 2) { /* age */
				lua_pushinteger(L, (lua_Integer)(int32_t)v);
				lua_setfield(L, result_idx, "age");
			}
		} else {
			/* Other wire types not exercised by bench payloads. */
			break;
		}
	}
done:
	if (emails_stkidx) {
		lua_pushvalue(L, emails_stkidx);
		lua_setfield(L, result_idx, "emails");
	}
	if (lucky_stkidx) {
		lua_pushvalue(L, lucky_stkidx);
		lua_setfield(L, result_idx, "lucky_numbers");
	}
	lua_settop(L, result_idx);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  Module entry.                                                   *
 * ---------------------------------------------------------------- */

static const struct luaL_Reg lib[] = {
	{"Person_encode", Person_encode},
	{"Person_decode", Person_decode},
	{NULL, NULL},
};

LUA_API int
luaopen_pb_c_person(lua_State *L)
{
	luaL_register(L, "pb_c_person", lib);
	return 1;
}
