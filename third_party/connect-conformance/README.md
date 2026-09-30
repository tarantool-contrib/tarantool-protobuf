# connect-conformance (vendored)

Unmodified copies of the protos of the Connect conformance suite, taken
from [connectrpc/conformance](https://github.com/connectrpc/conformance)
at release `v1.0.5` (commit `fc1c52eb4a602c058882f6ad6ca0ffb1c39c4730`):

- `connectrpc/conformance/v1/service.proto` — `ConformanceService`, the
  service a server under test implements;
- `connectrpc/conformance/v1/server_compat.proto` — the
  `ServerCompatRequest` / `ServerCompatResponse` handshake on
  stdin/stdout;
- `connectrpc/conformance/v1/config.proto` — enums both import.

They are licensed under the Apache License 2.0 (`LICENSE` in this
directory). `just gen-connect-conformance` compiles them with
`protoc-gen-tarantool` into `examples/expected/full/connectrpc/`, which
`test/connect-conformance/server.lua` implements. The suite's runner,
`connectconformance`, is installed at the same release by
`just connect-conformance`. To update, replace the files with a newer
release, change the version here and in the Justfile, and rerun both
recipes.
