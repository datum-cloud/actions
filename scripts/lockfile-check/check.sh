#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWK=${AWK:-awk}
SCAN_PATH=${SCAN_PATH:-.}
EXCLUDE_PATHS=${EXCLUDE_PATHS:-}
ALLOWED_REGISTRIES=${ALLOWED_REGISTRIES:-}
REQUIRE_LOCKFILE=${REQUIRE_LOCKFILE:-false}

default_registries=(https://registry.npmjs.org/ https://registry.yarnpkg.com/)

split_list() {
  printf '%s\n' "$1" | tr -s ',[:space:]' '\n' | sed '/^$/d'
}

fail_config() {
  echo "::error title=Lockfile check::$1"
  exit 2
}

[[ -d $SCAN_PATH ]] || fail_config "path '$SCAN_PATH' is not a directory"
command -v "$AWK" > /dev/null || fail_config "awk command '$AWK' not found"

registries=("${default_registries[@]}")
while IFS= read -r entry; do
  [[ $entry == https://* && $entry != *[[:space:]]* && $entry != https:///* ]] \
    || fail_config "allowed-registries entry '$entry' must be an https:// URL"
  [[ $entry == */ ]] || entry=$entry/
  registries+=("$entry")
done < <(split_list "$ALLOWED_REGISTRIES")
registry_list=${registries[*]}

excludes=()
while IFS= read -r pattern; do
  excludes+=("${pattern%/}")
done < <(split_list "$EXCLUDE_PATHS")

is_excluded() {
  local pattern
  for pattern in ${excludes[@]+"${excludes[@]}"}; do
    case $1 in $pattern | $pattern/*) return 0 ;; esac
  done
  return 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/lockfile-check.XXXXXX")
trap 'rm -rf "$work"' EXIT

if git -C "$SCAN_PATH" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  git -C "$SCAN_PATH" ls-files --cached --others --exclude-standard -z > "$work/files" \
    || fail_config "git could not list files under '$SCAN_PATH'"
else
  (cd "$SCAN_PATH" && find . -name node_modules -prune -o -type f -print0) > "$work/files" \
    || fail_config "find could not list files under '$SCAN_PATH'"
fi

lockfiles=()
while IFS= read -r -d '' file; do
  file=${file#./}
  case ${file##*/} in
    package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | yarn.lock | bun.lock | bun.lockb) ;;
    *) continue ;;
  esac
  case /$file/ in */node_modules/*) continue ;; esac
  is_excluded "$file" && continue
  [[ -f $SCAN_PATH/$file ]] || continue
  lockfiles+=("$file")
done < <(LC_ALL=C sort -z "$work/files")

if [[ ${#lockfiles[@]} -eq 0 ]]; then
  if [[ $REQUIRE_LOCKFILE == true ]]; then
    echo "::error title=Lockfile check::no lockfile found under '$SCAN_PATH' and require-lockfile is set"
    exit 2
  fi
  echo "lockfile-check: no lockfile found under '$SCAN_PATH'; nothing to check"
  exit 0
fi

extract() {
  local file=$1 name=${1##*/}
  case $name in
    package-lock.json | npm-shrinkwrap.json)
      command -v jq > /dev/null || { echo "jq not found" >&2; return 1; }
      jq -r -f "$script_dir/npm.jq" "$SCAN_PATH/$file"
      ;;
    pnpm-lock.yaml)
      "$AWK" -f "$script_dir/pnpm.awk" "$SCAN_PATH/$file"
      ;;
    yarn.lock)
      if grep -q '^__metadata:' "$SCAN_PATH/$file"; then
        "$AWK" -f "$script_dir/yarn-berry.awk" "$SCAN_PATH/$file"
      else
        "$AWK" -f "$script_dir/yarn-classic.awk" "$SCAN_PATH/$file"
      fi
      ;;
  esac
}

sanitize() {
  tr -c ' -~\n' '?'
}

checked=0
records=0
violations=0
errors=0
for file in "${lockfiles[@]}"; do
  checked=$((checked + 1))
  shown=$(printf '%s' "$file" | sanitize)
  case ${file##*/} in
    bun.lock | bun.lockb)
      echo "ERROR $shown: bun lockfiles are not supported; add it to exclude-paths if it is intentional"
      errors=$((errors + 1))
      continue
      ;;
  esac
  dir=${file%/*}
  [[ $dir != "$file" ]] || dir=.
  if ! extract "$file" > "$work/rows" 2> "$work/err"; then
    echo "ERROR $shown: could not parse: $(sanitize < "$work/err" | head -c 300)"
    errors=$((errors + 1))
    continue
  fi
  status=0
  LOCKCHECK_REGISTRIES=$registry_list LOCKCHECK_BASE=$dir LOCKCHECK_LABEL=$file \
    "$AWK" -f "$script_dir/evaluate.awk" "$work/rows" > "$work/out" || status=$?
  cat "$work/out"
  records=$((records + $(wc -l < "$work/rows")))
  case $status in
    0) echo "ok $shown" ;;
    1) violations=$((violations + $(grep -c '^FAIL ' "$work/out"))) ;;
    *) errors=$((errors + 1)) ;;
  esac
done

echo "lockfile-check: $checked lockfiles, $records records, $violations violations, $errors errors"
if [[ $errors -gt 0 ]]; then
  echo "::error title=Lockfile check::$errors lockfiles could not be checked"
  exit 2
fi
if [[ $violations -gt 0 ]]; then
  echo "::error title=Lockfile check::$violations packages resolve from outside the approved registries"
  exit 1
fi
