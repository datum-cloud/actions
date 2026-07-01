# Update Plugin Index

The `.github/workflows/update-plugin-index.yaml` reusable GitHub Action opens a
pull request against a [datumctl](https://github.com/datum-cloud/datumctl)
plugin catalog (the "index repo") whenever a service repo publishes a release.
It bumps a single plugin's manifest (`plugins/<plugin-name>.yaml`) to the new
version: it sets `spec.version` and, for every platform, rewrites the download
`uri` to point at the new tag and refreshes the `sha256` from the release's
`checksums.txt`.

This replaces the manual step of hand-editing catalog manifests after each
release.

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

## Secrets

- **PLUGIN_INDEX_TOKEN** (required): A token with `contents:write` and
  `pull-requests:write` permission on `index-repo`. A caller's built-in
  `GITHUB_TOKEN` is scoped to its own repository and **cannot** push a branch or
  open a PR on a different repository, so a cross-repo credential — a Personal
  Access Token or a GitHub App installation token — is required. Store it as a
  repository or organization secret on the calling repo.

## How archives are mapped to checksums

The mapping is fully generic and never hardcodes a plugin name or archive
prefix:

1. The release's `checksums.txt` is downloaded. Each line is
   `<sha256>  <filename>`; entries are keyed by the filename's **basename**.
2. For each entry in the manifest's existing `spec.platforms[]`, the archive
   name is taken from the **basename of that platform's current `uri`**.
   goreleaser archive names carry no version, so this basename is stable across
   releases.
3. That basename is looked up in `checksums.txt` to set the platform's `sha256`,
   and the `uri` is rewritten to
   `https://github.com/<release-repo>/releases/download/<version>/<basename>`.

If `checksums.txt` is missing, or any expected archive basename is not listed in
it, the workflow fails loudly.

## What it does not do

Regenerating `index.yaml` is left to the index repo's own generator, which
reconciles `index.yaml` from `plugins/*.yaml` on merge to its default branch.
This workflow only edits `plugins/<plugin-name>.yaml`.

## Workflow Example

Add a job that runs when a release is published:

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
    uses: datum-cloud/actions/.github/workflows/update-plugin-index.yaml@v1
    with:
      index-repo: milo-os/cli-plugins
      plugin-name: ipam
      version: ${{ github.event.release.tag_name }}
    secrets:
      PLUGIN_INDEX_TOKEN: ${{ secrets.PLUGIN_INDEX_TOKEN }}
```

## Best Practices

- Always reference a tagged version (e.g. `@v1`) to prevent unexpected breaking
  changes.
- Depend on the release-asset-publishing job (`needs:`) so `checksums.txt`
  exists before this workflow reads it.
- Trigger on `release: published` only (or gate with
  `if: github.event_name == 'release'`) so the update runs exactly once per
  release.
