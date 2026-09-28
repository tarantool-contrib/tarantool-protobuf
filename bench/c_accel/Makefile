# Makefile for the C-acceleration spike.
#
# Builds Lua C modules loadable from the bench harness with no install step
# -- the harness sets package.cpath to point here.

# Locate <module.h>. Order: env override, brew prefix, common system dirs.
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
$(error Cannot find <module.h>; set TARANTOOL_INCLUDE=/path/to/include/tarantool)
endif

UNAME_S := $(shell uname -s)

CFLAGS  := -O2 -fPIC -Wall -Wextra -std=c99 -I$(TT_INC)
ifeq ($(UNAME_S),Darwin)
	LIB_EXT := dylib
	LDFLAGS := -bundle -undefined dynamic_lookup
else
	LIB_EXT := so
	LDFLAGS := -shared
endif

MODULES := pb_c_person.$(LIB_EXT) pb_c_generic.$(LIB_EXT) libpb_prim.$(LIB_EXT)

all: $(MODULES)

pb_c_person.$(LIB_EXT): person_codec.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

pb_c_generic.$(LIB_EXT): generic_codec.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

libpb_prim.$(LIB_EXT): prim.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f *.dylib *.so

.PHONY: all clean
