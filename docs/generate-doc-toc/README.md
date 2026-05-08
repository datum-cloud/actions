# Generate Doc TOC

The `.github/workflows/generate-doc-toc.yaml` reusable GitHub Action generates
and maintains tables of contents for markdown documentation using
[doctoc](https://github.com/thlorenz/doctoc). When docs change on the main
branch, it regenerates the TOC and commits the result automatically.

## 🚀 Usage

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `docs-path` | No | `docs/` | Path to the directory containing markdown docs |
| `node-version` | No | `20` | Node.js version to use |

### Required Permissions

```yaml
permissions:
  contents: write
```

### Basic Usage

```yaml
name: Generate Doc TOC

on:
  push:
    branches: [main]
    paths:
      - "docs/**/*.md"

jobs:
  generate-toc:
    uses: datum-cloud/actions/.github/workflows/generate-doc-toc.yaml@main
    permissions:
      contents: write
```

### Custom Docs Path

```yaml
jobs:
  generate-toc:
    uses: datum-cloud/actions/.github/workflows/generate-doc-toc.yaml@main
    with:
      docs-path: content/docs/
    permissions:
      contents: write
```

## How It Works

1. Checks out the repository at the current branch.
2. Installs `doctoc` via npm.
3. Runs `doctoc` against the docs directory. On first run, doctoc inserts TOC
   marker comments into each file. On subsequent runs it updates the TOC in place.
4. If any files changed, commits them back to the branch with `[skip ci]` to
   avoid triggering another workflow run.

TOC markers look like this and are added automatically on first run:

```markdown
<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
## Contents

- [Section One](#section-one)
- [Section Two](#section-two)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->
```

## Best Practices

- Trigger only on pushes to `main` (not PRs) to avoid commit conflicts on
  short-lived branches.
- Use the `paths` filter to limit runs to actual doc changes.
- The `[skip ci]` suffix on the commit message prevents the push from
  triggering another workflow run.
