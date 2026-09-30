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
# Offline: both tools take google/api from third_party/googleapis/, not
# from a registry or a git dependency. A tool that is not installed is skipped
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

# list_modules <dir> <file>: writes the *.lua files under <dir>, sorted,
# one per line, to <file>. Fails when find fails or finds nothing, so
# a loop reading the list cannot pass over a listing that went wrong.
# Callers check its status: it also runs where errexit does not apply.
list_modules() {
    local found
    found=$(cd "$1" && find . -type f -name '*.lua') || {
        echo "FAIL: cannot list the modules under $1" >&2
        return 1
    }
    if [ -z "$found" ]; then
        echo "FAIL: no modules under $1" >&2
        return 1
    fi
    printf '%s\n' "$found" | sort > "$2" || return 1
}

protoc_version=$(protoc --version)

mkdir -p "$tmp/protoc"
for mode in full runtime; do
    protoc \
        --plugin=./protoc-gen-tarantool \
        --tarantool_out="$tmp/protoc" \
        --tarantool_opt="mode=$mode,prefix=$mode" \
        -I examples/proto -I options -I third_party/googleapis \
        examples/proto/*.proto
done

list_modules "$tmp/protoc" "$tmp/protoc.list"
stale=0
while IFS= read -r f; do
    if ! cmp -s "$tmp/protoc/$f" "examples/expected/$f"; then
        echo "FAIL: examples/expected/$f differs from protoc output (run just gen," \
             "or align this script with the Justfile)" >&2
        stale=$((stale + 1))
    fi
done < "$tmp/protoc.list"
[ "$stale" -eq 0 ]

check_buf() {
    if ! command -v buf > /dev/null 2>&1; then
        echo "buf: SKIP: buf is not installed (https://buf.build/docs/installation)"
        return 0
    fi
    # The check functions run as `check_x || rc=1`, where errexit does
    # not apply: every step propagates its failure itself.
    local version
    version=$(buf --version 2>&1) || {
        echo "FAIL: buf --version failed: $version" >&2
        return 1
    }
    echo "buf: $version against $protoc_version"
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
    local version
    version=$("$easyp" --version 2>&1) || {
        echo "FAIL: $easyp --version failed: $version" >&2
        return 1
    }
    echo "easyp: $version against $protoc_version"

    # EasyP resolves paths against its working directory, so it runs in
    # a scratch workspace with copies of the inputs; EASYPPATH keeps its
    # cache there too.
    local ws="$tmp/easyp-ws"
    mkdir -p "$ws" || return 1
    cp -R examples/proto "$ws/proto" || return 1
    cp -R options "$ws/options" || return 1
    cp -R third_party/googleapis "$ws/googleapis" || return 1
    cp protoc-gen-tarantool "$ws/" || return 1
    cp "$here/easyp.yaml" "$ws/" || return 1
    (cd "$ws" && EASYPPATH="$ws/.easyp" "$easyp" generate) || return 1

    # options/ and googleapis/ are inputs, the only way to put them on
    # EasyP's import path without a git dependency, so their files are
    # generated as well. Those modules are moved to a tree of their own
    # and compared with protoc's output for options/*.proto and
    # third_party/googleapis/*.proto, each compiled from its own import
    # root. compare.sh checks that each pair of trees holds the same
    # files, so both comparisons together cover exactly what EasyP
    # generated.
    local base="$tmp/protoc-options" plugin="$PWD/protoc-gen-tarantool" mode root f
    mkdir -p "$base" "$ws/options-out" || return 1
    for root in options third_party/googleapis; do
        for mode in full runtime; do
            (cd "$root" && find . -name '*.proto' | sort | xargs protoc \
                --plugin="$plugin" \
                --tarantool_out="$base" \
                --tarantool_opt="mode=$mode,prefix=$mode" \
                -I .) || return 1
        done
    done
    list_modules "$base" "$tmp/protoc-options.list" || return 1
    while IFS= read -r f; do
        if [ ! -f "$ws/out/$f" ]; then
            echo "FAIL: easyp did not generate $f from options/ or googleapis/" >&2
            return 1
        fi
        mkdir -p "$(dirname "$ws/options-out/$f")" || return 1
        mv "$ws/out/$f" "$ws/options-out/$f" || return 1
    done < "$tmp/protoc-options.list"
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
