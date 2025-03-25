# Publish Kustomize Bundle

The `.github/workflows/publish-kustomize-bundle.yaml` reusable GitHub Action
builds and pushes a Kustomize bundle to **GitHub Container Registry**.

## 🚀 Usage

## Inputs

- **bundle-name**: The full name of the bundle that should be used, including
  the repository (e.g. `ghcr.io/datum-cloud/telemetry-services-operator/crds`).
- **bundle-path**: The path to the bundle that should be used, relative to the
  root of the repository (e.g. `config/crds`).

## Best Practices

- Always use a tagged version when referencing the GitHub action workflow to
  prevent unexpected breaking changes.

> [!IMPORTANT]
>
> Add the following to your `.gitignore` and `.dockerignore` files to exclude
> the automatically generated credentials from ever being included in the
> resulting docker container or committed to the repo.
>
> ```
> # Ignore generated credentials from google-github-actions/auth
> gha-creds-*.json
> ```

### **Workflow Example**

Create a workflow in your repository (e.g., `.github/workflows/publish.yaml`)
that calls this reusable action:

```yaml
name: Publish Kustomize Bundle

on:
  push:
  release:
    types: ['published']

jobs:
  publish:
    uses: datum-cloud/actions/.github/workflows/publish-kustomize-bundle.yaml@v1
    with:
      bundle-name: ghcr.io/datum-cloud/telemetry-services-operator/crds
      bundle-path: config/crds
```
