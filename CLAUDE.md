# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a repository of **reusable GitHub Actions** for Datum Cloud's CI/CD workflows. The repository provides modular, production-ready GitHub Actions that can be called from other repositories to standardize workflows and improve maintainability.

## Available Reusable Actions

### 1. Publish Docker Image (`.github/workflows/publish-docker.yaml`)

Builds and pushes Docker images to GitHub Container Registry (ghcr.io).

**Inputs:**
- `image-name` (required): The image name excluding the registry (e.g., `cloud-portal`)
- `extra-build-args` (optional): Additional build arguments in multiline string format
- `drop-distrusted-roots` (optional, default `true`): Builds the Dockerfile to a local OCI layout, then adds a layer from `scripts/drop-distrusted-roots/` that rewrites the image's CA certificate files without the eMudhra emSign C1, C3 and G3 roots, and pushes that. `test-drop-distrusted-roots.yaml` runs the filter tests and the same two builds on a distroless fixture. See [`docs/publish-docker/`](docs/publish-docker/README.md#distrusted-ca-roots).

**Automatic Build Arguments:**
The workflow automatically injects these build arguments:
- `VERSION`: Semver-compliant version generated from git tags/branches/commits
- `GIT_COMMIT`: Full commit SHA
- `GIT_TREE_STATE`: Set to `clean`
- `BUILD_DATE`: Build time, ISO8601 in UTC (e.g. `2026-08-26T22:03:21Z`)
- `SENTRY_AUTH_TOKEN`: From secrets (optional)

**Version Tag Logic:**
- Semver tags (e.g., `v1.2.3`) are passed as-is
- Non-semver tags are prefixed with `v0.0.0-` for Kubernetes compatibility (e.g., `pr-123` becomes `v0.0.0-pr-123`)

### 2. Publish Kustomize Bundle (`.github/workflows/publish-kustomize-bundle.yaml`)

Publishes Kustomize bundles to GitHub Container Registry using Flux CLI.

**Inputs:**
- `bundle-name` (required): Full bundle name including registry (e.g., `ghcr.io/datum-cloud/operator/crds`)
- `bundle-path` (required): Path to bundle relative to repo root (e.g., `config/crds`)

**Outputs:**
- `tags`: Generated tags for the bundle
- `labels`: Generated labels for the bundle
- `digest`: Digest of the published bundle

### 3. Publish npm Package (`.github/workflows/publish-npm-package.yaml`)

Publishes npm packages with two modes: dev builds on every push to main, and stable releases on demand.

**Inputs:**
- `package-name` (required): The npm package name (e.g. `@datum-cloud/datum-ui`)
- `package-path` (required): Path to the package directory relative to the repo root
- `node-version` (optional, default 26): Node.js version to use
- `release-mode` (optional, default `dev`): Publishing mode — `dev` or `release`

**Outputs:**
- `new-version`: The published version (e.g. `v1.2.3` or `0.1.2-dev.abc1234`)

**Dev mode (`release-mode: dev`):**
- Publishes `x.y.z-dev.{short-sha}` to the `dev` npm dist-tag
- No version bump commit or git tag — the base version in package.json is unchanged
- Consumers install via `npm install <package>@dev`
- Only needs `contents: read` permission

**Release mode (`release-mode: release`):**
- Bumps version based on PR labels (`release:major`, `release:minor`, or patch by default)
- Creates a version bump commit and git tag, pushes to main
- Publishes stable version to the `latest` npm dist-tag
- Needs `contents: write` for the version bump push

**Typical caller setup (single workflow file):**
```yaml
name: Publish Package
on:
  push:
    branches: [main]
  release:
    types: [published]

jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-npm-package.yaml@v1.23.0
    with:
      package-name: "@datum-cloud/my-package"
      package-path: packages/my-package
      release-mode: ${{ github.event_name == 'release' && 'release' || 'dev' }}
    secrets: inherit
```

Dev builds are published on every push to main. Stable releases are published
when a GitHub release is created. The `release-mode` expression selects the
right mode automatically. For release events, path filtering is skipped since
releases are intentional.

### 4. Lint GitHub Actions Workflows (`.github/workflows/lint-workflows.yaml`)

Validates workflow YAML files using actionlint. Runs automatically on workflow file changes.

### 5. Validate Kustomize Configurations (`.github/workflows/validate-kustomize.yaml`)

Finds and validates all `kustomization.yaml` files in the repository using `kustomize build --enable-helm`.

### 6. Update Plugin Index (`update-plugin-index/action.yml` — composite action)

Opens a PR against a datumctl plugin catalog (index repo) that bumps a plugin's manifest to a newly published release — setting `spec.version`, rewriting each platform's download `uri` to the new tag, and refreshing each `sha256` from the release's `checksums.txt`. It is a **composite action** (not a reusable workflow) so the caller mints the cross-repo token and runs this in the same job — a GitHub App token doesn't survive being passed across jobs.

**Inputs:**
- `index-repo` (required): Catalog repo to open the PR against (e.g. `milo-os/cli-plugins`)
- `plugin-name` (required): Plugin short name (e.g. `ipam`)
- `plugin-file` (optional): Manifest path in the index repo (default `plugins/<plugin-name>.yaml`)
- `version` (required): Release tag including leading `v` (e.g. `v0.2.0`)
- `release-repo` (optional): Repo that published the release assets (default: calling repo)
- `base-branch` (optional): Index repo branch to base the PR on (default `main`)
- `token` (required): PAT / GitHub App token with `contents:write` + `pull-requests:write` on `index-repo`, minted in the same job. The built-in `GITHUB_TOKEN` cannot push or open a PR cross-repo.

The archive→checksum mapping is driven off the basenames of the manifest's existing `platforms[].uri` values, so it works for any plugin. Regenerating `index.yaml` is left to the index repo's own generator. See [`docs/update-plugin-index/`](docs/update-plugin-index/README.md).

### 7. Update NOTICE (`.github/workflows/update-notice.yaml`)

Regenerates the calling repo's `NOTICE` file of third-party licenses by running a task from its `Taskfile.yml`, then commits and pushes any change to the triggering branch. Callers trigger it on pushes that change `go.mod` or `go.sum` outside `main`, so dependency PRs carry their own NOTICE update. The push step rebases and retries when another workflow from the same trigger (such as `nix-update-hash`, which has the same retry) pushed first.

**Inputs:**
- `go-version-file` (optional, default `go.mod`): Path to `go.mod` for `actions/setup-go`
- `task-command` (optional, default `notice`): Task that regenerates NOTICE
- `notice-path` (optional, default `NOTICE`): File to check and commit
- `commit-message` (optional, default `chore: update NOTICE for go deps`): Commit message

See [`docs/update-notice/`](docs/update-notice/README.md).

### 8. Vulnerability Scan (`.github/workflows/vuln-scan.yaml`)

Scans the calling repo for known vulnerabilities and fails on any that aren't explicitly ignored. Callers run it on every pull request and on a weekly schedule. It auto-detects ecosystems: `govulncheck` for each Go module (reachable vulnerabilities only), `osv-scanner` for npm, pnpm, yarn, bun, Python, and Cargo lockfiles, and Trivy for images named in `images`. Logic lives in `scripts/vuln-scan/*.sh`, in Bash with `jq`, plus `scripts/vuln-scan/toml-to-json.py`, the only Python, because nothing else preinstalled on runners parses the caller's `osv-scanner.toml`; the workflow sparse-checks-out only those files (never `testdata/`) at its own commit through `job.workflow_repository` and `job.workflow_sha`, then moves them to `$RUNNER_TEMP` so they're outside the caller's workspace. In a Git work tree it lists files with `git ls-files --cached --others --exclude-standard`, so the caller's `.gitignore` applies; submodules, nested repositories, and manifests without a lockfile are reported as not scanned. Scanner versions are pinned in `scripts/vuln-scan/install-tools.sh` for Renovate.

**Inputs:**
- `path` (optional, default `.`): Directory to scan
- `ecosystems` (optional, default `auto`): `auto`, or a list of `go`, `node`, `python`, `rust`; each listed ecosystem must be present
- `exclude-paths` (optional, default empty): Globs, relative to `path`, not to scan
- `include-dev-dependencies` (optional, default `false`): Also scan dev dependencies; only npm `package-lock.json` and dev-named requirements files can exclude them
- `images` (optional, default empty): Image references to scan with Trivy, pullable without credentials
- `image-severity` (optional, default `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL`): Trivy severities that fail the scan
- `image-ignore-unfixed` (optional, default `true`): Skip image vulnerabilities with no fix
- `go-version` (optional, default empty): Go version for `govulncheck`, which sets the standard library findings. Empty means: within the modules' highest Go minor, a `toolchain` pin if it meets every `go` directive, else that minor's latest patch. The scan runs with `GOTOOLCHAIN=local` and fails if the installed Go doesn't match the request or a module needs a newer Go
- `allow-empty` (optional, default `false`): Pass with a warning when there is nothing to scan. A manifest without a lockfile isn't "nothing", so it still fails when nothing else was scanned

**Local runs:** `scripts/vuln-scan/run.sh` runs detect, install, and scan on a workstation with the same env-var settings as the inputs (`--help` lists them). It caches scanners per version under `${XDG_CACHE_HOME:-$HOME/.cache}/datum-vuln-scan/bin` and sets `GOTOOLCHAIN` to the selected Go so standard library findings match CI. `scripts/vuln-scan/Taskfile.example.yml` is the caller's Taskfile snippet; it reads the ref (a tag or commit SHA) from the caller's `uses:` line for `vuln-scan.yaml` in `.github/workflows`, so a Renovate bump there moves the local scan too, resolves a tag with `git ls-remote`, fetches the scripts by commit once into the same cache, and runs `run.sh`. The README embeds that file verbatim, and the test fails if the two differ.

Suppressions go in the caller's `osv-scanner.toml` or `.trivyignore.yaml`. Every `osv-scanner.toml` entry needs an `id`, a `reason`, and an `ignoreUntil` at most 12 months after the scan date. `findings.sh` reimplements osv-scanner's matching (ID or alias, until `ignoreUntil`) to apply those entries to `govulncheck`, so the two can disagree. There's no input that turns failures off. `scripts/vuln-scan/test-vuln-scan.sh`, run by `test-vuln-scan.yaml`, asserts that vulnerable fixtures in `scripts/vuln-scan/testdata` fail and clean ones pass; fixture dependency files end in `.fixture` so that the dependency graph and Renovate ignore them. See [`docs/vuln-scan/`](docs/vuln-scan/README.md).

### 9. Code Scan (`.github/workflows/code-scan.yaml`)

Scans the calling repo's source for signs of injected code with Semgrep and fails on any finding that the central ignore file doesn't cover. Callers run it on every pull request. Semgrep only reads files: nothing from the caller is installed or run. Rules in `scripts/code-scan/rules/*.yaml` catch process execution, dynamic code execution, remote fetch then execute (taint), download piped into a shell, code after 100+ whitespace characters, and lines over 500 characters in build files. The scan reads the whole tree and deletes `.semgrepignore` files, turns off Semgrep's default skip list, `.gitignore`, the file size limit, timeouts, and inline `nosemgrep`. Logic lives in `scripts/code-scan/` (`install-semgrep.sh`, `scan.sh`, and Python for filtering and reporting); the workflow sparse-checks-out only the `.sh`, `.py`, and `rules/*.yaml` files (never `testdata/`) at its own commit through `job.workflow_repository` and `job.workflow_sha`, then moves them to `$RUNNER_TEMP`. Raw Semgrep output is never echoed to the log because it holds attacker-controlled text; findings appear as escaped annotations and in the job summary. The Semgrep version is pinned in `scripts/code-scan/install-semgrep.sh` for Renovate.

**Inputs:**
- `path` (optional, default `.`): Directory to scan
- `exclude-paths` (optional, default empty): Globs, relative to `path`, not to scan
- `extra-rules` (optional, default empty): Extra Semgrep rules file or directory, relative to `path`
- `ignore-file` (optional, default `.github/code-scan-ignore.toml`): Central ignore file, relative to `path`

Suppressions go only in the ignore file, as `[[Ignore]]` entries with `rule`, one exact `path` (no globs), `reason`, and an `ignoreUntil` at most 12 months out. Callers protect the file with CODEOWNERS. Exit codes: 0 clean, 1 findings, 2 scanner or configuration error. The job has a 30-minute limit because Semgrep runs with `--timeout 0`. `scripts/code-scan/test-code-scan.sh`, run by `test-code-scan.yaml`, asserts that payload fixtures in `scripts/code-scan/testdata` fail and the clean one passes; any workflow here that scans the repo root must exclude `scripts/code-scan/testdata`. See [`docs/code-scan/`](docs/code-scan/README.md).

## Common Development Commands

### Linting Workflows
```bash
# Run actionlint locally using Docker
docker run --rm -v $(pwd):/repo --workdir /repo rhysd/actionlint:latest -color
```

### Validating Kustomize Configurations
```bash
# Install kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

# Validate a specific kustomization
kustomize build path/to/dir --enable-helm

# Find and validate all kustomizations
find . -name "kustomization.yaml" -exec dirname {} \; | while read dir; do
  echo "Validating: $dir"
  kustomize build "$dir" --enable-helm
done
```

## Workflow Architecture

### Tagging Strategy
Both Docker and Kustomize workflows use `docker/metadata-action@v5` to generate consistent tags:
- `type=ref,event=pr`: PR number (e.g., `pr-123`)
- `type=ref,event=pr,suffix=-{{commit_date 'YYYYMMDD-HHmmss'}}`: PR with timestamp
- `type=ref,event=branch`: Branch name
- `type=ref,event=branch,suffix=-{{commit_date 'YYYYMMDD-HHmmss'}}`: Branch with timestamp
- `type=semver,pattern=v{{version}}`: Full semver (e.g., `v1.2.3`)
- `type=semver,pattern=v{{major}}.{{minor}}`: Minor version (e.g., `v1.2`)
- `type=semver,pattern=v{{major}}`: Major version (e.g., `v1`)
- `type=sha`: Git commit SHA

### Docker Publishing Flow
1. Checkout repository
2. Setup Docker Buildx (linux/amd64)
3. Login to ghcr.io
4. Extract metadata and generate tags
5. Transform version tag for semver compatibility
6. Build and push with GHA caching

### Kustomize Publishing Flow
1. Checkout repository
2. Login to ghcr.io
3. Setup Flux CLI
4. Extract metadata and generate tags
5. Push artifact using `flux push artifact` for each tag
6. Output digest from first push

## Important Patterns

### Using These Actions in Other Repositories
Pin an exact release tag, such as `@v1.23.0`, and let Renovate bump it.
This repository publishes only exact tags, with no major-version tag such as
`@v1`, so a reference to one fails:

```yaml
jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1.23.0
    with:
      image-name: my-app
    secrets: inherit  # Required for GITHUB_TOKEN and SENTRY_AUTH_TOKEN
```

### Build Arguments in Dockerfiles
To use the automatic build arguments, declare them in your Dockerfile:

```dockerfile
ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG GIT_TREE_STATE=dirty
ARG BUILD_DATE=unknown

RUN go build -ldflags="-X k8s.io/component-base/version.gitVersion=${VERSION} \
    -X k8s.io/component-base/version.gitCommit=${GIT_COMMIT} \
    -X k8s.io/component-base/version.gitTreeState=${GIT_TREE_STATE} \
    -X k8s.io/component-base/version.buildDate=${BUILD_DATE}" \
    -o app ./cmd/app
```

## Repository Structure

- `.github/workflows/` - Reusable GitHub Actions workflow definitions
- `docs/<action>/` - Documentation for each action with usage examples and best practices
- `scripts/<action>/` - Scripts, tests, and test fixtures for an action whose logic doesn't fit in its YAML, such as `scripts/vuln-scan/` and `scripts/code-scan/`
- `update-plugin-index/` - A composite action, kept at the root because callers reference it by path
- `renovate.json` - Renovate configuration for dependency updates
## GitHub PR / Issue / Comment Conventions

Follow the `datum-platform:pr-conventions` skill for all PRs, issues, and comments — including its concision rules: say it once (don't restate the summary as test-plan checkboxes, or describe the same behaviour in prose and again in a checklist), and cut every word carrying no fact. Compress, never omit — brevity must not drop facts.
