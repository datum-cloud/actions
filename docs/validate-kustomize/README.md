# Validate Kustomize Configurations

The `.github/workflows/validate-kustomize.yaml` reusable GitHub Action validates
all Kustomize configurations in a repository by building them and checking for
errors.

## 🚀 Usage

### Inputs

This workflow does not require any inputs.

### Automatic Triggers

The workflow automatically runs when:
- Workflow files in `.github/workflows/*.yaml` are modified
- Called as a reusable workflow from another repository

### Required Permissions

No special permissions required (uses default `contents: read`).

## Features

- ✅ **Automatic discovery**: Finds all `kustomization.yaml` files in the repository
- ✅ **Build validation**: Validates that each kustomization can be built successfully
- ✅ **Helm support**: Enables Helm chart inflation with `--enable-helm` flag
- ✅ **Detailed reporting**: Shows validation results in workflow summary
- ✅ **Error highlighting**: Clear error messages for failed validations
- ✅ **Multi-kustomization**: Validates all kustomizations in a single run

## Best Practices

- Always use a tagged version when referencing the GitHub action workflow to prevent unexpected breaking changes.
- Run this workflow on every pull request to catch configuration errors early.
- Organize kustomizations in separate directories for better maintainability.
- Use overlays for environment-specific configurations.

## Workflow Examples

### Basic Usage

Create a workflow in your repository (e.g., `.github/workflows/validate.yaml`)
that calls this reusable action:

```yaml
name: Validate Kustomize

on:
  pull_request:
  push:
    branches: [main]

jobs:
  validate:
    uses: datum-cloud/actions/.github/workflows/validate-kustomize.yaml@v1
```

### With Path Filtering

Only run when Kubernetes manifests change:

```yaml
name: Validate Kustomize

on:
  pull_request:
    paths:
      - 'config/**'
      - 'overlays/**'
      - '**/kustomization.yaml'

jobs:
  validate:
    uses: datum-cloud/actions/.github/workflows/validate-kustomize.yaml@v1
```

### Combined with Other Checks

Run alongside other validation workflows:

```yaml
name: CI

on:
  pull_request:

jobs:
  validate-kustomize:
    uses: datum-cloud/actions/.github/workflows/validate-kustomize.yaml@v1

  lint-yaml:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Lint YAML
        run: yamllint .

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: make test
```

## Validation Process

The workflow performs the following steps:

1. **Discovery**: Searches for all `kustomization.yaml` files recursively
2. **Build**: Runs `kustomize build` on each directory containing a kustomization
3. **Report**: Generates a summary with validation results
4. **Fail**: Exits with error code if any kustomization fails to build

## Workflow Summary Output

### All Valid

```
# Kustomize Validation Results

### 🎉 All kustomizations are valid!
```

### With Errors

```
# Kustomize Validation Results

### ❌ Error in `./config/base`
```
Error: accumulating resources: accumulation err='accumulating resources from 'deployment.yaml': 
evalsymlink failure on '/path/deployment.yaml' : lstat /path/deployment.yaml: no such file or directory'
```
```

## Supported Kustomize Features

- ✅ **Resources**: Standard Kubernetes manifests
- ✅ **Patches**: Strategic merge and JSON patches
- ✅ **Overlays**: Environment-specific configurations
- ✅ **Components**: Reusable configuration pieces
- ✅ **Helm charts**: Helm chart inflation (with `--enable-helm`)
- ✅ **Generators**: ConfigMap and Secret generators
- ✅ **Transformers**: Common labels, annotations, and name prefixes

## Common Validation Errors

### Missing Resource Files

```
Error: accumulating resources: accumulation err='accumulating resources from 'missing.yaml': 
evalsymlink failure on '/path/missing.yaml' : lstat /path/missing.yaml: no such file or directory'
```

**Solution**: Verify all files referenced in `kustomization.yaml` exist.

### Invalid YAML Syntax

```
Error: yaml: line 5: mapping values are not allowed in this context
```

**Solution**: Check YAML syntax in the referenced files.

### Invalid Patch Target

```
Error: no matches for Id ~G_v1_ConfigMap|~X|my-config; failed to find unique target for patch
```

**Solution**: Ensure patch targets exist in the base resources.

### Circular Dependencies

```
Error: cycle detected in kustomization
```

**Solution**: Review resource and base references to eliminate circular dependencies.

## Repository Structure Example

```
.
├── config/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── overlays/
│       ├── dev/
│       │   ├── kustomization.yaml
│       │   └── patch-replicas.yaml
│       └── prod/
│           ├── kustomization.yaml
│           └── patch-replicas.yaml
└── .github/
    └── workflows/
        └── validate.yaml
```

The workflow will validate:
- `./config/base/kustomization.yaml`
- `./config/overlays/dev/kustomization.yaml`
- `./config/overlays/prod/kustomization.yaml`

## Troubleshooting

### No kustomization.yaml files found

If the workflow reports no kustomization files:
- Verify files are named exactly `kustomization.yaml` (not `kustomization.yml`)
- Check that files are committed to the repository
- Ensure files are not in `.gitignore`

### Helm chart inflation fails

If using Helm charts:
- Verify Helm chart references are correct
- Check that chart repositories are accessible
- Ensure chart versions are specified

### Build succeeds locally but fails in CI

- Check for environment-specific paths or references
- Verify all files are committed
- Ensure no local-only files are referenced

## Additional Resources

- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Kustomize GitHub Repository](https://github.com/kubernetes-sigs/kustomize)
- [Kubernetes Documentation](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
