#!/usr/bin/env bash
# Exercise check.sh and run.sh against testdata/ fixtures and verify that
# docs/activity-policies/README.md embeds Taskfile.example.yml verbatim.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/activity-policies-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
export GIT_CEILING_DIRECTORIES=$test_root

if [[ -z ${ACTIVITYTOOL:-} ]]; then
  if command -v activitytool >/dev/null 2>&1; then
    ACTIVITYTOOL=$(command -v activitytool)
  else
    BIN_DIR=$test_root/bin bash "$script_dir/install-activitytool.sh"
    ACTIVITYTOOL=$test_root/bin/activitytool
  fi
fi
export ACTIVITYTOOL
PATH="$(cd "$(dirname "$ACTIVITYTOOL")" && pwd):$PATH"
export PATH

passed=0
failed=0
output=

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
      report "$name" true "output contains '$needle'"
    else
      report "$name" false "output missing '$needle'"
    fi
  done
}

run_case() {
  local name=$1 fixture=$2 expected=$3 dir status
  shift 3
  dir=$test_root/$name
  mkdir -p "$dir"
  if [[ -n $fixture ]]; then
    cp -R "$script_dir/testdata/$fixture/." "$dir/"
  fi
  set +e
  output=$( (
    export SCAN_PATH=$dir
    for assignment in "$@"; do export "${assignment?}"; done
    bash "$script_dir/check.sh"
  ) 2>&1)
  status=$?
  set -e
  if [[ $status -eq $expected ]]; then
    report "$name" true "exit $status"
  else
    report "$name" false "exit $status, want $expected"
  fi
}

# 1. Passing tests with auto-discovery (standard milo layout)
run_case "passing-auto" "passing-tests" 0 FAIL_ON_UNTESTED=true
expect_output "passing-auto" "4/4 tests passed, 2 policies validated (0 untested)"

# 2. Valid kustomization without tests passes by default, fails with FAIL_ON_UNTESTED=true
run_case "valid-kustomization" "valid-kustomization" 0 POLICIES_PATH=.
expect_output "valid-kustomization" "0/0 tests passed, 1 policies validated (1 untested)"

run_case "valid-kustomization-strict" "valid-kustomization" 1 POLICIES_PATH=. FAIL_ON_UNTESTED=true
expect_output "valid-kustomization-strict" "iam.miloapis.com-group"

# 3. Invalid policy fails validation and reports every compile/schema error
run_case "invalid-policy" "invalid-policy" 1 POLICIES_PATH=.
expect_output "invalid-policy" "invalid-group-policy" "undeclared reference" "duplicate rule name" "missing closing delimiter"

# 4. Failing English summary assertion prints clear exp vs got diff
run_case "failing-summary" "failing-summary" 1 POLICIES_PATH=group-policy.yaml TESTS_PATH=group.test.yaml
expect_output "failing-summary" \
  'exp: "alice@example.com provisioned team platform-admins"' \
  'got: "alice@example.com created group platform-admins"'

# 5. Empty repo fails by default and passes with ALLOW_EMPTY=true
run_case "empty-fail" "" 2
run_case "empty-allow" "" 0 ALLOW_EMPTY=true

# 6. Workstation runner run.sh works end-to-end
set +e
output=$(SCAN_PATH="$script_dir/testdata/passing-tests" FAIL_ON_UNTESTED=true bash "$script_dir/run.sh" 2>&1)
run_status=$?
set -e
if [[ $run_status -eq 0 ]]; then
  report "run.sh" true "exit 0"
else
  report "run.sh" false "exit $run_status, want 0"
fi
expect_output "run.sh" "SUCCESS: 4/4 tests passed"

# 7. Taskfile.example.yml is embedded verbatim in docs/activity-policies/README.md
readme="$repo_root/docs/activity-policies/README.md"
example="$script_dir/Taskfile.example.yml"
if [[ -f $readme ]]; then
  extracted=$(awk '
    /^```yaml/ { cap = 1; block = ""; next }
    cap && /^```$/ {
      if (block ~ /ACTIVITYTOOL_IMAGE:/ && block ~ /test-activity-policies:/) { printf "%s", block; found = 1; exit }
      cap = 0
    }
    cap { block = block $0 "\n" }
    END { if (!found) exit 1 }
  ' "$readme" 2>/dev/null || true)
  expected_example=$(cat "$example")
  if [[ -n $extracted && $extracted == "$expected_example" ]]; then
    report "readme-taskfile-sync" true "Taskfile.example.yml matches README"
  else
    report "readme-taskfile-sync" false "docs/activity-policies/README.md Taskfile snippet differs from Taskfile.example.yml"
  fi
else
  report "readme-taskfile-sync" false "missing $readme"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
