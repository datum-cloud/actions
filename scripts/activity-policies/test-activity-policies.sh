#!/usr/bin/env bash
# Exercise the activity-policies scripts against testdata/ fixtures, then
# weaken each guarded behavior in a copy of the scripts and check that some
# case notices (tamper tests, as in lockfile-check). Also checks that
# the installer pin and the README's Taskfile snippet pin agree.
#
# The fixture cases run the pinned ghcr.io/milo-os/activitytool image, which
# install-activitytool.sh pulls, so docker is required. The installer's own
# cases and the Docker wrapper cases use a stand-in docker command instead.
# SKIP_TAMPER=true skips the tamper tests.
#
# SC2016: tamper targets are literal script text, so they are single-quoted.
# SC2030/SC2031: each case sets its environment inside a subshell on purpose,
# so nothing leaks between cases.
# shellcheck disable=SC2016,SC2030,SC2031
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/activity-policies-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
test_root=$(cd "$test_root" && pwd -P)
export GIT_CEILING_DIRECTORIES=$test_root
# Keep the cases from writing into the real job's PATH, env, and summary.
unset GITHUB_WORKSPACE GITHUB_PATH GITHUB_ENV GITHUB_STEP_SUMMARY

unset ACTIVITYTOOL ACTIVITYTOOL_VERSION ACTIVITYTOOL_IMAGE CACHE_DIR BIN_DIR
# The pinned image, installed once and used by every fixture case.
BIN_DIR=$test_root/pinned-bin bash "$script_dir/install-activitytool.sh" > /dev/null
tool_bin=$test_root/pinned-bin/activitytool

# A stand-in for docker, so the installer and the Docker wrapper can be
# tested without a registry, a published image, or network access.
stub_dir=$test_root/stubs
mkdir -p "$stub_dir"
stub_digest=sha256:$(printf '%064d' 0 | tr 0 a)
cat > "$stub_dir/docker" << 'EOF'
#!/usr/bin/env bash
case $1 in
  pull)
    if [[ -n ${STUB_PULL_ERROR:-} ]]; then
      echo "$STUB_PULL_ERROR" >&2
      exit 1
    fi
    echo "${!#}"
    ;;
  image) printf '%s\n' "ghcr.io/milo-os/activitytool@$STUB_DIGEST" ;;
  run) echo "stub-docker $*" ;;
  *)
    echo "stub-docker: unexpected command: $*" >&2
    exit 64
    ;;
esac
EOF
chmod 0755 "$stub_dir/docker"

passed=0
failed=0
mode=loud
scripts=$script_dir
run_id=main
suite_before=0
output=
status=0
case_env=()
case_into=
case_git=false

reset_case() {
  case_env=()
  case_into=
  case_git=false
}

# judge NAME WANT_STATUS [NEEDLE...]: NEEDLE must appear in the output, or
# must not when it starts with "!".
judge() {
  local name=$1 want=$2 needle problems=""
  shift 2
  [[ $status -eq $want ]] || problems="$problems exit $status, want $want;"
  for needle in "$@"; do
    if [[ $needle == '!'* ]]; then
      ! grep -qF -- "${needle#!}" <<< "$output" || problems="$problems unexpected '${needle#!}';"
    else
      grep -qF -- "$needle" <<< "$output" || problems="$problems missing '$needle';"
    fi
  done
  if [[ -n $problems ]]; then
    failed=$((failed + 1))
    if [[ $mode == loud ]]; then
      echo "FAIL $name:$problems"
      printf '%s\n' "$output" | sed 's/^/     | /'
    fi
  else
    passed=$((passed + 1))
    if [[ $mode == loud ]]; then
      echo "ok   $name"
    fi
  fi
}

# Run a case unless a quiet (tamper) run already saw a failure.
c() {
  [[ $mode == loud || $failed -eq $suite_before ]] || return 0
  "$@"
}

new_case_dir() {
  local dir=$test_root/case-$run_id-$1
  rm -rf "$dir"
  mkdir -p "$dir/$case_into"
  if [[ -n $2 ]]; then
    cp -R "$script_dir/testdata/$2/." "$dir/$case_into/"
  fi
  if [[ $case_git == true ]]; then
    git -C "$dir" init -q
  fi
  printf '%s\n' "$dir"
}

# check_case NAME FIXTURE WANT SCAN_SUBDIR [NEEDLE...]: run check.sh with
# case_env, using the pinned activitytool image.
check_case() {
  local name=$1 fixture=$2 want=$3 scan=$4 dir
  shift 4
  dir=$(new_case_dir "$name" "$fixture")
  status=0
  output=$( (
    export SCAN_PATH=$dir/$scan ACTIVITYTOOL=$tool_bin
    for assignment in "${case_env[@]+"${case_env[@]}"}"; do export "${assignment?}"; done
    bash "$scripts/check.sh"
  ) 2>&1) || status=$?
  judge "$name" "$want" "$@"
}

# install_case NAME WANT [NEEDLE...]: run install-activitytool.sh with the
# docker stand-in first on PATH.
install_case() {
  local name=$1 want=$2 bin=$test_root/install-$run_id-$1
  shift 2
  rm -rf "$bin"
  status=0
  output=$( (
    export PATH=$stub_dir:$PATH BIN_DIR=$bin STUB_DIGEST=$stub_digest
    for assignment in "${case_env[@]+"${case_env[@]}"}"; do export "${assignment//@BIN@/$bin}"; done
    bash "$scripts/install-activitytool.sh" &&
      { [[ -z ${CACHE_DIR:-} ]] || bash "$scripts/install-activitytool.sh"; }
  ) 2>&1) || status=$?
  judge "$name" "$want" "$@"
}

# wrapper_case NAME CWD_SUBDIR WANT [NEEDLE...]: run docker-run.sh from a
# subdirectory of the nested-path fixture against the docker stand-in. @DIR@
# in case_env and needles is the fixture's directory.
wrapper_case() {
  local name=$1 cwd=$2 want=$3 dir needle needles=()
  shift 3
  dir=$(new_case_dir "$name" nested-path)
  for needle in "$@"; do needles+=("${needle//@DIR@/$dir}"); done
  status=0
  output=$( (
    cd "$dir/$cwd" || exit 99
    export PATH=$stub_dir:$PATH ACTIVITYTOOL_DOCKER_IMAGE=example.com/activitytool@$stub_digest
    for assignment in "${case_env[@]+"${case_env[@]}"}"; do export "${assignment//@DIR@/$dir}"; done
    bash "$scripts/docker-run.sh" test --policies x
  ) 2>&1) || status=$?
  judge "$name" "$want" "${needles[@]}"
}

# runsh_case NAME FIXTURE WANT [NEEDLE...]: run the workstation runner with
# the pinned image.
runsh_case() {
  local name=$1 fixture=$2 want=$3 dir
  shift 3
  dir=$(new_case_dir "$name" "$fixture")
  status=0
  output=$( (
    export SCAN_PATH=$dir XDG_CACHE_HOME=$test_root/cache-$run_id
    for assignment in "${case_env[@]+"${case_env[@]}"}"; do export "${assignment?}"; done
    bash "$scripts/run.sh"
  ) 2>&1) || status=$?
  judge "$name" "$want" "$@"
}

suite() {
  scripts=$1 mode=$2 run_id=$3
  suite_before=$failed

  # check.sh with the pinned image
  reset_case; case_env=(FAIL_ON_UNTESTED=true)
  c check_case passing-auto passing-tests 0 "" "4/4 tests passed, 2 policies validated (0 untested)"
  reset_case; case_env=(POLICIES_PATH=.)
  c check_case valid-kustomization valid-kustomization 0 "" "0/0 tests passed, 1 policies validated (1 untested)"
  reset_case; case_env=(POLICIES_PATH=. FAIL_ON_UNTESTED=true)
  c check_case valid-kustomization-strict valid-kustomization 1 "" "iam.miloapis.com-group"
  reset_case; case_env=(POLICIES_PATH=.)
  c check_case invalid-policy invalid-policy 1 "" "invalid-group-policy" "undeclared reference" "duplicate rule name" "missing closing delimiter"
  reset_case; case_env=(POLICIES_PATH=group-policy.yaml TESTS_PATH=group.test.yaml)
  c check_case failing-summary failing-summary 1 "" \
    'exp: "alice@example.com provisioned team platform-admins"' \
    'got: "alice@example.com created group platform-admins"'
  reset_case
  c check_case empty-fail "" 2 "" "no ActivityPolicy manifests or test files found"
  reset_case; case_env=(ALLOW_EMPTY=true)
  c check_case empty-allow "" 0 ""
  # Discovery prefers Kustomize directories and never passes patch files.
  reset_case
  c check_case kustomize-patches kustomize-patches 0 "" \
    "Skipping overlays/prod/group-patch.yaml: a kustomization uses it as a patch" \
    "Skipping overlays/prod/legacy-patch.yaml: a kustomization uses it as a patch" \
    "policies:     base standalone/project-policy.yaml" \
    "2 policies validated"
  # Lists split on commas and newlines only, so spaces stay in paths.
  reset_case; case_into="my policies"; case_env=("POLICIES_PATH= my policies , ")
  c check_case spaced-path valid-kustomization 0 "" "1 policies validated"
  reset_case; case_env=("POLICIES_PATH=../outside")
  c check_case escape-path valid-kustomization 2 "" "must not escape"
  # A path below the repository root whose tests reference ../../ policies;
  # the image sees them because the repository root is mounted.
  reset_case; case_git=true
  c check_case nested-path nested-path 0 services/foo "1/1 tests passed"
  # Several policy sources at once: a plain folder and a kustomization.
  reset_case; case_env=($'POLICIES_PATH=plain-policies\nkustomized-policies' TESTS_PATH=tests FAIL_ON_UNTESTED=true)
  c check_case multi-path multi-path 0 "" "2/2 tests passed, 2 policies validated (0 untested)"
  reset_case; case_env=("POLICIES_PATH=plain-policies, kustomized-policies" TESTS_PATH=tests FAIL_ON_UNTESTED=true)
  c check_case multi-path-comma multi-path 0 "" "2/2 tests passed, 2 policies validated (0 untested)"

  # install-activitytool.sh
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0/../../etc")
  c install_case install-version-slash 2 "is not a valid image tag" "!stub-docker"
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0 latest")
  c install_case install-version-space 2 "is not a valid image tag" "!stub-docker"
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0@sha256:abc")
  c install_case install-version-digest 2 "is not a valid image tag" "!stub-docker"
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0" "STUB_PULL_ERROR=Error response from daemon: denied: requested access to the resource is denied")
  c install_case install-pull-fails 2 "denied: requested access to the resource is denied" \
    "docker pull ghcr.io/milo-os/activitytool:v1.0.0 failed" "!Installed activitytool" "!go install"
  # A tag-only pin installs, locked to the digest it resolved to, with a
  # warning recommending a digest pin.
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0")
  c install_case install-ok 0 \
    "is a tag without a digest" "Pin it as v1.0.0@sha256:<digest>" \
    "Installed activitytool: stub-docker run --rm --pull never --network none" \
    "ghcr.io/milo-os/activitytool@$stub_digest --version"
  local pinned_digest
  pinned_digest=sha256:$(printf '%064d' 0 | tr 0 b)
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0@$pinned_digest")
  c install_case install-digest-pin 0 "!tag without a digest" \
    "ghcr.io/milo-os/activitytool@$pinned_digest --version" "!activitytool@$stub_digest"
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0" "CACHE_DIR=@BIN@/cache")
  c install_case install-cache 0 "Using cached activitytool v1.0.0 (ghcr.io/milo-os/activitytool@$stub_digest)"

  # docker-run.sh mounts the repository root and works from the subdirectory.
  reset_case; case_git=true
  c wrapper_case wrapper-git-root services/foo 0 \
    "--volume @DIR@:/work:ro --workdir /work/services/foo" \
    "--network none" "--user 65532:65532" "--read-only" "--cap-drop ALL" "--pull never" \
    "example.com/activitytool@$stub_digest test --policies x"
  reset_case; case_env=("GITHUB_WORKSPACE=@DIR@")
  c wrapper_case wrapper-workspace-root services/foo 0 "--volume @DIR@:/work:ro --workdir /work/services/foo"
  reset_case; case_env=("GITHUB_WORKSPACE=@DIR@/base")
  c wrapper_case wrapper-cwd-fallback services/foo 0 "--volume @DIR@/services/foo:/work:ro --workdir /work "

  # run.sh, the workstation runner
  reset_case; case_env=(FAIL_ON_UNTESTED=true)
  c runsh_case run.sh passing-tests 0 "SUCCESS: 4/4 tests passed"
  reset_case; case_env=(POLICIES_PATH=group-policy.yaml TESTS_PATH=group.test.yaml)
  c runsh_case run.sh-failing failing-summary 1 'got: "alice@example.com created group platform-admins"'
  # An install failure stops run.sh before check.sh runs.
  reset_case; case_env=("ACTIVITYTOOL_VERSION=v1.0.0 latest")
  c runsh_case run.sh-install-fails passing-tests 2 "is not a valid image tag" "!not found on PATH"
}

suite "$script_dir" loud main

# The installer pin and the README's Taskfile snippet pin agree (Renovate
# bumps both).
readme=$repo_root/docs/activity-policies/README.md
pin_install=$(sed -n 's/^PINNED_VERSION=//p' "$script_dir/install-activitytool.sh")
pin_readme=$(sed -n 's/^  ACTIVITYTOOL_VERSION: //p' "$readme")
if [[ -n $pin_install && $pin_install == "$pin_readme" ]]; then
  echo "ok   pins-agree: $pin_install"
  passed=$((passed + 1))
else
  echo "FAIL pins-agree: install-activitytool.sh has '$pin_install', docs/activity-policies/README.md has '$pin_readme'"
  failed=$((failed + 1))
fi

# The README offers no unsupported install routes or nonexistent versions.
output=$(cat "$readme")
status=0
judge readme-no-unsupported-routes 0 "!go install go.miloapis.com" "!v0.0.0-main" "!v0.9.3" "!@main"

echo "fixtures: $passed passed, $failed failed"

if [[ ${SKIP_TAMPER:-false} == true ]]; then
  [[ $failed -eq 0 ]]
  exit
fi

tampered=0
tamper() {
  local file=$1 old=$2 new=$3 copy content before_failed before_passed
  copy=$test_root/tamper-$tampered
  rm -rf "$copy"
  mkdir -p "$copy"
  cp "$script_dir"/*.sh "$copy/"
  content=$(cat "$copy/$file")
  if [[ $content != *"$old"* ]]; then
    echo "tamper target not found in $file: $old"
    failed=$((failed + 1))
    return
  fi
  printf '%s\n' "${content%%"$old"*}$new${content#*"$old"}" > "$copy/$file"
  before_failed=$failed
  before_passed=$passed
  suite "$copy" quiet "t$tampered"
  if [[ $failed -eq $before_failed ]]; then
    echo "TAMPER SURVIVED: $file: $old"
    failed=$((before_failed + 1))
  else
    echo "tamper caught: $file: $old"
    failed=$before_failed
  fi
  passed=$before_passed
  tampered=$((tampered + 1))
}

tamper check.sh 'if in_list "$rel" "$patch_files"; then' 'if false; then'
tamper check.sh 'if in_list "$dir" "$kustomize_dirs"; then' 'if false; then'
tamper check.sh "tr ',' '\\n'" "tr ', \\t' '\\n'"
tamper install-activitytool.sh "tag_re='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\$'" "tag_re='.*'"
tamper install-activitytool.sh "digest_re='^sha256:[0-9a-f]{64}\$'" "digest_re='^sha256:'"
tamper install-activitytool.sh 'if ! docker pull --quiet "$ref"; then' 'if ! { docker pull --quiet "$ref" || true; }; then'
tamper install-activitytool.sh 'if [[ -z $version_digest ]]; then' 'if false; then'
tamper install-activitytool.sh 'pinned_ref=$ACTIVITYTOOL_IMAGE@$digest' 'pinned_ref=$ref'
tamper install-activitytool.sh 'if [[ -n $version_digest ]]; then' 'if false; then'
tamper docker-run.sh '--workdir "/work${cwd#"$root"}"' '--workdir /work'
tamper docker-run.sh '--pull never --network none' '--pull never'
tamper docker-run.sh '--user 65532:65532 ' ''
tamper docker-run.sh 'candidates+=("$top")' ':'
tamper docker-run.sh 'candidates+=("$GITHUB_WORKSPACE")' ':'
tamper run.sh 'status=${PIPESTATUS[0]}
set -e
exit "$status"' 'exit 0'
tamper run.sh 'status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || exit "$status"' 'set -e'

echo "tamper: $tampered rules weakened, $failed failed"
echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
