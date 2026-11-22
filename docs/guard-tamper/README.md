# Guard tamper

The `.github/workflows/guard-tamper.yaml` reusable workflow finds guards that
no test protects. On a pull request, it removes or weakens each guard on the
Go lines the pull request changed, one at a time, and runs that package's
tests. A guard whose removal every test survives is reported, with the line
and the change that survived.

It catches the review finding "this check can be deleted and every test still
passes" before review, for checks such as authorization, tenancy, size caps
and race guards.

## What it changes

The workflow runs [go-mutesting](https://github.com/avito-tech/go-mutesting)
with its removal mutators only:

| Mutator | Change |
|---|---|
| `branch/if`, `branch/else`, `branch/case` | Empty an `if`, `else` or `case` body |
| `expression/remove` | Drop one clause of a `&&` or `\|\|` condition |
| `statement/remove` | Delete one statement |

Operator flips, arithmetic and loop mutators are off: they break unrelated
code and get caught for the wrong reason.

For each mutant on a changed line:

1. A mutant outside the pull request's changed lines is skipped.
2. A mutant whose only change removes a logger call or an Event is skipped.
   `ignore-regexp` replaces that pattern.
3. The package and its tests are built. A mutant that doesn't compile is
   excluded, not counted as caught.
4. The package's tests run. A failing test kills the mutant. Passing tests
   mean it survived.

The verdict comes from surviving mutants only. Survivors are grouped by the
enclosing `if`, `case` or function, so one guard gives one annotation.

Before any mutant runs, the package's tests must pass unchanged. If they
fail, the job fails, because no verdict is possible.

Test files, files with a `Code generated ... DO NOT EDIT.` header, and files
under `testdata` or `vendor` are never mutated.

## Usage

```yaml
on:
  pull_request:

permissions:
  contents: read

jobs:
  guard-tamper:
    uses: datum-cloud/actions/.github/workflows/guard-tamper.yaml@v1.31.0
```

A package whose tests need envtest:

```yaml
jobs:
  guard-tamper:
    uses: datum-cloud/actions/.github/workflows/guard-tamper.yaml@v1.31.0
    with:
      env-setup: go install sigs.k8s.io/controller-runtime/tools/setup-envtest@32759fab31191897ae86091d8831b2d4b890aedd && echo "KUBEBUILDER_ASSETS=$("$(go env GOPATH)/bin/setup-envtest" use 1.31.0 -p path)" >> "$GITHUB_ENV"
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Go module directory, relative to the repository root. |
| `required` | `false` | Fail the job when a guard survives. When `false`, survivors are reported and annotated and the job passes. |
| `base` | Pull request base | Commit or tree to diff against. |
| `env-setup` | None | One shell command run in `path` before testing. Write variables to `$GITHUB_ENV`. |
| `go-test-flags` | None | Extra flags for every `go test`, such as `-tags=integration`. |
| `ignore-regexp` | Logger and Event calls | Extended regular expression. A statement removal whose first removed line matches is skipped. |
| `max-mutants` | `60` | Most mutants to run. Over this, none run: the job warns, or fails when `required` is `true`. |
| `parallel` | `4` | Mutants tested at once, each in its own copy of the repository. |
| `test-timeout` | `300` | Seconds for one package's tests against one mutant. A timeout counts as caught. |
| `timeout-minutes` | `20` | Job timeout. |

## Outputs

| Output | Description |
|---|---|
| `survivors` | Guards with at least one surviving mutant. |
| `guards` | Newline-separated `file:line` of each surviving guard. |
| `killed` | Mutants a test caught. |

## Cost

Finding the mutants type-checks each changed file, about 20 seconds a file.
Then each mutant runs its package's tests once. Total time is roughly changed
files × 20 seconds plus mutants × package test time, both divided by
`parallel`. A pull request outside a `pull_request` event,
or with no changed Go lines, finishes without running a mutant.

## Report

The report is written to `$RUNNER_TEMP/guard-tamper/report.md`, outside the
checkout, and added to the job summary. Each surviving guard is a warning
annotation on its line, or an error when `required` is `true`.

## Run locally

```sh
bash scripts/guard-tamper/install.sh
PATH="${TMPDIR:-/tmp}/guard-tamper-bin:$PATH" \
  GT_PATH=. GT_BASE=origin/main GT_REPORT_DIR="${TMPDIR:-/tmp}/guard-tamper" \
  bash scripts/guard-tamper/run.sh
```

`GT_RANGES_FILE` takes a tab-separated list of file, first line and last line in place of
the diff, to check chosen lines.

## Tests

`scripts/guard-tamper/test-guard-tamper.sh` runs against a fixture package
with one guard its tests catch and one they don't, and asserts that only the
second is reported. `.github/workflows/test-guard-tamper.yaml` runs it and the
reusable workflow end to end.
