# Nix Update VendorHash

The `.github/workflows/nix-update-hash.yaml` reusable GitHub Action
automatically updates the `vendorHash` in `flake.nix` when Go dependencies
change. It opens a pull request targeting the branch that triggered the
workflow, keeping the dependency update and hash fix in the same review.

## Prerequisites

The calling repository must provide:

- A **`Taskfile.yml`** with a task matching `task-command` (default:
  `nix-update-hash`).
- A **script** (invoked by that task) that recomputes the `vendorHash` and
  writes it back to `flake.nix`. The task must run without arguments and exit
  non-zero on failure.

See [`datumctl/scripts/update-nix-hash.go`](https://github.com/datum-cloud/datumctl/blob/main/scripts/update-nix-hash.go)
for a reference implementation.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `go-version-file` | No | `go.mod` | Path to `go.mod`, used by `actions/setup-go` |
| `task-command` | No | `nix-update-hash` | Task command to run from the calling repo's `Taskfile.yml` |
| `flake-path` | No | `flake.nix` | Path to `flake.nix` checked for changes after the task runs |
| `pr-branch` | No | `nix/update-vendorhash` | Head branch for the opened PR (a timestamp suffix is appended) |
| `commit-message` | No | `chore(nix): update vendorHash for go deps` | Commit message |
| `pr-title` | No | `chore(nix): update vendorHash for go deps` | Pull request title |
| `pr-body` | No | `Automated vendorHash update for Go module dependency changes.` | Pull request body |

## Required Permissions

```yaml
permissions:
  contents: write
  pull-requests: write
```

## Usage

```yaml
name: nix-update-hash

on:
  push:
    paths:
      - 'go.mod'
      - 'go.sum'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  update-hash:
    uses: datum-cloud/actions/.github/workflows/nix-update-hash.yaml@main
    secrets: inherit
```

## How It Works

1. Checks out the repository at the triggering commit.
2. Installs Nix, Go, and Task.
3. Runs `task <task-command>` — the calling repo's script recomputes
   `vendorHash` and writes it back to `flake.nix`.
4. Diffs `flake.nix` — if unchanged, the workflow exits cleanly with no PR.
5. Opens a pull request from a timestamped branch (e.g.
   `nix/update-vendorhash-20240601-120000`) targeting **the branch that
   triggered the workflow**. This ensures the hash fix travels with the
   dependency update in the same PR review rather than landing separately on
   `main`.

## Best Practices

- Trigger on `push` with `paths: [go.mod, go.sum]` so the workflow only runs
  when Go dependencies actually change.
- Use `secrets: inherit` so `GITHUB_TOKEN` is available to both Nix and the
  `create-pull-request` action.
