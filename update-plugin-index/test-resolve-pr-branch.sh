#!/usr/bin/env bash
# Exercise the action's branch resolver against a read-only GitHub API mock.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/plugin-pr-tests.XXXXXX")
cleanup() {
  local directory fixture
  for directory in "$test_root"/case-*; do
    [[ -d $directory ]] || continue
    for fixture in "$directory"/pulls.json "$directory"/files-*.json \
      "$directory"/output "$directory"/stdout "$directory"/stderr "$directory"/fail-*; do
      [[ ! -f $fixture ]] || unlink "$fixture"
    done
    rmdir "$directory"
  done
  [[ ! -f $test_root/bin/gh ]] || unlink "$test_root/bin/gh"
  rmdir "$test_root/bin" "$test_root"
}
trap cleanup EXIT
mkdir "$test_root/bin"

cat > "$test_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == api ]] || exit 2
shift
method= endpoint= state= paginate=false slurp=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method) method=$2; shift 2 ;;
    --paginate) paginate=true; shift ;;
    --slurp) slurp=true; shift ;;
    -f|-F|--field|--raw-field)
      [[ $2 != base=* ]] || exit 2
      [[ $2 != state=* ]] || state=${2#state=}
      shift 2
      ;;
    repos/*/pulls) endpoint=pulls; shift ;;
    repos/*/pulls/*/files)
      path=${1%/files}
      endpoint=files-${path##*/}
      shift
      ;;
    *) printf 'Unexpected gh argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ $method == GET && $paginate == true && $slurp == true ]] || exit 2
[[ $endpoint != pulls || $state == open ]] || exit 2
if [[ -f $GH_FIXTURES/fail-$endpoint ]]; then
  printf 'Simulated GitHub API failure\n' >&2
  exit 42
fi
response=$GH_FIXTURES/$endpoint.json
if [[ $endpoint == files-* && ! -f $response ]]; then
  response=$GH_FIXTURES/files-default.json
fi
cat "$response"
MOCK
chmod +x "$test_root/bin/gh"
export PATH="$test_root/bin:$PATH"
export INDEX_REPO=datum-cloud/datumctl-plugins PLUGIN_NAME=dns

case_count=0
begin_case() {
  case_name=$1
  case_count=$((case_count + 1))
  export GH_FIXTURES="$test_root/case-$case_count"
  export PLUGIN_FILE=plugins/dns.yaml BASE_BRANCH=main
  export GITHUB_OUTPUT="$GH_FIXTURES/output"
  mkdir "$GH_FIXTURES"
  printf 'existing=value\n' > "$GITHUB_OUTPUT"
  printf '[[]]\n' > "$GH_FIXTURES/pulls.json"
  printf '[[{"filename":"plugins/dns.yaml"}]]\n' > "$GH_FIXTURES/files-default.json"
}

pull() {
  jq -cn --argjson number "$1" --arg branch "$2" --arg base "${3-main}" \
    --arg repo "${4-$INDEX_REPO}" --arg state "${5-open}" '
    {number: $number, state: $state, base: {ref: $base}, head: {
      ref: $branch, repo: (if $repo == "" then null else {full_name: $repo} end)
    }}'
}

pulls() {
  printf '%s\n' "$@" | jq -sc '[.]' > "$GH_FIXTURES/pulls.json"
}

files() {
  number=$1
  shift
  jq -cn --args '$ARGS.positional | map({filename: .}) | [.]' "$@" \
    > "$GH_FIXTURES/files-$number.json"
}

fail_case() {
  printf 'FAIL: %s: %s\n' "$case_name" "$1" >&2
  cat "$GH_FIXTURES/stderr" >&2
  exit 1
}

expect_branch() {
  bash "$script_dir/resolve-pr-branch.sh" > "$GH_FIXTURES/stdout" \
    2> "$GH_FIXTURES/stderr" || fail_case 'resolver failed'
  expected=$(printf 'existing=value\nbranch=%s\n' "$1")
  [[ $(cat "$GITHUB_OUTPUT") == "$expected" ]] || fail_case 'unexpected branch output'
  printf 'PASS: %s\n' "$case_name"
}

expect_failure() {
  if bash "$script_dir/resolve-pr-branch.sh" > "$GH_FIXTURES/stdout" \
    2> "$GH_FIXTURES/stderr"; then
    fail_case 'resolver should have failed'
  fi
  [[ $(cat "$GITHUB_OUTPUT") == existing=value ]] || fail_case 'published output after failure'
  printf 'PASS: %s\n' "$case_name"
}

begin_case 'first release uses a stable branch'
expect_branch update-plugin/dns

begin_case 'later release reuses an open legacy PR'
pulls "$(pull 10 update-plugin/dns-v0.1.0)"
expect_branch update-plugin/dns-v0.1.0

begin_case 'stable branch wins over older legacy PRs'
pulls "$(pull 10 update-plugin/dns-v0.1.0)" "$(pull 20 update-plugin/dns)"
expect_branch update-plugin/dns

begin_case 'oldest legacy PR wins regardless of API order'
pulls "$(pull 30 update-plugin/dns-v0.3.0)" "$(pull 10 update-plugin/dns-v0.1.0)"
expect_branch update-plugin/dns-v0.1.0

begin_case 'similarly named plugin is not overwritten'
pulls "$(pull 10 update-plugin/dns-extra-v0.1.0)"
files 10 plugins/dns-extra.yaml
expect_branch update-plugin/dns

begin_case 'unrelated branch editing the manifest is not overwritten'
pulls "$(pull 10 fix-dns-platforms)"
expect_branch update-plugin/dns

begin_case 'legacy PR with unrelated changes is not overwritten'
pulls "$(pull 10 update-plugin/dns-v0.1.0)"
files 10 plugins/dns.yaml README.md
expect_branch update-plugin/dns

begin_case 'custom manifest path identifies the correct PR'
PLUGIN_FILE=catalog/network/dns.yaml
pulls "$(pull 10 update-plugin/dns-v0.1.0)" "$(pull 20 update-plugin/dns-v0.2.0)"
files 20 "$PLUGIN_FILE"
expect_branch update-plugin/dns-v0.2.0

begin_case 'relative manifest path matches GitHub file paths'
PLUGIN_FILE=./plugins/dns.yaml
pulls "$(pull 10 update-plugin/dns-v0.1.0)"
expect_branch update-plugin/dns-v0.1.0

begin_case 'fork, deleted head, wrong base, and closed legacy PRs are ignored'
pulls "$(pull 10 update-plugin/dns-v0.1.0 main someone/catalog)" \
  "$(pull 20 update-plugin/dns-v0.2.0 main '')" \
  "$(pull 30 update-plugin/dns-v0.3.0 release)" \
  "$(pull 40 update-plugin/dns-v0.4.0 main "$INDEX_REPO" closed)"
expect_branch update-plugin/dns

begin_case 'head repository comparison is case insensitive'
pulls "$(pull 10 update-plugin/dns-v0.1.0 main DATUM-CLOUD/DATUMCTL-PLUGINS)"
expect_branch update-plugin/dns-v0.1.0

begin_case 'requested base branch is respected'
BASE_BRANCH=release
pulls "$(pull 10 update-plugin/dns-v0.1.0)" "$(pull 20 update-plugin/dns-v0.2.0 release)"
expect_branch update-plugin/dns-v0.2.0

begin_case 'closed and fork PRs do not reserve the stable catalog branch'
pulls "$(pull 10 update-plugin/dns main "$INDEX_REPO" closed)" \
  "$(pull 20 update-plugin/dns main someone/catalog)"
expect_branch update-plugin/dns

begin_case 'stable branch targeting another base is protected'
pulls "$(pull 10 update-plugin/dns release)"
expect_failure

begin_case 'stable branch shared across bases is protected'
pulls "$(pull 10 update-plugin/dns)" "$(pull 20 update-plugin/dns release)"
expect_failure

begin_case 'legacy branch shared across bases is not overwritten'
pulls "$(pull 10 update-plugin/dns-v0.1.0)" "$(pull 20 update-plugin/dns-v0.1.0 release)"
expect_branch update-plugin/dns

for branch in update-plugin/dns update-plugin/dns-v0.1.0; do
  begin_case "shared $branch allows reuse of a dedicated PR"
  pulls "$(pull 10 "$branch")" "$(pull 20 "$branch" release)" \
    "$(pull 30 update-plugin/dns-v0.2.0)"
  expect_branch update-plugin/dns-v0.2.0
done

for paths in 'plugins/compute.yaml' 'plugins/dns.yaml README.md' ''; do
  begin_case "stable branch with unrelated files [$paths] is protected"
  pulls "$(pull 10 update-plugin/dns)"
  # The fixture intentionally separates the two literal test filenames.
  # shellcheck disable=SC2086
  files 10 $paths
  expect_failure
done

begin_case 'matching PR on a later API page is reused'
printf '%s\n' "$(pull 1 unrelated)" "$(pull 20 update-plugin/dns-v0.1.0)" \
  | jq -sc 'map([.])' > "$GH_FIXTURES/pulls.json"
expect_branch update-plugin/dns-v0.1.0

begin_case 'unrelated files on later pages prevent overwriting a PR'
pulls "$(pull 10 update-plugin/dns)"
printf '[[{"filename":"plugins/dns.yaml"}],[{"filename":"README.md"}]]\n' \
  > "$GH_FIXTURES/files-10.json"
expect_failure

begin_case 'PR lookup failure publishes no branch output'
touch "$GH_FIXTURES/fail-pulls"
expect_failure

begin_case 'file lookup failure publishes no branch output'
pulls "$(pull 10 update-plugin/dns-v0.1.0)"
touch "$GH_FIXTURES/fail-files-10"
expect_failure

printf '\nAll %s regression cases passed.\n' "$case_count"
