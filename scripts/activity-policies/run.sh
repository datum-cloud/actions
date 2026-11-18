#!/usr/bin/env bash
# Run ActivityPolicy validation and unit tests on a workstation the same way
# CI runs them: set up the pinned activitytool image, then run check.sh.
#
# set -e is on; it is turned off only around the two pipelines below, whose
# first command's status is read from PIPESTATUS.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run.sh [--help]

Validate ActivityPolicy manifests and run unit tests with the same scripts
and pinned activitytool version as the test-activity-policies workflow.

Settings are environment variables named after the workflow inputs:

  SCAN_PATH            Repository directory to check. Default: current directory.
  POLICIES_PATH        Comma- or newline-separated policy files, directories,
                       or Kustomize directories relative to SCAN_PATH.
  TESTS_PATH           Comma- or newline-separated test files or directories
                       relative to SCAN_PATH.
  FAIL_ON_UNTESTED     true to fail when any policy has no tests. Default: false.
  ALLOW_EMPTY          true to pass when nothing is found. Default: false.
  ACTIVITYTOOL_VERSION ghcr.io/milo-os/activitytool tag, optionally pinned as
                       vX.Y.Z@sha256:<digest>. Use the milo-os/activity release
                       deployed where the policies run. Default: the pin in
                       install-activitytool.sh.
  ACTIVITYTOOL_IMAGE   Image repository. Default: ghcr.io/milo-os/activitytool.

Requires docker. The generated wrapper is cached under
${XDG_CACHE_HOME:-$HOME/.cache}/datum-activity-policies/bin.
USAGE
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    echo "run.sh: unknown argument '$1'; see --help" >&2
    exit 2
    ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/datum-activity-policies

RUNNER_TEMP=
trap '[[ -z $RUNNER_TEMP ]] || rm -rf "$RUNNER_TEMP"' EXIT
RUNNER_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/activity-policies.XXXXXX") || exit 2
export RUNNER_TEMP
export SCAN_PATH=${SCAN_PATH:-.}
export GITHUB_PATH=$RUNNER_TEMP/path
unset GITHUB_STEP_SUMMARY
: > "$GITHUB_PATH"

to_terminal() {
  awk '
    /^::(error|warning|notice)/ {
      kind = substr($0, 3, index(substr($0, 3), " ") - 1)
      sub(/^::[a-z]+ title=/, "")
      title = substr($0, 1, index($0, "::") - 1)
      print kind ": " title ": " substr($0, index($0, "::") + 2)
      next
    }
    { print }
  '
}

set +e
CACHE_DIR=$cache_dir/bin bash "$script_dir/install-activitytool.sh" 2>&1 | to_terminal
status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || exit "$status"

while IFS= read -r dir; do
  [[ -n $dir ]] || continue
  PATH=$dir:$PATH
done < "$GITHUB_PATH"
export PATH

set +e
bash "$script_dir/check.sh" 2>&1 | to_terminal
status=${PIPESTATUS[0]}
set -e
exit "$status"
