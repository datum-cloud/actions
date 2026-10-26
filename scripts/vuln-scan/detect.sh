#!/usr/bin/env bash
# Find what the vulnerability scan should cover and write it to PLAN_FILE, one
# tab-separated line per target:
#
#   <action>  <ecosystem>  <target>  <note>
#
# action is one of:
#   scan         scan this target
#   skip         found, not scanned; the note says why
#   unlocked     a manifest with no lockfile, so nothing pins its versions
#   unsupported  found, but cannot be scanned; the scan fails
#   meta         a fact for the summary, with ecosystem as its key
# Targets are paths relative to SCAN_PATH, or image references.
#
# Inside a Git work tree, files come from Git: tracked files plus untracked
# ones that .gitignore doesn't exclude. Outside one, find walks SCAN_PATH.
set -euo pipefail

PLAN_FILE=${PLAN_FILE:-${RUNNER_TEMP:?}/vuln-scan-plan.tsv}
SCAN_PATH=${SCAN_PATH:-.}
ECOSYSTEMS=${ECOSYSTEMS:-auto}
EXCLUDE_PATHS=${EXCLUDE_PATHS:-}
INCLUDE_DEV=${INCLUDE_DEV:-false}
IMAGES=${IMAGES:-}
GO_VERSION=${GO_VERSION:-}

known_ecosystems=(go node python rust)

if [[ ! -d $SCAN_PATH ]]; then
  echo "::error title=Vulnerability scan::path '$SCAN_PATH' is not a directory"
  exit 1
fi

# Inputs are lists separated by commas, spaces, or newlines.
split_list() {
  tr ', \t' '\n' <<< "$1" | sed '/^$/d'
}

selected=()
if [[ $(split_list "$ECOSYSTEMS") == auto ]]; then
  selected=("${known_ecosystems[@]}")
  explicit=false
else
  explicit=true
  while IFS= read -r ecosystem; do
    case $ecosystem in
      go | node | python | rust) selected+=("$ecosystem") ;;
      *)
        echo "::error title=Vulnerability scan::unknown ecosystem '$ecosystem' in ecosystems input; use auto or any of: ${known_ecosystems[*]}"
        exit 1
        ;;
    esac
  done < <(split_list "$ECOSYSTEMS")
fi

is_selected() {
  local ecosystem
  for ecosystem in "${selected[@]}"; do
    [[ $ecosystem == "$1" ]] && return 0
  done
  return 1
}

excludes=()
while IFS= read -r pattern; do
  excludes+=("${pattern%/}")
done < <(split_list "$EXCLUDE_PATHS")

is_excluded() {
  local pattern
  for pattern in "${excludes[@]+"${excludes[@]}"}"; do
    # shellcheck disable=SC2053 # The pattern is a glob on purpose.
    [[ $1 == $pattern || $1 == $pattern/* ]] && return 0
  done
  return 1
}

# Requirements files for development, testing, linting, or docs, such as
# requirements-dev.txt, dev-requirements.txt, or requirements/test.txt.
is_dev_requirements() {
  local name
  name=$(basename "$1" .txt)
  [[ $1 == */requirements/* || $1 == requirements/* ]] || name=${name//requirements/}
  [[ $name =~ (^|[-_.])(dev|develop|test|tests|testing|lint|docs?)([-_.]|$) ]]
}

plan=()
add() {
  plan+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-}")
}

# Installed, vendored, and fixture code, even when tracked, holds other
# projects' dependency files rather than this project's.
is_foreign() {
  [[ /$1/ =~ /(node_modules|vendor|testdata)/ ]]
}

is_candidate() {
  case $(basename "$1") in
    go.mod | package.json | package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | \
      yarn.lock | bun.lock | bun.lockb | *requirements*.txt | poetry.lock | Pipfile.lock | \
      uv.lock | pdm.lock | pylock.toml | pylock.*.toml | pyproject.toml | Cargo.lock | Cargo.toml)
      return 0
      ;;
  esac
  [[ $1 == requirements/*.txt || $1 == */requirements/*.txt ]]
}

files=()
if git -C "$SCAN_PATH" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  add meta discovery git "tracked files and untracked files that .gitignore doesn't exclude"
  declare -A submodules=()
  while IFS= read -r -d '' entry; do
    [[ ${entry%% *} == 160000 ]] && submodules[${entry#*$'\t'}]=1
  done < <(git -C "$SCAN_PATH" ls-files --stage -z)
  while IFS= read -r -d '' path; do
    if [[ -n ${submodules[$path]:-} ]]; then
      add skip git "$path" "Git submodule; scan it from its own repository"
    elif [[ $path == */ ]]; then
      add skip git "${path%/}" "nested Git repository; scan it from its own repository"
    elif [[ -f $SCAN_PATH/$path ]] && ! is_foreign "$path" && is_candidate "$path"; then
      files+=("$path")
    fi
  done < <(git -C "$SCAN_PATH" ls-files --cached --others --exclude-standard \
    --deduplicate -z)
else
  add meta discovery find "not a Git work tree, so .gitignore doesn't apply"
  while IFS= read -r -d '' path; do
    path=${path#./}
    is_candidate "$path" && files+=("$path")
  done < <(cd "$SCAN_PATH" && find . \( -name .git -o -name node_modules -o -name vendor \
    -o -name testdata -o -name .venv \) -prune -o -type f -print0)
fi
mapfile -t files < <(printf '%s\n' "${files[@]+"${files[@]}"}" | sed '/^$/d' | LC_ALL=C sort -u)

# Directories whose lockfiles pin a manifest there or in any subdirectory, as
# in an npm, Cargo, or uv workspace.
declare -A lock_dirs=()
for file in "${files[@]+"${files[@]}"}"; do
  case $(basename "$file") in
    package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | yarn.lock | bun.lock | bun.lockb)
      lock_dirs[node:$(dirname "$file")]=1 ;;
    Cargo.lock) lock_dirs[rust:$(dirname "$file")]=1 ;;
    poetry.lock | Pipfile.lock | uv.lock | pdm.lock | pylock.toml | pylock.*.toml | *requirements*.txt)
      lock_dirs[python:$(dirname "$file")]=1 ;;
  esac
done

is_locked() {
  local dir=$2
  while :; do
    [[ -n ${lock_dirs[$1:$dir]:-} ]] && return 0
    [[ $dir == . ]] && return 1
    dir=$(dirname "$dir")
  done
}

go_modules=()
for file in "${files[@]+"${files[@]}"}"; do
  dir=$(dirname "$file")
  base=$(basename "$file")
  case $base in
    go.mod) ecosystem=go target=$dir ;;
    package.json | package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | yarn.lock | bun.lock | bun.lockb) ecosystem=node target=$file ;;
    Cargo.lock | Cargo.toml) ecosystem=rust target=$file ;;
    *) ecosystem=python target=$file ;;
  esac

  # A manifest matters only when no lockfile pins it. Report those so the gap
  # is visible instead of passing as if it were scanned.
  manifest=false
  case $base in
    package.json | Cargo.toml | pyproject.toml)
      is_locked "$ecosystem" "$dir" && continue
      manifest=true
      ;;
  esac

  if is_excluded "$file"; then
    add skip "$ecosystem" "$target" "excluded by exclude-paths"
    continue
  fi
  if ! is_selected "$ecosystem"; then
    add skip "$ecosystem" "$target" "ecosystem not selected"
    continue
  fi

  if $manifest; then
    add unlocked "$ecosystem" "$file" "$base with no lockfile; versions are not pinned"
    continue
  fi
  case $base in
    bun.lockb)
      add unsupported node "$file" "binary lockfile; run \`bun install --save-text-lockfile\` to switch to bun.lock"
      ;;
    *.txt)
      if [[ $INCLUDE_DEV != true ]] && is_dev_requirements "$file"; then
        add skip python "$file" "development requirements; set include-dev-dependencies to scan"
      else
        add scan python "$file"
      fi
      ;;
    go.mod)
      add scan go "$dir"
      go_modules+=("$file")
      ;;
    *)
      add scan "$ecosystem" "$target"
      ;;
  esac
done

# Pick the Go version govulncheck runs with, which decides the standard
# library findings. One Go serves every module, so it comes from the highest
# minor version among them. A toolchain directive names the exact version a
# module ships with, and wins if it meets every module's go directive. A go
# directive is only a floor, written X.Y.0, while builds use golang:X.Y, the
# latest X.Y patch, so without a usable pin the scan uses that latest patch.
go_version=
version_max() {
  printf '%s\n' "$@" | sed '/^$/d' | sort -V | tail -n 1
}
if [[ ${#go_modules[@]} -gt 0 ]]; then
  if [[ -n $GO_VERSION ]]; then
    go_version=$GO_VERSION
    go_note="set by the go-version input"
  else
    declare -A pins=() floors=() minors=()
    for file in "${go_modules[@]}"; do
      pins[$file]=$(sed -nE 's/^toolchain[[:space:]]+go([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$SCAN_PATH/$file" | head -n 1)
      floor=$(sed -nE 's/^go[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?)[[:space:]]*$/\1/p' "$SCAN_PATH/$file" | head -n 1)
      if [[ -z $floor ]]; then
        echo "::error title=Vulnerability scan::$file has no go directive; set the go-version input"
        exit 1
      fi
      [[ $floor == *.*.* ]] || floor=$floor.0
      floors[$file]=$floor
      version=$(version_max "$floor" "${pins[$file]}")
      minors[$file]=${version%.*}
    done
    minor=$(version_max "${minors[@]}")
    highest_floor=$(version_max "${floors[@]}")
    pin='' pin_file='' floor_file='' source_file=''
    for file in "${go_modules[@]}"; do
      [[ ${floors[$file]} == "$highest_floor" && -z $floor_file ]] && floor_file=$file
      [[ ${minors[$file]} == "$minor" ]] || continue
      if [[ -n ${pins[$file]} && $(version_max "$pin" "${pins[$file]}") == "${pins[$file]}" && ${pins[$file]} != "$pin" ]]; then
        pin=${pins[$file]} pin_file=$file
      fi
      [[ -n $source_file ]] || source_file=$file
    done
    if [[ -n $pin && $(version_max "$pin" "$highest_floor") == "$pin" ]]; then
      go_version=$pin
      go_note="from the toolchain directive in $pin_file"
    else
      go_version=$minor
      if [[ -n $pin ]]; then
        go_note="latest $minor patch, because $floor_file requires go $highest_floor, above the toolchain directive in $pin_file"
      else
        go_note="latest $minor patch, from the go directive in $source_file"
      fi
    fi
    if [[ $(printf '%s\n' "${minors[@]}" | sort -u | wc -l) -gt 1 ]]; then
      go_note+="; the highest Go minor version across ${#go_modules[@]} modules, so modules on older ones are scanned with it"
    elif [[ ${#go_modules[@]} -gt 1 ]]; then
      go_note+="; used for all ${#go_modules[@]} Go modules"
    fi
  fi
  add meta go-version "$go_version" "$go_note"
fi

if $explicit; then
  for ecosystem in "${selected[@]}"; do
    if ! printf '%s\n' "${plan[@]+"${plan[@]}"}" | grep -q "^scan"$'\t'"$ecosystem"$'\t'; then
      echo "::error title=Vulnerability scan::ecosystems input selects $ecosystem, but no $ecosystem dependencies were found under '$SCAN_PATH'"
      exit 1
    fi
  done
fi

while IFS= read -r image; do
  add scan image "$image"
done < <(split_list "$IMAGES")

printf '%s\n' "${plan[@]+"${plan[@]}"}" | sed '/^$/d' > "$PLAN_FILE"

count() {
  awk -F'\t' -v a="$1" -v e="$2" '$1 == a && (e == "" || $2 == e)' "$PLAN_FILE" | wc -l | tr -d ' '
}

echo "Scan plan for '$SCAN_PATH':"
if grep -qv '^meta' "$PLAN_FILE"; then
  awk -F'\t' '$1 != "meta" { printf "  %-11s %-7s %s%s\n", $1, $2, $3, ($4 == "" ? "" : "  (" $4 ")") }' "$PLAN_FILE"
else
  echo "  (nothing found)"
fi
awk -F'\t' '$1 == "meta" { printf "%s: %s%s\n", $2, $3, ($4 == "" ? "" : " (" $4 ")") }' "$PLAN_FILE"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "go=$([[ $(count scan go) -gt 0 ]] && echo true || echo false)"
    echo "osv=$([[ $(($(count scan node) + $(count scan python) + $(count scan rust))) -gt 0 ]] && echo true || echo false)"
    echo "image=$([[ $(count scan image) -gt 0 ]] && echo true || echo false)"
    echo "go-version=$go_version"
  } >> "$GITHUB_OUTPUT"
fi
