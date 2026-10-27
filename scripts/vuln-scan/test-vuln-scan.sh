#!/usr/bin/env bash
# Run detect.sh and scan.sh against the fixtures in testdata/ and check that
# known-vulnerable dependencies fail the scan and name their advisories, that
# clean ones pass, and that nothing-to-scan, ignores, and narrowing behave as
# documented, then run the local entry point, run.sh, and the Taskfile that
# fetches it. Needs govulncheck, osv-scanner, go, git, task, and python3 on
# PATH, plus network access to the vulnerability databases, go.dev, and the Go
# module proxy. Set TEST_IMAGES=true to also scan container images with trivy.
#
# Fixture dependency files end in .fixture so that dependency graphs and
# update bots ignore their vulnerable versions; each case copies its fixture
# to a temporary directory and drops the suffix.

# Expected output quotes Markdown code spans, so backticks stay literal.
# shellcheck disable=SC2016
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/vuln-scan-tests.XXXXXX")
# The Go module cache is read-only, so make it writable before removing it.
trap 'chmod -R u+w "$test_root" 2> /dev/null; rm -rf "$test_root"' EXIT
# Stop Git from finding a repository above the temporary directory, so cases
# without their own `git init` exercise the non-Git fallback.
export GIT_CEILING_DIRECTORIES=$test_root
# As setup-go sets it: a module that needs a newer Go fails instead of
# downloading one.
export GOTOOLCHAIN=local

passed=0
failed=0
output=

# materialize FIXTURE DEST copies a testdata fixture and drops the suffixes.
materialize() {
  local file
  mkdir -p "$2"
  cp -R "$script_dir/testdata/$1/." "$2/"
  while IFS= read -r -d '' file; do
    mv "$file" "${file%.fixture}"
  done < <(find "$2" -name '*.fixture' -print0)
}

git_init() {
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.com commit -q -m fixture
}

# run_case NAME FIXTURE EXPECTED_EXIT [VAR=value ...]
# FIXTURE is a directory under testdata/, an absolute path, or empty.
run_case() {
  local name=$1 fixture=$2 expected=$3 dir status file
  shift 3
  dir=$test_root/$name
  mkdir -p "$dir"
  if [[ -n $fixture ]]; then
    [[ $fixture == /* ]] || fixture=$script_dir/testdata/$fixture
    cp -R "$fixture/." "$dir/"
    while IFS= read -r -d '' file; do
      mv "$file" "${file%.fixture}"
    done < <(find "$dir" -name '*.fixture' -not -path '*/.git/*' -print0)
  fi
  set +e
  output=$( (
    export SCAN_PATH=$dir PLAN_FILE=$dir.plan
    for assignment in "$@"; do export "${assignment?}"; done
    bash "$script_dir/detect.sh" && bash "$script_dir/scan.sh"
  ) 2>&1)
  status=$?
  set -e
  if [[ $status -eq $expected ]]; then
    report "$name" true "exit $status"
  else
    report "$name" false "exit $status, want $expected"
  fi
}

report() {
  if [[ $2 == true ]]; then
    passed=$((passed + 1))
    printf 'ok   %s: %s\n' "$1" "$3"
  else
    failed=$((failed + 1))
    printf 'FAIL %s: %s\n' "$1" "$3"
    printf '%s\n' "$output" | sed 's/^/     | /'
  fi
}

expect_output() {
  local name=$1 needle
  shift
  for needle in "$@"; do
    if grep -qF -- "$needle" <<< "$output"; then
      report "$name" true "output has '$needle'"
    else
      report "$name" false "output lacks '$needle'"
    fi
  done
}

reject_output() {
  local name=$1 needle
  shift
  for needle in "$@"; do
    if grep -qF -- "$needle" <<< "$output"; then
      report "$name" false "output has '$needle'"
    else
      report "$name" true "output lacks '$needle'"
    fi
  done
}

# Each ecosystem on its own fails on a known-vulnerable dependency.
run_case go-vulnerable vulnerable 1 ECOSYSTEMS=go
expect_output go-vulnerable GO-2021-0113 GO-2022-1059 \
  '| go | `go` | govulncheck | **vulnerabilities found** |' \
  '| node | `npm/package-lock.json` | not scanned | ecosystem not selected |'

run_case node-vulnerable vulnerable 1 ECOSYSTEMS=node
expect_output node-vulnerable GHSA-35jh-r3h4-6jhm \
  '| node | `npm/package-lock.json` | osv-scanner | **vulnerabilities found (' \
  '| node | `pnpm/pnpm-lock.yaml` | osv-scanner | **vulnerabilities found (' \
  '| node | `yarn/yarn.lock` | osv-scanner | **vulnerabilities found (' \
  '| node | `bun/bun.lock` | osv-scanner | **vulnerabilities found ('

run_case python-vulnerable vulnerable 1 ECOSYSTEMS=python
expect_output python-vulnerable GHSA-x84v-xcm2-53pg \
  '| python | `python/requirements.txt` | osv-scanner | **vulnerabilities found ('

run_case rust-vulnerable vulnerable 1 ECOSYSTEMS=rust
expect_output rust-vulnerable RUSTSEC-2021-0003 \
  '| rust | `rust/Cargo.lock` | osv-scanner | **vulnerabilities found ('

# Auto-detection finds every ecosystem in a multi-language repository.
run_case auto-vulnerable vulnerable 1
expect_output auto-vulnerable GO-2021-0113 GHSA-35jh-r3h4-6jhm GHSA-x84v-xcm2-53pg \
  RUSTSEC-2021-0003 'problem(s) across 7 scanned target(s)'

# exclude-paths drops targets and says so.
run_case exclude-paths vulnerable 1 'EXCLUDE_PATHS=go,npm pnpm
yarn bun python'
expect_output exclude-paths RUSTSEC-2021-0003 \
  '| go | `go` | not scanned | excluded by exclude-paths |'
reject_output exclude-paths GO-2021-0113 GHSA-35jh-r3h4-6jhm

# Clean dependencies pass. The Go fixture requires a vulnerable module version
# but never calls the vulnerable code, so govulncheck passes it. The npm and
# Python fixtures have a vulnerable dev dependency, which is out of scope by
# default.
run_case clean clean 0
expect_output clean '**Passed:** no known vulnerabilities in 4 scanned target(s).' \
  "File discovery: find, not a Git work tree, so .gitignore doesn't apply." \
  '| go | `go` | govulncheck | no called vulnerabilities |' \
  '| python | `python/requirements-dev.txt` | not scanned | development requirements; set include-dev-dependencies to scan |' \
  '| rust | `rust/Cargo.lock` | osv-scanner | no known vulnerabilities (1 informational advisories) |' \
  'RUSTSEC-2024-0436  paste@1.0.15'

run_case clean-with-dev clean 1 INCLUDE_DEV=true
expect_output clean-with-dev GHSA-xvch-5gv4-984h PYSEC-2026-1845 'Dev dependencies: included.'

# An ignore entry suppresses only the advisories it names, by ID or alias.
run_case ignored ignored 0
expect_output ignored 'GO-2021-0113: ignored by osv-scanner.toml entry GO-2021-0113' \
  'GO-2022-1059: ignored by osv-scanner.toml entry CVE-2022-32149' \
  '| go | `go` | govulncheck | no called vulnerabilities (some ignored) |' \
  '| node | `npm/package-lock.json` | osv-scanner | no known vulnerabilities |'

mkdir -p "$test_root/fixtures/expired"
cp -R "$script_dir/testdata/ignored/." "$test_root/fixtures/expired/"
sed -i.orig 's/ignoreUntil = 2099-01-01/ignoreUntil = 2020-01-01/' \
  "$test_root/fixtures/expired/osv-scanner.toml.fixture"
run_case ignore-expired "$test_root/fixtures/expired" 1
expect_output ignore-expired 'GO-2021-0113: not ignored' GHSA-35jh-r3h4-6jhm

mkdir -p "$test_root/fixtures/no-reason"
cp -R "$script_dir/testdata/ignored/." "$test_root/fixtures/no-reason/"
sed -i.orig '/Fixture: alias of GO-2022-1059/d' \
  "$test_root/fixtures/no-reason/osv-scanner.toml.fixture"
run_case ignore-without-reason "$test_root/fixtures/no-reason" 1
expect_output ignore-without-reason 'IgnoredVulns entry 2 (CVE-2022-32149) has no reason'

# In a Git work tree, files come from Git. An ignored lockfile and tracked
# vendor and testdata lockfiles are skipped; an untracked one that isn't
# ignored is scanned; submodules and nested repositories are listed as skipped.
repo=$test_root/fixtures/git-repo
materialize clean "$repo"
for dir in dist vendor/example testdata/example; do
  mkdir -p "$repo/$dir"
  cp "$script_dir/testdata/vulnerable/npm/package-lock.json.fixture" "$repo/$dir/package-lock.json"
done
printf 'dist/\n' > "$repo/.gitignore"
materialize vulnerable/npm "$repo/submodule"
git_init "$repo/submodule"
git_init "$repo" 2> /dev/null
materialize vulnerable/npm "$repo/nested"
git_init "$repo/nested"
run_case git-ignored "$repo" 0
expect_output git-ignored \
  "File discovery: git, tracked files and untracked files that .gitignore doesn't exclude." \
  '| git | `submodule` | not scanned | Git submodule; scan it from its own repository |' \
  '| git | `nested` | not scanned | nested Git repository; scan it from its own repository |'
reject_output git-ignored dist/package-lock.json vendor/example testdata/example GHSA-35jh-r3h4-6jhm

mkdir -p "$repo/untracked"
cp "$script_dir/testdata/vulnerable/npm/package-lock.json.fixture" "$repo/untracked/package-lock.json"
run_case git-untracked "$repo" 1
expect_output git-untracked GHSA-35jh-r3h4-6jhm \
  '| node | `untracked/package-lock.json` | osv-scanner | **vulnerabilities found ('
reject_output git-untracked dist/package-lock.json

# A manifest pinned by a lockfile in its own directory or any parent isn't
# reported; one with no lockfile is listed and warned about.
manifests=$test_root/fixtures/manifests
materialize clean/npm "$manifests/workspace"
materialize clean/rust "$manifests/workspace"
materialize clean/python "$manifests/workspace"
mkdir -p "$manifests/workspace/packages/app" "$manifests/workspace/crates/lib" \
  "$manifests/workspace/py/tool" "$manifests/lone"
cp "$manifests/workspace/package.json" "$manifests/workspace/packages/app/package.json"
cp "$manifests/workspace/Cargo.toml" "$manifests/workspace/crates/lib/Cargo.toml"
printf '[project]\nname = "tool"\nversion = "0.1.0"\n' > "$manifests/workspace/py/tool/pyproject.toml"
cp "$manifests/workspace/package.json" "$manifests/workspace/Cargo.toml" \
  "$manifests/workspace/py/tool/pyproject.toml" "$manifests/lone/"
run_case manifests "$manifests" 0
expect_output manifests \
  '| node | `lone/package.json` | not scanned | **no lockfile:** package.json with no lockfile; versions are not pinned |' \
  '| rust | `lone/Cargo.toml` | not scanned | **no lockfile:** Cargo.toml with no lockfile; versions are not pinned |' \
  '| python | `lone/pyproject.toml` | not scanned | **no lockfile:** pyproject.toml with no lockfile; versions are not pinned |' \
  '::warning title=Vulnerability scan (node)::lone/package.json has no lockfile'
reject_output manifests workspace/package.json packages/app crates/lib py/tool

# allow-empty covers a repository without dependencies, not one whose
# dependencies have no lockfile.
mkdir -p "$test_root/fixtures/unlocked-only"
cp "$manifests/lone/package.json" "$test_root/fixtures/unlocked-only/"
run_case unlocked-only "$test_root/fixtures/unlocked-only" 1 ALLOW_EMPTY=true
expect_output unlocked-only "\`allow-empty\` doesn't cover unlocked dependencies"
run_case unlocked-excluded "$test_root/fixtures/unlocked-only" 0 ALLOW_EMPTY=true \
  EXCLUDE_PATHS=package.json
expect_output unlocked-excluded 'excluded by exclude-paths' 'nothing was scanned'

# The Go version comes from the modules' highest minor version. A toolchain
# directive in that minor wins if it meets every go directive; otherwise the
# scan uses that minor's latest patch. The input overrides both.
gomods=$test_root/fixtures/go-versions
mkdir -p "$gomods/old" "$gomods/pinned" "$gomods/floor"
printf 'module example.com/old\n\ngo 1.24.0\n' > "$gomods/old/go.mod"
printf 'module example.com/pinned\n\ngo 1.26.0\n\ntoolchain go1.26.4\n' > "$gomods/pinned/go.mod"
printf 'module example.com/floor\n\ngo 1.26.0\n' > "$gomods/floor/go.mod"
run_case go-version-pin "$gomods" 0
expect_output go-version-pin \
  'go-version: 1.26.4 (from the toolchain directive in pinned/go.mod; the highest Go minor version across 3 modules'
printf 'module example.com/floor\n\ngo 1.26.6\n' > "$gomods/floor/go.mod"
run_case go-version-floor-above-pin "$gomods" 0
expect_output go-version-floor-above-pin \
  'go-version: 1.26 (latest 1.26 patch, because floor/go.mod requires go 1.26.6, above the toolchain directive in pinned/go.mod;'
rm -r "$gomods/old" "$gomods/pinned"
run_case go-version-directive "$gomods" 0
expect_output go-version-directive 'go-version: 1.26 (latest 1.26 patch, from the go directive in floor/go.mod)'
run_case go-version-input "$gomods" 0 GO_VERSION=1.25.7
expect_output go-version-input 'go-version: 1.25.7 (set by the go-version input)'

# The workflow checks that setup-go installed the version the scan asked for.
local_go=$(go env GOVERSION)
run_case go-version-mismatch "$gomods" 1 REQUIRE_GO_VERSION=true GO_VERSION=1.20.1
expect_output go-version-mismatch "installed Go is $local_go, but the scan requested 1.20.1"
run_case go-version-match "$gomods" 0 REQUIRE_GO_VERSION=true "GO_VERSION=${local_go#go}"
run_case go-version-minor-match "$gomods" 0 REQUIRE_GO_VERSION=true \
  "GO_VERSION=$(cut -d. -f1-2 <<< "${local_go#go}")"

# A module that needs a newer Go than the installed one fails loudly.
mkdir -p "$test_root/fixtures/go-too-new"
printf 'module example.com/future\n\ngo 1.99.0\n' > "$test_root/fixtures/go-too-new/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$test_root/fixtures/go-too-new/main.go"
run_case go-too-new "$test_root/fixtures/go-too-new" 1
expect_output go-too-new 'requires go >= 1.99.0' '| go | `.` | govulncheck | **scanner error (exit'

# Nothing to scan fails unless the caller says that is expected.
run_case empty empty 1
expect_output empty 'nothing was scanned'
run_case empty-allowed empty 0 ALLOW_EMPTY=true
expect_output empty-allowed '::warning title=Vulnerability scan::nothing was scanned'

# An ecosystem the caller asks for must be present.
run_case missing-ecosystem empty 1 ECOSYSTEMS=go
expect_output missing-ecosystem 'ecosystems input selects go, but no go dependencies were found'
run_case unknown-ecosystem empty 1 ECOSYSTEMS=java
expect_output unknown-ecosystem "unknown ecosystem 'java'"

# A dependency file that cannot be scanned fails instead of being skipped.
run_case unsupported unsupported 1
expect_output unsupported '**unsupported:** binary lockfile'

# run.sh, the local entry point, with its own scanner cache.
cache=$test_root/cache
# run_local NAME FIXTURE EXPECTED_EXIT [VAR=value ...] runs run.sh in a copy
# of FIXTURE, as a developer would from the repository root.
run_local() {
  local name=$1 fixture=$2 expected=$3 dir status
  shift 3
  dir=$test_root/$name
  if [[ $fixture == /* ]]; then
    mkdir -p "$dir"
    cp -R "$fixture/." "$dir/"
  else
    materialize "$fixture" "$dir"
  fi
  set +e
  output=$(cd "$dir" && env XDG_CACHE_HOME="$cache" "$@" bash "$script_dir/run.sh" 2>&1)
  status=$?
  set -e
  if [[ $status -eq $expected ]]; then
    report "$name" true "exit $status"
  else
    report "$name" false "exit $status, want $expected"
  fi
}

mtime() {
  python3 -I -c 'import os, sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"
}

set +e
output=$(bash "$script_dir/run.sh" --help 2>&1)
status=$?
set -e
report run-help "$([[ $status -eq 0 ]] && echo true || echo false)" "exit $status"
expect_output run-help 'Usage: run.sh' GO_VERSION ALLOW_EMPTY datum-vuln-scan/bin

run_local run-vulnerable vulnerable/npm 1
expect_output run-vulnerable GHSA-35jh-r3h4-6jhm 'Installed osv-scanner' \
  'error: Vulnerability scan (node): package-lock.json: osv-scanner found'
reject_output run-vulnerable '::error' '|---|'

osv_dir=$(find "$cache/datum-vuln-scan/bin" -maxdepth 1 -name 'osv-scanner-v*' | head -n 1)
before=$(mtime "$osv_dir")
run_local run-cached vulnerable/npm 1
expect_output run-cached "Using cached osv-scanner" GHSA-35jh-r3h4-6jhm
reject_output run-cached 'Installed osv-scanner'
report run-cached "$([[ $(mtime "$osv_dir") == "$before" ]] && echo true || echo false)" \
  "cache directory unchanged by the second run"

run_local run-clean clean 0
expect_output run-clean 'Passed: no known vulnerabilities in 4 scanned target(s).' \
  'Go 1.26 resolved to go1.26.'

# GOTOOLCHAIN makes the scan use the selected Go, not the installed one.
pin=1.26.10
[[ $(go env GOVERSION) != "go$pin" ]] || pin=1.26.9
mkdir -p "$test_root/fixtures/pinned-go"
printf 'module example.com/pinned\n\ngo 1.26.0\n\ntoolchain go%s\n' "$pin" > "$test_root/fixtures/pinned-go/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$test_root/fixtures/pinned-go/main.go"
# A fresh module cache makes go download the toolchain, as on a new machine.
run_local run-go-toolchain "$test_root/fixtures/pinned-go" 0 GOMODCACHE="$test_root/gomodcache"
downloaded=$(find "$test_root/gomodcache/golang.org" -maxdepth 1 -name "toolchain@*go$pin.*" 2> /dev/null)
report run-go-toolchain "$([[ -n $downloaded ]] && echo true || echo false)" \
  "go$pin downloaded into the empty module cache"
expect_output run-go-toolchain "Go: go$pin, from the toolchain directive in go.mod. Requested $pin."

# Without the module proxy the toolchain can't download, and the scan stops.
sed -i.orig 's/^toolchain .*/toolchain go1.26.3/' "$test_root/fixtures/pinned-go/go.mod"
run_local run-go-offline "$test_root/fixtures/pinned-go" 1 GOPROXY=off
expect_output run-go-offline "can't switch to Go 1.26.3"

# The documented Taskfile fetches the scripts at a tag, once per commit, from
# a local bare repository standing in for this one.
if ! command -v task > /dev/null; then
  report taskfile false "task is not on PATH"
else
  source_repo=$test_root/actions-source
  mkdir -p "$source_repo/scripts/vuln-scan"
  # Fixtures included, so the sparse fetch has something to leave out.
  cp -R "$script_dir/." "$source_repo/scripts/vuln-scan/"
  git_init "$source_repo"
  git -C "$source_repo" tag v0.0.1
  git -C "$source_repo" -c user.name=test -c user.email=test@example.com \
    commit -q --allow-empty -m second
  git -C "$source_repo" -c user.name=test -c user.email=test@example.com \
    tag -a v0.0.2 -m v0.0.2
  git clone -q --bare "$source_repo" "$test_root/actions.git"
  caller=$test_root/caller
  materialize clean/npm "$caller"
  cp "$script_dir/Taskfile.example.yml" "$caller/Taskfile.yml"
  run_task() {
    local name=$1 expected=$2 status
    shift 2
    set +e
    output=$(cd "$caller" && XDG_CACHE_HOME=$cache task "$@" \
      "ACTIONS_REPO=file://$test_root/actions.git" 2>&1)
    status=$?
    set -e
    report "$name" "$([[ $status -eq $expected ]] && echo true || echo false)" "exit $status, want $expected"
  }
  run_task taskfile-fetch 0 vuln-scan ACTIONS_REF=v0.0.1
  expect_output taskfile-fetch 'git clone --quiet --depth 1 --branch "v0.0.1"' \
    'Passed: no known vulnerabilities in 1 scanned target(s).'
  run_task taskfile-reuse 0 ci ACTIONS_REF=v0.0.1
  expect_output taskfile-reuse 'Task "vuln-scan:fetch" is up to date' 'Passed:'
  reject_output taskfile-reuse 'git clone'
  run_task taskfile-new-ref 0 vuln-scan ACTIONS_REF=v0.0.2
  expect_output taskfile-new-ref 'git clone --quiet --depth 1 --branch "v0.0.2"'
  fetched=$(find "$cache/datum-vuln-scan/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  report taskfile-new-ref "$([[ $fetched -eq 2 ]] && echo true || echo false)" \
    "$fetched cached script directories, want 2"
  report taskfile-new-ref "$([[ -z $(find "$cache/datum-vuln-scan/scripts" -path '*testdata*') ]] && echo true || echo false)" \
    "no testdata in the cached scripts"
  # A tag that moves to another commit, as v1 does, is fetched again.
  git -C "$source_repo" -c user.name=test -c user.email=test@example.com \
    commit -q --allow-empty -m third
  git -C "$source_repo" tag -f v0.0.1 > /dev/null
  git -C "$source_repo" push -q -f "$test_root/actions.git" v0.0.1
  run_task taskfile-moved-tag 0 vuln-scan ACTIONS_REF=v0.0.1
  expect_output taskfile-moved-tag 'git clone --quiet --depth 1 --branch "v0.0.1"'
  fetched=$(find "$cache/datum-vuln-scan/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  report taskfile-moved-tag "$([[ $fetched -eq 3 ]] && echo true || echo false)" \
    "$fetched cached script directories, want 3"
  run_task taskfile-missing-tag 201 vuln-scan ACTIONS_REF=v9.9.9
  expect_output taskfile-missing-tag 'has no tag v9.9.9'
fi

# The README's snippet is this Taskfile, word for word.
snippet=$(awk '/<!-- taskfile-snippet -->/ { found = 1; next }
  found && /^```yaml$/ { inside = 1; next }
  inside && /^```$/ { exit }
  inside { print }' "$script_dir/../../docs/vuln-scan/README.md")
if [[ $snippet == "$(cat "$script_dir/Taskfile.example.yml")" ]]; then
  report readme-snippet true "matches Taskfile.example.yml"
else
  report readme-snippet false "differs from Taskfile.example.yml"
fi

if [[ ${TEST_IMAGES:-false} == true ]]; then
  run_case image-vulnerable "" 1 IMAGES=alpine:3.18.0
  expect_output image-vulnerable CVE-2022-48174 \
    '| image | `alpine:3.18.0` | trivy | **vulnerabilities found** |'
  run_case image-clean "" 0 IMAGES=cgr.dev/chainguard/static:latest
  expect_output image-clean '| image | `cgr.dev/chainguard/static:latest` | trivy | no known vulnerabilities |'

  # .trivyignore.yaml drops the CVE it names and nothing else.
  mkdir -p "$test_root/fixtures/image-ignored"
  cat > "$test_root/fixtures/image-ignored/.trivyignore.yaml" <<'YAML'
vulnerabilities:
  - id: CVE-2022-48174
    expired_at: 2099-01-01
    statement: Fixture.
YAML
  run_case image-ignored "$test_root/fixtures/image-ignored" 1 IMAGES=alpine:3.18.0
  expect_output image-ignored CVE-2023-42363 'Ignore files: `.trivyignore.yaml`'
  reject_output image-ignored CVE-2022-48174
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
