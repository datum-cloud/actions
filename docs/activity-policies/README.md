# ActivityPolicy tests

The `.github/workflows/test-activity-policies.yaml` reusable workflow validates
`ActivityPolicy` manifests (raw YAML files, directories, or Kustomize
directories) and runs declarative unit tests (`*.test.yaml`) offline using the
`ghcr.io/milo-os/activitytool` container image from
[`milo-os/activity`](https://github.com/milo-os/activity).

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
    uses: datum-cloud/actions/.github/workflows/test-activity-policies.yaml@<release-tag>
    with:
      policies-path: config/services/activity/policies
      tests-path: test/activity-policies
```

The first tag that carries this workflow is the next release after the one
that merges it. If your repository only has policies today and no tests yet,
omit `tests-path` (or leave `fail-on-untested: false`) and the workflow still
validates every `ActivityPolicy` in `policies-path` and reports untested ones.

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Repository directory to inspect, relative to the repository root. |
| `policies-path` | Auto-discovered | Comma- or newline-separated policy files, directories, or Kustomize directories relative to `path`. When empty, checks `config/services/activity/policies`, `config/activity/policies`, `config/policies`, then scans YAML files for `kind: ActivityPolicy`. |
| `tests-path` | Auto-discovered | Comma- or newline-separated test files or directories relative to `path`. When empty, checks `test/activity-policies`, `test/policies`, then scans `*test.yaml` files with `policy_files:`. |
| `fail-on-untested` | `false` | Fail when any validated `ActivityPolicy` has no unit tests. |
| `allow-empty` | `false` | Pass with a warning when no `ActivityPolicy` manifests or test files are found. |
| `activitytool-version` | Pinned in `install-activitytool.sh` | Override the `ghcr.io/milo-os/activitytool` image tag (for example `v0.9.3` or `v0.0.0-main`). |

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

Add this snippet (kept verbatim in `scripts/activity-policies/Taskfile.example.yml`)
to your repository's `Taskfile.yaml`. It uses a local `activitytool` binary
when available and otherwise runs the pinned `ghcr.io/milo-os/activitytool`
Docker image (kept updated by Renovate):

```yaml
version: "3"

vars:
  # renovate: datasource=docker depName=ghcr.io/milo-os/activitytool
  ACTIVITYTOOL_IMAGE: ghcr.io/milo-os/activitytool:v0.9.2

tasks:
  test-activity-policies:
    desc: Validate ActivityPolicy manifests and run unit tests
    cmds:
      - |
        if command -v activitytool >/dev/null 2>&1; then
          exec activitytool test --policies config/services/activity/policies test/activity-policies
        fi
        docker run --rm \
          -v "{{.ROOT_DIR}}:/work:ro" -w /work \
          "{{.ACTIVITYTOOL_IMAGE}}" \
          test --policies config/services/activity/policies test/activity-policies
```

If your repository does not have tests yet, run `check config/services/activity/policies`
instead of `test --policies ...`.
