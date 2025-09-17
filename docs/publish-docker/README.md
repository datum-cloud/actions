# Publish Docker Images

The `.github/workflows/publish-docker.yaml` reusable GitHub Action builds and
pushes a Docker image to **GitHub Container Registry**.

## 🚀 Usage

### Inputs

- **image-name** (required): The name of the docker image (without the registry) that
  should be used (e.g. cloud-portal).
- **extra-build-args** (optional): Additional build arguments to pass to docker build
  in multiline string format.

### Automatic Build Arguments

The workflow automatically provides the following build arguments to your Dockerfile:

- **VERSION**: Generated from git tags, branch names, or commit SHA using Docker metadata action
- **GIT_COMMIT**: The full commit SHA (`${{ github.sha }}`)
- **GIT_TREE_STATE**: Set to `clean` (CI builds are always clean)
- **BUILD_DATE**: The commit timestamp (`${{ github.event.head_commit.timestamp }}`)
- **SENTRY_AUTH_TOKEN**: Passed from secrets (if available)

These are commonly used for version injection in Go applications using ldflags, e.g.:

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

## Best Practices

- Always use a tagged version when referencing the GitHub action workflow to
  prevent unexpected breaking changes.

### **Workflow Examples**

#### Basic Usage

Create a workflow in your repository (e.g., `.github/workflows/publish.yaml`)
that calls this reusable action:

```yaml
name: Publish Docker Image

on:
  push:
  release:
    types: ['published']

jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1
    with:
      image-name: my-app
    secrets: inherit
```

#### Advanced Usage with Extra Build Arguments

```yaml
name: Publish Docker Image

on:
  push:
  release:
    types: ['published']

jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1
    with:
      image-name: my-app
      extra-build-args: |
        CUSTOM_ARG=value
        ANOTHER_ARG=${{ github.run_number }}
    secrets: inherit
```
