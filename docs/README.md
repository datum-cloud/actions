# Reusable GitHub Actions

This directory contains documentation for the reusable GitHub actions that are
available for use across the organization.

## Available Actions

### Security & Compliance

- [**Snyk Security Scan**](./snyk-scan/) - Comprehensive security vulnerability scanning for dependencies, IaC, containers, and code using Snyk

### Publishing & Distribution

- [**Publish Docker Images**](./publish-docker/) - Build and push Docker images to GitHub Container Registry
- [**Publish Kustomize Bundle**](./publish-kustomize-bundle/) - Build and push Kustomize bundles to GitHub Container Registry

### Validation & Linting

- [**Lint GitHub Actions Workflows**](./lint-workflows/) - Validate workflow files using actionlint to catch errors and best practice violations
- [**Validate Kustomize Configurations**](./validate-kustomize/) - Validate all Kustomize configurations by building them and checking for errors

## Usage

All workflows are designed to be used as reusable workflows. Reference them in your repository workflows using:

```yaml
jobs:
  job-name:
    uses: datum-cloud/actions/.github/workflows/<workflow-name>.yaml@v1
    with:
      # inputs here
    secrets: inherit
```

## Best Practices

- **Use tagged versions**: Always reference workflows with a specific version tag (e.g., `@v1`) to prevent unexpected breaking changes
- **Inherit secrets**: Use `secrets: inherit` to pass repository secrets to reusable workflows
- **Set permissions**: Explicitly define required permissions in your workflow
- **Review documentation**: Check individual action documentation for specific requirements and examples

## Contributing

When adding new reusable workflows:

1. Create the workflow file in `.github/workflows/`
2. Add comprehensive documentation in `docs/<workflow-name>/README.md`
3. Follow the established documentation structure
4. Update this README to include the new action
5. Create a release with appropriate version tags

## Support

For issues or questions about these actions, please open an issue in the repository.
