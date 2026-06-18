# Setup datumctl

Installs [`datumctl`](https://www.datum.net/docs/cli/) and authenticates a Datum
service account, storing the session in the datumctl keyring so subsequent
`datumctl` and `kubectl` steps run against your Datum projects without
re-supplying the key.

Unlike the reusable *workflows* in this repo, this is a **composite action** —
add it as a step inside one of your own jobs, the same way you would use
[`google-github-actions/setup-gcloud`](https://github.com/google-github-actions/setup-gcloud).

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `version` | No | `v0.15.0` | datumctl version to install, given as a datumctl release tag. |
| `auth-hostname` | No | `auth.datum.net` | Datum auth server hostname. |
| `credentials` | **Yes** | — | Service account credentials JSON. Accepts raw JSON **or** a base64-encoded copy of it. |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The datumctl version that was installed. |
| `bin-path` | Directory datumctl was installed into and added to `PATH`. |

## Platforms

Installs the released tarball for the runner's OS/architecture:

| OS | Architectures |
|----|---------------|
| Linux | `x86_64`, `arm64` |
| macOS | `x86_64` (Intel), `arm64` (Apple Silicon) |

The download is verified against the release's published SHA-256 checksum before
it is installed. datumctl is placed in a job-scoped directory and added to
`PATH`; no `sudo` is required.

## Usage

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Setup datumctl
        uses: datum-cloud/actions/setup-datumctl@v1
        with:
          credentials: ${{ secrets.DATUM_SA_CREDENTIALS }}

      # datumctl is now on PATH and authenticated.
      - run: datumctl auth update-kubeconfig --organization my-org
      - run: kubectl get projects
```

### Pinning a version and selecting an auth host

```yaml
      - name: Setup datumctl
        uses: datum-cloud/actions/setup-datumctl@v1
        with:
          version: v0.15.0
          auth-hostname: auth.staging.env.datum.net
          credentials: ${{ secrets.DATUM_SA_CREDENTIALS_STAGING }}
```

## Credentials

Create a service account in the [Datum Cloud portal](https://app.datum.net)
under your organization's IAM settings, choose **Datum-managed key**, and
download the credentials JSON (shown only once). Store it as a repository or
environment secret and pass it via `credentials`.

The action tolerates the secret being stored either as raw JSON or
base64-encoded — useful when a secret store mangles multi-line JSON. The value
is written to a temporary file with mode `600` and removed after login; the
authenticated session lives in the datumctl keyring (file backend on headless
runners).

## Best Practices

- **Pin a version**: reference this action with a release tag (e.g. `@v1`) and
  pin `version` to a known datumctl release for reproducible runs.
- **Least privilege**: grant the service account only the roles the workflow
  needs.
- **Use secrets, not literals**: never inline credentials in the workflow file.
