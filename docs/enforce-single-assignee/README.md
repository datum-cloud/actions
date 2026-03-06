# Enforce Single Assignee

The `.github/workflows/enforce-single-assignee.yaml` reusable GitHub Action
enforces a maximum of one assignee per issue. When more than one assignee is
detected, all but the most recently assigned user are automatically removed.

## Usage

### Inputs

This workflow does not require any inputs.

### Required Permissions

The calling repository's GITHUB_TOKEN must have `issues: write` permission.
This is typically granted by default, but can be explicitly set:

```yaml
permissions:
  issues: write
```

### Behavior

| Assignee count | Action taken |
|---|---|
| 0 or 1 | No action taken |
| 2+ | All assignees are removed and a comment is posted listing who was attempted, asking the team to assign a single owner |

## Calling Example

Create a workflow in your repository (e.g., `.github/workflows/enforce-assignees.yaml`):

```yaml
name: Enforce Single Assignee

on:
  issues:
    types: [assigned]

jobs:
  enforce:
    uses: datum-cloud/actions/.github/workflows/enforce-single-assignee.yaml@v1
    secrets: inherit
```

## Troubleshooting

### Workflow fails with permission error

`secrets: inherit` is required in the calling workflow so that `GITHUB_TOKEN`
is passed through to the reusable workflow. Without it, the `GH_TOKEN`
environment variable will be empty and the GitHub API call will fail.

### Workflow not triggered

Verify the calling workflow is triggered on `issues: [assigned]`. Other issue
event types (e.g., `opened`, `edited`) will not trigger this workflow.
