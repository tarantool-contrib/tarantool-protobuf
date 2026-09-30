# Releasing

Maintainer notes for what a release publishes beyond the git tag.

## The options module

`options/` (only `tarantool/tarantool.proto`) is a module, configured
by the `buf.yaml` at the repository root:

- **EasyP** users take it as a git dependency on this repository at a
  tag. Nothing to publish: the tag is the release. EasyP reads the root
  `buf.yaml` of the dependency to strip the `options/` prefix, so every
  tag from the one that introduced `buf.yaml` on works.
- **buf** users take it from the Buf Schema Registry as
  `buf.build/tarantool-contrib/tarantool-protobuf`, which has to be
  pushed. It has not been pushed yet, and the `tarantool-contrib`
  organization does not exist on the BSR yet.

Before tagging, run `just test-options-module` (also part of
`just test-toolchains`). It fails when `options/` holds anything but
`tarantool/tarantool.proto`, when `buf lint` fails, or when the module
has a breaking change against the newest tag. A file added to
`options/` lands at the import root of every consumer, which is why the
vendored `google/api` protos live in `third_party/googleapis/` instead.

What the push sends: `buf.yaml`, `tarantool/tarantool.proto`,
`options/README.md` as the module's documentation, and the repository's
`LICENSE` (buf falls back to the workspace root when a module has no
license of its own).

### First publication, by hand

Needs a BSR account that may create the organization; the token ends up
in `~/.netrc`.

```bash
buf registry login                        # opens a browser; or --token-stdin
buf registry organization create buf.build/tarantool-contrib

git clone https://github.com/tarantool-contrib/tarantool-protobuf
cd tarantool-protobuf
git checkout <tag>                        # a tag that has the root buf.yaml
just test-options-module
buf push --create --create-visibility public --git-metadata
```

`--create` creates the module on the first push, `public` because the
default is private. `--git-metadata` labels the commit with the tag
(and any branch at that commit), links it to the GitHub commit through
the `origin` remote, and sets the module's default label to the
default branch; it needs a git checkout whose `origin` remote points
at GitHub. Later releases run the same `buf push --git-metadata` without
the `--create` flags.

Check the result without logging in:

```bash
buf registry module info buf.build/tarantool-contrib/tarantool-protobuf
```

### From CI

Once the organization exists, create a bot user or a token with write
access to it, store the token as the repository secret `BUF_TOKEN`, and
push on tags. A sketch for GitHub Actions with
[`bufbuild/buf-action`](https://github.com/bufbuild/buf-action) (check
its README for the current inputs before using it):

```yaml
name: buf
on:
  push:
    tags: ['*']
  pull_request:
permissions:
  contents: read
  pull-requests: write
jobs:
  buf:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: bufbuild/buf-action@v1
        with:
          token: ${{ secrets.BUF_TOKEN }}
          # Lint, format and breaking checks run on pull requests;
          # the push runs for tags only.
          push: ${{ github.ref_type == 'tag' }}
          push_create_visibility: public
```

The action runs from the repository root, so it sees the root
`buf.yaml` and pushes the options module only. On a pull request it
compares against the base branch for breaking changes.

## The extension number

`(tarantool.lua_package)` is extension `53301` of
`google.protobuf.FileOptions` (50000 plus Tarantool's default port
3301), a number from the 50000–99999 range that protobuf leaves to
individual organizations. The number is deliberately not registered in
the [global extension registry](https://github.com/protocolbuffers/protobuf/blob/main/docs/options.md)
and deliberately not a round one: protoc rejects two extensions of
`FileOptions` with the same number in one build, and round numbers
such as 50000 or 60001 are the ones other private options pick first.

The number is fixed. Changing it is a breaking change, and a silent one. Schemas
spell the option by name, so they keep compiling against either copy
of `tarantool/tarantool.proto`, but the plugin reads it by number
(`cmd/protoc-gen-tarantool/internal/gen/options.go`): a plugin built
for the new number ignores an option compiled from an old copy of the
file, and the module is generated under its default path instead of
the `lua_package` one. The file, the plugin and every copy consumers
vendored have to move together. `buf breaking` does not report a
changed extension number, so `just test-options-module` does not catch
it either.
