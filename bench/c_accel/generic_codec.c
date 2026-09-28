/*
 * generic_codec.c -- one-C-call generic codec, descriptor-walking.
 *
 * Strategy 3 of the C-acceleration spike.
 *
 * Same boundary as person_codec.c (one C call per top-level
 * encode/decode), but the inner loop walks a `message_desc_t` and
 * dispatches per-field on `kind_t`. This is what a generic
 * descriptor-driven C runtime would ship in production. The gap to
 * person_codec.c (Strategy 4) is the dispatch overhead of being
 * generic.
 *
 * Scope mirrors person_codec.c: only Person fields exercised by
 * bench/bench.lua. The descriptor tables for Person and Address
 * are hand-built; a real implementation would build them at
 * `pb.finalize_message` time from the Lua descriptor.
 */

#include <module.h>
#include <lauxlib.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- *
 *  buf_t (identical to person_codec.c -- duplicated to keep the    *
 *  spike modules independent).                                     *
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
 *  Descriptor model.                                               *
 * ---------------------------------------------------------------- */

typedef enum {
	K_INT32 = 0,
	K_STRING,
	K_MESSAGE,
	K_REPEATED_STRING,
	K_PACKED_INT32,
} kind_t;

struct message_desc;

typedef struct field_desc {
	uint32_t tag;          /* (field_num << 3) | wire_type */
	int      field_num;
	const char *name;
	kind_t   kind;
	const struct message_desc *submsg;
} field_desc_t;

typedef struct message_desc {
	const char *name;
	int n_fields;
	const field_desc_t *fields;
} message_desc_t;

/* Address (sub-message used by Person.address) */
static const field_desc_t address_fields[] = {
	{(1 << 3) | 2, 1, "street", K_STRING, NULL},
	{(2 << 3) | 2, 2, "city",   K_STRING, NULL},
	{(3 << 3) | 0, 3, "zip",    K_INT32,  NULL},
};
static const message_desc_t Address_desc = {
	"Address", 3, address_fields,
};

/* Person (subset exercised by bench payloads) */
static const field_desc_t person_fields[] = {
	{(1 << 3) | 2, 1, "name",          K_STRING,          NULL},
	{(2 << 3) | 0, 2, "age",           K_INT32,           NULL},
	{(3 << 3) | 2, 3, "emails",        K_REPEATED_STRING, NULL},
	{(5 << 3) | 2, 5, "address",       K_MESSAGE,         &Address_desc},
	{(7 << 3) | 2, 7, "lucky_numbers", K_PACKED_INT32,    NULL},
};
static const message_desc_t Person_desc = {
	"Person", 5, person_fields,
};

static int
find_field_idx(const message_desc_t *md, int field_num)
{
	for (int i = 0; i < md->n_fields; i++)
		if (md->fields[i].field_num == field_num)
			return i;
	return -1;
}

/* Max descriptor fields per message in the spike. Bumped above the
 * exercise to keep the stack-allocated index arrays in decode_message
 * safe; a real runtime would size dynamically. */
#define MAX_FIELDS_PER_MSG 16

/* ---------------------------------------------------------------- *
 *  Generic encode.                                                 *
 * ---------------------------------------------------------------- */

static void
encode_message(buf_t *b, lua_State *L, int t,
               const message_desc_t *md)
{
	for (int i = 0; i < md->n_fields; i++) {
		const field_desc_t *fd = &md->fields[i];
		lua_getfield(L, t, fd->name);
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			continue;
		}
		switch (fd->kind) {
		case K_STRING: {
			size_t n;
			const char *s = lua_tolstring(L, -1, &n);
			write_varint(b, fd->tag);
			write_varint(b, (uint64_t)n);
			write_bytes(b, s, n);
			break;
		}
		case K_INT32: {
			write_varint(b, fd->tag);
			write_varint(b,
			    (uint64_t)(int64_t)lua_tointeger(L, -1));
			break;
		}
		case K_REPEATED_STRING: {
			int idx = lua_gettop(L);
			int n = (int)lua_objlen(L, idx);
			for (int j = 1; j <= n; j++) {
				lua_rawgeti(L, idx, j);
				size_t slen;
				const char *s =
				    lua_tolstring(L, -1, &slen);
				write_varint(b, fd->tag);
				write_varint(b, (uint64_t)slen);
				write_bytes(b, s, slen);
				lua_pop(L, 1);
			}
			break;
		}
		case K_MESSAGE: {
			int idx = lua_gettop(L);
			buf_t sub;
			buf_init(&sub);
			encode_message(&sub, L, idx, fd->submsg);
			write_varint(b, fd->tag);
			write_varint(b, (uint64_t)sub.len);
			write_bytes(b, sub.data, sub.len);
			buf_free(&sub);
			break;
		}
		case K_PACKED_INT32: {
			int idx = lua_gettop(L);
			int n = (int)lua_objlen(L, idx);
			buf_t sub;
			buf_init(&sub);
			for (int j = 1; j <= n; j++) {
				lua_rawgeti(L, idx, j);
				write_varint(&sub,
				    (uint64_t)(int64_t)
				        lua_tointeger(L, -1));
				lua_pop(L, 1);
			}
			write_varint(b, fd->tag);
			write_varint(b, (uint64_t)sub.len);
			write_bytes(b, sub.data, sub.len);
			buf_free(&sub);
			break;
		}
		}
		lua_pop(L, 1);
	}
}

/* ---------------------------------------------------------------- *
 *  Generic decode.                                                 *
 * ---------------------------------------------------------------- */

static const uint8_t *
decode_message(lua_State *L, const uint8_t *p, const uint8_t *end,
               const message_desc_t *md);

/* Skip an unknown field given its wire type. Returns new p or NULL. */
static const uint8_t *
skip_field(const uint8_t *p, const uint8_t *end, int wt)
{
	uint64_t v;
	switch (wt) {
	case 0: /* varint */
		return read_varint(p, end, &v);
	case 1: /* 64-bit */
		if (end - p < 8) return NULL;
		return p + 8;
	case 2: { /* LEN */
		p = read_varint(p, end, &v);
		if (!p || (uint64_t)(end - p) < v) return NULL;
		return p + v;
	}
	case 5: /* 32-bit */
		if (end - p < 4) return NULL;
		return p + 4;
	default:
		return NULL;
	}
}

static const uint8_t *
decode_message(lua_State *L, const uint8_t *p, const uint8_t *end,
               const message_desc_t *md)
{
	lua_createtable(L, 0, md->n_fields);
	const int result_idx = lua_gettop(L);

	/* Per-field caches for repeated-array fields. Indexed by field
	 * position in md->fields. arr_stk[i] == 0 means "not yet
	 * created". Setting to result table happens once at the end so
	 * we only pay lua_setfield once per repeated field, not per
	 * element -- matches the hand-written codec's pattern. */
	int arr_stk[MAX_FIELDS_PER_MSG] = {0};
	int arr_n[MAX_FIELDS_PER_MSG] = {0};

	while (p < end) {
		uint64_t tag;
		p = read_varint(p, end, &tag);
		if (!p) break;
		int field_num = (int)(tag >> 3);
		int wt = (int)(tag & 7);
		int fi = find_field_idx(md, field_num);
		if (fi < 0) {
			p = skip_field(p, end, wt);
			if (!p) break;
			continue;
		}
		const field_desc_t *fd = &md->fields[fi];
		switch (fd->kind) {
		case K_STRING: {
			uint64_t slen;
			p = read_varint(p, end, &slen);
			if (!p || (uint64_t)(end - p) < slen) goto done;
			lua_pushlstring(L, (const char *)p, (size_t)slen);
			lua_setfield(L, result_idx, fd->name);
			p += slen;
			break;
		}
		case K_INT32: {
			uint64_t v;
			p = read_varint(p, end, &v);
			if (!p) goto done;
			lua_pushinteger(L, (lua_Integer)(int32_t)v);
			lua_setfield(L, result_idx, fd->name);
			break;
		}
		case K_REPEATED_STRING: {
			uint64_t slen;
			p = read_varint(p, end, &slen);
			if (!p || (uint64_t)(end - p) < slen) goto done;
			if (arr_stk[fi] == 0) {
				lua_createtable(L, 4, 0);
				arr_stk[fi] = lua_gettop(L);
			}
			lua_pushlstring(L, (const char *)p, (size_t)slen);
			lua_rawseti(L, arr_stk[fi], ++arr_n[fi]);
			p += slen;
			break;
		}
		case K_MESSAGE: {
			uint64_t slen;
			p = read_varint(p, end, &slen);
			if (!p || (uint64_t)(end - p) < slen) goto done;
			decode_message(L, p, p + slen, fd->submsg);
			lua_setfield(L, result_idx, fd->name);
			p += slen;
			break;
		}
		case K_PACKED_INT32: {
			uint64_t slen;
			p = read_varint(p, end, &slen);
			if (!p || (uint64_t)(end - p) < slen) goto done;
			const uint8_t *fend = p + slen;
			if (arr_stk[fi] == 0) {
				lua_createtable(L, 8, 0);
				arr_stk[fi] = lua_gettop(L);
			}
			while (p < fend) {
				uint64_t v;
				p = read_varint(p, fend, &v);
				if (!p) break;
				lua_pushinteger(L,
				    (lua_Integer)(int32_t)v);
				lua_rawseti(L, arr_stk[fi], ++arr_n[fi]);
			}
			break;
		}
		}
	}
done:
	/* Attach any deferred repeated arrays to the result table. */
	for (int i = 0; i < md->n_fields; i++) {
		if (arr_stk[i]) {
			lua_pushvalue(L, arr_stk[i]);
			lua_setfield(L, result_idx, md->fields[i].name);
		}
	}
	lua_settop(L, result_idx);
	return p;
}

/* ---------------------------------------------------------------- *
 *  Lua entry points.                                               *
 * ---------------------------------------------------------------- */

static int
Person_encode(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	buf_t b;
	buf_init(&b);
	encode_message(&b, L, 1, &Person_desc);
	lua_pushlstring(L, (const char *)b.data, b.len);
	buf_free(&b);
	return 1;
}

static int
Person_decode(lua_State *L)
{
	size_t len;
	const char *buf = luaL_checklstring(L, 1, &len);
	decode_message(L, (const uint8_t *)buf,
	               (const uint8_t *)buf + len, &Person_desc);
	return 1;
}

static const struct luaL_Reg lib[] = {
	{"Person_encode", Person_encode},
	{"Person_decode", Person_decode},
	{NULL, NULL},
};

LUA_API int
luaopen_pb_c_generic(lua_State *L)
{
	luaL_register(L, "pb_c_generic", lib);
	return 1;
}
