#!/usr/bin/env bash
# `just test-buf`: generates the examples (examples/proto/*.proto) with
# `buf generate` in both codegen modes and checks them against the
# protoc outputs of `just gen` (examples/expected/{full,runtime}).
#
# The buf outputs must match semantically, not byte for byte: identical
# code, and embedded descriptors equal once decoded (test/buf/compare.sh
# explains why). The protoc side is regenerated into a temporary
# directory with the flags of `just gen-full` / `just gen-runtime`,
# which gives the exact file set of the examples; it must be
# byte-identical to what `just gen` wrote to examples/expected/, so a
# drift between this script and the Justfile fails here too.
#
# Offline: test/buf/buf.yaml takes google/api from options/, not from
# the BSR. Skips (exit 0) when buf is not installed.
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v buf > /dev/null 2>&1; then
    echo "test-buf: SKIP: buf is not installed (https://buf.build/docs/installation)"
    exit 0
fi
echo "test-buf: $(buf --version 2>&1) against $(protoc --version)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

buf generate examples/proto \
    --config test/buf/buf.yaml \
    --template test/buf/buf.gen.yaml \
    -o "$tmp/buf"

mkdir -p "$tmp/protoc"
for mode in full runtime; do
    protoc \
        --plugin=./protoc-gen-tarantool \
        --tarantool_out="$tmp/protoc" \
        --tarantool_opt="mode=$mode,prefix=$mode" \
        -I examples/proto -I options \
        examples/proto/*.proto
done

stale=0
while IFS= read -r f; do
    if ! cmp -s "$tmp/protoc/$f" "examples/expected/$f"; then
        echo "FAIL: examples/expected/$f differs from protoc output (run just gen," \
             "or align this script with the Justfile)" >&2
        stale=$((stale + 1))
    fi
done < <(cd "$tmp/protoc" && find . -type f -name '*.lua' | sort)
[ "$stale" -eq 0 ]

test/buf/compare.sh "$tmp/protoc" "$tmp/buf"
