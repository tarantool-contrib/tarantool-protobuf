# Makefile for pb.c_runtime — the optional C-acceleration runtime.
#
# Output sits at ../c_runtime.{so,dylib} so that
#   require('pb.c_runtime')
# resolves it via the LUA_CPATH the Justfile sets for `just test`
# (see Justfile lua_cpath: "./runtime/?.so;./runtime/?.dylib;...").
#
# Built only when PB_ENABLE_C=1 is part of the user's workflow.
# Pure-Lua install ignores this directory entirely.

# Locate <module.h>. Order: env override, brew prefix, common system dirs.
# Mirrors bench/c_accel/Makefile.
TT_INC ?= $(shell \
	if [ -n "$$TARANTOOL_INCLUDE" ] && [ -f "$$TARANTOOL_INCLUDE/module.h" ]; then \
		echo "$$TARANTOOL_INCLUDE"; exit 0; \
	fi; \
	for d in \
		$$(brew --prefix tarantool 2>/dev/null)/include/tarantool \
		/opt/homebrew/include/tarantool \
		/usr/local/include/tarantool \
		/usr/include/tarantool; do \
		if [ -f "$$d/module.h" ]; then echo "$$d"; exit 0; fi; \
	done)

ifeq ($(TT_INC),)
$(error Cannot find <module.h>; set TARANTOOL_INCLUDE=/path/to/include/tarantool or install tarantool-dev)
endif

UNAME_S := $(shell uname -s)

# -fvisibility=hidden: the only symbol the module exports is its Lua
# entry point (marked visible in c_runtime.c). The vendored msgpuck
# emits out-of-line mp_* definitions that must stay private to the
# shared object.
CFLAGS  := -O2 -fPIC -Wall -Wextra -std=c99 -fvisibility=hidden \
	-I$(TT_INC) -Imsgpuck
ifeq ($(UNAME_S),Darwin)
	LIB_EXT := dylib
	LDFLAGS := -bundle -undefined dynamic_lookup
else
	LIB_EXT := so
	LDFLAGS := -shared
endif

SRCS    := c_runtime.c tuple.c
# Vendored MsgPuck (see msgpuck/README.md). Objects land flat in this
# directory, next to c_runtime.o.
SRCS    += msgpuck/msgpuck.c msgpuck/hints.c
OBJS    := $(notdir $(SRCS:.c=.o))
OUTPUT  := ../c_runtime.$(LIB_EXT)

all: $(OUTPUT)

$(OUTPUT): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: msgpuck/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

c_runtime.o: c_plan.h tuple.h
tuple.o: c_plan.h tuple.h msgpuck/msgpuck.h
msgpuck.o hints.o: msgpuck/msgpuck.h

clean:
	rm -f *.o $(OUTPUT)

.PHONY: all clean
