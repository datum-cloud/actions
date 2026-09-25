# Update NOTICE

The `.github/workflows/update-notice.yaml` reusable GitHub Action regenerates
a repository's `NOTICE` file of third-party licenses when Go dependencies
change, committing the result directly back to the branch that triggered the
workflow. Dependency update pull requests, including Renovate's, then carry
their own license attribution update.

## Prerequisites

The calling repository must provide:

- A **`Taskfile.yml`** with a task matching `task-command` (default:
  `notice`).
- A **script or command** (invoked by that task) that rewrites `NOTICE` from
  the current dependency set. The task must run without arguments, produce
  the same output on Linux as locally, and exit non-zero on failure.

See [`datumctl/scripts/licenses/notice.sh`](https://github.com/datum-cloud/datumctl/blob/main/scripts/licenses/notice.sh)
for a reference implementation that uses `go-licenses` and covers every
platform the release builds for.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `go-version-file` | No | `go.mod` | Path to `go.mod`, used by `actions/setup-go` |
| `task-command` | No | `notice` | Task command to run from the calling repo's `Taskfile.yml` |
| `notice-path` | No | `NOTICE` | Path to the NOTICE file to check and commit after the task runs |
| `commit-message` | No | `chore: update NOTICE for go deps` | Commit message |

## Required Permissions

```yaml
permissions:
  contents: write
```

## Usage

```yaml
name: update-notice

on:
  push:
    branches-ignore:
      - main
    paths:
      - 'go.mod'
      - 'go.sum'
  workflow_dispatch:

permissions:
  contents: write

jobs:
  update-notice:
    uses: datum-cloud/actions/.github/workflows/update-notice.yaml@main
    secrets: inherit
```

## How It Works

1. Checks out the repository at the triggering commit.
2. Installs Go and Task.
3. Runs `task <task-command>`, which regenerates `NOTICE`.
4. Diffs `NOTICE`. If unchanged, exits cleanly with no commit.
5. Commits the updated `NOTICE` and pushes directly to the triggering branch.
   If another workflow triggered by the same push (such as
   [`nix-update-hash`](../nix-update-hash/)) pushed first, it rebases onto
   that commit and retries, up to three attempts.

## Best Practices

- Trigger on `push` with `paths: [go.mod, go.sum]` so the workflow only runs
  when Go dependencies actually change.
- Ignore `main` in the trigger. This workflow pushes directly to the
  triggering branch, and `go.mod` changes should arrive via a pull request
  branch.
- Commits pushed with `GITHUB_TOKEN` do not trigger other workflows, so the
  NOTICE commit does not re-run this workflow or the caller's CI.
