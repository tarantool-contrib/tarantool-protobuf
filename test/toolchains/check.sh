#!/usr/bin/env bash
# `just test-toolchains` (and `just test-buf` / `just test-easyp`):
# generates the examples (examples/proto/*.proto) with `buf generate`
# and `easyp generate` in both codegen modes and checks them against the
# protoc outputs of `just gen` (examples/expected/{full,runtime}).
#
# Usage: test/toolchains/check.sh [buf|easyp]...   (default: both)
#
# The outputs must match semantically, not byte for byte: identical
# code, and embedded descriptors equal once decoded
# (test/toolchains/compare.sh explains why). The protoc side is
# regenerated into a temporary directory with the flags of
# `just gen-full` / `just gen-runtime`, which gives the exact file set
# of the examples; it must be byte-identical to what `just gen` wrote
# to examples/expected/, so a drift between this script and the
# Justfile fails here too.
#
# Offline: both tools take google/api from options/, not from a
# registry or a git dependency. A tool that is not installed is skipped
# with a message: buf is looked up on PATH, EasyP as $EASYP or `easyp`
# on PATH.
set -euo pipefail

cd "$(dirname "$0")/../.."
here=test/toolchains

tools=("$@")
if [ ${#tools[@]} -eq 0 ]; then
    tools=(buf easyp)
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

check_buf() {
    if ! command -v buf > /dev/null 2>&1; then
        echo "buf: SKIP: buf is not installed (https://buf.build/docs/installation)"
        return 0
    fi
    echo "buf: $(buf --version 2>&1) against $(protoc --version)"
    # The check functions run as `check_x || rc=1`, where errexit does
    # not apply: every step propagates its failure itself.
    buf generate examples/proto \
        --config "$here/buf.yaml" \
        --template "$here/buf.gen.yaml" \
        -o "$tmp/buf" || return 1
    "$here/compare.sh" "$tmp/protoc" "$tmp/buf" || return 1
}

check_easyp() {
    local easyp=${EASYP:-}
    if [ -z "$easyp" ]; then
        easyp=$(command -v easyp || true)
    fi
    if [ -z "$easyp" ]; then
        echo "easyp: SKIP: EasyP is not installed (set EASYP=<path> or put easyp on PATH;" \
             "go install github.com/easyp-tech/easyp/cmd/easyp@latest)"
        return 0
    fi
    echo "easyp: $("$easyp" --version 2>&1) against $(protoc --version)"

    # EasyP resolves paths against its working directory, so it runs in
    # a scratch workspace with copies of the inputs; EASYPPATH keeps its
    # cache there too.
    local ws="$tmp/easyp-ws"
    mkdir -p "$ws" || return 1
    cp -R examples/proto "$ws/proto" || return 1
    cp -R options "$ws/options" || return 1
    cp protoc-gen-tarantool "$ws/" || return 1
    cp "$here/easyp.yaml" "$ws/" || return 1
    (cd "$ws" && EASYPPATH="$ws/.easyp" "$easyp" generate) || return 1

    # options/ is an input, the only way to put it on EasyP's import
    # path without a git dependency, so its files are generated as well.
    # Those modules are moved to a tree of their own and compared with
    # protoc's output for options/*.proto.
    local base="$tmp/protoc-options" mode f
    mkdir -p "$base" "$ws/options-out" || return 1
    for mode in full runtime; do
        (cd options && find . -name '*.proto' | sort | xargs protoc \
            --plugin=../protoc-gen-tarantool \
            --tarantool_out="$base" \
            --tarantool_opt="mode=$mode,prefix=$mode" \
            -I .) || return 1
    done
    while IFS= read -r f; do
        if [ ! -f "$ws/out/$f" ]; then
            echo "FAIL: easyp did not generate $f from options/" >&2
            return 1
        fi
        mkdir -p "$(dirname "$ws/options-out/$f")" || return 1
        mv "$ws/out/$f" "$ws/options-out/$f" || return 1
    done < <(cd "$base" && find . -type f -name '*.lua' | sort)
    find "$ws/out" -type d -empty -delete || return 1
    "$here/compare.sh" "$tmp/protoc" "$ws/out" || return 1
    "$here/compare.sh" "$base" "$ws/options-out" || return 1
}

rc=0
for tool in "${tools[@]}"; do
    case "$tool" in
        buf) check_buf || rc=1 ;;
        easyp) check_easyp || rc=1 ;;
        *) echo "unknown tool: $tool (want buf or easyp)" >&2; exit 2 ;;
    esac
done
exit "$rc"
