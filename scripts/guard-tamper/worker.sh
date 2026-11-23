#!/usr/bin/env bash
set -euo pipefail

shard=$1
work=$2
results=$3
read -r -a flags <<< "${GT_GO_TEST_FLAGS:-}"
test_timeout=${GT_TEST_TIMEOUT:-300}
deadline=${GT_DEADLINE:-}
rerun_under=${GT_RERUN_UNDER_SECONDS:-60}
saved=$(mktemp "${TMPDIR:-/tmp}/guard-tamper-saved.XXXXXX")
log=$(mktemp "${TMPDIR:-/tmp}/guard-tamper-log.XXXXXX")
target=""
restore() {
  if [[ -n $target ]]; then cp "$saved" "$target"; fi
  rm -f "$saved" "$log"
}
trap restore EXIT

remaining() {
  if [[ -z $deadline ]]; then echo "$test_timeout"; return; fi
  local left=$(( deadline - $(date +%s) ))
  if (( left > test_timeout )); then left=$test_timeout; fi
  echo "$left"
}

run_tests() {
  local limit=$1
  if go test -count=1 -timeout "${limit}s" "${flags[@]}" "$pkg" > "$log" 2>&1; then
    echo pass
  elif grep -q -E '^panic: test timed out after' "$log"; then
    echo timeout
  elif grep -q -E '\[(build|setup) failed\]' "$log"; then
    echo uncompiled
  else
    echo fail
  fi
}

cd "$work"
: > "$results"
while IFS=$'\t' read -r id file pkg _ _; do
  limit=$(remaining)
  if [[ -n $deadline ]] && (( limit < 5 )); then
    printf '%s\t%s\n' "$id" unrun >> "$results"
    continue
  fi
  target=$work/$file
  cp "$target" "$saved"
  cp "$GT_MUTANTS/$id.go" "$target"
  if ! go test -count=1 -run '^$' "${flags[@]}" "$pkg" > "$log" 2>&1; then
    verdict=uncompiled
  else
    started=$(date +%s)
    case $(run_tests "$limit") in
      pass) verdict=survived ;;
      timeout) verdict=timeout ;;
      uncompiled) verdict=uncompiled ;;
      fail)
        verdict=killed
        took=$(( $(date +%s) - started ))
        limit=$(remaining)
        if (( took < rerun_under && limit >= took + 5 )) && [[ $(run_tests "$limit") == pass ]]; then
          verdict=flaky
        fi
        ;;
    esac
  fi
  cp "$saved" "$target"
  target=""
  printf '%s\t%s\n' "$id" "$verdict" >> "$results"
  printf '%s %s %s\n' "$id" "$verdict" "$file"
done < "$shard"
