# grpc-proto (vendored)

Unmodified copies of the gRPC service definitions the runtime serves
itself, taken from [grpc/grpc-proto](https://github.com/grpc/grpc-proto)
at commit `813330824839bfdd3abc52f41807095c0de2ec19`:

- `grpc/reflection/v1/reflection.proto`
- `grpc/reflection/v1alpha/reflection.proto`
- `grpc/health/v1/health.proto`

They are licensed under the Apache License 2.0 (`LICENSE` in this
directory). `just gen-grpc-services` compiles them with
`protoc-gen-tarantool` into `runtime/pb/gen/`, which `pb.reflection`
and `pb.health` build on. To update, replace the files with a newer
upstream revision, change the commit above, and rerun the recipe.
