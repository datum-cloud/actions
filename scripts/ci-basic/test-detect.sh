#!/usr/bin/env bash
# Checks detect.sh's package manager rules without a runner.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(mktemp -d "${TMPDIR:-/tmp}/ci-basic-detect.XXXXXX")
trap 'rm -rf "$root"' EXIT
failed=0

run_detect() {
  local dir=$1 status=0
  CI_PATH=$dir GITHUB_OUTPUT=$dir/.out bash "$script_dir/detect.sh" > /dev/null 2>&1 || status=$?
  echo "$status"
}

mkdir -p "$root/unpinned"
printf '{"name":"x","private":true}\n' > "$root/unpinned/package.json"
printf "lockfileVersion: '9.0'\n" > "$root/unpinned/pnpm-lock.yaml"
status=$(run_detect "$root/unpinned")
if [[ $status -ne 2 ]]; then
  echo "FAIL unpinned pnpm project: exit $status, want 2"; failed=1
elif ! grep -qF 'no packageManager' <<< "$(CI_PATH=$root/unpinned GITHUB_OUTPUT=/dev/null bash "$script_dir/detect.sh" 2>&1 || true)"; then
  echo "FAIL unpinned pnpm project: error does not name packageManager"; failed=1
fi

mkdir -p "$root/pinned"
printf '{"name":"x","private":true,"packageManager":"pnpm@12.23.0"}\n' > "$root/pinned/package.json"
printf "lockfileVersion: '9.0'\n" > "$root/pinned/pnpm-lock.yaml"
status=$(run_detect "$root/pinned")
if [[ $status -ne 0 ]]; then
  echo "FAIL pinned pnpm project: exit $status, want 0"; failed=1
elif ! grep -qx 'node-pm=pnpm' "$root/pinned/.out"; then
  echo "FAIL pinned pnpm project: node-pm is not pnpm"; failed=1
fi

mkdir -p "$root/npm"
printf '{"name":"x","private":true}\n' > "$root/npm/package.json"
printf '{}\n' > "$root/npm/package-lock.json"
status=$(run_detect "$root/npm")
[[ $status -eq 0 ]] || { echo "FAIL npm project without packageManager: exit $status, want 0"; failed=1; }

[[ $failed -eq 0 ]] && echo "detect tests passed"
exit "$failed"
