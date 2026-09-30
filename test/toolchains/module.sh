#!/usr/bin/env bash
# `just test-options-module`: pins what the options module publishes.
#
# The root buf.yaml makes options/ a module: `buf push` sends it to the
# Buf Schema Registry, and EasyP installs the files of a git dependency
# on this repository with the options/ prefix stripped. Either way,
# every .proto under options/ lands at the import root of every
# consumer, so the set must stay exactly tarantool/tarantool.proto — a
# google/api copy there would compete with the googleapis dependency
# consumers already have (see third_party/googleapis/README.md).
#
# Checks:
# - git: the tracked .proto files under options/ (what EasyP installs);
# - buf (skipped when not installed): `buf ls-files` of the root
#   workspace (what `buf push` sends), `buf lint` with the root config,
#   and, if the repository has a tag, `buf breaking` against the newest
#   one.
set -euo pipefail

cd "$(dirname "$0")/../.."

want=tarantool/tarantool.proto
rc=0

got=$(git ls-files -- 'options/*.proto' | sed 's|^options/||')
if [ "$got" != "$want" ]; then
    echo "FAIL: git: the tracked .proto files under options/ must be exactly $want, got:" >&2
    echo "$got" >&2
    rc=1
else
    echo "git: options/ holds $want only"
fi

if ! command -v buf > /dev/null 2>&1; then
    echo "buf: SKIP: buf is not installed (https://buf.build/docs/installation)"
    exit "$rc"
fi

got=$(buf ls-files --format import)
if [ "$got" != "$want" ]; then
    echo "FAIL: buf ls-files: the module must hold exactly $want, got:" >&2
    echo "$got" >&2
    rc=1
else
    echo "buf: the module holds $want only"
fi

if ! buf lint; then
    echo "FAIL: buf lint" >&2
    rc=1
else
    echo "buf: lint passes"
fi

# A tag without the root buf.yaml predates the module (its options/
# still held the google/api copies), so there is nothing to compare.
tag=$(git describe --tags --abbrev=0 2> /dev/null || true)
if [ -z "$tag" ]; then
    echo "buf: breaking: SKIP: no tag to compare against"
elif ! git cat-file -e "$tag:buf.yaml" 2> /dev/null; then
    echo "buf: breaking: SKIP: $tag predates the options module (no buf.yaml)"
elif ! buf breaking --against ".git#tag=$tag"; then
    echo "FAIL: buf breaking against $tag" >&2
    rc=1
else
    echo "buf: no breaking change against $tag"
fi

exit "$rc"
