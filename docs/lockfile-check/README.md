# Lockfile check

The `.github/workflows/lockfile-check.yaml` reusable workflow fails when a
committed JavaScript lockfile resolves a package from anywhere other than an
approved registry. A lockfile that points at an arbitrary tarball URL, a git
repository, or a file outside the repository installs code that no registry
vetted, and nothing else in CI notices. npm 10 and 11 allow remote tarballs by
default, and pnpm and Yarn have no equivalent guard.

## Adopt it

Add one job to a workflow that runs on pull requests, pinned to a release tag:

```yaml
jobs:
  lockfile-check:
    uses: datum-cloud/actions/.github/workflows/lockfile-check.yaml@<release-tag>
```

The first tag that carries this workflow is the next release after the one
that merges it. Protect the caller workflow, and the `exclude-paths` value in
it, with CODEOWNERS or a required workflow: whoever can edit them can exempt
every lockfile.

The workflow needs only `contents: read`. It runs `jq`, `yq`, and `awk` over the
committed files and installs nothing from the repository. `yq` must be
mikefarah `yq` v4.47.1 or newer, which `ubuntu-latest` runners carry; the check
fails when it is missing or is a different tool.

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Directory to check, relative to the repository root. |
| `exclude-paths` | None | Comma- or newline-separated globs, relative to `path`, of lockfiles not to check. |
| `allowed-registries` | None | Comma- or newline-separated `https://` registry URLs accepted besides the two defaults, such as `https://npm.pkg.github.com`. |
| `require-lockfile` | `false` | Fail when no lockfile is found, counting a lockfile that `exclude-paths` skipped as not found. |
| `allow-unchecked-yarn-artifacts` | `false` | Accept tracked `.yarn/cache/*.zip` and `.pnp.cjs` files instead of refusing them. |

## What it checks

It finds `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, and
`yarn.lock` anywhere under `path`. In a Git work tree it lists tracked files
plus untracked files that `.gitignore` doesn't exclude; elsewhere it walks the
directory. It never looks inside `node_modules`. Every lockfile that
`exclude-paths` skips prints `NOTICE excluded <file>`, and the run ends with a
`::warning` carrying the count. A lockfile that Git lists but the work tree
lacks is an error, not a skip.

| Lockfile | Read |
|---|---|
| npm lockfile versions 1, 2, and 3 | `resolved` and, for `dependencies` entries, `version`; for `packages`, each workspace and link path |
| `pnpm-lock.yaml` (v5 to v9) | parsed as YAML, every document, with `yq`: every `resolution` (`tarball`, `repo`, `directory`, `type`; a missing or non-mapping `resolution` fails), the source in each `packages` key, and every dependency, importer, catalog, and snapshot `version` and `specifier` that is not a plain version |
| `yarn.lock` classic | `resolved` lines and the source part of every descriptor in each entry header; an entry without `resolved` (other than `link:` and `file:`), with two, or with one at another indent fails |
| `yarn.lock` Berry | parsed as YAML with `yq`: the source part of the one `resolution` each entry must have |

A file is classic when a leading comment line reads `# yarn lockfile v1`, as
Yarn itself decides; anything else is read as Berry. YAML with duplicate
mapping keys fails, and anchors, aliases, and `<<` merges are expanded the way
the YAML spec says (a key in the entry wins over a merged one) before any
record is read.

## What it allows

A source passes only when it is one of these:

- A URL starting with `https://registry.npmjs.org/` or
  `https://registry.yarnpkg.com/`, or with an `https://` entry in
  `allowed-registries`. The match includes the trailing slash, so
  `registry.npmjs.org.example` and `registry.npmjs.org@example` fail.
- A plain version, range, or tag (a value with no `:`, `/`, or `\`), and the
  Yarn Berry `npm:` protocol. Berry's `npm:` carries no registry URL, and pnpm
  omits the tarball URL for the default registry, so those registries come
  from `.yarnrc.yml` and `.npmrc`, which this check does not read. A Berry
  `__archiveUrl` is checked against the allowed registries.
- `file:`, `link:`, `portal:`, `workspace:`, and bare `./` or `../` paths, only
  when the relative path stays inside the repository. Paths resolve against the
  lockfile's directory, a pnpm importer's directory, or the workspace named in a
  Berry `locator`. A symlink inside the repository that points outside is not
  followed.
- Berry `patch:` entries when the patched source passes these rules and every
  patch file is `builtin<...>` or a path inside the repository (`~/` is the
  repository root).

## What it refuses

Everything else, including `http:`, an `https:` tarball outside the approved
registries, `git:`, `git+ssh:`, `git+https:`, `github:`, `gitlab:`,
`bitbucket:`, `gist:`, a bare `user/repo` shorthand, `exec:`, an absolute or
`~` path, a `file:` or `link:` path that climbs out of the repository, a
Berry `patch:` of any of these, and any other protocol. A pnpm resolution
type other than a registry tarball, git, or directory, such as a Node runtime
download, also fails. Each offending package prints on its own line:

```
FAIL pnpm-lock.yaml: xlsx https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz (tarball outside approved registries)
```

The check fails, with exit code 2, rather than pass when:

- `yq` is missing, is not mikefarah v4.47.1 or newer, or can't parse a file
- a lockfile can't be parsed, or yields no records. A lockfile for a project
  with no dependencies counts as empty; add it to `exclude-paths`
- a `bun.lock` or `bun.lockb` exists, because it is not supported; add it to
  `exclude-paths` to accept it
- `require-lockfile` is set and no lockfile is found
- an `allowed-registries` entry isn't an `https://` URL
- a lockfile that Git lists is missing from the work tree

Exit code 1 means at least one source was refused, or a tracked
`.yarn/cache/*.zip`, `.pnp.cjs`, or `.pnp.loader.mjs` exists. Those hold
package contents or resolutions that no lockfile line describes; set
`allow-unchecked-yarn-artifacts` to accept them deliberately.

## Not covered

The check reads lockfiles only. It does not read:

- the zips in `.yarn/cache` and the `.pnp.cjs` Plug'n'Play map (it refuses
  them unless `allow-unchecked-yarn-artifacts` is set)
- `.pnpmfile.cjs`, which can rewrite dependencies at install time
- `.npmrc` and `.yarnrc.yml` registry overrides, which set where a plain
  version or an `npm:` entry downloads from
- `overrides`, `resolutions`, and `patchedDependencies` in manifests, except
  through the lockfile entries they produce
- a lockfile that no tool reads, or a manifest with no lockfile

## Local run and tests

```bash
SCAN_PATH=. bash scripts/lockfile-check/check.sh
```

`ALLOWED_REGISTRIES`, `EXCLUDE_PATHS`, `REQUIRE_LOCKFILE`,
`ALLOW_UNCHECKED_YARN_ARTIFACTS`, `AWK`, and `YQ` set the same options. The
scripts need `bash`, `jq`, `awk`, and, for pnpm and Yarn Berry, mikefarah
`yq` v4.47.1 or newer; they run under mawk and original-awk, the two awks CI
tests.

`scripts/lockfile-check/test-lockfile-check.sh`, run by
`test-lockfile-check.yaml`, runs every fixture in `testdata/` under each awk it
finds, then weakens one rule at a time in a copy of the scripts and fails
unless the fixtures catch each weakening. Fixture lockfiles end in `.fixture`
so dependency graphs and update bots ignore them. Set `TEST_AWKS` to choose
awks and `REQUIRE_AWKS` to fail when one is missing.
