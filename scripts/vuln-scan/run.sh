#!/usr/bin/env bash
# Run the vulnerability scan on a workstation, the way the vuln-scan workflow
# runs it in CI: detect.sh, then install-tools.sh for only the scanners the
# plan needs, then scan.sh. See --help.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: run.sh [--help]

Scan a directory for known vulnerabilities with the same scripts, scanner
versions, and Go version as the vuln-scan workflow. Exits non-zero when the
scan finds a vulnerability, a scanner fails, or there is nothing to scan.

Settings are environment variables, named after the workflow inputs:

  SCAN_PATH      Directory to scan. Default: the current directory.
  ECOSYSTEMS     auto, or a comma-separated list of go, node, python, rust.
                 Default: auto.
  EXCLUDE_PATHS  Comma- or newline-separated globs, relative to SCAN_PATH,
                 not to scan.
  INCLUDE_DEV    true to also scan dev dependencies. Default: false.
  IMAGES         Comma- or newline-separated container images to scan.
  IMAGE_SEVERITY, IMAGE_IGNORE_UNFIXED
                 Trivy settings, as in the workflow.
  ALLOW_EMPTY    true to pass, with a warning, when there is nothing to scan.
                 Default: false.
  GO_VERSION     Go version for govulncheck, such as 1.26 or 1.26.10.
                 Default: chosen from the go.mod files, as in CI.

Scanners are cached by version under
${XDG_CACHE_HOME:-$HOME/.cache}/datum-vuln-scan/bin. Delete that directory to
reinstall them.

Requires bash, git, curl, and jq, plus go when there are Go modules and
python3 3.11 or later when SCAN_PATH has an osv-scanner.toml, which only
Python's tomllib can read among preinstalled tools. The go command downloads the Go version the scan selects, so
standard library findings match CI even when your Go is newer.
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

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/datum-vuln-scan

die() {
  echo "error: $*" >&2
  exit 1
}

for command in git curl jq; do
  command -v "$command" > /dev/null || die "$command is required"
done
if [[ -f ${SCAN_PATH:-.}/osv-scanner.toml ]] && ! python3 -c 'import tomllib' 2> /dev/null; then
  die "python3 3.11 or later is required to read osv-scanner.toml; toml-to-json.py says why"
fi

RUNNER_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/vuln-scan.XXXXXX")
trap 'rm -rf "$RUNNER_TEMP"' EXIT
export RUNNER_TEMP
export SCAN_PATH=${SCAN_PATH:-.}
export PLAN_FILE=$RUNNER_TEMP/plan.tsv
export GITHUB_OUTPUT=$RUNNER_TEMP/output GITHUB_PATH=$RUNNER_TEMP/path
unset GITHUB_STEP_SUMMARY
: > "$GITHUB_OUTPUT"
: > "$GITHUB_PATH"

# The scripts print GitHub Actions annotations and Markdown. Turn them into
# plain terminal text: annotations become "error:" or "warning:" lines,
# groups become headings, and each table is aligned once it ends.
to_terminal() {
  awk '
    function flush(   i, j, n, cells, line) {
      for (i = 1; i <= rows; i++) {
        line = ""
        n = split(table[i], cells, "\t")
        for (j = 1; j <= n; j++) {
          line = line sprintf(j < n ? "%-" width[j] "s  " : "%s", cells[j])
        }
        print "  " line
      }
      rows = 0
      delete width
    }
    /^\|---/ { next }
    /^\| / {
      line = $0
      gsub(/\*\*|`/, "", line)
      sub(/^\| /, "", line)
      sub(/ \|$/, "", line)
      gsub(/ \| /, "\t", line)
      table[++rows] = line
      n = split(line, cells, "\t")
      for (j = 1; j <= n; j++) if (length(cells[j]) > width[j]) width[j] = length(cells[j])
      next
    }
    { if (rows) flush() }
    /^::endgroup::/ { next }
    /^::group::/ { sub(/^::group::/, "== "); print; next }
    /^::(error|warning|notice)/ {
      kind = substr($0, 3, index(substr($0, 3), " ") - 1)
      sub(/^::[a-z]+ title=/, "")
      title = substr($0, 1, index($0, "::") - 1)
      print kind ": " title ": " substr($0, index($0, "::") + 2)
      next
    }
    /^## / { sub(/^## /, ""); print toupper($0); next }
    { gsub(/\*\*|`/, ""); print }
    END { if (rows) flush() }
  '
}

output() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1
}

bash "$script_dir/detect.sh" | to_terminal
status=${PIPESTATUS[0]}
[[ $status -eq 0 ]] || exit "$status"

tools=()
[[ $(output go) != true ]] || tools+=(govulncheck)
[[ $(output osv) != true ]] || tools+=(osv-scanner)
[[ $(output image) != true ]] || tools+=(trivy)

if [[ $(output go) == true ]]; then
  command -v go > /dev/null || die "go is required to scan Go modules"
  requested=$(output go-version)
  exact=$requested
  # GOTOOLCHAIN needs an exact release, so resolve X.Y to its latest patch
  # the way setup-go's check-latest does in CI.
  if [[ $exact != *.*.* ]]; then
    exact=$(curl --fail --silent --show-error --location --retry 3 \
      'https://go.dev/dl/?mode=json&include=all' |
      jq -r --arg minor "$requested" '
        [.[] | select(.stable) | .version | ltrimstr("go")
         | select(. == $minor or startswith($minor + "."))]
        | max_by(split(".") | map(tonumber)) // ""
      ') || die "can't list Go releases from go.dev to resolve Go $requested"
    [[ -n $exact ]] || die "no stable Go release matches $requested"
  fi
fi

if [[ ${#tools[@]} -gt 0 ]]; then
  CACHE_DIR=$cache_dir/bin bash "$script_dir/install-tools.sh" "${tools[@]}" 2>&1 | to_terminal
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "installing scanners failed"
  while IFS= read -r dir; do
    PATH=$dir:$PATH
  done < "$GITHUB_PATH"
  export PATH
fi

if [[ $(output go) == true ]]; then
  # Switch after installing govulncheck, which builds with your own Go. The
  # go command downloads this toolchain if it isn't cached already.
  export GOTOOLCHAIN=go$exact
  # go prints its download progress on stderr; keep that out of the version.
  installed=$(go env GOVERSION 2> "$RUNNER_TEMP/go.err") ||
    die "can't switch to Go $exact (is the network or module proxy unreachable?): $(cat "$RUNNER_TEMP/go.err")"
  [[ $installed == "go$exact" ]] || die "asked for Go $exact but got $installed"
  echo "Go $requested resolved to $installed."
fi

REQUIRE_GO_VERSION=true bash "$script_dir/scan.sh" 2>&1 | to_terminal
exit "${PIPESTATUS[0]}"
