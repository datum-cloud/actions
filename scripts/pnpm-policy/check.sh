#!/usr/bin/env bash
# Checks that every pnpm project under SCAN_PATH keeps the org's pnpm install
# policy. Exit codes: 0 clean, 1 violations, 2 configuration or parse error.
set -euo pipefail

SCAN_PATH=${SCAN_PATH:-.}
PNPM_MAJOR=${PNPM_MAJOR:-12}
REQUIRE_PNPM=${REQUIRE_PNPM:-false}
REQUIRE_LOCKFILE=${REQUIRE_LOCKFILE:-false}
YQ=${YQ:-yq}

violations=0
warnings=0
checked=0

fail_config() {
  echo "::error title=pnpm policy::$1"
  exit 2
}

violation() {
  echo "FAIL $1: $2"
  echo "::error file=$1,title=pnpm policy::$2"
  violations=$((violations + 1))
}

warn() {
  echo "WARN $1: $2"
  echo "::warning file=$1,title=pnpm policy::$2"
  warnings=$((warnings + 1))
}

[[ -d $SCAN_PATH ]] || fail_config "path '$SCAN_PATH' is not a directory"
[[ $PNPM_MAJOR =~ ^[0-9]+$ ]] || fail_config "pnpm-major must be a whole number, got '$PNPM_MAJOR'"
[[ $REQUIRE_PNPM == true || $REQUIRE_PNPM == false ]] || fail_config "require-pnpm must be true or false, got '$REQUIRE_PNPM'"
[[ $REQUIRE_LOCKFILE == true || $REQUIRE_LOCKFILE == false ]] || fail_config "require-lockfile must be true or false, got '$REQUIRE_LOCKFILE'"

yq_out=$("$YQ" --version 2>&1) || fail_config "yq not found; mikefarah yq v4 is required to read pnpm-workspace.yaml"
[[ $yq_out == *github.com/mikefarah/yq*version\ v4.* ]] || fail_config "yq must be mikefarah yq v4, found: $(printf '%s' "$yq_out" | head -c 100)"

# Prints the value of a top-level key in a YAML file, or nothing when absent.
yaml_get() {
  "$YQ" -e "$2 // \"\"" "$1" 2>/dev/null || true
}

lockfiles=()
others=()
while IFS= read -r -d '' file; do
  case ${file##*/} in
    pnpm-lock.yaml) lockfiles+=("${file#./}") ;;
    package-lock.json | npm-shrinkwrap.json | yarn.lock | bun.lock | bun.lockb) others+=("${file#./}") ;;
  esac
done < <(cd "$SCAN_PATH" && find . -name node_modules -prune -o -type f \( -name pnpm-lock.yaml -o -name package-lock.json -o -name npm-shrinkwrap.json -o -name yarn.lock -o -name bun.lock -o -name bun.lockb \) -print0 | sort -z)

if [[ $REQUIRE_PNPM == true ]]; then
  for file in ${others[@]+"${others[@]}"}; do
    violation "$file" "lockfile from another package manager; this repository installs with pnpm"
  done
fi

for lock in ${lockfiles[@]+"${lockfiles[@]}"}; do
  checked=$((checked + 1))
  dir=$(dirname "$lock")
  rel() { [[ $dir == . ]] && echo "$1" || echo "$dir/$1"; }
  pkg=$SCAN_PATH/$(rel package.json)
  ws=$SCAN_PATH/$(rel pnpm-workspace.yaml)

  if [[ ! -f $pkg ]]; then
    violation "$(rel package.json)" "missing beside $lock"
  else
    jq -e . "$pkg" > /dev/null 2>&1 || fail_config "$(rel package.json) is not valid JSON"
    pm=$(jq -r '.packageManager // ""' "$pkg")
    if [[ -z $pm ]]; then
      violation "$(rel package.json)" "no packageManager field; pin pnpm@$PNPM_MAJOR.x.y"
    elif [[ ! $pm =~ ^pnpm@$PNPM_MAJOR\.[0-9]+\.[0-9]+ ]]; then
      violation "$(rel package.json)" "packageManager is '$pm'; pin pnpm $PNPM_MAJOR"
    fi
  fi

  if [[ ! -f $ws ]]; then
    violation "$(rel pnpm-workspace.yaml)" "missing beside $lock; it holds the install policy"
    continue
  fi
  "$YQ" -e '. // {} | tag == "!!map"' "$ws" > /dev/null 2>&1 || fail_config "$(rel pnpm-workspace.yaml) is not a YAML mapping"

  age=$(yaml_get "$ws" .minimumReleaseAge)
  if [[ -z $age ]]; then
    violation "$(rel pnpm-workspace.yaml)" "minimumReleaseAge is not set; set it to 1440 (one day)"
  elif [[ ! $age =~ ^[0-9]+$ || $age -eq 0 ]]; then
    violation "$(rel pnpm-workspace.yaml)" "minimumReleaseAge is '$age'; it must be a positive number of minutes"
  fi

  trust=$(yaml_get "$ws" .trustPolicy)
  [[ $trust == no-downgrade ]] || violation "$(rel pnpm-workspace.yaml)" "trustPolicy is '${trust:-unset}'; set it to no-downgrade"

  builds_tag=$("$YQ" '.allowBuilds | tag' "$ws")
  if [[ $builds_tag != '!!null' && $builds_tag != '!!map' ]]; then
    violation "$(rel pnpm-workspace.yaml)" "allowBuilds must map each package name to true or false"
  fi
  [[ $(yaml_get "$ws" .dangerouslyAllowAllBuilds) != true ]] || violation "$(rel pnpm-workspace.yaml)" "dangerouslyAllowAllBuilds lets every dependency run install scripts; list them in allowBuilds instead"
  [[ $(yaml_get "$ws" '(.allowBuilds // {}) | to_entries | map(select(.key | test("^[*]$"))) | .[0].value') != true ]] || violation "$(rel pnpm-workspace.yaml)" "allowBuilds allows every package; name each one"

  [[ -z $(yaml_get "$ws" .onlyBuiltDependencies) ]] || warn "$(rel pnpm-workspace.yaml)" "onlyBuiltDependencies is the old name; move its entries to allowBuilds"
done

if [[ $checked -eq 0 && $REQUIRE_LOCKFILE == true ]]; then
  fail_config "no pnpm-lock.yaml under '$SCAN_PATH', and require-lockfile is on"
fi
if [[ $checked -eq 0 && ${#others[@]} -eq 0 ]]; then
  echo "nothing to check: no pnpm-lock.yaml under '$SCAN_PATH'"
  exit 0
fi
echo "$checked pnpm lockfiles, $violations violations, $warnings warnings"
[[ $violations -eq 0 ]] || exit 1
