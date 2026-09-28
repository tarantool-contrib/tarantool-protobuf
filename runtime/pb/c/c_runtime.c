/*
 * c_runtime.c -- C-acceleration runtime for tarantool-protobuf.
 *
 * Descriptor -> plan compiler, plus the full encode/decode surface. Walks
 * a finalized Lua descriptor table and produces an opaque `pb_plan`
 * userdata, then encodes and decodes against it — scalars, messages,
 * groups, repeated/packed fields, maps, oneofs, and unknown-field
 * passthrough are all supported; features are added incrementally.
 *
 * Conventions follow docs/specs/c_accel_strategy.md.
 */

/* strdup is POSIX, not C99; declare we want the POSIX surface from
 * <string.h> before any system header pulls it in. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <module.h>
#include <lauxlib.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define PB_PLAN_MT      "pb.plan"
#define PB_ABI_VERSION  "1"

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

struct kind_info {
	const char *proto_type;
	uint8_t kind;
	uint8_t wire_type;
};

/* Lookup table keyed by proto3 field type string. Linear scan is fine —
 * a finalized descriptor calls this once per field at plan-compile time,
 * not per encode/decode. */
static const struct kind_info kind_table[] = {
	{"int32",    PB_KIND_INT32,    PB_WIRE_VARINT},
	{"int64",    PB_KIND_INT64,    PB_WIRE_VARINT},
	{"uint32",   PB_KIND_UINT32,   PB_WIRE_VARINT},
	{"uint64",   PB_KIND_UINT64,   PB_WIRE_VARINT},
	{"sint32",   PB_KIND_SINT32,   PB_WIRE_VARINT},
	{"sint64",   PB_KIND_SINT64,   PB_WIRE_VARINT},
	{"bool",     PB_KIND_BOOL,     PB_WIRE_VARINT},
	{"fixed32",  PB_KIND_FIXED32,  PB_WIRE_I32},
	{"sfixed32", PB_KIND_SFIXED32, PB_WIRE_I32},
	{"float",    PB_KIND_FLOAT,    PB_WIRE_I32},
	{"fixed64",  PB_KIND_FIXED64,  PB_WIRE_I64},
	{"sfixed64", PB_KIND_SFIXED64, PB_WIRE_I64},
	{"double",   PB_KIND_DOUBLE,   PB_WIRE_I64},
	{"string",   PB_KIND_STRING,   PB_WIRE_LEN},
	{"bytes",    PB_KIND_BYTES,    PB_WIRE_LEN},
};

static const struct kind_info *
lookup_kind(const char *proto_type)
{
	if (proto_type == NULL)
		return NULL;
	for (size_t i = 0; i < sizeof(kind_table) / sizeof(kind_table[0]); i++) {
		if (strcmp(kind_table[i].proto_type, proto_type) == 0)
			return &kind_table[i];
	}
	return NULL;
}

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

static void
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
 *  Plan lifecycle: alloc / free.                                    *
 * ---------------------------------------------------------------- */

static void
plan_free(lua_State *L, pb_plan *p)
{
	if (p->name != NULL)
		free(p->name);
	if (p->fields != NULL) {
		for (int i = 0; i < p->n_fields; i++) {
			if (p->fields[i].enum_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, p->fields[i].enum_ref);
			if (p->fields[i].full_name != NULL)
				free(p->fields[i].full_name);
		}
		free(p->fields);
	}
	if (p->extensions != NULL) {
		for (int i = 0; i < p->n_extensions; i++) {
			if (p->extensions[i].enum_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX,
				           p->extensions[i].enum_ref);
			if (p->extensions[i].full_name != NULL)
				free(p->extensions[i].full_name);
		}
		free(p->extensions);
	}
	if (p->oneofs != NULL) {
		for (int i = 0; i < p->n_oneofs; i++) {
			free(p->oneofs[i].name);
			free(p->oneofs[i].member_indices);
		}
		free(p->oneofs);
	}
	if (p->override_encode_ref != LUA_NOREF)
		luaL_unref(L, LUA_REGISTRYINDEX, p->override_encode_ref);
	if (p->override_decode_ref != LUA_NOREF)
		luaL_unref(L, LUA_REGISTRYINDEX, p->override_decode_ref);
	if (p->field_names_ref != LUA_NOREF)
		luaL_unref(L, LUA_REGISTRYINDEX, p->field_names_ref);
	if (p->sub_plans_ref != LUA_NOREF)
		luaL_unref(L, LUA_REGISTRYINDEX, p->sub_plans_ref);

	memset(p, 0, sizeof(*p));
	p->override_encode_ref = LUA_NOREF;
	p->override_decode_ref = LUA_NOREF;
	p->field_names_ref = LUA_NOREF;
	p->sub_plans_ref = LUA_NOREF;
}

static int
plan_gc(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	plan_free(L, p);
	return 0;
}

static int
plan_tostring(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	lua_pushfstring(L, "pb.plan: %s (n_fields=%d)",
	                p->name != NULL ? p->name : "(unnamed)",
	                p->n_fields);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  Field compilation.                                               *
 *                                                                  *
 *  Reads one descriptor-field table (at the top of the stack) and  *
 *  fills the corresponding pb_plan_field. Recurses into sub-message *
 *  plans by calling compile_plan_impl.                              *
 *                                                                  *
 *  Stack expectations on entry:                                     *
 *    -1: field-descriptor table (e.g. {name="foo", id=1, kind=...})*
 *    sub_plans_stack_idx: the sub-plans table being filled         *
 *                                                                  *
 *  Stack on exit: same (we pop everything we push).                *
 * ---------------------------------------------------------------- */

static int compile_plan_impl(lua_State *L, int desc_idx);

/* Append a sub-plan userdata (at -1) to the sub-plans table at
 * sub_plans_idx; return its 1-based index. Pops the userdata. */
static int
push_sub_plan(lua_State *L, int sub_plans_idx)
{
	int n = (int)lua_objlen(L, sub_plans_idx);
	lua_rawseti(L, sub_plans_idx, n + 1);
	return n + 1;
}

/* Resolve a sub-message descriptor (at stack idx `sub_desc_idx`) into a
 * 1-based index into the sub-plans table. Stack-neutral: pushes/pops the
 * intermediate desc copy and plan userdata internally. */
static int
resolve_sub_plan(lua_State *L, int sub_desc_idx, int sub_plans_idx)
{
	int saved_top = lua_gettop(L);
	/* compile_plan_impl is idempotent — if desc.c_plan exists it just
	 * leaves the cached userdata on top. */
	lua_pushvalue(L, sub_desc_idx);
	int dup_idx = lua_gettop(L);
	compile_plan_impl(L, dup_idx);
	if (!lua_isuserdata(L, -1))
		luaL_error(L, "compile_plan_impl did not return a userdata");
	int idx = push_sub_plan(L, sub_plans_idx); /* pops plan userdata */
	lua_settop(L, saved_top);                  /* drop sub_desc copy */
	return idx;
}

/* Compile one field. `f_desc_idx` is the absolute stack index of the
 * field descriptor table. `field` points at the pb_plan_field slot to
 * fill. `field_names_idx`, `sub_plans_idx` are absolute indices of the
 * field-names and sub-plans tables being populated. `field_idx_1based`
 * is the 1-based position used for the field-names lookup table. */
static void
compile_field(lua_State *L, int f_desc_idx, pb_plan_field *field,
              int field_names_idx, int sub_plans_idx, int field_idx_1based)
{
	memset(field, 0, sizeof(*field));
	field->enum_ref = LUA_NOREF;
	field->oneof_idx = -1;

	/* field number */
	lua_getfield(L, f_desc_idx, "id");
	if (!lua_isnumber(L, -1))
		luaL_error(L, "field descriptor missing 'id'");
	field->field_number = (uint32_t)lua_tointeger(L, -1);
	lua_pop(L, 1);

	/* name (interned in field_names_ref under field_idx_1based) */
	lua_getfield(L, f_desc_idx, "name");
	if (!lua_isstring(L, -1))
		luaL_error(L, "field descriptor missing 'name'");
	lua_pushvalue(L, -1);                       /* dup */
	lua_rawseti(L, field_names_idx, field_idx_1based);
	lua_pop(L, 1);

	/* repeated / packed / optional / required (proto2) */
	lua_getfield(L, f_desc_idx, "repeated");
	field->repeated = lua_toboolean(L, -1) ? 1 : 0;
	lua_pop(L, 1);
	lua_getfield(L, f_desc_idx, "packed");
	field->packed = lua_toboolean(L, -1) ? 1 : 0;
	lua_pop(L, 1);
	lua_getfield(L, f_desc_idx, "optional");
	field->optional = lua_toboolean(L, -1) ? 1 : 0;
	lua_pop(L, 1);
	lua_getfield(L, f_desc_idx, "required");
	field->required = lua_toboolean(L, -1) ? 1 : 0;
	lua_pop(L, 1);

	/* kind dispatch on desc.kind */
	lua_getfield(L, f_desc_idx, "kind");
	const char *kind_str = lua_tostring(L, -1);
	if (kind_str == NULL)
		luaL_error(L, "field descriptor missing 'kind'");

	uint8_t element_wire_type;

	if (strcmp(kind_str, "scalar") == 0) {
		lua_pop(L, 1); /* pop kind */
		lua_getfield(L, f_desc_idx, "proto_type");
		const char *pt = lua_tostring(L, -1);
		const struct kind_info *ki = lookup_kind(pt);
		if (ki == NULL)
			luaL_error(L, "unknown scalar proto_type: %s",
			           pt != NULL ? pt : "(nil)");
		field->kind = ki->kind;
		element_wire_type = ki->wire_type;
		lua_pop(L, 1);
	} else if (strcmp(kind_str, "enum") == 0) {
		lua_pop(L, 1);
		field->kind = PB_KIND_ENUM;
		element_wire_type = PB_WIRE_VARINT;
		lua_getfield(L, f_desc_idx, "enum");
		if (lua_istable(L, -1)) {
			field->enum_ref = luaL_ref(L, LUA_REGISTRYINDEX);
		} else {
			lua_pop(L, 1);
		}
	} else if (strcmp(kind_str, "message") == 0 ||
	           strcmp(kind_str, "group") == 0) {
		int is_group = (strcmp(kind_str, "group") == 0);
		lua_pop(L, 1);
		field->kind = PB_KIND_MESSAGE;
		field->is_group = is_group ? 1 : 0;
		/* Group wire-type is SGROUP at the field's tag; EGROUP is the
		 * closing bracket, pre-encoded separately for the encoder. */
		element_wire_type = is_group ? PB_WIRE_SGROUP : PB_WIRE_LEN;
		lua_getfield(L, f_desc_idx, "message");
		if (!lua_istable(L, -1))
			luaL_error(L, "%s field missing 'message' descriptor",
			           is_group ? "group" : "message");
		int sub_desc = lua_gettop(L);
		field->sub_plan_idx = resolve_sub_plan(L, sub_desc, sub_plans_idx);
		lua_pop(L, 1); /* sub-desc table */
	} else if (strcmp(kind_str, "map") == 0) {
		lua_pop(L, 1);
		field->kind = PB_KIND_MAP;
		element_wire_type = PB_WIRE_LEN;

		/* key */
		lua_getfield(L, f_desc_idx, "key");
		if (!lua_istable(L, -1))
			luaL_error(L, "map field missing 'key' descriptor");
		lua_getfield(L, -1, "proto_type");
		const struct kind_info *ki = lookup_kind(lua_tostring(L, -1));
		if (ki == NULL)
			luaL_error(L, "map key has unknown proto_type");
		field->map_key_kind = ki->kind;
		lua_pop(L, 2); /* proto_type + key */

		/* value */
		lua_getfield(L, f_desc_idx, "value");
		if (!lua_istable(L, -1))
			luaL_error(L, "map field missing 'value' descriptor");
		lua_getfield(L, -1, "kind");
		const char *vk = lua_tostring(L, -1);
		lua_pop(L, 1);
		if (vk != NULL && strcmp(vk, "scalar") == 0) {
			lua_getfield(L, -1, "proto_type");
			const struct kind_info *vki = lookup_kind(lua_tostring(L, -1));
			if (vki == NULL)
				luaL_error(L, "map value has unknown scalar proto_type");
			field->map_value_kind = vki->kind;
			lua_pop(L, 1);
		} else if (vk != NULL && strcmp(vk, "message") == 0) {
			field->map_value_kind = PB_KIND_MESSAGE;
			lua_getfield(L, -1, "message");
			if (lua_istable(L, -1)) {
				int sub_desc = lua_gettop(L);
				field->map_value_sub_plan_idx =
					resolve_sub_plan(L, sub_desc, sub_plans_idx);
			}
			lua_pop(L, 1);
		} else if (vk != NULL && strcmp(vk, "enum") == 0) {
			field->map_value_kind = PB_KIND_ENUM;
		} else {
			luaL_error(L, "map value has unknown kind: %s",
			           vk != NULL ? vk : "(nil)");
		}
		lua_pop(L, 1); /* value table */
	} else {
		luaL_error(L, "unknown field kind: %s", kind_str);
		return; /* unreachable */
	}

	/* Wire type: repeated+packed → LEN regardless of element type;
	 * repeated unpacked → element type per tag; singular → element.
	 * Groups can't be packed (LEN form), so this branch never fires for them. */
	if (field->repeated && field->packed) {
		field->wire_type = PB_WIRE_LEN;
	} else {
		field->wire_type = element_wire_type;
	}

	encode_tag(field->field_number, field->wire_type,
	           field->tag_bytes, &field->tag_len);
	if (field->is_group) {
		encode_tag(field->field_number, PB_WIRE_EGROUP,
		           field->egroup_tag_bytes, &field->egroup_tag_len);
	}
}

/* ---------------------------------------------------------------- *
 *  Oneof compilation.                                               *
 *                                                                  *
 *  desc.oneofs is the hash table {[name]=members}. We walk it and  *
 *  build pb_plan_oneof[]. For each member field, set its oneof_idx *
 *  to point back at the plan's oneof entry.                        *
 * ---------------------------------------------------------------- */

static int
find_field_by_name(pb_plan *p, lua_State *L, int field_names_idx,
                   const char *name)
{
	for (int i = 0; i < p->n_fields; i++) {
		lua_rawgeti(L, field_names_idx, i + 1);
		const char *fn = lua_tostring(L, -1);
		int match = (fn != NULL && strcmp(fn, name) == 0);
		lua_pop(L, 1);
		if (match) return i;
	}
	return -1;
}

static void
compile_oneofs(lua_State *L, pb_plan *p, int desc_idx, int field_names_idx)
{
	lua_getfield(L, desc_idx, "oneofs");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return;
	}

	/* First pass: count. */
	int count = 0;
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		count++;
		lua_pop(L, 1);
	}
	if (count == 0) {
		lua_pop(L, 1);
		return;
	}

	p->oneofs = (pb_plan_oneof *)calloc(count, sizeof(pb_plan_oneof));
	p->n_oneofs = count;

	int idx = 0;
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		/* key at -2 (oneof name), value at -1 (members array) */
		const char *oname = lua_tostring(L, -2);
		p->oneofs[idx].name = strdup(oname != NULL ? oname : "");

		int n_members = (int)lua_objlen(L, -1);
		p->oneofs[idx].n_members = n_members;
		p->oneofs[idx].member_indices = (int *)calloc(n_members, sizeof(int));

		for (int j = 0; j < n_members; j++) {
			lua_rawgeti(L, -1, j + 1);
			const char *mname = lua_tostring(L, -1);
			int fi = find_field_by_name(p, L, field_names_idx,
			                            mname != NULL ? mname : "");
			lua_pop(L, 1);
			p->oneofs[idx].member_indices[j] = fi;
			if (fi >= 0)
				p->fields[fi].oneof_idx = idx;
		}

		lua_pop(L, 1); /* value */
		idx++;
	}
	lua_pop(L, 1); /* oneofs table */
}

/* ---------------------------------------------------------------- *
 *  Main compile entry.                                              *
 *                                                                  *
 *  Idempotent. If desc.c_plan exists and is a pb.plan userdata,    *
 *  returns it. Otherwise allocates a new one, stashes it on        *
 *  desc.c_plan BEFORE recursing into sub-plans (breaks cycles for  *
 *  self-referencing messages like Person.friends → Person), then   *
 *  walks fields and oneofs.                                        *
 * ---------------------------------------------------------------- */

/* Lua 5.1 lacks lua_absindex; LuaJIT's compatibility layer too. */
static inline int
abs_idx(lua_State *L, int idx)
{
	if (idx < 0 && idx > LUA_REGISTRYINDEX)
		return lua_gettop(L) + idx + 1;
	return idx;
}

static int
compile_plan_impl(lua_State *L, int desc_idx)
{
	desc_idx = abs_idx(L, desc_idx);

	/* Idempotency check. */
	lua_getfield(L, desc_idx, "c_plan");
	if (lua_isuserdata(L, -1)) {
		/* Already compiled; leave on top of stack and pop the original
		 * desc-table push pattern wasn't done — caller still owns. */
		return 1;
	}
	lua_pop(L, 1);

	/* Allocate the plan userdata and stash it immediately. */
	pb_plan *p = (pb_plan *)lua_newuserdata(L, sizeof(pb_plan));
	memset(p, 0, sizeof(*p));
	p->override_encode_ref = LUA_NOREF;
	p->override_decode_ref = LUA_NOREF;
	p->field_names_ref = LUA_NOREF;
	p->sub_plans_ref = LUA_NOREF;

	luaL_getmetatable(L, PB_PLAN_MT);
	lua_setmetatable(L, -2);
	int plan_idx = lua_gettop(L);

	/* Stash on desc.c_plan first to break sub-message cycles. */
	lua_pushvalue(L, plan_idx);
	lua_setfield(L, desc_idx, "c_plan");

	/* desc.name */
	lua_getfield(L, desc_idx, "name");
	const char *dname = lua_tostring(L, -1);
	p->name = strdup(dname != NULL ? dname : "");
	lua_pop(L, 1);

	/* WKT override pointers — desc.encode / desc.decode. */
	lua_getfield(L, desc_idx, "encode");
	if (lua_isfunction(L, -1)) {
		p->has_override = 1;
		p->override_encode_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	} else {
		lua_pop(L, 1);
	}
	lua_getfield(L, desc_idx, "decode");
	if (lua_isfunction(L, -1)) {
		p->has_override = 1;
		p->override_decode_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	} else {
		lua_pop(L, 1);
	}

	/* Extension ranges (proto2). desc.extension_ranges = {{start, end}, ...} */
	lua_getfield(L, desc_idx, "extension_ranges");
	if (lua_istable(L, -1) && lua_objlen(L, -1) >= 1) {
		lua_rawgeti(L, -1, 1);
		if (lua_istable(L, -1)) {
			lua_rawgeti(L, -1, 1);
			p->extension_range_start = (int)lua_tointeger(L, -1);
			lua_pop(L, 1);
			lua_rawgeti(L, -1, 2);
			p->extension_range_end = (int)lua_tointeger(L, -1);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	/* If this descriptor has an override, we skip field-walk entirely —
	 * the override owns encode/decode and the field array is unused. */
	if (p->has_override) {
		return 1;
	}

	/* Create the field-names and sub-plans tables. */
	lua_newtable(L);
	int field_names_idx = lua_gettop(L);
	lua_newtable(L);
	int sub_plans_idx = lua_gettop(L);

	/* Walk desc.fields. */
	lua_getfield(L, desc_idx, "fields");
	if (!lua_istable(L, -1))
		luaL_error(L, "descriptor '%s' has no 'fields'",
		           p->name != NULL ? p->name : "?");
	int n_fields = (int)lua_objlen(L, -1);
	int fields_table_idx = lua_gettop(L);

	p->n_fields = n_fields;
	p->fields = (pb_plan_field *)calloc(
		n_fields > 0 ? n_fields : 1, sizeof(pb_plan_field));

	for (int i = 0; i < n_fields; i++) {
		lua_rawgeti(L, fields_table_idx, i + 1);
		int f_desc_idx = lua_gettop(L);
		compile_field(L, f_desc_idx, &p->fields[i],
		              field_names_idx, sub_plans_idx, i + 1);
		lua_pop(L, 1);
	}

	lua_pop(L, 1); /* fields table */

	/* Compile oneofs after fields so oneof_idx back-pointers can be set. */
	compile_oneofs(L, p, desc_idx, field_names_idx);

	/* Compile proto2 extensions (registered on this descriptor's
	 * extensions_list array). Each extension shares the field shape; we
	 * additionally cache its full_name string so encode can find the
	 * value in data._extensions[full_name] and decode can stash it back. */
	lua_getfield(L, desc_idx, "extensions_list");
	if (lua_istable(L, -1)) {
		int elist_idx = lua_gettop(L);
		int n_ext = (int)lua_objlen(L, elist_idx);
		if (n_ext > 0) {
			p->n_extensions = n_ext;
			p->extensions = (pb_plan_field *)calloc(
				n_ext, sizeof(pb_plan_field));
			for (int i = 0; i < n_ext; i++) {
				lua_rawgeti(L, elist_idx, i + 1);
				int e_desc_idx = lua_gettop(L);
				/* Reuse compile_field. Pass a throwaway 1-based
				 * index into field_names_idx — extension name
				 * caching there is harmless; we never look it
				 * up since we cache full_name separately. */
				compile_field(L, e_desc_idx,
				              &p->extensions[i],
				              field_names_idx, sub_plans_idx,
				              n_fields + i + 1);
				/* Cache full_name for _extensions[key] lookup. */
				lua_getfield(L, e_desc_idx, "full_name");
				const char *fn = lua_tostring(L, -1);
				p->extensions[i].full_name =
					strdup(fn != NULL ? fn : "");
				lua_pop(L, 1);
				lua_pop(L, 1); /* extension desc */
			}
		}
	}
	lua_pop(L, 1); /* extensions_list (table or nil) */

	/* Stash the field-names + sub-plans tables in the registry. */
	lua_pushvalue(L, sub_plans_idx);
	p->sub_plans_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pop(L, 1); /* sub_plans_idx (now unreferenced from stack) */

	lua_pushvalue(L, field_names_idx);
	p->field_names_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pop(L, 1);

	/* Stack now has just the plan userdata on top. */
	return 1;
}

static int
compile_plan_lua(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_settop(L, 1);
	return compile_plan_impl(L, 1);
}

/* ---------------------------------------------------------------- *
 *  Introspection (for the smoke test and future debugging).        *
 *                                                                  *
 *  These are intentionally lean — enough to let a Lua test assert  *
 *  the plan-build produced sensible values without a C-side test   *
 *  harness.                                                         *
 * ---------------------------------------------------------------- */

static int
plan_n_fields(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	lua_pushinteger(L, p->n_fields);
	return 1;
}

static int
plan_name(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	lua_pushstring(L, p->name != NULL ? p->name : "");
	return 1;
}

static int
plan_field_info(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	int i = luaL_checkint(L, 2);
	if (i < 1 || i > p->n_fields)
		return luaL_error(L, "field index %d out of range [1, %d]",
		                  i, p->n_fields);
	pb_plan_field *f = &p->fields[i - 1];

	lua_createtable(L, 0, 9);

	lua_pushinteger(L, f->field_number);
	lua_setfield(L, -2, "field_number");

	lua_pushinteger(L, f->wire_type);
	lua_setfield(L, -2, "wire_type");

	lua_pushinteger(L, f->kind);
	lua_setfield(L, -2, "kind");

	lua_pushboolean(L, f->repeated);
	lua_setfield(L, -2, "repeated");

	lua_pushboolean(L, f->packed);
	lua_setfield(L, -2, "packed");

	lua_pushboolean(L, f->optional);
	lua_setfield(L, -2, "optional");

	lua_pushinteger(L, f->sub_plan_idx);
	lua_setfield(L, -2, "sub_plan_idx");

	lua_pushinteger(L, f->oneof_idx);
	lua_setfield(L, -2, "oneof_idx");

	lua_pushlstring(L, (const char *)f->tag_bytes, f->tag_len);
	lua_setfield(L, -2, "tag_bytes");

	/* Field name from cached table. */
	lua_rawgeti(L, LUA_REGISTRYINDEX, p->field_names_ref);
	lua_rawgeti(L, -1, i);
	lua_remove(L, -2);
	lua_setfield(L, -2, "name");

	/* Map kinds, if any. */
	if (f->kind == PB_KIND_MAP) {
		lua_pushinteger(L, f->map_key_kind);
		lua_setfield(L, -2, "map_key_kind");
		lua_pushinteger(L, f->map_value_kind);
		lua_setfield(L, -2, "map_value_kind");
		lua_pushinteger(L, f->map_value_sub_plan_idx);
		lua_setfield(L, -2, "map_value_sub_plan_idx");
	}

	return 1;
}

static int
plan_n_oneofs(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	lua_pushinteger(L, p->n_oneofs);
	return 1;
}

static int
plan_oneof_info(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	int i = luaL_checkint(L, 2);
	if (i < 1 || i > p->n_oneofs)
		return luaL_error(L, "oneof index %d out of range [1, %d]",
		                  i, p->n_oneofs);
	pb_plan_oneof *o = &p->oneofs[i - 1];

	lua_createtable(L, 0, 2);
	lua_pushstring(L, o->name != NULL ? o->name : "");
	lua_setfield(L, -2, "name");

	lua_createtable(L, o->n_members, 0);
	for (int j = 0; j < o->n_members; j++) {
		lua_pushinteger(L, o->member_indices[j]);
		lua_rawseti(L, -2, j + 1);
	}
	lua_setfield(L, -2, "member_indices");

	return 1;
}

static int
plan_has_override(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	lua_pushboolean(L, p->has_override);
	return 1;
}

static int
plan_sub_plan(lua_State *L)
{
	pb_plan *p = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	int i = luaL_checkint(L, 2);
	if (p->sub_plans_ref == LUA_NOREF || i < 1) {
		lua_pushnil(L);
		return 1;
	}
	lua_rawgeti(L, LUA_REGISTRYINDEX, p->sub_plans_ref);
	lua_rawgeti(L, -1, i);
	lua_remove(L, -2);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  Encode.                                                          *
 *                                                                  *
 *  Covers singular scalars, singular sub-messages, repeated/packed  *
 *  fields, and maps (see encode_repeated_field / encode_map_field   *
 *  below).                                                          *
 *                                                                  *
 *  Buffer strategy: a 4KB stack-backed scratch buffer that promotes *
 *  to a Lua userdata (GC'd automatically) on overflow. Using        *
 *  `lua_newuserdata` for heap growth means a luaL_error mid-encode  *
 *  doesn't leak — the userdata is still on the stack at the unwind  *
 *  point and gets collected normally.                               *
 *                                                                  *
 *  Recursion shape: encode_body is called once per message; sub-    *
 *  message fields recurse by allocating a fresh enc_buf on the C    *
 *  stack and re-entering encode_body with the sub-plan. The parent's *
 *  heap_idx is force-established before recursing so it survives    *
 *  the lua_settop cleanup at sub-encode exit (see                   *
 *  encode_submessage_field for the contract).                       *
 * ---------------------------------------------------------------- */

#define ENC_STACK_BUF 4096

typedef struct enc_buf {
	uint8_t  stack[ENC_STACK_BUF];
	uint8_t *heap;       /* pointer into Lua userdata when grown; NULL while on stack */
	int      heap_idx;   /* stack slot of the userdata; 0 if not yet on heap */
	size_t   cap;
	size_t   used;
} enc_buf;

static inline uint8_t *
ebuf_base(enc_buf *b)
{
	return b->heap != NULL ? b->heap : b->stack;
}

static void
ebuf_init(enc_buf *b)
{
	b->heap = NULL;
	b->heap_idx = 0;
	b->cap = ENC_STACK_BUF;
	b->used = 0;
}

static void
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

/* Read a Lua value as uint64. Mirrors wire.lua's to_uint64: negative
 * Lua numbers are sign-extended through int64 (proto3 wire spec for
 * int32 fields). int64/uint64 cdata flow through luaL_touint64. */
static uint64_t
to_uint64_at(lua_State *L, int idx)
{
	if (lua_type(L, idx) == LUA_TNUMBER) {
		double d = lua_tonumber(L, idx);
		if (d < 0)
			return (uint64_t)(int64_t)d;
		return (uint64_t)d;
	}
	return luaL_touint64(L, idx);
}

static int32_t
to_int32_at(lua_State *L, int idx)
{
	if (lua_type(L, idx) == LUA_TNUMBER)
		return (int32_t)lua_tointeger(L, idx);
	return (int32_t)luaL_toint64(L, idx);
}

static int64_t
to_int64_at(lua_State *L, int idx)
{
	if (lua_type(L, idx) == LUA_TNUMBER)
		return (int64_t)lua_tonumber(L, idx);
	return luaL_toint64(L, idx);
}

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

/* Resolve an enum field's Lua value to its int32 ordinal. Accepts
 * numbers (returned directly), cdata int64 (downcast), or strings
 * (looked up in field->enum_ref's by_name table). Mirrors the
 * `if type(v) == 'string' then nv = M.Status[v]` branch in mode=full. */
static int32_t
enum_value_at(lua_State *L, pb_plan_field *f, int idx)
{
	int t = lua_type(L, idx);
	if (t == LUA_TSTRING) {
		const char *s = lua_tostring(L, idx);
		if (f->enum_ref == LUA_NOREF)
			luaL_error(L, "enum field '%s' has no enum descriptor", s);
		lua_rawgeti(L, LUA_REGISTRYINDEX, f->enum_ref);
		lua_getfield(L, -1, "by_name");
		if (!lua_istable(L, -1)) {
			luaL_error(L, "enum descriptor missing by_name");
		}
		lua_pushvalue(L, idx);
		lua_rawget(L, -2);
		if (lua_isnil(L, -1)) {
			luaL_error(L, "unknown enum value '%s'", s);
		}
		int32_t v = (int32_t)lua_tointeger(L, -1);
		lua_pop(L, 3); /* value + by_name + desc */
		return v;
	}
	return (int32_t)to_int64_at(L, idx);
}

/* Encode one scalar/enum/string field. Returns 1 if bytes were
 * written, 0 if the value collapsed to its proto3 default and was
 * suppressed. Zero-suppression is skipped for proto3-optional AND
 * when `force_emit` is non-zero (used by repeated-unpacked, where
 * every element must reach the wire regardless of value). */
static int
encode_one_field(lua_State *L, enc_buf *b, pb_plan_field *f, int val_idx,
                 int force_emit)
{
	int suppress = !force_emit && !f->optional;

	switch (f->kind) {
	case PB_KIND_INT32:
	case PB_KIND_INT64:
	case PB_KIND_UINT32:
	case PB_KIND_UINT64: {
		uint64_t u = to_uint64_at(L, val_idx);
		if (suppress && u == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 10);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, u);
		return 1;
	}
	case PB_KIND_SINT32: {
		int32_t s = to_int32_at(L, val_idx);
		if (suppress && s == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 5);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, zigzag32(s));
		return 1;
	}
	case PB_KIND_SINT64: {
		int64_t s = to_int64_at(L, val_idx);
		if (suppress && s == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 10);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, zigzag64(s));
		return 1;
	}
	case PB_KIND_BOOL: {
		int truthy = lua_toboolean(L, val_idx);
		if (suppress && !truthy) return 0;
		ebuf_reserve(L, b, f->tag_len + 1);
		ebuf_put_tag(b, f);
		ebuf_put_byte(b, truthy ? 1 : 0);
		return 1;
	}
	case PB_KIND_FIXED32:
	case PB_KIND_SFIXED32: {
		uint64_t u = to_uint64_at(L, val_idx);
		uint32_t u32 = (uint32_t)u;
		if (suppress && u32 == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 4);
		ebuf_put_tag(b, f);
		ebuf_put_fixed32(b, u32);
		return 1;
	}
	case PB_KIND_FIXED64:
	case PB_KIND_SFIXED64: {
		uint64_t u = to_uint64_at(L, val_idx);
		if (suppress && u == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 8);
		ebuf_put_tag(b, f);
		ebuf_put_fixed64(b, u);
		return 1;
	}
	case PB_KIND_FLOAT: {
		double d = lua_tonumber(L, val_idx);
		uint32_t u = f32_to_u32((float)d);
		/* +0.0 -> u==0 (skip); -0.0 -> u==0x80000000 (emit). Matches the
		 * Lua-side `(v ~= 0 or 1/v == -math.huge)` guard. */
		if (suppress && u == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 4);
		ebuf_put_tag(b, f);
		ebuf_put_fixed32(b, u);
		return 1;
	}
	case PB_KIND_DOUBLE: {
		double d = lua_tonumber(L, val_idx);
		uint64_t u = f64_to_u64(d);
		if (suppress && u == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 8);
		ebuf_put_tag(b, f);
		ebuf_put_fixed64(b, u);
		return 1;
	}
	case PB_KIND_ENUM: {
		int32_t e = enum_value_at(L, f, val_idx);
		if (suppress && e == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 10);
		ebuf_put_tag(b, f);
		/* enum is wire-equivalent to int32: sign-extend to uint64 then varint. */
		ebuf_put_varint(b, (uint64_t)(int64_t)e);
		return 1;
	}
	case PB_KIND_STRING:
	case PB_KIND_BYTES: {
		if (lua_type(L, val_idx) != LUA_TSTRING)
			luaL_error(L, "string/bytes field requires a string value");
		size_t len;
		const char *s = lua_tolstring(L, val_idx, &len);
		if (suppress && len == 0) return 0;
		ebuf_reserve(L, b, f->tag_len + 10 + len);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, (uint64_t)len);
		if (len > 0)
			ebuf_put_bytes(b, (const uint8_t *)s, len);
		return 1;
	}
	default:
		/* Map fields are handled by encode_map_field; message singular
		 * goes through encode_submessage_field; repeated dispatches at
		 * the field-walk level. */
		return 0;
	}
}

/* Encode one element of a packed scalar/enum/bool field into `b` —
 * raw value bytes only, no tag. Mirrors encode_one_field's per-kind
 * value emission with suppression always off. Length-delimited kinds
 * (STRING/BYTES/MESSAGE) are not packable per spec — caller must
 * dispatch them elsewhere. */
static void
encode_packed_element_at(lua_State *L, enc_buf *b, pb_plan_field *f,
                         int val_idx)
{
	switch (f->kind) {
	case PB_KIND_INT32:
	case PB_KIND_INT64:
	case PB_KIND_UINT32:
	case PB_KIND_UINT64: {
		uint64_t u = to_uint64_at(L, val_idx);
		ebuf_reserve(L, b, 10);
		ebuf_put_varint(b, u);
		return;
	}
	case PB_KIND_SINT32: {
		int32_t s = to_int32_at(L, val_idx);
		ebuf_reserve(L, b, 5);
		ebuf_put_varint(b, zigzag32(s));
		return;
	}
	case PB_KIND_SINT64: {
		int64_t s = to_int64_at(L, val_idx);
		ebuf_reserve(L, b, 10);
		ebuf_put_varint(b, zigzag64(s));
		return;
	}
	case PB_KIND_BOOL: {
		int truthy = lua_toboolean(L, val_idx);
		ebuf_reserve(L, b, 1);
		ebuf_put_byte(b, truthy ? 1 : 0);
		return;
	}
	case PB_KIND_FIXED32:
	case PB_KIND_SFIXED32: {
		uint64_t u = to_uint64_at(L, val_idx);
		ebuf_reserve(L, b, 4);
		ebuf_put_fixed32(b, (uint32_t)u);
		return;
	}
	case PB_KIND_FIXED64:
	case PB_KIND_SFIXED64: {
		uint64_t u = to_uint64_at(L, val_idx);
		ebuf_reserve(L, b, 8);
		ebuf_put_fixed64(b, u);
		return;
	}
	case PB_KIND_FLOAT: {
		double d = lua_tonumber(L, val_idx);
		ebuf_reserve(L, b, 4);
		ebuf_put_fixed32(b, f32_to_u32((float)d));
		return;
	}
	case PB_KIND_DOUBLE: {
		double d = lua_tonumber(L, val_idx);
		ebuf_reserve(L, b, 8);
		ebuf_put_fixed64(b, f64_to_u64(d));
		return;
	}
	case PB_KIND_ENUM: {
		int32_t e = enum_value_at(L, f, val_idx);
		ebuf_reserve(L, b, 10);
		ebuf_put_varint(b, (uint64_t)(int64_t)e);
		return;
	}
	default:
		luaL_error(L, "kind %d not packable", (int)f->kind);
	}
}

/* ---------------------------------------------------------------- *
 *  Map helpers.                                                      *
 *                                                                  *
 *  A map<K,V> field is wire-encoded as a repeated message with a   *
 *  synthetic Entry { key=1; value=2 } shape. Each entry payload    *
 *  contains zero/one key followed by zero/one value (defaults are  *
 *  proto3-elided on encode and re-defaulted on decode).            *
 *                                                                  *
 *  These helpers work with raw kind values (uint8_t) rather than   *
 *  pb_plan_field pointers because map K and V are not full         *
 *  pb_plan_fields in the plan — only their kinds are recorded.     *
 *  Enum values are accepted only as numeric ordinals (no enum_ref   *
 *  is stored per map value, so map<K, enum V> with string-form     *
 *  enums is not supported here).                                   *
 * ---------------------------------------------------------------- */

static uint8_t
wire_type_for_kind(uint8_t kind)
{
	switch (kind) {
	case PB_KIND_INT32: case PB_KIND_INT64:
	case PB_KIND_UINT32: case PB_KIND_UINT64:
	case PB_KIND_SINT32: case PB_KIND_SINT64:
	case PB_KIND_BOOL:  case PB_KIND_ENUM:
		return PB_WIRE_VARINT;
	case PB_KIND_FIXED32: case PB_KIND_SFIXED32: case PB_KIND_FLOAT:
		return PB_WIRE_I32;
	case PB_KIND_FIXED64: case PB_KIND_SFIXED64: case PB_KIND_DOUBLE:
		return PB_WIRE_I64;
	case PB_KIND_STRING: case PB_KIND_BYTES: case PB_KIND_MESSAGE:
		return PB_WIRE_LEN;
	default:
		return 0;
	}
}

/* Write a single value into `b` for the given kind. No tag, no length-
 * prefix for non-LEN kinds. STRING/BYTES include the varint length per
 * wire spec. MESSAGE is NOT handled here — sub-message values need a
 * sub-plan and recurse through encode_body. */
static void
encode_kind_value(lua_State *L, enc_buf *b, uint8_t kind, int val_idx)
{
	switch (kind) {
	case PB_KIND_INT32:
	case PB_KIND_INT64:
	case PB_KIND_UINT32:
	case PB_KIND_UINT64: {
		uint64_t u = to_uint64_at(L, val_idx);
		ebuf_reserve(L, b, 10);
		ebuf_put_varint(b, u);
		return;
	}
	case PB_KIND_SINT32: {
		int32_t s = to_int32_at(L, val_idx);
		ebuf_reserve(L, b, 5);
		ebuf_put_varint(b, zigzag32(s));
		return;
	}
	case PB_KIND_SINT64: {
		int64_t s = to_int64_at(L, val_idx);
		ebuf_reserve(L, b, 10);
		ebuf_put_varint(b, zigzag64(s));
		return;
	}
	case PB_KIND_BOOL: {
		int truthy = lua_toboolean(L, val_idx);
		ebuf_reserve(L, b, 1);
		ebuf_put_byte(b, truthy ? 1 : 0);
		return;
	}
	case PB_KIND_FIXED32:
	case PB_KIND_SFIXED32: {
		uint64_t u = to_uint64_at(L, val_idx);
		ebuf_reserve(L, b, 4);
		ebuf_put_fixed32(b, (uint32_t)u);
		return;
	}
	case PB_KIND_FIXED64:
	case PB_KIND_SFIXED64: {
		uint64_t u = to_uint64_at(L, val_idx);
		ebuf_reserve(L, b, 8);
		ebuf_put_fixed64(b, u);
		return;
	}
	case PB_KIND_FLOAT: {
		double d = lua_tonumber(L, val_idx);
		ebuf_reserve(L, b, 4);
		ebuf_put_fixed32(b, f32_to_u32((float)d));
		return;
	}
	case PB_KIND_DOUBLE: {
		double d = lua_tonumber(L, val_idx);
		ebuf_reserve(L, b, 8);
		ebuf_put_fixed64(b, f64_to_u64(d));
		return;
	}
	case PB_KIND_ENUM: {
		int32_t e = (int32_t)to_int64_at(L, val_idx);
		ebuf_reserve(L, b, 10);
		ebuf_put_varint(b, (uint64_t)(int64_t)e);
		return;
	}
	case PB_KIND_STRING:
	case PB_KIND_BYTES: {
		size_t len;
		const char *s = lua_tolstring(L, val_idx, &len);
		if (s == NULL)
			luaL_error(L, "map string/bytes value must be a string");
		ebuf_reserve(L, b, 10 + len);
		ebuf_put_varint(b, (uint64_t)len);
		if (len > 0)
			ebuf_put_bytes(b, (const uint8_t *)s, len);
		return;
	}
	default:
		luaL_error(L, "encode_kind_value: unsupported kind %d",
		           (int)kind);
	}
}

/* Proto3 default predicate for a Lua value of a given kind. Used to
 * elide key/value bytes in map entries when they collapse to the type
 * zero, matching the runtime Lua codec's `is_default_scalar` behavior. */
static int
value_is_default_kind(lua_State *L, uint8_t kind, int val_idx)
{
	switch (kind) {
	case PB_KIND_INT32: case PB_KIND_UINT32:
	case PB_KIND_SINT32: case PB_KIND_FIXED32: case PB_KIND_SFIXED32:
	case PB_KIND_ENUM:
		if (lua_type(L, val_idx) == LUA_TNUMBER)
			return lua_tonumber(L, val_idx) == 0;
		return luaL_toint64(L, val_idx) == 0;
	case PB_KIND_INT64: case PB_KIND_UINT64:
	case PB_KIND_SINT64: case PB_KIND_FIXED64: case PB_KIND_SFIXED64:
		if (lua_type(L, val_idx) == LUA_TNUMBER)
			return lua_tonumber(L, val_idx) == 0;
		return luaL_toint64(L, val_idx) == 0;
	case PB_KIND_BOOL:
		return !lua_toboolean(L, val_idx);
	case PB_KIND_FLOAT:
	case PB_KIND_DOUBLE: {
		double d = lua_tonumber(L, val_idx);
		if (d != 0.0) return 0;
		/* -0.0 still emits — its bit pattern is non-zero. */
		union { double d; uint64_t u; } pun;
		pun.d = d;
		return pun.u == 0;
	}
	case PB_KIND_STRING:
	case PB_KIND_BYTES: {
		size_t len;
		lua_tolstring(L, val_idx, &len);
		return len == 0;
	}
	default:
		return 0;
	}
}

/* Push the proto3 zero value for the given kind. MESSAGE pushes an
 * empty table — used as a placeholder before the message decode body
 * replaces it. */
static void
push_default_for_kind(lua_State *L, uint8_t kind)
{
	switch (kind) {
	case PB_KIND_BOOL:
		lua_pushboolean(L, 0); return;
	case PB_KIND_STRING:
	case PB_KIND_BYTES:
		lua_pushlstring(L, "", 0); return;
	case PB_KIND_INT64:   luaL_pushint64(L, 0); return;
	case PB_KIND_UINT64:  luaL_pushuint64(L, 0); return;
	case PB_KIND_SINT64:  luaL_pushint64(L, 0); return;
	case PB_KIND_FIXED64: luaL_pushuint64(L, 0); return;
	case PB_KIND_SFIXED64: luaL_pushint64(L, 0); return;
	case PB_KIND_MESSAGE:
		lua_newtable(L); return;
	default:
		/* int32/uint32/sint32/fixed32/sfixed32/enum/float/double → 0 */
		lua_pushinteger(L, 0); return;
	}
}

/* Forward decls for the recursive encode pair. */
static void encode_body(lua_State *L, enc_buf *b, pb_plan *plan, int msg_idx);
static void encode_submessage_field(lua_State *L, enc_buf *b, pb_plan *plan,
                                    pb_plan_field *f, int val_idx);
static void encode_group_field(lua_State *L, enc_buf *b, pb_plan *plan,
                                pb_plan_field *f, int val_idx);
static void encode_map_field(lua_State *L, enc_buf *b, pb_plan *plan,
                              pb_plan_field *f, int val_idx);
static void encode_extension(lua_State *L, enc_buf *b, pb_plan *plan,
                              pb_plan_field *ext, int val_idx);

/* Encode a repeated field's elements into `b`. Dispatches on element
 * kind and the `packed` plan flag:
 *   - packed scalar/enum/bool → single tag(LEN) + varint(len) + tight
 *     payload built in a stack-backed sub-buffer
 *   - unpacked scalar/enum/bool → per-element tag(elem_wire) + value
 *   - string/bytes → per-element tag(LEN) + varint(len) + bytes
 *     (string/bytes are never packable per spec)
 *   - message → per-element tag(LEN) + len-prefix + nested body via
 *     encode_submessage_field
 *
 * Empty arrays produce nothing — proto3 wire spec treats an absent
 * repeated field and an empty one identically.
 *
 * Sub-buffer cleanup follows encode_submessage_field's contract: the
 * parent's heap is force-established before allocating the sub-buffer
 * so the parent's heap_idx sits below saved_top and survives the final
 * lua_settop. */
static void
encode_repeated_field(lua_State *L, enc_buf *b, pb_plan *plan,
                      pb_plan_field *f, int val_idx)
{
	val_idx = abs_idx(L, val_idx);
	int n = (int)lua_objlen(L, val_idx);
	if (n == 0)
		return;

	if (f->kind == PB_KIND_MESSAGE) {
		if (f->is_group) {
			for (int i = 1; i <= n; i++) {
				lua_rawgeti(L, val_idx, i);
				int elem = lua_gettop(L);
				encode_group_field(L, b, plan, f, elem);
				lua_pop(L, 1);
			}
			return;
		}
		for (int i = 1; i <= n; i++) {
			lua_rawgeti(L, val_idx, i);
			int elem = lua_gettop(L);
			encode_submessage_field(L, b, plan, f, elem);
			lua_pop(L, 1);
		}
		return;
	}

	if (f->packed) {
		if (b->heap_idx == 0)
			ebuf_grow(L, b, 1);
		int saved_top = lua_gettop(L);

		enc_buf sub;
		ebuf_init(&sub);
		for (int i = 1; i <= n; i++) {
			lua_rawgeti(L, val_idx, i);
			encode_packed_element_at(L, &sub, f, lua_gettop(L));
			lua_pop(L, 1);
		}

		ebuf_reserve(L, b, f->tag_len + 10 + sub.used);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, (uint64_t)sub.used);
		if (sub.used > 0)
			ebuf_put_bytes(b, ebuf_base(&sub), sub.used);

		lua_settop(L, saved_top);
		return;
	}

	/* Unpacked: per-element tag + value. string/bytes flow through
	 * encode_one_field too — its STRING/BYTES branch already emits
	 * `tag + varint(len) + bytes`, which is exactly the unpacked
	 * length-delimited element shape. */
	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, val_idx, i);
		encode_one_field(L, b, f, lua_gettop(L), /* force_emit */ 1);
		lua_pop(L, 1);
	}
}

/* Encode one singular sub-message field into the parent buffer `b`.
 * Lifecycle / stack-management contract:
 *   - Parent's heap is force-established (one 8KB grow) BEFORE recursing
 *     so b->heap_idx is below the saved_top. This way the final
 *     ebuf_reserve on the parent can only either re-use b->heap_idx via
 *     lua_replace (no new stack slot) or — if no further grow is
 *     needed — leave the stack alone. Either way, lua_settop(L,
 *     saved_top) at the end is safe.
 *   - sub-buf is a fresh stack-backed enc_buf; its potential heap
 *     userdata is on the Lua stack above saved_top and is dropped by
 *     the lua_settop. */
static void
encode_submessage_field(lua_State *L, enc_buf *b, pb_plan *plan,
                        pb_plan_field *f, int val_idx)
{
	if (plan->sub_plans_ref == LUA_NOREF)
		luaL_error(L, "plan '%s' has no sub-plans table",
		           plan->name != NULL ? plan->name : "?");

	/* Force parent's heap to exist before the sub-encode allocates. */
	if (b->heap_idx == 0)
		ebuf_grow(L, b, 1);

	val_idx = abs_idx(L, val_idx);
	int saved_top = lua_gettop(L);

	lua_rawgeti(L, LUA_REGISTRYINDEX, plan->sub_plans_ref);
	lua_rawgeti(L, -1, f->sub_plan_idx);
	pb_plan *subplan = (pb_plan *)lua_touserdata(L, -1);
	if (subplan == NULL)
		luaL_error(L, "sub-plan at index %d is not a userdata",
		           f->sub_plan_idx);

	/* WKT override: call desc.encode(value) for the body bytes; emit
	 * tag + len + body verbatim. Accepts any Lua type (datetime cdata,
	 * number, string, table) per the override's contract. */
	if (subplan->override_encode_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		            subplan->override_encode_ref);
		lua_pushvalue(L, val_idx);
		lua_call(L, 1, 1);
		if (lua_type(L, -1) != LUA_TSTRING)
			luaL_error(L,
				"WKT encode for '%s' returned non-string",
				subplan->name != NULL ? subplan->name : "?");
		size_t blen;
		const char *bp = lua_tolstring(L, -1, &blen);
		ebuf_reserve(L, b, f->tag_len + 10 + blen);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, (uint64_t)blen);
		if (blen > 0)
			ebuf_put_bytes(b, (const uint8_t *)bp, blen);
		lua_settop(L, saved_top);
		return;
	}

	if (lua_type(L, val_idx) != LUA_TTABLE)
		luaL_error(L, "message field requires a table value");

	enc_buf sub;
	ebuf_init(&sub);
	encode_body(L, &sub, subplan, val_idx);

	/* Write tag + length-varint + body into parent. Parent regrowth
	 * here goes through lua_replace at b->heap_idx (safely below
	 * saved_top) — no stack-frame disruption. */
	ebuf_reserve(L, b, f->tag_len + 10 + sub.used);
	ebuf_put_tag(b, f);
	ebuf_put_varint(b, (uint64_t)sub.used);
	if (sub.used > 0)
		ebuf_put_bytes(b, ebuf_base(&sub), sub.used);

	lua_settop(L, saved_top);
}

/* Encode one singular proto2 group field: SGROUP tag, nested body bytes
 * verbatim (no length prefix), EGROUP tag. The body is built into a fresh
 * sub-buffer so the SGROUP/EGROUP bracket lands on the parent in one shot;
 * the lifecycle contract is identical to encode_submessage_field. */
static void
encode_group_field(lua_State *L, enc_buf *b, pb_plan *plan,
                    pb_plan_field *f, int val_idx)
{
	if (plan->sub_plans_ref == LUA_NOREF)
		luaL_error(L, "plan '%s' has no sub-plans table",
		           plan->name != NULL ? plan->name : "?");

	if (b->heap_idx == 0)
		ebuf_grow(L, b, 1);

	val_idx = abs_idx(L, val_idx);
	int saved_top = lua_gettop(L);

	lua_rawgeti(L, LUA_REGISTRYINDEX, plan->sub_plans_ref);
	lua_rawgeti(L, -1, f->sub_plan_idx);
	pb_plan *subplan = (pb_plan *)lua_touserdata(L, -1);
	if (subplan == NULL)
		luaL_error(L, "group sub-plan at index %d is not a userdata",
		           f->sub_plan_idx);

	if (lua_type(L, val_idx) != LUA_TTABLE)
		luaL_error(L, "group field requires a table value");

	enc_buf sub;
	ebuf_init(&sub);
	encode_body(L, &sub, subplan, val_idx);

	/* SGROUP tag + body + EGROUP tag (no length prefix). */
	ebuf_reserve(L, b, f->tag_len + sub.used + f->egroup_tag_len);
	ebuf_put_tag(b, f);
	if (sub.used > 0)
		ebuf_put_bytes(b, ebuf_base(&sub), sub.used);
	memcpy(ebuf_base(b) + b->used, f->egroup_tag_bytes, f->egroup_tag_len);
	b->used += f->egroup_tag_len;

	lua_settop(L, saved_top);
}

/* Encode one proto2 extension value into the parent buffer `b`. The
 * extension field shape mirrors a regular field; for the encode dispatch
 * we route through the same singular/repeated/message/group paths used
 * by the field-walk. Always force-emit (proto2 extensions are
 * presence-tracked: a user-set zero must reach the wire). */
static void
encode_extension(lua_State *L, enc_buf *b, pb_plan *plan,
                  pb_plan_field *ext, int val_idx)
{
	val_idx = abs_idx(L, val_idx);
	if (ext->repeated) {
		if (lua_type(L, val_idx) != LUA_TTABLE)
			luaL_error(L,
				"repeated extension '%s' requires a table value",
				ext->full_name != NULL ? ext->full_name : "?");
		encode_repeated_field(L, b, plan, ext, val_idx);
		return;
	}
	if (ext->kind == PB_KIND_MESSAGE) {
		if (ext->is_group)
			encode_group_field(L, b, plan, ext, val_idx);
		else
			encode_submessage_field(L, b, plan, ext, val_idx);
		return;
	}
	encode_one_field(L, b, ext, val_idx, /* force_emit */ 1);
}

/* Encode a map<K,V> field into `b`.
 *
 * Wire shape: each (k, v) pair becomes a length-delimited entry sub-
 * message with synthetic field-1 key + field-2 value. Proto3 default-
 * elision applies independently to key and value (key=='' or k==0 skip
 * the key tag; v==zero skips the value tag). Sub-message values are
 * always emitted regardless of contents (proto3 message presence).
 *
 * Iteration uses `lua_next` (pairs semantics) — this is the documented
 * exception to the ipairs-only hot-path rule (map fields must walk
 * user-provided keys with pairs; see docs/codegen.md). Map encode is
 * not on the JIT-traced hot path; hash iteration is the only way to
 * walk user-provided table keys.
 *
 * Stack/buffer lifecycle mirrors encode_submessage_field: the parent's
 * heap is force-established before any per-entry sub-buffer can allocate,
 * so the parent's heap_idx survives the per-iter `lua_settop` cleanup. */
static void
encode_map_field(lua_State *L, enc_buf *b, pb_plan *plan,
                  pb_plan_field *f, int val_idx)
{
	val_idx = abs_idx(L, val_idx);
	if (lua_type(L, val_idx) != LUA_TTABLE)
		luaL_error(L, "map field requires a table value");

	/* Fast empty-check: probe the first iter step and bail if nothing. */
	lua_pushnil(L);
	if (lua_next(L, val_idx) == 0)
		return;
	lua_pop(L, 2);  /* drop probe k+v */

	/* Force parent's heap to exist before per-entry sub-bufs allocate. */
	if (b->heap_idx == 0)
		ebuf_grow(L, b, 1);

	/* Pre-compute entry-internal tags. Both ids are < 16 so they fit
	 * in a single varint byte. */
	uint8_t key_wt = wire_type_for_kind(f->map_key_kind);
	uint8_t val_wt = wire_type_for_kind(f->map_value_kind);
	uint8_t key_tag = (uint8_t)((1u << 3) | key_wt);
	uint8_t val_tag = (uint8_t)((2u << 3) | val_wt);

	/* Resolve value sub-plan once if this is map<K, message>. */
	pb_plan *value_subplan = NULL;
	if (f->map_value_kind == PB_KIND_MESSAGE) {
		if (plan->sub_plans_ref == LUA_NOREF ||
		    f->map_value_sub_plan_idx <= 0)
			luaL_error(L,
				"map<,message> field has no value sub-plan");
		lua_rawgeti(L, LUA_REGISTRYINDEX, plan->sub_plans_ref);
		lua_rawgeti(L, -1, f->map_value_sub_plan_idx);
		value_subplan = (pb_plan *)lua_touserdata(L, -1);
		lua_pop(L, 2);
		if (value_subplan == NULL)
			luaL_error(L, "map value sub-plan is not a userdata");
	}

	int saved_top = lua_gettop(L);
	lua_pushnil(L);  /* iter sentinel */
	while (lua_next(L, val_idx) != 0) {
		int k_idx = saved_top + 1;
		int v_idx = saved_top + 2;

		/* Build the entry payload in a stack-backed sub-buffer. */
		enc_buf entry;
		ebuf_init(&entry);

		/* Key (proto3-elide on default). */
		if (!value_is_default_kind(L, f->map_key_kind, k_idx)) {
			ebuf_reserve(L, &entry, 1);
			ebuf_put_byte(&entry, key_tag);
			encode_kind_value(L, &entry, f->map_key_kind, k_idx);
		}

		/* Value. Messages always emit (presence is meaningful); other
		 * kinds proto3-elide on default. */
		if (f->map_value_kind == PB_KIND_MESSAGE) {
			if (value_subplan->override_encode_ref != LUA_NOREF) {
				/* WKT-typed map value: override owns body. */
				lua_rawgeti(L, LUA_REGISTRYINDEX,
				            value_subplan->override_encode_ref);
				lua_pushvalue(L, v_idx);
				lua_call(L, 1, 1);
				if (lua_type(L, -1) != LUA_TSTRING)
					luaL_error(L,
						"WKT encode for '%s' returned non-string",
						value_subplan->name != NULL
						? value_subplan->name : "?");
				size_t blen;
				const char *bp = lua_tolstring(L, -1, &blen);
				ebuf_reserve(L, &entry, 1 + 10 + blen);
				ebuf_put_byte(&entry, val_tag);
				ebuf_put_varint(&entry, (uint64_t)blen);
				if (blen > 0)
					ebuf_put_bytes(&entry,
						(const uint8_t *)bp, blen);
				lua_pop(L, 1);
			} else {
				if (lua_type(L, v_idx) != LUA_TTABLE)
					luaL_error(L,
						"map<,message> value must be a table");
				enc_buf vbody;
				ebuf_init(&vbody);
				encode_body(L, &vbody, value_subplan, v_idx);
				ebuf_reserve(L, &entry,
					     1 + 10 + vbody.used);
				ebuf_put_byte(&entry, val_tag);
				ebuf_put_varint(&entry, (uint64_t)vbody.used);
				if (vbody.used > 0)
					ebuf_put_bytes(&entry, ebuf_base(&vbody),
					               vbody.used);
			}
		} else if (!value_is_default_kind(L, f->map_value_kind,
		                                  v_idx)) {
			ebuf_reserve(L, &entry, 1);
			ebuf_put_byte(&entry, val_tag);
			encode_kind_value(L, &entry, f->map_value_kind,
			                  v_idx);
		}

		/* Emit outer tag + len-varint + entry body into parent. */
		ebuf_reserve(L, b, f->tag_len + 10 + entry.used);
		ebuf_put_tag(b, f);
		ebuf_put_varint(b, (uint64_t)entry.used);
		if (entry.used > 0)
			ebuf_put_bytes(b, ebuf_base(&entry), entry.used);

		/* Drop per-entry userdata frames, leave key for lua_next. */
		lua_settop(L, saved_top + 1);
	}
	/* lua_next returned 0 — it has already popped the final key. */
}

static void
encode_body(lua_State *L, enc_buf *b, pb_plan *plan, int msg_idx)
{
	msg_idx = abs_idx(L, msg_idx);

	if (plan->override_encode_ref != LUA_NOREF) {
		/* Defensive: callers must dispatch via the override Lua-ref
		 * directly. Reaching encode_body here means a code-path bug. */
		luaL_error(L,
			"internal: encode_body invoked on override plan '%s'",
			plan->name != NULL ? plan->name : "?");
	}

	if (plan->field_names_ref == LUA_NOREF || plan->n_fields == 0)
		return;

	lua_rawgeti(L, LUA_REGISTRYINDEX, plan->field_names_ref);
	int names_idx = lua_gettop(L);

	/* Oneof active-member resolution. For each oneof group, walk its
	 * member_indices in declaration order and check msg[member_name];
	 * the last non-nil member wins, matching codec.lua encode_message.
	 * active_member_idx[o] stores the plan->fields index of the active
	 * branch, or -1 if no member is set. Sized for n_oneofs >= 1; the
	 * dummy slot when n_oneofs == 0 avoids zero-length-VLA UB. */
	int oo_vla_n = plan->n_oneofs > 0 ? plan->n_oneofs : 1;
	int active_member_idx[oo_vla_n];
	for (int o = 0; o < oo_vla_n; o++) active_member_idx[o] = -1;
	for (int o = 0; o < plan->n_oneofs; o++) {
		pb_plan_oneof *oo = &plan->oneofs[o];
		for (int k = 0; k < oo->n_members; k++) {
			int m_idx = oo->member_indices[k];
			lua_rawgeti(L, names_idx, m_idx + 1);
			lua_rawget(L, msg_idx);
			if (!lua_isnil(L, -1))
				active_member_idx[o] = m_idx;
			lua_pop(L, 1);
		}
	}

	for (int i = 0; i < plan->n_fields; i++) {
		pb_plan_field *f = &plan->fields[i];

		/* Oneof: skip every non-active member. The active member
		 * encodes with force_emit so default values (e.g. text="")
		 * still carry presence. */
		if (f->oneof_idx >= 0 && active_member_idx[f->oneof_idx] != i)
			continue;

		lua_rawgeti(L, names_idx, i + 1); /* push field name */
		lua_rawget(L, msg_idx);            /* push msg[name] */
		int val_idx = lua_gettop(L);

		if (lua_isnil(L, val_idx)) {
			/* Proto2 required: missing → hard error with full path,
			 * matching codec.lua's build_required_writer. */
			if (f->required) {
				lua_rawgeti(L, names_idx, i + 1);
				const char *fname = lua_tostring(L, -1);
				luaL_error(L,
					"required field missing on encode: %s.%s",
					plan->name != NULL ? plan->name : "?",
					fname != NULL ? fname : "?");
			}
			lua_pop(L, 1);
			continue;
		}

		if (f->kind == PB_KIND_MAP) {
			encode_map_field(L, b, plan, f, val_idx);
		} else if (f->repeated) {
			if (lua_type(L, val_idx) != LUA_TTABLE)
				luaL_error(L,
					"repeated field requires a table value");
			encode_repeated_field(L, b, plan, f, val_idx);
		} else if (f->kind == PB_KIND_MESSAGE) {
			if (f->is_group)
				encode_group_field(L, b, plan, f, val_idx);
			else
				encode_submessage_field(L, b, plan, f, val_idx);
		} else {
			/* Force emit when the field has presence: oneof member,
			 * proto2 required, or proto2 explicit-optional. The
			 * non-forced path proto3-elides zeros. */
			int force = (f->oneof_idx >= 0 || f->required) ? 1 : 0;
			encode_one_field(L, b, f, val_idx, force);
		}
		lua_pop(L, 1);
	}

	/* Proto2 extensions: walk plan->extensions and emit each present
	 * entry from data._extensions[ext.full_name]. Registration order
	 * == iteration order (matches codec.lua's extensions_list walk). */
	if (plan->n_extensions > 0) {
		lua_getfield(L, msg_idx, "_extensions");
		if (lua_type(L, -1) == LUA_TTABLE) {
			int exts_idx = lua_gettop(L);
			for (int i = 0; i < plan->n_extensions; i++) {
				pb_plan_field *ext = &plan->extensions[i];
				lua_getfield(L, exts_idx,
				             ext->full_name != NULL ?
				             ext->full_name : "");
				if (!lua_isnil(L, -1)) {
					encode_extension(L, b, plan, ext,
					                 lua_gettop(L));
				}
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1); /* _extensions (table or nil) */
	}

	/* Re-emit captured unknown bytes at the tail.
	 * Mirrors codec.lua's `encode_message`: nil or "" are no-ops; any
	 * non-empty string is appended verbatim. */
	lua_getfield(L, msg_idx, "_unknown_fields");
	if (lua_type(L, -1) == LUA_TSTRING) {
		size_t ul;
		const char *up = lua_tolstring(L, -1, &ul);
		if (ul > 0) {
			ebuf_reserve(L, b, ul);
			ebuf_put_bytes(b, (const uint8_t *)up, ul);
		}
	}
	lua_pop(L, 1);

	lua_pop(L, 1); /* names table */
}

static int
encode_lua(lua_State *L)
{
	pb_plan *plan = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);

	/* WKT override: desc.encode(value) returns the body bytes verbatim.
	 * The value is any Lua type the override accepts (datetime cdata,
	 * Lua number, string, table, etc.) — don't pre-check for TTABLE. */
	if (plan->override_encode_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, plan->override_encode_ref);
		lua_pushvalue(L, 2);
		lua_call(L, 1, 1);
		if (lua_type(L, -1) != LUA_TSTRING)
			return luaL_error(L,
				"WKT encode for '%s' returned non-string",
				plan->name != NULL ? plan->name : "?");
		return 1;
	}

	luaL_checktype(L, 2, LUA_TTABLE);

	enc_buf b;
	ebuf_init(&b);
	encode_body(L, &b, plan, 2);

	lua_pushlstring(L, (const char *)ebuf_base(&b), b.used);
	return 1;
}

/* ---------------------------------------------------------------- *
 *  Decode.                                                           *
 *                                                                  *
 *  Covers singular scalars, singular sub-messages, repeated and    *
 *  map fields (see decode_map_entry below), and unknown-tag        *
 *  round-trip capture into result._unknown_fields.                 *
 *                                                                  *
 *  Result-table shape must match mode=full pure-Lua decode. That   *
 *  pins per-kind value types: int64/uint64/sint64/fixed64/sfixed64 *
 *  push Tarantool int64_t/uint64_t cdata via luaL_pushint64 /      *
 *  luaL_pushuint64; everything else pushes a Lua number, boolean,  *
 *  or string. See runtime/pb/wire.lua decoder comments.             *
 *                                                                  *
 *  Nested-message decode bounds the byte range by temporarily       *
 *  shrinking c->len to the sub-message's end offset; the wire-prim *
 *  helpers (dec_varint / dec_fixed*) already bounds-check against  *
 *  c->len, so this keeps a malformed inner payload from over-      *
 *  reading into the outer message's bytes.                          *
 * ---------------------------------------------------------------- */

typedef struct dec_ctx {
	lua_State    *L;
	const uint8_t *buf;
	size_t        len;
	size_t        pos;
	/* Opt-in skip of is_valid_utf8 on every PB_KIND_STRING payload.
	 * Set by decode_unsafe_lua for trusted producers (re-decoding our
	 * own encoder output, in-process typed RPC). Mirrors the Lua
	 * scalar_unsafe.string = scalar.bytes swap in pb.codec. */
	int           skip_utf8;
} dec_ctx;

static uint64_t
dec_varint(dec_ctx *c)
{
	uint64_t v = 0;
	int shift = 0;
	for (int i = 0; i < 10; i++) {
		if (c->pos >= c->len)
			luaL_error(c->L, "truncated varint at offset %d",
			           (int)c->pos);
		uint8_t b = c->buf[c->pos++];
		v |= ((uint64_t)(b & 0x7f)) << shift;
		if ((b & 0x80) == 0)
			return v;
		shift += 7;
	}
	luaL_error(c->L, "varint exceeds 10 bytes at offset %d",
	           (int)c->pos);
	return 0;
}

static uint32_t
dec_fixed32(dec_ctx *c)
{
	if (c->len - c->pos < 4)
		luaL_error(c->L, "truncated fixed32 at offset %d",
		           (int)c->pos);
	uint32_t v = (uint32_t)c->buf[c->pos]
	           | ((uint32_t)c->buf[c->pos + 1] << 8)
	           | ((uint32_t)c->buf[c->pos + 2] << 16)
	           | ((uint32_t)c->buf[c->pos + 3] << 24);
	c->pos += 4;
	return v;
}

static uint64_t
dec_fixed64(dec_ctx *c)
{
	if (c->len - c->pos < 8)
		luaL_error(c->L, "truncated fixed64 at offset %d",
		           (int)c->pos);
	uint64_t v = 0;
	for (int i = 0; i < 8; i++)
		v |= ((uint64_t)c->buf[c->pos + i]) << (i * 8);
	c->pos += 8;
	return v;
}

/* For SGROUP recursion we need to thread the opening field id so the closing
 * EGROUP can be id-matched per proto2 spec. Mirrors runtime/pb/wire.lua's
 * skip_field(buf, pos, wt, field_id). */
static void dec_skip_with_id(dec_ctx *c, uint8_t wt, uint32_t field_id);

static void
dec_skip(dec_ctx *c, uint8_t wt)
{
	dec_skip_with_id(c, wt, 0);
}

static void
dec_skip_with_id(dec_ctx *c, uint8_t wt, uint32_t field_id)
{
	switch (wt) {
	case PB_WIRE_VARINT:
		(void)dec_varint(c);
		break;
	case PB_WIRE_I32:
		(void)dec_fixed32(c);
		break;
	case PB_WIRE_I64:
		(void)dec_fixed64(c);
		break;
	case PB_WIRE_LEN: {
		uint64_t plen = dec_varint(c);
		if (c->len - c->pos < plen)
			luaL_error(c->L, "truncated length-delimited payload");
		c->pos += (size_t)plen;
		break;
	}
	case PB_WIRE_SGROUP: {
		if (field_id == 0)
			luaL_error(c->L,
				"skip SGROUP requires field id for EGROUP match");
		while (c->pos < c->len) {
			uint64_t itag = dec_varint(c);
			uint32_t iid  = (uint32_t)(itag >> 3);
			uint8_t  iwt  = (uint8_t)(itag & 0x07);
			if (iwt == PB_WIRE_EGROUP) {
				if (iid != field_id)
					luaL_error(c->L,
						"EGROUP id %d does not match SGROUP id %d",
						(int)iid, (int)field_id);
				return;
			}
			dec_skip_with_id(c, iwt, iid);
		}
		luaL_error(c->L,
			"unterminated SGROUP for field id %d", (int)field_id);
		break;
	}
	case PB_WIRE_EGROUP:
		luaL_error(c->L, "unexpected EGROUP for field id %d",
		           (int)field_id);
		break;
	default:
		luaL_error(c->L, "unsupported wire type %d for skip", (int)wt);
	}
}

static inline int32_t
zigzag32_dec(uint32_t u)
{
	return (int32_t)((u >> 1) ^ (~(u & 1) + 1));
}

static inline int64_t
zigzag64_dec(uint64_t u)
{
	return (int64_t)((u >> 1) ^ (~(u & 1) + 1));
}

/* RFC 3629 UTF-8 validator. Mirrors the rules enforced by Tarantool's
 * ICU-backed utf8.len (overlong, lone surrogate U+D800..U+DFFF, code
 * points > U+10FFFF, truncated multi-byte sequences). Returns 1 if the
 * byte run is valid UTF-8, 0 otherwise. Proto3 (and proto2 string
 * fields, per the recommended profile) requires this on the wire — the
 * pure-Lua decoder calls utf8.len() via wire.lua. */
static int
is_valid_utf8(const uint8_t *s, size_t n)
{
	size_t i = 0;
	while (i < n) {
		uint8_t c = s[i];
		if (c < 0x80) {
			i++;
		} else if ((c & 0xE0) == 0xC0) {
			/* 2-byte sequence. 0xC0/0xC1 are overlong. */
			if (c < 0xC2) return 0;
			if (i + 1 >= n) return 0;
			if ((s[i + 1] & 0xC0) != 0x80) return 0;
			i += 2;
		} else if ((c & 0xF0) == 0xE0) {
			/* 3-byte sequence. */
			if (i + 2 >= n) return 0;
			uint8_t b1 = s[i + 1], b2 = s[i + 2];
			if ((b1 & 0xC0) != 0x80) return 0;
			if ((b2 & 0xC0) != 0x80) return 0;
			/* 0xE0 with b1 < 0xA0 is overlong (< U+0800). */
			if (c == 0xE0 && b1 < 0xA0) return 0;
			/* 0xED with b1 >= 0xA0 is a UTF-16 surrogate
			 * (U+D800..U+DFFF), forbidden in UTF-8. */
			if (c == 0xED && b1 >= 0xA0) return 0;
			i += 3;
		} else if ((c & 0xF8) == 0xF0) {
			/* 4-byte sequence. 0xF5..0xFF would encode > U+10FFFF. */
			if (c > 0xF4) return 0;
			if (i + 3 >= n) return 0;
			uint8_t b1 = s[i + 1], b2 = s[i + 2], b3 = s[i + 3];
			if ((b1 & 0xC0) != 0x80) return 0;
			if ((b2 & 0xC0) != 0x80) return 0;
			if ((b3 & 0xC0) != 0x80) return 0;
			/* 0xF0 with b1 < 0x90 is overlong (< U+10000). */
			if (c == 0xF0 && b1 < 0x90) return 0;
			/* 0xF4 with b1 >= 0x90 is > U+10FFFF. */
			if (c == 0xF4 && b1 >= 0x90) return 0;
			i += 4;
		} else {
			return 0;
		}
	}
	return 1;
}

/* Decode a single value of the given `kind` from the stream and push it
 * onto the Lua stack. Per-kind Lua representations match wire.lua's
 * decoder (cdata int64/uint64 for 64-bit kinds, Lua number/integer for
 * everything else, lstring for STRING/BYTES). */
static void
dec_push_kind(dec_ctx *c, uint8_t kind)
{
	switch (kind) {
	case PB_KIND_INT32: {
		uint64_t u = dec_varint(c);
		int32_t v = (int32_t)(uint32_t)u;
		lua_pushinteger(c->L, v);
		return;
	}
	case PB_KIND_INT64: {
		uint64_t u = dec_varint(c);
		luaL_pushint64(c->L, (int64_t)u);
		return;
	}
	case PB_KIND_UINT32: {
		uint64_t u = dec_varint(c);
		uint32_t v = (uint32_t)u;
		lua_pushnumber(c->L, (double)v);
		return;
	}
	case PB_KIND_UINT64: {
		uint64_t u = dec_varint(c);
		luaL_pushuint64(c->L, u);
		return;
	}
	case PB_KIND_SINT32: {
		uint64_t u = dec_varint(c);
		int32_t v = zigzag32_dec((uint32_t)u);
		lua_pushinteger(c->L, v);
		return;
	}
	case PB_KIND_SINT64: {
		uint64_t u = dec_varint(c);
		luaL_pushint64(c->L, zigzag64_dec(u));
		return;
	}
	case PB_KIND_BOOL: {
		uint64_t u = dec_varint(c);
		lua_pushboolean(c->L, u != 0);
		return;
	}
	case PB_KIND_ENUM: {
		uint64_t u = dec_varint(c);
		int32_t v = (int32_t)(uint32_t)u;
		lua_pushinteger(c->L, v);
		return;
	}
	case PB_KIND_FIXED32: {
		uint32_t u = dec_fixed32(c);
		lua_pushnumber(c->L, (double)u);
		return;
	}
	case PB_KIND_SFIXED32: {
		uint32_t u = dec_fixed32(c);
		lua_pushinteger(c->L, (int32_t)u);
		return;
	}
	case PB_KIND_FLOAT: {
		uint32_t u = dec_fixed32(c);
		union { uint32_t u; float f; } pun;
		pun.u = u;
		lua_pushnumber(c->L, (double)pun.f);
		return;
	}
	case PB_KIND_FIXED64: {
		uint64_t u = dec_fixed64(c);
		luaL_pushuint64(c->L, u);
		return;
	}
	case PB_KIND_SFIXED64: {
		uint64_t u = dec_fixed64(c);
		luaL_pushint64(c->L, (int64_t)u);
		return;
	}
	case PB_KIND_DOUBLE: {
		uint64_t u = dec_fixed64(c);
		union { uint64_t u; double d; } pun;
		pun.u = u;
		lua_pushnumber(c->L, pun.d);
		return;
	}
	case PB_KIND_STRING: {
		uint64_t plen = dec_varint(c);
		if (c->len - c->pos < plen)
			luaL_error(c->L, "truncated string/bytes payload");
		if (!c->skip_utf8 &&
		    !is_valid_utf8(c->buf + c->pos, (size_t)plen))
			luaL_error(c->L,
				"invalid UTF-8 in string field at offset %d",
				(int)c->pos);
		lua_pushlstring(c->L, (const char *)(c->buf + c->pos),
		                (size_t)plen);
		c->pos += (size_t)plen;
		return;
	}
	case PB_KIND_BYTES: {
		uint64_t plen = dec_varint(c);
		if (c->len - c->pos < plen)
			luaL_error(c->L, "truncated string/bytes payload");
		lua_pushlstring(c->L, (const char *)(c->buf + c->pos),
		                (size_t)plen);
		c->pos += (size_t)plen;
		return;
	}
	default:
		luaL_error(c->L, "dec_push_kind: unsupported kind %d",
		           (int)kind);
	}
}

/* Decode a single value for field `f` and push it onto the Lua stack.
 * Thin wrapper around dec_push_kind to preserve the existing call sites. */
static void
dec_push_one(dec_ctx *c, pb_plan_field *f)
{
	dec_push_kind(c, f->kind);
}

/* Forward decl for the recursive decode.
 *
 * `stop_group_id`: 0 means decode to end of c->len (normal message); non-zero
 * means we're inside a proto2 group body and the loop terminates on the
 * matching EGROUP tag. After EGROUP, c->pos sits just past the closing tag.
 * Mirrors codec.lua's decode_group. */
static void decode_body(dec_ctx *c, pb_plan *plan, int result_idx,
                        uint32_t stop_group_id);
static void decode_submessage_field(dec_ctx *c, pb_plan_field *f,
                                    int sub_plans_idx);
static void decode_group_field(dec_ctx *c, pb_plan_field *f, int sub_plans_idx);
static void decode_extension_into(dec_ctx *c, pb_plan_field *ext, uint8_t wt,
                                  int sub_plans_idx, int result_idx);
static void decode_map_entry(dec_ctx *c, pb_plan_field *f, int sub_plans_idx,
                              int map_idx);
static inline int field_is_packable(const pb_plan_field *f);
static void merge_subresult_into(lua_State *L, pb_plan *desc,
                                 int prev_idx, int sub_idx);

/* Decode one singular sub-message field. On entry, `c->pos` points at
 * the length-varint byte; on exit, `c->pos == c->pos + plen`. Pushes
 * the decoded sub-table onto the Lua stack. */
static void
decode_submessage_field(dec_ctx *c, pb_plan_field *f, int sub_plans_idx)
{
	lua_State *L = c->L;
	uint64_t plen = dec_varint(c);
	if (c->len - c->pos < plen)
		luaL_error(L, "truncated nested message at offset %d",
		           (int)c->pos);

	lua_rawgeti(L, sub_plans_idx, f->sub_plan_idx);
	pb_plan *subplan = (pb_plan *)lua_touserdata(L, -1);
	if (subplan == NULL)
		luaL_error(L, "sub-plan at index %d is not a userdata",
		           f->sub_plan_idx);
	lua_pop(L, 1);

	/* WKT override: feed the body slice to desc.decode(buf), push whatever
	 * Lua representation the override returns. */
	if (subplan->override_decode_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		            subplan->override_decode_ref);
		lua_pushlstring(L, (const char *)(c->buf + c->pos),
		                (size_t)plen);
		lua_call(L, 1, 1);
		c->pos += (size_t)plen;
		return;
	}

	lua_createtable(L, 0, subplan->n_fields);
	int sub_result_idx = lua_gettop(L);

	/* Temporarily shrink c->len so the inner decode loop terminates at
	 * the sub-message boundary and so inner wire-prim reads cannot
	 * spill past it. */
	size_t saved_len = c->len;
	c->len = c->pos + (size_t)plen;
	decode_body(c, subplan, sub_result_idx, /* stop_group_id */ 0);
	if (c->pos != c->len)
		luaL_error(L,
			"nested message body underflow at offset %d (expected %d)",
			(int)c->pos, (int)c->len);
	c->len = saved_len;
}

/* Decode one proto2 group field. On entry, c->pos sits just past the
 * SGROUP tag — we walk the body via decode_body with stop_group_id set
 * to the field's id; decode_body terminates on EGROUP with matching id
 * and leaves c->pos just past the closing tag. The decoded sub-table
 * is left on top of the Lua stack (mirrors decode_submessage_field). */
static void
decode_group_field(dec_ctx *c, pb_plan_field *f, int sub_plans_idx)
{
	lua_State *L = c->L;
	lua_rawgeti(L, sub_plans_idx, f->sub_plan_idx);
	pb_plan *subplan = (pb_plan *)lua_touserdata(L, -1);
	if (subplan == NULL)
		luaL_error(L, "group sub-plan at index %d is not a userdata",
		           f->sub_plan_idx);
	lua_pop(L, 1);

	lua_createtable(L, 0, subplan->n_fields);
	int sub_result_idx = lua_gettop(L);

	/* Groups have no length prefix; decode_body walks raw bytes until
	 * the matching EGROUP tag. The outer c->len bound still applies
	 * (unterminated group ⇒ error). */
	decode_body(c, subplan, sub_result_idx, f->field_number);
}

/* Decode one proto2 extension's wire bytes into result._extensions[full_name].
 * Mirrors codec.lua's decode_extension: scalar/enum/message/group, singular
 * vs repeated, packed-payload handling. */
static void
decode_extension_into(dec_ctx *c, pb_plan_field *ext, uint8_t wt,
                      int sub_plans_idx, int result_idx)
{
	lua_State *L = c->L;

	/* Find or create result._extensions; leave it on top of the stack
	 * as `exts_idx`. */
	lua_getfield(L, result_idx, "_extensions");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		lua_createtable(L, 0, 4);
		lua_pushvalue(L, -1);
		lua_setfield(L, result_idx, "_extensions");
	}
	int exts_idx = lua_gettop(L);
	const char *key = ext->full_name != NULL ? ext->full_name : "";

	if (ext->repeated) {
		lua_getfield(L, exts_idx, key);
		if (!lua_istable(L, -1)) {
			lua_pop(L, 1);
			lua_createtable(L, 0, 0);
			lua_pushvalue(L, -1);
			lua_setfield(L, exts_idx, key);
		}
		int list_idx = lua_gettop(L);

		if (ext->kind == PB_KIND_MESSAGE) {
			if (ext->is_group) {
				if (wt != PB_WIRE_SGROUP)
					luaL_error(L,
						"repeated group extension '%s' expected wire 3, got %d",
						key, (int)wt);
				decode_group_field(c, ext, sub_plans_idx);
			} else {
				if (wt != PB_WIRE_LEN)
					luaL_error(L,
						"repeated message extension '%s' expected wire 2, got %d",
						key, (int)wt);
				decode_submessage_field(c, ext, sub_plans_idx);
			}
			lua_rawseti(L, list_idx,
			            (int)lua_objlen(L, list_idx) + 1);
		} else if (wt == PB_WIRE_LEN && field_is_packable(ext)) {
			/* Packed payload for a packable extension element. */
			uint64_t plen = dec_varint(c);
			if (c->len - c->pos < plen)
				luaL_error(L,
					"truncated packed extension '%s' payload", key);
			size_t saved_len = c->len;
			c->len = c->pos + (size_t)plen;
			while (c->pos < c->len) {
				dec_push_one(c, ext);
				lua_rawseti(L, list_idx,
				            (int)lua_objlen(L, list_idx) + 1);
			}
			if (c->pos != c->len)
				luaL_error(L,
					"packed extension '%s' underflow", key);
			c->len = saved_len;
		} else {
			dec_push_one(c, ext);
			lua_rawseti(L, list_idx,
			            (int)lua_objlen(L, list_idx) + 1);
		}
		lua_pop(L, 2); /* list, _extensions */
		return;
	}

	/* Singular extension. Scalars/enums use last-wins; messages merge. */
	if (ext->kind == PB_KIND_MESSAGE) {
		if (ext->is_group)
			decode_group_field(c, ext, sub_plans_idx);
		else
			decode_submessage_field(c, ext, sub_plans_idx);
		/* stack: ..., exts, sub_result */

		/* Repeated wire occurrence of a singular message extension
		 * must merge — same rule as in-message fields. */
		pb_plan *subplan_for_merge = NULL;
		if (ext->sub_plan_idx > 0) {
			lua_rawgeti(L, sub_plans_idx, ext->sub_plan_idx);
			subplan_for_merge =
				(pb_plan *)lua_touserdata(L, -1);
			lua_pop(L, 1);
		}
		lua_getfield(L, exts_idx, key);
		/* stack: ..., sub_result, prev_or_nil */
		if (lua_istable(L, -1) && lua_istable(L, -2) &&
		    subplan_for_merge != NULL &&
		    subplan_for_merge->override_decode_ref == LUA_NOREF) {
			int prev_idx = lua_gettop(L);
			int sub_idx  = prev_idx - 1;
			merge_subresult_into(L, subplan_for_merge,
			                     prev_idx, sub_idx);
			lua_pop(L, 2); /* prev, sub_result */
		} else {
			lua_pop(L, 1); /* pop prev/nil */
			lua_setfield(L, exts_idx, key); /* exts[key] = sub_result */
		}
	} else {
		dec_push_one(c, ext);
		lua_setfield(L, exts_idx, key);
	}
	lua_pop(L, 1); /* _extensions */
}

/* Decode one map<K,V> entry from the wire and lua_rawset it into the
 * map table at absolute stack index `map_idx`.
 *
 * On entry `c->pos` points at the entry's length-varint (one element of
 * the outer repeated-message stream). On exit `c->pos` has advanced past
 * the entry. Pushes the {key, value} pair temporarily, sets into the
 * map, then pops both.
 *
 * Inner-tag semantics:
 *   id == 1: key value
 *   id == 2: value value
 *   anything else: skipped per the wire-format spec for synthetic Entry
 *
 * Missing key or value defaults to the proto3 zero for the corresponding
 * kind — that's how an empty entry payload `{}` round-trips through a
 * map<,> field (see test_map_defaults_round_trip). For message-typed
 * values, the default is an empty Lua table. */
static void
decode_map_entry(dec_ctx *c, pb_plan_field *f, int sub_plans_idx,
                  int map_idx)
{
	lua_State *L = c->L;
	uint64_t plen = dec_varint(c);
	if (c->len - c->pos < plen)
		luaL_error(L, "truncated map entry for field %d",
		           (int)f->field_number);

	size_t saved_len = c->len;
	c->len = c->pos + (size_t)plen;

	/* Pre-push proto3 defaults; replace if the corresponding tag arrives. */
	push_default_for_kind(L, f->map_key_kind);
	int key_idx = lua_gettop(L);
	push_default_for_kind(L, f->map_value_kind);
	int val_idx = lua_gettop(L);

	while (c->pos < c->len) {
		uint64_t tag = dec_varint(c);
		uint32_t id = (uint32_t)(tag >> 3);
		uint8_t wt = (uint8_t)(tag & 0x07);
		if (id == 1) {
			dec_push_kind(c, f->map_key_kind);
			lua_replace(L, key_idx);
		} else if (id == 2) {
			if (f->map_value_kind == PB_KIND_MESSAGE) {
				if (f->map_value_sub_plan_idx <= 0)
					luaL_error(L,
						"map<,message> has no value sub-plan");
				lua_rawgeti(L, sub_plans_idx,
				            f->map_value_sub_plan_idx);
				pb_plan *vsub =
					(pb_plan *)lua_touserdata(L, -1);
				if (vsub == NULL)
					luaL_error(L,
						"map value sub-plan is not a userdata");
				lua_pop(L, 1);

				uint64_t sub_len = dec_varint(c);
				if (c->len - c->pos < sub_len)
					luaL_error(L,
						"truncated nested map<,message> value");
				if (vsub->override_decode_ref != LUA_NOREF) {
					/* WKT-typed map value: override consumes body. */
					lua_rawgeti(L, LUA_REGISTRYINDEX,
					            vsub->override_decode_ref);
					lua_pushlstring(L,
						(const char *)(c->buf + c->pos),
						(size_t)sub_len);
					lua_call(L, 1, 1);
					c->pos += (size_t)sub_len;
					lua_replace(L, val_idx);
				} else {
					lua_createtable(L, 0, vsub->n_fields);
					int new_val = lua_gettop(L);
					size_t saved2 = c->len;
					c->len = c->pos + (size_t)sub_len;
					decode_body(c, vsub, new_val,
					            /* stop_group_id */ 0);
					if (c->pos != c->len)
						luaL_error(L,
							"nested map<,message> body underflow");
					c->len = saved2;
					lua_replace(L, val_idx);
				}
			} else {
				dec_push_kind(c, f->map_value_kind);
				lua_replace(L, val_idx);
			}
		} else {
			dec_skip(c, wt);
		}
	}

	/* map[key] = val — proto3 last-wins per key. cdata int64/uint64 keys
	 * would need a pointer-equality dedup pass (see runtime/pb/codec.lua's
	 * `key_dedup`); this implementation handles string/int32-family keys
	 * losslessly and skips that dedup pass. */
	lua_pushvalue(L, key_idx);
	lua_pushvalue(L, val_idx);
	lua_rawset(L, map_idx);

	lua_pop(L, 2);  /* drop key + val defaults */
	c->len = saved_len;
}

/* Return 1 if the field's element wire type is varint/i32/i64 — i.e.
 * the field is eligible for packed encoding. Length-delimited kinds
 * (STRING/BYTES/MESSAGE) and MAP are never packable. Used on decode
 * to detect a wt==LEN payload for a repeated scalar field as a packed
 * blob even when the schema declares packed=false (proto3 readers MUST
 * accept both). */
static inline int
field_is_packable(const pb_plan_field *f)
{
	switch (f->kind) {
	case PB_KIND_STRING:
	case PB_KIND_BYTES:
	case PB_KIND_MESSAGE:
	case PB_KIND_MAP:
	case PB_KIND_NONE:
		return 0;
	default:
		return 1;
	}
}

/* Merge `sub_idx` (a freshly-decoded sub-table) into `prev_idx` (the
 * sub-table already at result[name] from a prior wire occurrence) per
 * proto3 spec:
 *   - scalar / enum fields: last-wins (replace)
 *   - repeated fields: concatenate (append decoded elements)
 *   - map fields: last-wins per key
 *   - sub-message fields: recursive merge (unless WKT override)
 * Mirrors runtime/pb/codec.lua's merge_message — exercised on the wire
 * when a singular message field (including a oneof message branch)
 * appears more than once. `prev_idx` is modified in-place; `sub_idx` is
 * left on the stack for the caller to drop.
 *
 * Both indices must be absolute (use abs_idx() before calling). */
static void
merge_subresult_into(lua_State *L, pb_plan *desc, int prev_idx, int sub_idx)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, desc->field_names_ref);
	int names_idx = lua_gettop(L);
	lua_rawgeti(L, LUA_REGISTRYINDEX, desc->sub_plans_ref);
	int sub_plans_idx = lua_gettop(L);

	for (int i = 0; i < desc->n_fields; i++) {
		pb_plan_field *f = &desc->fields[i];

		/* sub[name] */
		lua_rawgeti(L, names_idx, i + 1);          /* name */
		lua_pushvalue(L, -1);
		lua_rawget(L, sub_idx);                    /* name, v */
		if (lua_isnil(L, -1)) {
			lua_pop(L, 2);                     /* nil, name */
			continue;
		}

		/* prev[name] */
		lua_pushvalue(L, -2);                      /* dup name */
		lua_rawget(L, prev_idx);                   /* name, v, pv */

		if (lua_isnil(L, -1)) {
			/* prev[name] absent — assign. */
			lua_pop(L, 1);                     /* pop nil */
			lua_rawset(L, prev_idx);           /* prev[name] = v */
			continue;
		}

		if (f->kind == PB_KIND_MAP && lua_istable(L, -1) &&
		    lua_istable(L, -2)) {
			/* Map: copy v's pairs into pv, last-wins per key. */
			int v_idx = lua_gettop(L) - 1;
			int pv_idx = lua_gettop(L);
			lua_pushnil(L);
			while (lua_next(L, v_idx) != 0) {
				/* stack: ..., key, val */
				lua_pushvalue(L, -2);      /* key */
				lua_pushvalue(L, -2);      /* val */
				lua_rawset(L, pv_idx);
				lua_pop(L, 1);             /* pop val */
			}
			lua_pop(L, 3);                     /* pv, v, name */
		} else if (f->repeated && lua_istable(L, -1) &&
		           lua_istable(L, -2)) {
			/* Repeated: concat v[1..#v] onto pv. */
			int v_idx = lua_gettop(L) - 1;
			int pv_idx = lua_gettop(L);
			int pv_len = (int)lua_objlen(L, pv_idx);
			int v_len = (int)lua_objlen(L, v_idx);
			for (int j = 1; j <= v_len; j++) {
				lua_rawgeti(L, v_idx, j);
				lua_rawseti(L, pv_idx, pv_len + j);
			}
			lua_pop(L, 3);                     /* pv, v, name */
		} else if (f->kind == PB_KIND_MESSAGE &&
		           lua_istable(L, -1) && lua_istable(L, -2)) {
			/* Singular message: recurse, unless WKT (custom
			 * decode value is opaque — fall through to replace). */
			pb_plan *sub_desc = NULL;
			if (f->sub_plan_idx > 0) {
				lua_rawgeti(L, sub_plans_idx,
				            f->sub_plan_idx);
				sub_desc = (pb_plan *)lua_touserdata(L, -1);
				lua_pop(L, 1);
			}
			if (sub_desc != NULL &&
			    sub_desc->override_decode_ref == LUA_NOREF) {
				int v_idx = lua_gettop(L) - 1;
				int pv_idx = lua_gettop(L);
				merge_subresult_into(L, sub_desc,
				                     pv_idx, v_idx);
				lua_pop(L, 3);             /* pv, v, name */
			} else {
				/* WKT — last-wins; replace prev[name] with v. */
				lua_pop(L, 1);             /* pop pv */
				lua_rawset(L, prev_idx);   /* name, v */
			}
		} else {
			/* Scalar / enum / oneof-cleared / type mismatch:
			 * last-wins. Replace prev[name] with v. */
			lua_pop(L, 1);                     /* pop pv */
			lua_rawset(L, prev_idx);           /* name, v */
		}
	}

	lua_pop(L, 2);                                     /* sub_plans, names */
}

static void
decode_body(dec_ctx *c, pb_plan *plan, int result_idx,
            uint32_t stop_group_id)
{
	lua_State *L = c->L;
	if (plan->override_decode_ref != LUA_NOREF) {
		/* Defensive: callers must dispatch via the override Lua-ref
		 * directly. Reaching decode_body here means a code-path bug. */
		luaL_error(L,
			"internal: decode_body invoked on override plan '%s'",
			plan->name != NULL ? plan->name : "?");
	}

	result_idx = abs_idx(L, result_idx);

	/* Pin field-names + sub-plans so the loop can rawgeti by index. */
	int names_idx, sub_plans_idx;
	if (plan->field_names_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, plan->field_names_ref);
	} else {
		lua_pushnil(L);
	}
	names_idx = lua_gettop(L);
	if (plan->sub_plans_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, plan->sub_plans_ref);
	} else {
		lua_pushnil(L);
	}
	sub_plans_idx = lua_gettop(L);

	/* Per-field stack-slot cache for repeated fields. On first hit for
	 * a given field, we lua_createtable + store into result[name] and
	 * dup-push the table onto the stack; subsequent hits reuse the
	 * cached absolute stack index and lua_rawseti the new element
	 * directly. Avoids the per-element lua_getfield(result, name) round
	 * trip that the c-accel spike measured at 2x slower at 100KB.
	 *
	 * list_count[i] tracks length without calling lua_objlen per append
	 * — a Lua-side O(log n) probe that adds up fast on the 1000-element
	 * acceptance path.
	 *
	 * VLA size guarded against n_fields == 0 (UB for zero-length VLA).
	 * Both arrays live on the C stack; n_fields is bounded by message
	 * shape — for any realistic schema this is well under 1KB. */
	int vla_n = plan->n_fields > 0 ? plan->n_fields : 1;
	int list_stack_idx[vla_n];
	int list_count[vla_n];
	memset(list_stack_idx, 0, sizeof(list_stack_idx));
	memset(list_count, 0, sizeof(list_count));

	/* Unknown-field passthrough. Tags not present in
	 * the plan get their raw bytes (tag varint + payload) captured here,
	 * then written verbatim as `result._unknown_fields = string` at the
	 * tail. Mirrors codec.lua's `decode_message` behavior. Each recursive
	 * `decode_body` call has its own `unknown` buffer — nested messages
	 * carry their own _unknown_fields, isolated from the parent. */
	enc_buf unknown;
	ebuf_init(&unknown);

	/* Track whether the EGROUP was actually observed when decoding a
	 * group body, so an unterminated SGROUP fails loudly instead of
	 * silently returning at end-of-buffer. Mirrors wire.lua's behavior
	 * for the known-field-group case. */
	int egroup_seen = 0;

	while (c->pos < c->len) {
		size_t tag_start = c->pos;
		uint64_t tag = dec_varint(c);
		uint64_t field_number64 = tag >> 3;
		uint32_t field_number = (uint32_t)field_number64;
		uint8_t  wt           = (uint8_t)(tag & 0x07);

		/* Tag validation — strict-decode parity with wire.lua's
		 * decode_tag. The pure-Lua decoder rejects each of these; the
		 * C path now matches:
		 *   - wire types 6 and 7 are reserved/invalid (legal: 0..5)
		 *   - field number 0 is illegal
		 *   - field number > 2^29-1 is illegal (29-bit per spec)
		 *   - the tag varint must be minimum-length (no overlong
		 *     encodings). dec_varint already enforces the 10-byte
		 *     hard limit; the trailing-zero check catches padded
		 *     encodings that fit in fewer bytes. */
		if (wt >= 6)
			luaL_error(L,
				"illegal wire type %d at offset %d",
				(int)wt, (int)tag_start);
		if (field_number == 0)
			luaL_error(L,
				"illegal field number 0 at offset %d",
				(int)tag_start);
		if (c->pos - tag_start > 1 && c->buf[c->pos - 1] == 0)
			luaL_error(L,
				"overlong tag varint at offset %d",
				(int)tag_start);
		if (field_number64 > 0x1FFFFFFFULL)
			luaL_error(L,
				"field number out of range at offset %d",
				(int)tag_start);

		/* Proto2 group body: EGROUP with matching id terminates this
		 * decode_body call. A mismatched id is a hard error per spec. */
		if (wt == PB_WIRE_EGROUP) {
			if (stop_group_id == 0)
				luaL_error(L,
					"unexpected EGROUP for field id %d at top level",
					(int)field_number);
			if (field_number != stop_group_id)
				luaL_error(L,
					"EGROUP id %d does not match SGROUP id %d",
					(int)field_number, (int)stop_group_id);
			/* Successful close — drop into the unknown-fields
			 * tail handling below. */
			egroup_seen = 1;
			break;
		}

		/* Linear scan over plan->fields. n_fields is typically small;
		 * tag-keyed dispatch table is a future optimization. */
		pb_plan_field *f = NULL;
		int f_idx = -1;
		for (int i = 0; i < plan->n_fields; i++) {
			if (plan->fields[i].field_number == field_number) {
				f = &plan->fields[i];
				f_idx = i;
				break;
			}
		}

		/* Unknown tag — proto2 extensions get a second chance before
		 * the bytes are stashed verbatim as result._unknown_fields. */
		if (f == NULL) {
			if (plan->n_extensions > 0) {
				pb_plan_field *ext = NULL;
				for (int i = 0; i < plan->n_extensions; i++) {
					if (plan->extensions[i].field_number
					        == field_number) {
						ext = &plan->extensions[i];
						break;
					}
				}
				if (ext != NULL) {
					decode_extension_into(c, ext, wt,
					    sub_plans_idx, result_idx);
					continue;
				}
			}
			dec_skip_with_id(c, wt, field_number);
			size_t chunk = c->pos - tag_start;
			ebuf_reserve(L, &unknown, chunk);
			ebuf_put_bytes(&unknown, c->buf + tag_start, chunk);
			continue;
		}

		/* ------------------------------------------------------ *
		 *  Map dispatch                                          *
		 * ------------------------------------------------------ */
		if (f->kind == PB_KIND_MAP) {
			if (wt != PB_WIRE_LEN)
				luaL_error(L,
					"map field %d expected wire 2, got %d",
					(int)field_number, (int)wt);

			/* Lazy-create the map table on first hit. Reuses the
			 * list_stack_idx[] slot since a field is either
			 * repeated or map, never both. */
			int m_idx = list_stack_idx[f_idx];
			if (m_idx == 0) {
				lua_createtable(L, 0, 0);
				lua_pushvalue(L, -1);
				lua_rawgeti(L, names_idx, f_idx + 1);
				lua_insert(L, -2);
				lua_rawset(L, result_idx);
				m_idx = lua_gettop(L);
				list_stack_idx[f_idx] = m_idx;
			}
			decode_map_entry(c, f, sub_plans_idx, m_idx);
			continue;
		}

		/* ------------------------------------------------------ *
		 *  Repeated dispatch                                      *
		 * ------------------------------------------------------ */
		if (f->repeated) {
			/* Lazy-create the list table on first hit. */
			int list_idx = list_stack_idx[f_idx];
			if (list_idx == 0) {
				lua_createtable(L, 0, 0);
				/* Stack: ..., new_list. Dup, write name → list
				 * into result, leave list on top as our cache. */
				lua_pushvalue(L, -1);
				lua_rawgeti(L, names_idx, f_idx + 1);
				lua_insert(L, -2);            /* name, list_copy */
				lua_rawset(L, result_idx);    /* result[name] = list */
				list_idx = lua_gettop(L);
				list_stack_idx[f_idx] = list_idx;
				list_count[f_idx] = 0;
			}

			/* Repeated message: per-element length-delimited body.
			 * Repeated proto2 group: SGROUP-framed body, one per
			 * element. */
			if (f->kind == PB_KIND_MESSAGE) {
				if (f->is_group) {
					if (wt != PB_WIRE_SGROUP)
						luaL_error(L,
							"repeated group field %d expected wire 3, got %d",
							(int)field_number, (int)wt);
					decode_group_field(c, f, sub_plans_idx);
				} else {
					if (wt != PB_WIRE_LEN)
						luaL_error(L,
							"repeated message field %d expected wire 2, got %d",
							(int)field_number, (int)wt);
					decode_submessage_field(c, f, sub_plans_idx);
				}
				/* Stack top is the decoded sub-table. */
				list_count[f_idx]++;
				lua_rawseti(L, list_idx, list_count[f_idx]);
				continue;
			}

			/* Packed payload: a single LEN-prefixed blob carrying
			 * N elements end-to-end. Proto3 readers must accept a
			 * packed payload for any packable scalar regardless of
			 * the schema's packed flag — that's why this check is
			 * `field_is_packable`, not `f->packed`. */
			if (wt == PB_WIRE_LEN && field_is_packable(f)) {
				uint64_t plen = dec_varint(c);
				if (c->len - c->pos < plen)
					luaL_error(L,
						"truncated packed payload for field %d",
						(int)field_number);
				size_t saved_len = c->len;
				c->len = c->pos + (size_t)plen;
				while (c->pos < c->len) {
					dec_push_one(c, f);
					list_count[f_idx]++;
					lua_rawseti(L, list_idx, list_count[f_idx]);
				}
				if (c->pos != c->len)
					luaL_error(L,
						"packed payload underflow for field %d",
						(int)field_number);
				c->len = saved_len;
				continue;
			}

			/* Unpacked single element. */
			dec_push_one(c, f);
			list_count[f_idx]++;
			lua_rawseti(L, list_idx, list_count[f_idx]);
			continue;
		}

		/* ------------------------------------------------------ *
		 *  Singular dispatch                                      *
		 * ------------------------------------------------------ */
		if (f->kind == PB_KIND_MESSAGE) {
			if (f->is_group)
				decode_group_field(c, f, sub_plans_idx);
			else
				decode_submessage_field(c, f, sub_plans_idx);
			/* stack: ..., names, sub_plans, [lists...], sub_result */

			/* Singular-message merge: a repeated wire
			 * occurrence of a singular message field must merge
			 * into the previous value, not replace it (proto3
			 * spec; mirrors codec.lua's merge_message). WKT
			 * subplans with a custom decode skip the merge —
			 * their decoded value is opaque (often not a table).
			 *
			 * Resolve the subplan first; the sub_result table
			 * sits at stack top until we either merge or assign.
			 */
			pb_plan *subplan_for_merge = NULL;
			if (f->sub_plan_idx > 0) {
				lua_rawgeti(L, sub_plans_idx, f->sub_plan_idx);
				subplan_for_merge =
					(pb_plan *)lua_touserdata(L, -1);
				lua_pop(L, 1);
			}
			lua_rawgeti(L, names_idx, f_idx + 1);
			lua_pushvalue(L, -1);                /* dup name */
			lua_rawget(L, result_idx);           /* prev or nil */
			/* stack: ..., sub_result, name, prev_or_nil */
			if (lua_istable(L, -1) && lua_istable(L, -3) &&
			    subplan_for_merge != NULL &&
			    subplan_for_merge->override_decode_ref
			        == LUA_NOREF) {
				int prev_idx = lua_gettop(L);
				int sub_idx  = prev_idx - 2;
				merge_subresult_into(L, subplan_for_merge,
				                     prev_idx, sub_idx);
				lua_pop(L, 3);  /* prev, name, sub_result */
			} else {
				lua_pop(L, 1);  /* pop prev/nil */
				/* stack: sub_result, name */
				lua_insert(L, -2);     /* name, sub_result */
				lua_rawset(L, result_idx);
			}
		} else {
			dec_push_one(c, f);  /* stack: ..., names, sub_plans, [lists...], value */

			lua_rawgeti(L, names_idx, f_idx + 1);
			lua_insert(L, -2);                /* name, value */
			lua_rawset(L, result_idx);        /* result[name] = value */
		}

		/* Oneof: clear sibling branches in the result table. Wire-order
		 * last-wins semantics — the most-recently-decoded member is the
		 * one whose value remains. Mirrors codec.lua's
		 * `oneof_siblings` clearing. */
		if (f->oneof_idx >= 0) {
			pb_plan_oneof *oo = &plan->oneofs[f->oneof_idx];
			for (int k = 0; k < oo->n_members; k++) {
				int m_idx = oo->member_indices[k];
				if (m_idx == f_idx) continue;
				lua_rawgeti(L, names_idx, m_idx + 1);
				lua_pushnil(L);
				lua_rawset(L, result_idx);
			}
		}
	}

	/* Unterminated SGROUP body: when decoding a group, the
	 * loop must exit via the EGROUP break — falling out by end-of-
	 * buffer means the group was never closed. Mirrors wire.lua's
	 * skip_field SGROUP error path for the known-field-group case. */
	if (stop_group_id != 0 && !egroup_seen)
		luaL_error(L, "unterminated SGROUP for field id %d",
		           (int)stop_group_id);

	/* Write captured unknown bytes as result._unknown_fields. Skipped
	 * when nothing was captured (key stays absent — matches codec.lua). */
	if (unknown.used > 0) {
		lua_pushlstring(L, (const char *)ebuf_base(&unknown),
		                unknown.used);
		lua_setfield(L, result_idx, "_unknown_fields");
	}

	/* Pop everything we pushed: per-field list tables (one per repeated
	 * field that appeared), then sub_plans and names. Walk list_stack_idx
	 * to count list-table pushes — equals lua_gettop(L) - sub_plans_idx.
	 * Also pops any userdata `unknown` allocated when it outgrew its
	 * stack[] buffer (heap_idx > 0). */
	int top = lua_gettop(L);
	int to_pop = top - names_idx + 1;
	lua_pop(L, to_pop);
}

static int
decode_impl(lua_State *L, int skip_utf8)
{
	pb_plan *plan = (pb_plan *)luaL_checkudata(L, 1, PB_PLAN_MT);
	size_t buf_len;
	const char *buf = luaL_checklstring(L, 2, &buf_len);

	/* WKT override: desc.decode(buf) consumes the entire body and returns
	 * whatever Lua representation the override picks (e.g. datetime).
	 * The override is opaque — there is no unsafe variant to thread the
	 * skip_utf8 flag into, so the safe and unsafe paths both call it as
	 * declared. WKT string payloads (Timestamp/Duration/Value) are
	 * either ASCII or not user-supplied. */
	if (plan->override_decode_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, plan->override_decode_ref);
		lua_pushlstring(L, buf, buf_len);
		lua_call(L, 1, 1);
		return 1;
	}

	lua_createtable(L, 0, plan->n_fields);
	int result_idx = lua_gettop(L);

	dec_ctx c;
	c.L         = L;
	c.buf       = (const uint8_t *)buf;
	c.len       = buf_len;
	c.pos       = 0;
	c.skip_utf8 = skip_utf8;

	decode_body(&c, plan, result_idx, /* stop_group_id */ 0);
	return 1;
}

static int
decode_lua(lua_State *L)
{
	return decode_impl(L, /* skip_utf8 */ 0);
}

/* Sister of decode_lua for trusted producers — skips is_valid_utf8 on
 * every PB_KIND_STRING payload across the entire decode tree (the flag
 * lives on dec_ctx and survives sub-message recursion). Dispatched from
 * pb.decode_unsafe and from full-mode codegen's <Name>_decode_unsafe
 * prologue. */
static int
decode_unsafe_lua(lua_State *L)
{
	return decode_impl(L, /* skip_utf8 */ 1);
}

/* ---------------------------------------------------------------- *
 *  Module entry.                                                    *
 * ---------------------------------------------------------------- */

static const struct luaL_Reg c_runtime_methods[] = {
	{"compile_plan",    compile_plan_lua},
	{"plan_n_fields",   plan_n_fields},
	{"plan_name",       plan_name},
	{"plan_field_info", plan_field_info},
	{"plan_n_oneofs",   plan_n_oneofs},
	{"plan_oneof_info", plan_oneof_info},
	{"plan_has_override", plan_has_override},
	{"plan_sub_plan",   plan_sub_plan},
	{"encode",          encode_lua},
	{"decode",          decode_lua},
	{"decode_unsafe",   decode_unsafe_lua},
	{NULL, NULL},
};

static const struct luaL_Reg plan_mt_methods[] = {
	{"__gc",       plan_gc},
	{"__tostring", plan_tostring},
	{NULL, NULL},
};

LUA_API int
luaopen_pb_c_runtime(lua_State *L)
{
	/* Register the plan metatable. */
	luaL_newmetatable(L, PB_PLAN_MT);
	luaL_register(L, NULL, plan_mt_methods);
	lua_pop(L, 1);

	/* Build the module table. */
	lua_newtable(L);
	luaL_register(L, NULL, c_runtime_methods);

	lua_pushliteral(L, PB_ABI_VERSION);
	lua_setfield(L, -2, "_abi_version");

	/* Kind constants — exported so Lua tests can compare without
	 * duplicating the enum. */
	lua_createtable(L, 0, 19);
	lua_pushinteger(L, PB_KIND_NONE);     lua_setfield(L, -2, "NONE");
	lua_pushinteger(L, PB_KIND_INT32);    lua_setfield(L, -2, "INT32");
	lua_pushinteger(L, PB_KIND_INT64);    lua_setfield(L, -2, "INT64");
	lua_pushinteger(L, PB_KIND_UINT32);   lua_setfield(L, -2, "UINT32");
	lua_pushinteger(L, PB_KIND_UINT64);   lua_setfield(L, -2, "UINT64");
	lua_pushinteger(L, PB_KIND_SINT32);   lua_setfield(L, -2, "SINT32");
	lua_pushinteger(L, PB_KIND_SINT64);   lua_setfield(L, -2, "SINT64");
	lua_pushinteger(L, PB_KIND_FIXED32);  lua_setfield(L, -2, "FIXED32");
	lua_pushinteger(L, PB_KIND_FIXED64);  lua_setfield(L, -2, "FIXED64");
	lua_pushinteger(L, PB_KIND_SFIXED32); lua_setfield(L, -2, "SFIXED32");
	lua_pushinteger(L, PB_KIND_SFIXED64); lua_setfield(L, -2, "SFIXED64");
	lua_pushinteger(L, PB_KIND_FLOAT);    lua_setfield(L, -2, "FLOAT");
	lua_pushinteger(L, PB_KIND_DOUBLE);   lua_setfield(L, -2, "DOUBLE");
	lua_pushinteger(L, PB_KIND_BOOL);     lua_setfield(L, -2, "BOOL");
	lua_pushinteger(L, PB_KIND_STRING);   lua_setfield(L, -2, "STRING");
	lua_pushinteger(L, PB_KIND_BYTES);    lua_setfield(L, -2, "BYTES");
	lua_pushinteger(L, PB_KIND_ENUM);     lua_setfield(L, -2, "ENUM");
	lua_pushinteger(L, PB_KIND_MESSAGE);  lua_setfield(L, -2, "MESSAGE");
	lua_pushinteger(L, PB_KIND_MAP);      lua_setfield(L, -2, "MAP");
	lua_setfield(L, -2, "KIND");

	lua_createtable(L, 0, 4);
	lua_pushinteger(L, PB_WIRE_VARINT); lua_setfield(L, -2, "VARINT");
	lua_pushinteger(L, PB_WIRE_I64);    lua_setfield(L, -2, "I64");
	lua_pushinteger(L, PB_WIRE_LEN);    lua_setfield(L, -2, "LEN");
	lua_pushinteger(L, PB_WIRE_I32);    lua_setfield(L, -2, "I32");
	lua_setfield(L, -2, "WIRE");

	return 1;
}
