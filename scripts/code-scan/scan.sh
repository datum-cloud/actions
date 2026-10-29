#!/usr/bin/env bash
# Scan every file under SCAN_PATH with Semgrep and the rules in RULES_DIR, and
# fail on any finding. The scan only reads files: it installs no dependencies
# and runs none of the repository's code.
#
# The scan reads the whole tree, not a diff, and ignores everything an attacker
# who can edit the repository could use to hide a file: .semgrepignore files
# are deleted, Semgrep's default skip list (tests/, vendor/, *.min.js) is off,
# .gitignore is not consulted, inline `nosemgrep` comments are off, and there
# is no file size limit.
#
# Inputs (environment):
#   SCAN_PATH      Directory to scan. Default: .
#   EXCLUDE_PATHS  Comma or newline separated globs to skip, as semgrep
#                  --exclude takes them.
#   EXTRA_RULES    Path to an extra rules file or directory. Default: none.
#   RULES_DIR      Rules shipped with this scan. Default: rules/ beside this
#                  script.
#   IGNORE_FILE   Central ignore file, relative to SCAN_PATH. Default:
#                  .github/code-scan-ignore.toml. A missing file means no
#                  suppressions. An entry names a rule id and one exact path
#                  (no globs), a reason, and an ignoreUntil date at most 12
#                  months out; see filter.py. The file itself is not scanned.
#   IGNORE_BASE_REF  A Git revision, such as the base commit of a pull
#                  request. When set, the ignore file is read from that
#                  revision instead of the working tree, so a change can't
#                  suppress its own findings; a file missing there means no
#                  suppressions. A revision that doesn't resolve is a
#                  configuration error. Default: unset.
#   TODAY          Date (YYYY-MM-DD) that expiry is judged against. Default:
#                  today in UTC.
#   GITHUB_STEP_SUMMARY  When set, the job summary is appended to this file.
#   RESULTS_FILE   Where to write Semgrep's JSON. Default:
#                  $RUNNER_TEMP/code-scan.json
#
# Exit status: 0 for no findings, 1 for findings, 2 for a scanner or
# configuration error.
set -euo pipefail

SCAN_PATH=${SCAN_PATH:-.}
EXCLUDE_PATHS=${EXCLUDE_PATHS:-}
EXTRA_RULES=${EXTRA_RULES:-}
IGNORE_FILE=${IGNORE_FILE:-.github/code-scan-ignore.toml}
IGNORE_BASE_REF=${IGNORE_BASE_REF:-}
TODAY=${TODAY:-$(date -u +%F)}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RULES_DIR=${RULES_DIR:-$script_dir/rules}
RESULTS_FILE=${RESULTS_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/code-scan.json}

config_error() {
  echo "::error title=Code scan::$1"
  exit 2
}

[[ -d $SCAN_PATH ]] || config_error "scan path '$SCAN_PATH' is not a directory"
root=$(cd "$SCAN_PATH" && pwd)
[[ -e $RULES_DIR ]] || config_error "rules '$RULES_DIR' do not exist"
rules=$(cd "$(dirname "$RULES_DIR")" && pwd)/$(basename "$RULES_DIR")
extra=
if [[ -n $EXTRA_RULES ]]; then
  [[ -e $root/$EXTRA_RULES || -e $EXTRA_RULES ]] || config_error "extra rules '$EXTRA_RULES' do not exist"
  if [[ -e $root/$EXTRA_RULES ]]; then extra=$root/$EXTRA_RULES; else extra=$EXTRA_RULES; fi
fi
mkdir -p "$(dirname "$RESULTS_FILE")"

# A caller's .semgrepignore could exclude the file an attacker changed. Semgrep
# also skips tests/, vendor/, *.min.js and similar paths by default; the
# internal flag below turns off that list along with any .semgrepignore file.
find "$root" -name .semgrepignore -not -path '*/.git/*' -type f -delete

# Only the root .git directory. node_modules is scanned: CI installs nothing,
# so any file there was committed, and a pull would put it over the
# developer's installed copy. Lockfiles are scanned too: Node runs a .lock
# file named in a require() as code.
excludes=(/.git)
# The ignore file's reasons may quote the code they excuse (child_process,
# curl | sh), so the scan skips exactly that one path. Nothing runs it: it is
# only parsed as TOML, and code owners review every change to it.
case $IGNORE_FILE in
  /* | ../* | */../* | */.. | ..) config_error "IGNORE_FILE '$IGNORE_FILE' must be a path inside SCAN_PATH" ;;
esac
# Semgrep reads --exclude as a gitignore-style glob, so a pattern character
# would exclude more than the one file.
case $IGNORE_FILE in
  *[*?\[\]{}]* | '!'* | */) config_error "IGNORE_FILE '$IGNORE_FILE' must be one literal file path, without glob characters" ;;
esac
if [[ -e $root/$IGNORE_FILE && ! -f $root/$IGNORE_FILE ]]; then
  config_error "IGNORE_FILE '$IGNORE_FILE' is not a regular file"
fi
excludes+=("/${IGNORE_FILE#./}")

# The ignore file that applies: the working tree's, or the one at
# IGNORE_BASE_REF. The base copy goes to a temporary file; a path missing at
# the base leaves no file there, which means no suppressions.
ignore_source=$root/$IGNORE_FILE
ignore_label=
if [[ -n $IGNORE_BASE_REF ]]; then
  git -C "$root" rev-parse --verify --quiet "$IGNORE_BASE_REF^{commit}" > /dev/null ||
    config_error "IGNORE_BASE_REF '$IGNORE_BASE_REF' is not a commit in this checkout; fetch it (fetch-depth: 2 for a pull request)"
  ignore_source=$RESULTS_FILE.ignore-base.toml
  rm -f "$ignore_source"
  base_object="$IGNORE_BASE_REF:./${IGNORE_FILE#./}"
  case $(git -C "$root" cat-file -t "$base_object" 2> /dev/null || echo missing) in
    blob) git -C "$root" cat-file blob "$base_object" > "$ignore_source" ;;
    missing) ;;
    *) config_error "IGNORE_FILE '$IGNORE_FILE' is not a regular file at $IGNORE_BASE_REF" ;;
  esac
  ignore_label="base commit $(git -C "$root" rev-parse --short "$IGNORE_BASE_REF^{commit}")"
  echo "Code scan: ignore entries come from the $ignore_label."
  # The pull request's own copy doesn't apply, but it is still validated: a
  # broken file would otherwise merge and fail every later scan, including
  # the pull request that fixes it.
  if [[ -f $root/$IGNORE_FILE ]]; then
    python3 "$script_dir/filter.py" --validate-only --results /dev/null --ignore-file "$root/$IGNORE_FILE" \
      --scan-root "$root" --today "$TODAY" "--source-label=the pull request's ignore file (${IGNORE_FILE#./})" || exit 2
  fi
  if ! cmp -s "$ignore_source" "$root/$IGNORE_FILE" 2> /dev/null && [[ -e $ignore_source || -e $root/$IGNORE_FILE ]]; then
    echo "::notice title=Code scan::This pull request changes the ignore file. The scan uses the version at the $ignore_label; the pull request's entries take effect only after it merges."
  fi
fi
while IFS= read -r pattern; do
  pattern=${pattern#"${pattern%%[![:space:]]*}"}
  pattern=${pattern%"${pattern##*[![:space:]]}"}
  [[ -z $pattern ]] || excludes+=("$pattern")
done < <(printf '%s\n' "$EXCLUDE_PATHS" | tr ',' '\n')

# Target selection, shared by the listing and the scan so both see the same
# files. --no-exclude-binary-files: Semgrep's binary test would skip a
# polyglot such as a GIF that is also JavaScript; real binaries hold NUL bytes
# and match nothing.
select_args=(
  --metrics=off --no-git-ignore --max-target-bytes=0
  --x-ignore-semgrepignore-files --no-exclude-binary-files
)
for pattern in "${excludes[@]}"; do
  select_args+=(--exclude "$pattern")
done

rule_args=(--disable-nosem --timeout 0 --timeout-threshold 0 --config "$rules")
[[ -z $extra ]] || rule_args+=(--config "$extra")

# run_semgrep OUTPUT ARGS... scans from the scan root and stops with a scanner
# error unless Semgrep exits 0 or 1.
run_semgrep() {
  local output=$1 status=0
  shift
  (cd "$root" && semgrep scan "${select_args[@]}" "${rule_args[@]}" --json --output "$output" "$@") || status=$?
  if [[ $status -ne 0 && $status -ne 1 ]]; then
    config_error "semgrep exited $status"
  fi
}

run_semgrep "$RESULTS_FILE" .

# Checks Semgrep's rules can't make, such as text that isn't valid UTF-8, on
# the files the main pass lists in paths.scanned; the results join Semgrep's
# below. An empty list while the scan root holds files is a scanner error.
prescan_file=$RESULTS_FILE.prescan.json
explicit_file=$RESULTS_FILE.explicit
python3 "$script_dir/prescan.py" --scan-root "$root" --semgrep-results "$RESULTS_FILE" \
  "--ignore-file=${IGNORE_FILE#./}" --output "$prescan_file" --explicit-targets "$explicit_file" || exit 2
extra_results=(--extra-results "$prescan_file")

# Semgrep picks a file's language by extension and skips symlinks, so files
# Node can run but Semgrep wouldn't read as JavaScript (.mts, .cts, node
# shebang scripts, symlink targets; see prescan.py) are scanned again as
# explicit targets, which --scan-unknown-extensions gives every rule.
explicit_targets=()
while IFS= read -r -d '' target; do
  explicit_targets+=("$target")
done < "$explicit_file"
if [[ ${#explicit_targets[@]} -gt 0 ]]; then
  run_semgrep "$RESULTS_FILE.explicit.json" --scan-unknown-extensions -- "${explicit_targets[@]}"
  extra_results+=(--extra-results "$RESULTS_FILE.explicit.json")
fi

# GitHub draws an annotation at a repository-relative path; findings are
# relative to the scan root, so annotations get its path in the repository.
path_prefix=$(git -C "$root" rev-parse --show-prefix 2> /dev/null || true)

# Semgrep exits 0 with findings unless told otherwise, so the JSON decides.
python3 "$script_dir/list-findings.py" "$RESULTS_FILE" "$ignore_source" "$root" "$TODAY" "${GITHUB_STEP_SUMMARY:-}" \
  "${extra_results[@]}" "--ignore-file-name=${IGNORE_FILE#./}" "--path-prefix=$path_prefix" \
  ${ignore_label:+"--ignore-source-label=$ignore_label"}
