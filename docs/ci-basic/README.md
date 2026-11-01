# Basic CI

The `.github/workflows/ci-basic.yaml` reusable workflow builds and tests a
repository on every pull request without publishing anything. It is meant for
repositories that have no CI of their own, so dependency updates are at least
built before they merge.

It detects each stack in `path` and runs what it finds:

| Stack | Detected by | Steps |
|---|---|---|
| Node | `package.json` plus `package-lock.json`, `pnpm-lock.yaml`, or `bun.lock`/`bun.lockb` | `npm ci`, `pnpm install --frozen-lockfile`, or `bun install --frozen-lockfile`, then the `typecheck`, `lint`, `build` and `test` scripts, each only when `package.json` defines it |
| Go | `go.mod` | `go build ./...`, `go test ./...` |
| Python | `pyproject.toml` plus `poetry.lock` | `poetry install`, then `poetry run pytest` when any `test_*.py` or `*_test.py` file exists |
| Docker | the `dockerfile` input, `Dockerfile` by default | `docker build`, never pushed |

When more than one Node lockfile is present, `package-lock.json` wins, then
`pnpm-lock.yaml`, then Bun's. A `package.json` without a lockfile fails the
job. Finding nothing to build, and no `run` command, also fails the job.

Toolchains come from the project: Node from `.nvmrc` or `.node-version`, pnpm
from the `packageManager` field (pnpm 10 without one), Go from `go.mod`, and
Python from `.python-version`. The `node-version` and `python-version` inputs
apply only when those files are missing.

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Project directory, relative to the repository root. |
| `skip` | None | Comma- or space-separated steps not to run: `typecheck`, `lint`, `build`, `test`, `docker`. An unknown name fails the job. For Go, `build` and `test` name the two `go` commands; for Python, `build` is `poetry install`. |
| `run` | None | Extra shell command, run in `path` after the detected steps, such as `node --check main.mjs`. |
| `dockerfile` | `Dockerfile` | Dockerfile to build, relative to `path`. Skipped when the file does not exist. |
| `docker-context` | `.` | Docker build context, relative to `path`. |
| `node-version` | `lts/*` | Node.js version when `path` has no `.nvmrc` or `.node-version`. |
| `python-version` | `3.12` | Python version when `path` has no `.python-version`. |

## Usage

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  ci:
    uses: datum-cloud/actions/.github/workflows/ci-basic.yaml@v1.26.0
```

Use `skip` to keep the check green while a step that fails on the default
branch is fixed, and track that fix in an issue. Make the check required in
the repository's ruleset once it has run green on a few pull requests.
