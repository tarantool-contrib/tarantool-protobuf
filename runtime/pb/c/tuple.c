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
 * non-NULL ones. Nested levels stack their slots in one scratch array.
 *
 * The scratch array and re-entrancy
 * ---------------------------------
 * An encode can run Lua code before it returns: every allocation it makes
 * (the output buffer growing, the scratch growing, an error message) may
 * run a GC step, and a GC step runs finalizers, which may encode with the
 * same tplan. The error path also calls the global `tostring` on a value.
 * So the scratch cannot simply belong to the tplan: a nested call would
 * overwrite the slots of the call it interrupted.
 *
 * Instead the scratch is a Lua userdata that a call takes for itself. The
 * tplan caches one in its environment table (env[1]). A call takes it out
 * (env[1] = nil) and keeps it on its own Lua stack; a nested call finds
 * env[1] empty and makes a scratch of its own, as a Lua userdata on its
 * own stack. A call that returns normally puts its scratch back in
 * env[1]. A call that raises never does: its scratch dies with its stack
 * frame and is collected, and the next call makes a new one. There is no
 * flag to reset, so an error's longjmp cannot leave one stuck, and the
 * common path -- take the cached scratch, put it back -- allocates
 * nothing.
 *
 * Output goes to one enc_buf (c_plan.h): 4KB on the C stack, promoted to
 * Lua userdata on overflow, so an error mid-encode leaks nothing. A
 * length-delimited body is written in place after a one-byte length
 * placeholder, and moved up when its length needs more bytes. The only
 * Lua value allocated by an encode is the result string (plus the
 * buffer's growth userdata for a result past 4KB).
 */

#include <module.h>
#include <lauxlib.h>

#include <stdarg.h>
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
	uint8_t  ctype;          /* TP_CTYPE_*: the column type, for decode */
	int      dfield;         /* the field in the node's decoder message */
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
	int       n_members;     /* every member of the oneof groups */
	uint32_t *member_no;     /* ... by field number, ascending */
	int      *member_group;  /* ... and their 1-based group */
	int       n_unbound;     /* tuple layout: unbound non-nullable columns */
	int       has_raw;       /* a field is carried as raw wire bytes */
	int       dmsg;          /* decoder message (td_msg) of this level */
} tp_node;

/* Column types decode distinguishes. */
enum {
	TP_CTYPE_OTHER = 0,
	TP_CTYPE_VARBINARY,
	TP_CTYPE_STRING,
	TP_CTYPE_DOUBLE,
	TP_CTYPE_UNSIGNED,
};

/*
 * The decoder's view of a message descriptor: what the Lua codec reads
 * off it (see "Decode" below). Compiled from the descriptor graph, not
 * from the plan: decode checks every field on the wire, bound or not.
 */
#define TD_KIND_GROUP (PB_KIND_MAP + 2)

typedef struct td_field {
	uint32_t id;
	uint8_t  kind;           /* PB_KIND_* scalar/ENUM/MESSAGE/MAP or GROUP */
	uint8_t  repeated;
	uint8_t  key_kind;       /* map: key scalar kind */
	uint8_t  value_kind;     /* map: value scalar kind, ENUM or MESSAGE */
	int      msg;            /* message/group, map message value: td_msg */
	int      oneof;          /* oneof group in its message; -1 when none */
} td_field;

enum {
	TD_PLAIN = 0,            /* decoded field by field */
	TD_TIMESTAMP,            /* google.protobuf.Timestamp: decoded here */
	TD_CUSTOM,               /* another descriptor-level decode (Lua) */
};

typedef struct td_msg {
	char     *name;
	int       n;
	td_field *fields;        /* declaration order */
	int      *by_id;         /* field indices by ascending id */
	int       n_oneofs;
	int      *oo_start;      /* [g]..[g+1]: members of group g in oo_member */
	int      *oo_member;     /* field indices */
	int       n_ext;
	td_field *ext;           /* registered extensions, ascending id */
	uint8_t   message_set;
	uint8_t   custom;        /* TD_* */
	int       custom_fn;     /* TD_CUSTOM: index into env[2] */
} td_msg;

/* The slot scratch is not here: see "The scratch array and re-entrancy"
 * above. It lives in the tplan's environment table. */
typedef struct tp_plan {
	int          n_nodes;
	tp_node     *nodes;      /* nodes[0] is the tuple level */
	int          n_msgs;
	td_msg      *msgs;       /* msgs[0] is the bound message */
	uint8_t     *root_want;  /* msgs[0] fields decode keeps values of */
} tp_plan;

/* Slots in a freshly made scratch array. */
#define TP_SCRATCH_INITIAL 64

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
		free(node->member_no);
		free(node->member_group);
	}
	free(tp->nodes);
	for (int k = 0; k < tp->n_msgs; k++) {
		td_msg *m = &tp->msgs[k];
		free(m->name);
		free(m->fields);
		free(m->by_id);
		free(m->oo_start);
		free(m->oo_member);
		free(m->ext);
	}
	free(tp->msgs);
	free(tp->root_want);
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

/* Raise the formatted message as it stands, the way tuple.lua raises
 * with error(msg, 0). luaL_error would prefix it with the file and line
 * of its Lua caller, so the same error would read differently depending
 * on whether the C entry point was tail-called. */
static int
tp_error(lua_State *L, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	lua_pushvfstring(L, fmt, ap);
	va_end(ap);
	return lua_error(L);
}

static int
tp_malformed(lua_State *L, const char *message, const char *what)
{
	return tp_error(L, "pb.tuple: malformed plan of %s: %s",
	                message != NULL ? message : "?", what);
}

static char *
tp_strdup(lua_State *L, const char *s, size_t len)
{
	char *copy = (char *)malloc(len + 1);
	if (copy == NULL)
		tp_error(L, "pb.tuple: out of memory compiling a plan");
	memcpy(copy, s, len);
	copy[len] = '\0';
	return copy;
}

static void *
tp_calloc(lua_State *L, size_t n, size_t size)
{
	void *p = calloc(n > 0 ? n : 1, size);
	if (p == NULL)
		tp_error(L, "pb.tuple: out of memory compiling a plan");
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
	int field_no, name, column, column_name, column_type, kind, packed,
	    repr, conv, optional, key_kind, value_kind, sub, oneof;
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

	tp_push_key(L, idx, "column_type", LUA_TTABLE, message);
	a.column_type = lua_gettop(L);

	/* Every member of the oneof groups, bound or not, for decode. */
	tp_push_key(L, idx, "oneof_member_no", LUA_TTABLE, message);
	int member_no = lua_gettop(L);
	tp_push_key(L, idx, "oneof_member_group", LUA_TTABLE, message);
	int member_group = lua_gettop(L);
	int n_members = (int)lua_objlen(L, member_no);
	if ((int)lua_objlen(L, member_group) != n_members)
		tp_malformed(L, message, "oneof member arrays differ in length");
	node->member_no = (uint32_t *)tp_calloc(L, (size_t)n_members,
	                                        sizeof(uint32_t));
	node->member_group = (int *)tp_calloc(L, (size_t)n_members,
	                                      sizeof(int));
	node->n_members = n_members;
	for (int k = 1; k <= n_members; k++) {
		node->member_no[k - 1] = (uint32_t)tp_arr_int(L, member_no, k,
			"oneof_member_no", message, 1, TP_MAX_FIELD_NO);
		if (k > 1 && node->member_no[k - 1] <= node->member_no[k - 2])
			tp_malformed(L, message, "oneof members do not ascend");
		node->member_group[k - 1] = (int)tp_arr_int(L, member_group, k,
			"oneof_member_group", message, 1, n_oneofs);
	}

	tp_push_key(L, idx, "unbound_nonnull", LUA_TTABLE, message);
	node->n_unbound = (int)lua_objlen(L, -1);
	node->dmsg = -1;

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
		s = tp_arr_str(L, a.column_type, i, "column_type", message, &len);
		f->ctype = strcmp(s, "varbinary") == 0 ? TP_CTYPE_VARBINARY :
		           strcmp(s, "string") == 0 ? TP_CTYPE_STRING :
		           strcmp(s, "double") == 0 ? TP_CTYPE_DOUBLE :
		           strcmp(s, "unsigned") == 0 ? TP_CTYPE_UNSIGNED :
		           TP_CTYPE_OTHER;
		if (f->repr == TP_REPR_RAW)
			node->has_raw = 1;
		f->dfield = -1;

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

/* ---------------------------------------------------------------- *
 *  Descriptor compiler (decode).                                    *
 *                                                                  *
 *  Decode checks the whole message the way the Lua codec does --    *
 *  omitted fields, unknown fields, extensions -- so it needs the   *
 *  descriptor graph, not only the plan. Every message reachable    *
 *  from the bound one becomes a td_msg, numbered breadth-first     *
 *  through a memo (descriptors may be recursive).                  *
 * ---------------------------------------------------------------- */

#define TD_TIMESTAMP_NAME "google.protobuf.Timestamp"

static int
td_fail(lua_State *L, const char *message, const char *what)
{
	return tp_error(L, "pb.tuple: cannot compile %s for the C "
	                "decoder: %s", message != NULL ? message : "?", what);
}

/* Number the descriptor on top of the stack (popped) unless it already
 * is; returns its 1-based number. */
static int
td_number(lua_State *L, int memo, int order, int *count)
{
	if (lua_type(L, -1) != LUA_TTABLE)
		td_fail(L, NULL, "a message descriptor is not a table");
	lua_pushvalue(L, -1);
	lua_rawget(L, memo);
	if (lua_type(L, -1) == LUA_TNUMBER) {
		int k = (int)lua_tointeger(L, -1);
		lua_pop(L, 2);
		return k;
	}
	lua_pop(L, 1);
	(*count)++;
	lua_pushvalue(L, -1);
	lua_pushinteger(L, *count);
	lua_rawset(L, memo);
	lua_rawseti(L, order, *count);
	return *count;
}

/* The message descriptor a field (table at `fidx`) refers to, numbered;
 * -1 when it refers to none. */
static int
td_field_msg(lua_State *L, int fidx, int memo, int order, int *count)
{
	int top = lua_gettop(L);
	int k = -1;
	lua_getfield(L, fidx, "kind");
	const char *kind = lua_tostring(L, -1);
	if (kind != NULL && (strcmp(kind, "message") == 0 ||
	                     strcmp(kind, "group") == 0)) {
		lua_getfield(L, fidx, "message");
		k = td_number(L, memo, order, count) - 1;
	} else if (kind != NULL && strcmp(kind, "map") == 0) {
		lua_getfield(L, fidx, "value");
		if (lua_type(L, -1) != LUA_TTABLE)
			td_fail(L, NULL, "a map field has no value descriptor");
		lua_getfield(L, -1, "kind");
		const char *vk = lua_tostring(L, -1);
		if (vk != NULL && strcmp(vk, "message") == 0) {
			lua_getfield(L, -2, "message");
			k = td_number(L, memo, order, count) - 1;
		}
	}
	lua_settop(L, top);
	return k;
}

static uint8_t
td_scalar_kind(const char *name)
{
	if (name == NULL)
		return 0;
	for (int k = 0; k < TP_N_KINDS; k++) {
		if (tp_is_scalar_kind(tp_kinds[k].kind) &&
		    tp_kinds[k].kind != PB_KIND_ENUM &&
		    strcmp(name, tp_kinds[k].name) == 0)
			return tp_kinds[k].kind;
	}
	return 0;
}

/* Compile the field (or extension) table at `fidx`. `oneofs` is the
 * stack index of a {[oneof name] = index} table being filled, or 0. */
static void
td_compile_field(lua_State *L, td_field *f, int fidx, int memo,
                 const char *message, int oneofs, int *n_oneofs)
{
	int top = lua_gettop(L);
	lua_getfield(L, fidx, "id");
	lua_Number id = lua_tonumber(L, -1);
	if (lua_type(L, -1) != LUA_TNUMBER || !(id >= 1) ||
	    !(id <= TP_MAX_FIELD_NO) || id != (lua_Number)(int)id)
		td_fail(L, message, "a field has no valid id");
	f->id = (uint32_t)id;
	lua_getfield(L, fidx, "repeated");
	f->repeated = (uint8_t)lua_toboolean(L, -1);
	f->msg = -1;
	f->oneof = -1;

	lua_getfield(L, fidx, "kind");
	const char *kind = lua_tostring(L, -1);
	if (kind == NULL)
		td_fail(L, message, "a field has no kind");
	if (strcmp(kind, "scalar") == 0) {
		lua_getfield(L, fidx, "proto_type");
		f->kind = td_scalar_kind(lua_tostring(L, -1));
		if (f->kind == 0)
			td_fail(L, message, "a scalar field has an unknown type");
	} else if (strcmp(kind, "enum") == 0) {
		f->kind = PB_KIND_ENUM;
	} else if (strcmp(kind, "message") == 0 ||
	           strcmp(kind, "group") == 0) {
		f->kind = kind[0] == 'm' ? PB_KIND_MESSAGE : TD_KIND_GROUP;
		lua_getfield(L, fidx, "message");
		lua_rawget(L, memo);
		f->msg = (int)lua_tointeger(L, -1) - 1;
	} else if (strcmp(kind, "map") == 0) {
		f->kind = PB_KIND_MAP;
		lua_getfield(L, fidx, "key");
		if (lua_type(L, -1) != LUA_TTABLE)
			td_fail(L, message, "a map field has no key descriptor");
		lua_getfield(L, -1, "proto_type");
		f->key_kind = td_scalar_kind(lua_tostring(L, -1));
		if (f->key_kind == 0)
			td_fail(L, message, "a map key has an unknown type");
		lua_getfield(L, fidx, "value");
		int value = lua_gettop(L);
		lua_getfield(L, value, "kind");
		const char *vk = lua_tostring(L, -1);
		if (vk != NULL && strcmp(vk, "scalar") == 0) {
			lua_getfield(L, value, "proto_type");
			f->value_kind = td_scalar_kind(lua_tostring(L, -1));
			if (f->value_kind == 0)
				td_fail(L, message, "a map value has an unknown type");
		} else if (vk != NULL && strcmp(vk, "enum") == 0) {
			f->value_kind = PB_KIND_ENUM;
		} else if (vk != NULL && strcmp(vk, "message") == 0) {
			f->value_kind = PB_KIND_MESSAGE;
			lua_getfield(L, value, "message");
			lua_rawget(L, memo);
			f->msg = (int)lua_tointeger(L, -1) - 1;
		} else {
			td_fail(L, message, "a map value has an unknown kind");
		}
	} else {
		td_fail(L, message, "a field has an unknown kind");
	}

	if (oneofs != 0) {
		/* The codec decodes a field through the reader
		 * pb.finalize_message builds for it; maps go through its
		 * decode loop. A descriptor without readers decodes by
		 * other rules, which this decoder does not reproduce. */
		if (f->kind != PB_KIND_MAP) {
			lua_getfield(L, fidx, "_reader");
			if (lua_type(L, -1) != LUA_TFUNCTION)
				td_fail(L, message, "the descriptor is not finalized "
				        "(a field has no reader)");
		}
		lua_getfield(L, fidx, "oneof");
		if (lua_type(L, -1) == LUA_TSTRING) {
			lua_pushvalue(L, -1);
			lua_rawget(L, oneofs);
			if (lua_isnil(L, -1)) {
				lua_pop(L, 1);
				lua_pushinteger(L, *n_oneofs);
				lua_rawset(L, oneofs);
				f->oneof = (*n_oneofs)++;
			} else {
				f->oneof = (int)lua_tointeger(L, -1);
			}
		}
	}
	lua_settop(L, top);
}

/* Indices of `fields` sorted by ascending id; raises on a duplicate. */
static int *
td_sort_by_id(lua_State *L, const td_field *fields, int n,
              const char *message)
{
	int *by_id = (int *)tp_calloc(L, (size_t)n, sizeof(int));
	for (int i = 0; i < n; i++) {
		int j = i;
		while (j > 0 && fields[by_id[j - 1]].id > fields[i].id) {
			by_id[j] = by_id[j - 1];
			j--;
		}
		if (j > 0 && fields[by_id[j - 1]].id == fields[i].id)
			td_fail(L, message, "two fields share an id");
		by_id[j] = i;
	}
	return by_id;
}

static void
td_compile_msg(lua_State *L, td_msg *m, int didx, int memo, int fns)
{
	int top = lua_gettop(L);
	size_t len;
	lua_getfield(L, didx, "name");
	if (lua_type(L, -1) != LUA_TSTRING)
		td_fail(L, NULL, "a message descriptor has no name");
	const char *name = lua_tolstring(L, -1, &len);
	m->name = tp_strdup(L, name, len);
	name = m->name;

	lua_getfield(L, didx, "decode");
	if (!lua_isnil(L, -1)) {
		if (strcmp(name, TD_TIMESTAMP_NAME) == 0) {
			m->custom = TD_TIMESTAMP;
		} else {
			m->custom = TD_CUSTOM;
			m->custom_fn = (int)lua_objlen(L, fns) + 1;
			lua_pushvalue(L, -1);
			lua_rawseti(L, fns, m->custom_fn);
		}
		lua_settop(L, top);
		return;
	}
	if (strcmp(name, TD_TIMESTAMP_NAME) == 0)
		td_fail(L, name, "a Timestamp without its well-known decode");

	lua_getfield(L, didx, "message_set");
	m->message_set = (uint8_t)lua_toboolean(L, -1);

	lua_getfield(L, didx, "fields");
	if (lua_type(L, -1) != LUA_TTABLE)
		td_fail(L, name, "the descriptor has no fields");
	int fields = lua_gettop(L);
	int n = (int)lua_objlen(L, fields);
	lua_newtable(L);
	int oneofs = lua_gettop(L);
	m->fields = (td_field *)tp_calloc(L, (size_t)n, sizeof(td_field));
	m->n = n;
	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, fields, i);
		if (lua_type(L, -1) != LUA_TTABLE)
			td_fail(L, name, "a field is not a table");
		td_compile_field(L, &m->fields[i - 1], lua_gettop(L), memo, name,
		                 oneofs, &m->n_oneofs);
		lua_pop(L, 1);
	}
	m->by_id = td_sort_by_id(L, m->fields, n, name);

	/* Members of each oneof group, for clearing siblings. */
	m->oo_start = (int *)tp_calloc(L, (size_t)m->n_oneofs + 1,
	                               sizeof(int));
	m->oo_member = (int *)tp_calloc(L, (size_t)n, sizeof(int));
	int k = 0;
	for (int g = 0; g < m->n_oneofs; g++) {
		m->oo_start[g] = k;
		for (int i = 0; i < n; i++) {
			if (m->fields[i].oneof == g)
				m->oo_member[k++] = i;
		}
	}
	m->oo_start[m->n_oneofs] = k;

	/* Registered proto2 extensions. */
	lua_getfield(L, didx, "extensions_by_id");
	if (lua_type(L, -1) == LUA_TTABLE) {
		int exts = lua_gettop(L);
		int n_ext = 0;
		lua_pushnil(L);
		while (lua_next(L, exts) != 0) {
			n_ext++;
			lua_pop(L, 1);
		}
		m->ext = (td_field *)tp_calloc(L, (size_t)n_ext, sizeof(td_field));
		int e = 0;
		lua_pushnil(L);
		while (lua_next(L, exts) != 0) {
			if (lua_type(L, -1) != LUA_TTABLE)
				td_fail(L, name, "an extension is not a table");
			td_compile_field(L, &m->ext[e], lua_gettop(L), memo, name, 0,
			                 NULL);
			if (m->ext[e].kind == PB_KIND_MAP)
				td_fail(L, name, "a map extension");
			e++;
			lua_pop(L, 1);
		}
		m->n_ext = e;
		/* Sort in place by id. */
		for (int i = 1; i < e; i++) {
			td_field x = m->ext[i];
			int j = i;
			while (j > 0 && m->ext[j - 1].id > x.id) {
				m->ext[j] = m->ext[j - 1];
				j--;
			}
			m->ext[j] = x;
		}
	}
	lua_settop(L, top);
}

/* Compile the descriptor graph from the descriptor at `desc_idx`;
 * descriptor-level decode functions go to the table at `fns`. */
static void
td_compile(lua_State *L, tp_plan *tp, int desc_idx, int fns)
{
	int top = lua_gettop(L);
	lua_newtable(L);
	int memo = lua_gettop(L);
	lua_newtable(L);
	int order = lua_gettop(L);
	int count = 0;
	lua_pushvalue(L, desc_idx);
	td_number(L, memo, order, &count);
	for (int k = 1; k <= count; k++) {
		if (count > 1000000)
			td_fail(L, NULL, "too many messages");
		lua_rawgeti(L, order, k);
		int d = lua_gettop(L);
		lua_getfield(L, d, "decode");
		int custom = !lua_isnil(L, -1);
		lua_pop(L, 1);
		if (!custom) {
			lua_getfield(L, d, "fields");
			if (lua_type(L, -1) == LUA_TTABLE) {
				int fields = lua_gettop(L);
				int n = (int)lua_objlen(L, fields);
				for (int i = 1; i <= n; i++) {
					lua_rawgeti(L, fields, i);
					if (lua_type(L, -1) == LUA_TTABLE)
						td_field_msg(L, lua_gettop(L), memo, order,
						             &count);
					lua_pop(L, 1);
				}
			}
			lua_getfield(L, d, "extensions_by_id");
			if (lua_type(L, -1) == LUA_TTABLE) {
				int exts = lua_gettop(L);
				lua_pushnil(L);
				while (lua_next(L, exts) != 0) {
					if (lua_type(L, -1) == LUA_TTABLE)
						td_field_msg(L, lua_gettop(L), memo, order,
						             &count);
					lua_pop(L, 1);
				}
			}
		}
		lua_settop(L, d - 1);
	}
	tp->msgs = (td_msg *)tp_calloc(L, (size_t)count, sizeof(td_msg));
	tp->n_msgs = count;
	for (int k = 1; k <= count; k++) {
		lua_rawgeti(L, order, k);
		td_compile_msg(L, &tp->msgs[k - 1], lua_gettop(L), memo, fns);
		lua_pop(L, 1);
	}
	lua_settop(L, top);
}

/* Index of the field with id `id` in `m`, or -1. */
static int
td_find(const td_msg *m, uint32_t id)
{
	int lo = 0, hi = m->n - 1;
	while (lo <= hi) {
		int mid = lo + (hi - lo) / 2;
		uint32_t x = m->fields[m->by_id[mid]].id;
		if (x == id)
			return m->by_id[mid];
		if (x < id)
			lo = mid + 1;
		else
			hi = mid - 1;
	}
	return -1;
}

static const td_field *
td_find_ext(const td_msg *m, uint64_t id)
{
	int lo = 0, hi = m->n_ext - 1;
	while (lo <= hi) {
		int mid = lo + (hi - lo) / 2;
		uint32_t x = m->ext[mid].id;
		if (x == id)
			return &m->ext[mid];
		if (x < id)
			lo = mid + 1;
		else
			hi = mid - 1;
	}
	return NULL;
}

/* Tie each plan node to the decoder message of its level, and each plan
 * field to its decoder field. */
static void
td_link(lua_State *L, tp_plan *tp)
{
	tp->nodes[0].dmsg = 0;
	for (int k = 0; k < tp->n_nodes; k++) {
		tp_node *node = &tp->nodes[k];
		if (node->dmsg < 0)
			td_fail(L, node->message, "a plan node is not reachable");
		const td_msg *m = &tp->msgs[node->dmsg];
		if (m->custom != TD_PLAIN || strcmp(m->name, node->message) != 0)
			td_fail(L, node->message, "the plan and the descriptor "
			        "disagree on a message");
		for (int i = 0; i < node->n; i++) {
			tp_field *f = &node->fields[i];
			int j = td_find(m, f->field_no);
			if (j < 0)
				td_fail(L, node->message, "a plan field is not in the "
				        "descriptor");
			f->dfield = j;
			const td_field *df = &m->fields[j];
			int msg = df->kind == PB_KIND_MESSAGE ||
			          (df->kind == PB_KIND_MAP &&
			           df->value_kind == PB_KIND_MESSAGE) ? df->msg : -1;
			uint8_t vkind = f->repr == TP_REPR_DICT ? f->value_kind :
			                f->kind;
			if (vkind == TP_KIND_TIMESTAMP &&
			    (msg < 0 || tp->msgs[msg].custom != TD_TIMESTAMP))
				td_fail(L, node->message, "a Timestamp field is not a "
				        "well-known Timestamp");
			if (f->sub < 0)
				continue;
			if (msg < 0)
				td_fail(L, node->message, "a message field has no "
				        "message");
			tp_node *child = &tp->nodes[f->sub];
			if (child->dmsg < 0)
				child->dmsg = msg;
			else if (child->dmsg != msg)
				td_fail(L, node->message, "a plan node stands for two "
				        "messages");
		}
	}
	const tp_node *root = &tp->nodes[0];
	tp->root_want = (uint8_t *)tp_calloc(L, (size_t)tp->msgs[0].n, 1);
	for (int i = 0; i < root->n; i++) {
		if (root->fields[i].repr != TP_REPR_RAW)
			tp->root_want[root->fields[i].dfield] = 1;
	}
}

int
pb_tuple_compile(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, 2, LUA_TTABLE);
	luaL_checkstack(L, 40, "pb.tuple: compiling a plan");
	lua_settop(L, 2);

	tp_plan *tp = (tp_plan *)lua_newuserdata(L, sizeof(tp_plan));
	memset(tp, 0, sizeof(*tp));
	luaL_getmetatable(L, TUPLE_PLAN_MT);
	lua_setmetatable(L, -2);                     /* 3: tplan */
	/* env[1]: the cached slot scratch, see tp_scratch_take.
	 * env[2]: descriptor-level decode functions, see td_custom. */
	lua_createtable(L, 2, 0);
	lua_newuserdata(L, TP_SCRATCH_INITIAL * sizeof(const char *));
	lua_rawseti(L, -2, 1);
	lua_newtable(L);
	lua_rawseti(L, -2, 2);
	lua_setfenv(L, 3);

	lua_newtable(L);                             /* 4: node -> index */
	int memo = lua_gettop(L);
	lua_newtable(L);                             /* 5: index -> node */
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

	lua_settop(L, 3);
	lua_getfenv(L, 3);
	lua_rawgeti(L, -1, 2);                       /* 5: decode functions */
	td_compile(L, tp, 2, lua_gettop(L));
	td_link(L, tp);
	lua_settop(L, 3);
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

#define TP_EXT_DECIMAL  1
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
	lua_State   *L;
	tp_plan     *plan;
	enc_buf     *b;
	int          scratch_idx; /* stack slot of this call's scratch */
	const char **slots;       /* its storage */
	size_t       cap;         /* its size in slots */
	size_t       top;         /* slots in use */
} tp_ctx;

/*
 * Take the scratch cached by the tplan at stack index `plan_idx`, or make
 * one when a call that is still running (this one's caller, re-entered
 * through a finalizer) holds it. Leaves it at the top of the stack; the
 * call keeps it there until it returns.
 */
static void
tp_scratch_take(lua_State *L, tp_ctx *ctx, int plan_idx)
{
	lua_getfenv(L, plan_idx);
	lua_rawgeti(L, -1, 1);
	if (lua_type(L, -1) == LUA_TUSERDATA) {
		lua_pushnil(L);
		lua_rawseti(L, -3, 1);           /* env[1] = nil: taken */
	} else {
		lua_pop(L, 1);
		lua_newuserdata(L, TP_SCRATCH_INITIAL * sizeof(const char *));
	}
	lua_remove(L, -2);                   /* the env table */
	ctx->scratch_idx = lua_gettop(L);
	ctx->slots = (const char **)lua_touserdata(L, -1);
	ctx->cap = lua_objlen(L, -1) / sizeof(const char *);
	ctx->top = 0;
}

/* Hand the scratch back to the tplan. Only on a normal return: a call
 * that raises leaves env[1] empty and its scratch to the GC. */
static void
tp_scratch_return(lua_State *L, const tp_ctx *ctx, int plan_idx)
{
	lua_getfenv(L, plan_idx);
	lua_pushvalue(L, ctx->scratch_idx);
	lua_rawseti(L, -2, 1);
	lua_pop(L, 1);
}

/* Claim `n` cleared slots; returns the index of the first. Growing the
 * scratch moves it, so callers index it through ctx->slots every time. */
static size_t
tp_slots_push(tp_ctx *ctx, int n)
{
	size_t base = ctx->top;
	size_t need = base + (size_t)n;
	if (need > ctx->cap) {
		size_t cap = ctx->cap * 2;
		while (cap < need)
			cap *= 2;
		const char **slots = (const char **)lua_newuserdata(ctx->L,
			cap * sizeof(const char *));
		memcpy((void *)slots, (const void *)ctx->slots,
		       base * sizeof(const char *));
		lua_replace(ctx->L, ctx->scratch_idx);
		ctx->slots = slots;
		ctx->cap = cap;
	}
	if (n > 0)
		memset((void *)&ctx->slots[base], 0, (size_t)n * sizeof(char *));
	ctx->top = need;
	return base;
}

#define TP_SLOT(ctx, k) ((ctx)->slots[(k)])

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
		} else if (h.cls == TP_MP_EXT && h.ext == TP_EXT_DECIMAL) {
			/* A `number` column holds decimals as well; rounding one
			 * to a double would lose digits without a word. */
			tp_push_where(L, node, i, elem);
			lua_pushliteral(L, "expected a number, got decimal (a "
			                "decimal is not converted to floating point)");
			tp_raise(L, 2);
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
		tp_error(L, "pb.tuple: no scalar conversion for kind %s",
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
		return tp_error(L, "pb.tuple: expected a box.tuple, got %s",
		                tp_typename(L, 2));
	lua_settop(L, 2);

	uint8_t storage[ENC_TOP_BUF];
	enc_buf b;
	ebuf_init(L, &b, storage, sizeof(storage), 0);
	tp_ctx ctx;
	ctx.L = L;
	ctx.plan = tp;
	ctx.b = &b;
	tp_scratch_take(L, &ctx, 1);         /* 3: scratch */
	tp_encode_tuple(&ctx, tuple);
	tp_scratch_return(L, &ctx, 1);

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
		return tp_error(L, "pb.tuple: tuples must be an array of "
		                "box.tuple, got %s", tp_typename(L, 3));
	lua_settop(L, 3);
	uint8_t tag[5], tag_len;
	encode_tag((uint32_t)d, PB_WIRE_LEN, tag, &tag_len);

	uint8_t storage[ENC_TOP_BUF];
	enc_buf b;
	ebuf_init(L, &b, storage, sizeof(storage), 0);
	tp_ctx ctx;
	ctx.L = L;
	ctx.plan = tp;
	ctx.b = &b;
	tp_scratch_take(L, &ctx, 1);         /* 4: scratch */

	/* Index 5 holds the tuple being encoded. It sits below the buffer's
	 * growth userdata, which ebuf_grow keeps at the top. */
	lua_pushnil(L);
	int slot = lua_gettop(L);

	size_t n = lua_objlen(L, 3);
	for (size_t k = 1; k <= n; k++) {
		lua_rawgeti(L, 3, (int)k);
		lua_replace(L, slot);
		box_tuple_t *tuple = luaT_istuple(L, slot);
		if (tuple == NULL)
			return tp_error(L, "pb.tuple: expected a box.tuple, "
			                "got %s", tp_typename(L, slot));
		tp_put(&ctx, tag, tag_len);
		size_t mark = tp_len_begin(&ctx);
		tp_encode_tuple(&ctx, tuple);
		tp_len_end(&ctx, mark);
	}
	tp_scratch_return(L, &ctx, 1);

	lua_pushlstring(L, (const char *)ebuf_base(&b), b.used);
	return 1;
}

/* ================================================================ *
 *  Decode: wire -> tuple.                                           *
 *                                                                  *
 *  The Lua path decodes through the descriptor codec into a Lua    *
 *  table, then lays that table out per the plan. This path does    *
 *  the same in two steps without a Lua value per field:            *
 *                                                                  *
 *  1. The wire bytes are decoded, by the codec's rules, into a     *
 *     tree of tv_msg values in the fiber region: every field is    *
 *     read as its kind (the codec ignores the wire type of a known *
 *     field), strings are checked for UTF-8, oneof members unset   *
 *     their siblings, a message given twice is merged field by     *
 *     field in declaration order, and so on. Fields no column      *
 *     reads are decoded and checked but not kept.                  *
 *  2. The tree is laid out as msgpack per the plan, twice: once to *
 *     size the tuple, once to write it into one region block.      *
 *                                                                  *
 *  Errors are not worded here. Input the rules refuse makes decode *
 *  return false; the caller (tuple.lua) then runs the Lua path on  *
 *  the same bytes, which raises the error in its own words. So the *
 *  message is the Lua path's by construction, and the region is    *
 *  truncated before anything is raised. Only box errors (an insert *
 *  of a duplicate key, out of memory) are raised from here, after  *
 *  truncation, as the Lua path raises them from box.               *
 *                                                                  *
 *  Where the Lua layout depends on Lua's hash order -- the keys of *
 *  a message laid out as a map, the entries of a map<K,V> -- this  *
 *  path writes a fixed order instead: fields by ascending number,  *
 *  entries by first appearance on the wire.                        *
 * ================================================================ */

typedef struct tv_msg tv_msg;

typedef union tv_val {
	uint64_t u;              /* integer kinds (two's complement), bool */
	double   d;              /* float, double */
	struct {
		const char *p;
		uint32_t    n;
	} s;                     /* string, bytes */
	tv_msg  *m;              /* message; NULL: an empty one */
	struct {
		int64_t secs;
		int32_t nanos;
	} ts;                    /* Timestamp */
} tv_val;

/* A list element, or a map entry (key and value). */
typedef struct tv_node {
	struct tv_node *next;
	tv_val          key;
	tv_val          v;
	uint8_t         has_v;   /* map: the value was given */
	uint8_t         key_num; /* map: the key is the number the codec
	                          * defaults a missing key to, not a cdata
	                          * (see td_cdata_key) */
} tv_node;

typedef struct tv_field {
	uint8_t   set;           /* singular: holds a value; else: seen */
	tv_val    v;
	tv_node  *head;
	tv_node  *tail;
	uint32_t  count;
	tv_node **index;         /* map: open-addressing key index */
	uint32_t  index_cap;
} tv_field;

struct tv_msg {
	int      msg;
	int      n;
	tv_field f[];
};

typedef struct td_ctx {
	lua_State *L;
	tp_plan   *plan;
	int        plan_idx;     /* stack index of the tplan */
	int        oom;          /* a region allocation failed (diag set) */
} td_ctx;

/* Every decode step returns 0, or -1 when the input does not convert
 * (or memory ran out: ctx->oom). */
#define TD_TRY(x) do { if ((x) != 0) return -1; } while (0)

static void *
td_alloc(td_ctx *c, size_t size)
{
	void *p = box_region_aligned_alloc(size, 8);
	if (p == NULL)
		c->oom = 1;
	return p;
}

/* -- Wire reading (wire.lua) ------------------------------------ */

typedef struct td_buf {
	const uint8_t *b;
	size_t         len;
	size_t         pos;
} td_buf;

static int
td_varint(td_buf *r, uint64_t *out)
{
	uint64_t result = 0;
	int shift = 0;
	for (;;) {
		if (r->pos >= r->len)
			return -1;                   /* truncated varint */
		uint8_t c = r->b[r->pos++];
		result |= (uint64_t)(c & 0x7f) << shift;
		if (c < 0x80) {
			*out = result;
			return 0;
		}
		shift += 7;
		if (shift >= 70)
			return -1;                   /* varint exceeds 10 bytes */
	}
}

static int
td_tag(td_buf *r, uint32_t *id, int *wt)
{
	if (r->pos >= r->len)
		return -1;
	uint8_t c = r->b[r->pos];
	if (c < 0x80) {
		*wt = c & 7;
		*id = c >> 3;
		r->pos++;
	} else {
		uint64_t u;
		TD_TRY(td_varint(r, &u));
		if (r->b[r->pos - 1] == 0)
			return -1;                   /* overlong tag */
		*wt = (int)(u & 7);
		uint64_t fn = u >> 3;
		if (*wt < 6 && fn > 0x1FFFFFFF)
			return -1;                   /* field number out of range */
		*id = (uint32_t)fn;
	}
	if (*wt >= 6 || *id == 0)
		return -1;                       /* illegal wire type / field 0 */
	return 0;
}

/* A LEN payload: sets *p, *n, advances past it. */
static int
td_len(td_buf *r, const uint8_t **p, uint32_t *n)
{
	uint64_t len;
	TD_TRY(td_varint(r, &len));
	if (len > r->len - r->pos)
		return -1;                       /* truncated LEN payload */
	*p = r->b + r->pos;
	*n = (uint32_t)len;
	r->pos += (size_t)len;
	return 0;
}

static int
td_skip(td_buf *r, int wt, uint32_t id)
{
	switch (wt) {
	case PB_WIRE_VARINT: {
		uint64_t u;
		return td_varint(r, &u);
	}
	case PB_WIRE_I64:
		if (r->len - r->pos < 8)
			return -1;
		r->pos += 8;
		return 0;
	case PB_WIRE_LEN: {
		const uint8_t *p;
		uint32_t n;
		return td_len(r, &p, &n);
	}
	case PB_WIRE_I32:
		if (r->len - r->pos < 4)
			return -1;
		r->pos += 4;
		return 0;
	case PB_WIRE_SGROUP: {
		/* Nested groups on an explicit stack, bounded like messages. */
		uint32_t open[PB_RECURSION_LIMIT + 1];
		int n = 0;
		open[n++] = id;
		for (;;) {
			uint32_t iid;
			int iwt;
			TD_TRY(td_tag(r, &iid, &iwt));
			if (iwt == PB_WIRE_EGROUP) {
				if (iid != open[n - 1])
					return -1;
				if (--n == 0)
					return 0;
			} else if (iwt == PB_WIRE_SGROUP) {
				if (n + 1 > PB_RECURSION_LIMIT)
					return -1;
				open[n++] = iid;
			} else {
				TD_TRY(td_skip(r, iwt, iid));
			}
		}
	}
	default:
		return -1;                       /* unexpected EGROUP */
	}
}

static int
td_utf8(const uint8_t *s, size_t n)
{
	size_t i = 0;
	while (i < n) {
		uint8_t c = s[i];
		if (c < 0x80) {
			i++;
		} else if ((c & 0xE0) == 0xC0) {
			if (c < 0xC2 || i + 1 >= n || (s[i + 1] & 0xC0) != 0x80)
				return 0;
			i += 2;
		} else if ((c & 0xF0) == 0xE0) {
			if (i + 2 >= n)
				return 0;
			uint8_t b1 = s[i + 1], b2 = s[i + 2];
			if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80)
				return 0;
			if ((c == 0xE0 && b1 < 0xA0) || (c == 0xED && b1 >= 0xA0))
				return 0;
			i += 3;
		} else if ((c & 0xF8) == 0xF0) {
			if (c > 0xF4 || i + 3 >= n)
				return 0;
			uint8_t b1 = s[i + 1], b2 = s[i + 2], b3 = s[i + 3];
			if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 ||
			    (b3 & 0xC0) != 0x80)
				return 0;
			if ((c == 0xF0 && b1 < 0x90) || (c == 0xF4 && b1 >= 0x90))
				return 0;
			i += 4;
		} else {
			return 0;
		}
	}
	return 1;
}

/* NaN as the Lua decoders produce it: `0/0`, whose bits are the
 * machine's default NaN. */
static double
td_nan(void)
{
	volatile double zero = 0.0;
	return zero / zero;
}

static inline uint32_t
td_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
	       (uint32_t)p[3] << 24;
}

static inline uint64_t
td_le64(const uint8_t *p)
{
	return (uint64_t)td_le32(p) | (uint64_t)td_le32(p + 4) << 32;
}

/* One scalar or enum value of `kind`, read whatever the wire type. */
static int
td_scalar(td_buf *r, uint8_t kind, tv_val *v)
{
	uint64_t u;
	switch (kind) {
	case PB_KIND_INT32:
	case PB_KIND_ENUM:
		TD_TRY(td_varint(r, &u));
		v->u = (uint64_t)(int64_t)(int32_t)(uint32_t)u;
		return 0;
	case PB_KIND_INT64:
	case PB_KIND_UINT64:
		TD_TRY(td_varint(r, &u));
		v->u = u;
		return 0;
	case PB_KIND_UINT32:
		TD_TRY(td_varint(r, &u));
		v->u = (uint32_t)u;
		return 0;
	case PB_KIND_SINT32: {
		TD_TRY(td_varint(r, &u));
		uint32_t x = (uint32_t)u;
		v->u = (uint64_t)(int64_t)(int32_t)((x >> 1) ^ (0u - (x & 1)));
		return 0;
	}
	case PB_KIND_SINT64:
		TD_TRY(td_varint(r, &u));
		v->u = (u >> 1) ^ (0 - (u & 1));
		return 0;
	case PB_KIND_BOOL:
		TD_TRY(td_varint(r, &u));
		v->u = u != 0;
		return 0;
	case PB_KIND_FIXED32:
	case PB_KIND_SFIXED32:
	case PB_KIND_FLOAT: {
		if (r->len - r->pos < 4)
			return -1;
		uint32_t x = td_le32(r->b + r->pos);
		r->pos += 4;
		if (kind == PB_KIND_FIXED32) {
			v->u = x;
		} else if (kind == PB_KIND_SFIXED32) {
			v->u = (uint64_t)(int64_t)(int32_t)x;
		} else if (((x >> 23) & 0xff) == 0xff) {
			union { uint64_t u; double d; } inf;
			inf.u = (x & 0x80000000u) ? 0xfff0000000000000ULL :
			        0x7ff0000000000000ULL;
			v->d = (x & 0x7fffff) == 0 ? inf.d : td_nan();
		} else {
			union { uint32_t u; float f; } pun;
			pun.u = x;
			v->d = (double)pun.f;
		}
		return 0;
	}
	case PB_KIND_FIXED64:
	case PB_KIND_SFIXED64:
	case PB_KIND_DOUBLE: {
		if (r->len - r->pos < 8)
			return -1;
		uint64_t x = td_le64(r->b + r->pos);
		r->pos += 8;
		if (kind != PB_KIND_DOUBLE) {
			v->u = x;
		} else if (((x >> 52) & 0x7ff) == 0x7ff &&
		           (x & 0xfffffffffffffULL) != 0) {
			v->d = td_nan();
		} else {
			union { uint64_t u; double d; } pun;
			pun.u = x;
			v->d = pun.d;
		}
		return 0;
	}
	case PB_KIND_STRING:
	case PB_KIND_BYTES: {
		const uint8_t *p;
		uint32_t n;
		TD_TRY(td_len(r, &p, &n));
		if (kind == PB_KIND_STRING && !td_utf8(p, n))
			return -1;
		v->s.p = (const char *)p;
		v->s.n = n;
		return 0;
	}
	default:
		return -1;
	}
}

static inline int
td_packable(uint8_t kind)
{
	return tp_is_scalar_kind(kind) && kind != PB_KIND_STRING &&
	       kind != PB_KIND_BYTES;
}

/* -- The decoded tree ------------------------------------------- */

static tv_msg *
tv_new(td_ctx *c, int msg)
{
	int n = c->plan->msgs[msg].n;
	size_t size = sizeof(tv_msg) + (size_t)n * sizeof(tv_field);
	tv_msg *m = (tv_msg *)td_alloc(c, size);
	if (m == NULL)
		return NULL;
	memset(m, 0, size);
	m->msg = msg;
	m->n = n;
	return m;
}

static tv_node *
tv_append(td_ctx *c, tv_field *f)
{
	tv_node *e = (tv_node *)td_alloc(c, sizeof(tv_node));
	if (e == NULL)
		return NULL;
	memset(e, 0, sizeof(*e));
	if (f->tail == NULL)
		f->head = e;
	else
		f->tail->next = e;
	f->tail = e;
	f->count++;
	return e;
}

static int
tv_key_eq(uint8_t kind, const tv_val *a, const tv_val *b)
{
	if (kind == PB_KIND_STRING || kind == PB_KIND_BYTES)
		return a->s.n == b->s.n && memcmp(a->s.p, b->s.p, a->s.n) == 0;
	return a->u == b->u;
}

static uint32_t
tv_key_hash(uint8_t kind, const tv_val *k)
{
	uint64_t h;
	if (kind == PB_KIND_STRING || kind == PB_KIND_BYTES) {
		h = 1469598103934665603ULL;
		for (uint32_t i = 0; i < k->s.n; i++)
			h = (h ^ (uint8_t)k->s.p[i]) * 1099511628211ULL;
	} else {
		h = k->u * 0x9E3779B97F4A7C15ULL;
		h ^= h >> 29;
	}
	return (uint32_t)(h ^ (h >> 32));
}

static void
tv_index_put(tv_node **index, uint32_t cap, uint8_t kind, tv_node *e)
{
	uint32_t h = tv_key_hash(kind, &e->key) & (cap - 1);
	while (index[h] != NULL)
		h = (h + 1) & (cap - 1);
	index[h] = e;
}

/* Index entry `e`, already appended to f's list (and counted). */
static int
tv_index_add(td_ctx *c, tv_field *f, uint8_t kind, tv_node *e)
{
	if (f->count * 2 <= f->index_cap) {
		tv_index_put(f->index, f->index_cap, kind, e);
		return 0;
	}
	uint32_t cap = f->index_cap == 0 ? 32 : f->index_cap;
	while (f->count * 2 > cap)
		cap *= 2;
	tv_node **index = (tv_node **)td_alloc(c, cap * sizeof(tv_node *));
	if (index == NULL)
		return -1;
	memset(index, 0, cap * sizeof(tv_node *));
	for (tv_node *x = f->head; x != NULL; x = x->next)
		tv_index_put(index, cap, kind, x);
	f->index = index;
	f->index_cap = cap;
	return 0;
}

static tv_node *
tv_index_find(const tv_field *f, uint8_t kind, const tv_val *key)
{
	if (f->index == NULL) {
		for (tv_node *x = f->head; x != NULL; x = x->next) {
			if (tv_key_eq(kind, &x->key, key))
				return x;
		}
		return NULL;
	}
	uint32_t h = tv_key_hash(kind, key) & (f->index_cap - 1);
	while (f->index[h] != NULL) {
		if (tv_key_eq(kind, &f->index[h]->key, key))
			return f->index[h];
		h = (h + 1) & (f->index_cap - 1);
	}
	return NULL;
}

/* map_t[key] = value: a key already present keeps its place, and its
 * identity (`key_num` of the first entry with that key). */
static int
tv_map_put(td_ctx *c, tv_field *f, uint8_t kkind, const tv_val *key,
           int key_num, const tv_val *v, int has_v)
{
	tv_node *e = tv_index_find(f, kkind, key);
	if (e == NULL) {
		e = tv_append(c, f);
		if (e == NULL)
			return -1;
		e->key = *key;
		e->key_num = (uint8_t)key_num;
		/* Up to 8 entries a scan finds a key; past that, an index. */
		if (f->count > 8 && tv_index_add(c, f, kkind, e) != 0)
			return -1;
	}
	e->v = *v;
	e->has_v = (uint8_t)has_v;
	return 0;
}

/* Keys the codec keeps as 64-bit cdata. Lua tables key cdata by
 * identity, so a map merged into another keeps both entries of a key
 * given in each, where every other key type is merged by value. The
 * exception is a key missing from its entry: the codec defaults it to
 * the number 0, one and the same key in every map, so those entries
 * merge like any number key. (Within one message the codec deduplicates
 * 64-bit keys by value, number or cdata alike, keeping the first.) */
static inline int
td_cdata_key(uint8_t kind)
{
	return kind == PB_KIND_INT64 || kind == PB_KIND_UINT64 ||
	       kind == PB_KIND_SINT64 || kind == PB_KIND_FIXED64 ||
	       kind == PB_KIND_SFIXED64;
}

static void
tv_clear_siblings(const td_msg *m, tv_msg *out, int j)
{
	int g = m->fields[j].oneof;
	if (g < 0)
		return;
	for (int k = m->oo_start[g]; k < m->oo_start[g + 1]; k++) {
		int s = m->oo_member[k];
		if (s != j)
			memset(&out->f[s], 0, sizeof(tv_field));
	}
}

/* merge_message in codec.lua: `dec` into `prev`, field by field in
 * declaration order. */
static int
tv_merge(td_ctx *c, tv_msg *prev, tv_msg *dec)
{
	const td_msg *m = &c->plan->msgs[prev->msg];
	for (int j = 0; j < m->n; j++) {
		tv_field *v = &dec->f[j];
		if (!v->set)
			continue;
		tv_field *pv = &prev->f[j];
		const td_field *f = &m->fields[j];
		if (!pv->set) {
			*pv = *v;
		} else if (f->kind == PB_KIND_MAP) {
			for (tv_node *e = v->head; e != NULL; e = e->next) {
				if (!td_cdata_key(f->key_kind)) {
					TD_TRY(tv_map_put(c, pv, f->key_kind, &e->key, 0,
					                  &e->v, e->has_v));
					continue;
				}
				tv_node *x = NULL;
				if (e->key_num) {
					/* The number 0: the entry of pv keyed by it. */
					for (x = pv->head; x != NULL; x = x->next) {
						if (x->key_num)
							break;
					}
				}
				if (x == NULL) {
					x = tv_append(c, pv);
					if (x == NULL)
						return -1;
					x->key = e->key;
					x->key_num = e->key_num;
				}
				x->v = e->v;
				x->has_v = e->has_v;
			}
		} else if (f->repeated) {
			if (v->head != NULL) {
				if (pv->tail == NULL)
					pv->head = v->head;
				else
					pv->tail->next = v->head;
				pv->tail = v->tail;
				pv->count += v->count;
			}
		} else if (f->kind == PB_KIND_MESSAGE &&
		           c->plan->msgs[f->msg].custom == TD_PLAIN) {
			TD_TRY(tv_merge(c, pv->v.m, v->v.m));
		} else {
			pv->v = v->v;
		}
		tv_clear_siblings(m, prev, j);
	}
	return 0;
}

/* -- Decoding ---------------------------------------------------- */

static int td_fields(td_ctx *c, int mi, const uint8_t *b, size_t len,
                     int depth, tv_msg *out, const uint8_t *want);

/* A descriptor-level decode other than Timestamp's runs in Lua, for its
 * checks only: nothing it returns is laid out. */
static int
td_custom(td_ctx *c, const td_msg *m, const uint8_t *p, uint32_t n,
          int depth)
{
	lua_State *L = c->L;
	int top = lua_gettop(L);
	lua_getfenv(L, c->plan_idx);
	lua_rawgeti(L, -1, 2);
	lua_rawgeti(L, -1, m->custom_fn);
	lua_pushlstring(L, (const char *)p, n);
	lua_pushinteger(L, depth);
	int rc = lua_pcall(L, 2, 0, 0);
	lua_settop(L, top);
	return rc == 0 ? 0 : -1;
}

/* wkt.Timestamp_decode: the last seconds and nanos on the wire. */
static int
td_timestamp(const uint8_t *p, uint32_t n, tv_val *v)
{
	td_buf r = {p, n, 0};
	tv_val secs = {0}, nanos = {0};
	while (r.pos < r.len) {
		uint32_t id;
		int wt;
		TD_TRY(td_tag(&r, &id, &wt));
		if (id == 1)
			TD_TRY(td_scalar(&r, PB_KIND_INT64, &secs));
		else if (id == 2)
			TD_TRY(td_scalar(&r, PB_KIND_INT32, &nanos));
		else
			TD_TRY(td_skip(&r, wt, id));
	}
	v->ts.secs = (int64_t)secs.u;
	v->ts.nanos = (int32_t)(int64_t)nanos.u;
	return 0;
}

/* decode_msg: the payload of a message value. Keeps it in *v when
 * `store`; checks it only otherwise. */
static int
td_message(td_ctx *c, int mi, const uint8_t *p, uint32_t n, int depth,
           int store, tv_val *v)
{
	const td_msg *m = &c->plan->msgs[mi];
	memset(v, 0, sizeof(*v));
	if (m->custom == TD_TIMESTAMP)
		return td_timestamp(p, n, v);
	if (m->custom == TD_CUSTOM)
		return td_custom(c, m, p, n, depth);
	tv_msg *out = NULL;
	if (store) {
		out = tv_new(c, mi);
		if (out == NULL)
			return -1;
	}
	v->m = out;
	return td_fields(c, mi, p, n, depth, out, NULL);
}

/* decode_group: fields until the matching EGROUP. Groups are never
 * bound to a column, so only checked. */
static int
td_group(td_ctx *c, int mi, td_buf *r, uint32_t stop_id, int depth);

static int td_read(td_ctx *c, const td_msg *m, const td_field *f, int j,
                   td_buf *r, int wt, int depth, tv_msg *out, int store,
                   int in_group);

static int
td_group(td_ctx *c, int mi, td_buf *r, uint32_t stop_id, int depth)
{
	if (depth > PB_RECURSION_LIMIT)
		return -1;
	const td_msg *m = &c->plan->msgs[mi];
	while (r->pos < r->len) {
		uint32_t id;
		int wt;
		TD_TRY(td_tag(r, &id, &wt));
		if (wt == PB_WIRE_EGROUP)
			return id == stop_id ? 0 : -1;
		int j = m->custom == TD_PLAIN ? td_find(m, id) : -1;
		if (j < 0) {
			TD_TRY(td_skip(r, wt, id));
			continue;
		}
		TD_TRY(td_read(c, m, &m->fields[j], j, r, wt, depth, NULL, 0, 1));
	}
	return -1;                           /* not terminated by EGROUP */
}

/* One map entry (decode_one for key and value); the payload of the map
 * field's LEN. */
static int
td_map_entry(td_ctx *c, const td_field *f, const uint8_t *p, uint32_t n,
             int depth, tv_field *vf)
{
	td_buf r = {p, n, 0};
	tv_val key = {0}, val = {0};
	int has_key = 0, has_val = 0;
	while (r.pos < r.len) {
		uint32_t id;
		int wt;
		TD_TRY(td_tag(&r, &id, &wt));
		if (id == 1) {
			TD_TRY(td_scalar(&r, f->key_kind, &key));
			has_key = 1;
		} else if (id == 2) {
			if (f->value_kind == PB_KIND_MESSAGE) {
				const uint8_t *vp;
				uint32_t vn;
				TD_TRY(td_len(&r, &vp, &vn));
				TD_TRY(td_message(c, f->msg, vp, vn, depth + 1,
				                  vf != NULL, &val));
			} else {
				TD_TRY(td_scalar(&r, f->value_kind, &val));
			}
			has_val = 1;
		} else {
			TD_TRY(td_skip(&r, wt, id));
		}
	}
	if (vf == NULL)
		return 0;
	if (!has_key) {
		/* The key type's default: 0, false or ''. */
		memset(&key, 0, sizeof(key));
		if (f->key_kind == PB_KIND_STRING)
			key.s.p = "";
	}
	/* A missing value is the value type's default: see tl_element. */
	if (!has_val)
		memset(&val, 0, sizeof(val));
	vf->set = 1;
	return tv_map_put(c, vf, f->key_kind, &key, !has_key, &val, has_val);
}

/* The value of known field `f` (index j of message m) at the reader
 * position: f._reader in codec.lua, or its map branch. */
static int
td_read(td_ctx *c, const td_msg *m, const td_field *f, int j, td_buf *r,
        int wt, int depth, tv_msg *out, int store, int in_group)
{
	tv_field *vf = out != NULL ? &out->f[j] : NULL;
	tv_val v;
	if (f->kind == PB_KIND_MAP) {
		if (in_group)
			return td_skip(r, wt, f->id);  /* no reader in a group */
		const uint8_t *p;
		uint32_t n;
		TD_TRY(td_len(r, &p, &n));
		if (vf != NULL)
			vf->set = 1;
		return td_map_entry(c, f, p, n, depth, store ? vf : NULL);
	}
	if (f->repeated) {
		if (vf != NULL)
			vf->set = 1;
		if (tp_is_scalar_kind(f->kind)) {
			if (td_packable(f->kind) && wt == PB_WIRE_LEN) {
				const uint8_t *p;
				uint32_t n;
				TD_TRY(td_len(r, &p, &n));
				td_buf pr = {p, n, 0};
				while (pr.pos < pr.len) {
					TD_TRY(td_scalar(&pr, f->kind, &v));
					if (store) {
						tv_node *e = tv_append(c, vf);
						if (e == NULL)
							return -1;
						e->v = v;
					}
				}
				return 0;
			}
			TD_TRY(td_scalar(r, f->kind, &v));
		} else if (f->kind == PB_KIND_MESSAGE) {
			const uint8_t *p;
			uint32_t n;
			TD_TRY(td_len(r, &p, &n));
			TD_TRY(td_message(c, f->msg, p, n, depth + 1, store, &v));
		} else {
			return td_group(c, f->msg, r, f->id, depth + 1);
		}
		if (store) {
			tv_node *e = tv_append(c, vf);
			if (e == NULL)
				return -1;
			e->v = v;
		}
		return 0;
	}
	/* Singular. */
	if (tp_is_scalar_kind(f->kind)) {
		TD_TRY(td_scalar(r, f->kind, &v));
	} else if (f->kind == PB_KIND_MESSAGE) {
		const uint8_t *p;
		uint32_t n;
		TD_TRY(td_len(r, &p, &n));
		TD_TRY(td_message(c, f->msg, p, n, depth + 1, store, &v));
		if (store && vf->set &&
		    c->plan->msgs[f->msg].custom == TD_PLAIN) {
			TD_TRY(tv_merge(c, vf->v.m, v.m));
			v = vf->v;
		}
	} else {
		TD_TRY(td_group(c, f->msg, r, f->id, depth + 1));
	}
	if (vf != NULL) {
		vf->set = 1;
		if (store)
			vf->v = v;
		tv_clear_siblings(m, out, j);
	}
	return 0;
}

/* A registered extension (decode_extension): checked, not kept. */
static int
td_extension(td_ctx *c, const td_field *e, td_buf *r, int wt, int depth)
{
	tv_val v;
	if (e->kind == TD_KIND_GROUP)
		return td_group(c, e->msg, r, e->id, depth + 1);
	if (e->kind == PB_KIND_MESSAGE) {
		const uint8_t *p;
		uint32_t n;
		TD_TRY(td_len(r, &p, &n));
		return td_message(c, e->msg, p, n, depth + 1, 0, &v);
	}
	if (e->repeated && td_packable(e->kind) && wt == PB_WIRE_LEN) {
		const uint8_t *p;
		uint32_t n;
		TD_TRY(td_len(r, &p, &n));
		td_buf pr = {p, n, 0};
		while (pr.pos < pr.len)
			TD_TRY(td_scalar(&pr, e->kind, &v));
		return 0;
	}
	return td_scalar(r, e->kind, &v);
}

/* A MessageSet item (decode_message_set_item), its SGROUP consumed. */
static int
td_message_set_item(td_ctx *c, const td_msg *m, td_buf *r, int depth)
{
	uint64_t type_id = 0;
	int has_type = 0;
	const uint8_t *p = NULL;
	uint32_t n = 0;
	for (;;) {
		uint32_t id;
		int wt;
		TD_TRY(td_tag(r, &id, &wt));
		if (wt == PB_WIRE_EGROUP) {
			if (id != 1)
				return -1;
			break;
		}
		if (id == 2 && wt == PB_WIRE_VARINT) {
			TD_TRY(td_varint(r, &type_id));
			has_type = 1;
		} else if (id == 3 && wt == PB_WIRE_LEN) {
			TD_TRY(td_len(r, &p, &n));
		} else {
			TD_TRY(td_skip(r, wt, id));
		}
	}
	const td_field *e = has_type ? td_find_ext(m, type_id) : NULL;
	if (e == NULL || p == NULL || e->kind != PB_KIND_MESSAGE)
		return 0;
	tv_val v;
	return td_message(c, e->msg, p, n, depth + 1, 0, &v);
}

/* decode_message: every field of message `mi` in b[0, len). Values go
 * to `out` (NULL: check only) for the fields `want` marks (NULL: all). */
static int
td_fields(td_ctx *c, int mi, const uint8_t *b, size_t len, int depth,
          tv_msg *out, const uint8_t *want)
{
	if (depth > PB_RECURSION_LIMIT)
		return -1;
	const td_msg *m = &c->plan->msgs[mi];
	td_buf r = {b, len, 0};
	while (r.pos < r.len) {
		uint32_t id;
		int wt;
		TD_TRY(td_tag(&r, &id, &wt));
		int j = td_find(m, id);
		if (j >= 0) {
			int store = out != NULL && (want == NULL || want[j]);
			TD_TRY(td_read(c, m, &m->fields[j], j, &r, wt, depth, out,
			               store, 0));
			continue;
		}
		const td_field *e = td_find_ext(m, id);
		if (e != NULL) {
			TD_TRY(td_extension(c, e, &r, wt, depth));
		} else if (id == 1 && wt == PB_WIRE_SGROUP && m->message_set) {
			TD_TRY(td_message_set_item(c, m, &r, depth));
		} else {
			TD_TRY(td_skip(&r, wt, id));
		}
	}
	return 0;
}

/* collect_raw in tuple.lua: the payloads of the tuple level's raw
 * fields, a oneof member unsetting the group's previous raw member. */
static int
td_collect_raw(td_ctx *c, const tp_node *node, const uint8_t *b,
               size_t len, tv_field *parts)
{
	uint32_t *active = NULL;
	if (node->n_oneofs > 0) {
		active = (uint32_t *)td_alloc(c, (size_t)node->n_oneofs *
		                              sizeof(uint32_t));
		if (active == NULL)
			return -1;
		memset(active, 0, (size_t)node->n_oneofs * sizeof(uint32_t));
	}
	td_buf r = {b, len, 0};
	while (r.pos < r.len) {
		uint32_t id;
		int wt;
		TD_TRY(td_tag(&r, &id, &wt));
		/* Oneof membership: binary search over member_no. */
		int lo = 0, hi = node->n_members - 1, g = 0;
		while (lo <= hi) {
			int mid = lo + (hi - lo) / 2;
			if (node->member_no[mid] == id) {
				g = node->member_group[mid];
				break;
			}
			if (node->member_no[mid] < id)
				lo = mid + 1;
			else
				hi = mid - 1;
		}
		if (g != 0) {
			uint32_t prev = active[g - 1];
			if (prev != 0 && prev != id) {
				for (int i = 0; i < node->n; i++) {
					if (node->fields[i].field_no == prev &&
					    node->fields[i].repr == TP_REPR_RAW)
						memset(&parts[i], 0, sizeof(tv_field));
				}
			}
			active[g - 1] = id;
		}
		int ri = -1;
		for (int i = 0; i < node->n; i++) {
			if (node->fields[i].field_no == id &&
			    node->fields[i].repr == TP_REPR_RAW)
				ri = i;
		}
		if (ri >= 0 && wt == PB_WIRE_LEN) {
			const uint8_t *p;
			uint32_t n;
			TD_TRY(td_len(&r, &p, &n));
			tv_node *e = tv_append(c, &parts[ri]);
			if (e == NULL)
				return -1;
			e->v.s.p = (const char *)p;
			e->v.s.n = n;
			parts[ri].set = 1;
		} else {
			TD_TRY(td_skip(&r, wt, id));
		}
	}
	return 0;
}

/* -- Layout: the tree as msgpack (tuple_value & co in tuple.lua) --- */

/* Sizes (p NULL) or writes. */
typedef struct mpw {
	char  *p;
	size_t size;
} mpw;

static inline void
w_nil(mpw *w)
{
	if (w->p != NULL) w->p = mp_encode_nil(w->p);
	else w->size += mp_sizeof_nil();
}

static inline void
w_bool(mpw *w, int v)
{
	if (w->p != NULL) w->p = mp_encode_bool(w->p, v != 0);
	else w->size += mp_sizeof_bool(v != 0);
}

static inline void
w_uint(mpw *w, uint64_t v)
{
	if (w->p != NULL) w->p = mp_encode_uint(w->p, v);
	else w->size += mp_sizeof_uint(v);
}

/* An integer by value: non-negative ones as unsigned. */
static inline void
w_int(mpw *w, int64_t v)
{
	if (v >= 0) {
		w_uint(w, (uint64_t)v);
	} else if (w->p != NULL) {
		w->p = mp_encode_int(w->p, v);
	} else {
		w->size += mp_sizeof_int(v);
	}
}

static inline void
w_double(mpw *w, double v)
{
	if (w->p != NULL) w->p = mp_encode_double(w->p, v);
	else w->size += mp_sizeof_double(v);
}

static inline void
w_str(mpw *w, const char *s, uint32_t n)
{
	if (w->p != NULL) w->p = mp_encode_str(w->p, s, n);
	else w->size += mp_sizeof_str(n);
}

static inline void
w_bin(mpw *w, const char *s, uint32_t n)
{
	if (w->p != NULL) w->p = mp_encode_bin(w->p, s, n);
	else w->size += mp_sizeof_bin(n);
}

static inline void
w_array(mpw *w, uint32_t n)
{
	if (w->p != NULL) w->p = mp_encode_array(w->p, n);
	else w->size += mp_sizeof_array(n);
}

static inline void
w_map(mpw *w, uint32_t n)
{
	if (w->p != NULL) w->p = mp_encode_map(w->p, n);
	else w->size += mp_sizeof_map(n);
}

static inline void
w_ext(mpw *w, int8_t type, const char *data, uint32_t n)
{
	if (w->p != NULL) w->p = mp_encode_ext(w->p, type, data, n);
	else w->size += mp_sizeof_ext(n);
}

/* A Lua number as box encodes it: a finite non-integral value as a
 * double, an integral one in range as an integer, the rest as a double. */
static void
w_number(mpw *w, double d)
{
	union { double d; uint64_t u; } pun;
	pun.d = d;
	int finite = ((pun.u >> 52) & 0x7ff) != 0x7ff;
	double two63 = 9223372036854775808.0;
	if (finite && d > -4503599627370496.0 && d < 4503599627370496.0 &&
	    d != (double)(int64_t)d) {
		w_double(w, d);
	} else if (d >= 0 && d < 2 * two63) {
		w_uint(w, (uint64_t)d);
	} else if (d >= -two63 && d < two63) {
		w_int(w, (int64_t)d);
	} else {
		w_double(w, d);
	}
}

/* datetime.new{timestamp = seconds, nsec = nanos}, as msgpack; -1 when
 * it is outside the datetime range. */
static int
w_timestamp(mpw *w, const tv_val *v)
{
	int64_t secs = v->ts.secs;
	int32_t nanos = v->ts.nanos;
	if (secs < -185604722870400LL || secs > 185480451417600LL ||
	    nanos < 0 || nanos > 1000000000)
		return -1;
	char data[16];
	uint64_t s = (uint64_t)secs;
	for (int k = 0; k < 8; k++)
		data[k] = (char)(s >> (8 * k));
	if (nanos == 0) {
		w_ext(w, TP_EXT_DATETIME, data, 8);
		return 0;
	}
	uint32_t ns = (uint32_t)nanos;
	for (int k = 0; k < 4; k++)
		data[8 + k] = (char)(ns >> (8 * k));
	memset(data + 12, 0, 4);             /* tzoffset, tzindex */
	w_ext(w, TP_EXT_DATETIME, data, 16);
	return 0;
}

static inline int
td_signed(uint8_t kind)
{
	return kind == PB_KIND_INT32 || kind == PB_KIND_INT64 ||
	       kind == PB_KIND_SINT32 || kind == PB_KIND_SINT64 ||
	       kind == PB_KIND_SFIXED32 || kind == PB_KIND_SFIXED64 ||
	       kind == PB_KIND_ENUM;
}

static inline int
td_hex(char ch)
{
	if (ch >= '0' && ch <= '9') return ch - '0';
	if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
	return -1;
}

/* tuple_scalar: value `v` (the kind's default when !has) of scalar
 * `kind` in a slot of column type `ctype`. A uuid column's empty value
 * is NULL: the caller asks tl_scalar_present first. */
static int
w_scalar(mpw *w, uint8_t kind, uint8_t uuid, uint8_t ctype, int has,
         const tv_val *v)
{
	tv_val zero;
	memset(&zero, 0, sizeof(zero));
	if (!has) {
		if (kind == PB_KIND_STRING || kind == PB_KIND_BYTES)
			zero.s.p = "";
		v = &zero;
	}
	if (tp_range_of(kind) != TP_RANGE_NONE) {
		if (td_signed(kind)) {
			int64_t x = (int64_t)v->u;
			if (ctype == TP_CTYPE_UNSIGNED && x < 0)
				return -1;
			w_int(w, x);
		} else {
			w_uint(w, v->u);
		}
		return 0;
	}
	switch (kind) {
	case PB_KIND_FLOAT:
	case PB_KIND_DOUBLE:
		if (ctype == TP_CTYPE_DOUBLE)
			w_double(w, v->d);
		else
			w_number(w, v->d);
		return 0;
	case PB_KIND_BOOL:
		w_bool(w, v->u != 0);
		return 0;
	default:
		break;
	}
	/* string / bytes */
	if (uuid == TP_UUID_TEXT) {
		/* uuid.fromstr(v) whose :str() is v: the canonical text. */
		if (v->s.n != 36)
			return -1;
		char bin[16];
		int nibble = 0;
		for (int i = 0; i < 36; i++) {
			char ch = v->s.p[i];
			if (i == 8 || i == 13 || i == 18 || i == 23) {
				if (ch != '-')
					return -1;
				continue;
			}
			int x = td_hex(ch);
			if (x < 0)
				return -1;
			if (nibble % 2 == 0)
				bin[nibble / 2] = (char)(x << 4);
			else
				bin[nibble / 2] = (char)(bin[nibble / 2] | x);
			nibble++;
		}
		w_ext(w, TP_EXT_UUID, bin, 16);
		return 0;
	}
	if (uuid == TP_UUID_BIN) {
		if (v->s.n != 16)
			return -1;
		w_ext(w, TP_EXT_UUID, v->s.p, 16);
		return 0;
	}
	if (ctype == TP_CTYPE_VARBINARY ||
	    (ctype != TP_CTYPE_STRING && kind == PB_KIND_BYTES))
		w_bin(w, v->s.p, v->s.n);
	else
		w_str(w, v->s.p, v->s.n);
	return 0;
}

static int tl_message(td_ctx *c, mpw *w, int node_idx, const tv_msg *m);

/* tuple_value is nil (NULL; absent from a map) for field i. */
static int
tl_present(const tp_field *f, const tv_field *vf)
{
	switch (f->repr) {
	case TP_REPR_SCALAR:
		if (!vf->set)
			return !(f->optional || f->kind == TP_KIND_TIMESTAMP ||
			         f->uuid != TP_UUID_NONE);
		return !(f->uuid != TP_UUID_NONE && vf->v.s.n == 0);
	case TP_REPR_MSG_MAP:
	case TP_REPR_MSG_ARRAY:
		return vf->set;
	default:
		return 1;
	}
}

/* tuple_element: one element of a list or one value of a map<K,V>. */
static int
tl_element(td_ctx *c, mpw *w, const tp_field *f, uint8_t kind, int has,
           const tv_val *v)
{
	if (kind == PB_KIND_MESSAGE)
		return tl_message(c, w, f->sub, has ? v->m : NULL);
	if (kind == TP_KIND_TIMESTAMP)
		return has ? w_timestamp(w, v) : -1;
	return w_scalar(w, kind, TP_UUID_NONE, TP_CTYPE_OTHER, has, v);
}

/* tuple_value for a present field i. */
static int
tl_value(td_ctx *c, mpw *w, const tp_field *f, const tv_field *vf)
{
	switch (f->repr) {
	case TP_REPR_SCALAR:
		if (f->kind == TP_KIND_TIMESTAMP)
			return w_timestamp(w, &vf->v);
		return w_scalar(w, f->kind, f->uuid, f->ctype, vf->set, &vf->v);
	case TP_REPR_MSG_MAP:
	case TP_REPR_MSG_ARRAY:
		return tl_message(c, w, f->sub, vf->v.m);
	case TP_REPR_LIST:
		w_array(w, vf->count);
		for (const tv_node *e = vf->head; e != NULL; e = e->next)
			TD_TRY(tl_element(c, w, f, f->kind, 1, &e->v));
		return 0;
	default: /* TP_REPR_DICT */
		w_map(w, vf->count);
		for (const tv_node *e = vf->head; e != NULL; e = e->next) {
			uint8_t kk = f->key_kind;
			if (kk == PB_KIND_STRING)
				w_str(w, e->key.s.p, e->key.s.n);
			else if (kk == PB_KIND_BOOL)
				w_bool(w, e->key.u != 0);
			else if (td_signed(kk))
				w_int(w, (int64_t)e->key.u);
			else
				w_uint(w, e->key.u);
			TD_TRY(tl_element(c, w, f, f->value_kind, e->has_v, &e->v));
		}
		return 0;
	}
}

/* tuple_message: a nested message (m NULL: an empty one). */
static int
tl_message(td_ctx *c, mpw *w, int node_idx, const tv_msg *m)
{
	const tp_node *node = &c->plan->nodes[node_idx];
	static const tv_field unset;
	if (node->layout == TP_LAYOUT_MAP) {
		uint32_t count = 0;
		for (int i = 0; i < node->n; i++) {
			const tp_field *f = &node->fields[i];
			if (tl_present(f, m != NULL ? &m->f[f->dfield] : &unset))
				count++;
		}
		w_map(w, count);
		for (int i = 0; i < node->n; i++) {
			const tp_field *f = &node->fields[i];
			const tv_field *vf = m != NULL ? &m->f[f->dfield] : &unset;
			if (!tl_present(f, vf))
				continue;
			w_str(w, f->name, f->name_len);
			TD_TRY(tl_value(c, w, f, vf));
		}
		return 0;
	}
	w_array(w, node->width);
	for (uint32_t pos = 1; pos <= node->width; pos++) {
		int i = node->at[pos];
		if (i < 0) {
			w_nil(w);
			continue;
		}
		const tp_field *f = &node->fields[i];
		const tv_field *vf = m != NULL ? &m->f[f->dfield] : &unset;
		if (tl_present(f, vf))
			TD_TRY(tl_value(c, w, f, vf));
		else
			w_nil(w);
	}
	return 0;
}

/* The tuple: the top-level message and the raw fields' payloads. */
static int
tl_tuple(td_ctx *c, mpw *w, const tv_msg *m, const tv_field *raw)
{
	const tp_node *node = &c->plan->nodes[0];
	w_array(w, node->width);
	for (uint32_t col = 1; col <= node->width; col++) {
		int i = node->at[col];
		if (i < 0) {
			w_nil(w);
			continue;
		}
		const tp_field *f = &node->fields[i];
		if (f->repr == TP_REPR_RAW) {
			const tv_field *parts = &raw[i];
			if (!parts->set) {
				w_nil(w);
				continue;
			}
			uint32_t total = 0;
			for (const tv_node *e = parts->head; e != NULL; e = e->next)
				total += e->v.s.n;
			if (w->p == NULL) {
				w->size += mp_sizeof_bin(total);
				continue;
			}
			w->p = mp_encode_binl(w->p, total);
			for (const tv_node *e = parts->head; e != NULL; e = e->next) {
				memcpy(w->p, e->v.s.p, e->v.s.n);
				w->p += e->v.s.n;
			}
			continue;
		}
		const tv_field *vf = &m->f[f->dfield];
		if (tl_present(f, vf))
			TD_TRY(tl_value(c, w, f, vf));
		else
			w_nil(w);
	}
	return 0;
}

enum { TD_OP_NEW, TD_OP_REPLACE, TD_OP_INSERT };

/* Decode `bytes` and lay it out: the tuple's msgpack in `data`, `size`
 * bytes long, on success. */
static int
td_decode(td_ctx *c, const uint8_t *b, size_t len, char **data,
          size_t *size)
{
	const tp_node *root = &c->plan->nodes[0];
	tv_msg *m = tv_new(c, 0);
	if (m == NULL)
		return -1;
	TD_TRY(td_fields(c, 0, b, len, 0, m, c->plan->root_want));
	tv_field *raw = NULL;
	if (root->has_raw) {
		size_t sz = (size_t)root->n * sizeof(tv_field);
		raw = (tv_field *)td_alloc(c, sz);
		if (raw == NULL)
			return -1;
		memset(raw, 0, sz);
		TD_TRY(td_collect_raw(c, root, b, len, raw));
	}
	mpw w = {NULL, 0};
	TD_TRY(tl_tuple(c, &w, m, raw));
	char *buf = (char *)td_alloc(c, w.size);
	if (buf == NULL)
		return -1;
	mpw out = {buf, 0};
	TD_TRY(tl_tuple(c, &out, m, raw));
	*data = buf;
	*size = w.size;
	return 0;
}

int
pb_tuple_decode(lua_State *L)
{
	tp_plan *tp = (tp_plan *)luaL_checkudata(L, 1, TUPLE_PLAN_MT);
	const char *ops = luaL_checkstring(L, 3);
	int op;
	uint32_t space_id = 0;
	if (strcmp(ops, "new") == 0) {
		op = TD_OP_NEW;
	} else if (strcmp(ops, "replace") == 0 || strcmp(ops, "insert") == 0) {
		op = ops[0] == 'r' ? TD_OP_REPLACE : TD_OP_INSERT;
		lua_Number id = luaL_checknumber(L, 4);
		if (!(id >= 0) || !(id <= UINT32_MAX) ||
		    id != (lua_Number)(uint32_t)id)
			return luaL_argerror(L, 4, "space id expected");
		space_id = (uint32_t)id;
	} else {
		return luaL_argerror(L, 3, "'new', 'replace' or 'insert' "
		                     "expected");
	}
	/* Input that does not convert: the caller words the error. The
	 * Lua path checks the unbound columns before the bytes. */
	if (tp->nodes[0].n_unbound > 0 || lua_type(L, 2) != LUA_TSTRING) {
		lua_pushboolean(L, 0);
		return 1;
	}
	size_t len;
	const uint8_t *b = (const uint8_t *)lua_tolstring(L, 2, &len);

	td_ctx c;
	c.L = L;
	c.plan = tp;
	c.plan_idx = 1;
	c.oom = 0;
	size_t mark = box_region_used();
	char *data = NULL;
	size_t size = 0;
	if (td_decode(&c, b, len, &data, &size) != 0) {
		box_region_truncate(mark);
		if (c.oom)
			return luaT_error(L);
		lua_pushboolean(L, 0);
		return 1;
	}
	box_tuple_t *tuple = NULL;
	int rc;
	if (op == TD_OP_NEW) {
		tuple = box_tuple_new(box_tuple_format_default(), data,
		                      data + size);
		rc = tuple == NULL ? -1 : 0;
	} else if (op == TD_OP_REPLACE) {
		rc = box_replace(space_id, data, data + size, &tuple);
	} else {
		rc = box_insert(space_id, data, data + size, &tuple);
	}
	/* box copied the data into the tuple; the region is ours again. */
	box_region_truncate(mark);
	if (rc != 0)
		return luaT_error(L);
	lua_pushboolean(L, 1);
	if (tuple == NULL)
		lua_pushnil(L);
	else
		luaT_pushtuple(L, tuple);
	return 2;
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
