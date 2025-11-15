# Snyk Security Scan

The `.github/workflows/snyk-scan.yaml` reusable GitHub Action performs security
vulnerability scanning using **Snyk** for dependencies, Infrastructure as Code (IaC),
containers, and code.

## 🚀 Usage

### Inputs

- **command** (optional, default: `test`): Snyk command to run. Options: `test`, `monitor`, `iac test`, `container test`, `code test`.
- **fail-on-issues** (optional, default: `true`): Whether to fail the build if vulnerabilities are found.
- **severity-threshold** (optional, default: `high`): Minimum severity to fail on. Options: `low`, `medium`, `high`, `critical`.
- **target-file** (optional): Specific file to scan (e.g., `package.json`, `go.mod`, `pom.xml`).
- **args** (optional): Additional arguments to pass to Snyk CLI.
- **snyk-org** (optional): Snyk organization slug or ID.
- **debug** (optional, default: `false`): Enable debug mode (`-d` flag) for verbose output.
- **upload-sarif** (optional, default: `true`): Whether to upload SARIF results to GitHub Security.
- **sarif-file-output** (optional, default: `snyk.sarif`): Path for SARIF output file.
- **json-file-output** (optional, default: `snyk.json`): Path for JSON output file.

### Outputs

- **vulnerabilities-found**: Whether vulnerabilities were found (`true`/`false`).

### Required Secrets

- **SNYK_TOKEN**: Snyk API token for authentication. Must be configured in repository or organization secrets.

### Required Permissions

```yaml
permissions:
  contents: read
  security-events: write
  actions: read
```

## Features

- ✅ **Multi-scan support**: Dependencies, IaC, containers, and code scanning
- ✅ **GitHub Security integration**: Automatic SARIF upload to Security tab
- ✅ **Detailed reporting**: JSON output with vulnerability breakdown
- ✅ **Workflow summary**: Visual table with severity counts
- ✅ **Artifact retention**: Results saved for 30 days for audit purposes
- ✅ **Flexible configuration**: Customizable thresholds and failure modes
- ✅ **Monitor mode**: Track vulnerabilities over time in Snyk dashboard

## Best Practices

- Always use a tagged version when referencing the GitHub action workflow to prevent unexpected breaking changes.
- Enable `upload-sarif: true` to integrate with GitHub Security features.
- Use `fail-on-issues: true` in pull requests to prevent merging vulnerable code.
- Configure `monitor` command on main/master branches to track vulnerabilities over time.
- Set appropriate `severity-threshold` based on your project's security requirements.
- Review artifacts regularly for compliance and audit purposes.

## Workflow Examples

### Basic IaC Scan

Scan Infrastructure as Code files (Terraform, CloudFormation, Kubernetes, etc.):

```yaml
name: Snyk Security Scan

on:
  push:
  pull_request:

jobs:
  snyk-iac:
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: datum-cloud/actions/.github/workflows/snyk-scan.yaml@v1
    with:
      command: "iac test"
      fail-on-issues: false
      severity-threshold: "high"
      upload-sarif: true
      snyk-org: ${{ vars.SNYK_ORG }}
    secrets: inherit
```

### Dependency Scan with Strict Mode

Fail on critical vulnerabilities in dependencies:

```yaml
name: Snyk Dependency Scan

on:
  pull_request:

jobs:
  snyk-dependencies:
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: datum-cloud/actions/.github/workflows/snyk-scan.yaml@v1
    with:
      command: "test"
      fail-on-issues: true
      severity-threshold: "critical"
      upload-sarif: true
      snyk-org: ${{ vars.SNYK_ORG }}
    secrets: inherit
```

### Container Image Scan

Scan Docker container images for vulnerabilities:

```yaml
name: Snyk Container Scan

on:
  push:
    branches: [main]

jobs:
  snyk-container:
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: datum-cloud/actions/.github/workflows/snyk-scan.yaml@v1
    with:
      command: "container test"
      args: "myapp:latest"
      fail-on-issues: true
      severity-threshold: "high"
      upload-sarif: true
      snyk-org: ${{ vars.SNYK_ORG }}
    secrets: inherit
```

### Multi-Scan with Monitor

Combine test and monitor for comprehensive security:

```yaml
name: Snyk Security

on:
  push:
    branches: [main, master]

jobs:
  snyk-test:
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: datum-cloud/actions/.github/workflows/snyk-scan.yaml@v1
    with:
      command: "test"
      fail-on-issues: false
      upload-sarif: true
      snyk-org: ${{ vars.SNYK_ORG }}
    secrets: inherit

  snyk-monitor:
    needs: snyk-test
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: datum-cloud/actions/.github/workflows/snyk-scan.yaml@v1
    with:
      command: "monitor"
      fail-on-issues: false
      upload-sarif: false
      snyk-org: ${{ vars.SNYK_ORG }}
    secrets: inherit
```

### Scheduled Security Audit

Run daily security scans to detect new vulnerabilities:

```yaml
name: Scheduled Security Scan

on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM UTC

jobs:
  snyk-scan:
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: datum-cloud/actions/.github/workflows/snyk-scan.yaml@v1
    with:
      command: "test"
      fail-on-issues: false
      severity-threshold: "medium"
      upload-sarif: true
      snyk-org: ${{ vars.SNYK_ORG }}
    secrets: inherit
```

## Results Visualization

### GitHub Security Tab

SARIF results are automatically uploaded to the Security tab:
- Navigate to **Security** → **Code scanning** → **Snyk**
- View detailed vulnerability information with remediation advice

### Workflow Summary

Each workflow run displays a summary table with vulnerability counts:

| Severity | Count |
|----------|-------|
| 🔴 Critical | X |
| 🟠 High | X |
| 🟡 Medium | X |
| 🟢 Low | X |

### Artifacts

JSON and SARIF files are saved as artifacts for 30 days, accessible from the workflow run page.

### Snyk Dashboard

When using `monitor` command, view historical trends and detailed analysis in the Snyk dashboard.

## Supported Commands

| Command | Description | Generates SARIF |
|---------|-------------|-----------------|
| `test` | Scan dependencies for vulnerabilities | ✅ |
| `monitor` | Send snapshot to Snyk for continuous monitoring | ❌ |
| `iac test` | Scan Infrastructure as Code files | ✅ |
| `container test` | Scan container images | ✅ |
| `code test` | Scan source code (SAST) | ✅ |

## Troubleshooting

### Error: SNYK_TOKEN is not set

- Verify the `SNYK_TOKEN` secret exists in repository or organization settings
- Ensure `secrets: inherit` is specified in the workflow

### SARIF upload fails

- Verify `upload-sarif: true` is set
- Check that `security-events: write` permission is granted
- Confirm the Snyk command supports SARIF output (e.g., `monitor` does not)

### Workflow fails unexpectedly

- Enable `debug: true` temporarily for verbose output
- Review the "Run Snyk Security Scan" step logs
- Verify the command is compatible with your project type

## Configuration Variables

### Repository Variables (Optional)

- **SNYK_ORG**: Snyk organization slug or ID for centralized configuration

### Repository Secrets (Required)

- **SNYK_TOKEN**: Snyk API authentication token
  - Obtain from: https://app.snyk.io/account
  - Add to: Settings → Secrets and variables → Actions → New repository secret

## Additional Resources

- [Snyk CLI Documentation](https://docs.snyk.io/snyk-cli)
- [GitHub Code Scanning](https://docs.github.com/en/code-security/code-scanning)
- [SARIF Format Specification](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning)
