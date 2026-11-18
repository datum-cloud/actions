#!/usr/bin/env bash
# Validate ActivityPolicy manifests and run declarative *.test.yaml suites
# using activitytool. Works inside GitHub Actions and locally via run.sh.
set -euo pipefail

SCAN_PATH=${SCAN_PATH:-.}
POLICIES_PATH=${POLICIES_PATH:-}
TESTS_PATH=${TESTS_PATH:-}
FAIL_ON_UNTESTED=${FAIL_ON_UNTESTED:-false}
ALLOW_EMPTY=${ALLOW_EMPTY:-false}
ACTIVITYTOOL=${ACTIVITYTOOL:-activitytool}

fail_config() {
  echo "::error title=Activity policy tests::$1"
  exit 2
}

[[ -d $SCAN_PATH ]] || fail_config "path '$SCAN_PATH' is not a directory"
case $FAIL_ON_UNTESTED in
  true | false) ;;
  *) fail_config "fail-on-untested must be 'true' or 'false', got '$FAIL_ON_UNTESTED'" ;;
esac
case $ALLOW_EMPTY in
  true | false) ;;
  *) fail_config "allow-empty must be 'true' or 'false', got '$ALLOW_EMPTY'" ;;
esac

resolved_tool=$(command -v "$ACTIVITYTOOL" 2>/dev/null || true)
[[ -n $resolved_tool && -x $resolved_tool ]] || fail_config "activitytool binary '$ACTIVITYTOOL' not found on PATH"
if [[ $resolved_tool == */* ]]; then
  resolved_tool=$(cd "$(dirname "$resolved_tool")" && pwd)/$(basename "$resolved_tool")
fi
ACTIVITYTOOL=$resolved_tool

cd "$SCAN_PATH"

split_list() {
  printf '%s\n' "$1" | tr ', \t' '\n' | sed '/^$/d'
}

normalize_rel_path() {
  local rel=$1
  rel=${rel#./}
  rel=${rel%/}
  [[ -n $rel ]] || rel=.
  if [[ $rel == /* ]]; then
    fail_config "path '$1' must be relative to '$SCAN_PATH'"
  fi
  case /$rel/ in
    */../*) fail_config "path '$1' must not escape '$SCAN_PATH'" ;;
  esac
  printf '%s\n' "$rel"
}

list_repo_yaml_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files --cached --others --exclude-standard -z -- '*.yaml' '*.yml' | tr '\0' '\n'
  else
    find . \( -name .git -o -name node_modules -o -name vendor -o -name testdata \) -prune \
      -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sed 's|^\./||'
  fi | LC_ALL=C sort -u
}

is_test_filename() {
  case $(basename "$1") in
    *.test.yaml | *.tests.yaml | *-test.yaml | *-tests.yaml | *.test.yml | *.tests.yml | *-test.yml | *-tests.yml)
      return 0
      ;;
  esac
  return 1
}

policy_paths=()
if [[ -n $POLICIES_PATH ]]; then
  while IFS= read -r entry; do
    rel=$(normalize_rel_path "$entry")
    [[ -e $rel ]] || fail_config "policies-path entry '$rel' does not exist under '$SCAN_PATH'"
    policy_paths+=("$rel")
  done < <(split_list "$POLICIES_PATH")
else
  for candidate in config/services/activity/policies config/activity/policies config/policies; do
    if [[ -e $candidate ]]; then
      policy_paths+=("$candidate")
    fi
  done

  if [[ ${#policy_paths[@]} -eq 0 ]]; then
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      case /$rel/ in */node_modules/* | */vendor/* | */testdata/*) continue ;; esac
      is_test_filename "$rel" && continue
      [[ -f $rel ]] || continue
      if grep -qE '^[[:space:]]*kind:[[:space:]]*ActivityPolicy([[:space:]]|$)' "$rel"; then
        policy_paths+=("$rel")
      fi
    done < <(list_repo_yaml_files)
  fi
fi

test_paths=()
if [[ -n $TESTS_PATH ]]; then
  while IFS= read -r entry; do
    rel=$(normalize_rel_path "$entry")
    [[ -e $rel ]] || fail_config "tests-path entry '$rel' does not exist under '$SCAN_PATH'"
    test_paths+=("$rel")
  done < <(split_list "$TESTS_PATH")
else
  for candidate in test/activity-policies test/policies; do
    if [[ -d $candidate ]]; then
      test_paths+=("$candidate")
    fi
  done

  if [[ ${#test_paths[@]} -eq 0 ]]; then
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      case /$rel/ in */node_modules/* | */vendor/* | */testdata/*) continue ;; esac
      is_test_filename "$rel" || continue
      [[ -f $rel ]] || continue
      if grep -qE '^[[:space:]]*(policy_files|rule_files):' "$rel"; then
        test_paths+=("$rel")
      fi
    done < <(list_repo_yaml_files)
  fi
fi

echo "ActivityPolicy validation and testing"
echo "  activitytool: $("$ACTIVITYTOOL" --version 2>&1)"
if [[ ${#policy_paths[@]} -gt 0 ]]; then
  echo "  policies:     ${policy_paths[*]}"
else
  echo "  policies:     (none discovered; using test policy_files)"
fi
if [[ ${#test_paths[@]} -gt 0 ]]; then
  echo "  tests:        ${test_paths[*]}"
else
  echo "  tests:        (none)"
fi
echo ""

if [[ ${#policy_paths[@]} -eq 0 && ${#test_paths[@]} -eq 0 ]]; then
  if [[ $ALLOW_EMPTY == true ]]; then
    echo "::warning title=Activity policy tests::no ActivityPolicy manifests or test files found under '$SCAN_PATH'"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      {
        echo "### ActivityPolicy Tests"
        echo ""
        echo "No ActivityPolicy manifests or test files found (\`allow-empty: true\`)."
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  fail_config "no ActivityPolicy manifests or test files found under '$SCAN_PATH' (set allow-empty: true to pass)"
fi

cmd=("$ACTIVITYTOOL" test)
for p in "${policy_paths[@]+"${policy_paths[@]}"}"; do
  cmd+=(--policies "$p")
done
if [[ $FAIL_ON_UNTESTED == true ]]; then
  cmd+=(--fail-on-untested)
fi
if [[ $ALLOW_EMPTY == true ]]; then
  cmd+=(--allow-empty)
fi
for t in "${test_paths[@]+"${test_paths[@]}"}"; do
  cmd+=("$t")
done

set +e
output=$("${cmd[@]}" 2>&1)
status=$?
set -e

printf '%s\n' "$output"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### ActivityPolicy Tests"
    echo ""
    echo '```text'
    printf '%s\n' "$output"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ $status -ne 0 ]]; then
  echo "::error title=Activity policy tests::activitytool failed with exit code $status"
  exit "$status"
fi
