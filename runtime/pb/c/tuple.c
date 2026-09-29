/*
 * tuple.c -- box.tuple -> protobuf wire encoder for pb.tuple.
 *
 * pb.tuple.bind (runtime/pb/tuple.lua) compiles a descriptor and a space
 * format into a plan: a graph of Lua nodes, one per message level (IF2,
 * documented in the header of tuple.lua). This unit compiles that graph
 * into a flat array of C nodes and encodes tuples against it, reading the
 * tuple's msgpack in place:
 *
 *   c_runtime.tuple_compile(plan)                             -> tplan
 *   c_runtime.tuple_encode(tplan, tuple)                      -> string
 *   c_runtime.tuple_encode_repeated(tplan, field_no, tuples)  -> string
 *
 * The Lua encoder in tuple.lua is the reference: for every tuple the
 * output bytes and the error messages are the same. The C side adds no
 * rule of its own; where this file makes a choice, it is the Lua path's.
 *
 * Plan graph -> C nodes
 * ---------------------
 * Map-layout nodes are shared per descriptor, so a recursive message
 * yields a cyclic graph. The compiler numbers the nodes breadth-first
 * through a memo table (node -> index) and refers to children by index,
 * so it never recurses. Encoding recurses once per message level and
 * raises past PB_RECURSION_LIMIT, as the Lua path does.
 *
 * Encoding a message level
 * ------------------------
 * The wire output lists fields in ascending field-number order whatever
 * the key order in the tuple's maps. Each level first scans its msgpack
 * map (or array) and records where each field's value starts, one slot
 * per plan field; then it walks the slots in plan order and emits the
 * non-NULL ones. The slots live in a scratch array owned by the tplan,
 * grown on demand and reused by every call, so the per-call cost is no
 * allocation at all.
 *
 * Output goes to one enc_buf (c_plan.h): 4KB on the C stack, promoted to
 * Lua userdata on overflow, so a luaL_error mid-encode leaks nothing. A
 * length-delimited body is written in place after a one-byte length
 * placeholder, and moved up when its length needs more bytes. The only
 * Lua value allocated by an encode is the result string (plus the
 * buffer's growth userdata for a result past 4KB).
 */

#include <module.h>
#include <lauxlib.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "c_plan.h"
#include "msgpuck.h"
#include "tuple.h"

#define TUPLE_PLAN_MT "pb.tuple_plan"

/* Largest legal field number, 2^29 - 1. */
#define TP_MAX_FIELD_NO 536870911

/* google.protobuf.Timestamp, stored as a datetime; not a sub-node. */
#define TP_KIND_TIMESTAMP (PB_KIND_MAP + 1)

enum {
	TP_LAYOUT_TUPLE = 1,
	TP_LAYOUT_MAP,
	TP_LAYOUT_ARRAY,
};

enum {
	TP_REPR_SCALAR = 1,
	TP_REPR_MSG_MAP,
	TP_REPR_MSG_ARRAY,
	TP_REPR_RAW,
	TP_REPR_LIST,
	TP_REPR_DICT,
};

/* The only conversion codes that change what encode does. */
enum {
	TP_UUID_NONE = 0,
	TP_UUID_TEXT,
	TP_UUID_BIN,
};

/* Integer ranges, as INT_RANGE in tuple.lua. */
enum {
	TP_RANGE_NONE = 0,
	TP_RANGE_S32,
	TP_RANGE_U32,
	TP_RANGE_S64,
	TP_RANGE_U64,
};

/* Location of a value inside its field, for error messages: the field's
 * own value, an element index (> 0), a map key or a map value. */
#define TP_ELEM_NONE   0
#define TP_ELEM_KEY   (-1)
#define TP_ELEM_VALUE (-2)

/* ---------------------------------------------------------------- *
 *  Compiled plan.                                                   *
 * ---------------------------------------------------------------- */

typedef struct tp_field {
	char    *name;           /* proto field name; the key in a map layout */
	uint32_t name_len;
	char    *column_name;    /* tuple layout: column name; else "" */
	uint32_t field_no;
	uint32_t column;         /* tuple: column; array: position; map: 0 */
	uint8_t  kind;           /* PB_KIND_* or TP_KIND_TIMESTAMP */
	uint8_t  repr;           /* TP_REPR_* */
	uint8_t  uuid;           /* TP_UUID_* */
	uint8_t  optional;       /* explicit presence: written when default */
	uint8_t  packed;         /* repeated scalar written packed */
	uint8_t  key_kind;       /* map<K,V> only */
	uint8_t  value_kind;     /* map<K,V> only */
	uint8_t  tag_len;
	uint8_t  key_tag_len;
	uint8_t  val_tag_len;
	uint8_t  tag[5];
	uint8_t  key_tag[5];
	uint8_t  val_tag[5];
	int      sub;            /* child node index; -1 when none */
	int      oneof;          /* 1-based oneof group; 0 when none */
	int      oneof_prev;     /* previous member of the same group; -1 */
} tp_field;

typedef struct tp_node {
	char     *message;       /* full message name */
	uint8_t   layout;        /* TP_LAYOUT_* */
	int       n;
	tp_field *fields;        /* ascending field number */
	int       n_oneofs;
	char    **oneof_names;
	uint32_t  width;         /* tuple / array: largest column */
	int      *at;            /* tuple / array: [column] -> field or -1 */
	int      *by_name;       /* map: field indices sorted by name */
} tp_node;

typedef struct tp_plan {
	int          n_nodes;
	tp_node     *nodes;      /* nodes[0] is the tuple level */
	const char **slots;      /* scratch: per-level value positions */
	size_t       slots_cap;
} tp_plan;

static void
tp_plan_free(tp_plan *tp)
{
	for (int k = 0; k < tp->n_nodes; k++) {
		tp_node *node = &tp->nodes[k];
		free(node->message);
		if (node->fields != NULL) {
			for (int i = 0; i < node->n; i++) {
				free(node->fields[i].name);
				free(node->fields[i].column_name);
			}
		}
		free(node->fields);
		if (node->oneof_names != NULL) {
			for (int j = 0; j < node->n_oneofs; j++)
				free(node->oneof_names[j]);
		}
		free(node->oneof_names);
		free(node->at);
		free(node->by_name);
	}
	free(tp->nodes);
	free((void *)tp->slots);
	memset(tp, 0, sizeof(*tp));
}

static int
tuple_plan_gc(lua_State *L)
{
	tp_plan *tp = (tp_plan *)luaL_checkudata(L, 1, TUPLE_PLAN_MT);
	tp_plan_free(tp);
	return 0;
}

static int
tuple_plan_tostring(lua_State *L)
{
	tp_plan *tp = (tp_plan *)luaL_checkudata(L, 1, TUPLE_PLAN_MT);
	lua_pushfstring(L, "pb.tuple_plan: %s (%d nodes)",
	                tp->n_nodes > 0 ? tp->nodes[0].message : "(empty)",
	                tp->n_nodes);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  Kind taxonomy.                                                   *
 * ---------------------------------------------------------------- */

static const struct {
	const char *name;
	uint8_t kind;
} tp_kinds[] = {
	{"int32",     PB_KIND_INT32},
	{"int64",     PB_KIND_INT64},
	{"uint32",    PB_KIND_UINT32},
	{"uint64",    PB_KIND_UINT64},
	{"sint32",    PB_KIND_SINT32},
	{"sint64",    PB_KIND_SINT64},
	{"fixed32",   PB_KIND_FIXED32},
	{"fixed64",   PB_KIND_FIXED64},
	{"sfixed32",  PB_KIND_SFIXED32},
	{"sfixed64",  PB_KIND_SFIXED64},
	{"float",     PB_KIND_FLOAT},
	{"double",    PB_KIND_DOUBLE},
	{"bool",      PB_KIND_BOOL},
	{"string",    PB_KIND_STRING},
	{"bytes",     PB_KIND_BYTES},
	{"enum",      PB_KIND_ENUM},
	{"message",   PB_KIND_MESSAGE},
	{"timestamp", TP_KIND_TIMESTAMP},
	{"map",       PB_KIND_MAP},
};

#define TP_N_KINDS ((int)(sizeof(tp_kinds) / sizeof(tp_kinds[0])))

static const char *
tp_kind_name(uint8_t kind)
{
	for (int k = 0; k < TP_N_KINDS; k++) {
		if (tp_kinds[k].kind == kind)
			return tp_kinds[k].name;
	}
	return "?";
}

/* A kind whose values are single scalars (the proto scalar types and
 * enum): what `read_scalar` in tuple.lua converts. */
static int
tp_is_scalar_kind(uint8_t kind)
{
	return kind >= PB_KIND_INT32 && kind <= PB_KIND_ENUM;
}

static int
tp_range_of(uint8_t kind)
{
	switch (kind) {
	case PB_KIND_INT32:
	case PB_KIND_SINT32:
	case PB_KIND_SFIXED32:
	case PB_KIND_ENUM:
		return TP_RANGE_S32;
	case PB_KIND_UINT32:
	case PB_KIND_FIXED32:
		return TP_RANGE_U32;
	case PB_KIND_INT64:
	case PB_KIND_SINT64:
	case PB_KIND_SFIXED64:
		return TP_RANGE_S64;
	case PB_KIND_UINT64:
	case PB_KIND_FIXED64:
		return TP_RANGE_U64;
	default:
		return TP_RANGE_NONE;
	}
}

/* Wire type of a single value of `kind` (value_wire in tuple.lua). */
static uint8_t
tp_value_wire(uint8_t kind)
{
	switch (kind) {
	case PB_KIND_INT32:
	case PB_KIND_INT64:
	case PB_KIND_UINT32:
	case PB_KIND_UINT64:
	case PB_KIND_SINT32:
	case PB_KIND_SINT64:
	case PB_KIND_BOOL:
	case PB_KIND_ENUM:
		return PB_WIRE_VARINT;
	case PB_KIND_FIXED32:
	case PB_KIND_SFIXED32:
	case PB_KIND_FLOAT:
		return PB_WIRE_I32;
	case PB_KIND_FIXED64:
	case PB_KIND_SFIXED64:
	case PB_KIND_DOUBLE:
		return PB_WIRE_I64;
	default:
		return PB_WIRE_LEN;
	}
}

/* ---------------------------------------------------------------- *
 *  Plan compiler.                                                   *
 *                                                                  *
 *  Every read is checked: a plan that does not have the documented  *
 *  shape raises "malformed plan" instead of being guessed at.       *
 * ---------------------------------------------------------------- */

static int
tp_malformed(lua_State *L, const char *message, const char *what)
{
	return luaL_error(L, "pb.tuple: malformed plan of %s: %s",
	                  message != NULL ? message : "?", what);
}

static char *
tp_strdup(lua_State *L, const char *s, size_t len)
{
	char *copy = (char *)malloc(len + 1);
	if (copy == NULL)
		luaL_error(L, "pb.tuple: out of memory compiling a plan");
	memcpy(copy, s, len);
	copy[len] = '\0';
	return copy;
}

static void *
tp_calloc(lua_State *L, size_t n, size_t size)
{
	void *p = calloc(n > 0 ? n : 1, size);
	if (p == NULL)
		luaL_error(L, "pb.tuple: out of memory compiling a plan");
	return p;
}

/* Push t[key] of the table at `idx` (raw) and check its type. */
static void
tp_push_key(lua_State *L, int idx, const char *key, int type,
            const char *message)
{
	lua_pushstring(L, key);
	lua_rawget(L, idx);
	if (lua_type(L, -1) != type) {
		lua_pushfstring(L, "'%s' is not a %s", key,
		                lua_typename(L, type));
		tp_malformed(L, message, lua_tostring(L, -1));
	}
}

static const char *
tp_arr_str(lua_State *L, int arr, int i, const char *key,
           const char *message, size_t *len)
{
	lua_rawgeti(L, arr, i);
	if (lua_type(L, -1) != LUA_TSTRING) {
		lua_pushfstring(L, "%s[%d] is not a string", key, i);
		tp_malformed(L, message, lua_tostring(L, -1));
	}
	/* The string stays referenced by the array table, so the pointer
	 * outlives the pop. */
	const char *s = lua_tolstring(L, -1, len);
	lua_pop(L, 1);
	return s;
}

static lua_Integer
tp_arr_int(lua_State *L, int arr, int i, const char *key,
           const char *message, lua_Integer lo, lua_Integer hi)
{
	lua_rawgeti(L, arr, i);
	lua_Number d = lua_tonumber(L, -1);
	if (lua_type(L, -1) != LUA_TNUMBER || !(d >= (lua_Number)lo) ||
	    !(d <= (lua_Number)hi) || d != (lua_Number)(lua_Integer)d) {
		lua_pushfstring(L, "%s[%d] is not an integer in [%d, %d]",
		                key, i, (int)lo, (int)hi);
		tp_malformed(L, message, lua_tostring(L, -1));
	}
	lua_pop(L, 1);
	return (lua_Integer)d;
}

static int
tp_arr_bool(lua_State *L, int arr, int i, const char *key,
            const char *message)
{
	lua_rawgeti(L, arr, i);
	if (lua_type(L, -1) != LUA_TBOOLEAN) {
		lua_pushfstring(L, "%s[%d] is not a boolean", key, i);
		tp_malformed(L, message, lua_tostring(L, -1));
	}
	int v = lua_toboolean(L, -1);
	lua_pop(L, 1);
	return v;
}

/* One of `names` (NULL-terminated), as its 1-based position. */
static int
tp_arr_enum(lua_State *L, int arr, int i, const char *key,
            const char *message, const char *const *names)
{
	size_t len;
	const char *s = tp_arr_str(L, arr, i, key, message, &len);
	for (int k = 0; names[k] != NULL; k++) {
		if (strcmp(s, names[k]) == 0)
			return k + 1;
	}
	lua_pushfstring(L, "%s[%d] = '%s' is not known", key, i, s);
	return tp_malformed(L, message, lua_tostring(L, -1));
}

/* A kind name, or '' (returned as 0) when `allow_empty`. */
static uint8_t
tp_arr_kind(lua_State *L, int arr, int i, const char *key,
            const char *message, int allow_empty)
{
	size_t len;
	const char *s = tp_arr_str(L, arr, i, key, message, &len);
	if (allow_empty && len == 0)
		return 0;
	for (int k = 0; k < TP_N_KINDS; k++) {
		if (strcmp(s, tp_kinds[k].name) == 0)
			return tp_kinds[k].kind;
	}
	lua_pushfstring(L, "%s[%d] = '%s' is not a kind", key, i, s);
	tp_malformed(L, message, lua_tostring(L, -1));
	return 0;
}

static const char *const tp_layout_names[] = {"tuple", "map", "array", NULL};
static const char *const tp_repr_names[] = {
	"scalar", "msg_map", "msg_array", "raw", "list", "dict", NULL,
};
static const char *const tp_conv_names[] = {
	"direct", "range", "number", "str_bin", "uuid_text", "uuid_bin",
	"any", NULL,
};

static int
tp_name_cmp(const char *a, uint32_t alen, const char *b, uint32_t blen)
{
	if (alen != blen)
		return alen < blen ? -1 : 1;
	return memcmp(a, b, alen);
}

/* Parallel arrays of a plan node, as stack indices. */
struct tp_arrays {
	int field_no, name, column, column_name, kind, packed, repr, conv,
	    optional, key_kind, value_kind, sub, oneof;
};

/*
 * Compile the plan node at stack index `idx` into `node`. `memo` maps
 * node tables to their 1-based index.
 */
static void
tp_compile_node(lua_State *L, tp_node *node, int idx, int memo,
                int is_root)
{
	int top = lua_gettop(L);
	size_t len;

	tp_push_key(L, idx, "message", LUA_TSTRING, NULL);
	const char *message = lua_tolstring(L, -1, &len);
	node->message = tp_strdup(L, message, len);
	message = node->message;

	tp_push_key(L, idx, "layout", LUA_TSTRING, message);
	int layout = 0;
	for (int k = 0; tp_layout_names[k] != NULL; k++) {
		if (strcmp(lua_tostring(L, -1), tp_layout_names[k]) == 0)
			layout = k + 1;
	}
	if (layout == 0 || (layout == TP_LAYOUT_TUPLE) != (is_root != 0))
		tp_malformed(L, message, "unexpected layout");
	node->layout = (uint8_t)layout;

	tp_push_key(L, idx, "n", LUA_TNUMBER, message);
	lua_Number dn = lua_tonumber(L, -1);
	if (!(dn >= 0) || !(dn <= 1000000) || dn != (lua_Number)(int)dn)
		tp_malformed(L, message, "'n' is not a field count");
	int n = (int)dn;

	struct tp_arrays a;
	tp_push_key(L, idx, "field_no", LUA_TTABLE, message);
	a.field_no = lua_gettop(L);
	tp_push_key(L, idx, "name", LUA_TTABLE, message);
	a.name = lua_gettop(L);
	tp_push_key(L, idx, "column", LUA_TTABLE, message);
	a.column = lua_gettop(L);
	tp_push_key(L, idx, "column_name", LUA_TTABLE, message);
	a.column_name = lua_gettop(L);
	tp_push_key(L, idx, "kind", LUA_TTABLE, message);
	a.kind = lua_gettop(L);
	tp_push_key(L, idx, "packed", LUA_TTABLE, message);
	a.packed = lua_gettop(L);
	tp_push_key(L, idx, "repr", LUA_TTABLE, message);
	a.repr = lua_gettop(L);
	tp_push_key(L, idx, "conv", LUA_TTABLE, message);
	a.conv = lua_gettop(L);
	tp_push_key(L, idx, "optional", LUA_TTABLE, message);
	a.optional = lua_gettop(L);
	tp_push_key(L, idx, "key_kind", LUA_TTABLE, message);
	a.key_kind = lua_gettop(L);
	tp_push_key(L, idx, "value_kind", LUA_TTABLE, message);
	a.value_kind = lua_gettop(L);
	tp_push_key(L, idx, "sub", LUA_TTABLE, message);
	a.sub = lua_gettop(L);
	tp_push_key(L, idx, "oneof", LUA_TTABLE, message);
	a.oneof = lua_gettop(L);

	tp_push_key(L, idx, "oneof_names", LUA_TTABLE, message);
	int names = lua_gettop(L);
	int n_oneofs = (int)lua_objlen(L, names);
	node->oneof_names = (char **)tp_calloc(L, (size_t)n_oneofs,
	                                       sizeof(char *));
	node->n_oneofs = n_oneofs;
	for (int j = 1; j <= n_oneofs; j++) {
		const char *s = tp_arr_str(L, names, j, "oneof_names", message,
		                           &len);
		node->oneof_names[j - 1] = tp_strdup(L, s, len);
	}

	node->fields = (tp_field *)tp_calloc(L, (size_t)n, sizeof(tp_field));
	node->n = n;
	uint32_t width = 0;
	uint32_t prev_no = 0;
	for (int i = 1; i <= n; i++) {
		tp_field *f = &node->fields[i - 1];
		const char *s;

		/* Owned strings first, so the gc frees them on any error. */
		s = tp_arr_str(L, a.name, i, "name", message, &len);
		f->name = tp_strdup(L, s, len);
		f->name_len = (uint32_t)len;
		s = tp_arr_str(L, a.column_name, i, "column_name", message, &len);
		f->column_name = tp_strdup(L, s, len);

		f->field_no = (uint32_t)tp_arr_int(L, a.field_no, i, "field_no",
		                                   message, 1, TP_MAX_FIELD_NO);
		if (f->field_no <= prev_no)
			tp_malformed(L, message, "field numbers do not ascend");
		prev_no = f->field_no;
		if (layout == TP_LAYOUT_MAP) {
			f->column = (uint32_t)tp_arr_int(L, a.column, i, "column",
			                                 message, 0, 0);
		} else {
			f->column = (uint32_t)tp_arr_int(L, a.column, i, "column",
			                                 message, 1, TP_MAX_FIELD_NO);
		}
		if (f->column > width)
			width = f->column;

		f->kind = tp_arr_kind(L, a.kind, i, "kind", message, 0);
		f->repr = (uint8_t)tp_arr_enum(L, a.repr, i, "repr", message,
		                               tp_repr_names);
		int conv = tp_arr_enum(L, a.conv, i, "conv", message,
		                       tp_conv_names);
		f->uuid = conv == 5 ? TP_UUID_TEXT :
		          conv == 6 ? TP_UUID_BIN : TP_UUID_NONE;
		f->optional = (uint8_t)tp_arr_bool(L, a.optional, i, "optional",
		                                   message);
		int packed = tp_arr_bool(L, a.packed, i, "packed", message);
		f->key_kind = tp_arr_kind(L, a.key_kind, i, "key_kind", message,
		                          1);
		f->value_kind = tp_arr_kind(L, a.value_kind, i, "value_kind",
		                            message, 1);

		lua_rawgeti(L, a.sub, i);
		if (lua_type(L, -1) == LUA_TTABLE) {
			lua_rawget(L, memo);
			if (lua_type(L, -1) != LUA_TNUMBER)
				tp_malformed(L, message, "sub node not numbered");
			f->sub = (int)lua_tointeger(L, -1) - 1;
		} else if (lua_type(L, -1) == LUA_TBOOLEAN &&
		           !lua_toboolean(L, -1)) {
			f->sub = -1;
		} else {
			tp_malformed(L, message, "sub is neither a node nor false");
		}
		lua_pop(L, 1);

		f->oneof = (int)tp_arr_int(L, a.oneof, i, "oneof", message, 0,
		                           n_oneofs);
		f->oneof_prev = -1;
		if (f->oneof != 0) {
			for (int j = i - 2; j >= 0; j--) {
				if (node->fields[j].oneof == f->oneof) {
					f->oneof_prev = j;
					break;
				}
			}
		}

		/* Shape checks: which kinds each representation carries, and
		 * which of them have a child node. The child's layout is
		 * checked once every node is compiled. */
		uint8_t kind = f->kind;
		int ok;
		switch (f->repr) {
		case TP_REPR_SCALAR:
			ok = (tp_is_scalar_kind(kind) ||
			      kind == TP_KIND_TIMESTAMP) && f->sub < 0;
			break;
		case TP_REPR_MSG_MAP:
		case TP_REPR_MSG_ARRAY:
			ok = kind == PB_KIND_MESSAGE && f->sub >= 0;
			break;
		case TP_REPR_RAW:
			ok = (kind == PB_KIND_MESSAGE ||
			      kind == TP_KIND_TIMESTAMP) && f->sub < 0;
			break;
		case TP_REPR_LIST:
			ok = (tp_is_scalar_kind(kind) ||
			      kind == TP_KIND_TIMESTAMP ||
			      kind == PB_KIND_MESSAGE) &&
			     (f->sub >= 0) == (kind == PB_KIND_MESSAGE);
			break;
		default: /* TP_REPR_DICT */
			ok = kind == PB_KIND_MAP &&
			     tp_is_scalar_kind(f->key_kind) &&
			     (tp_is_scalar_kind(f->value_kind) ||
			      f->value_kind == TP_KIND_TIMESTAMP ||
			      f->value_kind == PB_KIND_MESSAGE) &&
			     (f->sub >= 0) == (f->value_kind == PB_KIND_MESSAGE);
			break;
		}
		if (f->uuid != TP_UUID_NONE &&
		    (f->repr != TP_REPR_SCALAR ||
		     (kind != PB_KIND_STRING && kind != PB_KIND_BYTES)))
			ok = 0;
		if (f->repr != TP_REPR_DICT &&
		    (f->key_kind != 0 || f->value_kind != 0))
			ok = 0;
		if (!ok) {
			lua_pushfstring(L, "field '%s' has kind '%s' and a "
			                "representation that do not fit",
			                f->name, tp_kind_name(kind));
			tp_malformed(L, message, lua_tostring(L, -1));
		}

		/* Tags, as aux_of in tuple.lua computes them. */
		int packable = kind != PB_KIND_STRING && kind != PB_KIND_BYTES &&
		               tp_is_scalar_kind(kind);
		f->packed = (uint8_t)(f->repr == TP_REPR_LIST && packed &&
		                      packable);
		uint8_t wt = PB_WIRE_LEN;
		if (!f->packed && (f->repr == TP_REPR_SCALAR ||
		                   f->repr == TP_REPR_LIST))
			wt = tp_value_wire(kind);
		encode_tag(f->field_no, wt, f->tag, &f->tag_len);
		if (f->repr == TP_REPR_DICT) {
			encode_tag(1, tp_value_wire(f->key_kind), f->key_tag,
			           &f->key_tag_len);
			encode_tag(2, tp_value_wire(f->value_kind), f->val_tag,
			           &f->val_tag_len);
		}
	}

	if (layout == TP_LAYOUT_MAP) {
		/* Field indices sorted by (length, bytes) of the name. */
		node->by_name = (int *)tp_calloc(L, (size_t)n, sizeof(int));
		for (int i = 0; i < n; i++) {
			const tp_field *f = &node->fields[i];
			int j = i;
			while (j > 0) {
				const tp_field *g = &node->fields[node->by_name[j - 1]];
				int c = tp_name_cmp(g->name, g->name_len, f->name,
				                    f->name_len);
				if (c == 0)
					tp_malformed(L, message, "duplicate field name");
				if (c < 0)
					break;
				node->by_name[j] = node->by_name[j - 1];
				j--;
			}
			node->by_name[j] = i;
		}
	} else {
		node->width = width;
		node->at = (int *)tp_calloc(L, (size_t)width + 1, sizeof(int));
		for (uint32_t c = 0; c <= width; c++)
			node->at[c] = -1;
		for (int i = 0; i < n; i++) {
			uint32_t c = node->fields[i].column;
			if (node->at[c] >= 0)
				tp_malformed(L, message, "two fields share a column");
			node->at[c] = i;
		}
	}
	lua_settop(L, top);
}

int
pb_tuple_compile(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checkstack(L, 40, "pb.tuple: compiling a plan");
	lua_settop(L, 1);

	tp_plan *tp = (tp_plan *)lua_newuserdata(L, sizeof(tp_plan));
	memset(tp, 0, sizeof(*tp));
	luaL_getmetatable(L, TUPLE_PLAN_MT);
	lua_setmetatable(L, -2);                     /* 2: tplan */

	lua_newtable(L);                             /* 3: node -> index */
	int memo = lua_gettop(L);
	lua_newtable(L);                             /* 4: index -> node */
	int order = lua_gettop(L);

	/* Number the nodes breadth-first. Map-layout nodes are shared, so
	 * the graph may be cyclic: the memo is what ends the walk. */
	lua_pushvalue(L, 1);
	lua_pushinteger(L, 1);
	lua_rawset(L, memo);
	lua_pushvalue(L, 1);
	lua_rawseti(L, order, 1);
	int count = 1;
	for (int k = 1; k <= count; k++) {
		lua_rawgeti(L, order, k);
		int node = lua_gettop(L);
		lua_pushliteral(L, "message");
		lua_rawget(L, node);
		const char *message = lua_tostring(L, -1);
		tp_push_key(L, node, "n", LUA_TNUMBER, message);
		lua_Number dn = lua_tonumber(L, -1);
		if (!(dn >= 0) || !(dn <= 1000000) || dn != (lua_Number)(int)dn)
			tp_malformed(L, message, "'n' is not a field count");
		int n = (int)dn;
		tp_push_key(L, node, "sub", LUA_TTABLE, message);
		int sub = lua_gettop(L);
		for (int j = 1; j <= n; j++) {
			lua_rawgeti(L, sub, j);
			if (lua_type(L, -1) == LUA_TTABLE) {
				lua_pushvalue(L, -1);
				lua_rawget(L, memo);
				int seen = !lua_isnil(L, -1);
				lua_pop(L, 1);
				if (!seen) {
					if (count >= 1000000)
						tp_malformed(L, message, "too many nodes");
					count++;
					lua_pushvalue(L, -1);
					lua_pushinteger(L, count);
					lua_rawset(L, memo);
					lua_pushvalue(L, -1);
					lua_rawseti(L, order, count);
				}
			}
			lua_pop(L, 1);
		}
		lua_settop(L, node - 1);
	}

	tp->nodes = (tp_node *)tp_calloc(L, (size_t)count, sizeof(tp_node));
	tp->n_nodes = count;
	for (int k = 1; k <= count; k++) {
		lua_rawgeti(L, order, k);
		tp_compile_node(L, &tp->nodes[k - 1], lua_gettop(L), memo, k == 1);
		lua_pop(L, 1);
	}

	/* A message's child layout follows its representation; the
	 * elements of lists and maps are always map-laid-out. */
	for (int k = 0; k < count; k++) {
		const tp_node *node = &tp->nodes[k];
		for (int i = 0; i < node->n; i++) {
			const tp_field *f = &node->fields[i];
			if (f->sub < 0)
				continue;
			uint8_t want = f->repr == TP_REPR_MSG_ARRAY ?
			               TP_LAYOUT_ARRAY : TP_LAYOUT_MAP;
			if (tp->nodes[f->sub].layout != want)
				tp_malformed(L, node->message,
				             "a child node has the wrong layout");
		}
	}

	lua_settop(L, 2);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  msgpack heads.                                                   *
 *                                                                  *
 *  Classes and their names follow mp_head / class_name in           *
 *  tuple.lua, byte for byte.                                        *
 * ---------------------------------------------------------------- */

enum {
	TP_MP_NIL = 1,
	TP_MP_BOOL,
	TP_MP_UINT,
	TP_MP_INT,
	TP_MP_FLOAT,
	TP_MP_STR,
	TP_MP_BIN,
	TP_MP_ARRAY,
	TP_MP_MAP,
	TP_MP_EXT,
};

static const char *const tp_class_names[] = {
	NULL, "nil", "boolean", "unsigned integer", "integer", "float",
	"string", "binary", "array", "map",
};

#define TP_EXT_UUID     2
#define TP_EXT_DATETIME 4

typedef struct tp_head {
	int         cls;
	uint32_t    n;     /* str/bin/ext: payload length; array/map: count */
	const char *body;  /* str/bin/ext: payload; array/map: first item */
	int         ext;   /* ext: its type */
} tp_head;

static inline uint32_t
tp_be16(const char *p)
{
	const uint8_t *u = (const uint8_t *)p;
	return (uint32_t)u[0] << 8 | u[1];
}

static inline uint32_t
tp_be32(const char *p)
{
	const uint8_t *u = (const uint8_t *)p;
	return (uint32_t)u[0] << 24 | (uint32_t)u[1] << 16 |
	       (uint32_t)u[2] << 8 | u[3];
}

static void
tp_head_of(lua_State *L, const char *p, tp_head *h)
{
	uint8_t c = (uint8_t)*p;
	h->n = 0;
	h->body = p;
	h->ext = 0;
	if (c <= 0x7f) {
		h->cls = TP_MP_UINT;
	} else if (c <= 0x8f) {
		h->cls = TP_MP_MAP;
		h->n = c - 0x80;
		h->body = p + 1;
	} else if (c <= 0x9f) {
		h->cls = TP_MP_ARRAY;
		h->n = c - 0x90;
		h->body = p + 1;
	} else if (c <= 0xbf) {
		h->cls = TP_MP_STR;
		h->n = c - 0xa0;
		h->body = p + 1;
	} else if (c >= 0xe0) {
		h->cls = TP_MP_INT;
	} else {
		switch (c) {
		case 0xc0:
			h->cls = TP_MP_NIL;
			break;
		case 0xc2: case 0xc3:
			h->cls = TP_MP_BOOL;
			break;
		case 0xc4:
			h->cls = TP_MP_BIN;
			h->n = (uint8_t)p[1];
			h->body = p + 2;
			break;
		case 0xc5:
			h->cls = TP_MP_BIN;
			h->n = tp_be16(p + 1);
			h->body = p + 3;
			break;
		case 0xc6:
			h->cls = TP_MP_BIN;
			h->n = tp_be32(p + 1);
			h->body = p + 5;
			break;
		case 0xc7:
			h->cls = TP_MP_EXT;
			h->n = (uint8_t)p[1];
			h->ext = (int8_t)p[2];
			h->body = p + 3;
			break;
		case 0xc8:
			h->cls = TP_MP_EXT;
			h->n = tp_be16(p + 1);
			h->ext = (int8_t)p[3];
			h->body = p + 4;
			break;
		case 0xc9:
			h->cls = TP_MP_EXT;
			h->n = tp_be32(p + 1);
			h->ext = (int8_t)p[5];
			h->body = p + 6;
			break;
		case 0xca: case 0xcb:
			h->cls = TP_MP_FLOAT;
			break;
		case 0xcc: case 0xcd: case 0xce: case 0xcf:
			h->cls = TP_MP_UINT;
			break;
		case 0xd0: case 0xd1: case 0xd2: case 0xd3:
			h->cls = TP_MP_INT;
			break;
		case 0xd4: case 0xd5: case 0xd6: case 0xd7: case 0xd8:
			h->cls = TP_MP_EXT;
			h->n = 1u << (c - 0xd4);
			h->ext = (int8_t)p[1];
			h->body = p + 2;
			break;
		case 0xd9:
			h->cls = TP_MP_STR;
			h->n = (uint8_t)p[1];
			h->body = p + 2;
			break;
		case 0xda:
			h->cls = TP_MP_STR;
			h->n = tp_be16(p + 1);
			h->body = p + 3;
			break;
		case 0xdb:
			h->cls = TP_MP_STR;
			h->n = tp_be32(p + 1);
			h->body = p + 5;
			break;
		case 0xdc:
			h->cls = TP_MP_ARRAY;
			h->n = tp_be16(p + 1);
			h->body = p + 3;
			break;
		case 0xdd:
			h->cls = TP_MP_ARRAY;
			h->n = tp_be32(p + 1);
			h->body = p + 5;
			break;
		case 0xde:
			h->cls = TP_MP_MAP;
			h->n = tp_be16(p + 1);
			h->body = p + 3;
			break;
		case 0xdf:
			h->cls = TP_MP_MAP;
			h->n = tp_be32(p + 1);
			h->body = p + 5;
			break;
		default: {
			/* 0xc1, never used by msgpack: a tuple cannot hold it. */
			char msg[64];
			snprintf(msg, sizeof(msg),
			         "pb.tuple: invalid msgpack byte 0x%02x", c);
			lua_pushstring(L, msg);
			lua_error(L);
		}
		}
	}
}

static inline int
tp_is_nil(const char *p)
{
	return (uint8_t)*p == 0xc0;
}

/* ---------------------------------------------------------------- *
 *  Errors.                                                          *
 *                                                                  *
 *  Worded as value_error in tuple.lua. Building a message allocates *
 *  Lua strings, which is fine: the call is about to raise.         *
 * ---------------------------------------------------------------- */

/* Replace the value on top of the stack by tostring(value). */
static void
tp_tostring(lua_State *L)
{
	lua_getfield(L, LUA_GLOBALSINDEX, "tostring");
	lua_insert(L, -2);
	lua_call(L, 1, 1);
}

/* type(v) of argument `idx`, "nil" for an absent one. */
static const char *
tp_typename(lua_State *L, int idx)
{
	if (lua_isnone(L, idx))
		return "nil";
	return luaL_typename(L, idx);
}

/* Push "pb.tuple: field 'x' of M (column 'c')[: element k]: ". */
static void
tp_push_where(lua_State *L, const tp_node *node, int i, int elem)
{
	const tp_field *f = &node->fields[i];
	if (f->column_name[0] != '\0')
		lua_pushfstring(L, "pb.tuple: field '%s' of %s (column '%s')",
		                f->name, node->message, f->column_name);
	else
		lua_pushfstring(L, "pb.tuple: field '%s' of %s", f->name,
		                node->message);
	if (elem > 0)
		lua_pushfstring(L, ": element %d: ", elem);
	else if (elem == TP_ELEM_KEY)
		lua_pushliteral(L, ": map key: ");
	else if (elem == TP_ELEM_VALUE)
		lua_pushliteral(L, ": map value: ");
	else
		lua_pushliteral(L, ": ");
	lua_concat(L, 2);
}

static int
tp_raise(lua_State *L, int n)
{
	lua_concat(L, n);
	return lua_error(L);
}

static void
tp_push_class(lua_State *L, const tp_head *h)
{
	if (h->cls != TP_MP_EXT) {
		lua_pushstring(L, tp_class_names[h->cls]);
		return;
	}
	switch (h->ext) {
	case 1: lua_pushliteral(L, "decimal"); break;
	case 2: lua_pushliteral(L, "uuid"); break;
	case 3: lua_pushliteral(L, "error"); break;
	case 4: lua_pushliteral(L, "datetime"); break;
	case 6: lua_pushliteral(L, "interval"); break;
	default: lua_pushfstring(L, "extension type %d", h->ext); break;
	}
}

static int
tp_type_error(lua_State *L, const tp_node *node, int i, int elem,
              const char *what, const tp_head *h)
{
	tp_push_where(L, node, i, elem);
	lua_pushfstring(L, "expected %s, got ", what);
	tp_push_class(L, h);
	return tp_raise(L, 3);
}

/* `value <v> is out of range for <kind>`; the value on top of the
 * stack is spelled by tostring, as the Lua path spells it. */
static int
tp_range_error(lua_State *L, const tp_node *node, int i, int elem,
               uint8_t kind)
{
	tp_tostring(L);
	int v = lua_gettop(L);
	tp_push_where(L, node, i, elem);
	lua_pushliteral(L, "value ");
	lua_pushvalue(L, v);
	lua_pushfstring(L, " is out of range for %s", tp_kind_name(kind));
	return tp_raise(L, 4);
}

/* ---------------------------------------------------------------- *
 *  Encode context and output.                                       *
 * ---------------------------------------------------------------- */

typedef struct tp_ctx {
	lua_State *L;
	tp_plan   *plan;
	enc_buf   *b;
	size_t     top;          /* slots in use */
} tp_ctx;

/* Claim `n` cleared slots; returns the index of the first. The slot
 * array may move, so callers index it through ctx->plan every time. */
static size_t
tp_slots_push(tp_ctx *ctx, int n)
{
	tp_plan *tp = ctx->plan;
	size_t base = ctx->top;
	size_t need = base + (size_t)n;
	if (need > tp->slots_cap) {
		size_t cap = tp->slots_cap * 2;
		if (cap < 64)
			cap = 64;
		while (cap < need)
			cap *= 2;
		const char **slots = (const char **)realloc(
			(void *)tp->slots, cap * sizeof(const char *));
		if (slots == NULL)
			luaL_error(ctx->L, "pb.tuple: out of memory");
		tp->slots = slots;
		tp->slots_cap = cap;
	}
	if (n > 0)
		memset((void *)&tp->slots[base], 0, (size_t)n * sizeof(char *));
	ctx->top = need;
	return base;
}

#define TP_SLOT(ctx, k) ((ctx)->plan->slots[(k)])

static inline void
tp_put(tp_ctx *ctx, const void *src, size_t n)
{
	ebuf_reserve(ctx->L, ctx->b, n);
	ebuf_put_bytes(ctx->b, (const uint8_t *)src, n);
}

static inline void
tp_put_varint(tp_ctx *ctx, uint64_t v)
{
	ebuf_reserve(ctx->L, ctx->b, 10);
	ebuf_put_varint(ctx->b, v);
}

/* Start a length-delimited body: a one-byte length placeholder. */
static size_t
tp_len_begin(tp_ctx *ctx)
{
	ebuf_reserve(ctx->L, ctx->b, 1);
	size_t mark = ctx->b->used;
	ctx->b->used++;
	return mark;
}

/* Finish the body started at `mark`: write its length, moving the body
 * up when the length needs more than one byte. */
static void
tp_len_end(tp_ctx *ctx, size_t mark)
{
	enc_buf *b = ctx->b;
	uint64_t len = b->used - mark - 1;
	if (len < 0x80) {
		ebuf_base(b)[mark] = (uint8_t)len;
		return;
	}
	size_t k = 1;
	for (uint64_t v = len; v >= 0x80; v >>= 7)
		k++;
	ebuf_reserve(ctx->L, b, k - 1);
	uint8_t *base = ebuf_base(b);
	memmove(base + mark + k, base + mark + 1, (size_t)len);
	uint8_t *p = base + mark;
	uint64_t v = len;
	while (v >= 0x80) {
		*p++ = (uint8_t)(v | 0x80);
		v >>= 7;
	}
	*p = (uint8_t)v;
	b->used += k - 1;
}

/* ---------------------------------------------------------------- *
 *  Scalars (read_scalar / is_default / scalar_bytes in tuple.lua).  *
 * ---------------------------------------------------------------- */

typedef struct tp_scalar {
	uint64_t    u;       /* integer kinds (two's complement), bool */
	double      d;       /* float, double */
	const char *s;       /* string, bytes: the payload */
	uint32_t    len;
	uint8_t     uuid;    /* TP_UUID_*: s is a uuid's 16 bytes */
} tp_scalar;

/* LuaJIT canonicalizes every NaN a C function pushes; the Lua path
 * encodes the canonical one, whatever payload the msgpack carried. */
static inline double
tp_canon(double d)
{
	if (d != d) {
		union { uint64_t u; double d; } nan;
		nan.u = 0xfff8000000000000ULL;
		return nan.d;
	}
	return d;
}

static void
tp_read_scalar(tp_ctx *ctx, const tp_node *node, int i, int elem,
               uint8_t kind, uint8_t uuid, const char **pp, tp_scalar *v)
{
	lua_State *L = ctx->L;
	const char *p = *pp;
	tp_head h;
	tp_head_of(L, p, &h);
	v->uuid = TP_UUID_NONE;

	int range = tp_range_of(kind);
	if (range != TP_RANGE_NONE) {
		if (h.cls == TP_MP_UINT) {
			uint64_t u = mp_decode_uint(&p);
			int fits = range == TP_RANGE_S32 ? u <= INT32_MAX :
			           range == TP_RANGE_U32 ? u <= UINT32_MAX :
			           range == TP_RANGE_S64 ? u <= INT64_MAX : 1;
			if (!fits) {
				luaL_pushuint64(L, u);
				tp_range_error(L, node, i, elem, kind);
			}
			v->u = u;
		} else if (h.cls == TP_MP_INT) {
			int64_t x = mp_decode_int(&p);
			int fits = range == TP_RANGE_S32 ?
			           x >= INT32_MIN && x <= INT32_MAX :
			           range == TP_RANGE_U32 ?
			           x >= 0 && x <= (int64_t)UINT32_MAX :
			           range == TP_RANGE_S64 ? 1 : x >= 0;
			if (!fits) {
				luaL_pushint64(L, x);
				tp_range_error(L, node, i, elem, kind);
			}
			v->u = (uint64_t)x;
		} else {
			tp_type_error(L, node, i, elem, "an integer", &h);
		}
		*pp = p;
		return;
	}

	switch (kind) {
	case PB_KIND_FLOAT:
	case PB_KIND_DOUBLE:
		if (h.cls == TP_MP_FLOAT) {
			if ((uint8_t)*p == 0xca)
				v->d = (double)mp_decode_float(&p);
			else
				v->d = mp_decode_double(&p);
		} else if (h.cls == TP_MP_UINT) {
			v->d = (double)mp_decode_uint(&p);
		} else if (h.cls == TP_MP_INT) {
			v->d = (double)mp_decode_int(&p);
		} else {
			tp_type_error(L, node, i, elem, "a number", &h);
		}
		v->d = tp_canon(v->d);
		break;
	case PB_KIND_BOOL:
		if (h.cls != TP_MP_BOOL)
			tp_type_error(L, node, i, elem, "a boolean", &h);
		v->u = (uint8_t)*p == 0xc3;
		p++;
		break;
	case PB_KIND_STRING:
	case PB_KIND_BYTES:
		if (uuid != TP_UUID_NONE) {
			if (h.cls != TP_MP_EXT || h.ext != TP_EXT_UUID || h.n != 16)
				tp_type_error(L, node, i, elem, "a uuid", &h);
			v->uuid = uuid;
		} else if (h.cls != TP_MP_STR && h.cls != TP_MP_BIN) {
			tp_type_error(L, node, i, elem,
			              kind == PB_KIND_STRING ? "a string" :
			              "binary data", &h);
		}
		v->s = h.body;
		v->len = h.n;
		p = h.body + h.n;
		break;
	default:
		/* The compiler admits only scalar kinds here. */
		luaL_error(L, "pb.tuple: no scalar conversion for kind %s",
		           tp_kind_name(kind));
	}
	*pp = p;
}

/* proto3 default test. -0.0 is not the default: it encodes differently. */
static inline int
tp_is_default(uint8_t kind, const tp_scalar *v)
{
	switch (kind) {
	case PB_KIND_STRING:
	case PB_KIND_BYTES:
		return v->uuid == TP_UUID_NONE && v->len == 0;
	case PB_KIND_FLOAT:
	case PB_KIND_DOUBLE:
		return f64_to_u64(v->d) == 0;
	default:
		return v->u == 0;
	}
}

static void
tp_put_scalar(tp_ctx *ctx, uint8_t kind, const tp_scalar *v)
{
	enc_buf *b = ctx->b;
	switch (kind) {
	case PB_KIND_SINT32:
		tp_put_varint(ctx, zigzag32((int32_t)(int64_t)v->u));
		return;
	case PB_KIND_SINT64:
		tp_put_varint(ctx, zigzag64((int64_t)v->u));
		return;
	case PB_KIND_FIXED32:
	case PB_KIND_SFIXED32:
		ebuf_reserve(ctx->L, b, 4);
		ebuf_put_fixed32(b, (uint32_t)v->u);
		return;
	case PB_KIND_FIXED64:
	case PB_KIND_SFIXED64:
		ebuf_reserve(ctx->L, b, 8);
		ebuf_put_fixed64(b, v->u);
		return;
	case PB_KIND_FLOAT:
		ebuf_reserve(ctx->L, b, 4);
		ebuf_put_fixed32(b, f32_to_u32((float)v->d));
		return;
	case PB_KIND_DOUBLE:
		ebuf_reserve(ctx->L, b, 8);
		ebuf_put_fixed64(b, f64_to_u64(v->d));
		return;
	case PB_KIND_STRING:
	case PB_KIND_BYTES:
		if (v->uuid == TP_UUID_TEXT) {
			/* Canonical text: the 16 bytes in order, lowercase hex,
			 * dashes after bytes 4, 6, 8 and 10. */
			static const char hex[] = "0123456789abcdef";
			char text[36];
			int k = 0;
			for (int j = 0; j < 16; j++) {
				if (j == 4 || j == 6 || j == 8 || j == 10)
					text[k++] = '-';
				uint8_t c = (uint8_t)v->s[j];
				text[k++] = hex[c >> 4];
				text[k++] = hex[c & 0x0f];
			}
			tp_put_varint(ctx, 36);
			tp_put(ctx, text, 36);
			return;
		}
		tp_put_varint(ctx, v->len);
		tp_put(ctx, v->s, v->len);
		return;
	default:
		/* int32 / int64 / uint32 / uint64 / enum / bool: negatives are
		 * sign-extended to ten bytes. */
		tp_put_varint(ctx, v->u);
		return;
	}
}

/* Tag, length and Timestamp body of the datetime at *pp. */
static void
tp_emit_timestamp(tp_ctx *ctx, const tp_node *node, int i, int elem,
                  const uint8_t *tag, uint8_t tag_len, const char **pp)
{
	lua_State *L = ctx->L;
	tp_head h;
	tp_head_of(L, *pp, &h);
	if (h.cls != TP_MP_EXT || h.ext != TP_EXT_DATETIME)
		tp_type_error(L, node, i, elem, "a datetime", &h);
	if (h.n != 8 && h.n != 16) {
		/* box validates datetimes, so a tuple never holds this. */
		tp_push_where(L, node, i, elem);
		lua_pushliteral(L, "invalid datetime");
		tp_raise(L, 2);
	}
	/* Little-endian int64 seconds, then int32 nanoseconds (and the
	 * zone, which does not move the instant). */
	const uint8_t *u = (const uint8_t *)h.body;
	uint64_t secs = 0;
	for (int k = 7; k >= 0; k--)
		secs = secs << 8 | u[k];
	uint32_t nsec = 0;
	if (h.n == 16)
		nsec = (uint32_t)u[8] | (uint32_t)u[9] << 8 |
		       (uint32_t)u[10] << 16 | (uint32_t)u[11] << 24;

	ebuf_reserve(L, ctx->b, (size_t)tag_len + 1 + 22);
	ebuf_put_bytes(ctx->b, tag, tag_len);
	size_t mark = ctx->b->used;
	ctx->b->used++;
	if (secs != 0) {
		ebuf_put_byte(ctx->b, 0x08);
		ebuf_put_varint(ctx->b, secs);
	}
	if (nsec != 0) {
		ebuf_put_byte(ctx->b, 0x10);
		ebuf_put_varint(ctx->b, (uint64_t)(int64_t)(int32_t)nsec);
	}
	ebuf_base(ctx->b)[mark] = (uint8_t)(ctx->b->used - mark - 1);
	*pp = h.body + h.n;
}

/* ---------------------------------------------------------------- *
 *  Messages and fields.                                             *
 * ---------------------------------------------------------------- */

static void
tp_encode_message(tp_ctx *ctx, int node_idx, const char **pp, int depth,
                  const tp_node *parent, int pi, int elem);

static void
tp_emit_list(tp_ctx *ctx, const tp_node *node, int i, const char *p,
             int depth)
{
	lua_State *L = ctx->L;
	const tp_field *f = &node->fields[i];
	tp_head h;
	tp_head_of(L, p, &h);
	if (h.cls != TP_MP_ARRAY)
		tp_type_error(L, node, i, TP_ELEM_NONE, "an array", &h);
	if (h.n == 0)
		return;
	const char *q = h.body;
	int count = (int)h.n;
	tp_scalar v;
	if (f->kind == PB_KIND_MESSAGE) {
		for (int k = 1; k <= count; k++) {
			tp_put(ctx, f->tag, f->tag_len);
			size_t mark = tp_len_begin(ctx);
			tp_encode_message(ctx, f->sub, &q, depth + 1, node, i, k);
			tp_len_end(ctx, mark);
		}
	} else if (f->kind == TP_KIND_TIMESTAMP) {
		for (int k = 1; k <= count; k++)
			tp_emit_timestamp(ctx, node, i, k, f->tag, f->tag_len, &q);
	} else if (f->packed) {
		tp_put(ctx, f->tag, f->tag_len);
		size_t mark = tp_len_begin(ctx);
		for (int k = 1; k <= count; k++) {
			tp_read_scalar(ctx, node, i, k, f->kind, TP_UUID_NONE, &q,
			               &v);
			tp_put_scalar(ctx, f->kind, &v);
		}
		tp_len_end(ctx, mark);
	} else {
		for (int k = 1; k <= count; k++) {
			tp_read_scalar(ctx, node, i, k, f->kind, TP_UUID_NONE, &q,
			               &v);
			tp_put(ctx, f->tag, f->tag_len);
			tp_put_scalar(ctx, f->kind, &v);
		}
	}
}

/* Entries go out in the order of the keys in the msgpack map; a key or
 * scalar value equal to its default is left out of the entry. */
static void
tp_emit_dict(tp_ctx *ctx, const tp_node *node, int i, const char *p,
             int depth)
{
	lua_State *L = ctx->L;
	const tp_field *f = &node->fields[i];
	tp_head h;
	tp_head_of(L, p, &h);
	if (h.cls != TP_MP_MAP)
		tp_type_error(L, node, i, TP_ELEM_NONE, "a map", &h);
	const char *q = h.body;
	tp_scalar v;
	for (uint32_t k = 0; k < h.n; k++) {
		tp_put(ctx, f->tag, f->tag_len);
		size_t mark = tp_len_begin(ctx);
		tp_read_scalar(ctx, node, i, TP_ELEM_KEY, f->key_kind,
		               TP_UUID_NONE, &q, &v);
		if (!tp_is_default(f->key_kind, &v)) {
			tp_put(ctx, f->key_tag, f->key_tag_len);
			tp_put_scalar(ctx, f->key_kind, &v);
		}
		if (f->value_kind == PB_KIND_MESSAGE) {
			tp_put(ctx, f->val_tag, f->val_tag_len);
			size_t vmark = tp_len_begin(ctx);
			tp_encode_message(ctx, f->sub, &q, depth + 1, node, i,
			                  TP_ELEM_VALUE);
			tp_len_end(ctx, vmark);
		} else if (f->value_kind == TP_KIND_TIMESTAMP) {
			tp_emit_timestamp(ctx, node, i, TP_ELEM_VALUE, f->val_tag,
			                  f->val_tag_len, &q);
		} else {
			tp_read_scalar(ctx, node, i, TP_ELEM_VALUE, f->value_kind,
			               TP_UUID_NONE, &q, &v);
			if (!tp_is_default(f->value_kind, &v)) {
				tp_put(ctx, f->val_tag, f->val_tag_len);
				tp_put_scalar(ctx, f->value_kind, &v);
			}
		}
		tp_len_end(ctx, mark);
	}
}

/* Write field i, whose value at p is not NULL. */
static void
tp_emit_value(tp_ctx *ctx, const tp_node *node, int i, const char *p,
              int depth)
{
	lua_State *L = ctx->L;
	const tp_field *f = &node->fields[i];
	switch (f->repr) {
	case TP_REPR_SCALAR: {
		if (f->kind == TP_KIND_TIMESTAMP) {
			tp_emit_timestamp(ctx, node, i, TP_ELEM_NONE, f->tag,
			                  f->tag_len, &p);
			return;
		}
		tp_scalar v;
		tp_read_scalar(ctx, node, i, TP_ELEM_NONE, f->kind, f->uuid, &p,
		               &v);
		if (f->optional || !tp_is_default(f->kind, &v)) {
			tp_put(ctx, f->tag, f->tag_len);
			tp_put_scalar(ctx, f->kind, &v);
		}
		return;
	}
	case TP_REPR_MSG_MAP:
	case TP_REPR_MSG_ARRAY: {
		tp_put(ctx, f->tag, f->tag_len);
		size_t mark = tp_len_begin(ctx);
		tp_encode_message(ctx, f->sub, &p, depth + 1, node, i,
		                  TP_ELEM_NONE);
		tp_len_end(ctx, mark);
		return;
	}
	case TP_REPR_RAW: {
		tp_head h;
		tp_head_of(L, p, &h);
		if (h.cls != TP_MP_BIN)
			tp_type_error(L, node, i, TP_ELEM_NONE, "binary data", &h);
		tp_put(ctx, f->tag, f->tag_len);
		tp_put_varint(ctx, h.n);
		tp_put(ctx, h.body, h.n);
		return;
	}
	case TP_REPR_LIST:
		tp_emit_list(ctx, node, i, p, depth);
		return;
	default:
		tp_emit_dict(ctx, node, i, p, depth);
		return;
	}
}

/* Write the fields of `node` whose slots (from `base`) hold a non-NULL
 * value, in plan order: ascending field number. */
static void
tp_emit_fields(tp_ctx *ctx, const tp_node *node, size_t base, int depth)
{
	for (int i = 0; i < node->n; i++) {
		const char *p = TP_SLOT(ctx, base + (size_t)i);
		if (p == NULL || tp_is_nil(p))
			continue;
		const tp_field *f = &node->fields[i];
		/* The fields before i are checked already, so at most one
		 * earlier member of the group is set. */
		for (int j = f->oneof_prev; j >= 0;
		     j = node->fields[j].oneof_prev) {
			const char *pj = TP_SLOT(ctx, base + (size_t)j);
			if (pj != NULL && !tp_is_nil(pj)) {
				lua_pushfstring(ctx->L, "pb.tuple: oneof '%s' of %s has "
				                "more than one member set: '%s' and "
				                "'%s'", node->oneof_names[f->oneof - 1],
				                node->message, node->fields[j].name,
				                f->name);
				lua_error(ctx->L);
			}
		}
		tp_emit_value(ctx, node, i, p, depth);
	}
}

/* Field index of `key` in a map-layout node, or -1. */
static int
tp_lookup(const tp_node *node, const char *key, uint32_t len)
{
	int lo = 0, hi = node->n - 1;
	while (lo <= hi) {
		int mid = lo + (hi - lo) / 2;
		const tp_field *f = &node->fields[node->by_name[mid]];
		int c = tp_name_cmp(f->name, f->name_len, key, len);
		if (c == 0)
			return node->by_name[mid];
		if (c < 0)
			lo = mid + 1;
		else
			hi = mid - 1;
	}
	return -1;
}

/*
 * Body of the nested message at *pp (a map or an array per the node's
 * layout); advances *pp past it. `parent`, `pi`, `elem` locate the value
 * for error messages.
 */
static void
tp_encode_message(tp_ctx *ctx, int node_idx, const char **pp, int depth,
                  const tp_node *parent, int pi, int elem)
{
	lua_State *L = ctx->L;
	if (depth > PB_RECURSION_LIMIT) {
		lua_pushfstring(L, "pb.tuple: %s nests deeper than %d levels",
		                parent->message, PB_RECURSION_LIMIT);
		lua_error(L);
	}
	const tp_node *node = &ctx->plan->nodes[node_idx];
	tp_head h;
	tp_head_of(L, *pp, &h);
	const char *q = h.body;
	size_t base = tp_slots_push(ctx, node->n);

	/* Pass one: where each field's value starts. */
	if (node->layout == TP_LAYOUT_MAP) {
		if (h.cls != TP_MP_MAP)
			tp_type_error(L, parent, pi, elem, "a map", &h);
		for (uint32_t k = 0; k < h.n; k++) {
			tp_head kh;
			tp_head_of(L, q, &kh);
			if (kh.cls != TP_MP_STR) {
				tp_push_where(L, parent, pi, elem);
				lua_pushfstring(L, "a %s map has a key of type ",
				                node->message);
				tp_push_class(L, &kh);
				lua_pushliteral(L, ", field names are strings");
				tp_raise(L, 4);
			}
			int i = tp_lookup(node, kh.body, kh.n);
			if (i < 0 || TP_SLOT(ctx, base + (size_t)i) != NULL) {
				tp_push_where(L, parent, pi, elem);
				lua_pushfstring(L, i < 0 ? "unknown key '" : "key '");
				lua_pushlstring(L, kh.body, kh.n);
				if (i < 0)
					lua_pushfstring(L, "' in a %s map", node->message);
				else
					lua_pushfstring(L, "' appears twice in a %s map",
					                node->message);
				tp_raise(L, 4);
			}
			q = kh.body + kh.n;
			TP_SLOT(ctx, base + (size_t)i) = q;
			mp_next(&q);
		}
	} else {
		if (h.cls != TP_MP_ARRAY)
			tp_type_error(L, parent, pi, elem, "an array", &h);
		for (uint32_t pos = 1; pos <= h.n; pos++) {
			int i = pos <= node->width ? node->at[pos] : -1;
			if (i >= 0) {
				TP_SLOT(ctx, base + (size_t)i) = q;
			} else if (!tp_is_nil(q)) {
				tp_push_where(L, parent, pi, elem);
				lua_pushfstring(L, "position %d of a %s array has no "
				                "field", (int)pos, node->message);
				tp_raise(L, 2);
			}
			mp_next(&q);
		}
	}

	/* Pass two: emit in field-number order. */
	tp_emit_fields(ctx, node, base, depth);
	ctx->top = base;
	*pp = q;
}

/* The message a tuple holds, at the top level of the plan. */
static void
tp_encode_tuple(tp_ctx *ctx, box_tuple_t *tuple)
{
	const tp_node *node = &ctx->plan->nodes[0];
	const char *p = box_tuple_data(tuple, NULL);
	uint32_t count = mp_decode_array(&p);
	size_t base = tp_slots_push(ctx, node->n);
	uint32_t last = count < node->width ? count : node->width;
	for (uint32_t c = 1; c <= last; c++) {
		int i = node->at[c];
		if (i >= 0)
			TP_SLOT(ctx, base + (size_t)i) = p;
		mp_next(&p);
	}
	tp_emit_fields(ctx, node, base, 0);
	ctx->top = base;
}

int
pb_tuple_encode(lua_State *L)
{
	tp_plan *tp = (tp_plan *)luaL_checkudata(L, 1, TUPLE_PLAN_MT);
	/* The tuple stays at index 2 for the whole call, which keeps the
	 * pointer box_tuple_data returns valid. */
	box_tuple_t *tuple = luaT_istuple(L, 2);
	if (tuple == NULL)
		return luaL_error(L, "pb.tuple: expected a box.tuple, got %s",
		                  tp_typename(L, 2));
	lua_settop(L, 2);

	uint8_t storage[ENC_TOP_BUF];
	enc_buf b;
	ebuf_init(&b, storage, sizeof(storage), 0);
	tp_ctx ctx = {L, tp, &b, 0};
	tp_encode_tuple(&ctx, tuple);

	lua_pushlstring(L, (const char *)ebuf_base(&b), b.used);
	return 1;
}

int
pb_tuple_encode_repeated(lua_State *L)
{
	tp_plan *tp = (tp_plan *)luaL_checkudata(L, 1, TUPLE_PLAN_MT);
	lua_Number d = lua_tonumber(L, 2);
	if (lua_type(L, 2) != LUA_TNUMBER || !(d >= 1) ||
	    !(d <= TP_MAX_FIELD_NO) || d != (lua_Number)(int64_t)d) {
		lua_settop(L, 2);
		lua_pushfstring(L, "pb.tuple: field number must be an integer "
		                "in [1, %d], got ", TP_MAX_FIELD_NO);
		lua_pushvalue(L, 2);
		tp_tostring(L);
		return tp_raise(L, 2);
	}
	if (lua_type(L, 3) != LUA_TTABLE)
		return luaL_error(L, "pb.tuple: tuples must be an array of "
		                  "box.tuple, got %s", tp_typename(L, 3));
	lua_settop(L, 3);
	uint8_t tag[5], tag_len;
	encode_tag((uint32_t)d, PB_WIRE_LEN, tag, &tag_len);

	/* Index 4 holds the tuple being encoded. It sits below the buffer's
	 * growth userdata, which ebuf_grow keeps at the top. */
	lua_pushnil(L);
	int slot = lua_gettop(L);

	uint8_t storage[ENC_TOP_BUF];
	enc_buf b;
	ebuf_init(&b, storage, sizeof(storage), 0);
	tp_ctx ctx = {L, tp, &b, 0};
	size_t n = lua_objlen(L, 3);
	for (size_t k = 1; k <= n; k++) {
		lua_rawgeti(L, 3, (int)k);
		lua_replace(L, slot);
		box_tuple_t *tuple = luaT_istuple(L, slot);
		if (tuple == NULL)
			return luaL_error(L, "pb.tuple: expected a box.tuple, "
			                  "got %s", tp_typename(L, slot));
		tp_put(&ctx, tag, tag_len);
		size_t mark = tp_len_begin(&ctx);
		tp_encode_tuple(&ctx, tuple);
		tp_len_end(&ctx, mark);
	}

	lua_pushlstring(L, (const char *)ebuf_base(&b), b.used);
	return 1;
}

void
pb_tuple_open(lua_State *L)
{
	luaL_newmetatable(L, TUPLE_PLAN_MT);
	lua_pushcfunction(L, tuple_plan_gc);
	lua_setfield(L, -2, "__gc");
	lua_pushcfunction(L, tuple_plan_tostring);
	lua_setfield(L, -2, "__tostring");
	lua_pop(L, 1);
}
