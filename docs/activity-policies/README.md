# ActivityPolicy tests

The `.github/workflows/test-activity-policies.yaml` reusable workflow validates
`ActivityPolicy` manifests (raw YAML files, directories, or Kustomize
directories) and runs declarative unit tests (`*.test.yaml`) offline in the
`ghcr.io/milo-os/activitytool` container image from
[`milo-os/activity`](https://github.com/milo-os/activity).

Policy tests always run in that image, in CI and on workstations. The
workflow pulls it by its pinned digest and runs that digest with no network
access, as a non-root user, with the
repository mounted read-only. Building `activitytool` from source or with
`go install` is not a supported way to test a repository's policies.

## Adopt it

Add `.github/workflows/test-activity-policies.yaml` to the calling repository,
pinned to an exact release tag of `datum-cloud/actions`:

```yaml
name: Activity Policy Tests

on:
  pull_request:
    paths:
      - "config/services/activity/**"
      - "test/activity-policies/**"
      - ".github/workflows/test-activity-policies.yaml"
  push:
    branches: [main]
    paths:
      - "config/services/activity/**"
      - "test/activity-policies/**"
      - ".github/workflows/test-activity-policies.yaml"

permissions:
  contents: read

jobs:
  test-activity-policies:
    permissions:
      contents: read
    uses: datum-cloud/actions/.github/workflows/test-activity-policies.yaml@<release-tag>
    with:
      # The milo-os/activity release deployed where these policies run.
      # renovate: datasource=docker depName=ghcr.io/milo-os/activitytool
      activitytool-version: vX.Y.Z@sha256:<digest>
      policies-path: config/services/activity/policies
      tests-path: test/activity-policies
```

The job needs only `contents: read`. The first tag of `datum-cloud/actions` that carries
this workflow is the next release after the one that merges it. If your
repository only has policies today and no tests yet, omit `tests-path` (or
leave `fail-on-untested: false`) and the workflow still validates every
`ActivityPolicy` and reports the untested ones.

## Choose the activitytool version

`activitytool` evaluates policies with the CEL environment and template
functions of the Activity release it was built from. A test only says
something about production when it runs against the same release that
production runs, so **set `activitytool-version` to the `milo-os/activity`
release deployed in the environments your policies target**, and move it
when that deployment moves (for example, in the same change that bumps
Activity in the infra repository). When environments run different releases,
pin the oldest one your policies must support.

- Use a release tag (`vX.Y.Z`), pinned to its digest:
  `vX.Y.Z@sha256:<digest>`. Find the digest with
  `docker buildx imagetools inspect ghcr.io/milo-os/activitytool:vX.Y.Z`.
  With a digest, a re-pushed tag can't change what runs. A tag without a
  digest still works but logs a warning recommending a digest pin.
- The default, used when `activitytool-version` is empty, is the pin in
  `scripts/activity-policies/install-activitytool.sh` (currently `v0.10.0`).
  Renovate moves that pin to the newest Activity release, which is not
  necessarily the one you deploy, so don't rely on the default.
- `milo-os/activity` publishes an `activitytool` image from every branch, like
  its other images, tagged `v0.0.0-<branch>`. Those dev builds are unsupported
  for consumers: don't pin them. Renovate only proposes `vX.Y.Z` release tags.

If your repository uses Renovate, let it propose updates and review them
alongside your Activity deployment rather than auto-merging them. The
`# renovate:` comments above `activitytool-version` (in the workflow) and
`ACTIVITYTOOL_VERSION` (in the Taskfile below) need this in your
`renovate.json`:

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "description": "activitytool version in the policy-test workflow and Taskfile",
      "managerFilePatterns": ["/^\\.github/workflows/.+\\.ya?ml$/", "/(^|/)Taskfile\\.ya?ml$/"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)\\n\\s*(?:activitytool-version|ACTIVITYTOOL_VERSION): (?<currentValue>[^@\\s]+)(?:@(?<currentDigest>sha256:[a-f0-9]{64}))?"
      ]
    }
  ],
  "packageRules": [
    {
      "matchDepNames": ["ghcr.io/milo-os/activitytool"],
      "allowedVersions": "/^v\\d+\\.\\d+\\.\\d+$/",
      "pinDigests": true,
      "groupName": "activitytool"
    }
  ]
}
```

With `groupName`, the workflow and Taskfile pins move together in one PR.

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Repository directory to inspect, relative to the repository root. |
| `policies-path` | Auto-discovered | Comma- or newline-separated policy files, directories, or Kustomize directories relative to `path`; mix as many as you need. Spaces inside a path are kept; commas can't appear in one. See [Discovery](#discovery). |
| `tests-path` | Auto-discovered | Comma- or newline-separated test files or directories relative to `path`. When empty, checks `test/activity-policies`, `test/policies`, then scans `*test.yaml` files with `policy_files:`. |
| `fail-on-untested` | `false` | Fail when any validated `ActivityPolicy` has no unit tests. |
| `allow-empty` | `false` | Pass with a warning when no `ActivityPolicy` manifests or test files are found. |
| `activitytool-version` | Pin in `install-activitytool.sh` | `ghcr.io/milo-os/activitytool` tag, optionally with its digest (`vX.Y.Z@sha256:<digest>`). Set it to the Activity release you deploy; see [Choose the activitytool version](#choose-the-activitytool-version). |

## Image integrity

`scripts/activity-policies/install-activitytool.sh`:

1. Rejects an `activitytool-version` that is not a Docker tag, optionally
   followed by `@sha256:<64 hex digits>`.
2. Pulls `ghcr.io/milo-os/activitytool:<version>`. A failed pull fails the
   job with Docker's own error.
3. Resolves the image digest: the pinned one when given, otherwise the digest
   the tag resolved to at pull time (with a warning recommending a digest
   pin).
4. Writes an `activitytool` wrapper that runs that digest through
   `docker-run.sh`: `docker run --pull never --network none --read-only
   --user 65532:65532 --cap-drop ALL`, with the repository root mounted
   read-only at `/work` and the working directory set to the matching
   subdirectory. Paths such as `../../base` that stay inside the repository
   resolve as they would natively, even with `path: services/foo`.

The repository root is `git rev-parse --show-toplevel`, else
`GITHUB_WORKSPACE`, else the current directory: the first that contains the
current directory.

Integrity rests on the digest pin, which Renovate keeps current. Build
provenance attestation of the image is planned, via `publish-docker.yaml`.

## Discovery

When `policies-path` is empty, the check uses the first of
`config/services/activity/policies`, `config/activity/policies` and
`config/policies` that exists. Otherwise it scans the repository's YAML files
(skipping `node_modules/`, `vendor/` and `testdata/`):

- A directory whose `kustomization.yaml` sits next to an `ActivityPolicy`
  manifest is passed as one Kustomize directory, which `activitytool`
  renders.
- Files that any kustomization uses as a patch (`patches[].path`,
  `patchesJson6902[].path`, `patchesStrategicMerge`) are never passed on
  their own: a strategic-merge patch is `kind: ActivityPolicy` with only part
  of a spec and would fail validation by itself.
- Any other file with `kind: ActivityPolicy` is passed individually.

Set `policies-path` explicitly when this guess is wrong for your layout.

## Writing tests

Tests use a `promtool`-style YAML format (`*.test.yaml`, `*.tests.yaml`,
`*-test.yaml`, `*-tests.yaml`):

```yaml
policy_files:
  - ../../config/services/activity/policies

tests:
  - name: create group renders expected summary and link
    audit:
      verb: create
      user:
        username: alice@example.com
      objectRef:
        apiGroup: iam.miloapis.com
        resource: groups
        name: platform-admins
    exp_rule: create
    exp_summary: "alice@example.com created group platform-admins"
    exp_change_source: human
    exp_links:
      - marker: platform-admins
        apiGroup: iam.miloapis.com
        kind: Group
        name: platform-admins

  - name: system create is ignored
    policy: iam.miloapis.com-group
    audit:
      verb: create
      user:
        username: system:serviceaccount:kube-system:controller
      objectRef:
        apiGroup: iam.miloapis.com
        resource: groups
        name: platform-admins
    exp_no_match: true
```

## Run locally with Taskfile

Add this snippet to your repository's `Taskfile.yaml`. It runs the `ghcr.io/milo-os/activitytool`
image the same way CI does: offline, as a non-root user, with the repository
root mounted read-only. Set `ACTIVITYTOOL_VERSION` to the same value as the
workflow's `activitytool-version`:

```yaml
version: "3"

vars:
  # Use the milo-os/activity release deployed where these policies run, so CEL
  # and template functions match production, pinned with its digest.
  # renovate: datasource=docker depName=ghcr.io/milo-os/activitytool
  ACTIVITYTOOL_VERSION: v0.10.1@sha256:9efcfff21f2533919a8a43bb49ab1a6fa2e29edd9cb665e34574428c490389c3
  ACTIVITY_POLICIES: config/services/activity/policies
  ACTIVITY_POLICY_TESTS: test/activity-policies

tasks:
  test-activity-policies:
    desc: Validate ActivityPolicy manifests and run unit tests in the activitytool image
    cmds:
      - |
        set -eu
        root=$(git rev-parse --show-toplevel)
        prefix=$(git rev-parse --show-prefix)
        docker run --rm --network none --user 65532:65532 --read-only \
          --cap-drop ALL --security-opt no-new-privileges \
          --volume "$root:/work:ro" --workdir "/work/$prefix" \
          "ghcr.io/milo-os/activitytool:{{.ACTIVITYTOOL_VERSION}}" \
          test --policies {{.ACTIVITY_POLICIES}} {{.ACTIVITY_POLICY_TESTS}}
```

If your repository does not have tests yet, run `check {{.ACTIVITY_POLICIES}}`
instead of `test --policies ...`. The `# renovate:` comment lets a Renovate
regex manager keep the version current; review those updates against your
Activity deployment.

To reproduce the workflow exactly, including discovery and the digest pin,
run `scripts/activity-policies/run.sh` from a checkout of this
repository (`run.sh --help` lists its settings; it needs `docker`).

## Self-tests

`scripts/activity-policies/test-activity-policies.sh`, run by
`test-activity-policies-action.yaml`, runs the fixtures in `testdata/` with
the pinned `activitytool` image (so it needs `docker`), and the installer and
the Docker wrapper against a stand-in `docker` command. It then weakens each
guarded behavior in a copy of the scripts to prove some case catches it.
