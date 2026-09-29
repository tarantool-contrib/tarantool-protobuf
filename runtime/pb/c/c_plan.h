/*
 * c_plan.h -- compiled-plan layout and encode-buffer helpers shared by
 * the translation units linked into pb.c_runtime.
 *
 * c_runtime.c owns the plan compiler and the Lua-table encode/decode
 * surface; everything here is the part other units in the same shared
 * object read or write against: the kind / wire-type taxonomy, the
 * plan structs a compiled descriptor becomes, and the stack-backed
 * encode buffer with its wire writers.
 *
 * Everything is `static inline` (or a type / macro), so including this
 * header from several units adds no exported symbols and no
 * unused-function warnings.
 */

#ifndef PB_C_PLAN_H
#define PB_C_PLAN_H

#include <module.h>
#include <lauxlib.h>

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define PB_PLAN_MT      "pb.plan"

/* Maximum message / group nesting the decoder descends into (and the
 * encoder emits). Must equal wire.RECURSION_LIMIT in runtime/pb/wire.lua;
 * keeping recursion bounded is what keeps hostile input from running a
 * 512KB fiber stack into the guard page. */
#define PB_RECURSION_LIMIT 100

/* ---------------------------------------------------------------- *
 *  Kind / wire-type taxonomy.                                       *
 *                                                                  *
 *  Mirrors runtime/pb/wire.lua's TYPE_INFO. The numbering is        *
 *  internal — only the C runtime needs to agree with itself.       *
 * ---------------------------------------------------------------- */

enum {
	PB_KIND_NONE = 0,
	PB_KIND_INT32,
	PB_KIND_INT64,
	PB_KIND_UINT32,
	PB_KIND_UINT64,
	PB_KIND_SINT32,
	PB_KIND_SINT64,
	PB_KIND_FIXED32,
	PB_KIND_FIXED64,
	PB_KIND_SFIXED32,
	PB_KIND_SFIXED64,
	PB_KIND_FLOAT,
	PB_KIND_DOUBLE,
	PB_KIND_BOOL,
	PB_KIND_STRING,
	PB_KIND_BYTES,
	PB_KIND_ENUM,
	PB_KIND_MESSAGE,
	PB_KIND_MAP,
};

/* Wire types per proto3 spec. SGROUP/EGROUP are proto2-only legacy. */
enum {
	PB_WIRE_VARINT = 0,
	PB_WIRE_I64    = 1,
	PB_WIRE_LEN    = 2,
	PB_WIRE_SGROUP = 3,
	PB_WIRE_EGROUP = 4,
	PB_WIRE_I32    = 5,
};

/* ---------------------------------------------------------------- *
 *  Plan struct layout.                                              *
 *                                                                  *
 *  Spec: docs/specs/c_accel_strategy.md § The plan userdata.        *
 *  Layout notes:                                                    *
 *    - oneofs[] holds member dispatch; encode/decode use            *
 *      f->oneof_idx to clear sibling branches and pick the active   *
 *      member                                                       *
 *    - extension_range_* bounds which field numbers route through   *
 *      the proto2 extensions[] dispatch                             *
 *    - sub_plan_idx points into `sub_plans_ref` table (1-based)    *
 *    - Field name strings live in a Lua table keyed by 1..n;       *
 *      lookup via `lua_rawgeti(L, names, i+1)` per spec.           *
 * ---------------------------------------------------------------- */

typedef struct pb_plan_field {
	uint32_t field_number;
	uint8_t  wire_type;
	uint8_t  kind;
	uint8_t  packed;
	uint8_t  repeated;
	uint8_t  optional;
	uint8_t  required;           /* proto2 required — missing-on-encode errors, no zero suppression */
	uint8_t  is_group;           /* proto2 group — SGROUP/EGROUP framing instead of LEN */
	uint8_t  tag_len;
	uint8_t  tag_bytes[5];
	uint8_t  egroup_tag_len;     /* groups only: pre-encoded EGROUP tag */
	uint8_t  egroup_tag_bytes[5];
	int      sub_plan_idx;       /* 1-based into sub_plans table; 0 if none */
	uint8_t  map_key_kind;
	uint8_t  map_value_kind;
	int      map_value_sub_plan_idx; /* 1-based; 0 if value is scalar */
	int      oneof_idx;          /* 0-based into plan->oneofs; -1 if none */
	int      enum_ref;           /* LUA_REGISTRYINDEX ref for enum desc; LUA_NOREF if none */
	char    *full_name;          /* extensions: "<package>.<ext_name>" key in data._extensions; NULL for regular fields */
} pb_plan_field;

typedef struct pb_plan_oneof {
	char *name;                  /* malloc'd */
	int   n_members;
	int  *member_indices;        /* indices into plan->fields */
} pb_plan_oneof;

typedef struct pb_plan {
	char *name;                  /* malloc'd descriptor name */
	int   n_fields;
	pb_plan_field *fields;
	int   n_oneofs;
	pb_plan_oneof *oneofs;
	int   extension_range_start;
	int   extension_range_end;
	int   n_extensions;          /* proto2 extensions registered on this message */
	pb_plan_field *extensions;   /* extension field shapes; keyed by full_name */
	uint8_t message_set;         /* desc.message_set: extensions travel as MessageSet items */
	uint8_t has_override;
	int   override_encode_ref;   /* LUA_NOREF if absent */
	int   override_decode_ref;
	int   field_names_ref;       /* table { [1]=name1, ... } */
	int   sub_plans_ref;         /* table { [1]=plan_userdata, ... } */
} pb_plan;

/* ---------------------------------------------------------------- *
 *  Tag encoding.                                                    *
 *                                                                  *
 *  Pre-encodes the (field_number << 3) | wire_type varint so the    *
 *  hot encode path emits a fixed memcpy instead of recomputing.    *
 *  Up to 5 bytes for any legal field number (2^29 - 1 max).        *
 * ---------------------------------------------------------------- */

static inline void
encode_tag(uint32_t field_number, uint8_t wire_type,
           uint8_t *out, uint8_t *out_len)
{
	uint64_t v = ((uint64_t)field_number << 3) | wire_type;
	uint8_t i = 0;
	while (v >= 0x80) {
		out[i++] = (uint8_t)(v | 0x80);
		v >>= 7;
	}
	out[i++] = (uint8_t)v;
	*out_len = i;
}

/* ---------------------------------------------------------------- *
 *  Encode buffer.                                                   *
 *                                                                  *
 *  Buffer strategy: a 4KB stack-backed scratch buffer that promotes *
 *  to a Lua userdata (GC'd automatically) on overflow. Using        *
 *  `lua_newuserdata` for heap growth means a luaL_error mid-encode  *
 *  doesn't leak — the userdata is still on the stack at the unwind  *
 *  point and gets collected normally.                               *
 *                                                                  *
 *  Callers reserve before they write: ebuf_reserve() guarantees     *
 *  room, the ebuf_put_* writers do no bounds checking of their own. *
 * ---------------------------------------------------------------- */

/* Initial C-stack storage for an enc_buf. Only the top-level encode gets
 * the large buffer: every nested message, group and map entry recurses
 * with its own enc_buf, and at PB_RECURSION_LIMIT levels 4KB apiece
 * would not fit a 512KB fiber stack. Nested bodies that outgrow the
 * small buffer spill to a Lua userdata like any other. */
#define ENC_TOP_BUF    4096
#define ENC_NESTED_BUF 512

typedef struct enc_buf {
	uint8_t *stack;      /* caller-provided initial storage (C stack) */
	uint8_t *heap;       /* pointer into Lua userdata when grown; NULL while on stack */
	int      heap_idx;   /* stack slot of the userdata; 0 if not yet on heap */
	size_t   cap;
	size_t   used;
	int      depth;      /* message nesting level, checked by encode_body */
} enc_buf;

static inline uint8_t *
ebuf_base(enc_buf *b)
{
	return b->heap != NULL ? b->heap : b->stack;
}

static inline void
ebuf_init(enc_buf *b, uint8_t *storage, size_t size, int depth)
{
	b->stack = storage;
	b->heap = NULL;
	b->heap_idx = 0;
	b->cap = size;
	b->used = 0;
	b->depth = depth;
}

static inline void
ebuf_grow(lua_State *L, enc_buf *b, size_t needed)
{
	size_t new_cap = b->cap * 2;
	while (new_cap - b->used < needed)
		new_cap *= 2;

	uint8_t *new_buf = (uint8_t *)lua_newuserdata(L, new_cap);
	memcpy(new_buf, ebuf_base(b), b->used);
	if (b->heap_idx == 0) {
		b->heap_idx = lua_gettop(L);
	} else {
		lua_replace(L, b->heap_idx);
	}
	b->heap = new_buf;
	b->cap = new_cap;
}

static inline void
ebuf_reserve(lua_State *L, enc_buf *b, size_t needed)
{
	if (b->cap - b->used < needed)
		ebuf_grow(L, b, needed);
}

static inline void
ebuf_put_byte(enc_buf *b, uint8_t v)
{
	ebuf_base(b)[b->used++] = v;
}

static inline void
ebuf_put_bytes(enc_buf *b, const uint8_t *src, size_t n)
{
	memcpy(ebuf_base(b) + b->used, src, n);
	b->used += n;
}

static inline void
ebuf_put_varint(enc_buf *b, uint64_t v)
{
	uint8_t *p = ebuf_base(b) + b->used;
	while (v >= 0x80) {
		*p++ = (uint8_t)(v | 0x80);
		v >>= 7;
	}
	*p++ = (uint8_t)v;
	b->used = (size_t)(p - ebuf_base(b));
}

static inline void
ebuf_put_fixed32(enc_buf *b, uint32_t v)
{
	uint8_t *p = ebuf_base(b) + b->used;
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
	b->used += 4;
}

static inline void
ebuf_put_fixed64(enc_buf *b, uint64_t v)
{
	uint8_t *p = ebuf_base(b) + b->used;
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
	p[4] = (uint8_t)(v >> 32);
	p[5] = (uint8_t)(v >> 40);
	p[6] = (uint8_t)(v >> 48);
	p[7] = (uint8_t)(v >> 56);
	b->used += 8;
}

static inline void
ebuf_put_tag(enc_buf *b, const pb_plan_field *f)
{
	memcpy(ebuf_base(b) + b->used, f->tag_bytes, f->tag_len);
	b->used += f->tag_len;
}

/* ---------------------------------------------------------------- *
 *  Scalar -> wire-value transforms (sint zigzag, float bit casts).  *
 * ---------------------------------------------------------------- */

static inline uint32_t
zigzag32(int32_t n)
{
	return ((uint32_t)n << 1) ^ (uint32_t)(n >> 31);
}

static inline uint64_t
zigzag64(int64_t n)
{
	return ((uint64_t)n << 1) ^ (uint64_t)(n >> 63);
}

static inline uint32_t
f32_to_u32(float f)
{
	union { float f; uint32_t u; } pun;
	pun.f = f;
	return pun.u;
}

static inline uint64_t
f64_to_u64(double d)
{
	union { double d; uint64_t u; } pun;
	pun.d = d;
	return pun.u;
}

#endif /* PB_C_PLAN_H */
