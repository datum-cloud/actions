# Plugin catalog

A datumctl plugin catalog is a repository with one manifest per plugin in
`plugins/<name>.yaml` and an `index.yaml` built from them. `datumctl` reads
`index.yaml` to search for, install, and upgrade plugins. Four reusable
workflows run a catalog, so every catalog validates, rebuilds, and updates the
same way:

- **`plugin-catalog-validate.yaml`**, on every pull request: checks every
  manifest against the schema, runs `datumctl plugin index validate` on the
  index they build, and downloads the archives of changed manifests to check
  each `sha256`.
- **`plugin-catalog-index.yaml`**, on pushes to the default branch that change
  `plugins/`: rebuilds `index.yaml` and opens a pull request with it, set to
  merge once required checks pass.
- **`plugin-catalog-scan.yaml`**, daily: opens or refreshes an update pull
  request for each plugin whose upstream repository published a newer release.
- **`plugin-catalog-health.yaml`**, weekly: re-checks every manifest and archive
  and that `index.yaml` matches `plugins/`, and opens an issue on failure.

A plugin's own release updates its catalog entry through the
[`update-plugin-index`](../update-plugin-index/README.md) action. The scan is
the backstop for when that update fails, and it reuses the pull request the
action opened, so each plugin has one open update.

## Set up a catalog

The catalog needs a GitHub App installed on it with **Contents** and **Pull
requests** read and write permission. The index rebuild and the scan push with
the App's token, not `GITHUB_TOKEN`, for two reasons:

- GitHub holds the workflow runs of anything `GITHUB_TOKEN` pushes until a
  maintainer approves them, so required checks would never report on their
  own.
- Commits the App makes through the API are signed, which branch rules that
  require signed commits accept.

Turn on **Allow auto-merge** in the catalog's settings, or set `auto-merge:
false` on the rebuild. If the catalog runs a contributor license agreement
check, add the App's bot account to its allowlist, or the check stays pending
on every pull request the App opens.

Then add the callers. Replace `vX.Y.Z` with the latest tag from the
[releases page](https://github.com/datum-cloud/actions/releases); Renovate
keeps the pin current from then on.

```yaml
# .github/workflows/ci.yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  ci:
    uses: datum-cloud/actions/.github/workflows/plugin-catalog-validate.yaml@vX.Y.Z
    with:
      # Match the status check the branch rules require: "ci / Build and test".
      check-name: Build and test
```

```yaml
# .github/workflows/rebuild-index.yaml
name: Rebuild index
on:
  push:
    branches: [main]
    paths: ["plugins/**"]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  rebuild:
    uses: datum-cloud/actions/.github/workflows/plugin-catalog-index.yaml@vX.Y.Z
    with:
      name: acme
      description: CLI plugins for the Acme platform
      owner: acme-corp
      homepage: https://github.com/acme-corp/datumctl-plugins
    secrets:
      app-id: ${{ secrets.CATALOG_APP_ID }}
      app-private-key: ${{ secrets.CATALOG_APP_PRIVATE_KEY }}
```

```yaml
# .github/workflows/scan-releases.yaml
name: Scan releases
on:
  schedule:
    - cron: "17 6 * * *"
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: false
permissions:
  contents: read
jobs:
  scan:
    uses: datum-cloud/actions/.github/workflows/plugin-catalog-scan.yaml@vX.Y.Z
    with:
      dry-run: ${{ inputs.dry-run || false }}
    secrets:
      app-id: ${{ secrets.CATALOG_APP_ID }}
      app-private-key: ${{ secrets.CATALOG_APP_PRIVATE_KEY }}
```

```yaml
# .github/workflows/catalog-health.yaml
name: Catalog health
on:
  schedule:
    - cron: "0 12 * * 1"
  workflow_dispatch:
permissions:
  contents: read
jobs:
  health:
    uses: datum-cloud/actions/.github/workflows/plugin-catalog-health.yaml@vX.Y.Z
    permissions:
      contents: read
      issues: write
    with:
      # The same header the rebuild writes, so the drift check compares like
      # with like.
      name: acme
      description: CLI plugins for the Acme platform
      owner: acme-corp
      homepage: https://github.com/acme-corp/datumctl-plugins
```

## Manifest schema

The schema is
[`scripts/plugin-catalog/schema/plugin-v1alpha1.json`](../../scripts/plugin-catalog/schema/plugin-v1alpha1.json).
Catalogs don't keep a copy, so link to it at the tag your workflows pin.

The schema may be stricter than `datumctl`, never looser: a manifest the schema
accepts and `datumctl` rejects would pass the catalog's checks and then fail
for everyone who installs it. So, beyond the fields `datumctl` reads, the
schema requires:

- An HTTPS download URL with a host.
- A lowercase hex `sha256`.
- A platform selector of `matchLabels` with only `os` and `arch`.

`test_catalog.py` checks the schema against `datumctl plugin index validate`
on cases the two could disagree on, and fails when the schema accepts one that
`datumctl` rejects. The validate and health workflows also run `datumctl` on
the catalog's own index.

## Inputs

### `plugin-catalog-validate.yaml`

- **path** (default `.`): Catalog root, relative to the repository root.
- **download** (default `changed`): Whose archives to download and check.
  `changed` means the manifests a pull request adds or changes, and nothing on
  other events. Also `all` or `none`.
- **check-name** (default `Validate plugin catalog`): The job name, so the
  status check can match the one the branch rules require. It shows as
  `<caller job> / <check-name>`.

### `plugin-catalog-index.yaml`

- **path** (default `.`): Catalog root.
- **name**, **description**, **owner**, **homepage** (default empty): The
  catalog header that `datumctl plugin index list` and `datumctl plugin browse`
  show. Empty fields are left out of `index.yaml`.
- **branch** (default `regenerate-index`): Branch the rebuild pull request is
  opened from.
- **auto-merge** (default `true`): Set the rebuild pull request to merge once
  required checks pass.
- Secrets **app-id** and **app-private-key** (required): The GitHub App the
  pull request is opened with.

When `index.yaml` already matches, the workflow closes any open rebuild pull
request and deletes its branch.

### `plugin-catalog-scan.yaml`

- **dry-run** (default `false`): Report which plugins are behind without
  opening pull requests.
- **plugin** (default empty): Scan only this plugin.
- Secrets **app-id** and **app-private-key** (required): The GitHub App that
  commits and opens the update pull requests.

The scan reads the newest published release of each plugin's upstream
repository, ignoring drafts and prereleases. It takes checksums from the
release's `checksums.txt`, or computes them from the archives when there is
none.

### `plugin-catalog-health.yaml`

- **path** (default `.`): Catalog root.
- **name**, **description**, **owner**, **homepage**: The header given to the
  rebuild workflow.
- **label** (default `catalog-health`): Label on the issue a failure opens.

The caller grants `issues: write`.

## Run the checks locally

From a catalog checkout, with this repository at `$ACTIONS`:

```bash
python=$(PLUGIN_CATALOG_PYTHON=python3.12 bash "$ACTIONS/scripts/plugin-catalog/install-deps.sh")
datumctl=$(bash "$ACTIONS/scripts/plugin-catalog/install-datumctl.sh")
"$python" "$ACTIONS/scripts/plugin-catalog/catalog.py" validate --datumctl "$datumctl"
"$python" "$ACTIONS/scripts/plugin-catalog/catalog.py" index --check
```

`PLUGIN_CATALOG_PYTHON` picks the interpreter for the virtualenv, which needs
Python 3.11 or later with prebuilt wheels for the pinned libraries.
`DATUMCTL`, when set, names a `datumctl` to use instead of downloading the
pinned release.

## Tests

`test-plugin-catalog.yaml` runs `scripts/plugin-catalog/test-plugin-catalog.sh`
and calls the validate and health workflows on the fixture catalog in
`scripts/plugin-catalog/testdata/catalog`. The fixture's one archive is a small
release asset, so the workflow test downloads something real and checks its
`sha256`.
