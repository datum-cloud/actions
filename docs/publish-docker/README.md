# Publish Docker Images

The `.github/workflows/publish-docker.yaml` reusable GitHub Action builds and
pushes a Docker image to **Google Cloud Artifact Registry** using **Workload
Identity Federation** for authentication. It eliminates the need for long-lived
credentials, improving security and maintainability.

## 🚀 Usage

## Inputs

- **image-name**: The name of the docker image (without the registry) that
  should be used (e.g. cloud-portal).

## Best Practices

- Always use a tagged version when referencing the GitHub action workflow to
  prevent unexpected breaking changes.

### **Workflow Example**

Create a workflow in your repository (e.g., `.github/workflows/publish.yaml`)
that calls this reusable action:

```yaml
name: Publish Docker Image

on:
  push:
    branches:
      - main

jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-docker.yaml@v1
    with:
      image-name: my-app
```
