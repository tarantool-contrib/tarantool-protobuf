# googleapis (vendored)

Copies of the HTTP annotation protos, taken from
[googleapis/googleapis](https://github.com/googleapis/googleapis) at
commit `93d6085996d0b4ff7e7e86ca9945d5524bb380d1`, unmodified except
for a note under the license header:

- `google/api/annotations.proto`
- `google/api/http.proto`

They are licensed under the Apache License 2.0 (`LICENSE` in this
directory). They make `import "google/api/annotations.proto"` resolve
offline: `just gen` and the tests pass `-I third_party/googleapis`
next to `-I options`, and `just gen-builtin-descriptors` compiles them
into `runtime/pb/descriptors_builtin.lua`.

They live here rather than in `options/` so that `options/` holds only
this project's own `tarantool/tarantool.proto`: `options/` is the
published options module (see `buf.yaml` at the repository root), and a
copy of `google/api` in it would compete with the googleapis module or
repository that projects already depend on. To update, replace the
files with a newer upstream revision, change the commit above and in
the files' notes, and rerun `just gen`.
