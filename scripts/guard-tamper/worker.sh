#!/usr/bin/env bash
set -euo pipefail

shard=$1
work=$2
results=$3
read -r -a flags <<< "${GT_GO_TEST_FLAGS:-}"
saved=$(mktemp "${TMPDIR:-/tmp}/guard-tamper-saved.XXXXXX")
log=$(mktemp "${TMPDIR:-/tmp}/guard-tamper-log.XXXXXX")
target=""
restore() {
  if [[ -n $target ]]; then cp "$saved" "$target"; fi
  rm -f "$saved" "$log"
}
trap restore EXIT

cd "$work"
: > "$results"
while IFS=$'\t' read -r id file pkg _ _; do
  target=$work/$file
  cp "$target" "$saved"
  cp "$GT_MUTANTS/$id.go" "$target"
  if ! go test -count=1 -run '^$' "${flags[@]}" "$pkg" > "$log" 2>&1; then
    verdict=uncompiled
  elif go test -count=1 -timeout "${GT_TEST_TIMEOUT:-300}s" "${flags[@]}" "$pkg" > "$log" 2>&1; then
    verdict=survived
  else
    verdict=killed
  fi
  cp "$saved" "$target"
  target=""
  printf '%s\t%s\n' "$id" "$verdict" >> "$results"
  printf '%s %s %s\n' "$id" "$verdict" "$file"
done < "$shard"
