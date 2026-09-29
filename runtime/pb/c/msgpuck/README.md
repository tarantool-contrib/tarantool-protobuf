# Vendored MsgPuck

Upstream: https://github.com/tarantool/msgpuck
Pinned commit: `0d90633c1b31de9bc63416b501159734b5213af5` (2025-08-29)
License: BSD-2-Clause, see [LICENSE](LICENSE).

`msgpuck.h`, `msgpuck.c`, `hints.c` and `LICENSE` are byte-identical
copies of the files at that commit. Do not edit them here; to update,
copy the same four files from a newer upstream commit and change the
commit above.

Why vendored: Tarantool's installed headers ship only `module.h`, not
`msgpuck.h`, and the Tarantool binary exports its MsgPuck copy only
under `tnt_mp_*` names, so a C module that reads MessagePack has to
compile its own. `msgpuck.c` defines `MP_LIBRARY` and so emits the
out-of-line definitions of every `mp_*` function; any other unit
including `msgpuck.h` gets inline definitions only. The C runtime
Makefile builds with `-fvisibility=hidden`, so none of these `mp_*`
symbols is exported from `c_runtime.{so,dylib}`.
