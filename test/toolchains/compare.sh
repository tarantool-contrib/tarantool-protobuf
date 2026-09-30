#!/usr/bin/env bash
# Compares two trees of generated Lua modules for semantic parity.
#
# Usage: test/toolchains/compare.sh <expected_dir> <actual_dir>
# Run from the repository root (protoc resolves options/ from there).
#
# Both trees must hold the same set of files. For each pair of modules:
#   - the code outside the embedded descriptors must be identical;
#   - each embedded FileDescriptorProto must be byte-identical or, when
#     the bytes differ, decode to the same text with
#     `protoc --decode=google.protobuf.FileDescriptorProto`, with the
#     option extensions this repository uses loaded, so that option
#     fields serialized in a different order compare equal.
#
# Different compilers serialize option messages in different field
# orders (protoc, buf and EasyP each write the google.api.http HttpRule
# fields in their own order), and the plugin embeds the bytes it was given,
# so byte equality is too strict for descriptors.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <expected_dir> <actual_dir>" >&2
    exit 2
fi
expected=$1
actual=$2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(cd "$expected" && find . -type f -name '*.lua' | sort) > "$work/expected.list"
(cd "$actual" && find . -type f -name '*.lua' | sort) > "$work/actual.list"
if ! diff -u "$work/expected.list" "$work/actual.list"; then
    echo "FAIL: the two trees hold different files" >&2
    exit 1
fi

decode() {
    protoc --decode=google.protobuf.FileDescriptorProto \
        -I options -I third_party/googleapis \
        google/protobuf/descriptor.proto \
        google/api/annotations.proto \
        tarantool/tarantool.proto < "$1" > "$2"
}

files=0
identical=0
equivalent=0
failed=0
while IFS= read -r f; do
    files=$((files + 1))
    a="$work/a/$files"
    b="$work/b/$files"
    na=$(tarantool test/toolchains/split.lua "$expected/$f" "$a")
    nb=$(tarantool test/toolchains/split.lua "$actual/$f" "$b")
    if [ "$na" != "$nb" ]; then
        echo "FAIL $f: $na embedded descriptors vs $nb" >&2
        failed=$((failed + 1))
        continue
    fi
    if ! diff -u "$a/code.lua" "$b/code.lua" > "$work/code.diff"; then
        echo "FAIL $f: code differs outside the embedded descriptors:" >&2
        head -40 "$work/code.diff" >&2
        failed=$((failed + 1))
        continue
    fi
    i=1
    while [ "$i" -le "$na" ]; do
        if cmp -s "$a/desc.$i.bin" "$b/desc.$i.bin"; then
            identical=$((identical + 1))
        else
            decode "$a/desc.$i.bin" "$a/desc.$i.txt"
            decode "$b/desc.$i.bin" "$b/desc.$i.txt"
            if diff -u "$a/desc.$i.txt" "$b/desc.$i.txt" > "$work/desc.diff"; then
                equivalent=$((equivalent + 1))
                echo "note $f: descriptor $i differs in bytes, equal once decoded"
            else
                echo "FAIL $f: descriptor $i differs once decoded:" >&2
                head -40 "$work/desc.diff" >&2
                failed=$((failed + 1))
            fi
        fi
        i=$((i + 1))
    done
done < "$work/expected.list"

echo "compared $files modules: $identical descriptors byte-identical," \
     "$equivalent equal once decoded, $failed failures"
if [ "$files" -eq 0 ]; then
    echo "FAIL: nothing to compare" >&2
    exit 1
fi
if [ $((identical + equivalent)) -eq 0 ]; then
    echo "FAIL: no embedded descriptors found" >&2
    exit 1
fi
[ "$failed" -eq 0 ]
