# Publish Kustomize Bundle (composite action)

Stamp **one or more** image references into a Kustomize bundle and push it to
GitHub Container Registry with Flux — as a **step inside the caller's job**.

This is the multi-image, in-job alternative to the reusable workflow
[`.github/workflows/publish-kustomize-bundle.yaml`](../.github/workflows/publish-kustomize-bundle.yaml).
Because it runs in the caller's job, it reuses the caller's existing checkout and
can read outputs from earlier build-and-push steps (one tag per image), then
stamp them all into a single bundle before pushing.

## Usage

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v4.2.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: provider   # build + push the provider image → outputs.tag
        uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1
        # ...
      - id: runtime    # build + push the runtime image  → outputs.tag
        uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1
        # ...

      - uses: datum-cloud/actions/publish-kustomize-bundle@v1.20.0
        with:
          bundle-name: ghcr.io/datum-cloud/unikraft-provider-kustomize
          bundle-path: config
          images: |
            - { path: config/default, name: ghcr.io/datum-cloud/unikraft-provider, tag: "${{ steps.provider.outputs.tag }}" }
            - { path: config/dependencies/ukp-runtime, name: ghcr.io/datum-cloud/ukp-runtime, tag: "${{ steps.runtime.outputs.tag }}" }
```

> Reference a tagged version to avoid unexpected breaking changes. Use a floating
> major (`@v1`) to track the latest compatible release, or pin an exact tag
> (`@v1.20.0`) for full reproducibility.

## Inputs

| Input         | Required | Default | Description |
| ------------- | -------- | ------- | ----------- |
| `bundle-name` | yes      | —       | Full bundle name including registry and repository (e.g. `ghcr.io/datum-cloud/unikraft-provider-kustomize`). |
| `bundle-path` | yes      | —       | Path to the bundle to push, relative to the repo root (e.g. `config`). |
| `images`      | yes      | —       | Multi-line YAML list of `{ path, name, tag }` entries to stamp before pushing (see below). |
| `debug`       | no       | `false` | Print the stamped `images:` blocks and bundle structure before pushing. |

### The `images` list

Each entry stamps one image into one kustomization directory:

- **`path`** — kustomization directory (relative to the repo root) to run
  `kustomize edit set image` in. Must contain a `kustomization.yaml`.
- **`name`** — image reference to rewrite (the `name=newName` target).
- **`tag`** — *optional*. When provided it is used verbatim. When omitted the
  entry falls back to the **bundle's first computed tag** (the same tag logic the
  reusable workflow uses), so images without their own build step still get a
  sensible version.

The bundle itself is stamped **once** and then pushed under **every** computed
tag (PR/branch/semver/sha variants), matching the reusable workflow's push loop.

## Outputs

| Output   | Description |
| -------- | ----------- |
| `tags`   | Newline-separated tags computed for the bundle. |
| `labels` | Labels computed for the bundle. |
| `digest` | Digest of the pushed bundle (from the final push). |

## Prerequisites

Composite actions run in the caller's job and **cannot** take a `secrets:` block
or set job `permissions:`. The caller's job must therefore provide, before this
step:

1. `actions/checkout` — the bundle and kustomization files are read from the
   working tree.
2. `docker/login-action` against `ghcr.io` — `flux push` authenticates using the
   caller's Docker credentials; there is no separate login here.
3. Job `permissions:` including `packages: write` and `contents: read`.
4. A runner with `kustomize`, `yq`, and `jq` available (GitHub-hosted Ubuntu
   runners have all three). Flux is installed by this action.

## Relationship to the reusable workflow

The reusable workflow
[`publish-kustomize-bundle.yaml`](../.github/workflows/publish-kustomize-bundle.yaml)
still exists and is unchanged. Use it when a **single** image (or none) needs
stamping in a **dedicated job**; use this composite action when several images —
each with its own build-step tag — must be stamped into **one** bundle from
**within** the caller's job. Whether to keep both long-term or deprecate the
reusable workflow is an open question for review.
