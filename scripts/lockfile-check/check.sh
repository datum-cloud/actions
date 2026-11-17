#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWK=${AWK:-awk}
SCAN_PATH=${SCAN_PATH:-.}
EXCLUDE_PATHS=${EXCLUDE_PATHS:-}
ALLOWED_REGISTRIES=${ALLOWED_REGISTRIES:-}
REQUIRE_LOCKFILE=${REQUIRE_LOCKFILE:-false}
ALLOW_UNCHECKED_YARN_ARTIFACTS=${ALLOW_UNCHECKED_YARN_ARTIFACTS:-false}
YQ=${YQ:-yq}
YAML_FLAGS=(--yaml-fix-merge-anchor-to-spec=true -o=json -I0)
YAML_FILTER='(if ([.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length))] | length) > 0 then error("duplicate mapping keys") else . end)'

default_registries=(https://registry.npmjs.org/ https://registry.yarnpkg.com/)

sanitize() {
  tr -c ' -~\n' '?'
}

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

excluded=0

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
  if is_excluded "$file"; then
    echo "NOTICE excluded $(printf '%s' "$file" | sanitize)"
    excluded=$((excluded + 1))
    continue
  fi
  lockfiles+=("$file")
done < <(LC_ALL=C sort -z "$work/files")

if [[ $excluded -gt 0 ]]; then
  echo "::warning title=Lockfile check::$excluded lockfiles were excluded by exclude-paths and not checked"
fi

violations=0
while IFS= read -r -d '' file; do
  file=${file#./}
  case /$file/ in */node_modules/*) continue ;; esac
  case /$file in
    */.yarn/cache/*.zip | */.pnp.cjs | */.pnp.loader.mjs) ;;
    *) continue ;;
  esac
  [[ $ALLOW_UNCHECKED_YARN_ARTIFACTS != true ]] || continue
  echo "FAIL $(printf '%s' "$file" | sanitize): tracked Yarn offline cache or Plug'n'Play file the check can't read (set allow-unchecked-yarn-artifacts to accept)"
  violations=$((violations + 1))
done < <(LC_ALL=C sort -z "$work/files")

if [[ ${#lockfiles[@]} -eq 0 ]]; then
  if [[ $REQUIRE_LOCKFILE == true ]]; then
    echo "::error title=Lockfile check::no lockfile found under '$SCAN_PATH' to check ($excluded excluded) and require-lockfile is set"
    exit 2
  fi
  if [[ $violations -gt 0 ]]; then
    echo "::error title=Lockfile check::$violations tracked files hold packages the check can't read"
    exit 1
  fi
  echo "lockfile-check: no lockfile found under '$SCAN_PATH' to check ($excluded excluded); nothing to check"
  exit 0
fi

need_yq() {
  local out
  out=$("$YQ" --version 2>&1) || fail_config "yq not found; mikefarah yq v4 is required to read pnpm and Yarn Berry lockfiles"
  [[ $out == *github.com/mikefarah/yq*version\ v4.* ]] || fail_config "yq must be mikefarah yq v4, found: $(printf '%s' "$out" | sanitize | head -c 100)"
  printf 'a: 1\n' | "$YQ" "${YAML_FLAGS[@]}" . > /dev/null 2>&1 || fail_config "this yq does not support --yaml-fix-merge-anchor-to-spec; use v4.47 or newer"
}

yaml_to_json() {
  "$YQ" "${YAML_FLAGS[@]}" "$YAML_FILTER" "$SCAN_PATH/$1"
}

is_yarn_classic() {
  "$AWK" '
    /^#/ { if (tolower($0) ~ /^#[ \t]+yarn[ \t]+lockfile[ \t]+v1\r?$/) { found = 1; exit } next }
    { exit }
    END { exit !found }
  ' "$SCAN_PATH/$1"
}

extract() {
  local file=$1 name=${1##*/}
  case $name in
    package-lock.json | npm-shrinkwrap.json)
      command -v jq > /dev/null || { echo "jq not found" >&2; return 1; }
      jq -r -f "$script_dir/npm.jq" "$SCAN_PATH/$file"
      ;;
    pnpm-lock.yaml)
      yaml_to_json "$file" | jq -r -f "$script_dir/pnpm.jq"
      ;;
    yarn.lock)
      if is_yarn_classic "$file"; then
        "$AWK" -f "$script_dir/yarn-classic.awk" "$SCAN_PATH/$file"
      else
        yaml_to_json "$file" | jq -r -f "$script_dir/yarn-berry.jq"
      fi
      ;;
  esac
}

checked=0
records=0
errors=0
command -v jq > /dev/null || fail_config "jq not found"
for file in "${lockfiles[@]}"; do
  case ${file##*/} in
    pnpm-lock.yaml | yarn.lock)
      need_yq
      break
      ;;
  esac
done
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
  if [[ ! -f $SCAN_PATH/$file ]]; then
    echo "ERROR $shown: listed by git but missing from the work tree"
    errors=$((errors + 1))
    continue
  fi
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
