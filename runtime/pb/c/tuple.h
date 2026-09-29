/*
 * tuple.h -- the pb.tuple encoder entry points, registered into the
 * pb.c_runtime module table by c_runtime.c. See tuple.c.
 */

#ifndef PB_C_TUPLE_H
#define PB_C_TUPLE_H

#include <lua.h>

/* Register the tuple-plan metatable. Called once from the module entry. */
void
pb_tuple_open(lua_State *L);

/* c_runtime.tuple_compile(plan) -> tplan */
int
pb_tuple_compile(lua_State *L);

/* c_runtime.tuple_encode(tplan, tuple) -> string */
int
pb_tuple_encode(lua_State *L);

/* c_runtime.tuple_encode_repeated(tplan, field_no, tuples) -> string */
int
pb_tuple_encode_repeated(lua_State *L);

#endif /* PB_C_TUPLE_H */
