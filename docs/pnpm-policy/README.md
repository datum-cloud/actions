# pnpm Policy

The `.github/workflows/pnpm-policy.yaml` reusable workflow fails a pull
request when a pnpm project drops the org's install policy. It reads every
`pnpm-lock.yaml` under `path`, skipping `node_modules`, and checks the
`package.json` and `pnpm-workspace.yaml` beside it.

| Rule | Fails when |
|---|---|
| Pinned pnpm | `packageManager` is missing, isn't pnpm, or isn't the `pnpm-major` major |
| Release delay | `minimumReleaseAge` is missing, 0, or not a number of minutes |
| Trust policy | `trustPolicy` isn't `no-downgrade` |
| Install scripts | `dangerouslyAllowAllBuilds: true`, `allowBuilds` has a `'*'` entry, or `allowBuilds` isn't a map of package names |
| Workspace file | `pnpm-workspace.yaml` is missing beside the lockfile |
| Other lockfiles | with `require-pnpm: true`, any `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `bun.lock` or `bun.lockb` |

An `onlyBuiltDependencies` key is a warning, not a failure: it is the old
name for `allowBuilds`.

Exit codes: 0 clean, 1 violations, 2 bad inputs, a missing yq (mikefarah yq
v4), invalid JSON, a `pnpm-workspace.yaml` that isn't a mapping, or no
lockfile when `require-lockfile` is on.

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Directory to check, relative to the repository root. |
| `pnpm-major` | `12` | pnpm major version every `packageManager` pin must use. |
| `require-pnpm` | `false` | Also fail on lockfiles from npm, Yarn or Bun. Turn it on once the repository has moved to pnpm, so an npm lockfile can't come back. |
| `require-lockfile` | `false` | Fail with exit 2 when `path` has no `pnpm-lock.yaml`. Without it, an empty or mistyped `path` passes with "nothing to check". |

## Usage

```yaml
name: pnpm policy

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  pnpm-policy:
    uses: datum-cloud/actions/.github/workflows/pnpm-policy.yaml@v1.30.0
    with:
      require-pnpm: true
      require-lockfile: true
```

A compliant `pnpm-workspace.yaml`:

```yaml
minimumReleaseAge: 1440
minimumReleaseAgeExclude:
  - '@datum-cloud/*'
trustPolicy: no-downgrade
allowBuilds:
  esbuild: true
```

## Tests

`scripts/pnpm-policy/test-pnpm-policy.sh`, run by `test-pnpm-policy.yaml`,
runs `check.sh` against each case in `scripts/pnpm-policy/testdata/`. A case's
name sets its expected exit code (`pass-*` 0, `fail-*` 1, `error-*` 2);
`expect` and `absent` list output lines it must and must not print, and `env`
sets inputs. Fixture files end in `.fixture` so Renovate and the dependency
graph ignore them. The same workflow also runs the check on
`scripts/ci-basic/testdata/node-pnpm`.
