# Update Plugin Index

The `update-plugin-index` composite action opens a pull request against a
[datumctl](https://github.com/datum-cloud/datumctl) plugin catalog (the "index
repo") whenever a service repo publishes a release. It bumps a single plugin's
manifest (`plugins/<plugin-name>.yaml`) to the new version: it sets
`spec.version` and, for every platform, rewrites the download `uri` to point at
the new tag and refreshes the `sha256` from the release's `checksums.txt`.

This replaces the manual step of hand-editing catalog manifests after each
release.

## Why a composite action (not a reusable workflow)

Cross-repo PRs need a token the caller's built-in `GITHUB_TOKEN` can't provide
(it only reaches its own repo), so callers mint a GitHub App installation token.
A GitHub App token minted in one job and handed to a **reusable workflow** (a
separate job) is scrubbed to an empty string — masked values do not survive
job-to-job outputs. A **composite action** runs inside the caller's job, so the
mint step and this action share one job and the token is passed directly as an
input. Mint and use must live in the same job; that's the whole reason this is
an action rather than a reusable workflow.

## Inputs

- **index-repo** (required): The plugin catalog repository to open the PR
  against (e.g. `milo-os/cli-plugins`).
- **plugin-name** (required): The plugin's short name, used to locate its
  manifest and label the PR (e.g. `ipam`).
- **plugin-file** (optional): Path to the plugin manifest within the index repo.
  Defaults to `plugins/<plugin-name>.yaml`.
- **version** (required): The release tag to publish, including the leading `v`
  (e.g. `v0.2.0`).
- **release-repo** (optional): The repository that published the release assets.
  Defaults to the calling repository (`github.repository`).
- **base-branch** (optional): Branch in the index repo to base the PR on.
  Defaults to `main`.
- **token** (required): A token with `contents:write` and `pull-requests:write`
  on `index-repo`. Mint it **in the same job** (e.g. with
  `actions/create-github-app-token`) and pass it here. The caller's built-in
  `GITHUB_TOKEN` cannot push a branch or open a PR on a different repository.

## How archives are mapped to checksums

The mapping is fully generic and never hardcodes a plugin name or archive
prefix:

1. The release's `checksums.txt` is downloaded (using the caller's
   `GITHUB_TOKEN`, since the release lives in the calling repo). Each line is
   `<sha256>  <filename>`; entries are keyed by the filename's **basename**.
2. For each entry in the manifest's existing `spec.platforms[]`, the archive
   name is taken from the **basename of that platform's current `uri`**.
   goreleaser archive names carry no version, so this basename is stable across
   releases.
3. That basename is looked up in `checksums.txt` to set the platform's `sha256`,
   and the `uri` is rewritten to
   `https://github.com/<release-repo>/releases/download/<version>/<basename>`.

If `checksums.txt` is missing, or any expected archive basename is not listed in
it, the action fails loudly.

## What it does not do

Regenerating `index.yaml` is left to the index repo's own generator, which
reconciles `index.yaml` from `plugins/*.yaml` on merge to its default branch.
This action only edits `plugins/<plugin-name>.yaml`.

## Workflow Example

Mint the App token and call the action in a **single job**, gated on the release
event:

```yaml
name: Release

on:
  release:
    types: [published]

jobs:
  # ... a job that publishes per-platform archives + checksums.txt as release
  # assets (e.g. goreleaser) ...

  update-plugin-index:
    needs: [publish-plugin]
    if: github.event_name == 'release'
    runs-on: ubuntu-latest
    steps:
      - name: Mint catalog token from a GitHub App
        id: app-token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.PLUGIN_INDEX_APP_ID }}
          private-key: ${{ secrets.PLUGIN_INDEX_APP_PRIVATE_KEY }}
          owner: milo-os
          repositories: cli-plugins

      - name: Open the catalog PR
        uses: datum-cloud/actions/update-plugin-index@v1
        with:
          index-repo: milo-os/cli-plugins
          plugin-name: ipam
          version: ${{ github.event.release.tag_name }}
          token: ${{ steps.app-token.outputs.token }}
```

## Best Practices

- Always reference a tagged version (e.g. `@v1`) to prevent unexpected breaking
  changes.
- Mint the token in the **same job** and pass it via `token:` — never across
  jobs.
- Depend on the release-asset-publishing job (`needs:`) so `checksums.txt`
  exists before this action reads it.
- Trigger on `release: published` only (or gate with
  `if: github.event_name == 'release'`) so the update runs exactly once per
  release.
