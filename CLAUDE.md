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

**Automatic Build Arguments:**
The workflow automatically injects these build arguments:
- `VERSION`: Semver-compliant version generated from git tags/branches/commits
- `GIT_COMMIT`: Full commit SHA
- `GIT_TREE_STATE`: Set to `clean`
- `BUILD_DATE`: Commit timestamp
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
- `node-version` (optional, default 24): Node.js version to use
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
    uses: datum-cloud/actions/.github/workflows/publish-npm-package.yaml@v1
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
Always reference a tagged version (e.g., `@v1`) to prevent breaking changes:

```yaml
jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1
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
- `docs/` - Documentation for each action with usage examples and best practices
- `renovate.json` - Renovate configuration for dependency updates
