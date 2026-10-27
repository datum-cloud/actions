# Vulnerability scan

The `.github/workflows/vuln-scan.yaml` reusable workflow scans a repository
for known vulnerabilities and fails when it finds one that isn't explicitly
ignored. Call it on every pull request and on a weekly schedule. The weekly
run catches advisories published after the code last changed.

The workflow picks a scanner for each kind of dependency:

| Ecosystem | Files | Scanner |
|---|---|---|
| `go` | Each directory with a `go.mod` | [`govulncheck`](https://go.dev/doc/tutorial/govulncheck), which reports only vulnerabilities that your code calls |
| `node` | `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock` | [`osv-scanner`](https://google.github.io/osv-scanner/) |
| `python` | `requirements*.txt`, `poetry.lock`, `Pipfile.lock`, `uv.lock`, `pdm.lock`, `pylock.toml` | `osv-scanner` |
| `rust` | `Cargo.lock` | `osv-scanner` |
| Container images | References in the `images` input | [Trivy](https://trivy.dev/) |

## What gets scanned

The workflow finds these files anywhere under `path`, including Go modules in
subdirectories:

- In a Git work tree, it lists files with Git: tracked files, plus untracked
  files that `.gitignore` doesn't exclude. Build output that your
  `.gitignore` excludes, such as `dist/` or `target/`, isn't scanned.
  Submodules and nested Git repositories aren't scanned, and the job summary
  lists them. Scan each from its own repository.
- Outside a Git work tree, it walks `path` and skips `.git`, `node_modules`,
  `vendor`, `testdata`, and `.venv` directories.

Either way, it skips files under a `node_modules`, `vendor`, or `testdata`
directory, which hold other projects' dependencies or test fixtures.

A manifest without a lockfile has no pinned versions to scan. The job summary
lists each `package.json`, `Cargo.toml`, or `pyproject.toml` that has no
lockfile in its own directory or any parent directory up to `path`, and adds a
warning. A workspace member, covered by its workspace root's lockfile, isn't
listed. Commit a lockfile, or add a manifest without dependencies to
`exclude-paths`.

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Directory to scan, relative to the repository root. |
| `ecosystems` | `auto` | `auto` scans every ecosystem found. A comma-separated list, such as `go,node`, scans only those ecosystems and fails if one of them has no dependency files. |
| `exclude-paths` | None | Comma- or newline-separated globs, relative to `path`, of files or directories not to scan, such as `examples/*`. |
| `include-dev-dependencies` | `false` | Also scan dev dependencies. See [Dev dependencies](#dev-dependencies). |
| `images` | None | Comma- or newline-separated container image references to scan with Trivy. Each image must be pullable without credentials. |
| `image-severity` | `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL` | Trivy severities that fail the scan. |
| `image-ignore-unfixed` | `true` | Skip image vulnerabilities that have no fixed version yet. |
| `go-version` | None | Go version for `govulncheck`, which decides which Go standard library vulnerabilities apply. When empty, the workflow picks it from your `go.mod` files. See [Go version](#go-version). |
| `allow-empty` | `false` | Pass, with a warning, when there is nothing to scan. |

## Required permissions

```yaml
permissions:
  contents: read
```

## Usage

Add `.github/workflows/vuln-scan.yaml` to the calling repository:

```yaml
name: Vulnerability scan

on:
  pull_request:
  push:
    branches:
      - main
  schedule:
    # Weekly, Monday 06:00 UTC.
    - cron: "0 6 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  vuln-scan:
    uses: datum-cloud/actions/.github/workflows/vuln-scan.yaml@v1
```

To make the scan block merges, add the `vuln-scan / Scan for vulnerabilities`
check to the branch's required status checks.

### Narrow the scan

Scan only the Go modules and skip example code:

```yaml
jobs:
  vuln-scan:
    uses: datum-cloud/actions/.github/workflows/vuln-scan.yaml@v1
    with:
      ecosystems: go
      exclude-paths: examples/*
```

### Scan a published image

```yaml
jobs:
  vuln-scan:
    uses: datum-cloud/actions/.github/workflows/vuln-scan.yaml@v1
    with:
      images: ghcr.io/example-org/example-app:latest
```

### A repository with nothing to scan

If a repository has no dependency files, such as a repository of shell
scripts or documentation, the scan fails by default. A scan that checks
nothing and passes would look the same as a clean scan. Set `allow-empty` to
record that the repository has nothing to scan:

```yaml
jobs:
  vuln-scan:
    uses: datum-cloud/actions/.github/workflows/vuln-scan.yaml@v1
    with:
      allow-empty: true
```

The scan still auto-detects ecosystems. If someone adds a lockfile later, the
scan covers it.

A manifest without a lockfile, such as a lone `package.json`, means the
repository has dependencies that the scan can't check, so `allow-empty`
doesn't cover it. If nothing else was scanned, the job fails. If the manifest
has no dependencies, add it to `exclude-paths`.

## Results

The job fails when any of these happen:

- A scanner reports a known vulnerability that no ignore entry covers.
- A scanner exits with an error.
- A dependency file can't be scanned, such as a binary `bun.lockb`.
- There is nothing to scan and `allow-empty` is `false`.
- Nothing was scanned and a manifest has no lockfile, whatever `allow-empty`
  is set to.
- An entry in `osv-scanner.toml` has no `reason` or no `ignoreUntil`, or an
  `ignoreUntil` more than 12 months after the day of the scan.

An informational advisory doesn't fail the job. The RustSec database uses
these for crates that are unmaintained or unsound rather than vulnerable, and
`cargo audit` reports them as warnings for the same reason. The scan lists
them in the log and adds a warning annotation. If any advisory in a group of
aliases isn't informational, such as a GitHub advisory for the same issue, the
group fails the job.

The job summary lists every dependency file and image the workflow found and
what happened to each: scanned and clean, scanned with findings, or not
scanned and why. The job log lists each finding with its advisory IDs,
package, version, fixed versions, and summary.

## Run it locally

`scripts/vuln-scan/run.sh` runs the same scan on your workstation, with the
same scripts, scanner versions, and Go version as CI, so you don't have to
wait for a pull request. It needs `bash`, `git`, `curl`, and `jq`, plus `go`
when the repository has Go modules, and `python3` 3.11 or later when the
repository has an `osv-scanner.toml`. [How it works](#how-it-works) says why
Python. It reads the same
settings as the workflow inputs from environment variables, such as
`ECOSYSTEMS`, `EXCLUDE_PATHS`, `ALLOW_EMPTY`, and `GO_VERSION`. Run
`run.sh --help` for the full list.

It exits non-zero on the same results that fail the workflow. A newly
published advisory can make it fail without any change to your code, the same
as the weekly CI run.

### From your repository's Taskfile

Add these tasks to your repository's `Taskfile.yml`. If you already have a
`ci` task, add `vuln-scan` to its `deps`.

<!-- taskfile-snippet -->
```yaml
version: "3"

vars:
  # A tag. Keep it equal to the ref in your vuln-scan workflow's uses: line;
  # Renovate doesn't update it.
  ACTIONS_REF: v1
  ACTIONS_REPO: https://github.com/datum-cloud/actions.git

tasks:
  ci:
    deps: [vuln-scan]

  vuln-scan:
    desc: Scan dependencies for known vulnerabilities, the same way CI does
    # Needs bash, git, curl, and jq, plus go for Go modules, and python3 3.11
    # or later (for tomllib) when the repository has an osv-scanner.toml.
    vars:
      # Scripts are cached per commit, so a tag that moves, such as v1, is
      # fetched again.
      COMMIT:
        sh: git ls-remote "{{.ACTIONS_REPO}}" "refs/tags/{{.ACTIONS_REF}}" "refs/tags/{{.ACTIONS_REF}}^{}" | tail -n 1 | cut -f 1
      SCRIPTS:
        sh: echo "${XDG_CACHE_HOME:-$HOME/.cache}/datum-vuln-scan/scripts/{{.COMMIT}}"
    cmds:
      - test -n "{{.COMMIT}}" || (echo "{{.ACTIONS_REPO}} has no tag {{.ACTIONS_REF}}" >&2; exit 1)
      - task: vuln-scan:fetch
        vars: { COMMIT: "{{.COMMIT}}", SCRIPTS: "{{.SCRIPTS}}" }
      - bash "{{.SCRIPTS}}/scripts/vuln-scan/run.sh"

  vuln-scan:fetch:
    internal: true
    status:
      - test -f "{{.SCRIPTS}}/scripts/vuln-scan/run.sh"
    cmds:
      - rm -rf "{{.SCRIPTS}}.tmp"
      - git clone --quiet --depth 1 --branch "{{.ACTIONS_REF}}" --no-checkout "{{.ACTIONS_REPO}}" "{{.SCRIPTS}}.tmp"
      - test "$(git -C "{{.SCRIPTS}}.tmp" rev-parse HEAD)" = "{{.COMMIT}}"
      - git -C "{{.SCRIPTS}}.tmp" sparse-checkout set --no-cone '/scripts/vuln-scan/*.sh' '/scripts/vuln-scan/*.py'
      - git -C "{{.SCRIPTS}}.tmp" checkout --quiet
      - mv "{{.SCRIPTS}}.tmp" "{{.SCRIPTS}}"
```

Then run `task vuln-scan`, or `task ci`.

The first run fetches only the scan scripts from this repository at
`ACTIONS_REF` and caches them. Later runs reuse the cache until the tag points
at a different commit. Each run checks the tag with `git ls-remote`, so it
needs network access, as the scan does.

Keep `ACTIONS_REF` equal to the ref in your workflow's `uses:` line, such as
`v1` in `vuln-scan.yaml@v1`, so that the local scan matches CI. Renovate
doesn't update `ACTIONS_REF`, so change it by hand when you change the
workflow's ref.

### From a clone of this repository

In the repository you want to scan, run the script from your clone:

```sh
bash ~/src/actions/scripts/vuln-scan/run.sh
```

To scan another directory, set `SCAN_PATH`:

```sh
SCAN_PATH=path/to/repository bash scripts/vuln-scan/run.sh
```

### Go version on your workstation

`run.sh` selects the Go version the same way the workflow does, then sets
`GOTOOLCHAIN` to it. The `go` command downloads that version if it isn't
cached, so standard library findings match CI even when your installed Go is
newer. If the download fails, such as when you're offline, the scan stops
with an error.

### Cache

`run.sh` caches scanner binaries under
`${XDG_CACHE_HOME:-$HOME/.cache}/datum-vuln-scan/bin`, one directory per tool
version, so a version change installs the new one. The Taskfile caches the
scan scripts under `datum-vuln-scan/scripts` in the same directory, one
directory per commit. To clear both, delete the directory:

```sh
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/datum-vuln-scan"
```

Go toolchains that `run.sh` downloads live in Go's own module cache.

## Ignore a vulnerability

Fix a reported vulnerability by upgrading the dependency when you can. When
you can't, add an ignore entry to the scanners' own ignore file at the root of
`path`, so that the suppression goes through code review.

### Dependencies and Go modules

Add an entry to `osv-scanner.toml`. The workflow applies it to `osv-scanner`
and to `govulncheck` findings, because `govulncheck` has no ignore file of its
own.

```toml
[[IgnoredVulns]]
id = "GO-2022-1059"
ignoreUntil = 2026-12-31
reason = "Only parses headers set by our own proxy. Upgrade: example-org/app#123."
```

- `id` is the advisory ID that the scan reported.
- `reason` is required. The scan fails on an entry without one.
- `ignoreUntil` is required, and can be at most 12 months after the day of
  the scan. The scan fails on an entry without one, or with a later date, and
  the error names the latest date allowed. After `ignoreUntil`, the entry stops
  applying and the scan fails again, so that someone reviews it.

`osv-scanner` applies these entries itself. For `govulncheck` findings, the
workflow reimplements the matching: an entry matches a finding by its Go
advisory ID or by any of its aliases, such as its CVE or GHSA ID, and stops
applying at its `ignoreUntil`. These are two separate implementations of the
same file, so they can disagree on an entry. To avoid that, ignore an
advisory by the ID that the scan reported for it.

The workflow reads only the `osv-scanner.toml` at the root of `path`. It
ignores files of that name in subdirectories.

### Container images

Add an entry to `.trivyignore.yaml`, or `.trivyignore`, at the root of `path`.
See
[Trivy's filtering documentation](https://trivy.dev/latest/docs/configuration/filtering/).

```yaml
vulnerabilities:
  - id: CVE-2023-42363
    expired_at: 2026-12-31
    statement: Busybox awk isn't run in this image.
```

### Protect the ignore files

Add the ignore files to the repository's `CODEOWNERS`, so that a suppression
needs approval from the people responsible for security:

```text
/osv-scanner.toml   @example-org/security
/.trivyignore.yaml  @example-org/security
```

## Dev dependencies

By default, the scan covers production dependencies only where it can tell
them apart:

- In npm `package-lock.json` files, packages marked as dev dependencies are
  skipped.
- Requirements files named for development, testing, linting, or docs, such
  as `requirements-dev.txt` or `requirements/test.txt`, are skipped.

The other lockfiles (`pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, Python
lockfiles, and `Cargo.lock`) don't mark dev dependencies in a form
`osv-scanner` reads, so the scan covers every package in them. A vulnerable dev
dependency in those files fails the scan.

Set `include-dev-dependencies: true` to scan dev dependencies everywhere.

## Go version

`govulncheck` reports standard library vulnerabilities for the Go version it
runs with. The workflow installs one Go version for all modules, chosen from
your `go.mod` files:

1. It finds the highest Go minor version, such as `1.26`, among the modules'
   `go` and `toolchain` directives.
1. If a module in that minor version has a `toolchain goX.Y.Z` line, the
   workflow uses exactly that version, as long as it meets every module's
   `go` directive. With several such lines, it uses the highest.
1. Otherwise, it uses the latest patch release of that minor version. The
   `go` directive is a minimum, written as `X.Y.0`, while release builds with
   an image like `golang:X.Y` use the latest patch. Scanning with `X.Y.0`
   would report standard library vulnerabilities that your builds already
   fix.

The job summary says which version was used and which `go.mod` set it. The
scan fails if the installed Go doesn't match the version it asked for.

Set the `go-version` input to override this choice, such as to match a
Dockerfile that pins a patch release.

The scan runs with `GOTOOLCHAIN=local`. If a module requires a newer Go than
the installed one, `govulncheck` fails and the job fails, instead of
downloading another version.

## How it works

1. Checks out the calling repository. Then checks out only the scripts from
   this repository's `scripts/vuln-scan` directory, at the same commit as the
   workflow, and moves them out of the workspace. The test fixtures next to
   the scripts aren't checked out.
2. Runs `scripts/vuln-scan/detect.sh` to list what to scan.
3. Installs Go when there are Go modules, then installs only the scanners the
   scan needs. Scanner versions are pinned in
   `scripts/vuln-scan/install-tools.sh`, and Renovate updates them.
4. Runs `scripts/vuln-scan/scan.sh`, which runs each scanner, writes the job
   summary, and fails the job if any target failed.
   `scripts/vuln-scan/findings.sh` reads the scanners' JSON output with `jq`
   to apply ignore entries and skip informational advisories.

The scripts are Bash, with `awk`, `sed`, `grep`, and `jq`, which GitHub-hosted
runners have preinstalled. The one exception is
`scripts/vuln-scan/toml-to-json.py`, which converts `osv-scanner.toml` to JSON
for `jq`. None of those tools can parse TOML, a hand-written parser could read
a suppression differently from `osv-scanner`, and Python's `tomllib` is the
only TOML parser preinstalled on the runners. So the scan needs Python 3.11
or later, but only when the repository has an `osv-scanner.toml`.

## Limitations

- `govulncheck` analyzes code for Linux on amd64 with default build tags. A
  vulnerable call that only builds for another platform or with a build tag
  isn't reported.
- One Go version serves every module. In a repository whose modules use
  different Go minor versions, modules on older versions are scanned with the
  newest one, which can miss standard library vulnerabilities fixed only in
  newer releases.
- Without a `toolchain` line, the scan assumes release builds use the latest
  patch of the `go` directive's minor version. If yours pin an older patch,
  set `go-version`.
- Private Go modules, private npm registries, and images that need
  credentials aren't supported. The workflow has only `contents: read` access.
- For a `requirements.txt` with version ranges instead of pinned versions,
  `osv-scanner` resolves the dependencies through the
  [deps.dev](https://deps.dev/) API. The versions it picks can differ from
  what `pip` installs, so findings can include versions you don't run. Pin
  versions, or use a lockfile, for accurate results.
- Images are scanned after they're published, not as part of the pull request
  that builds them.

## Test the workflow

`.github/workflows/test-vuln-scan.yaml` runs
`scripts/vuln-scan/test-vuln-scan.sh` on every change to the workflow and
weekly. The test scans fixtures in `scripts/vuln-scan/testdata` and checks
each outcome:

- Each ecosystem fails on a known-vulnerable dependency and names the advisory.
- Clean fixtures pass, including a Go module that requires a vulnerable module
  version but never calls the vulnerable code.
- Informational RustSec advisories don't fail the scan.
- Ignore entries suppress only what they name and expire on their date. An
  entry without a reason or an `ignoreUntil` fails the scan, and so does one
  13 months away, while one 11 months away passes.
- Nothing to scan fails unless `allow-empty` is `true`.
- In a Git work tree, ignored files aren't scanned and untracked ones are.
  Outside one, the scan falls back to walking the directory.
- Manifests without a lockfile are listed, and workspace members aren't.
- `run.sh` fails on vulnerable fixtures, passes clean ones, reuses cached
  scanners, and scans with the selected Go through `GOTOOLCHAIN`.
- The Taskfile snippet fetches the scripts once per tag commit and matches
  `scripts/vuln-scan/Taskfile.example.yml` exactly.
- The Go version follows the `toolchain` and `go` directives, a mismatch
  between the installed and requested Go fails the scan, and so does a module
  that needs a newer Go.

To run the test locally, put `go`, `git`, `task`, `jq`, `govulncheck`,
`osv-scanner`, and `python3` on your `PATH`, then run:

```sh
bash scripts/vuln-scan/test-vuln-scan.sh
```

Set `TEST_IMAGES=true` to also test image scanning, which needs `trivy`.
