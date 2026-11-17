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
    uses: datum-cloud/actions/.github/workflows/lockfile-check.yaml@v1.23.0
```

The workflow needs only `contents: read`. It runs `jq` and `awk` over the
committed files and installs nothing from the repository.

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Directory to check, relative to the repository root. |
| `exclude-paths` | None | Comma- or newline-separated globs, relative to `path`, of lockfiles not to check. |
| `allowed-registries` | None | Comma- or newline-separated `https://` registry URLs accepted besides the two defaults, such as `https://npm.pkg.github.com`. |
| `require-lockfile` | `false` | Fail when no lockfile is found. |

## What it checks

It finds `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, and
`yarn.lock` anywhere under `path`. In a Git work tree it lists tracked files
plus untracked files that `.gitignore` doesn't exclude; elsewhere it walks the
directory. It never looks inside `node_modules`.

| Lockfile | Read |
|---|---|
| npm lockfile versions 1, 2, and 3 | `resolved` and, for `dependencies` entries, `version`; for `packages`, each workspace and link path |
| `pnpm-lock.yaml` (v5 to v9) | `resolution` entries (`tarball`, `repo`, `directory`, `type`) and every `version:` and dependency value that is not a plain version |
| `yarn.lock` classic | `resolved` lines and the source part of every descriptor in each entry header |
| `yarn.lock` Berry | the source part of every `resolution:` value |

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

- a lockfile can't be parsed, or yields no records. A lockfile for a project
  with no dependencies counts as empty; add it to `exclude-paths`
- a `bun.lock` or `bun.lockb` exists, because it is not supported; add it to
  `exclude-paths` to accept it
- `require-lockfile` is set and no lockfile is found
- an `allowed-registries` entry isn't an `https://` URL

Exit code 1 means at least one source was refused.

## Local run and tests

```bash
SCAN_PATH=. bash scripts/lockfile-check/check.sh
```

`ALLOWED_REGISTRIES`, `EXCLUDE_PATHS`, `REQUIRE_LOCKFILE`, and `AWK` set the
same options. The scripts need `bash`, `jq`, and any `awk`; they run under
BSD awk and mawk.

`scripts/lockfile-check/test-lockfile-check.sh`, run by
`test-lockfile-check.yaml`, runs every fixture in `testdata/` under each awk it
finds, then weakens one rule at a time in a copy of the scripts and fails
unless the fixtures catch each weakening. Fixture lockfiles end in `.fixture`
so dependency graphs and update bots ignore them. Set `TEST_AWKS` to choose
awks and `REQUIRE_AWKS` to fail when one is missing.
