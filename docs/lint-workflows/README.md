# Lint GitHub Actions Workflows

The `.github/workflows/lint-workflows.yaml` reusable GitHub Action validates
GitHub Actions workflow files using **actionlint** to catch common errors and
best practice violations.

## 🚀 Usage

### Inputs

This workflow does not require any inputs.

### Automatic Triggers

The workflow automatically runs when:
- Workflow files in `.github/workflows/*.yaml` are modified
- Called as a reusable workflow from another repository

### Required Permissions

```yaml
permissions:
  contents: read
```

## Features

- ✅ **Syntax validation**: Catches YAML syntax errors
- ✅ **Workflow validation**: Validates GitHub Actions workflow structure
- ✅ **Best practices**: Identifies common mistakes and anti-patterns
- ✅ **Shell script validation**: Checks shell scripts in `run` steps using shellcheck
- ✅ **Expression validation**: Validates GitHub Actions expressions
- ✅ **Colored output**: Easy-to-read error messages with color coding

## Best Practices

- Always use a tagged version when referencing the GitHub action workflow to prevent unexpected breaking changes.
- Run this workflow on every pull request to catch issues before merging.
- Consider adding this as a required status check for branch protection.

## Workflow Examples

### Basic Usage

Create a workflow in your repository (e.g., `.github/workflows/lint.yaml`)
that calls this reusable action:

```yaml
name: Lint Workflows

on:
  pull_request:
  push:
    paths:
      - '.github/workflows/*.yaml'

jobs:
  lint:
    uses: datum-cloud/actions/.github/workflows/lint-workflows.yaml@v1
```

### With Branch Protection

Combine with other checks as required status:

```yaml
name: CI

on:
  pull_request:

jobs:
  lint-workflows:
    uses: datum-cloud/actions/.github/workflows/lint-workflows.yaml@v1

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: make test
```

### Standalone in Actions Repository

For the actions repository itself:

```yaml
name: Lint Workflows

on:
  push:
    paths:
      - '.github/workflows/*.yaml'
  pull_request:
    paths:
      - '.github/workflows/*.yaml'

jobs:
  lint:
    uses: datum-cloud/actions/.github/workflows/lint-workflows.yaml@v1
```

## Common Issues Detected

### Syntax Errors

- Invalid YAML syntax
- Incorrect indentation
- Missing required fields

### Workflow Structure

- Invalid job dependencies
- Incorrect `needs` references
- Invalid trigger configurations

### Expression Errors

- Malformed GitHub Actions expressions
- Invalid context access
- Type mismatches in expressions

### Shell Script Issues

- Unquoted variables
- Missing error handling
- Unsafe command usage

## Example Error Output

```
.github/workflows/example.yaml:15:7: "needs" section has unknown job "typo-job" [unknown-job]
   |
15 |       needs: typo-job
   |       ^~~~~~

.github/workflows/example.yaml:23:15: shellcheck reported issue in this script: SC2086:info:1:6: Double quote to prevent globbing and word splitting [shellcheck]
   |
23 |         run: echo $VARIABLE
   |               ^~~~~~~~~~~~
```

## Actionlint Features

The workflow uses [actionlint](https://github.com/rhysd/actionlint) which provides:

- **Fast validation**: Lints workflows in seconds
- **Comprehensive checks**: Covers syntax, semantics, and best practices
- **Shell script integration**: Uses shellcheck for `run` steps
- **Expression validation**: Validates GitHub Actions expressions
- **Detailed error messages**: Clear explanations with line numbers

## Troubleshooting

### False Positives

If actionlint reports a false positive, you can:

1. Add a comment to disable specific checks:
   ```yaml
   # actionlint-ignore: rule-name
   ```

2. Configure actionlint with a config file (`.github/actionlint.yaml`)

### Workflow Not Triggering

- Verify the workflow file is in `.github/workflows/` directory
- Check that file extensions are `.yaml` or `.yml`
- Ensure the path filter matches your file changes

## Additional Resources

- [actionlint Documentation](https://github.com/rhysd/actionlint)
- [GitHub Actions Workflow Syntax](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions)
- [GitHub Actions Best Practices](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
