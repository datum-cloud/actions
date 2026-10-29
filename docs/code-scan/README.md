# Code scan

The `.github/workflows/code-scan.yaml` reusable workflow looks for signs of
injected code in a repository and fails when it finds one that the central
ignore file doesn't cover. Call it on every pull request. It reads the whole
tree, so it also catches a payload that an earlier commit introduced.

[Semgrep](https://semgrep.dev/) reads the files. The workflow installs
nothing from your repository and runs none of its code: there is no
`npm install` and no build step.

## Rules

| Rule | What it catches |
|---|---|
| `process-execution` | Loading `child_process` or `node:child_process` by `import`, `require`, or dynamic `import()`, and calling `Bun.spawn`, `Bun.spawnSync`, or `` Bun.$ ``, including by bracket access or destructuring. |
| `dynamic-code-execution` | `eval`, `Function`, and `new Function(...)`, including through `globalThis`, `window`, `global`, or `self`. It also covers the `vm` module (`runInNewContext`, `runInThisContext`, `runInContext`, `compileFunction`, `new vm.Script`), the `constructor.constructor` trick, a function's own constructor (`(function(){}).constructor(...)`, `[].map.constructor(...)`), and `Reflect.construct(Function, ...)`. |
| `remote-fetch-then-execute` | Data from `fetch`, `axios`, or `http.get` that reaches `eval`, `Function`, `vm`, `child_process`, `Bun.spawn`, `require`, or a dynamic `import`. The rule follows the value through `await`, `.text()`, `.json()`, and `.data`. |
| `download-pipe-to-shell` | `curl` or `wget` piped into `sh`, `bash`, or `zsh` (with or without `sudo`), `sh -c "$(curl ...)"`, and PowerShell `iwr ... \| iex`. It checks shell scripts (`*.sh`, `*.bash`, `*.zsh`), JavaScript and TypeScript files, `package.json`, `Dockerfile*`, `Makefile`, `Taskfile*`, Git hooks (`.husky/`, `lefthook.yml`, `lefthook.yaml`), and files under `.github/`. It skips documentation, because install instructions often show `curl \| sh`. |
| `download-pipe-to-shell-shebang` | The same check in any file whose first line is a shell shebang (`#!/bin/sh`, `#!/usr/bin/env bash`), such as an extensionless `bin/setup` that no path pattern can name. It reports the first match in the file. |
| `hidden-code-after-whitespace` | Code that follows a long run of blank characters on the same line, which pushes it off-screen in diffs and editors. The rule fires on 100 or more blank characters of any kind, 13 or more tabs, or 50 or more ideographic spaces (U+3000). Blank characters include spaces, tabs, form feeds, vertical tabs, Unicode spaces such as NBSP, and zero-width or blank-looking characters such as U+200B, U+FEFF, U+2800, and U+3164. Leading indentation doesn't match. `.md` and `.markdown` files are out of scope because their tables pad cells with spaces; `.mdx` files are in scope. |
| `oversized-line-build-file` | A line longer than 500 characters in a build, CI, or tooling file: `*.config.{js,mjs,cjs,ts}`, `package.json`, `*.sh`, `.eslintrc*`, `.prettierrc*`, `lefthook.yml`, `lefthook.yaml`, and files under `scripts/`, `.github/`, `.husky/`, `cypress/support/`, and `cypress/plugins/`. |
| `require-non-code-file` | `require`, `module.require`, or a `createRequire` function loading a relative or absolute path whose extension isn't `.js`, `.mjs`, `.cjs`, `.ts`, `.mts`, `.cts`, `.jsx`, `.tsx`, `.json`, or `.node`, such as `require('./logo.gif')`. CommonJS runs such a file as JavaScript. TypeScript leaves extensions off imports (`./x.schema` means `x.schema.ts`), so for `import`, dynamic `import()`, and `export ... from` the rule matches only extensions that are never modules: text and data (`.txt`, `.md`, `.yaml`, `.csv`, ...), scripts in other languages (`.sh`, `.py`, ...), archives, and raster images. Bundler assets such as `.css`, `.svg`, fonts, and specifiers with a query (`./x.ttf?url`) don't match. |
| `package-script-exec` | A `scripts` entry in any `package.json` that mentions `child_process`, `eval`, `Function(`, inline code (`node -e`, `node --eval`, `node -p`, `bun -e`, `deno eval`), or `base64`. Install hooks such as `postinstall` run these scripts on every install. |
| `non-utf8-text` | A text file that isn't valid UTF-8. Semgrep's regex rules match nothing in such a file, so one Latin-1 byte would switch them all off for it. A file with a NUL byte in its first 8000 bytes counts as binary and isn't flagged, unless its name or role marks it as code or text: a JavaScript, TypeScript, JSON, shell, YAML, TOML, Markdown, or other source or text extension, `package.json`, `Dockerfile*`, `Makefile`, `Taskfile*`, a dotfile such as `.eslintrc*`, any file that starts with a shebang, any file the `download-pipe-to-shell` rule reads by path (such as a Husky hook, which needs no shebang), and the target of any symlink or other file that gets the JavaScript rules as an explicit target. Those files never get the binary exemption. The scan reports a finding in a symlink target on the link as well. Re-encode the file as UTF-8, or suppress the finding if the file isn't text. |
| `nul-in-text-file` | A NUL byte in a code or text file (as defined above) that is otherwise valid UTF-8. Node still runs such a file, but tools that see the NUL treat it as binary and hide it. |
| `unscanned-content` | Content the checkout doesn't hold, so no rule reads it: a `.gitattributes` line that sends files to Git LFS (`filter=lfs`), a `.gitmodules` file, or a gitlink (a submodule commit) when `path` is in a Git work tree. Review that content another way, then suppress the finding for the `.gitattributes`, `.gitmodules`, or submodule path. |

The JavaScript and TypeScript rules match in `.js`, `.mjs`, `.cjs`, `.ts`, and
the other extensions Semgrep treats as those languages. They also match in
files Node runs that Semgrep wouldn't read as JavaScript: `.mts` and `.cts`
files, files whose first line is a `node`, `bun`, or `deno` shebang, and the
target of a symlink named like a JavaScript file (`link.config.cjs ->
payload.txt`) when the target is inside `path`.

## What gets scanned

The scan reads every file under `path` and ignores the settings an attacker
who can edit the repository could use to hide a file:

- It deletes `.semgrepignore` files before it scans.
- It turns off Semgrep's default skip list (`tests/`, `vendor/`, `*.min.js`).
- It doesn't consult `.gitignore`.
- It has no file size limit and no per-file timeout.
- It scans files that Semgrep takes for binary, so a file that is both an
  image and JavaScript can't pass as an image.
- It ignores inline `nosemgrep` comments. See [Why no inline
  `nosemgrep`](#why-no-inline-nosemgrep).

It skips only the root-level `.git` directory and the ignore file itself. Use
`exclude-paths` for anything else.

It scans `node_modules`, including the root one. The workflow installs
nothing, so any file there was committed, and a later `git pull` would write
it over the developer's installed copy. For a local run on a checkout with
dependencies installed, pass `EXCLUDE_PATHS=/node_modules`.

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Directory to scan, relative to the repository root. |
| `exclude-paths` | None | Comma- or newline-separated globs, relative to `path`, of files or directories not to scan. |
| `extra-rules` | None | Path, relative to `path`, of an extra Semgrep rules file or directory. These run in addition to the rules above. |
| `ignore-file` | `.github/code-scan-ignore.toml` | Central ignore file, relative to `path`. A missing file means no suppressions. |

Each of these inputs can turn the scan off, so the workflow file that sets
them needs the same review as the ignore file. See [Protect the scan's
configuration](#protect-the-scans-configuration).

## Runner requirements

The workflow runs on `ubuntu-latest`, and callers can't change that. The
scripts need Bash, Git, and Python 3.11 or later (`filter.py` reads the
ignore file with `tomllib`); `install-semgrep.sh` stops with exit 2 on an
older Python. Semgrep installs only from prebuilt wheels: on Linux x86_64 its
wheel needs glibc 2.34 or later (Ubuntu 22.04 or later), and macOS on Apple
silicon works too. If you copy the steps to a custom or self-hosted runner,
check those first.

## Required permissions

```yaml
permissions:
  contents: read
```

## Usage

Add `.github/workflows/code-scan.yaml` to the calling repository:

```yaml
name: Code scan

on:
  pull_request:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

jobs:
  code-scan:
    uses: datum-cloud/actions/.github/workflows/code-scan.yaml@v1.24.0
```

To make the scan block merges, add the `code-scan / Scan for injected code`
check to the branch's required status checks.

The job has a 30-minute limit. Semgrep runs without its own timeouts, so a
file can't escape the scan by being slow to parse.

### Exclude paths

```yaml
jobs:
  code-scan:
    uses: datum-cloud/actions/.github/workflows/code-scan.yaml@v1.24.0
    with:
      exclude-paths: |
        examples/*
        docs/snippets
```

Every exclude opens a hole in the scan. For a single file, use an [ignore
entry](#the-ignore-file) instead: it names a rule, needs a reason, and
expires.

Ignore entries name one exact path, so a directory of generated or minified
files, such as a build output or a generated API client that trips
`oversized-line-build-file`, would need one entry per file and new entries
whenever the generator adds a file. Exclude the directory instead, with a
pattern no wider than the generator's output:

```yaml
    with:
      exclude-paths: |
        /app/generated
        /public/vendor/*.min.js
```

A leading `/` anchors the pattern at `path`; without it, the pattern matches
at any depth. Only exclude output that a tool writes and that reviewers don't
read line by line, and protect the workflow file that lists the excludes (see
[Protect the scan's configuration](#protect-the-scans-configuration)). Prefer
generating such files in CI over committing them where you can.

## The ignore file

When you mean a finding to stay, such as a build script that starts a
process, suppress it in `.github/code-scan-ignore.toml`:

```toml
[[Ignore]]
rule = "process-execution"
path = "scripts/release.mjs"
reason = "Runs git to read the tag; reviewed in #123"
ignoreUntil = 2027-04-30
```

Every entry needs all four fields:

| Field | Rule |
|---|---|
| `rule` | The rule id from the findings or the [table above](#rules). |
| `path` | One exact path, relative to `path`. No globs and no directories. |
| `reason` | Why the code is safe. The job summary shows the reason. |
| `ignoreUntil` | A date at most 12 months after the day of the scan. |

An entry suppresses a finding only when the rule id and the path both match
exactly. Once `ignoreUntil` passes, the entry stops applying, the finding
fails the scan again, and the job warns about the expired entry. To renew it,
write a new date and a new reason.

An entry covers every finding of its rule in that file, including any that a
later change adds. A pull request that changes a suppressed file can slip in
a second payload the scan won't report, so reviewers need to re-check a
suppressed file whenever it changes. The job summary lists every suppressed
finding.

The ignore file's location and every entry path are relative to the `path`
input, not the repository root. With the default `path: .` the two are the
same.

On a `pull_request` event the scan reads the ignore file from the pull
request's base commit, not from the pull request. An entry that a pull
request adds or changes takes effect only after it merges, so a pull request
can't suppress its own finding, even in a repository without code owner
review. The trade-off: a pull request that adds code and the entry that
excuses it fails until the entry reaches the base branch in a pull request
of its own, and that separate pull request is the change reviewers approve.

The base is the first parent of the merge commit that GitHub builds for the
pull request. The workflow fetches two commits (`fetch-depth: 2`) and checks
that the merge commit's second parent is the pull request's head; if it
isn't, or the base is missing, the scan exits 2. The job summary names the
base commit the entries came from. When the pull request changes the ignore
file, the job adds a notice that its entries take effect only after it
merges. The scan still validates the pull request's copy and exits 2 if it is
invalid, so a broken file can't merge and fail every later scan.

On `push`, `merge_group`, `workflow_dispatch`, and other events the scan
reads the ignore file from the checked-out commit. For `merge_group` that is
the merged file, which is fine while the `pull_request` check is required: a
pull request whose findings need its own new entries fails that check and
can't reach the merge queue.

The scan accepts an ignore file only inside `path` and only without glob
characters. It doesn't scan the ignore file as code, because its reasons may
quote the code they excuse.

### Protect the scan's configuration

Reading the ignore file from the base stops a pull request from suppressing
its own finding, but anyone who can merge a change to the ignore file can
still hide a payload in a later pull request. Scans on `push` and
`merge_group` read the checked-out file, and the workflow file that calls the
scan is part of the pull request. In the caller's workflow,
`exclude-paths: "**"`, a `path` that points at an empty directory, or an
`ignore-file` that names a file nobody reviews each switches the gate off
without touching the ignore file. Code owner review is still needed: require
it for the ignore file, the workflow directory, and the CODEOWNERS file
itself. In `.github/CODEOWNERS`:

```text
/.github/code-scan-ignore.toml @example-org/security
/.github/workflows/ @example-org/security
/.github/CODEOWNERS @example-org/security
```

Turn on "Require review from Code Owners" in the branch's protection rules.
Without it, the entries only request a review.

The ignore file pattern above matches only when `path` is `.`, the default.
If you set `path` to a subdirectory, the ignore file lives under it, so point
the CODEOWNERS entry at that location.

## Why no inline `nosemgrep`

A `// nosemgrep` comment sits on the same line as the code it excuses. An
attacker who adds a payload adds the comment in the same commit, and the
reviewer sees an ordinary-looking line. The ignore file sits apart from the
code, code owners review it, and each entry names a rule, an exact path, a
reason, and an expiry date. The scan passes `--disable-nosem` to Semgrep, so
the comment suppresses nothing.

## Results

The job exits with one of these codes:

| Code | Meaning |
|---|---|
| `0` | No findings, or an active ignore entry covers every finding. |
| `1` | At least one finding has no ignore entry. |
| `2` | A scanner or configuration error, such as a missing `path`, an unreadable rules file, an invalid ignore file, or a Semgrep failure. No ignore entry can excuse it. |

The scan doesn't echo raw Semgrep output to the log. That output contains the
matched source line, which comes from the pull request and so from a possible
attacker. GitHub parses any log line that starts with `::` as a workflow
command, so a crafted line could forge one. The scan prints each finding as
an escaped `::error` annotation instead, which GitHub draws on the
Files-changed line, and appends a Markdown table of findings and
suppressions to the job summary.

Annotation paths are relative to the repository root, so GitHub can draw them
when `path` is a subdirectory. The job summary, like the ignore file, shows
paths relative to `path`.

## Run it locally

You need `bash`, `python3`, and `git`.

```bash
# From a checkout of datum-cloud/actions.
bash scripts/code-scan/install-semgrep.sh
export PATH="${TMPDIR:-/tmp}/code-scan-venv/bin:$PATH"

SCAN_PATH=/path/to/your/repo bash scripts/code-scan/scan.sh
```

`install-semgrep.sh` installs the locked Semgrep into a virtualenv; set
`CODE_SCAN_VENV` to choose where. It works with Python 3.11 or later on macOS
and Linux. `scan.sh` reads the workflow inputs from the environment variables
`SCAN_PATH`, `EXCLUDE_PATHS`, `EXTRA_RULES`, and `IGNORE_FILE`, and exits
with the codes above. Set `IGNORE_BASE_REF` to a commit to read the ignore
file from that commit, as the workflow does on a pull request.
`IGNORE_BASE_REF=origin/main` means the tip of `main`, not the merge base of
your branch; use `IGNORE_BASE_REF=$(git merge-base origin/main HEAD)` to match
what a pull request would see.

The scan deletes every `.semgrepignore` file under `SCAN_PATH`, so run it on a
checkout you can afford to modify.

## Test the workflow

`.github/workflows/test-code-scan.yaml` runs when the scan changes and once a
week. Its `test` job runs `scripts/code-scan/test-code-scan.sh`, which checks
that every payload fixture in `scripts/code-scan/testdata` fails the scan and
the clean fixture passes. Its `workflow` job calls the reusable workflow on
the clean fixture, which exercises the script checkout and the inputs.

The fixtures hold payloads on purpose. If you scan a copy of this repository
with the workflow, exclude `scripts/code-scan/testdata`.

## How it works

The workflow sparse-checks-out only `scripts/code-scan/*.sh`, `*.py`,
`requirements.txt`, and `rules/*.yaml` from this repository at its own
commit, using `job.workflow_repository` and `job.workflow_sha`, so the
scripts match the version you pinned. It moves them to `$RUNNER_TEMP`,
outside your workspace, where the scan can't see them.

After the main Semgrep pass, `prescan.py` reads the files that pass listed in
its JSON output (`paths.scanned`, so the same excludes apply). It checks them
for what Semgrep's rules can't see, such as text that isn't valid UTF-8, and
picks the files for a second pass with explicit targets. Its findings join
Semgrep's and go through the same ignore file and report.

The scan treats two cases as errors: a file the pre-pass can't read, and a
scan that read no files while `path` holds some, for example because
`exclude-paths` matches everything. An empty `path`, or one that holds only
the ignore file, has nothing to scan and exits 0.

Semgrep and every package it depends on are pinned by version and SHA-256
hash in `scripts/code-scan/requirements.txt`, which `uv pip compile
--universal --generate-hashes` generates from `requirements.in` (the command
is in the file's header). `install-semgrep.sh` installs it with `pip
--require-hashes --no-deps --only-binary :all:`, so a changed or compromised
release of any dependency fails the install rather than running inside the
scanner. Renovate's `pip-compile` manager bumps `requirements.in` and
regenerates the lock file.
