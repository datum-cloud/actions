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
```
