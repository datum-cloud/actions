# Nix Update VendorHash

The `.github/workflows/nix-update-hash.yaml` reusable GitHub Action
automatically updates the `vendorHash` in `flake.nix` when Go dependencies
change, committing the result directly back to the branch that triggered the
workflow.

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
| `flake-path` | No | `flake.nix` | Path to `flake.nix` to check and commit after the task runs |
| `commit-message` | No | `chore(nix): update vendorHash for go deps` | Commit message |

## Required Permissions

```yaml
permissions:
  contents: write
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
4. Diffs `flake.nix` — if unchanged, exits cleanly with no commit.
5. Commits the updated `flake.nix` and pushes directly to the triggering
   branch, keeping the hash fix in the same branch as the dependency update.

## Best Practices

- Trigger on `push` with `paths: [go.mod, go.sum]` so the workflow only runs
  when Go dependencies actually change.
- Use `secrets: inherit` so `GITHUB_TOKEN` is available to both Nix and the
  push step.
- This workflow pushes directly to the triggering branch. Do not trigger it on
  `main` — `go.mod` changes should always arrive via a pull request branch.
