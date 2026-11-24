#!/usr/bin/env bash
# Runs check.sh against every case in testdata/. A case's name sets the exit
# code it must give (pass-* 0, fail-* 1, error-* 2); `expect` lists lines the
# output must contain, `absent` lines it must not, and `env` variables to set.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/pnpm-policy-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

passed=0
failed=0

for src in "$script_dir"/testdata/*/; do
  src=${src%/}
  name=${src##*/}
  case $name in
    pass-*) want=0 ;;
    fail-*) want=1 ;;
    error-*) want=2 ;;
    *) echo "unknown case prefix: $name" >&2; exit 2 ;;
  esac
  dir=$test_root/$name
  mkdir -p "$dir"
  cp -R "$src/." "$dir/"
  rm -f "$dir/expect" "$dir/absent" "$dir/env"
  while IFS= read -r -d '' file; do
    mv "$file" "${file%.fixture}"
  done < <(find "$dir" -name '*.fixture' -print0)

  status=0
  out=$(
    unset PNPM_MAJOR REQUIRE_PNPM REQUIRE_LOCKFILE YQ
    if [[ -f $src/env ]]; then
      while IFS= read -r line; do
        [[ -z $line ]] || export "${line%%=*}=${line#*=}"
      done < "$src/env"
    fi
    SCAN_PATH=$dir bash "$script_dir/check.sh" 2>&1
  ) || status=$?

  problems=""
  [[ $status -eq $want ]] || problems="$problems exit $status, want $want;"
  if [[ -f $src/expect ]]; then
    while IFS= read -r line; do
      [[ -z $line ]] || grep -qF -- "$line" <<< "$out" || problems="$problems missing '$line';"
    done < "$src/expect"
  fi
  if [[ -f $src/absent ]]; then
    while IFS= read -r line; do
      [[ -z $line ]] || ! grep -qF -- "$line" <<< "$out" || problems="$problems unexpected '$line';"
    done < "$src/absent"
  fi

  if [[ -z $problems ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL $name:$problems"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
done

echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
