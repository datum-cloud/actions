# Publish npm Package

The `.github/workflows/publish-npm-package.yaml` reusable GitHub Action
automatically versions and publishes a pnpm monorepo package to **npm**.

It detects changes to the package path on every push to `main`, determines the
version bump type from PR labels (`release:major`, `release:minor`, or
`patch` as the default), commits the version bump, and publishes with
[npm provenance](https://docs.npmjs.com/generating-provenance-statements).

## Inputs

- **package-name** (required): The npm package name (e.g. `@datum-cloud/datum-ui`).
- **package-path** (required): Path to the package directory relative to the
  repo root (e.g. `packages/datum-ui`).
- **node-version** (optional, default: `26`): Node.js version to use.

## Outputs

- **new-version**: The new version that was published (e.g. `v1.2.3`).

## Version Bump Strategy

The workflow reads labels from the PR that was merged into the triggering
commit:

| Label | Bump |
|-------|------|
| `release:major` | major |
| `release:minor` | minor |
| _(none)_ | patch |

## Best Practices

- Always use a tagged version when referencing this workflow to prevent
  unexpected breaking changes.
- Add `release:major` or `release:minor` labels to PRs before merging when
  you want a non-patch bump.
- The workflow skips bot commits automatically, so the version bump commit it
  pushes will not trigger a second publish run.

## Workflow Example

Create a workflow in your repository (e.g., `.github/workflows/publish.yaml`)
that calls this reusable action:

```yaml
name: Publish datum-ui

on:
  push:
    branches:
      - main

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  publish-datum-ui:
    uses: datum-cloud/actions/.github/workflows/publish-npm-package.yaml@v1.23.0
    with:
      package-name: "@datum-cloud/datum-ui"
      package-path: packages/datum-ui
```
